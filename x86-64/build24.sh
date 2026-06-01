#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  # 解压并拷贝ipk到packages目录
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= 下载指定版本的 Kucat 主题 ===============
echo "🎨 正在下载 Kucat 主题 v3.3.0..."

# 创建 Kucat 包目录
mkdir -p /home/build/immortalwrt/packages/kucat

# 下载主题包
echo "正在下载 luci-theme-kucat..."
wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-theme-kucat_3.3.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk

if [ $? -eq 0 ] && [ -f /home/build/immortalwrt/packages/kucat/luci-theme-kucat_3.3.0-r20260227_all.ipk ]; then
    echo "✅ 主题包下载成功"
else
    echo "❌ 主题包下载失败"
fi

# 下载配置应用
echo "正在下载 luci-app-kucat-config..."
wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-app-kucat-config_2.2.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk

if [ $? -eq 0 ] && [ -f /home/build/immortalwrt/packages/kucat/luci-app-kucat-config_2.2.0-r20260227_all.ipk ]; then
    echo "✅ 配置应用下载成功"
else
    echo "❌ 配置应用下载失败"
fi

# 下载语言包
echo "正在下载 luci-i18n-kucat-config-zh-cn..."
wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-i18n-kucat-config-zh-cn_0_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

if [ $? -eq 0 ] && [ -f /home/build/immortalwrt/packages/kucat/luci-i18n-kucat-config-zh-cn_0_all.ipk ]; then
    echo "✅ 语言包下载成功"
else
    echo "❌ 语言包下载失败"
fi

# 记录下载的包文件
ls -lh /home/build/immortalwrt/packages/kucat/ > /home/build/immortalwrt/packages/kucat/kucat_packages.txt

# 设置默认主题为 Kucat
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
# 设置 Kucat 为默认主题
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci

# 可选：设置 Argon 为暗色主题（如果需要）
# uci set luci.themes.Argon='/luci-static/argon'
# uci commit luci
exit 0
EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

echo "✅ Kucat 主题安装完成并设置为默认主题"
ls -lh /home/build/immortalwrt/packages/kucat/

# ============= imm仓库内的插件==============
# 定义所需安装的包列表（已移除 Argon 主题）
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
# 已移除 Argon 主题相关包
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 新增插件
PACKAGES="$PACKAGES luci-app-ddns-go"  # DDNS-GO
PACKAGES="$PACKAGES luci-app-zerotier"  # ZeroTier
PACKAGES="$PACKAGES luci-app-openclash"  # OpenClash
PACKAGES="$PACKAGES luci-app-smartdns"  # SmartDNS

# 添加本地 Kucat 主题包路径
if ls /home/build/immortalwrt/packages/kucat/luci-theme-kucat*.ipk 1> /dev/null 2>&1; then
    # 将本地包路径添加到构建系统
    mkdir -p /home/build/immortalwrt/extra-packages-local
    cp /home/build/immortalwrt/packages/kucat/*.ipk /home/build/immortalwrt/extra-packages-local/
    # 使用本地包
    PACKAGES="$PACKAGES luci-theme-kucat"
    PACKAGES="$PACKAGES luci-app-kucat-config"
    PACKAGES="$PACKAGES luci-i18n-kucat-config-zh-cn"
fi

# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# SmartDNS 配置优化
if echo "$PACKAGES" | grep -q "luci-app-smartdns"; then
    echo "✅ 已选择 luci-app-smartdns，创建默认配置"
    mkdir -p /home/build/immortalwrt/files/etc/config
    # 可选：创建 SmartDNS 配置文件
    cat << 'SMARTDNS_EOF' > /home/build/immortalwrt/files/etc/config/smartdns
config smartdns
    option enabled '1'
    option server_name 'SmartDNS'
    option port '6053'
    option tcp_server '1'
    option ipv6_server '1'
    option dualstack_ipv6 '1'
    option prefetch_domain '1'
    option serve_expired '1'
    option cache_size '1024'
    option cache_persist '1'
    option log_level 'info'
    option log_file '/var/log/smartdns.log'
    option audit_enable '0'
    option redirect '1'  # 自动重定向 DNS 到 SmartDNS

config domain
    option name 'services.googleapis.cn'
    option ip '203.208.40.66'

config domain
    option name 'ssl.gstatic.com'
    option ip '203.208.40.66'
SMARTDNS_EOF
    echo "✅ SmartDNS 默认配置已创建"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# 显示已安装的 Kucat 包
echo "📦 Kucat 主题包列表:"
ls -lh /home/build/immortalwrt/packages/kucat/ 2>/dev/null || echo "无本地 Kucat 包"

make image PROFILE="generic" \
  PACKAGES="$PACKAGES" \
  FILES="/home/build/immortalwrt/files" \
  ROOTFS_PARTSIZE=$PROFILE \
  EXT4_IMGS=1 \
  SQUASHFS_IMGS=1 \
  TARGET_ROOTFS_EXT4FS=y \
  TARGET_ROOTFS_SQUASHFS=y \
  TARGET_IMAGES_GZIP=y

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
