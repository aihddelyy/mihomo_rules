#!/bin/sh

# 切换到nikki运行目录
cd /etc/nikki/run

# 下载并解压mihomo
wget -O mihomo.gz "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-amd64-alpha-smart-f83f0c7.gz" && gunzip mihomo.gz

# 下载模型文件
wget -O Model.bin "https://gh-proxy.com/github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin"

# 移动并设置权限
mv -f mihomo /usr/bin/mihomo
chmod 755 /usr/bin/mihomo

# 重启服务
/etc/init.d/nikki restart

# 清理文件
rm -f mihomo.gz
