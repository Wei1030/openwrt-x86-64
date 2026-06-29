#!/bin/sh
CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

ACTIVE_NODE=$(uci -q get ${UCI_CONF}.main.active_node)

# 读取活动节点的协议类型 (从 protocol 字段)
NODE_TYPE=""
if [ -n "$ACTIVE_NODE" ]; then
    NODE_TYPE=$(uci -q get ${UCI_CONF}.${ACTIVE_NODE}.protocol)
fi

# ====================
# 通用函数: 构建传输方式 Settings JSON 片段
# 根据 network 类型生成对应的 xxxSettings
# ====================
gen_transport_settings() {
    local node=$1
    local net=$2
    local transport_json=""

    case "$net" in
        raw|tcp)
            transport_json=""
            ;;
        ws|websocket)
            local ws_path=$(uci -q get ${UCI_CONF}.${node}.ws_path)
            local ws_host=$(uci -q get ${UCI_CONF}.${node}.ws_host)
            local ws_heartbeat=$(uci -q get ${UCI_CONF}.${node}.ws_heartbeat)
            local inner="\"path\": \"${ws_path:-/}\""
            [ -n "$ws_host" ] && inner="${inner}, \"host\": \"${ws_host}\""
            [ -n "$ws_heartbeat" ] && inner="${inner}, \"heartbeatPeriod\": ${ws_heartbeat}"
            transport_json="\"wsSettings\": { ${inner} }"
            ;;
        grpc)
            local grpc_svc=$(uci -q get ${UCI_CONF}.${node}.grpc_serviceName)
            local grpc_auth=$(uci -q get ${UCI_CONF}.${node}.grpc_authority)
            local grpc_multi=$(uci -q get ${UCI_CONF}.${node}.grpc_multiMode)
            local inner=""
            [ -n "$grpc_svc" ] && inner="\"serviceName\": \"${grpc_svc}\""
            [ -n "$grpc_auth" ] && inner="${inner:+${inner}, }\"authority\": \"${grpc_auth}\""
            if [ "$grpc_multi" = "1" ]; then
                inner="${inner:+${inner}, }\"multiMode\": true"
            fi
            [ -n "$inner" ] && transport_json="\"grpcSettings\": { ${inner} }"
            ;;
        mkcp)
            local kcp_mtu=$(uci -q get ${UCI_CONF}.${node}.kcp_mtu)
            local kcp_tti=$(uci -q get ${UCI_CONF}.${node}.kcp_tti)
            local kcp_up=$(uci -q get ${UCI_CONF}.${node}.kcp_uplinkCapacity)
            local kcp_down=$(uci -q get ${UCI_CONF}.${node}.kcp_downlinkCapacity)
            local kcp_cong=$(uci -q get ${UCI_CONF}.${node}.kcp_congestion)
            local inner=""
            [ -n "$kcp_mtu" ] && inner="\"mtu\": ${kcp_mtu}"
            [ -n "$kcp_tti" ] && inner="${inner:+${inner}, }\"tti\": ${kcp_tti}"
            [ -n "$kcp_up" ] && inner="${inner:+${inner}, }\"uplinkCapacity\": ${kcp_up}"
            [ -n "$kcp_down" ] && inner="${inner:+${inner}, }\"downlinkCapacity\": ${kcp_down}"
            if [ "$kcp_cong" = "1" ]; then
                inner="${inner:+${inner}, }\"congestion\": true"
            fi
            [ -n "$inner" ] && transport_json="\"kcpSettings\": { ${inner} }"
            ;;
        httpupgrade)
            local hu_path=$(uci -q get ${UCI_CONF}.${node}.hu_path)
            local hu_host=$(uci -q get ${UCI_CONF}.${node}.hu_host)
            local inner="\"path\": \"${hu_path:-/}\""
            [ -n "$hu_host" ] && inner="${inner}, \"host\": \"${hu_host}\""
            transport_json="\"httpupgradeSettings\": { ${inner} }"
            ;;
        xhttp)
            # XHTTP 文档指向外部讨论，基本配置含 path/host
            local xh_path=$(uci -q get ${UCI_CONF}.${node}.xh_path)
            local xh_host=$(uci -q get ${UCI_CONF}.${node}.xh_host)
            local xh_mode=$(uci -q get ${UCI_CONF}.${node}.xh_mode)
            local inner=""
            [ -n "$xh_path" ] && inner="\"path\": \"${xh_path}\""
            [ -n "$xh_host" ] && inner="${inner:+${inner}, }\"host\": \"${xh_host}\""
            [ -n "$xh_mode" ] && inner="${inner:+${inner}, }\"mode\": \"${xh_mode}\""
            [ -n "$inner" ] && transport_json="\"xhttpSettings\": { ${inner} }"
            ;;
    esac

    echo "$transport_json"
}

