#!/bin/bash

# 设置路径
TMP_DIR="/tmp/nikki_update"
LOG_DIR="/var/log/nikki_update"
LOG_FILE="$LOG_DIR/update_$(date '+%Y-%m-%d_%H-%M-%S').log"

# 创建目录
mkdir -p "$TMP_DIR"
mkdir -p "$LOG_DIR"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "开始 Nikki Smart 内核更新流程"

# 获取版本号 若架构不同对应修改此处链接
log "获取内核版本号..."
version=$(wget -qO - https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/version.txt)

if [ -z "$version" ]; then
    log "❌ 获取版本号失败，终止更新"
    exit 1
fi

log "获取的版本号为 $version"

# 下载 Smart 内核 若架构不同对应修改此处链接
log "下载内核..."
wget -qO "$TMP_DIR/mihomo-linux-amd64.gz" "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-amd64-$version.gz"
if [ $? -ne 0 ]; then
    log "❌ 内核下载失败，终止更新"
    exit 1
fi

# 解压
log "解压内核..."
gzip -d "$TMP_DIR/mihomo-linux-amd64.gz"
if [ $? -ne 0 ]; then
    log "❌ 解压失败，终止更新"
    exit 1
fi

# 替换旧内核
log "替换旧内核..."
mv -f "$TMP_DIR/mihomo-linux-amd64" /usr/bin/mihomo
chmod +x /usr/bin/mihomo

# 重启服务
log "重启 nikki 服务..."
service nikki restart
if [ $? -eq 0 ]; then
    log "✅ Nikki 服务重启成功"
else
    log "⚠️ Nikki 服务重启失败，请手动检查"
fi

# 清理
log "清理临时文件..."
rm -rf "$TMP_DIR"

# 清理 15 天前的日志
log "清理 15 天前的日志文件..."
find "$LOG_DIR" -type f -name "update_*.log" -mtime +15 -exec rm -f {} \;

log "🎉 内核更新流程完成"
