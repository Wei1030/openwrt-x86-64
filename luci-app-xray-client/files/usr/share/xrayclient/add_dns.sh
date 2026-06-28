#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

# 常量定义
DNS_USR_NAME="dnsmasq"
UCI_CONF="xrayclient"
DEFAULT_DNS_NAME="DNSForXrayClient"
DEFAULT_DNS_PORT="22653"
FALLBACK_DNS_SERVER="223.5.5.5"
FALLBACK_DNS_PORT="53"
DEFAULT_DNS_GID="453"

# 降级处理: 将国内域名 DNS 设为外部权威 DNS 并退出 (不生成 remove_dns.sh)
fallback_to_external_dns() {
    echo " -> 将国内域名 DNS 设为外部权威 DNS: $FALLBACK_DNS_SERVER:$FALLBACK_DNS_PORT"
    uci set $UCI_CONF.main.local_dns_server="$FALLBACK_DNS_SERVER"
    uci set $UCI_CONF.main.local_dns_port="$FALLBACK_DNS_PORT"
    uci set $UCI_CONF.main.dns_gid="$DEFAULT_DNS_GID"
    uci commit $UCI_CONF
    echo "=================================="
    echo "Xray 专用 DNS 实例配置完成（降级为外部 DNS 模式）。"
    exit 0
}

echo "开始配置 Xray 专用 DNS 实例..."

# 确保 main section 存在
uci -q set $UCI_CONF.main=main

# 1. 从 UCI 读取实例名称和端口，若无则使用默认值并写回 UCI
NEW_DNS_NAME=$(uci -q get $UCI_CONF.main.dns_name)
if [ -z "$NEW_DNS_NAME" ]; then
    NEW_DNS_NAME="$DEFAULT_DNS_NAME"
    uci set $UCI_CONF.main.dns_name="$NEW_DNS_NAME"
fi

NEW_DNS_PORT=$(uci -q get $UCI_CONF.main.dns_port)
if [ -z "$NEW_DNS_PORT" ]; then
    NEW_DNS_PORT="$DEFAULT_DNS_PORT"
    uci set $UCI_CONF.main.dns_port="$NEW_DNS_PORT"
fi
uci commit $UCI_CONF

echo " -> 使用实例名称: $NEW_DNS_NAME"
echo " -> 使用监听端口: $NEW_DNS_PORT"

# 2. 检查同名实例是否已存在
EXISTING_SECTION=$(uci -q get dhcp.$NEW_DNS_NAME)
if [ -n "$EXISTING_SECTION" ] && [ "$EXISTING_SECTION" = "dnsmasq" ]; then
    echo "提示: 系统中已存在名为 '$NEW_DNS_NAME' 的 dnsmasq 实例，无法重复创建。"
    fallback_to_external_dns
fi

# 3. 检查端口与现有 dnsmasq 实例冲突
echo "正在检查现有 dnsmasq 实例端口冲突..."
SECTIONS=$(uci show dhcp | awk -F'[.=]' '/=dnsmasq$/{print $2}')

for sec in $SECTIONS; do
    port=$(uci -q get dhcp.$sec.port)
    [ -z "$port" ] && port=53
    
    if [ "$port" = "$NEW_DNS_PORT" ]; then
        echo "提示: 端口 '$NEW_DNS_PORT' 与现有实例 '$sec' 冲突，无法使用。"
        fallback_to_external_dns
    fi
done
echo " -> 端口 '$NEW_DNS_PORT' 无冲突。"

# 4. 获取 dnsmasq 用户 GID (找不到则降级为外部 DNS)
echo "正在获取 dnsmasq 用户 GID..."
DNS_GID=$(awk -F: -v user="$DNS_USR_NAME" '$1 == user {print $3}' /etc/group | head -n 1)
if [ -z "$DNS_GID" ] || [ "$DNS_GID" -eq 0 ]; then
    echo "提示: 未找到用户 '$DNS_USR_NAME' 或其 GID 为 0，无法继续创建实例。"
    fallback_to_external_dns
else
    echo " -> 找到 dnsmasq GID: $DNS_GID"
fi

# 5. 创建新的 dnsmasq 实例
echo "正在创建新的 dnsmasq 实例 '$NEW_DNS_NAME'..."
uci set dhcp.$NEW_DNS_NAME=dnsmasq
uci set dhcp.$NEW_DNS_NAME.port="$NEW_DNS_PORT"
uci set dhcp.$NEW_DNS_NAME.domainneeded='1'
uci set dhcp.$NEW_DNS_NAME.rebind_protection='1'
uci set dhcp.$NEW_DNS_NAME.rebind_localhost='1'
uci set dhcp.$NEW_DNS_NAME.localservice='1'
uci set dhcp.$NEW_DNS_NAME.localise_queries='1'
uci commit dhcp
echo " -> 实例创建并提交成功。"

# 6. 将获取到的 GID 写回 UCI 配置文件中供其他脚本使用
echo "正在将 GID 写入 UCI ($UCI_CONF)..."
uci set $UCI_CONF.main.dns_gid="$DNS_GID"
uci commit $UCI_CONF
echo " -> UCI 配置已更新。"

# 7. 重启 dnsmasq 使新实例生效
echo "正在重启 dnsmasq..."
/etc/init.d/dnsmasq restart >/dev/null 2>&1
echo " -> dnsmasq 已重启。"

# 8. 生成对应的 remove_dns.sh 脚本 (含 dnsmasq 重启)
echo "正在生成卸载脚本 remove_dns.sh..."
cat > "$SCRIPT_DIR/remove_dns.sh" << EOF
#!/bin/sh
UCI_CONF="xrayclient"
NEW_DNS_NAME=\$(uci -q get \$UCI_CONF.main.dns_name)

if [ -z "\$NEW_DNS_NAME" ]; then
    NEW_DNS_NAME="DNSForXray"
fi

echo "正在移除 dnsmasq 实例 '\$NEW_DNS_NAME'..."
uci del dhcp.\$NEW_DNS_NAME
uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1
echo " -> 实例已移除，dnsmasq 已重启。"
EOF
chmod +x "$SCRIPT_DIR/remove_dns.sh"

echo "=================================="
echo "Xray 专用 DNS 实例配置完成！"
