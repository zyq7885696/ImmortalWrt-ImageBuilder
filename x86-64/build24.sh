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

# ============= 创建单网卡自动配置脚本 ===============
echo "🔧 创建网络自动配置脚本（支持单网卡自动固定IP）"
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

# 读取用户设置的路由器管理地址
CUSTOM_ROUTER_IP=$(cat /home/build/immortalwrt/files/etc/config/custom_router_ip.txt 2>/dev/null || echo "192.168.100.1")
echo "路由器管理地址: $CUSTOM_ROUTER_IP"

cat << 'NETWORK_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
#!/bin/sh

# 日志文件
LOG_FILE="/tmp/network-auto-config.log"
echo "$(date): Starting network auto-config script" >> $LOG_FILE

# 读取PPPoE配置
if [ -f /etc/config/pppoe-settings ]; then
    source /etc/config/pppoe-settings
    echo "$(date): Loaded PPPoE settings - ENABLE_PPPOE=$enable_pppoe" >> $LOG_FILE
fi

# 读取自定义路由器IP
CUSTOM_IP=""
if [ -f /etc/config/custom_router_ip.txt ]; then
    CUSTOM_IP=$(cat /etc/config/custom_router_ip.txt)
    echo "$(date): Loaded custom router IP: $CUSTOM_IP" >> $LOG_FILE
fi

# 如果没读取到，使用默认值
if [ -z "$CUSTOM_IP" ]; then
    CUSTOM_IP="192.168.100.1"
    echo "$(date): Using default router IP: $CUSTOM_IP" >> $LOG_FILE
fi

# 检测网卡数量
NIC_COUNT=$(ls /sys/class/net/ 2>/dev/null | grep -E '^eth[0-9]+$' | wc -l)
echo "$(date): Detected $NIC_COUNT network interface(s)" >> $LOG_FILE

# 如果有网络接口但数量为0，尝试其他命名方式
if [ "$NIC_COUNT" -eq 0 ]; then
    NIC_COUNT=$(ls /sys/class/net/ 2>/dev/null | grep -v 'lo' | wc -l)
    echo "$(date): Alternative detection found $NIC_COUNT interface(s)" >> $LOG_FILE
fi

# 单网卡处理
if [ "$NIC_COUNT" -eq 1 ]; then
    echo "$(date): Single NIC detected, configuring static IP" >> $LOG_FILE
    
    # 获取网卡名称
    NIC_NAME=$(ls /sys/class/net/ 2>/dev/null | grep -E '^eth[0-9]+$' | head -1)
    if [ -z "$NIC_NAME" ]; then
        NIC_NAME=$(ls /sys/class/net/ 2>/dev/null | grep -v 'lo' | head -1)
    fi
    
    echo "$(date): Using network interface: $NIC_NAME" >> $LOG_FILE
    
    # 备份原始配置
    if [ -f /etc/config/network ]; then
        cp /etc/config/network /etc/config/network.backup
    fi
    
    # 配置单网卡为LAN口，使用静态IP
    cat > /etc/config/network << EOF
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config interface 'lan'
        option device '$NIC_NAME'
        option proto 'static'
        option ipaddr '$CUSTOM_IP'
        option netmask '255.255.255.0'
        option ip6assign '60'
EOF
    
    # 如果启用了PPPoE，单网卡模式下PPPoE可能不适用，给出警告
    if [ "$enable_pppoe" = "yes" ]; then
        echo "$(date): WARNING: PPPoE is enabled but single NIC detected. PPPoE may not work properly." >> $LOG_FILE
    fi
    
    echo "$(date): Single NIC configured with static IP: $CUSTOM_IP" >> $LOG_FILE
    
else
    echo "$(date): Multiple NICs detected ($NIC_COUNT), using standard configuration" >> $LOG_FILE
    
    # 多网卡情况，保持标准配置
    if [ "$enable_pppoe" = "yes" ]; then
        echo "$(date): Configuring PPPoE on WAN interface" >> $LOG_FILE
        
        cat > /etc/config/network << EOF
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config interface 'wan'
        option device 'eth0'
        option proto 'pppoe'
        option username '$pppoe_account'
        option password '$pppoe_password'
        option ipv6 'auto'

config interface 'wan6'
        option device 'eth0'
        option proto 'dhcpv6'

config interface 'lan'
        option device 'eth1'
        option proto 'static'
        option ipaddr '$CUSTOM_IP'
        option netmask '255.255.255.0'
        option ip6assign '60'
EOF
        echo "$(date): PPPoE configured on eth0" >> $LOG_FILE
    else
        echo "$(date): Using standard DHCP configuration on WAN" >> $LOG_FILE
        
        cat > /etc/config/network << EOF
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config interface 'wan'
        option device 'eth0'
        option proto 'dhcp'

config interface 'wan6'
        option device 'eth0'
        option proto 'dhcpv6'

config interface 'lan'
        option device 'eth1'
        option proto 'static'
        option ipaddr '$CUSTOM_IP'
        option netmask '255.255.255.0'
        option ip6assign '60'
EOF
    fi
    
    echo "$(date): Multiple NIC configuration completed" >> $LOG_FILE
fi

# 提交配置
uci commit network

# 重启网络服务
/etc/init.d/network restart

echo "$(date): Network configuration completed" >> $LOG_FILE
exit 0
NETWORK_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
echo "✅ 网络自动配置脚本已创建"

# 保存自定义路由器IP到文件
if [ -n "$CUSTOM_ROUTER_IP" ] && [ "$CUSTOM_ROUTER_IP" != "192.168.100.1" ]; then
    echo "$CUSTOM_ROUTER_IP" > /home/build/immortalwrt/files/etc/config/custom_router_ip.txt
    echo "✅ 自定义路由器IP已保存: $CUSTOM_ROUTER_IP"
fi

# ============= 原有代码继续 =============

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
cat << 'THEME_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
# 设置 Kucat 为默认主题
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
THEME_EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

echo "✅ Kucat 主题安装完成并设置为默认主题"
ls -lh /home/build/immortalwrt/packages/kucat/

# ============= imm仓库内的插件==============
# 定义所需安装的包列表
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 新增插件
PACKAGES="$PACKAGES luci-app-ddns-go"  # DDNS-GO
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"  # DDNS-GO 中文语言包
PACKAGES="$PACKAGES luci-app-zerotier"  # ZeroTier
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"  # ZeroTier 中文语言包
PACKAGES="$PACKAGES luci-app-openclash"  # OpenClash
# PACKAGES="$PACKAGES luci-app-smartdns"  # SmartDNS
# PACKAGES="$PACKAGES luci-i18n-smartdns-zh-cn"  # SmartDNS 中文语言包

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