# ====================
# 通用函数: 构建 sockopt JSON 片段
# ====================
gen_sockopt() {
    local node=$1
    local tcp_cong=$(uci -q get ${UCI_CONF}.${node}.tcpcongestion)
    if [ -n "$tcp_cong" ]; then
        echo "\"sockopt\": { \"tcpcongestion\": \"${tcp_cong}\" }"
    fi
}

# ====================
# 通用函数: 构建 streamSettings JSON
# 调用 gen_transport_settings 和 gen_sockopt
# ====================
gen_stream_settings() {
    local node=$1
    local net=$2
    local sec=$3

    # 传输方式 settings
    local transport_json=$(gen_transport_settings "$node" "$net")

    # 安全 settings
    local sec_json=""
    case "$sec" in
        reality)
            local sn=$(uci -q get ${UCI_CONF}.${node}.serverName)
            local fp=$(uci -q get ${UCI_CONF}.${node}.fingerprint)
            local pwd=$(uci -q get ${UCI_CONF}.${node}.password)
            local sid=$(uci -q get ${UCI_CONF}.${node}.shortId)
            local mld=$(uci -q get ${UCI_CONF}.${node}.mldsa65Verify)
            local spx=$(uci -q get ${UCI_CONF}.${node}.spiderX)
            sec_json="\"realitySettings\": {
                \"serverName\": \"${sn}\", \"fingerprint\": \"${fp}\",
                \"password\": \"${pwd}\", \"shortId\": \"${sid}\",
                \"mldsa65Verify\": \"${mld}\", \"spiderX\": \"${spx}\"
            }"
            ;;
        tls)
            local sn=$(uci -q get ${UCI_CONF}.${node}.serverName)
            local fp=$(uci -q get ${UCI_CONF}.${node}.fingerprint)
            local allow_insecure=$(uci -q get ${UCI_CONF}.${node}.allow_insecure)
            local ai="false"
            [ "$allow_insecure" = "1" ] && ai="true"
            sec_json="\"tlsSettings\": {
                \"serverName\": \"${sn}\", \"fingerprint\": \"${fp}\",
                \"allowInsecure\": ${ai}
            }"
            ;;
    esac

    # sockopt
    local sockopt_json=$(gen_sockopt "$node")

    # 组装
    local parts="\"network\": \"${net}\", \"security\": \"${sec}\""
    [ -n "$transport_json" ] && parts="${parts}, ${transport_json}"
    [ -n "$sec_json" ] && parts="${parts}, ${sec_json}"
    [ -n "$sockopt_json" ] && parts="${parts}, ${sockopt_json}"

    echo "\"streamSettings\": { ${parts} }"
}

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

    [ -z "$enc" ] && enc="none"
    [ -z "$lvl" ] && lvl=0
    [ -z "$sec" ] && sec="none"
    [ -z "$net" ] && net="raw"

    local stream_json=$(gen_stream_settings "$node" "$net" "$sec")

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
