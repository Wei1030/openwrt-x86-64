#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
CONF_DIR="/etc/xrayclient/conf.d"
SOCKS_PROXY_DIR="/etc/xrayclient/socks_proxy"
UCI_CONF="xrayclient"

mkdir -p "$CONF_DIR"

# 读取白名单直连代理端口
LOCAL_SOCKS_PORT=$(uci -q get ${UCI_CONF}.main.local_socks_port)
[ -z "$LOCAL_SOCKS_PORT" ] && LOCAL_SOCKS_PORT="10808"

# 读取国内域名 DNS (用于第二实例)
LOCAL_DNS_SERVER=$(uci -q get ${UCI_CONF}.main.local_dns_server)
LOCAL_DNS_PORT=$(uci -q get ${UCI_CONF}.main.local_dns_port)
[ -z "$LOCAL_DNS_SERVER" ] && LOCAL_DNS_SERVER="223.5.5.5"
[ -z "$LOCAL_DNS_PORT" ] && LOCAL_DNS_PORT="53"

echo "正在生成 Xray 配置文件到 $CONF_DIR ..."

# 1. 生成 00_default.json
cat << JSONEOF > "$CONF_DIR/00_default.json"
{
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "socks", "tag": "local_socks_server", "settings": { "address": "127.0.0.1", "port": ${LOCAL_SOCKS_PORT} } },
        { "tag": "blackhole", "protocol": "blackhole" },
        { "protocol": "dns", "tag": "query_internal_dns" }
    ],
    "log": {
        "access": "none", "error": "none", "loglevel": "warning", "dnsLog": false
    }
}
JSONEOF

# 2. 依次调用同目录下的子脚本生成 01 - 05
sh "$SCRIPT_DIR/gen_01_inbounds.sh"
sh "$SCRIPT_DIR/gen_02_dns.sh"
sh "$SCRIPT_DIR/gen_03_fakedns.sh"
sh "$SCRIPT_DIR/gen_04_routing.sh"
sh "$SCRIPT_DIR/gen_05_outbounds.sh"

# 3. 生成白名单直连代理实例配置 (第二 Xray 实例，仅在有白名单域名时生成)
WL_DOMAINS_RAW=$(uci -q show ${UCI_CONF}.main.whitelist_domain | sed "s/.*=//; s/'//g")
if [ -n "$WL_DOMAINS_RAW" ]; then
    mkdir -p "$SOCKS_PROXY_DIR"
    echo "正在生成白名单直连代理配置到 $SOCKS_PROXY_DIR ..."

    cat << JSONEOF > "$SOCKS_PROXY_DIR/config.json"
{
    "inbounds": [
        {
            "protocol": "socks",
            "tag": "socks_in",
            "listen": "127.0.0.1",
            "port": ${LOCAL_SOCKS_PORT},
            "settings": {
                "auth": "noauth",
                "udp": true
            }
        }
    ],
    "dns": {
        "servers": [
            { "address": "${LOCAL_DNS_SERVER}", "port": ${LOCAL_DNS_PORT} }
        ]
    },
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {
                "domainStrategy": "ForceIP"
            }
        }
    ],
    "log": {
        "access": "none", "error": "none", "loglevel": "warning", "dnsLog": false
    }
}
JSONEOF
else
    echo "无白名单域名，跳过生成第二实例配置。"
    rm -rf "$SOCKS_PROXY_DIR"
fi

echo "=================================="
echo "Xray 配置文件生成完毕！"
