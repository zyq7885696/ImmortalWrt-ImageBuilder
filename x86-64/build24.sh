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
mkdir -p /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# ============= 集成 kucat 主题 =============
echo "🔄 正在下载并集成 kucat 主题..."
mkdir -p /home/build/immortalwrt/kucat-packages
cd /home/build/immortalwrt/kucat-packages

# 下载 kucat 主题和插件
echo "下载 luci-theme-kucat..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat_2.2.0_all.ipk

echo "下载 luci-i18n-kucat-config-zh-cn..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-i18n-kucat-config-zh-cn_0_all.ipk

echo "下载 luci-app-kucat-config..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-app-kucat-config_2.2.0-r20260227_all.ipk

# 方法：直接解压到files目录（正确的方式）
echo "正在解压主题包到文件系统..."
for ipk in *.ipk; do
    if [ -f "$ipk" ]; then
        echo "处理 $ipk..."
        # 创建临时目录
        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"
        
        # 解压 ipk (ar归档格式)
        ar x "/home/build/immortalwrt/kucat-packages/$ipk"
        
        # 解压 data.tar.gz 或 data.tar.xz
        if [ -f data.tar.gz ]; then
            tar -xzf data.tar.gz -C /home/build/immortalwrt/files/
            echo "✅ 已解压 $ipk 的内容"
        elif [ -f data.tar.xz ]; then
            tar -xJf data.tar.xz -C /home/build/immortalwrt/files/
            echo "✅ 已解压 $ipk 的内容"
        else
            echo "⚠️ 找不到数据文件"
        fi
        
        cd /home/build/immortalwrt
        rm -rf "$TEMP_DIR"
    fi
done

# 创建UCI预设，将kucat设置为默认主题
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
# 设置kucat为默认主题（无需sleep，uci-defaults执行时机系统已就绪）
if [ -d "/www/luci-static/kucat" ]; then
    uci set luci.main.mediaurlbase='/luci-static/kucat'
    uci commit luci
    echo "✅ Kucat主题已设置为默认"
else
    echo "⚠️ Kucat主题目录不存在"
fi
exit 0
EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

# 验证文件已正确复制
echo "验证主题文件："
find /home/build/immortalwrt/files -name "*kucat*" -type d 2>/dev/null
echo "✅ Kucat主题集成完成"

cd /home/build/immortalwrt

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -rf /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run 2>/dev/null
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
# 基础luci
PACKAGES="$PACKAGES luci luci-base"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# ============ 新增 SmartDNS 插件 ============
PACKAGES="$PACKAGES luci-app-smartdns luci-i18n-smartdns-zh-cn smartdns"

# ============ 新增插件 ============
# MOSDNS
PACKAGES="$PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn mosdns"

# OpenClash
PACKAGES="$PACKAGES luci-app-openclash"

# ZeroTier
PACKAGES="$PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn zerotier"

# DDNS-GO
PACKAGES="$PACKAGES luci-app-ddns-go luci-i18n-ddns-go-zh-cn ddns-go"

# ======== shell/custom-packages.sh =======
# 合并第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn docker docker-compose"
    echo "Adding Docker packages"
fi

# 为 OpenClash 添加内核文件
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 OpenClash 内核和配置文件"
    
    # 创建 OpenClash 目录
    mkdir -p /home/build/immortalwrt/files/etc/openclash/core
    mkdir -p /home/build/immortalwrt/files/etc/openclash/config
    
    # 下载 clash_meta 内核
    echo "正在下载 Clash Meta 内核..."
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    if wget -q --show-progress "$META_URL" -O - | tar xOvz > /home/build/immortalwrt/files/etc/openclash/core/clash_meta; then
        chmod +x /home/build/immortalwrt/files/etc/openclash/core/clash_meta
        echo "✅ Clash Meta 内核下载完成"
    else
        echo "⚠️ Clash Meta 内核下载失败"
    fi
    
    # 下载 GeoIP 库
    echo "正在下载规则库..."
    wget -q --show-progress https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O /home/build/immortalwrt/files/etc/openclash/GeoIP.dat
    wget -q --show-progress https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O /home/build/immortalwrt/files/etc/openclash/GeoSite.dat
    
    echo "✅ OpenClash 文件添加完成"
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 为 MOSDNS 添加默认配置
if echo "$PACKAGES" | grep -q "luci-app-mosdns"; then
    echo "✅ 已选择 luci-app-mosdns，创建配置目录"
    mkdir -p /home/build/immortalwrt/files/etc/mosdns
fi

# 为 ZeroTier 创建配置目录
if echo "$PACKAGES" | grep -q "luci-app-zerotier"; then
    echo "✅ 已选择 luci-app-zerotier，创建配置目录"
    mkdir -p /home/build/immortalwrt/files/etc/zerotier
fi

# 执行构建
echo "开始执行 make image..."
if make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE="$PROFILE" 2>&1 | tee /tmp/make_output.log; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建成功！"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建失败！"
    tail -50 /tmp/make_output.log
    exit 1
fi
