#!/bin/sh
CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

ACTIVE_NODE=$(uci -q get ${UCI_CONF}.main.active_node)

# 检查 active_node 是否存在且是 node 类型
NODE_TYPE=""
if [ -n "$ACTIVE_NODE" ]; then
    NODE_TYPE=$(uci -q get ${UCI_CONF}.${ACTIVE_NODE}.protocol)
fi

gen_vless() {
    local node=$1
    local addr=$(uci -q get ${UCI_CONF}.${node}.address)
    local port=$(uci -q get ${UCI_CONF}.${node}.port)
    local id=$(uci -q get ${UCI_CONF}.${node}.id)
    local enc=$(uci -q get ${UCI_CONF}.${node}.encryption)
    local flow=$(uci -q get ${UCI_CONF}.${node}.flow)
    local lvl=$(uci -q get ${UCI_CONF}.${node}.level)
    local net=$(uci -q get ${UCI_CONF}.${node}.network)
    local sec=$(uci -q get ${UCI_CONF}.${node}.security)
    local sn=$(uci -q get ${UCI_CONF}.${node}.serverName)
    local fp=$(uci -q get ${UCI_CONF}.${node}.fingerprint)
    local pwd=$(uci -q get ${UCI_CONF}.${node}.password)
    local sid=$(uci -q get ${UCI_CONF}.${node}.shortId)
    local sp=$(uci -q get ${UCI_CONF}.${node}.spiderX)
    local path=$(uci -q get ${UCI_CONF}.${node}.path)
    local host=$(uci -q get ${UCI_CONF}.${node}.host)
    local sni=$(uci -q get ${UCI_CONF}.${node}.sni)

    # 默认值
    [ -z "$enc" ] && enc="none"
    [ -z "$flow" ] && flow=""
    [ -z "$lvl" ] && lvl=0
    [ -z "$net" ] && net="raw"
    [ -z "$sec" ] && sec="none"

    # 构造 streamSettings
    STREAM_JSON=""
    case "$net" in
        raw|tcp)
            NET_OUTER='"tcpSettings": {}'
            ;;
        ws)
            WS_PATH="${path:-/}"
            WS_HOST="${host:-$addr}"
            NET_OUTER="{ \"wsSettings\": { \"path\": \"${WS_PATH}\", \"headers\": { \"Host\": \"${WS_HOST}\" } } }"
            ;;
        grpc)
            GRPC_SN="${sn:-}"
            NET_OUTER="{ \"grpcSettings\": { \"serviceName\": \"${GRPC_SN}\" } }"
            ;;
        mkcp)
            NET_OUTER='"kcpSettings": {}'
            ;;
        httpupgrade)
            HU_PATH="${path:-/}"
            HU_HOST="${host:-$addr}"
            NET_OUTER="{ \"httpupgradeSettings\": { \"path\": \"${HU_PATH}\", \"host\": \"${HU_HOST}\" } }"
            ;;
        xhttp)
            XH_PATH="${path:-/}"
            XH_HOST="${host:-$addr}"
            NET_OUTER="{ \"xhttpSettings\": { \"path\": \"${XH_PATH}\", \"host\": \"${XH_HOST}\" } }"
            ;;
        *)
            NET_OUTER='"tcpSettings": {}'
            ;;
    esac

    # 构造 security
    SEC_JSON='"none"'
    case "$sec" in
        none)
            SEC_JSON='"none"'
            ;;
        tls)
            TLS_SN="${sn:-$sni}"
            TLS_FP="${fp:-}"
            if [ -n "$TLS_FP" ]; then
                SEC_JSON="{ \"tls\": { \"serverName\": \"${TLS_SN}\", \"fingerprint\": \"${TLS_FP}\" } }"
            else
                SEC_JSON="{ \"tls\": { \"serverName\": \"${TLS_SN}\" } }"
            fi
            ;;
        reality)
            R_SN="${sn:-$sni}"
            R_FP="${fp:-}"
            R_PWD="${pwd:-}"
            R_SID="${sid:-}"
            R_SP="${sp:-}"
            REALITY_INNER="{ \"serverName\": \"${R_SN}\", \"fingerprint\": \"${R_FP}\", \"publicKey\": \"${R_PWD}\", \"shortId\": \"${R_SID}\" }"
            if [ -n "$R_SP" ]; then
                REALITY_INNER=$(echo "$REALITY_INNER" | sed 's/}$/,"spiderX":"'"$R_SP"'"}/')
            fi
            SEC_JSON="{ \"reality\": ${REALITY_INNER} }"
            ;;
    esac

    stream_json="\"streamSettings\": { \"network\": \"${net}\", ${NET_OUTER}, \"security\": ${SEC_JSON} }"

    cat << JSONEOF
{
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "address": "${addr}", "port": ${port}, "id": "${id}",
                "encryption": "${enc}", "flow": "${flow}", "level": ${lvl}
            },
            "tag": "proxy",
            ${stream_json}
        }
    ]
}
JSONEOF
}

case "$NODE_TYPE" in
    vless)
        gen_vless "$ACTIVE_NODE" > "$CONF_DIR/05_outbounds_tail.json"
        ;;
    "")
        echo "{ \"error\": \"未配置代理节点\" }" > "$CONF_DIR/05_outbounds_tail.json"
        if [ -z "$ACTIVE_NODE" ]; then
            echo "警告: 未配置代理节点 (active_node 为空)，请在 LuCI 页面选择节点后再启动服务。"
        else
            echo "警告: 活动节点 '${ACTIVE_NODE}' 不存在或未配置协议，请在 LuCI 页面重新选择节点。"
        fi
        ;;
    *)
        echo "{ \"error\": \"未知协议类型 '$NODE_TYPE'\" }" > "$CONF_DIR/05_outbounds_tail.json"
        echo "警告: 未知协议类型 '$NODE_TYPE'"
        ;;
esac
