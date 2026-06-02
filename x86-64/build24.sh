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
        # 创建临时目录
        TEMP_DIR=$(mktemp -d)
        cd $TEMP_DIR
        
        # 解压 ipk (ipk 是 ar 归档格式)
        ar x /home/build/immortalwrt/kucat-packages/"$ipk"
        
        # 解压 data.tar.gz
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

# 验证文件是否已正确复制
echo "验证 kucat 主题文件是否已复制:"
find /home/build/immortalwrt/files -name "*kucat*" -type f 2>/dev/null | head -20

echo "✅ kucat 主题和相关插件已解压到 files 目录"

# ============= 下载和配置 MOSDNS ===============
echo "🌐 正在配置 MOSDNS..."

# 检查并安装 unzip（如果需要）
if ! command -v unzip &> /dev/null; then
    echo "安装 unzip 工具..."
    sudo apt-get update && sudo apt-get install -y unzip
fi

# 创建 MOSDNS 相关目录
mkdir -p /home/build/immortalwrt/packages/mosdns
mkdir -p /home/build/immortalwrt/files/usr/bin
mkdir -p /home/build/immortalwrt/files/usr/share/v2ray
mkdir -p /home/build/immortalwrt/files/etc/mosdns
mkdir -p /home/build/immortalwrt/files/etc/init.d

# 1. 下载 luci-app-mosdns
echo "正在下载 luci-app-mosdns..."
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/packages/mosdns/luci-app-mosdns_all.ipk \
    https://github.com/sbwml/luci-app-mosdns/releases/latest/download/luci-app-mosdns_all.ipk

# 2. 下载中文语言包
echo "正在下载 luci-i18n-mosdns-zh-cn..."
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/packages/mosdns/luci-i18n-mosdns-zh-cn_all.ipk \
    https://github.com/sbwml/luci-app-mosdns/releases/latest/download/luci-i18n-mosdns-zh-cn_all.ipk

