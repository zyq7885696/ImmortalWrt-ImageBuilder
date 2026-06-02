#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# ============= 启用内核 BBR 支持 ===============
echo "🚀 正在配置内核以支持 BBR..."

# 方法1: 修改内核配置文件
KERNEL_CONFIG="/home/build/immortalwrt/target/linux/x86/config-6.6"
if [ -f "$KERNEL_CONFIG" ]; then
    # 检查是否已配置 BBR
    if ! grep -q "CONFIG_TCP_CONG_BBR=y" "$KERNEL_CONFIG"; then
        cat >> "$KERNEL_CONFIG" << 'KERNEL_EOF'

# BBR Congestion Control
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_DEFAULT_NET_SCH="fq"
KERNEL_EOF
        echo "✅ 内核 BBR 支持已添加到 config-6.6"
    fi
fi

# 方法2: 修改 .config 文件
if [ -f "/home/build/immortalwrt/.config" ]; then
    # 启用 BBR 相关配置
    sed -i 's/# CONFIG_TCP_CONG_BBR is not set/CONFIG_TCP_CONG_BBR=y/' /home/build/immortalwrt/.config 2>/dev/null
    echo "CONFIG_TCP_CONG_BBR=y" >> /home/build/immortalwrt/.config
    echo "CONFIG_DEFAULT_BBR=y" >> /home/build/immortalwrt/.config
    echo "CONFIG_NET_SCH_FQ=y" >> /home/build/immortalwrt/.config
    echo "CONFIG_DEFAULT_NET_SCH=\"fq\"" >> /home/build/immortalwrt/.config
fi

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

# ============= 禁用 IPv6 ===============
echo "$(date): Disabling IPv6 globally" >> $LOG_FILE

# 禁用 IPv6
uci set network.globals='globals'
uci set network.globals.ula_prefix=''
uci commit network

# 系统级禁用 IPv6
cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

sysctl -p > /dev/null 2>&1

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
    
    # 配置单网卡为LAN口，使用静态IP，禁用DHCP
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
EOF
    
    # 禁用 DHCP
    uci set dhcp.lan.ignore='1'
    uci commit dhcp
    
    echo "$(date): Single NIC configured with static IP: $CUSTOM_IP (DHCP disabled)" >> $LOG_FILE
    
else
    echo "$(date): Multiple NICs detected ($NIC_COUNT), using standard configuration" >> $LOG_FILE
    
    # 多网卡情况
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
        option ipv6 '0'

config interface 'lan'
        option device 'eth1'
        option proto 'static'
        option ipaddr '$CUSTOM_IP'
        option netmask '255.255.255.0'
EOF
        echo "$(date): PPPoE configured on eth0 (IPv6 disabled)" >> $LOG_FILE
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
        option ipv6 '0'

config interface 'lan'
        option device 'eth1'
        option proto 'static'
        option ipaddr '$CUSTOM_IP'
        option netmask '255.255.255.0'
EOF
    fi
    
    # 禁用 LAN 口 DHCP
    uci set dhcp.lan.ignore='1'
    uci commit dhcp
    
    echo "$(date): Multiple NIC configuration completed (DHCP disabled)" >> $LOG_FILE
fi

# 禁用 odhcpd (IPv6 DHCP)
if [ -f /etc/init.d/odhcpd ]; then
    /etc/init.d/odhcpd disable
    /etc/init.d/odhcpd stop
fi

# 提交配置
uci commit network

# 重启网络服务
/etc/init.d/network restart
/etc/init.d/dnsmasq restart 2>/dev/null

echo "$(date): Network configuration completed (IPv6: DISABLED, DHCP: DISABLED)" >> $LOG_FILE
exit 0
NETWORK_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
echo "✅ 网络自动配置脚本已创建 (IPv6 和 DHCP 已禁用)"

# 保存自定义路由器IP到文件
if [ -n "$CUSTOM_ROUTER_IP" ] && [ "$CUSTOM_ROUTER_IP" != "192.168.100.1" ]; then
    echo "$CUSTOM_ROUTER_IP" > /home/build/immortalwrt/files/etc/config/custom_router_ip.txt
    echo "✅ 自定义路由器IP已保存: $CUSTOM_ROUTER_IP"
