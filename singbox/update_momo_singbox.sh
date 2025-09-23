#!/bin/bash

# 设置路径
TMP_DIR="/tmp/momo_update"
LOG_DIR="/var/log/momo_update"
LOG_FILE="$LOG_DIR/update_$(date '+%Y-%m-%d_%H-%M-%S').log"

# 创建目录
mkdir -p "$TMP_DIR"
mkdir -p "$LOG_DIR"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "开始 Momo sing-box fork 内核更新流程"


# 下载 fork 内核 若架构不同对应修改此处链接
log "下载内核..."
wget -qO "$TMP_DIR/sing-box" "https://gh-proxy.com/raw.githubusercontent.com/aihddelyy/mihomo_rules/refs/heads/main/singbox/sing-box-1.13.0-alpha.17-reF1nd-linux-amd64"
if [ $? -ne 0 ]; then
    log "❌ 内核下载失败，终止更新"
    exit 1
fi


# 替换旧内核
log "替换旧内核..."
mv -f "$TMP_DIR/sing-box" /usr/bin/sing-box
chmod +x /usr/bin/sing-box


# 重启服务
log "重启 nikki 服务..."
service momo restart
if [ $? -eq 0 ]; then
    log "✅ Momo 服务重启成功"
else
    log "⚠️ Momo 服务重启失败，请手动检查"
fi

# 清理
log "清理临时文件..."
rm -rf "$TMP_DIR"

# 清理 15 天前的日志
log "清理 15 天前的日志文件..."
find "$LOG_DIR" -type f -name "update_*.log" -mtime +15 -exec rm -f {} \;

log "🎉 内核更新流程完成"
