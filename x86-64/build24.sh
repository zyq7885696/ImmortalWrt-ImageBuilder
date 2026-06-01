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

# ============= 自动检测并下载最新 Kucat 主题 ===============
echo "🎨 正在检测最新 Kucat 主题版本..."

# 获取最新 release 信息
get_latest_kucat_version() {
    local repo="sirpdboy/luci-theme-kucat"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    
    echo "正在从 GitHub API 获取最新版本信息..."
    
    # 获取最新 release 数据
    local release_data=$(curl -s "${api_url}")
    
    # 检查 API 是否成功
    if echo "$release_data" | grep -q "API rate limit exceeded"; then
        echo "⚠️ GitHub API 限流，使用备用 URL 模式"
        return 1
    fi
    
    if echo "$release_data" | grep -q "Not Found"; then
        echo "❌ 未找到 Kucat 主题仓库"
        return 1
    fi
    
    # 提取 tag_name
    local tag_name=$(echo "$release_data" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    
    if [ -n "$tag_name" ]; then
        echo "✅ 最新版本: ${tag_name}"
        # 提取版本号（去除 v 前缀）
        echo "${tag_name}" | sed 's/^v//'
        return 0
    else
        echo "⚠️ 无法解析版本号，使用默认版本"
        return 1
    fi
}

# 获取最新版本号
KUCAT_VERSION=$(get_latest_kucat_version)
if [ -z "$KUCAT_VERSION" ]; then
    KUCAT_VERSION="2.2.0"  # 默认版本
    echo "使用默认版本: ${KUCAT_VERSION}"
fi

# 构建下载 URL 的函数
build_kucat_url() {
    local pkg_type=$1
    local base_url="https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download"
    
    case $pkg_type in
        "theme")
            echo "${base_url}/luci-theme-kucat_${KUCAT_VERSION}_all.ipk"
            ;;
        "app")
            # 尝试获取最新的 app 版本号（可能包含日期）
            echo "${base_url}/luci-app-kucat-config_${KUCAT_VERSION}-r$(date +%Y%m%d)_all.ipk"
            ;;
        "i18n")
            echo "${base_url}/luci-i18n-kucat-config-zh-cn_0_all.ipk"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 尝试多个 URL 模式下载
download_kucat_with_fallback() {
    local pkg_name=$1
    local urls=("${@:2}")
    local output_path="/home/build/immortalwrt/packages/kucat/${pkg_name}.ipk"
    
    mkdir -p /home/build/immortalwrt/packages/kucat
    
    for url in "${urls[@]}"; do
        echo "尝试下载: ${url}"
        wget -q --show-progress --timeout=30 --tries=2 -O "$output_path" "$url"
        if [ $? -eq 0 ] && [ -s "$output_path" ]; then
            echo "✅ 下载成功: ${pkg_name}"
            echo "$output_path" >> /home/build/immortalwrt/packages/kucat/kucat_packages.txt
            return 0
        else
            echo "⚠️ 下载失败，尝试下一个 URL"
            rm -f "$output_path"
        fi
    done
    
    echo "❌ 所有 URL 都下载失败: ${pkg_name}"
    return 1
}

# 获取实际的 release assets 列表
get_release_assets() {
    local repo="sirpdboy/luci-theme-kucat"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    
    curl -s "${api_url}" | grep -o '"browser_download_url": "[^"]*"' | cut -d'"' -f4
}

echo "正在获取 Kucat 主题最新资源列表..."
RELEASE_URLS=$(get_release_assets)

if [ -n "$RELEASE_URLS" ]; then
    echo "✅ 从 GitHub API 获取到资源列表"
    
    # 从 API 获取的实际 URL 中筛选并下载
    echo "$RELEASE_URLS" | while read -r url; do
        if echo "$url" | grep -q "luci-theme-kucat.*\.ipk"; then
            output_path="/home/build/immortalwrt/packages/kucat/$(basename "$url")"
            wget -q --show-progress -O "$output_path" "$url"
            echo "✅ 下载主题: $(basename "$url")"
            echo "$output_path" >> /home/build/immortalwrt/packages/kucat/kucat_packages.txt
        elif echo "$url" | grep -q "luci-app-kucat-config.*\.ipk"; then
            output_path="/home/build/immortalwrt/packages/kucat/$(basename "$url")"
            wget -q --show-progress -O "$output_path" "$url"
            echo "✅ 下载配置: $(basename "$url")"
            echo "$output_path" >> /home/build/immortalwrt/packages/kucat/kucat_packages.txt
        elif echo "$url" | grep -q "luci-i18n-kucat-config-zh-cn.*\.ipk"; then
            output_path="/home/build/immortalwrt/packages/kucat/$(basename "$url")"
            wget -q --show-progress -O "$output_path" "$url"
            echo "✅ 下载语言包: $(basename "$url")"
            echo "$output_path" >> /home/build/immortalwrt/packages/kucat/kucat_packages.txt
        fi
    done
else
    echo "⚠️ API 获取失败，使用预定义 URL 模式尝试下载"
    
    # 预定义 URL 模式（多个备选）
    THEME_URLS=(
        "https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat_${KUCAT_VERSION}_all.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/download/${KUCAT_VERSION}/luci-theme-kucat_${KUCAT_VERSION}_all.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat_all.ipk"
    )
    
    APP_URLS=(
        "https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-app-kucat-config_${KUCAT_VERSION}-r$(date +%Y%m%d)_all.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/download/${KUCAT_VERSION}/luci-app-kucat-config_${KUCAT_VERSION}_all.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-app-kucat-config_all.ipk"
    )
    
    I18N_URLS=(
        "https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-i18n-kucat-config-zh-cn_0_all.ipk"
        "https://github.com/sirpdboy/luci-theme-kucat/releases/download/${KUCAT_VERSION}/luci-i18n-kucat-config-zh-cn_0_all.ipk"
    )
    
    # 下载主题
    download_kucat_with_fallback "luci-theme-kucat" "${THEME_URLS[@]}"
    
    # 下载配置应用
    download_kucat_with_fallback "luci-app-kucat-config" "${APP_URLS[@]}"
    
    # 下载语言包
    download_kucat_with_fallback "luci-i18n-kucat-config-zh-cn" "${I18N_URLS[@]}"
fi

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
if [ -f /home/build/immortalwrt/packages/kucat/luci-theme-kucat*.ipk ]; then
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
