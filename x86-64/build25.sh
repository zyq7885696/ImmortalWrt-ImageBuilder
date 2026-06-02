#!/bin/bash
# Build script for ImmortalWrt 25.12.x
# 25.12 使用 APK 包管理器，内核默认支持 BBR

source shell/custom-packages.sh
source shell/switch_repository.sh

echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting build25.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

cd /home/build/immortalwrt

# ============= 读取自定义路由器IP =============
CUSTOM_ROUTER_IP=$(cat /home/build/immortalwrt/files/etc/config/custom_router_ip.txt 2>/dev/null || echo "192.168.100.1")
echo "路由器管理地址: $CUSTOM_ROUTER_IP"

# ============= 创建 pppoe-settings 配置文件 =============
echo "Create pppoe-settings"
mkdir -p /home/build/immortalwrt/files/etc/config

cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# ============= 保存自定义路由器IP =============
if [ -n "$CUSTOM_ROUTER_IP" ] && [ "$CUSTOM_ROUTER_IP" != "192.168.100.1" ]; then
    echo "$CUSTOM_ROUTER_IP" > /home/build/immortalwrt/files/etc/config/custom_router_ip.txt
    echo "✅ 自定义路由器IP已保存: $CUSTOM_ROUTER_IP"
fi

# ============= 第三方包处理 =============
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 同步第三方软件仓库..."
    git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true
    echo "✅ Run files copied"
    if [ -f "shell/prepare-packages.sh" ]; then
        sh shell/prepare-packages.sh
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= Kucat 主题下载 ===============
echo "🎨 正在下载 Kucat 主题 v3.3.0..."
mkdir -p /home/build/immortalwrt/packages/kucat

wget --no-check-certificate -q -O /home/build/immortalwrt/packages/kucat/luci-theme-kucat_3.3.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk

wget --no-check-certificate -q -O /home/build/immortalwrt/packages/kucat/luci-app-kucat-config_2.2.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk

wget --no-check-certificate -q -O /home/build/immortalwrt/packages/kucat/luci-i18n-kucat-config-zh-cn_0_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

# 设置默认主题 (25.12 使用 service 命令)
cat << 'THEME_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
THEME_EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
echo "✅ Kucat 主题配置完成"

# ============= 软件包列表 ===============
PACKAGES="curl luci-i18n-diskman-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server luci-i18n-filemanager-zh-cn luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-app-zerotier luci-i18n-zerotier-zh-cn luci-app-openclash"

# 添加 Kucat 主题
if ls /home/build/immortalwrt/packages/kucat/*.ipk 1>/dev/null 2>&1; then
    mkdir -p /home/build/immortalwrt/extra-packages-local
    cp /home/build/immortalwrt/packages/kucat/*.ipk /home/build/immortalwrt/extra-packages-local/
    PACKAGES="$PACKAGES luci-theme-kucat luci-app-kucat-config luci-i18n-kucat-config-zh-cn"
fi

PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ 添加 Docker 支持"
fi

# OpenClash 内核下载
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 添加 OpenClash 内核"
    mkdir -p files/etc/openclash/core
    wget -qO- https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    [ -n "$URL" ] && wget -q "$URL" -P /home/build/immortalwrt/packages/
fi

# ============= 更新 feeds 并构建 =============
cd /home/build/immortalwrt

# 更新 feeds (25.12 使用 APK)
./scripts/feeds update -a > /dev/null 2>&1
./scripts/feeds install -a > /dev/null 2>&1

# 构建固件 - 仅 squashfs
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image..."
echo "包含的软件包: $PACKAGES"

make image PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE="$PROFILE" \
    EXT4_IMGS=0 \
    SQUASHFS_IMGS=1

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully!"
echo "=========================================="
echo "✅ ImmortalWrt 25.12 固件已生成"
echo "✅ 仅 squashfs 格式"
echo "✅ IPv6 已禁用"
echo "✅ DHCPv4 已禁用"
echo "✅ BBR 加速已启用 (内核原生支持)"
echo "✅ 包管理器: APK"
echo "=========================================="

# 显示固件位置
echo "📦 固件位置:"
find /home/build/immortalwrt/bin -name "*.img" -o -name "*.gz" 2>/dev/null | head -10

exit 0
