#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
CONF_DIR="/etc/xrayclient/conf.d"

mkdir -p "$CONF_DIR"

echo "正在生成 Xray 配置文件到 $CONF_DIR ..."

# 1. 生成 00_default.json
cat << 'EOF' > "$CONF_DIR/00_default.json"
{
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "tag": "blackhole", "protocol": "blackhole" },
        { "protocol": "dns", "tag": "query_internal_dns" }
    ],
    "log": {
        "access": "none", "error": "none", "loglevel": "warning", "dnsLog": false
    }
}
EOF

# 2. 依次调用同目录下的子脚本生成 01 - 05
sh "$SCRIPT_DIR/gen_01_inbounds.sh"
sh "$SCRIPT_DIR/gen_02_dns.sh"
sh "$SCRIPT_DIR/gen_03_fakedns.sh"
sh "$SCRIPT_DIR/gen_04_routing.sh"
sh "$SCRIPT_DIR/gen_05_outbounds.sh"

echo "=================================="
echo "Xray 配置文件生成完毕！"
