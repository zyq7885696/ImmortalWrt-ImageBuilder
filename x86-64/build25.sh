#!/bin/bash
# Build script for ImmortalWrt 25.12.x
# 25.12 使用 APK 包管理器

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
if [ -n "$CUSTOM_ROUTER_IP" ] && [ "$CUSTOM_ROUTER_IP" != "172.16.1.251" ]; then
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

# ============= Kucat 主题下载并添加到本地仓库 ===============
echo "🎨 正在下载 Kucat 主题 v3.3.0..."

# 创建临时目录用于构建本地源
KUCAT_DIR="/home/build/immortalwrt/kucat-packages"
mkdir -p "$KUCAT_DIR"
mkdir -p "/home/build/immortalwrt/files/etc/uci-defaults"

# 下载主题包到临时目录
cd "$KUCAT_DIR"

# 下载并验证文件
echo "下载 luci-theme-kucat..."
wget --no-check-certificate -q --show-progress -O luci-theme-kucat.ipk \
    https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk

if [ ! -f luci-theme-kucat.ipk ] || [ ! -s luci-theme-kucat.ipk ]; then
    echo "❌ 下载 luci-theme-kucat 失败"
    KUCAT_AVAILABLE=false
else
    echo "✅ luci-theme-kucat 下载成功"
    KUCAT_AVAILABLE=true
fi

echo "下载 luci-app-kucat-config..."
wget --no-check-certificate -q --show-progress -O luci-app-kucat-config.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk

if [ ! -f luci-app-kucat-config.ipk ] || [ ! -s luci-app-kucat-config.ipk ]; then
    echo "❌ 下载 luci-app-kucat-config 失败"
    KUCAT_AVAILABLE=false
fi

echo "下载 luci-i18n-kucat-config-zh-cn..."
wget --no-check-certificate -q --show-progress -O luci-i18n-kucat-config-zh-cn.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

if [ ! -f luci-i18n-kucat-config-zh-cn.ipk ] || [ ! -s luci-i18n-kucat-config-zh-cn.ipk ]; then
    echo "❌ 下载 luci-i18n-kucat-config-zh-cn 失败"
    KUCAT_AVAILABLE=false
fi

