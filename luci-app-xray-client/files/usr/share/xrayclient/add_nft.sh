#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

# 常量定义
UCI_CONF="xrayclient"
REMOVE_SCRIPT="$SCRIPT_DIR/remove_nft.sh"

# 确保 main section 存在
uci -q set $UCI_CONF.main=main

# ====================
# 从 UCI 读取配置 (带默认值)
# ====================
NFT_TABLE_NAME=$(uci -q get ${UCI_CONF}.main.nft_table_name)
if [ -z "$NFT_TABLE_NAME" ]; then
    NFT_TABLE_NAME="xrayclient_tproxy"
    uci set ${UCI_CONF}.main.nft_table_name="$NFT_TABLE_NAME"
fi

# 从 UCI 读取接口名称列表
NFT_LAN_IFACES=$(uci -q show ${UCI_CONF}.main.nft_lan_iface 2>/dev/null | sed "s/.*=//; s/'//g")
if [ -z "$NFT_LAN_IFACES" ]; then
    NFT_LAN_IFACES="lan"
    uci add_list ${UCI_CONF}.main.nft_lan_iface='lan'
    uci commit ${UCI_CONF}
fi

# 通过 ubus 将 UCI 接口名转换为 l3_device 设备名
NFT_LAN_IFACE_SET=""
for iface in $NFT_LAN_IFACES; do
    dev=$(ubus call "network.interface.${iface}" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    if [ -n "$dev" ]; then
        NFT_LAN_IFACE_SET="${NFT_LAN_IFACE_SET}\"${dev}\", "
        echo " -> 接口 '${iface}' -> l3_device: '${dev}'"
    else
        echo "警告: 接口 '${iface}' 未找到 l3_device，跳过"
    fi
done

# 始终添加 "lo" 到集合中
NFT_LAN_IFACE_SET="${NFT_LAN_IFACE_SET}\"lo\""

# ====================
# 从 UCI 读取配置 (无默认值，必须存在)
# ====================
FWMARK=$(uci -q get ${UCI_CONF}.main.fwmark)
if [ -z "$FWMARK" ]; then
    echo "错误: 未在 UCI (${UCI_CONF}.main.fwmark) 中找到防火墙标记，请确保已执行 add_route.sh"
    exit 1
fi

XRAY_USR_GID=$(uci -q get ${UCI_CONF}.main.xray_usr_gid)
if [ -z "$XRAY_USR_GID" ]; then
    echo "错误: 未在 UCI (${UCI_CONF}.main.xray_usr_gid) 中找到 GID，请确保已执行 add_usr.sh"
    exit 1
fi

XRAY_TPROXY_PORT=$(uci -q get ${UCI_CONF}.main.tproxy_port)
if [ -z "$XRAY_TPROXY_PORT" ]; then
    echo "错误: 未在 UCI (${UCI_CONF}.main.tproxy_port) 中找到 tproxy 端口，请确保已执行 gen_01_inbounds.sh"
    exit 1
fi

FAKEIP_CIDR=$(uci -q get ${UCI_CONF}.main.fakeip_cidr)
if [ -z "$FAKEIP_CIDR" ]; then
    echo "错误: 未在 UCI (${UCI_CONF}.main.fakeip_cidr) 中找到 FakeIP 网段，请确保已执行 gen_03_fakedns.sh"
    exit 1
fi

# 读取代理服务器 IP (从 active_node 的 address 字段，仅 IPv4)
PROXY_SERVER_IP=""
ACTIVE_NODE=$(uci -q get ${UCI_CONF}.main.active_node)
if [ -n "$ACTIVE_NODE" ]; then
    PROXY_SERVER_IP=$(uci -q get ${UCI_CONF}.${ACTIVE_NODE}.address)
    if [ -n "$PROXY_SERVER_IP" ]; then
        if echo "$PROXY_SERVER_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo " -> 代理服务器 IP: $PROXY_SERVER_IP"
        else
            echo "警告: 代理服务器地址 '$PROXY_SERVER_IP' 不是 IPv4，跳过 nft 排除规则"
            PROXY_SERVER_IP=""
        fi
    fi
fi

# ====================
# 预执行与初始化
# ====================
if [ -f "$REMOVE_SCRIPT" ]; then
    echo "检测到 $REMOVE_SCRIPT，正在执行卸载以清理历史 nft 规则..."
    sh "$REMOVE_SCRIPT"
fi

cat << 'EOF' > "$REMOVE_SCRIPT"
#!/bin/sh
echo "开始还原 nftables 增量修改..."
EOF
chmod +x "$REMOVE_SCRIPT"

add_remove_cmd() {
    local cmd="$1"
    if ! grep -qF "$cmd" "$REMOVE_SCRIPT"; then
        echo "$cmd" >> "$REMOVE_SCRIPT"
    fi
}

# ====================
# 冲突预检查
# ====================
# 检查 nftables 表是否已存在
if nft list table inet "$NFT_TABLE_NAME" > /dev/null 2>&1; then
    echo "错误: nftables 表 '$NFT_TABLE_NAME' 已存在！"
    echo "这可能是系统其他服务占用的表名。请修改 UCI 配置 (${UCI_CONF}.main.nft_table_name) 后重试。"
    exit 1
fi

# ====================
# 从 UCI 解析白名单 IP
# ====================
parse_uci_ip_list() {
    local option=$1
    uci -q show ${UCI_CONF}.main.${option} | sed "s/.*=//; s/'//g" | awk '{for(i=1;i<=NF;i++) printf "%s%s", (NR>1||i>1?",":""), $i}'
}

WL_V4=$(parse_uci_ip_list "nft_whitelist_v4")
WL_V6=$(parse_uci_ip_list "nft_whitelist_v6")

# 将代理服务器 IP 追加到 IPv4 白名单列表末尾 (合并为一条规则)
if [ -n "$PROXY_SERVER_IP" ]; then
    if [ -n "$WL_V4" ]; then
        WL_V4="$WL_V4, $PROXY_SERVER_IP"
    else
        WL_V4="$PROXY_SERVER_IP"
    fi
fi

# 动态构建规则字符串
build_rule() {
    local proto=$1; local list=$2; local action=$3
    if [ -n "$list" ]; then
        echo "$proto daddr { $list } $action"
    fi
}

# ====================
# 加载中国 IP 列表 (如果存在)
# ====================
CN_V4_SET_DEF=""
CN_V4_SET_RULE=""
if [ -f "$SCRIPT_DIR/cn_v4.list" ] && [ -s "$SCRIPT_DIR/cn_v4.list" ]; then
    CN_V4_IP_ELEMENTS=$(awk '{printf "%s, ", $1}' "$SCRIPT_DIR/cn_v4.list" | sed 's/, $//')
    CN_V4_SET_DEF='set china_v4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { '"$CN_V4_IP_ELEMENTS"' }
    }'
    CN_V4_SET_RULE="ip daddr @china_v4 accept"
    echo "已加载中国 IPv4 列表 ($(wc -l < "$SCRIPT_DIR/cn_v4.list") 条)"
