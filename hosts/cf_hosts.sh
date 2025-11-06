#!/bin/sh

HOSTS_FILE="/etc/hosts"
SCRIPT_PATH="/root/cf_hosts.sh"
CONFIG_FILE="/root/cf_hosts.conf"
MARKER="# auto_hosts managed"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

reload_dns() {
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 && log "dnsmasq 已重启。"
}

resolve_ip() {
    local domain="$1"
    local type="$2"
    local ip=""
    if [ "$type" = "A" ]; then
        ip=$(nslookup -type=A "$domain" 2>/dev/null | awk '/^Address: / && !/127\.0\.0\.1/ {print $2; exit}')
    elif [ "$type" = "AAAA" ]; then
        ip=$(nslookup -type=AAAA "$domain" 2>/dev/null | awk '/^Address: / && !/::1$/ {print $2; exit}')
    fi
    echo "$ip"
}

update_hosts() {
    local ip="$1"
    local alias="$2"
    cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"
    # 先删除旧条目（带标记或匹配别名）
    sed -i "/[[:space:]]$alias\($\|[[:space:]]\)/d" "$HOSTS_FILE"
    # 添加新条目并打标记
    echo "$ip    $alias    $MARKER" >> "$HOSTS_FILE"
    log "✅ 已更新 hosts: $ip → $alias"
}

set_cron() {
    local interval="$1"
    sed -i '/auto_hosts\.sh.*--auto-update/d' /etc/crontabs/root
    if [ "$interval" -gt 0 ]; then
        echo "0 */$interval * * * $SCRIPT_PATH --auto-update" >> /etc/crontabs/root
        /etc/init.d/cron restart >/dev/null 2>&1
        log "⏰ 定时任务已设置：每 $interval 小时更新一次。"
    else
        /etc/init.d/cron restart >/dev/null 2>&1
        log "🔕 定时任务已清除。"
    fi
}

auto_update() {
    if [ ! -f "$CONFIG_FILE" ]; then
        logger -t auto_hosts "配置文件不存在，跳过自动更新。"
        exit 0
    fi
    . "$CONFIG_FILE"
    if [ -z "$TARGET_DOMAIN" ] || [ -z "$LOCAL_ALIAS" ] || [ -z "$RECORD_TYPE" ]; then
        logger -t auto_hosts "配置不完整，跳过。"
        exit 1
    fi
    IP=$(resolve_ip "$TARGET_DOMAIN" "$RECORD_TYPE")
    if [ -z "$IP" ]; then
        logger -t auto_hosts "解析失败：$TARGET_DOMAIN"
        exit 1
    fi
    update_hosts "$IP" "$LOCAL_ALIAS"
    reload_dns
    logger -t auto_hosts "自动更新完成: $IP → $LOCAL_ALIAS"
}

uninstall() {
    printf "⚠️  此操作将执行以下动作：\n"
    printf "   • 删除定时任务\n"
    printf "   • 清理 /etc/hosts 中相关条目\n"
    printf "   • 删除配置文件和本脚本\n"
    printf "   • 无法撤销！\n"
    printf "是否确认完全卸载？(y/N): "
    read -r confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            # 1. 删除 cron
            sed -i '/auto_hosts\.sh.*--auto-update/d' /etc/crontabs/root
            /etc/init.d/cron restart >/dev/null 2>&1

            # 2. 删除 hosts 条目（带标记 或 匹配 LOCAL_ALIAS）
            if [ -f "$CONFIG_FILE" ]; then
                . "$CONFIG_FILE"
                if [ -n "$LOCAL_ALIAS" ]; then
                    sed -i "/[[:space:]]$LOCAL_ALIAS\($\|[[:space:]]\)/d" "$HOSTS_FILE"
                fi
            fi
            # 也尝试按标记删除（双重保险）
            sed -i "\|$MARKER|d" "$HOSTS_FILE"

            # 3. 删除配置文件
            rm -f "$CONFIG_FILE"

            # 4. 删除脚本自身（延迟执行）
            log "🧹 正在清理..."
            reload_dns

            # 自删除（必须用 exec + sh -c，否则会报“Text file busy”）
            exec sh -c "rm -f '$SCRIPT_PATH'; log '✅ 完全卸载完成。'"
            ;;
        *)
            log "❌ 卸载已取消。"
            ;;
    esac
}

