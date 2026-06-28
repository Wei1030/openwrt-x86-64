#
# OpenWrt Makefile for luci-app-xray-client
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xray-client
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

# Xray 下载信息 (如果版本更新，修改这里的URL和HASH)
PKG_SOURCE:=Xray-linux-64.zip
PKG_SOURCE_URL:=https://github.com/XTLS/Xray-core/releases/download/v26.3.27/
PKG_HASH:=skip

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# 包含 OpenWrt 核心打包规则
include $(INCLUDE_DIR)/package.mk

# ==========================================
# 包定义：luci-app-xray-client 
# ==========================================
define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Xray Client with LuCI
  DEPENDS:=+ip-full +ucode +uci +luci-base
  PKGARCH:=x86_64
endef

define Package/$(PKG_NAME)/description
  Xray client with LuCI support.
endef

# 定义配置文件（升级时保留）
define Package/$(PKG_NAME)/conffiles
/etc/config/xrayclient
endef

# ==========================================
# 构建准备：下载并解压 Xray
# ==========================================
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	# 解压下载好的 Xray zip 包到构建目录
	unzip -o $(DL_DIR)/$(PKG_SOURCE) -d $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
endef

# ==========================================
# 安装规则：把所有文件放到目标系统的对应目录
# ==========================================
define Package/$(PKG_NAME)/install
	# 1. 创建所有需要的目录
	$(INSTALL_DIR) $(1)/usr/share/xrayclient
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/xray-client
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/xrayclient/conf.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d

	# 2. 安装下载的 Xray 二进制文件和地理数据
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/xray $(1)/usr/share/xrayclient/xray
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/geoip.dat $(1)/usr/share/xrayclient/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/geosite.dat $(1)/usr/share/xrayclient/

	# 3. 安装后端脚本 (确保之前写的所有 .sh 文件都在 files/usr/share/xrayclient/ 下)
	$(INSTALL_BIN) ./files/usr/share/xrayclient/*.sh $(1)/usr/share/xrayclient/

	# 4. 安装 LuCI 前端文件 (JS/JSON)
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-xray-client.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/xray-client/settings.js $(1)/www/luci-static/resources/view/xray-client/

	# 5. 安装配置文件和服务启动脚本
	$(INSTALL_CONF) ./files/etc/config/xrayclient $(1)/etc/config/xrayclient
	$(INSTALL_BIN) ./files/etc/init.d/xrayclient $(1)/etc/init.d/xrayclient

	# 6. 安装 rpcd ACL 权限文件
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-xrayclient.json $(1)/usr/share/rpcd/acl.d/
endef

# ==========================================
# 安装后执行的脚本
# ==========================================
define Package/$(PKG_NAME)/postinst
#!/bin/sh
# 给所有脚本赋予可执行权限
[ -d /usr/share/xrayclient ] && chmod +x /usr/share/xrayclient/*.sh 2>/dev/null

# 重载 rpcd 使 ACL 权限生效
/etc/init.d/rpcd reload 2>/dev/null

# 执行初始化安装脚本
if [ -f /usr/share/xrayclient/install.sh ]; then
    sh /usr/share/xrayclient/install.sh
fi
exit 0
endef

# ==========================================
# 卸载前执行的脚本
# ==========================================
define Package/$(PKG_NAME)/prerm
#!/bin/sh
# 执行卸载脚本清理 nftables、路由和用户
if [ -f /usr/share/xrayclient/uninstall.sh ]; then
    sh /usr/share/xrayclient/uninstall.sh
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
