#!/bin/sh

CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

# 确保 main section 存在
uci -q set $UCI_CONF.main=main

TPROXY_PORT=$(uci -q get ${UCI_CONF}.main.tproxy_port)
if [ -z "$TPROXY_PORT" ]; then
    TPROXY_PORT="22610"
    uci set ${UCI_CONF}.main.tproxy_port="$TPROXY_PORT"
    uci commit ${UCI_CONF}
fi

cat << EOF > "$CONF_DIR/01_inbounds.json"
{
  "inbounds": [
    {
      "port": $TPROXY_PORT,
      "protocol": "tunnel",
      "tag": "tproxy_inbound",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["fakedns"],
        "metadataOnly": true
      }
    }
  ]
}
EOF
