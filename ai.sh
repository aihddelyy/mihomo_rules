#!/bin/sh

# 优化后的脚本，适用于 OpenWrt 环境

# 下载并解压 mihomo
wget -O mihomo.gz "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-amd64-alpha-smart-f83f0c7.gz" && gunzip mihomo.gz

# 下载模型文件
wget -O Model.bin "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin"

# 移动并设置权限
mv -f mihomo /usr/bin/mihomo
chmod 755 /usr/bin/mihomo

# 重启服务
/etc/init.d/nikki restart

# 清理临时文件
rm -f mihomo.gz
