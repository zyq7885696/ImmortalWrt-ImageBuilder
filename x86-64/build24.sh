#!/bin/bash
# Build script for ImmortalWrt 24.10.x
# Log file for debugging

source shell/custom-packages.sh
source shell/switch_repository.sh

echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting build.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

cd /home/build/immortalwrt

# ============= 强制启用内核 BBR 支持 (在构建前) ===============
echo "🚀 正在配置内核以支持 BBR..."

# 读取自定义路由器IP
CUSTOM_ROUTER_IP=$(cat /home/build/immortalwrt/files/etc/config/custom_router_ip.txt 2>/dev/null || echo "192.168.100.1")
echo "路由器管理地址: $CUSTOM_ROUTER_IP"

# 方法1: 直接修改 .config
cat >> .config << 'BBR_CONFIG'
# BBR Congestion Control
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_DEFAULT_NET_SCH="fq"
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_RENO=y
CONFIG_DEFAULT_TCP_CONG="bbr"
BBR_CONFIG

# 方法2: 修改内核配置文件
KERNEL_VERSION="6.6"
KERNEL_CONFIG="target/linux/x86/config-${KERNEL_VERSION}"

if [ -f "$KERNEL_CONFIG" ]; then
    grep -q "CONFIG_TCP_CONG_BBR=y" "$KERNEL_CONFIG" || echo "CONFIG_TCP_CONG_BBR=y" >> "$KERNEL_CONFIG"
    grep -q "CONFIG_NET_SCH_FQ=y" "$KERNEL_CONFIG" || echo "CONFIG_NET_SCH_FQ=y" >> "$KERNEL_CONFIG"
    echo "✅ 内核配置文件已更新: $KERNEL_CONFIG"
fi

# 重新生成配置
make defconfig > /dev/null 2>&1

# 验证 BBR 配置
echo "验证内核配置:"
grep -E "CONFIG_TCP_CONG_BBR|CONFIG_DEFAULT_BBR|CONFIG_NET_SCH_FQ" .config || echo "⚠️ BBR 配置验证中"

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

# ============= 创建网络配置脚本 (增强版) ===============
echo "🔧 创建网络自动配置脚本"
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

cat << 'NETWORK_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
#!/bin/sh

LOG_FILE="/tmp/network-auto-config.log"
echo "$(date): Starting network auto-config script" >> $LOG_FILE

# 读取PPPoE配置
if [ -f /etc/config/pppoe-settings ]; then
    . /etc/config/pppoe-settings
    echo "$(date): Loaded PPPoE settings - ENABLE_PPPOE=$enable_pppoe" >> $LOG_FILE
fi

# 读取自定义路由器IP
CUSTOM_IP=""
if [ -f /etc/config/custom_router_ip.txt ]; then
    CUSTOM_IP=$(cat /etc/config/custom_router_ip.txt)
fi

if [ -z "$CUSTOM_IP" ]; then
    CUSTOM_IP="192.168.100.1"
fi

echo "$(date): Using router IP: $CUSTOM_IP" >> $LOG_FILE

# ============= 禁用 IPv6 ===============
echo "$(date): Disabling IPv6" >> $LOG_FILE

# 修改系统配置禁用 IPv6
uci set network.globals='globals'
uci set network.globals.ula_prefix=''
uci commit network

cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl -p > /dev/null 2>&1

# 禁用 IPv6 内核模块
cat > /etc/modules.d/disable-ipv6 << EOF
blacklist ipv6
blacklist sit
EOF

# 检测网卡数量
NIC_COUNT=$(ls /sys/class/net/ 2>/dev/null | grep -E '^eth[0-9]+$' | wc -l)
[ "$NIC_COUNT" -eq 0 ] && NIC_COUNT=$(ls /sys/class/net/ 2>/dev/null | grep -v 'lo' | wc -l)
echo "$(date): Detected $NIC_COUNT NIC(s)" >> $LOG_FILE

# ============= 网络配置 =============
if [ "$NIC_COUNT" -eq 1 ]; then
    # 单网卡处理
    NIC_NAME=$(ls /sys/class/net/ | grep -E '^eth[0-9]+' | head -1)
    [ -z "$NIC_NAME" ] && NIC_NAME=$(ls /sys/class/net/ | grep -v 'lo' | head -1)
    
    uci set network.lan=interface
    uci set network.lan.device="$NIC_NAME"
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$CUSTOM_IP"
    uci set network.lan.netmask='255.255.255.0'
    
    # 禁用 WAN
    uci set network.wan=interface
    uci set network.wan.proto='none'
    
    echo "$(date): Single NIC configured with IP: $CUSTOM_IP on $NIC_NAME" >> $LOG_FILE
