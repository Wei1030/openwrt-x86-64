#!/bin/sh

# 获取脚本绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

UCI_CONF="xrayclient"
LOG_FILE="/var/log/xrayclient.log"
DATA_DIR="/usr/share/xrayclient"

# geoip/geosite 的存放目录 (由 v2ray-geoip / v2ray-geosite 包提供)
ASSET_DIR="/usr/share/v2ray"

# 更新模式: ip (cn_v4+cn_v6+geoip), dat (geosite), all 或无参数 (全部)
UPDATE_MODE="${1:-all}"

mkdir -p /var/log 2>/dev/null

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [update_data] $1" >> "$LOG_FILE"
}

# ====================
# 下载函数: 优先 curl，没有则用 wget (uclient-fetch)
# 用法: dl URL OUTPUT_FILE [TIMEOUT]
#   TIMEOUT 默认 120 秒
# 返回: 0 成功且文件非空，1 失败
# ====================
dl() {
    _url="$1"
    _out="$2"
    _timeout="${3:-120}"

    if command -v curl >/dev/null 2>&1; then
        curl -sL --connect-timeout 10 --max-time "$_timeout" "$_url" -o "$_out" 2>/dev/null
    else
        wget -q -T "$_timeout" -O "$_out" "$_url" 2>/dev/null
    fi

    [ -s "$_out" ]
}

# 下载到 stdout (用于管道场景，如 | grep)
# 用法: dl_stdout URL [TIMEOUT]
dl_stdout() {
    _url="$1"
    _timeout="${2:-60}"

    if command -v curl >/dev/null 2>&1; then
        curl -sL --connect-timeout 10 --max-time "$_timeout" "$_url" 2>/dev/null
    else
        wget -q -T "$_timeout" -O - "$_url" 2>/dev/null
    fi
}

# 从 UCI 读取 URL (带默认值)
CN_IP_URL=$(uci -q get ${UCI_CONF}.main.cn_ip_url)
[ -z "$CN_IP_URL" ] && CN_IP_URL="https://gaoyifan.github.io/china-operator-ip/china.txt"

CN_V6_URL=$(uci -q get ${UCI_CONF}.main.cn_v6_url)
[ -z "$CN_V6_URL" ] && CN_V6_URL="https://gaoyifan.github.io/china-operator-ip/china6.txt"

GEOIP_URL=$(uci -q get ${UCI_CONF}.main.geoip_url)
[ -z "$GEOIP_URL" ] && GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

GEOSITE_URL=$(uci -q get ${UCI_CONF}.main.geosite_url)
[ -z "$GEOSITE_URL" ] && GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

GEOIP_SHA256_URL=$(uci -q get ${UCI_CONF}.main.geoip_sha256_url)
[ -z "$GEOIP_SHA256_URL" ] && GEOIP_SHA256_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat.sha256sum"

GEOSITE_SHA256_URL=$(uci -q get ${UCI_CONF}.main.geosite_sha256_url)
[ -z "$GEOSITE_SHA256_URL" ] && GEOSITE_SHA256_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat.sha256sum"

UPDATED=0

log "开始更新数据文件 (模式: ${UPDATE_MODE})..."

# ====================
# 通用函数: 带 sha256 校验的 dat 文件更新
# ====================
update_dat_with_checksum() {
    DAT_NAME="$1"       # geoip.dat / geosite.dat
    DAT_URL="$2"        # dat 下载 URL
    SHA_URL="$3"        # 校验文件 URL
    SHA_LOCAL="$ASSET_DIR/${DAT_NAME}.sha256sum"

    # 下载新的校验文件
    TMP_SHA=$(mktemp)
    if [ -n "$SHA_URL" ]; then
        if ! dl "$SHA_URL" "$TMP_SHA" 30; then
            log "${DAT_NAME} 校验文件下载失败，直接更新 dat 文件"
            rm -f "$TMP_SHA"
            TMP_SHA=""
        fi
    else
        rm -f "$TMP_SHA"
        TMP_SHA=""
    fi

    # 如果有校验文件，比较内容
    if [ -n "$TMP_SHA" ]; then
        NEW_SHA_CONTENT=$(cat "$TMP_SHA")
        if [ -f "$SHA_LOCAL" ]; then
            OLD_SHA_CONTENT=$(cat "$SHA_LOCAL")
            if [ "$NEW_SHA_CONTENT" = "$OLD_SHA_CONTENT" ]; then
                log "${DAT_NAME} 校验文件一致，数据已是最新，跳过更新"
                rm -f "$TMP_SHA"
                return 0
            fi
        fi
        log "${DAT_NAME} 校验文件不一致 (或本地无校验文件)，开始更新 dat..."
    fi

    # 下载 dat 文件
    TMP_DAT=$(mktemp)
    if dl "$DAT_URL" "$TMP_DAT" 120; then
        mv "$TMP_DAT" "$ASSET_DIR/${DAT_NAME}"
        log "${DAT_NAME} 更新成功 ($(ls -lh "$ASSET_DIR/${DAT_NAME}" | awk '{print $5}'))"
        # 保存校验文件
        if [ -n "$TMP_SHA" ]; then
            mv "$TMP_SHA" "$SHA_LOCAL"
        fi
        UPDATED=1
    else
        log "${DAT_NAME} 下载失败"
        rm -f "$TMP_DAT" "$TMP_SHA"
    fi
}

# ====================
# 1. 更新 IP 类数据 (cn_v4 + cn_v6 + geoip)
# ====================
if [ "$UPDATE_MODE" = "ip" ] || [ "$UPDATE_MODE" = "all" ]; then
    # 1. 更新中国 IPv4 列表
    TMP_CN=$(mktemp)
    if dl_stdout "$CN_IP_URL" 60 | grep -E '^[0-9]+\.' > "$TMP_CN" 2>/dev/null && [ -s "$TMP_CN" ]; then
        mv "$TMP_CN" "$DATA_DIR/cn_v4.list"
        log "CN IPv4 列表更新成功 ($(wc -l < "$DATA_DIR/cn_v4.list") 条)"
        UPDATED=1
    else
        log "CN IPv4 列表下载失败"
    fi
    rm -f "$TMP_CN"

    # 2. 更新中国 IPv6 列表
    TMP_CN6=$(mktemp)
    if dl_stdout "$CN_V6_URL" 60 | grep -E '^([0-9a-fA-F:]+/)' > "$TMP_CN6" 2>/dev/null && [ -s "$TMP_CN6" ]; then
        mv "$TMP_CN6" "$DATA_DIR/cn_v6.list"
        log "CN IPv6 列表更新成功 ($(wc -l < "$DATA_DIR/cn_v6.list") 条)"
        UPDATED=1
    else
        log "CN IPv6 列表下载失败或无 IPv6 数据"
    fi
    rm -f "$TMP_CN6"

    # 3. 更新 geoip.dat (带校验文件检查)
    update_dat_with_checksum "geoip.dat" "$GEOIP_URL" "$GEOIP_SHA256_URL"
fi

# ====================
# 4. 更新 geosite.dat (带校验文件检查)
# ====================
if [ "$UPDATE_MODE" = "dat" ] || [ "$UPDATE_MODE" = "all" ]; then
    update_dat_with_checksum "geosite.dat" "$GEOSITE_URL" "$GEOSITE_SHA256_URL"
fi

# ====================
# 5. 如果有文件更新，重启 xrayclient 服务
# ====================
if [ "$UPDATED" = "1" ]; then
    log "有文件更新，重启 xrayclient 服务..."
    /etc/init.d/xrayclient restart 2>/dev/null
    log "服务重启完成"
else
    log "无文件更新，跳过重启"
fi