# 3. 下载 mosdns 主程序
echo "正在下载 mosdns 主程序..."
MOSDNS_VERSION=$(curl -s https://api.github.com/repos/IrineSistiana/mosdns/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
echo "最新 mosdns 版本: v$MOSDNS_VERSION"
wget --no-check-certificate -q --show-progress -O /tmp/mosdns.zip \
    "https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/mosdns-linux-amd64.zip"

# 解压 mosdns
unzip -j /tmp/mosdns.zip "mosdns" -d /home/build/immortalwrt/files/usr/bin/
chmod +x /home/build/immortalwrt/files/usr/bin/mosdns
echo "✅ mosdns 主程序已安装"

# 4. 下载 v2dat 工具
echo "正在下载 v2dat 工具..."
V2DAT_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
echo "最新 Xray-core 版本: v$V2DAT_VERSION"
wget --no-check-certificate -q --show-progress -O /tmp/xray.zip \
    "https://github.com/XTLS/Xray-core/releases/download/v${V2DAT_VERSION}/Xray-linux-64.zip"

# 解压获取 v2dat
unzip -j /tmp/xray.zip "v2dat" -d /home/build/immortalwrt/files/usr/bin/
chmod +x /home/build/immortalwrt/files/usr/bin/v2dat
echo "✅ v2dat 工具已安装"

# 5. 下载 v2ray-geoip 和 v2ray-geosite 数据库
echo "正在下载 v2ray-geoip 和 v2ray-geosite 数据..."
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/files/usr/share/v2ray/geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
wget --no-check-certificate -q --show-progress -O /home/build/immortalwrt/files/usr/share/v2ray/geosite.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
echo "✅ GeoIP/GeoSite 数据库已下载"

# 6. 解压 MOSDNS 的 IPK 包到 files 目录
echo "正在解压 MOSDNS IPK 包..."
for ipk in /home/build/immortalwrt/packages/mosdns/*.ipk; do
    if [ -f "$ipk" ]; then
        echo "解压: $(basename $ipk)"
        TEMP_DIR=$(mktemp -d)
        cd $TEMP_DIR
        ar x "$ipk"
        if [ -f data.tar.gz ]; then
            tar -xzf data.tar.gz -C /home/build/immortalwrt/files/
        elif [ -f data.tar.xz ]; then
            tar -xJf data.tar.xz -C /home/build/immortalwrt/files/
        fi
        cd /home/build/immortalwrt
        rm -rf $TEMP_DIR
    fi
done

# 7. 创建 mosdns 基础配置文件
cat << 'MOSDNS_EOF' > /home/build/immortalwrt/files/etc/mosdns/config.yaml
# MosDNS 基础配置
log:
  level: info
  file: "/var/log/mosdns.log"

data_providers:
  - tag: geoip
    file: /usr/share/v2ray/geoip.dat
    auto_reload: true
  - tag: geosite
    file: /usr/share/v2ray/geosite.dat
    auto_reload: true

plugins:
  - tag: forward_remote
    type: forward
    args:
      upstreams:
        - addr: "https://dns.google/dns-query"
        - addr: "https://cloudflare-dns.com/dns-query"
      dial_addr: "8.8.8.8:53"

  - tag: forward_local
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"
        
  - tag: local_sequence
    type: sequence
    args:
      - exec: $forward_local
      
  - tag: remote_sequence
    type: sequence
    args:
      - exec: $forward_remote

  - tag: query_matcher
    type: query_matcher
    args:
      domain:
        - 'geosite:cn'
      exec: $local_sequence
      continue: true
      
  - tag: geoip_matcher
    type: ip_matcher
    args:
      ip:
        - 'geoip:cn'
      exec: $local_sequence
      continue: true
      
  - tag: main_router
    type: sequence
    args:
      - exec: $query_matcher
      - exec: $geoip_matcher
      - exec: $remote_sequence
      
listeners:
  - protocol: udp
    addr: "0.0.0.0:5353"
    exec: $main_router
  - protocol: tcp
    addr: "0.0.0.0:5353"
    exec: $main_router
MOSDNS_EOF

# 8. 创建 mosdns 初始化脚本
cat << 'MOSDNS_INIT_EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-mosdns-setup
#!/bin/sh
# MOSDNS 初始化配置

# 创建必要目录
mkdir -p /usr/share/v2ray
mkdir -p /etc/mosdns
mkdir -p /var/log

# 确保 geoip/geosite 文件存在
[ -f /usr/share/v2ray/geoip.dat ] || cp /etc/mosdns/geoip.dat /usr/share/v2ray/geoip.dat 2>/dev/null
[ -f /usr/share/v2ray/geosite.dat ] || cp /etc/mosdns/geosite.dat /usr/share/v2ray/geosite.dat 2>/dev/null

# 设置 mosdns 开机自启
if [ -f /etc/init.d/mosdns ]; then
    /etc/init.d/mosdns enable
fi

exit 0
MOSDNS_INIT_EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-mosdns-setup

# 清理临时文件
rm -f /tmp/mosdns.zip /tmp/xray.zip

echo "✅ MOSDNS 组件配置完成"
ls -lh /home/build/immortalwrt/files/usr/bin/mosdns 2>/dev/null
ls -lh /home/build/immortalwrt/files/usr/bin/v2dat 2>/dev/null

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
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
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
# 注意：kucat 主题已被解压到 files 目录，不需要在 PACKAGES 中声明
# 只需要包含 luci 基础包
PACKAGES="$PACKAGES luci"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# ============ 新增 SmartDNS 插件 ============
# SmartDNS - 智能DNS解析加速，提升网络访问速度
# PACKAGES="$PACKAGES luci-app-smartdns"
# PACKAGES="$PACKAGES luci-i18n-smartdns-zh-cn"
# PACKAGES="$PACKAGES smartdns"

# ============ 新增 MOSDNS 插件 ============
# MOSDNS - DNS 分流工具（只添加 luci 包，二进制已手动添加）
PACKAGES="$PACKAGES luci-app-mosdns"
PACKAGES="$PACKAGES luci-i18n-mosdns-zh-cn"

# OpenClash - 代理客户端
PACKAGES="$PACKAGES luci-app-openclash"

# ZeroTier - 虚拟组网
PACKAGES="$PACKAGES luci-app-zerotier"
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"
PACKAGES="$PACKAGES zerotier"

# DDNS-GO - 动态域名解析
PACKAGES="$PACKAGES luci-app-ddns-go"
PACKAGES="$PACKAGES luci-i18n-ddns-go-zh-cn"
PACKAGES="$PACKAGES ddns-go"

# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 为 OpenClash 添加内核文件
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 OpenClash 内核和配置文件"
    
    # 创建 OpenClash 目录
    mkdir -p files/etc/openclash/core
    mkdir -p files/etc/openclash/config
    
    # 下载 clash_meta 内核 (推荐使用 meta 内核)
    echo "正在下载 Clash Meta 内核..."
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    if wget -q --show-progress $META_URL -O - | tar xOvz > files/etc/openclash/core/clash_meta; then
        chmod +x files/etc/openclash/core/clash_meta
        echo "✅ Clash Meta 内核下载完成"
    else
        echo "⚠️ Clash Meta 内核下载失败"
    fi
    
    # 下载 GeoIP 和 GeoSite 数据库
    echo "正在下载 GeoIP 和 GeoSite 数据库..."
    wget -q --show-progress https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q --show-progress https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    
    echo "✅ OpenClash 文件添加完成"
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 为 ZeroTier 创建配置目录
if echo "$PACKAGES" | grep -q "luci-app-zerotier"; then
    echo "✅ 已选择 luci-app-zerotier，创建配置目录"
    mkdir -p files/etc/zerotier
    echo "✅ ZeroTier 配置目录创建完成"
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
else
    echo "⚠️ 未找到自定义IP配置，使用默认配置"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"
echo "=========================================="
echo "包含的主要插件:"
# echo "- SmartDNS (智能DNS加速)"
echo "- MOSDNS (DNS 分流 + v2dat + GeoIP/GeoSite)"
echo "- OpenClash (代理客户端 + 内核)"
echo "- ZeroTier (虚拟组网)"
echo "- DDNS-GO (动态域名解析)"
echo "- Docker (如果启用: $INCLUDE_DOCKER)"
echo "- Kucat 主题 (已预装并设为默认)"
echo "=========================================="

# 测试软件包是否可用
echo "测试软件包可用性..."
for pkg in $PACKAGES; do
    echo "检查包: $pkg"
done

# 执行构建并捕获错误详情
echo "开始执行 make image 命令..."
if make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE 2>&1 | tee /tmp/make_output.log; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    echo "最后50行构建日志:"
    tail -50 /tmp/make_output.log
    exit 1
fi
