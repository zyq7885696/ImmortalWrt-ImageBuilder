#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
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
    CUSTOM_IP="172.16.1.251"
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

# ============= 下载 kucat 主题和相关插件 =============
echo "🔄 正在下载 kucat 主题和相关插件..."
mkdir -p /home/build/immortalwrt/kucat-packages
cd /home/build/immortalwrt/kucat-packages

# 下载 kucat 主题和插件
echo "下载 luci-theme-kucat..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/download/v3.3.0/luci-theme-kucat_3.3.0-r20260227_all.ipk 2>/dev/null || \
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat_2.2.0_all.ipk

echo "下载 luci-i18n-kucat-config-zh-cn..."
wget -q --show-progress https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-i18n-kucat-config-zh-cn_0_all.ipk

echo "下载 luci-app-kucat-config..."
wget -q --show-progress https://github.com/sirpdboy/luci-app-kucat-config/releases/download/v2.2.0/luci-app-kucat-config_2.2.0-r20260227_all.ipk

# 检查下载是否成功
echo "下载的文件列表:"
ls -lh *.ipk 2>/dev/null || echo "没有下载到ipk文件"

# 解压 ipk 文件到 files 目录
for ipk in *.ipk; do
    if [ -f "$ipk" ]; then
        echo "正在解压 $ipk..."
        TEMP_DIR=$(mktemp -d)
        cd $TEMP_DIR
        
        ar x /home/build/immortalwrt/kucat-packages/"$ipk" 2>/dev/null
        
        if [ -f data.tar.gz ]; then
            tar -xzf data.tar.gz -C /home/build/immortalwrt/files/ 2>/dev/null
            echo "✅ 已解压 $ipk"
        elif [ -f data.tar.xz ]; then
            tar -xJf data.tar.xz -C /home/build/immortalwrt/files/ 2>/dev/null
            echo "✅ 已解压 $ipk"
        fi
        
        cd /home/build/immortalwrt
        rm -rf $TEMP_DIR
    fi
done

# 创建默认主题配置文件（Kucat 设为默认）
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
# 设置 kucat 为默认主题
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

echo "✅ Kucat 主题已设为默认"

cd /home/build/immortalwrt

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表（已移除 argon 和 smartdns）
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
# PACKAGES="$PACKAGES luci-theme-argon"  # 已移除 Argon 主题
# PACKAGES="$PACKAGES luci-app-argon-config"  # 已移除 Argon 配置
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
# PACKAGES="$PACKAGES luci-app-smartdns"  # 已移除 SmartDNS
# PACKAGES="$PACKAGES luci-i18n-smartdns-zh-cn"  # 已移除 SmartDNS 中文语言包

# ============= BBR 加速配置 =============
echo "🚀 正在配置 BBR 加速..."
mkdir -p /home/build/immortalwrt/files/etc/sysctl.d
cat << 'BBR_EOF' > /home/build/immortalwrt/files/etc/sysctl.d/99-bbr.conf
# BBR 加速配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR_EOF

# 同时创建 uci-defaults 脚本确保 BBR 在启动时启用
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'BBR_UCI_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-bbr-enable
#!/bin/sh
# 启用 BBR 加速
if [ -f /etc/sysctl.d/99-bbr.conf ]; then
    sysctl -p /etc/sysctl.d/99-bbr.conf 2>/dev/null
    echo "BBR acceleration enabled" > /tmp/bbr-status.log
fi
exit 0
BBR_UCI_EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-bbr-enable
echo "✅ BBR 加速配置已添加"

# Kucat 主题已手动解压到 files 目录，不需要添加到包列表
# 验证文件是否已正确解压
if [ -d "/home/build/immortalwrt/files/usr/lib/lua/luci/view/kucat" ] || \
   [ -d "/home/build/immortalwrt/files/www/luci-static/kucat" ]; then
    echo "✅ Kucat 主题文件已存在于 files 目录"
else
    echo "⚠️ 警告: Kucat 主题文件可能未正确解压"
fi

# ======== shell/apk-custom-packages.sh =======
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
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
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
echo "=========================================="
echo "包含的主要插件:"
echo "- Kucat 主题 (已预装并设为默认)"
echo "- BBR 加速 (已启用)"
echo "- OpenClash (代理客户端 + 内核)"
echo "- ZeroTier (虚拟组网)"
echo "- DDNS-GO (动态域名解析)"
echo "- Docker (如果启用: $INCLUDE_DOCKER)"
echo "=========================================="

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
