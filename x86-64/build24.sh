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

# ============= 下载 kucat 主题和相关插件 =============
echo "🔄 正在下载 kucat 主题和相关插件..."
mkdir -p /home/build/immortalwrt/kucat-packages
cd /home/build/immortalwrt/kucat-packages

# 下载 kucat 主题和插件
echo "下载 luci-theme-kucat..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-theme-kucat_2.2.0_all.ipk

echo "下载 luci-i18n-kucat-config-zh-cn..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-i18n-kucat-config-zh-cn_0_all.ipk

echo "下载 luci-app-kucat-config..."
wget -q --show-progress https://github.com/sirpdboy/luci-theme-kucat/releases/latest/download/luci-app-kucat-config_2.2.0-r20260227_all.ipk

# 检查下载是否成功
echo "下载的文件列表:"
ls -lh *.ipk

# 解压 ipk 文件到 files 目录
for ipk in *.ipk; do
    if [ -f "$ipk" ]; then
        echo "正在解压 $ipk..."
        TEMP_DIR=$(mktemp -d)
        cd $TEMP_DIR
        
        ar x /home/build/immortalwrt/kucat-packages/"$ipk"
        
        if [ -f data.tar.gz ]; then
            tar -xzf data.tar.gz -C /home/build/immortalwrt/files/
            echo "✅ 已解压 $ipk 的内容到 files 目录"
        elif [ -f data.tar.xz ]; then
            tar -xJf data.tar.xz -C /home/build/immortalwrt/files/
            echo "✅ 已解压 $ipk 的内容到 files 目录"
        else
            echo "⚠️ 找不到 data.tar.gz 或 data.tar.xz"
        fi
        
        cd /home/build/immortalwrt
        rm -rf $TEMP_DIR
    fi
done

# 创建默认主题配置文件
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme
#!/bin/sh
# 设置 kucat 为默认主题
uci set luci.main.mediaurlbase='/luci-static/kucat'
uci commit luci
exit 0
EOF
chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-kucat-theme

echo "✅ kucat 主题和相关插件已解压到 files 目录"

cd /home/build/immortalwrt

# ============= 注意：已移除 store 相关代码 =============

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 - 精简版本，确保兼容性
PACKAGES=""
# 基础包
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci"
PACKAGES="$PACKAGES luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"

# 磁盘管理
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES fdisk"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# SmartDNS
PACKAGES="$PACKAGES luci-app-smartdns"
PACKAGES="$PACKAGES luci-i18n-smartdns-zh-cn"
PACKAGES="$PACKAGES smartdns"

# ZeroTier
PACKAGES="$PACKAGES luci-app-zerotier"
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"
PACKAGES="$PACKAGES zerotier"

# DDNS-GO
PACKAGES="$PACKAGES luci-app-ddns-go"
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"
PACKAGES="$PACKAGES ddns-go"

# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
if [ -n "$CUSTOM_PACKAGES" ]; then
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

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

    echo "✅ 已设置路由器管理地址为: $CUSTOM_ROUTER_IP"
fi

# 构建镜像 - 指定生成所有需要的格式
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"
echo "=========================================="
echo "包含的主要插件:"
echo "- SmartDNS (智能DNS加速)"
echo "- ZeroTier (虚拟组网)"
echo "- DDNS-GO (动态域名解析)"
echo "- Kucat 主题 (已预装并设为默认)"
echo "=========================================="

# 使用 make image 并指定生成所有格式
# TARGET_IMAGES 参数可以指定要生成的镜像类型
make image \
    PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE=$PROFILE \
    TARGET_IMAGES="ext4-combined-efi ext4-rootfs squashfs-combined-efi squashfs-rootfs"

# 检查构建结果
if [ $? -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
    
    # 显示生成的镜像文件
    echo "=========================================="
    echo "生成的镜像文件:"
    echo "----------------------------------------"
    
    # 查找并列出所有镜像文件
    IMAGE_DIR="/home/build/immortalwrt/bin/targets/x86/64"
    
    if [ -d "$IMAGE_DIR" ]; then
        echo "ext4 格式:"
        ls -lh $IMAGE_DIR/*ext4* 2>/dev/null || echo "  ❌ 未找到 ext4 镜像"
        
        echo ""
        echo "squashfs 格式:"
        ls -lh $IMAGE_DIR/*squashfs* 2>/dev/null || echo "  ❌ 未找到 squashfs 镜像"
        
        echo ""
        echo "combined 格式:"
        ls -lh $IMAGE_DIR/*combined* 2>/dev/null || echo "  ❌ 未找到 combined 镜像"
        
        echo ""
        echo "rootfs 格式:"
        ls -lh $IMAGE_DIR/*rootfs* 2>/dev/null || echo "  ❌ 未找到 rootfs 镜像"
        
        echo "----------------------------------------"
        echo "完整文件列表:"
        ls -lh $IMAGE_DIR/*.img* 2>/dev/null || echo "未找到镜像文件"
    else
        echo "❌ 镜像目录不存在: $IMAGE_DIR"
    fi
    echo "=========================================="
    
    # 创建一个文件清单，方便后续上传
    find $IMAGE_DIR -name "*.img*" -type f > /home/build/immortalwrt/bin/generated_images.txt
    echo "镜像清单已保存到: /home/build/immortalwrt/bin/generated_images.txt"
    
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi
