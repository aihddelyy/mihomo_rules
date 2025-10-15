#!/bin/bash

# 设置路径
TMP_DIR="/tmp/nikki_update"
LOG_DIR="/var/log/nikki_update"
LOG_FILE="$LOG_DIR/update_$(date '+%Y-%m-%d_%H-%M-%S').log"

GITHUB_RAW_URL="https://github.com/vernesong/mihomo/releases/download/Prerelease-Alpha"

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
version=$(wget -qO - "$GITHUB_RAW_URL/version.txt")

if [ -z "$version" ]; then
    log "⚠️ 直接从 GitHub 获取版本号失败，尝试通过代理获取..."
    version=$(wget -qO - "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/version.txt")
    if [ -z "$version" ]; then
        log "❌ 代理获取版本号失败，终止更新"
        exit 1
    fi
fi
    log "❌ 获取版本号失败，终止更新"
    exit 1
fi

log "获取的版本号为 $version"

# 下载 Smart 内核 若架构不同对应修改此处链接
log "下载内核..."
wget -qO "$TMP_DIR/mihomo-linux-amd64.gz" "$GITHUB_RAW_URL/mihomo-linux-amd64-v3-$version.gz"
if [ $? -ne 0 ]; then
    log "⚠️ 直接从 GitHub 下载内核失败，尝试通过代理下载..."
    wget -qO "$TMP_DIR/mihomo-linux-amd64.gz" "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-amd64-v3-$version.gz"
    if [ $? -ne 0 ]; then
        log "❌ 代理下载内核失败，终止更新"
        exit 1
    fi
fi
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

# 下载模型文件
log "下载模型文件..."
wget -qO "$TMP_DIR/Model.bin" "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin"
if [ $? -ne 0 ]; then
    log "❌ 模型文件下载失败，终止更新"
    exit 1
fi
# 替换旧模型文件
log "替换旧模型文件..."
mv -f "$TMP_DIR/Model.bin" /etc/nikki/run/Model.bin

# 重启服务
log "重启 nikki 服务..."
if service nikki status >/dev/null 2>&1; then
    log "重启 nikki 服务..."
    service nikki restart
    if [ $? -eq 0 ]; then
        log "✅ Nikki 服务重启成功"
    else
        log "⚠️ Nikki 服务重启失败，请手动检查"
    fi
else
    log "⚠️ Nikki 服务未找到，跳过重启"
fi

# 清理
log "清理临时文件..."
rm -rf "$TMP_DIR"

# 清理 15 天前的日志
log "清理 15 天前的日志文件..."
find "$LOG_DIR" -type f -name "update_*.log" -mtime +15 -exec rm -f {} \;

log "🎉 内核更新流程完成"
