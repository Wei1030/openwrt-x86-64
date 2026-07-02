#!/bin/sh
CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

# 修复：同样使用 awk 循环分割
WL_DOMAINS=$(uci -q show ${UCI_CONF}.main.whitelist_domain | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')
BL_DOMAINS=$(uci -q show ${UCI_CONF}.main.blacklist_domain | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')
BL_IPS=$(uci -q show ${UCI_CONF}.main.blacklist_ip | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')

WL_RULE=""
if [ -n "$WL_DOMAINS" ]; then
    WL_RULE="            { \"domain\": [ $WL_DOMAINS ], \"outboundTag\": \"local_socks_server\" },"
fi

# 读取使用 FakeIP 的额外域名 (插入到 geosite:google 之后)
FAKEIP_DOMAINS=$(uci -q show ${UCI_CONF}.main.fakeip_domains | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')

BL_DOMAIN_STR="\"geosite:google\""
if [ -n "$FAKEIP_DOMAINS" ]; then BL_DOMAIN_STR="${BL_DOMAIN_STR}, ${FAKEIP_DOMAINS}"; fi
BL_DOMAIN_STR="${BL_DOMAIN_STR}, \"geosite:cn\", \"geosite:apple\", \"geosite:microsoft\""

# 追加尝试使用国内DNS解析的额外域名
CN_DNS_DOMAINS=$(uci -q show ${UCI_CONF}.main.cn_dns_domains | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')
if [ -n "$CN_DNS_DOMAINS" ]; then BL_DOMAIN_STR="${BL_DOMAIN_STR}, ${CN_DNS_DOMAINS}"; fi
if [ -n "$BL_DOMAINS" ]; then BL_DOMAIN_STR="${BL_DOMAIN_STR}, $BL_DOMAINS"; fi

BL_IP_STR="\"geoip:!cn\""
if [ -n "$BL_IPS" ]; then BL_IP_STR="${BL_IP_STR}, $BL_IPS"; fi

cat << JSONEOF > "$CONF_DIR/04_routing.json"
{
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
$WL_RULE
            { "inboundTag": [ "dns_query_direct" ], "outboundTag": "direct" },
            { "inboundTag": [ "dns_query" ], "outboundTag": "proxy" },
            { "port": 53, "outboundTag": "query_internal_dns" },
            { "domain": [ $BL_DOMAIN_STR ], "outboundTag": "proxy" },
            { "ip": [ "geoip:private" ], "outboundTag": "direct" },
            { "ip": [ $BL_IP_STR ], "outboundTag": "proxy" }
        ]
    }
}
JSONEOF