fi

# ============= 添加 BBR 加速配置 ===============
echo "🚀 正在配置 BBR 加速..."

# 创建 BBR 配置脚本
cat << 'BBR_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/98-bbr-enable
#!/bin/sh
# 启用 BBR 拥塞控制算法

# 等待内核完全启动
sleep 2

# 检查并启用 BBR
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    # 检查内核是否支持 BBR
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        # 设置 BBR 为默认拥塞控制算法
        echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control
        
        # 设置 fq 队列
        echo "fq" > /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq_codel" > /proc/sys/net/core/default_qdisc
        
        # 永久保存配置
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        
        # 应用配置
        sysctl -p > /dev/null 2>&1
        
        echo "✅ BBR 加速已启用 (ImmortalWrt)" > /dev/console
        echo "$(date): BBR acceleration enabled successfully" >> /tmp/bbr-setup.log
    else
        echo "⚠️ 内核不支持 BBR，请确保编译时启用了 CONFIG_TCP_CONG_BBR" > /dev/console
        echo "$(date): BBR not supported by kernel" >> /tmp/bbr-setup.log
    fi
fi

exit 0
BBR_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/98-bbr-enable
echo "✅ BBR 配置脚本已创建"

# ============= 原有代码继续 =============

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= 下载指定版本的 Kucat 主题 ===============
echo "🎨 正在下载 Kucat 主题 v3.3.0..."

# 创建 Kucat 包目录
mkdir -p /home/build/immortalwrt/packages/kucat
mkdir -p /home/build/immortalwrt/bin/packages/x86_64/kucat

# 下载主题包
wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-theme-kucat_3.3.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk

wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-app-kucat-config_2.2.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk

wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-i18n-kucat-config-zh-cn_0_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

# 复制到本地仓库并创建索引
cp /home/build/immortalwrt/packages/kucat/*.ipk /home/build/immortalwrt/bin/packages/x86_64/kucat/

# 生成包索引
cd /home/build/immortalwrt/bin/packages/x86_64
./../../../../scripts/ipkg-make-index.sh ./kucat > ./kucat/Packages 2>/dev/null
gzip -9c ./kucat/Packages > ./kucat/Packages.gz 2>/dev/null

# 添加本地仓库
cat >> /home/build/immortalwrt/repositories.conf << 'REPO_EOF'
src/gz kucat file:///home/build/immortalwrt/bin/packages/x86_64/kucat
REPO_EOF

# 设置默认主题
cat << 'THEME_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
THEME_EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

echo "✅ Kucat 主题下载并配置完成"

# ============= 插件包列表 ===============
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES luci-app-ddns-go"
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"
PACKAGES="$PACKAGES luci-app-zerotier"
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"

# 添加 Kucat 包
if ls /home/build/immortalwrt/packages/kucat/luci-theme-kucat*.ipk 1> /dev/null 2>&1; then
    PACKAGES="$PACKAGES luci-theme-kucat"
    PACKAGES="$PACKAGES luci-app-kucat-config"
    PACKAGES="$PACKAGES luci-i18n-kucat-config-zh-cn"
fi

PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# OpenClash 内核下载
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    wget "$URL" -P /home/build/immortalwrt/packages/
fi

# 构建镜像 - 仅生成 squashfs 格式
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image..."
echo "包含的软件包: $PACKAGES"

make image PROFILE="generic" \
  PACKAGES="$PACKAGES" \
  FILES="/home/build/immortalwrt/files" \
  ROOTFS_PARTSIZE=$PROFILE \
  EXT4_IMGS=0 \
  SQUASHFS_IMGS=1 \
  TARGET_ROOTFS_EXT4FS=n \
  TARGET_ROOTFS_SQUASHFS=y \
  TARGET_IMAGES_GZIP=y

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
echo "✅ 固件已生成 (仅 squashfs 格式)"
echo "✅ IPv6 已禁用"
echo "✅ DHCPv4 已禁用"
echo "✅ BBR 支持已添加到内核配置"
