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

# ============= 下载 kucat 主题和相关插件 =============
echo "🔄 正在下载 kucat 主题和相关插件..."
mkdir -p /home/build/immortalwrt/kucat-packages
cd /home/build/immortalwrt/kucat-packages

# 下载 kucat 主题和插件
wget -q https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat_2.2.0_all.ipk
wget -q https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-i18n-kucat-config-zh-cn_0_all.ipk
wget -q https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-app-kucat-config_2.2.0-r20260227_all.ipk

# 解压 ipk 文件到 files 目录
for ipk in *.ipk; do
    if [ -f "$ipk" ]; then
        echo "正在解压 $ipk..."
        TEMP_DIR=$(mktemp -d)
        cd $TEMP_DIR
        ar x /home/build/immortalwrt/kucat-packages/"$ipk"
        if [ -f data.tar.gz ]; then
            tar -xzf data.tar.gz -C /home/build/immortalwrt/files/
        elif [ -f data.tar.xz ]; then
            tar -xJf data.tar.xz -C /home/build/immortalwrt/files/
        fi
        cd /home/build/immortalwrt
        rm -rf $TEMP_DIR
    fi
done

# 创建默认主题配置文件
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

echo "✅ kucat 主题已解压"

cd /home/build/immortalwrt

# ============= 简化包列表 - 先测试基础功能 =============
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# 最精简的包列表 - 只包含必要组件
PACKAGES=""
PACKAGES="$PACKAGES luci"           # Luci 界面
PACKAGES="$PACKAGES luci-i18n-base-zh-cn"  # 中文
PACKAGES="$PACKAGES curl"

# 添加固定IP设置
CUSTOM_ROUTER_IP=$(cat /home/build/immortalwrt/files/etc/config/custom_router_ip.txt 2>/dev/null)

if [ -n "$CUSTOM_ROUTER_IP" ]; then
    echo "🔄 正在设置路由器管理地址为: $CUSTOM_ROUTER_IP"
    cat << EOF > /home/build/immortalwrt/files/etc/config/network
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config globals 'globals'
        option ula_prefix 'fd00:ab68:d9f0::/48'

config device
        option name 'br-lan'
        option type 'bridge'
        list ports 'eth0'

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '$CUSTOM_ROUTER_IP'
        option netmask '255.255.255.0'
        option ip6assign '60'

config interface 'wan'
        option device 'eth1'
        option proto 'dhcp'

config interface 'wan6'
        option device 'eth1'
        option proto 'dhcpv6'
EOF
fi

# 构建镜像
echo "Building with packages: $PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
    echo "生成的镜像:"
    ls -lh /home/build/immortalwrt/bin/targets/x86/64/*.img.gz 2>/dev/null
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Build failed!"
    exit 1
fi
