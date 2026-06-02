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

# 创建pppoe配置文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# ============= 创建网络配置脚本 (25.12 新版) ===============
echo "🔧 创建网络自动配置脚本（适配 ImmortalWrt 25.12）"
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

# 读取用户设置的路由器管理地址
CUSTOM_ROUTER_IP=$(cat /home/build/immortalwrt/files/etc/config/custom_router_ip.txt 2>/dev/null || echo "192.168.100.1")
echo "路由器管理地址: $CUSTOM_ROUTER_IP"

cat << 'NETWORK_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
#!/bin/sh

# 加载必要的库
. /lib/functions.sh
. /lib/functions/uci-defaults.sh
. /lib/functions/system.sh

LOG_FILE="/tmp/network-auto-config.log"
echo "$(date): Starting network auto-config for ImmortalWrt 25.12" >> $LOG_FILE

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

if [ -z "$CUSTOM_IP" ]; then
    CUSTOM_IP="192.168.100.1"
    echo "$(date): Using default router IP: $CUSTOM_IP" >> $LOG_FILE
fi

# 检测网卡数量（25.12 使用 DSA 架构）
NIC_COUNT=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|lan|wan)[0-9]*$' | grep -v 'lo' | wc -l)
echo "$(date): Detected $NIC_COUNT network interface(s)" >> $LOG_FILE

# 单网卡处理
if [ "$NIC_COUNT" -eq 1 ]; then
    echo "$(date): Single NIC detected, configuring static IP" >> $LOG_FILE
    
    # 获取网卡名称
    NIC_NAME=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|lan|wan)' | head -1)
    
    # 使用新版 API 配置
    ucidef_set_interface_lan "$NIC_NAME"
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$CUSTOM_IP"
    uci set network.lan.netmask='255.255.255.0'
    
    echo "$(date): Single NIC configured with static IP: $CUSTOM_IP on $NIC_NAME" >> $LOG_FILE
    
else
    echo "$(date): Multiple NICs detected ($NIC_COUNT), using standard configuration" >> $LOG_FILE
    
    # 多网卡：默认 eth0 为 WAN，eth1 为 LAN
    WAN_DEV="eth0"
    LAN_DEV="eth1"
    
    # 验证设备存在性
    if [ ! -d "/sys/class/net/$WAN_DEV" ]; then
        WAN_DEV=$(ls /sys/class/net/ | grep -E '^wan' | head -1)
    fi
    if [ ! -d "/sys/class/net/$LAN_DEV" ]; then
        LAN_DEV=$(ls /sys/class/net/ | grep -E '^lan' | head -1)
    fi
    
    if [ "$enable_pppoe" = "yes" ]; then
        echo "$(date): Configuring PPPoE on $WAN_DEV" >> $LOG_FILE
        
        # 使用新版 API 配置
        ucidef_set_interface_lan "$LAN_DEV"
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr="$CUSTOM_IP"
        uci set network.lan.netmask='255.255.255.0'
        
        ucidef_set_interface_wan "$WAN_DEV"
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        
        # 配置 IPv6
        ucidef_set_interface_wan6 "$WAN_DEV"
        uci set network.wan6.proto='dhcpv6'
        
        echo "$(date): PPPoE configured on $WAN_DEV" >> $LOG_FILE
    else
        echo "$(date): Using DHCP on WAN" >> $LOG_FILE
        
        ucidef_set_interfaces_lan_wan "$LAN_DEV" "$WAN_DEV"
        uci set network.lan.ipaddr="$CUSTOM_IP"
        uci set network.lan.netmask='255.255.255.0'
    fi
fi

# 提交配置
uci commit network

# 重启网络服务（25.12 使用 service 命令）
service network restart

echo "$(date): Network configuration completed for ImmortalWrt 25.12" >> $LOG_FILE
exit 0
NETWORK_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-fix-network
echo "✅ 网络自动配置脚本已创建 (ImmortalWrt 25.12 兼容)"

# 保存自定义路由器IP到文件
if [ -n "$CUSTOM_ROUTER_IP" ] && [ "$CUSTOM_ROUTER_IP" != "192.168.100.1" ]; then
    echo "$CUSTOM_ROUTER_IP" > /home/build/immortalwrt/files/etc/config/custom_router_ip.txt
    echo "✅ 自定义路由器IP已保存: $CUSTOM_ROUTER_IP"
fi

# ============= 添加 BBR 加速配置（完全兼容） ===============
echo "🚀 正在配置 BBR 加速..."

cat << 'BBR_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/98-bbr-enable
#!/bin/sh
# 启用 BBR 拥塞控制算法 - 兼容 4.9+ 内核（包括 6.x）

if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
        # 设置 BBR
        echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control
        
        # 持久化配置
        if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
            echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        else
            sed -i 's/net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control = bbr/' /etc/sysctl.conf
        fi
        
        # 配置 fq 队列
        if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
            echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        else
            sed -i 's/net.core.default_qdisc.*/net.core.default_qdisc = fq/' /etc/sysctl.conf
        fi
        
        sysctl -p > /dev/null 2>&1
        
        echo "✅ BBR 加速已启用 (ImmortalWrt 25.12)" > /dev/console
        echo "$(date): BBR acceleration enabled successfully" >> /tmp/bbr-setup.log
    else
        echo "⚠️ 内核不支持 BBR" > /dev/console
    fi
fi
exit 0
BBR_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/98-bbr-enable
echo "✅ BBR 配置脚本已创建"

# ============= 原有代码继续（无需修改） =============

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= Kucat 主题下载（无需修改） ===============
echo "🎨 正在下载 Kucat 主题 v3.3.0..."
mkdir -p /home/build/immortalwrt/packages/kucat

wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-theme-kucat_3.3.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk

wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-app-kucat-config_2.2.0-r20260227_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk

wget --no-check-certificate -O /home/build/immortalwrt/packages/kucat/luci-i18n-kucat-config-zh-cn_0_all.ipk \
    https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

cat << 'THEME_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
THEME_EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
echo "✅ Kucat 主题安装完成"

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

if ls /home/build/immortalwrt/packages/kucat/luci-theme-kucat*.ipk 1> /dev/null 2>&1; then
    mkdir -p /home/build/immortalwrt/extra-packages-local
    cp /home/build/immortalwrt/packages/kucat/*.ipk /home/build/immortalwrt/extra-packages-local/
    PACKAGES="$PACKAGES luci-theme-kucat"
    PACKAGES="$PACKAGES luci-app-kucat-config"
    PACKAGES="$PACKAGES luci-i18n-kucat-config-zh-cn"
fi

PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
fi

# OpenClash 内核下载（路径需注意）
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

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image..."
echo "$PACKAGES"

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
