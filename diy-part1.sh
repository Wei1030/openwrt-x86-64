#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' >>feeds.conf.default
#echo 'src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main' >>feeds.conf.default
#echo 'src-git helloworld https://github.com/Openwrt-Passwall/openwrt-passwall2' >>feeds.conf.default
#echo 'src-git-full luci_app_xray https://github.com/yichya/luci-app-xray' >>feeds.conf.default

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
cp -r $SCRIPT_DIR/luci-app-xray-client $SCRIPT_DIR/openwrt/package/
