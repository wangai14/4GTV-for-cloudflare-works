#!/bin/sh

HOSTS_FILE="/etc/hosts"
SCRIPT_PATH="/root/cf_hosts.sh"
CONFIG_FILE="/root/cf_hosts.conf"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 刷新 dnsmasq
reload_dns() {
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 && log "dnsmasq 已重启，DNS 缓存已刷新。"
}

# 获取 IP 地址（支持 A / AAAA）
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

# 写入 hosts
update_hosts() {
    local ip="$1"
    local alias="$2"
    cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"
    sed -i "/[[:space:]]$alias\$/d" "$HOSTS_FILE"
    echo "$ip    $alias" >> "$HOSTS_FILE"
    log "✅ 已更新 hosts: $ip → $alias"
}

# 设置定时任务（小时数）
set_cron() {
    local interval="$1"  # 单位：小时
    local cron_line="0 */$interval * * * $SCRIPT_PATH --auto-update"

    # 删除旧 cron 条目
    sed -i '/auto_hosts\.sh/d' /etc/crontabs/root

    # 添加新条目（仅当 interval > 0）
    if [ "$interval" -gt 0 ]; then
        echo "$cron_line" >> /etc/crontabs/root
        log "⏰ 定时任务已设置：每 $interval 小时自动更新一次。"
    else
        log "🔕 定时任务已清除。"
    fi

    /etc/init.d/cron restart >/dev/null 2>&1
}

# 自动更新模式（由 cron 调用）
auto_update() {
    if [ ! -f "$CONFIG_FILE" ]; then
        logger -t auto_hosts "配置文件不存在，跳过自动更新。"
        exit 0
    fi

    . "$CONFIG_FILE"
    if [ -z "$TARGET_DOMAIN" ] || [ -z "$LOCAL_ALIAS" ] || [ -z "$RECORD_TYPE" ]; then
        logger -t auto_hosts "配置不完整，跳过自动更新。"
        exit 1
    fi

    IP=$(resolve_ip "$TARGET_DOMAIN" "$RECORD_TYPE")
    if [ -z "$IP" ]; then
        logger -t auto_hosts "无法解析 $TARGET_DOMAIN，跳过更新。"
        exit 1
    fi

    update_hosts "$IP" "$LOCAL_ALIAS"
    reload_dns
    logger -t auto_hosts "自动更新完成: $TARGET_DOMAIN ($RECORD_TYPE) → $IP → $LOCAL_ALIAS"
}

# 主菜单
show_menu() {
    clear
    cat <<EOF
==========================================
  OpenWrt 优选域名本地解析管理工具
==========================================
  1. 优选域名本地解析
  2. 修改定时解析周期
  3. 取消定时解析任务
------------------------------------------
  当前配置文件: $CONFIG_FILE
EOF

    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE" 2>/dev/null
        echo "  优选域名: ${TARGET_DOMAIN:-无}"
        echo "  本地域名: ${LOCAL_ALIAS:-无}"
        echo "  解析类型:     ${RECORD_TYPE:-无}"
        # 尝试从 crontab 获取周期
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
    printf "请选择操作 (1/2/3): "
}

# === 主程序入口 ===

# 如果带有 --auto-update 参数，则执行自动更新（供 cron 调用）
if [ "$1" = "--auto-update" ]; then
    auto_update
    exit 0
fi

# 显示菜单并处理用户选择
while true; do
    show_menu
    read -r choice

    case "$choice" in
        1)
            # 重新设置解析任务
            printf "请输入要解析的优选域名 (例如: cdn.example.com): "
            read -r TARGET_DOMAIN
            [ -z "$TARGET_DOMAIN" ] && { log "❌ 域名不能为空。"; continue; }

            printf "请选择解析类型:\n  1) IPv4 (A 记录)\n  2) IPv6 (AAAA 记录)\n请选择 (1/2): "
            read -r rt_choice
            RECORD_TYPE="A"
            [ "$rt_choice" = "2" ] && RECORD_TYPE="AAAA"

            IP=$(resolve_ip "$TARGET_DOMAIN" "$RECORD_TYPE")
            if [ -z "$IP" ]; then
                log "❌ 无法解析 $TARGET_DOMAIN 的 $RECORD_TYPE 记录，请检查网络或域名。"
                continue
            fi

            log "🔍 解析成功: $TARGET_DOMAIN → $IP"

            # 后台 ping 触发缓存（可选）
            ping -c 1 -W 1 "$IP" >/dev/null 2>&1 &

            printf "请输入映射到该 IP 的本地域名 (例如: my.cdn): "
            read -r LOCAL_ALIAS
            [ -z "$LOCAL_ALIAS" ] && { log "❌ 本地域名不能为空。"; continue; }

            # 更新 hosts
            update_hosts "$IP" "$LOCAL_ALIAS"

            # 保存配置
            cat > "$CONFIG_FILE" <<EOF
TARGET_DOMAIN="$TARGET_DOMAIN"
RECORD_TYPE="$RECORD_TYPE"
LOCAL_ALIAS="$LOCAL_ALIAS"
EOF

            reload_dns

            # 默认设置每 3 小时
            set_cron 3

            log "✅ 域名解析配置已更新！"
            read -p "按回车返回主菜单..."
            ;;

        2)
            if [ ! -f "$CONFIG_FILE" ]; then
                log "⚠️  尚未设置域名解析任务，请先选择选项 1。"
                read -p "按回车返回..."
                continue
            fi

            printf "当前定时任务将被修改。\n请输入新的解析间隔（单位：小时，例如 1、2、6、12）: "
            read -r hours
            case "$hours" in
                ''|*[!0-9]*)
                    log "❌ 请输入有效的正整数。"
                    ;;
                *)
                    if [ "$hours" -lt 1 ]; then
                        log "❌ 间隔必须 ≥1 小时。"
                    else
                        set_cron "$hours"
                        read -p "按回车返回主菜单..."
                    fi
                    ;;
            esac
            ;;

        3)
            set_cron 0  # 0 表示清除
            read -p "按回车返回主菜单..."
            ;;

        *)
            log "❌ 无效选项，请输入 1、2 或 3。"
            read -p "按回车继续..."
            ;;
    esac
done