fi

CN_V6_SET_DEF=""
CN_V6_SET_RULE=""
if [ -f "$SCRIPT_DIR/cn_v6.list" ] && [ -s "$SCRIPT_DIR/cn_v6.list" ]; then
    CN_V6_IP_ELEMENTS=$(awk '{printf "%s, ", $1}' "$SCRIPT_DIR/cn_v6.list" | sed 's/, $//')
    CN_V6_SET_DEF='set china_v6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { '"$CN_V6_IP_ELEMENTS"' }
    }'
    CN_V6_SET_RULE="ip6 daddr @china_v6 accept"
    echo "已加载中国 IPv6 列表 ($(wc -l < "$SCRIPT_DIR/cn_v6.list") 条)"
fi

# ====================
# 生成并应用 nftables 规则
# ====================
echo "正在生成并应用 nftables 规则 (表: $NFT_TABLE_NAME)..."
nft -f - << EOF
table inet $NFT_TABLE_NAME {
    $CN_V4_SET_DEF
    $CN_V6_SET_DEF

    chain handle_mark {
        # 丢弃目标为本机 tproxy 端口的流量 (防止回环)
        th dport $XRAY_TPROXY_PORT fib daddr type local drop

        # 请求53端口的流量都打标，并返回原链继续
        th dport 53 meta mark set $FWMARK return
        # FakeIP网段都打标，并返回原链继续
        ip daddr $FAKEIP_CIDR meta mark set $FWMARK return

        # 放行本地/内网/保留地址
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } accept
        ip6 daddr { ::1, fc00::/7, fe80::/10, ff00::/8 } accept

        # 放行白名单 (含代理服务器 IP)
        $(build_rule "ip" "$WL_V4" "accept")
        $(build_rule "ip6" "$WL_V6" "accept")

        # 放行中国 IP
        $CN_V4_SET_RULE
        $CN_V6_SET_RULE

        # 剩余流量全部标记
        meta mark set $FWMARK return
    }

    # 内网请求自己或转发到外网、 外网请求自己或转发到内网、 自己请求自己（重路由进入）
    chain handle_tproxy {
        # 已标记流量直接 tproxy
        meta mark $FWMARK meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$XRAY_TPROXY_PORT accept
        meta mark $FWMARK meta l4proto { tcp, udp } tproxy ip6 to [::1]:$XRAY_TPROXY_PORT accept

        # 放行非用户指定接口以及非lo接口的流量 （外网请求靠用户的选择过滤）
        iifname != { $NFT_LAN_IFACE_SET } accept

        jump handle_mark

        # 已标记流量直接 tproxy
        meta mark $FWMARK meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$XRAY_TPROXY_PORT accept
        meta mark $FWMARK meta l4proto { tcp, udp } tproxy ip6 to [::1]:$XRAY_TPROXY_PORT accept
    }

    chain hook_prerouting {
        type filter hook prerouting priority filter; policy accept;

        # 仅处理 TCP/UDP
        meta l4proto != { tcp, udp } accept
        jump handle_tproxy
    }

    chain hook_output {
        type route hook output priority filter; policy accept;

        # 仅处理 TCP/UDP
        meta l4proto != { tcp, udp } accept

        # 放行本机特定进程发出的请求流量
        meta skgid $XRAY_USR_GID accept
        jump handle_mark
    }
}
EOF

if [ $? -ne 0 ]; then
    echo "错误: nftables 规则应用失败。"
    sh "$REMOVE_SCRIPT"
    exit 1
fi

add_remove_cmd "nft delete table inet $NFT_TABLE_NAME 2>/dev/null"
echo "echo 'nftables 增量修改已还原完毕。'" >> "$REMOVE_SCRIPT"

echo "=================================="
echo "nftables 配置完成！"
