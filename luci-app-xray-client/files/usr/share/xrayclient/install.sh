#!/bin/sh

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
CONF_DIR="/etc/xrayclient/conf.d"

# 错误时触发回滚
rollback_and_exit() {
    echo "错误: $1 执行失败，正在执行回滚清理..."
    if [ -f "$SCRIPT_DIR/uninstall.sh" ]; then
        sh "$SCRIPT_DIR/uninstall.sh" > /dev/null 2>&1
    fi
    echo "安装失败，已回滚。"
    exit 1
}

echo "开始安装 Xray client..."

# 预创建目录
mkdir -p /etc/xrayclient "$CONF_DIR"

echo "步骤 1: 配置定时更新任务..."
mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i '/# xrayclient-update-ip\|# xrayclient-update-dat/d' /etc/crontabs/root 2>/dev/null

# --- IP 类更新调度 (cn_v4 + cn_v6 + geoip) ---
IP_INTERVAL=$(uci -q get xrayclient.main.ip_update_interval)
[ -z "$IP_INTERVAL" ] && IP_INTERVAL="weekly"
IP_HOUR=$(uci -q get xrayclient.main.ip_update_hour)
[ -z "$IP_HOUR" ] && IP_HOUR="4"
IP_DOW=$(uci -q get xrayclient.main.ip_update_dow)
[ -z "$IP_DOW" ] && IP_DOW="5"

case "$IP_INTERVAL" in
    daily)
        echo "0 ${IP_HOUR} * * * sh /usr/share/xrayclient/update_data.sh ip # xrayclient-update-ip" >> /etc/crontabs/root
        ;;
    every3d)
        echo "0 ${IP_HOUR} */3 * * sh /usr/share/xrayclient/update_data.sh ip # xrayclient-update-ip" >> /etc/crontabs/root
        ;;
    weekly)
        echo "0 ${IP_HOUR} * * ${IP_DOW} sh /usr/share/xrayclient/update_data.sh ip # xrayclient-update-ip" >> /etc/crontabs/root
        ;;
    never)
        ;;
esac

# --- 域名类更新调度 (geosite) ---
DAT_INTERVAL=$(uci -q get xrayclient.main.dat_update_interval)
[ -z "$DAT_INTERVAL" ] && DAT_INTERVAL="every3d"
DAT_HOUR=$(uci -q get xrayclient.main.dat_update_hour)
[ -z "$DAT_HOUR" ] && DAT_HOUR="4"
DAT_DOW=$(uci -q get xrayclient.main.dat_update_dow)
[ -z "$DAT_DOW" ] && DAT_DOW="1"

case "$DAT_INTERVAL" in
    daily)
        echo "0 ${DAT_HOUR} * * * sh /usr/share/xrayclient/update_data.sh dat # xrayclient-update-dat" >> /etc/crontabs/root
        ;;
    every3d)
        echo "0 ${DAT_HOUR} */3 * * sh /usr/share/xrayclient/update_data.sh dat # xrayclient-update-dat" >> /etc/crontabs/root
        ;;
    weekly)
        echo "0 ${DAT_HOUR} * * ${DAT_DOW} sh /usr/share/xrayclient/update_data.sh dat # xrayclient-update-dat" >> /etc/crontabs/root
        ;;
    never)
        ;;
esac

/etc/init.d/cron enable 2>/dev/null
/etc/init.d/cron restart 2>/dev/null

echo "步骤 2: 配置用户..."
sh "$SCRIPT_DIR/add_usr.sh" || rollback_and_exit "add_usr.sh"

echo "步骤 3: 配置 DNS 实例..."
sh "$SCRIPT_DIR/add_dns.sh" || rollback_and_exit "add_dns.sh"

echo "步骤 4: 启用开机自启..."
/etc/init.d/xrayclient enable

echo "=================================="
echo "Xray client 安装完成！"
echo "使用 /etc/init.d/xrayclient start|stop|restart 管理服务"
