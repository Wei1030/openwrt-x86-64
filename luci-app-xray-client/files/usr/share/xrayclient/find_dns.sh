#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

UCI_CONF="xrayclient"

# 默认值
FALLBACK_DNS_SERVER="223.5.5.5"
FALLBACK_DNS_PORT="53"
DEFAULT_RESOLV_FILE="/tmp/resolv.conf.d/resolv.conf.auto"

echo "开始检测国内域名 DNS..."

# 检查用户是否勾选了自定义国内域名 DNS
CUSTOM_DNS=$(uci -q get ${UCI_CONF}.main.custom_local_dns)
if [ "$CUSTOM_DNS" = "1" ]; then
    echo " -> 用户已自定义国内域名 DNS，跳过自动检测。"
    echo "=================================="
    echo "国内域名 DNS 检测完成。"
    exit 0
fi

# 从 dhcp UCI 配置读取 resolvfile 路径
RESOLV_FILE=$(uci -q get dhcp.@dnsmasq[0].resolvfile)
[ -z "$RESOLV_FILE" ] && RESOLV_FILE="$DEFAULT_RESOLV_FILE"

echo " -> resolvfile 路径: $RESOLV_FILE"

# 解析 resolvfile 中的 nameserver
DNS_SERVER=""
if [ -f "$RESOLV_FILE" ]; then
    # 取第一个 nameserver
    DNS_SERVER=$(grep -m1 '^nameserver' "$RESOLV_FILE" | awk '{print $2}')
fi

if [ -n "$DNS_SERVER" ]; then
    echo " -> 从 resolvfile 解析到 DNS: $DNS_SERVER"
    uci set ${UCI_CONF}.main.local_dns_server="$DNS_SERVER"
    uci set ${UCI_CONF}.main.local_dns_port="53"
else
    echo " -> 未能从 resolvfile 解析到 DNS，使用默认权威 DNS: $FALLBACK_DNS_SERVER"
    uci set ${UCI_CONF}.main.local_dns_server="$FALLBACK_DNS_SERVER"
    uci set ${UCI_CONF}.main.local_dns_port="$FALLBACK_DNS_PORT"
fi

uci -q commit ${UCI_CONF}
echo "=================================="
echo "国内域名 DNS 检测完成。"
