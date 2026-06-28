#!/bin/sh

CONF_DIR="/etc/xrayclient/conf.d"
UCI_CONF="xrayclient"

# 确保 main section 存在
uci -q set $UCI_CONF.main=main

FAKEIP_CIDR=$(uci -q get ${UCI_CONF}.main.fakeip_cidr)
if [ -z "$FAKEIP_CIDR" ]; then
    FAKEIP_CIDR="198.18.0.0/15"
    uci set ${UCI_CONF}.main.fakeip_cidr="$FAKEIP_CIDR"
    uci commit ${UCI_CONF}
fi

cat << EOF > "$CONF_DIR/03_fakedns.json"
{
  "fakedns": [
    {
      "ipPool": "${FAKEIP_CIDR}",
      "poolSize": 65535
    }
  ]
}
EOF