show_menu() {
    clear
    cat <<EOF
==========================================
  OpenWrt 优选域名本地解析管理工具
==========================================  
  1. 优选域名本地解析
  2. 修改定时解析周期
  3. 取消定时解析任务
  4. 完全卸载（删除任务+配置+脚本）
  0. 退出脚本
------------------------------------------
EOF

    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE" 2>/dev/null
        echo "  当前目标域名: ${TARGET_DOMAIN:-无}"
        echo "  当前本地别名: ${LOCAL_ALIAS:-无}"
        echo "  解析类型:     ${RECORD_TYPE:-无}"
        CRON_ENTRY=$(grep -F "$SCRIPT_PATH --auto-update" /etc/crontabs/root 2>/dev/null)
        if [ -n "$CRON_ENTRY" ]; then
            INTERVAL=$(echo "$CRON_ENTRY" | awk -F'[*/]' '{print $2}' | awk '{print $1}')
            echo "  定时周期:     每 ${INTERVAL:-?} 小时"
        else
            echo "  定时周期:     未设置"
        fi
    else
        echo "  当前状态:     未配置"
    fi
    echo "=========================================="
    printf "请选择操作 (0/1/2/3/4): "
}

# 自动更新模式
if [ "$1" = "--auto-update" ]; then
    auto_update
    exit 0
fi

# 主循环
while true; do
    show_menu
    read -r choice

    case "$choice" in
        0)
            log "👋 再见！"
            exit 0
            ;;
        1)
            printf "请输入要解析的优选域名: "
            read -r TARGET_DOMAIN
            [ -z "$TARGET_DOMAIN" ] && { log "❌ 域名不能为空。"; continue; }

            printf "解析类型:\n  1) IPv4\n  2) IPv6\n请选择: "
            read -r rt_choice
            RECORD_TYPE="A"
            [ "$rt_choice" = "2" ] && RECORD_TYPE="AAAA"

            IP=$(resolve_ip "$TARGET_DOMAIN" "$RECORD_TYPE")
            [ -z "$IP" ] && { log "❌ 解析失败，请检查域名或网络。"; continue; }
            log "🔍 解析成功: $TARGET_DOMAIN → $IP"
            ping -c 1 -W 1 "$IP" >/dev/null 2>&1 &

            printf "请输入本地别名域名: "
            read -r LOCAL_ALIAS
            [ -z "$LOCAL_ALIAS" ] && { log "❌ 本地域名不能为空。"; continue; }

            update_hosts "$IP" "$LOCAL_ALIAS"

            cat > "$CONFIG_FILE" <<EOF
TARGET_DOMAIN="$TARGET_DOMAIN"
RECORD_TYPE="$RECORD_TYPE"
LOCAL_ALIAS="$LOCAL_ALIAS"
EOF

            reload_dns
            set_cron 3
            log "✅ 配置完成！"
            read -p "按回车返回主菜单..."
            ;;

        2)
            if [ ! -f "$CONFIG_FILE" ]; then
                log "⚠️  请先设置解析任务（选项 1）。"
                read -p "按回车继续..."
                continue
            fi
            printf "请输入新的定时间隔（小时，≥1）: "
            read -r hours
            case "$hours" in
                ''|*[!0-9]*)
                    log "❌ 请输入有效数字。"
                    ;;
                *)
                    if [ "$hours" -lt 1 ]; then
                        log "❌ 间隔不能小于 1 小时。"
                    else
                        set_cron "$hours"
                    fi
                    ;;
            esac
            read -p "按回车返回主菜单..."
            ;;

        3)
            set_cron 0
            read -p "按回车返回主菜单..."
            ;;

        4)
            uninstall
            exit 0  # uninstall 中已自删，但保险起见仍 exit
            ;;

        *)
            log "❌ 无效选项。"
            read -p "按回车继续..."
            ;;
    esac
done
