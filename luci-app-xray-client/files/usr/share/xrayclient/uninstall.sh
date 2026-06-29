#!/bin/sh
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

echo "开始卸载 Xray client..."

# 1. 先清理定时更新任务 (避免卸载过程中 cron 触发脚本)
sed -i '/# xrayclient-update-ip\|# xrayclient-update-dat/d' /etc/crontabs/root 2>/dev/null
/etc/init.d/cron restart 2>/dev/null

# 2. 停止服务和规则
/etc/init.d/xrayclient stop 2>/dev/null || true

# 3. 移除用户
[ -f "$SCRIPT_DIR/remove_usr.sh" ] && sh "$SCRIPT_DIR/remove_usr.sh" > /dev/null 2>&1 || true

# 4. 禁用并删除服务脚本
/etc/init.d/xrayclient disable > /dev/null 2>&1 || true
rm -f /etc/init.d/xrayclient

# 5. 删除所有相关目录和文件
rm -rf /etc/xrayclient/
rm -rf /usr/share/xrayclient/
rm -f /etc/config/xrayclient

echo "=================================="
echo "Xray client 卸载完毕。"