else
    # 多网卡处理
    if [ "$enable_pppoe" = "yes" ]; then
        uci set network.wan=interface
        uci set network.wan.device='eth0'
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.ipv6='0'
        echo "$(date): PPPoE configured on eth0" >> $LOG_FILE
    else
        uci set network.wan=interface
        uci set network.wan.device='eth0'
        uci set network.wan.proto='dhcp'
        uci set network.wan.ipv6='0'
    fi
    
    uci set network.lan=interface
    uci set network.lan.device='eth1'
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$CUSTOM_IP"
    uci set network.lan.netmask='255.255.255.0'
    
    echo "$(date): Multiple NICs configured, LAN IP: $CUSTOM_IP" >> $LOG_FILE
fi

# ============= 禁用 DHCP ===============
uci set dhcp.lan=dhcp
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dynamicdhcp='0'

# 禁用 odhcpd (IPv6 DHCP)
if [ -f /etc/init.d/odhcpd ]; then
    /etc/init.d/odhcpd disable
    /etc/init.d/odhcpd stop
fi

# 提交配置
uci commit network
uci commit dhcp

# 重启服务
/etc/init.d/network restart
/etc/init.d/dnsmasq restart 2>/dev/null

echo "$(date): Network config completed (IPv6: DISABLED, DHCP: DISABLED)" >> $LOG_FILE
exit 0
NETWORK_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
echo "✅ 网络配置脚本已创建 (IPv6 和 DHCP 已禁用)"

# 保存自定义路由器IP到文件（如果从 workflow 传入）
if [ -n "$CUSTOM_ROUTER_IP" ] && [ "$CUSTOM_ROUTER_IP" != "192.168.100.1" ]; then
    echo "$CUSTOM_ROUTER_IP" > /home/build/immortalwrt/files/etc/config/custom_router_ip.txt
    echo "✅ 自定义路由器IP已保存: $CUSTOM_ROUTER_IP"
fi

# ============= BBR 运行时配置脚本 ===============
echo "🚀 正在配置 BBR 运行时脚本..."

cat << 'BBR_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/98-bbr-enable
#!/bin/sh
# 启用 BBR 拥塞控制算法

sleep 3

# 等待网络初始化
for i in 1 2 3 4 5; do
    if [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
        break
    fi
    sleep 1
done

if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    AVAILABLE=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
    echo "$(date): Available congestion controls: $AVAILABLE" >> /tmp/bbr-setup.log
    
    if echo "$AVAILABLE" | grep -q "bbr"; then
        echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control
        echo "fq" > /proc/sys/net/core/default_qdisc 2>/dev/null
        
        # 持久化配置
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        
        sysctl -p > /dev/null 2>&1
        
        CURRENT=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
        echo "$(date): BBR enabled, current: $CURRENT" >> /tmp/bbr-setup.log
        echo "✅ BBR 加速已启用 (当前算法: $CURRENT)" > /dev/console
    else
        echo "$(date): BBR not available. Available: $AVAILABLE" >> /tmp/bbr-setup.log
        echo "⚠️ BBR 不可用，可用的算法: $AVAILABLE" > /dev/console
    fi
fi
exit 0
BBR_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/98-bbr-enable
echo "✅ BBR 运行时脚本已创建"

# ============= 第三方包处理 =============
if [ -n "$CUSTOM_PACKAGES" ]; then
    echo "🔄 同步第三方软件仓库..."
    git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
    echo "✅ Run files copied"
    sh shell/prepare-packages.sh
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

# 设置默认主题
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

# ============= 重新配置并构建 =============
cd /home/build/immortalwrt

# 更新 feeds
./scripts/feeds update -a > /dev/null 2>&1
./scripts/feeds install -a > /dev/null 2>&1

# 确保 BBR 配置在 .config 中
echo "确保 BBR 内核配置已启用..."
echo "CONFIG_TCP_CONG_BBR=y" >> .config
echo "CONFIG_DEFAULT_BBR=y" >> .config
echo "CONFIG_NET_SCH_FQ=y" >> .config
echo "CONFIG_DEFAULT_TCP_CONG=\"bbr\"" >> .config

# 重新生成配置
make defconfig > /dev/null 2>&1

# 验证 BBR 配置
echo ""
echo "========== 内核配置验证 =========="
grep "CONFIG_TCP_CONG_BBR" .config || echo "⚠️ CONFIG_TCP_CONG_BBR 未设置"
grep "CONFIG_DEFAULT_BBR" .config || echo "⚠️ CONFIG_DEFAULT_BBR 未设置"
grep "CONFIG_NET_SCH_FQ" .config || echo "⚠️ CONFIG_NET_SCH_FQ 未设置"
echo "=================================="

# 构建固件
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
echo "✅ 固件已生成 (仅 squashfs 格式)"
echo "✅ IPv6 已禁用"
echo "✅ DHCPv4 已禁用"
echo "✅ BBR 支持已配置到内核"
echo "=========================================="

# 显示固件位置
echo "📦 固件位置:"
find /home/build/immortalwrt/bin -name "*.img" -o -name "*.gz" 2>/dev/null | head -10

exit 0