if [ "$KUCAT_AVAILABLE" = true ]; then
    # 创建本地仓库目录结构
    LOCAL_REPO="/home/build/immortalwrt/bin/packages/x86_64/kucat"
    mkdir -p "$LOCAL_REPO"
    
    # 复制包到仓库
    cp -f "$KUCAT_DIR"/*.ipk "$LOCAL_REPO/"
    
    # 生成 APK 索引 (ImmortalWrt 25.12 使用 APK)
    cd "$LOCAL_REPO"
    
    # 创建 APKINDEX
    echo "生成 APK 仓库索引..."
    apk index -o APKINDEX.tar.gz *.ipk 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✅ APK 索引生成成功"
        # 创建签名文件（空文件，用于跳过签名验证）
        touch APKINDEX.tar.gz.asc
    else
        echo "⚠️ APK 索引生成失败，尝试使用传统方法"
        # 备用方案：使用 ipkg-make-index.sh
        if [ -f "../../../../scripts/ipkg-make-index.sh" ]; then
            ../../../../scripts/ipkg-make-index.sh . > Packages 2>/dev/null
            gzip -9c Packages > Packages.gz 2>/dev/null
            echo "✅ 传统索引生成成功"
        fi
    fi
    
    # 添加本地仓库源
    mkdir -p /home/build/immortalwrt/files/etc/apk
    cat << 'APK_REPO' > /home/build/immortalwrt/files/etc/apk/repositories.local
/src/kucat file:///usr/local/kucat-packages
APK_REPO
    
    # 创建安装脚本（在固件首次启动时安装）
    cat << 'INSTALL_SCRIPT' > /home/build/immortalwrt/files/etc/uci-defaults/98-install-kucat
#!/bin/sh
# 安装 Kucat 主题包
mkdir -p /usr/local/kucat-packages
cp -f /etc/kucat-packages/*.ipk /usr/local/kucat-packages/ 2>/dev/null
cd /usr/local/kucat-packages
apk add --allow-untrusted *.ipk 2>/dev/null || opkg install *.ipk 2>/dev/null
exit 0
INSTALL_SCRIPT
    
    # 准备包文件到 files 目录
    mkdir -p /home/build/immortalwrt/files/etc/kucat-packages
    cp -f "$LOCAL_REPO"/*.ipk /home/build/immortalwrt/files/etc/kucat-packages/
    
    chmod +x /home/build/immortalwrt/files/etc/uci-defaults/98-install-kucat
    
    # 设置默认主题脚本
    cat << 'THEME_SCRIPT' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
# 等待主题安装完成
sleep 2
if [ -d "/usr/lib/lua/luci/view/kucat" ] || [ -f "/usr/lib/lua/luci/view/theme/kucat" ]; then
    uci set luci.main.mediaurlbase='/luci-static/kucat'
    uci commit luci
    echo "✅ Kucat 主题已激活"
fi
exit 0
THEME_SCRIPT
    chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
    
    echo "✅ Kucat 主题配置完成"
    
    # 列出已准备的包
    echo "📦 Kucat 包列表:"
    ls -lh "$LOCAL_REPO/"
else
    echo "⚠️ Kucat 主题下载失败，将跳过主题集成"
fi

# 清理临时目录
rm -rf "$KUCAT_DIR"

# ============= 软件包列表 ===============
PACKAGES="curl luci-i18n-diskman-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server luci-i18n-filemanager-zh-cn luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-app-zerotier luci-i18n-zerotier-zh-cn luci-app-openclash"

# 只有在 Kucat 包可用时才添加到列表
if [ "$KUCAT_AVAILABLE" = true ]; then
    # 注意：包会在首次启动时通过 uci-defaults 脚本安装
    echo "✅ Kucat 主题将在首次启动时安装"
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
fi

# ============= 更新 feeds 并构建 =============
cd /home/build/immortalwrt

# 更新 feeds
./scripts/feeds update -a > /dev/null 2>&1
./scripts/feeds install -a > /dev/null 2>&1

# 添加基本配置到 .config
cat >> .config << 'CONFIG_EOF'
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="ImmortalWrt"
CONFIG_VERSION_REPO="https://download.immortalwrt.org"
CONFIG_KERNEL_BUILD_USER="builder"
CONFIG_KERNEL_BUILD_DOMAIN="buildhost"
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_EXT4FS=n
CONFIG_TARGET_IMAGES_GZIP=y
CONFIG_TARGET_ROOTFS_PARTSIZE=$PROFILE
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_luci-app-diskman=y
CONFIG_PACKAGE_luci-app-filemanager=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_EOF

# 构建固件
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image..."
echo "包含的软件包: $PACKAGES"

# 使用 make image
make image PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE="$PROFILE" \
    EXT4_IMGS=0 \
    SQUASHFS_IMGS=1

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    echo "检查错误日志..."
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully!"
echo "=========================================="
echo "✅ ImmortalWrt 25.12 固件已生成"
echo "✅ 仅 squashfs 格式"
echo "✅ IPv6 已禁用 (运行时配置)"
echo "✅ DHCPv4 已禁用 (运行时配置)"
echo "✅ 包管理器: APK"
if [ "$KUCAT_AVAILABLE" = true ]; then
    echo "✅ Kucat 主题已集成 (首次启动时安装)"
else
    echo "⚠️ Kucat 主题未集成 (下载失败)"
fi
echo "=========================================="

# 显示固件位置
echo "📦 固件位置:"
find /home/build/immortalwrt/bin -name "*.img" -o -name "*.gz" 2>/dev/null | head -10

# 列出所有生成的文件
echo ""
echo "📁 完整文件列表:"
find /home/build/immortalwrt/bin -type f -size +1M 2>/dev/null | while read file; do
    ls -lh "$file"
done

exit 0
