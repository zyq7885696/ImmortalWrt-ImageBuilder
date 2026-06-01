#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# ============= 下载并安装 Kucat 主题（最新版检查 + 默认主题）==============
echo "🔍 检查并拉取最新 Kucat 主题..."
mkdir -p /home/build/immortalwrt/packages
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

# 自动获取最新版下载链接
KUCAT_THEME_URL=$(curl -s https://api.github.com/repos/sirpdboy/luci-theme-kucat/releases/latest | grep "browser_download_url.*luci-theme-kucat.*all.ipk" | cut -d '"' -f 4)
KUCAT_CONFIG_URL=$(curl -s https://api.github.com/repos/sirpdboy/luci-theme-kucat/releases/latest | grep "browser_download_url.*luci-app-kucat-config.*ipk" | cut -d '"' -f 4)
KUCAT_I18N_URL=$(curl -s https://api.github.com/repos/sirpdboy/luci-theme-kucat/releases/latest | grep "browser_download_url.*luci-i18n-kucat-config-zh-cn.*ipk" | cut -d '"' -f 4)

# 下载IPK包
wget -q -P /home/build/immortalwrt/packages/ ${KUCAT_THEME_URL}
wget -q -P /home/build/immortalwrt/packages/ ${KUCAT_CONFIG_URL}
wget -q -P /home/build/immortalwrt/packages/ ${KUCAT_I18N_URL}

# 设置 Kucat 为默认主题（开机自动生效）
cat > /home/build/immortalwrt/files/etc/uci-defaults/90-kucat-default << EOF
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci set luci.main.theme='kucat'
uci commit luci
EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/90-kucat-default

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

# ============= imm仓库内的插件（已删除argon，新增需求包）==============
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"

# Kucat 主题（已下载IPK）
PACKAGES="$PACKAGES luci-theme-kucat"
PACKAGES="$PACKAGES luci-app-kucat-config"
PACKAGES="$PACKAGES luci-i18n-kucat-config-zh-cn"

# 基础必备
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 新增需求：ddns-go + zerotier + smartdns + openclash（全中文）
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"
PACKAGES="$PACKAGES luci-i18n-smartdns-zh-cn"
PACKAGES="$PACKAGES luci-i18n-openclash-zh-cn"

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

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
