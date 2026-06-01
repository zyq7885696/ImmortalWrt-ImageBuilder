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

# ============= 添加 luci-theme-kucat 主题 =============
echo "🎨 正在拉取 luci-theme-kucat 主题..."

# 方法1: 从 sirpdboy 的 GitHub 仓库克隆源码
if [ ! -d "/home/build/immortalwrt/package/luci-theme-kucat" ]; then
    echo "Cloning luci-theme-kucat from sirpdboy GitHub..."
    git clone --depth=1 https://github.com/sirpdboy/luci-theme-kucat.git /home/build/immortalwrt/package/luci-theme-kucat
    if [ $? -eq 0 ]; then
        echo "✅ luci-theme-kucat 源码克隆成功"
        # 添加到自定义包列表
        CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-theme-kucat"
    else
        echo "⚠️ GitHub克隆失败，尝试备用方法..."
    fi
else
    echo "✅ luci-theme-kucat 目录已存在，跳过克隆"
    CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-theme-kucat"
fi

# 方法2: 如果克隆失败，直接从 Releases 下载 IPK
if [ ! -d "/home/build/immortalwrt/package/luci-theme-kucat" ]; then
    echo "尝试下载预编译的 IPK 文件..."
    mkdir -p /home/build/immortalwrt/packages
    
    # 获取最新版本号
    LATEST_VERSION=$(wget -qO- https://api.github.com/repos/sirpdboy/luci-theme-kucat/releases/latest | grep -oP '"tag_name": "\K[^"]+' | head -1)
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION="v1.5.6"  # 默认版本
    fi
    echo "最新版本: $LATEST_VERSION"
    
    # 尝试多个可能的下载链接
    IPK_URLS=(
        "https://github.com/sirpdboy/luci-theme-kucat/releases/download/${LATEST_VERSION}/luci-theme-kucat_${LATEST_VERSION#v}-20240302_all.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/download/v1.5.6/luci-theme-kucat_1.5.6-20240302_all.ipk"
    )
    
    for URL in "${IPK_URLS[@]}"; do
        echo "尝试下载: $URL"
        wget -q --timeout=10 --no-check-certificate "$URL" -O /home/build/immortalwrt/packages/luci-theme-kucat.ipk
        if [ $? -eq 0 ] && [ -f /home/build/immortalwrt/packages/luci-theme-kucat.ipk ] && [ -s /home/build/immortalwrt/packages/luci-theme-kucat.ipk ]; then
            echo "✅ luci-theme-kucat.ipk 下载成功"
            CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-theme-kucat"
            break
        fi
    done
fi

# 方法3: 使用 wget 直接下载到 files 目录（运行时安装）
if [ ! -d "/home/build/immortalwrt/package/luci-theme-kucat" ] && [ ! -f "/home/build/immortalwrt/packages/luci-theme-kucat.ipk" ]; then
    echo "准备在固件启动时自动下载安装..."
    mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
    cat > /home/build/immortalwrt/files/etc/uci-defaults/99-install-kucat << 'EOF'
#!/bin/sh
# 启动时下载并安装 kucat 主题
sleep 5
wget --no-check-certificate -q https://github.com/sirpdboy/luci-theme-kucat/releases/download/v1.5.6/luci-theme-kucat_1.5.6-20240302_all.ipk -O /tmp/kucat.ipk
if [ -f /tmp/kucat.ipk ]; then
    opkg install /tmp/kucat.ipk
    rm /tmp/kucat.ipk
    # 设置为默认主题
    uci set luci.main.mediaurlbase='/luci-static/kucat'
    uci commit luci
    echo "✅ kucat 主题安装完成"
fi
exit 0
EOF
    chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-install-kucat
    echo "✅ 已添加启动时自动安装 kucat 主题的脚本"
fi

# 检查主题是否成功添加
if echo "$CUSTOM_PACKAGES" | grep -q "luci-theme-kucat"; then
    echo "✅ luci-theme-kucat 已成功添加到构建列表"
else
    echo "⚠️ luci-theme-kucat 未添加到构建列表，将在启动时安装"
fi

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

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 显示主题包含情况
echo "📦 最终包含的主题:"
echo "$PACKAGES" | tr ' ' '\n' | grep "luci-theme"

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

# 设置默认主题（如果 kucat 可用）
if echo "$PACKAGES" | grep -q "luci-theme-kucat"; then
    mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
    cat > /home/build/immortalwrt/files/etc/uci-defaults/99-set-kucat-theme << 'EOF'
#!/bin/sh
# 设置 kucat 为默认主题
if uci get luci.main.mediaurlbase >/dev/null 2>&1; then
    uci set luci.main.mediaurlbase='/luci-static/kucat'
    uci commit luci
fi
exit 0
EOF
    chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-set-kucat-theme
    echo "✅ 已设置 kucat 为默认主题"
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
