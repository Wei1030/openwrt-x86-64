#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

# 常量定义
UCI_CONF="xrayclient"
DEFAULT_USR_NAME="xrayclient_user"
DEFAULT_USR_GID="22610"

# 确保 main section 存在
uci -q set $UCI_CONF.main=main

# 1. 从 UCI 读取用户名和 GID，若无则使用默认值并写回 UCI
XRAY_USR_NAME=$(uci -q get $UCI_CONF.main.xray_usr_name)
if [ -z "$XRAY_USR_NAME" ]; then
    XRAY_USR_NAME="$DEFAULT_USR_NAME"
    uci set $UCI_CONF.main.xray_usr_name="$XRAY_USR_NAME"
fi

XRAY_USR_GID=$(uci -q get $UCI_CONF.main.xray_usr_gid)
if [ -z "$XRAY_USR_GID" ]; then
    XRAY_USR_GID="$DEFAULT_USR_GID"
    uci set $UCI_CONF.main.xray_usr_gid="$XRAY_USR_GID"
fi
uci commit $UCI_CONF

# 使用绝对路径定义卸载脚本路径
REMOVE_SCRIPT="$SCRIPT_DIR/remove_usr.sh"

# ====================
# 预执行与初始化
# ====================
# 1. 如果存在旧的卸载脚本，先执行它，还原上一次的增量修改
if [ -f "$REMOVE_SCRIPT" ]; then
    echo "检测到 $REMOVE_SCRIPT，正在执行卸载以清理历史用户修改..."
    sh "$REMOVE_SCRIPT"
fi

# 2. 重置卸载脚本（覆盖写入），准备记录本次的新增
cat << 'EOF' > "$REMOVE_SCRIPT"
#!/bin/sh
# 自动生成的增量还原脚本，仅撤销对应安装脚本带来的新增用户修改
echo "开始还原用户增量修改..."
EOF
chmod +x "$REMOVE_SCRIPT"

# ====================
# 辅助函数
# ====================
# 作用：将还原语句追加到卸载脚本中（带有防重复写入检测）
add_remove_cmd() {
    local cmd="$1"
    if ! grep -qF "$cmd" "$REMOVE_SCRIPT"; then
        echo "$cmd" >> "$REMOVE_SCRIPT"
    fi
}

# ====================
# 核心配置逻辑
# ====================
echo "正在检查用户配置 (期望新增用户: ${XRAY_USR_NAME}, UID:0, GID:${XRAY_USR_GID})..."

# 1. 检查是否已存在 UID=0 且 GID=XRAY_USR_GID 的用户
EXISTING_UID0_GID_USR=$(awk -F: -v gid="$XRAY_USR_GID" '$3 == 0 && $4 == gid {print $1}' /etc/passwd | head -n 1)
if [ -n "$EXISTING_UID0_GID_USR" ]; then
    echo "错误: 系统中已存在 UID=0 且 GID=${XRAY_USR_GID} 的用户 (${EXISTING_UID0_GID_USR})！"
    echo "请修改 UCI 配置 ($UCI_CONF.main.xray_usr_gid) 后重试。"
    echo "正在自动运行 $REMOVE_SCRIPT 清理本次脚本半途产生的修改..."
    sh "$REMOVE_SCRIPT"
    exit 1
fi

# 2. 检查指定的用户名是否已经被占用
if grep -qw "$XRAY_USR_NAME" /etc/passwd; then
    echo "错误: 用户名 '$XRAY_USR_NAME' 已存在，但不满足当前所需的 UID/GID 条件！"
    echo "请修改 UCI 配置 ($UCI_CONF.main.xray_usr_name) 后重试。"
    echo "正在自动运行 $REMOVE_SCRIPT 清理本次脚本半途产生的修改..."
    sh "$REMOVE_SCRIPT"
    exit 1
fi

# 3. 环境干净，开始添加用户
echo "${XRAY_USR_NAME}:x:0:${XRAY_USR_GID}:::" >> /etc/passwd
if [ $? -ne 0 ]; then
    echo "错误: 添加用户 ${XRAY_USR_NAME} 失败。"
    sh "$REMOVE_SCRIPT"
    exit 1
fi
echo " -> 已添加用户: ${XRAY_USR_NAME} (UID:0, GID:${XRAY_USR_GID})"

# 记录对应的 sed 删除语句 (精准匹配整行)
add_remove_cmd "sed -i '/^${XRAY_USR_NAME}:x:0:${XRAY_USR_GID}:::/d' /etc/passwd 2>/dev/null"

# 记录状态锁重置语句到卸载脚本
add_remove_cmd "uci -q set $UCI_CONF.main.usr_setup='0'"
add_remove_cmd "uci -q commit $UCI_CONF"

# 在卸载脚本末尾加上结束提示
echo "echo '用户增量修改已还原完毕。'" >> "$REMOVE_SCRIPT"

# 4. 标记本次安装成功，写入状态锁
uci set $UCI_CONF.main.usr_setup='1'
uci commit $UCI_CONF

echo "=================================="
echo "用户配置完成！"
