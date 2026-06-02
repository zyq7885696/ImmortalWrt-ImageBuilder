#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
# 该文件实际为imagebuilder容器内的build.sh

# 下载 run 文件仓库
echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

# 拷贝 run/arm64 下所有 run 文件和ipk文件 到 extra-packages 目录
mkdir -p /home/build/immortalwrt/extra-packages
cp -r /tmp/store-run-repo/run/arm64/* /home/build/immortalwrt/extra-packages/

echo "✅ Run files copied to extra-packages:"
ls -lh /home/build/immortalwrt/extra-packages/*.run
# 解压并拷贝ipk到packages目录
sh shell/prepare-packages.sh
ls -lah /home/build/immortalwrt/packages/
# 添加架构优先级信息
sed -i '1i\
arch aarch64_generic 10\n\
arch aarch64_cortex-a53 15' repositories.conf

# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"

echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入pppoe变量————>pppoe-settings文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."

# 定义所需安装的包列表
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
# 移除 luci-theme-argon
# PACKAGES="$PACKAGES luci-theme-argon"
# PACKAGES="$PACKAGES luci-app-argon-config"
# PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
# 移除 diskman
# PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
# 移除 ttyd
# PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器（可选保留）
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 添加 DDNS-GO
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"
# 添加 ZeroTier
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"

# 下载并安装 Kucat 主题和相关包
echo "🔄 正在下载 Kucat 主题及相关包..."
mkdir -p /home/build/immortalwrt/kucat-packages
cd /home/build/immortalwrt/kucat-packages

# 下载 Kucat 主题
wget https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk
# 下载 Kucat 配置应用
wget https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk
# 下载 Kucat 中文语言包
wget https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

# 将下载的 ipk 文件复制到 packages 目录
cp *.ipk /home/build/immortalwrt/packages/
cd /home/build/immortalwrt

echo "✅ Kucat 主题包已下载并复制到 packages 目录"

# 第三方软件包 合并
if [ "$PROFILE" = "glinet_gl-axt1800" ] || [ "$PROFILE" = "glinet_gl-ax1800" ]; then
    # 这2款 暂时不支持第三方插件的集成 snapshot版本太高
    echo "Model:$PROFILE not support third-parted packages"
    PACKAGES="$PACKAGES -luci-i18n-diskman-zh-cn"
else
    echo "Other Model:$PROFILE"
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 添加 OpenClash
echo "✅ 添加 luci-app-openclash"
PACKAGES="$PACKAGES luci-app-openclash"

# 创建 OpenClash 内核目录
mkdir -p files/etc/openclash/core

# Download clash_meta for ARM64 (Nx30 pro 使用 aarch64)
META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
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

# 添加 Kucat 包到安装列表
PACKAGES="$PACKAGES luci-theme-kucat luci-app-kucat-config luci-i18n-kucat-config-zh-cn"

# 创建 UCI 默认配置脚本，设置 Kucat 为默认主题
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-default-theme
#!/bin/sh
# 设置 Kucat 为默认主题
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-default-theme

echo "✅ 已设置 Kucat 为默认主题"

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
