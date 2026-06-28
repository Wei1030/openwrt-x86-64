#!/bin/sh
CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

LOCAL_DNS_SERVER=$(uci -q get ${UCI_CONF}.main.local_dns_server)
LOCAL_DNS_PORT=$(uci -q get ${UCI_CONF}.main.local_dns_port)
[ -z "$LOCAL_DNS_SERVER" ] && LOCAL_DNS_SERVER="127.0.0.1"
[ -z "$LOCAL_DNS_PORT" ] && LOCAL_DNS_PORT="22653"

# 读取黑白名单
WL_DOMAINS=$(uci -q show ${UCI_CONF}.main.whitelist_domain | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')
BL_DOMAINS=$(uci -q show ${UCI_CONF}.main.blacklist_domain | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')

ALL_BL_WL_DOMAINS=""
if [ -n "$WL_DOMAINS" ] || [ -n "$BL_DOMAINS" ]; then
    ALL_BL_WL_DOMAINS=$(echo "$WL_DOMAINS,$BL_DOMAINS" | sed 's/^,//; s/,$//')
fi

# ====================
# 动态生成 hosts (广告屏蔽) 块
# ====================
BLOCK_AD=$(uci -q get ${UCI_CONF}.main.block_ad)
HOSTS_BLOCK=""

if [ "$BLOCK_AD" = "1" ]; then
    BLOCK_DOMAINS=$(uci -q show ${UCI_CONF}.main.block_domain | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) print $i}')
    
    if [ -n "$BLOCK_DOMAINS" ]; then
        HOSTS_ITEMS=""
        for domain in $BLOCK_DOMAINS; do
            [ -z "$domain" ] && continue
            if [ -z "$HOSTS_ITEMS" ]; then
                # 第一项前面不加逗号
                HOSTS_ITEMS="            \"${domain}\": [ \"127.127.127.127\", \"100::6c62:636f:656b:2164\" ]"
            else
                # 后续项在前面加逗号和换行
                HOSTS_ITEMS="${HOSTS_ITEMS},\n            \"${domain}\": [ \"127.127.127.127\", \"100::6c62:636f:656b:2164\" ]"
            fi
        done
        
        # 闭合 hosts 大括号，末尾带逗号连接下面的 servers（这个逗号是必须的）
        HOSTS_BLOCK="        \"hosts\": {\n$HOSTS_ITEMS\n        },"
    fi
fi

# ====================
# 动态生成 remote_dns 数组
# 遍历所有 remote_dns section，读取 address 和 port
# 修复：port 现在会正确输出到 JSON 中
# ====================
REMOTE_DNS_JSON=""
for section in $(uci -q show ${UCI_CONF} | grep '=remote_dns' | cut -d. -f2 | cut -d= -f1); do
    addr=$(uci -q get ${UCI_CONF}.${section}.address)
    port=$(uci -q get ${UCI_CONF}.${section}.port)
    [ -z "$addr" ] && continue
    [ -z "$port" ] && port="53"
    REMOTE_DNS_JSON="${REMOTE_DNS_JSON}            { \"address\": \"${addr}\", \"port\": ${port}, \"expectedIPs\": [ \"geoip:!cn\" ], \"queryStrategy\": \"UseIPv4\" },"
done

FAKEDNS_BLOCK=""
if [ -n "$ALL_BL_WL_DOMAINS" ]; then
    FAKEDNS_BLOCK="            { \"address\": \"fakedns\", \"domains\": [ $ALL_BL_WL_DOMAINS ], \"queryStrategy\": \"UseIPv4\", \"skipFallback\": true, \"finalQuery\": true },"
fi

# 读取尝试使用国内DNS解析的额外域名
CN_DNS_DOMAINS=$(uci -q show ${UCI_CONF}.main.cn_dns_domains | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')

# 构建完整的国内域名数组 (默认3个 + 用户自定义)
CN_DOMAIN_LIST="\"geosite:cn\", \"geosite:apple\", \"geosite:microsoft\""
if [ -n "$CN_DNS_DOMAINS" ]; then
    CN_DOMAIN_LIST="${CN_DOMAIN_LIST}, ${CN_DNS_DOMAINS}"
fi

# 读取使用 FakeIP 的额外域名 (默认已包含 geosite:google)
FAKEIP_DOMAINS=$(uci -q show ${UCI_CONF}.main.fakeip_domains | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//')

# 构建 FakeIP 域名数组 (默认 geosite:google + 用户自定义)
FAKEIP_DOMAIN_LIST="\"geosite:google\""
if [ -n "$FAKEIP_DOMAINS" ]; then
    FAKEIP_DOMAIN_LIST="${FAKEIP_DOMAIN_LIST}, ${FAKEIP_DOMAINS}"
fi

# 使用 printf 解析换行符 \n，再用 cat 写入文件
printf "{\n    \"dns\": {\n$HOSTS_BLOCK\n" > "$CONF_DIR/02_dns.json"

cat << JSONEOF >> "$CONF_DIR/02_dns.json"
        "servers": [
$FAKEDNS_BLOCK
            { "address": "fakedns", "domains": [ ${FAKEIP_DOMAIN_LIST} ], "queryStrategy": "UseIPv4", "skipFallback": true, "finalQuery": true },
            { "address": "${LOCAL_DNS_SERVER}", "port": ${LOCAL_DNS_PORT}, "domains": [ ${CN_DOMAIN_LIST} ], "expectedIPs": [ "geoip:cn" ], "tag": "dns_query_direct", "skipFallback": true },
            { "address": "fakedns", "domains": [ ${CN_DOMAIN_LIST} ], "queryStrategy": "UseIPv4", "skipFallback": true, "finalQuery": true },
$REMOTE_DNS_JSON
            { "address": "fakedns", "queryStrategy": "UseIPv4" }
        ],
        "tag": "dns_query", "disableFallbackIfMatch": true, "enableParallelQuery": true
    }
}
JSONEOF
