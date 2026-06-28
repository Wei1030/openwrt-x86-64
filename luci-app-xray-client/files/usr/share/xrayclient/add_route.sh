#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

# 常量定义
UCI_CONF="xrayclient"
DEFAULT_FWMARK="22610"
DEFAULT_TABLE_V4_ID="82"
DEFAULT_TABLE_V4_NAME="xrayclient4"
DEFAULT_TABLE_V6_ID="88"
DEFAULT_TABLE_V6_NAME="xrayclient6"

# 确保 main section 存在
uci -q set $UCI_CONF.main=main

# 1. 从 UCI 读取配置，若无则使用默认值并写回 UCI
FWMARK=$(uci -q get $UCI_CONF.main.fwmark)
if [ -z "$FWMARK" ]; then
    FWMARK="$DEFAULT_FWMARK"
    uci set $UCI_CONF.main.fwmark="$FWMARK"
fi

TABLE_V4_ID=$(uci -q get $UCI_CONF.main.table_v4_id)
if [ -z "$TABLE_V4_ID" ]; then
    TABLE_V4_ID="$DEFAULT_TABLE_V4_ID"
    uci set $UCI_CONF.main.table_v4_id="$TABLE_V4_ID"
fi

TABLE_V4_NAME=$(uci -q get $UCI_CONF.main.table_v4_name)
if [ -z "$TABLE_V4_NAME" ]; then
    TABLE_V4_NAME="$DEFAULT_TABLE_V4_NAME"
    uci set $UCI_CONF.main.table_v4_name="$TABLE_V4_NAME"
fi

TABLE_V6_ID=$(uci -q get $UCI_CONF.main.table_v6_id)
if [ -z "$TABLE_V6_ID" ]; then
    TABLE_V6_ID="$DEFAULT_TABLE_V6_ID"
    uci set $UCI_CONF.main.table_v6_id="$TABLE_V6_ID"
fi

TABLE_V6_NAME=$(uci -q get $UCI_CONF.main.table_v6_name)
if [ -z "$TABLE_V6_NAME" ]; then
    TABLE_V6_NAME="$DEFAULT_TABLE_V6_NAME"
    uci set $UCI_CONF.main.table_v6_name="$TABLE_V6_NAME"
fi

uci commit $UCI_CONF

# 使用绝对路径定义卸载脚本路径
REMOVE_SCRIPT="$SCRIPT_DIR/remove_route.sh"

# ====================
# 预执行与初始化
# ====================
if [ -f "$REMOVE_SCRIPT" ]; then
    echo "检测到 $REMOVE_SCRIPT，正在执行卸载以清理历史修改..."
    sh "$REMOVE_SCRIPT"
fi

cat << 'EOF' > "$REMOVE_SCRIPT"
#!/bin/sh
# 自动生成的增量还原脚本，仅撤销对应安装脚本带来的新增修改
echo "开始还原增量修改..."
EOF
chmod +x "$REMOVE_SCRIPT"

# ====================
# 辅助函数
# ====================
add_remove_cmd() {
    local cmd="$1"
    if ! grep -qF "$cmd" "$REMOVE_SCRIPT"; then
        echo "$cmd" >> "$REMOVE_SCRIPT"
    fi
}

# ====================
# 核心配置函数
# ====================
setup_routing() {
    local family=$1
    local table_id=$2
    local table_name=$3
    local local_route=$4
    local ip_cmd="ip ${family}"
    local ver_name="IPv4"
    [ "$family" = "-6" ] && ver_name="IPv6"

    echo "正在检查 ${ver_name} 配置 (表: ${table_name}/${table_id}, fwmark: ${FWMARK})..."

    # 1. 检查 /etc/iproute2/rt_tables 冲突
    local existing_id_by_name=$(grep -E "^\s*[0-9]+\s+${table_name}\s*$" /etc/iproute2/rt_tables 2>/dev/null | awk '{print $1}')
    if [ -n "$existing_id_by_name" ] && [ "$existing_id_by_name" != "$table_id" ]; then
        echo "错误: 别名 '${table_name}' 已存在，但 ID 为 ${existing_id_by_name} (期望 ${table_id})。请修改 UCI 配置 ($UCI_CONF.main.table_v4_id/name) 后重试。"
        return 1
    fi

    local existing_name_by_id=$(grep -E "^\s*${table_id}\s+\S+\s*$" /etc/iproute2/rt_tables 2>/dev/null | awk '{print $2}')
    if [ -n "$existing_name_by_id" ] && [ "$existing_name_by_id" != "$table_name" ]; then
        echo "错误: ID '${table_id}' 已被别名 '${existing_name_by_id}' 占用。请修改 UCI 配置 ($UCI_CONF.main.table_v4_id/name) 后重试。"
        return 1
    fi

    if [ -z "$existing_id_by_name" ] && [ -z "$existing_name_by_id" ]; then
        echo "${table_id} ${table_name}" >> /etc/iproute2/rt_tables
        echo " -> 已追加路由表映射: ${table_id} ${table_name}"
        add_remove_cmd "sed -i '/${table_id}/ {/${table_name}/d}' /etc/iproute2/rt_tables 2>/dev/null"
    fi

    # 2. 检查 ip rule 冲突
    local existing_rule=$(${ip_cmd} rule show | grep "fwmark ${FWMARK}")
    if [ -n "$existing_rule" ]; then
        if echo "$existing_rule" | grep -q -E "lookup ${table_id}|lookup ${table_name}"; then
            echo " -> 策略规则已存在且配置正确，无需重复添加。"
        else
            echo "错误: fwmark ${FWMARK} 已被用于其他路由表！规则详情: ${existing_rule}"
            echo "请修改 UCI 配置 ($UCI_CONF.main.fwmark) 后重试。"
            return 1
        fi
    else
        ${ip_cmd} rule add fwmark ${FWMARK} table ${table_id}
        echo " -> 已添加策略规则: fwmark ${FWMARK} -> table ${table_id}"
        add_remove_cmd "${ip_cmd} rule del fwmark ${FWMARK} table ${table_id} 2>/dev/null"
    fi

    # 3. 检查 ip route 冲突
    local routes_in_table=$(${ip_cmd} route show table ${table_id} 2>/dev/null)
    if [ -n "$routes_in_table" ]; then
        local match_pattern="local (${local_route}|default) dev lo"
        if echo "$routes_in_table" | grep -qE "$match_pattern"; then
            echo " -> 本地路由已存在，无需重复添加。"
        else
            echo "错误: 路由表 ${table_id} 中已存在其他路由，无法添加 local 路由！"
            echo "现有路由: ${routes_in_table}"
            return 1
        fi
    else
        ${ip_cmd} route add local ${local_route} dev lo table ${table_id}
        echo " -> 已添加本地路由: local ${local_route} dev lo"
        add_remove_cmd "${ip_cmd} route del local ${local_route} dev lo table ${table_id} 2>/dev/null"
    fi

    return 0
}

# ====================
# 执行配置
# ====================
if ! setup_routing "-4" "$TABLE_V4_ID" "$TABLE_V4_NAME" "0.0.0.0/0"; then
    echo "IPv4 配置失败，终止脚本。"
    sh "$REMOVE_SCRIPT"
    exit 1
fi

if ! setup_routing "-6" "$TABLE_V6_ID" "$TABLE_V6_NAME" "::/0"; then
    echo "IPv6 配置失败，终止脚本。"
    sh "$REMOVE_SCRIPT"
    exit 1
fi

echo "echo '增量修改已还原完毕。'" >> "$REMOVE_SCRIPT"

echo "=================================="
echo "路由配置完成！"
