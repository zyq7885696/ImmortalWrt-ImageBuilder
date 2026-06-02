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

# 下载 kucat 主题和插件（使用特定版本，避免latest问题）
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

echo "✅ kucat 主题配置完成"

# ============= 下载和配置 MOSDNS（简化版，更稳定） ===============
echo "🌐 正在配置 MOSDNS..."

# 创建目录
mkdir -p /home/build/immortalwrt/files/usr/bin
mkdir -p /home/build/immortalwrt/files/usr/share/v2ray
mkdir -p /home/build/immortalwrt/files/etc/mosdns

# 1. 直接下载预编译的 MOSDNS 二进制（使用固定版本，避免API限制）
echo "正在下载 mosdns 主程序..."
# 使用固定版本，更稳定
MOSDNS_URL="https://github.com/IrineSistiana/mosdns/releases/download/v5.3.3/mosdns-linux-amd64.zip"
if wget --no-check-certificate -q --show-progress -O /tmp/mosdns.zip "$MOSDNS_URL"; then
    unzip -q -j /tmp/mosdns.zip "mosdns" -d /home/build/immortalwrt/files/usr/bin/ 2>/dev/null
    chmod +x /home/build/immortalwrt/files/usr/bin/mosdns
    echo "✅ mosdns 主程序已安装"
else
    echo "⚠️ MOSDNS 下载失败，跳过"
fi

# 2. 下载 v2dat 工具（固定版本）
echo "正在下载 v2dat 工具..."
V2DAT_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"
if wget --no-check-certificate -q --show-progress -O /tmp/xray.zip "$V2DAT_URL"; then
    unzip -q -j /tmp/xray.zip "v2dat" -d /home/build/immortalwrt/files/usr/bin/ 2>/dev/null
    chmod +x /home/build/immortalwrt/files/usr/bin/v2dat
    echo "✅ v2dat 工具已安装"
else
    echo "⚠️ v2dat 下载失败，跳过"
fi

# 3. 下载 geoip 和 geosite 数据库
echo "正在下载 GeoIP/GeoSite 数据库..."
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/files/usr/share/v2ray/geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/files/usr/share/v2ray/geosite.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

# 4. 下载 MOSDNS 的 LUCI 应用（不手动解压，让构建系统处理）
echo "正在下载 luci-app-mosdns..."
mkdir -p /home/build/immortalwrt/extra-packages-local
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/extra-packages-local/luci-app-mosdns_all.ipk \
    https://github.com/sbwml/luci-app-mosdns/releases/latest/download/luci-app-mosdns_all.ipk
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/extra-packages-local/luci-i18n-mosdns-zh-cn_all.ipk \
    https://github.com/sbwml/luci-app-mosdns/releases/latest/download/luci-i18n-mosdns-zh-cn_all.ipk

# 创建简化的 mosdns 配置
cat << 'MOSDNS_EOF' > /home/build/immortalwrt/files/etc/mosdns/config.yaml
log:
  level: info

plugins:
  - tag: forward_local
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"

  - tag: forward_remote
    type: forward
    args:
      upstreams:
        - addr: "8.8.8.8"

  - tag: main_sequence
    type: sequence
    args:
      - exec: $forward_local

listeners:
  - protocol: udp
    addr: "0.0.0.0:5353"
    exec: $main_sequence
  - protocol: tcp
    addr: "0.0.0.0:5353"
    exec: $main_sequence
MOSDNS_EOF

# 清理临时文件
rm -f /tmp/mosdns.zip /tmp/xray.zip

echo "✅ MOSDNS 配置完成"

cd /home/build/immortalwrt

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  echo "🔄 正在同步第三方软件仓库..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo 2>/dev/null

  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run 2>/dev/null
  sh shell/prepare-packages.sh 2>/dev/null
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= 定义包列表 ===============
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# SmartDNS
# PACKAGES="$PACKAGES luci-app-smartdns"
# PACKAGES="$PACKAGES luci-i18n-smartdns-zh-cn"
# PACKAGES="$PACKAGES smartdns"

# MOSDNS (只添加luci界面，二进制已手动添加)
PACKAGES="$PACKAGES luci-app-mosdns"
PACKAGES="$PACKAGES luci-i18n-mosdns-zh-cn"

# OpenClash
PACKAGES="$PACKAGES luci-app-openclash"

# ZeroTier
PACKAGES="$PACKAGES luci-app-zerotier"
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"
PACKAGES="$PACKAGES zerotier"

# DDNS-GO
PACKAGES="$PACKAGES luci-app-ddns-go"
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"
PACKAGES="$PACKAGES ddns-go"

# 合并第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# Docker
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding Docker packages"
fi

# OpenClash 内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 添加 OpenClash 内核"
    mkdir -p files/etc/openclash/core
    mkdir -p files/etc/openclash/config
    
    # 下载内核
    wget -q https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz -O - | tar xz -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash-linux-amd64-v1 files/etc/openclash/core/clash_meta 2>/dev/null
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null
    
    # 下载数据库
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
fi

# 设置IP
CUSTOM_ROUTER_IP=$(cat /home/build/immortalwrt/files/etc/config/custom_router_ip.txt 2>/dev/null)
if [ -n "$CUSTOM_ROUTER_IP" ]; then
    echo "🔄 设置路由器IP: $CUSTOM_ROUTER_IP"
    sed -i "s/192.168.1.1/$CUSTOM_ROUTER_IP/g" files/etc/config/network 2>/dev/null || true
fi

# 构建
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建..."
echo "包列表: $PACKAGES"

# 执行构建
make image PROFILE="generic" \
  PACKAGES="$PACKAGES" \
  FILES="/home/build/immortalwrt/files" \
  ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建失败！"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 构建成功完成！"
