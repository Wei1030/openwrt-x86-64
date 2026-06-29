#!/bin/sh
CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

ACTIVE_NODE=$(uci -q get ${UCI_CONF}.main.active_node)

# 读取活动节点的协议类型 (从 protocol 字段)
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
    local mld=$(uci -q get ${UCI_CONF}.${node}.mldsa65Verify)
    local spx=$(uci -q get ${UCI_CONF}.${node}.spiderX)
    local allow_insecure=$(uci -q get ${UCI_CONF}.${node}.allow_insecure)

    [ -z "$enc" ] && enc="none"
    [ -z "$lvl" ] && lvl=0
    [ -z "$sec" ] && sec="none"
    [ -z "$net" ] && net="raw"

    # 构建 securitySettings JSON 片段
    local sec_json=""
    case "$sec" in
        reality)
            sec_json="\"realitySettings\": {
                \"serverName\": \"${sn}\", \"fingerprint\": \"${fp}\",
                \"password\": \"${pwd}\", \"shortId\": \"${sid}\",
                \"mldsa65Verify\": \"${mld}\", \"spiderX\": \"${spx}\"
            }"
            ;;
        tls)
            local ai="false"
            [ "$allow_insecure" = "1" ] && ai="true"
            sec_json="\"tlsSettings\": {
                \"serverName\": \"${sn}\", \"fingerprint\": \"${fp}\",
                \"allowInsecure\": ${ai}
            }"
            ;;
        none)
            sec_json=""
            ;;
    esac

    # 组装 streamSettings
    local stream_json=""
    if [ -n "$sec_json" ]; then
        stream_json="\"streamSettings\": {
            \"network\": \"${net}\", \"security\": \"${sec}\",
            ${sec_json}
        }"
    else
        stream_json="\"streamSettings\": {
            \"network\": \"${net}\", \"security\": \"none\"
        }"
    fi

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
