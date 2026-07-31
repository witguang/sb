#!/bin/bash
# ==============================================================================
# Sing-box VMess + WebSocket + TLS + Cloudflare Argo 极简全能版
# 支持三格式订阅 (.txt / .json / .yaml) & WARP-WireGuard-IPv6 域名分流
# ==============================================================================

export LANG=en_US.UTF-8

red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue(){ echo -e "\033[36m\033[01m$1\033[0m"; }
white(){ echo -e "\033[37m\033[01m$1\033[0m"; }
readp(){ read -p "$(yellow "$1")" "$2"; }

plain="\033[0m"

# 1. 环境与权限检查
[[ $EUID -ne 0 ]] && yellow "请以 root 权限运行此脚本" && exit 1

stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null

if [[ -f /etc/redhat-release ]]; then
    release="Centos"
elif grep -q -E -i "debian" /etc/os-release /proc/version 2>/dev/null; then
    release="Debian"
elif grep -q -E -i "ubuntu" /etc/os-release /proc/version 2>/dev/null; then
    release="Ubuntu"
elif grep -q -E -i "centos|red hat|redhat" /etc/os-release /proc/version 2>/dev/null; then
    release="Centos"
elif grep -q -E -i "alpine" /etc/issue 2>/dev/null; then
    release="Alpine"
else 
    red "脚本不支持当前的系统，请选择 Ubuntu, Debian, CentOS 系统。" && exit 1
fi

case $(uname -m) in
    aarch64) cpu="arm64" ;;
    x86_64)  cpu="amd64" ;;
    *) red "目前脚本不支持 $(uname -m) 架构" && exit 1 ;;
esac

mkdir -p /etc/s-box /etc/s-box/web

# 获取本机公网 IP
get_public_ip() {
    local v4 v6
    v4=$(curl -s4m5 icanhazip.com 2>/dev/null)
    v6=$(curl -s6m5 icanhazip.com 2>/dev/null)
    if [[ -n "$v4" ]]; then
        echo "$v4"
    elif [[ -n "$v6" ]]; then
        echo "[$v6]"
    else
        echo "127.0.0.1"
    fi
}

# 2. 安装必要依赖
install_dependencies() {
    green "检查并安装必要依赖……"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl jq tar wget unzip procps psmisc qrencode git busybox python3 xxd
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y curl jq tar wget unzip procps psmisc qrencode git busybox python3 xxd epel-release
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
        dnf install -y curl jq tar wget unzip procps psmisc qrencode git busybox python3 xxd
    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add bash curl jq tar wget unzip procps qrencode git busybox python3 xxd
    fi
}

# 3. 安装 / 更新 Sing-box 内核
install_singbox() {
    green "正在下载并安装最新版 Sing-box 内核……"
    local sbcore
    sbcore=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r ".tag_name" 2>/dev/null | sed "s/^v//")
    if [[ -z "$sbcore" || "$sbcore" == "null" ]]; then
        sbcore="1.10.7"
    fi
    local sbname="sing-box-${sbcore}-linux-${cpu}"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"
    
    curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 3 "$url"
    if [[ -f "/etc/s-box/sing-box.tar.gz" ]]; then
        tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
        mv /etc/s-box/"$sbname"/sing-box /etc/s-box/sing-box
        rm -rf /etc/s-box/sing-box.tar.gz /etc/s-box/"$sbname"
        chmod +x /etc/s-box/sing-box
        blue "成功安装 Sing-box 内核版本: v${sbcore}"
    else
        red "下载 Sing-box 内核失败，请检查网络连接。" && exit 1
    fi
}

# 4. 安装 Cloudflared (Argo)
install_cloudflared() {
    if [[ ! -f /etc/s-box/cloudflared ]]; then
        green "正在下载 Cloudflared 客户端……"
        local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
        curl -L -o /etc/s-box/cloudflared -# --retry 3 "$url"
        chmod +x /etc/s-box/cloudflared
    fi
}

# 辅助函数：生成 WARP-WireGuard 账号配置
generate_warp_wg() {
    local keypair private_key public_key response reserved_str reserved_hex reserved_dec
    keypair=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -text -noout 2>/dev/null)
    private_key=$(echo "$keypair" | awk "/priv:/{flag=1; next} /pub:/{flag=0} flag" | tr -d "[:space:]" | xxd -r -p 2>/dev/null | base64)
    public_key=$(echo "$keypair" | awk "/pub:/{flag=1} flag" | tr -d "[:space:]" | xxd -r -p 2>/dev/null | base64)

    response=$(curl -sL --tlsv1.3 --connect-timeout 5 \
        -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "CF-Client-Version: a-7.21-0721" \
        -H "Content-Type: application/json" \
        -d '{"key": "'"$public_key"'", "tos": "'"$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"'"}' 2>/dev/null)

    reserved_str=$(echo "$response" | jq -r ".config.client_id" 2>/dev/null)
    if [[ -n "$reserved_str" && "$reserved_str" != "null" ]]; then
        reserved_hex=$(echo "$reserved_str" | base64 -d | xxd -p)
        reserved_dec=$(echo "$reserved_hex" | fold -w2 | while read HEX; do printf "%d " "0x${HEX}"; done | awk "{print \"[\"$1\", \"$2\", \"$3\"]\"}")
        local v6_addr=$(echo "$response" | jq -r ".config.interface.addresses.v6" 2>/dev/null)
        echo "$private_key" > /etc/s-box/warp_pvk.log
        echo "${v6_addr:-2606:4700:110:860e:738f:b37:f15:d38d}" > /etc/s-box/warp_v6.log
        echo "${reserved_dec:-[33,217,129]}" > /etc/s-box/warp_res.log
    else
        echo "g9I2sgUH6OCbIBTehkEfVEnuvInHYZvPOFhWchMLSc4=" > /etc/s-box/warp_pvk.log
        echo "2606:4700:110:860e:738f:b37:f15:d38d" > /etc/s-box/warp_v6.log
        echo "[33,217,129]" > /etc/s-box/warp_res.log
    fi
}

# 辅助函数：根据 UUID 转换 Path 路径 (调换第1段与第5段，后缀变 -ao)
generate_custom_path() {
    local uuid="$1"
    local p1 p2 p3 p4 p5
    IFS="-" read -r p1 p2 p3 p4 p5 <<< "$uuid"
    if [[ -n "$p1" && -n "$p5" ]]; then
        echo "${p5}-${p2}-${p3}-${p4}-${p1}-ao"
    else
        echo "${uuid}-ao"
    fi
}

# 5. 生成服务端配置文件
generate_config() {
    local port=${1:-8088}
    local uuid=${2:-$(/etc/s-box/sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
    local ws_path
    ws_path=$(generate_custom_path "$uuid")

    if [[ ! -f /etc/s-box/warp_pvk.log ]]; then
        generate_warp_wg
    fi

    local pvk v6_addr res_val
    pvk=$(cat /etc/s-box/warp_pvk.log 2>/dev/null)
    v6_addr=$(cat /etc/s-box/warp_v6.log 2>/dev/null)
    res_val=$(cat /etc/s-box/warp_res.log 2>/dev/null)

    local warp_domains_json="[]"
    if [[ -f /etc/s-box/warp_domains.log ]]; then
        warp_domains_json=$(cat /etc/s-box/warp_domains.log)
    fi

    cat > /etc/s-box/sb.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        {
          "uuid": "${uuid}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/${ws_path}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "wireguard",
      "tag": "warp-IPv6-out",
      "server": "162.159.192.1",
      "server_port": 2408,
      "local_address": [
        "172.16.0.2/32",
        "${v6_addr}/128"
      ],
      "private_key": "${pvk}",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": ${res_val:-[0,0,0]}
    }
  ],
  "route": {
    "rules": [
      {
        "outbound": "warp-IPv6-out",
        "domain_suffix": ${warp_domains_json}
      },
      {
        "outbound": "direct",
        "network": "udp,tcp"
      }
    ]
  }
}
EOF
    echo "$port" > /etc/s-box/port.log
    echo "$uuid" > /etc/s-box/uuid.log
    echo "$ws_path" > /etc/s-box/path.log
    if [[ ! -f /etc/s-box/cdn.log ]]; then
        echo "cloudflare-ech.com" > /etc/s-box/cdn.log
    fi
}

# 6. 重置/设置 WARP WireGuard IPv6 优先分流域名
reset_warp_v6_domains() {
    echo
    green "【 重置 WARP-WireGuard IPv6 优先分流域名 】"
    yellow "当前已分流的域名列表："
    if [[ -f /etc/s-box/warp_domains_raw.log ]]; then
        blue "  $(cat /etc/s-box/warp_domains_raw.log)"
    else
        blue "  未设置 (默认空)"
    fi
    echo
    yellow "请输入需要走 WARP IPv6 出站的域名 (多个域名之间用空格隔开，例如：google.com openai.com netflix.com)"
    yellow "回车跳过/清空表示重置清空分流通道："
    readp "域名列表: " input_domains

    if [[ -z "$input_domains" ]]; then
        echo "[]" > /etc/s-box/warp_domains.log
        rm -f /etc/s-box/warp_domains_raw.log
        green "已清空 WARP IPv6 分流域名！"
    else
        echo "$input_domains" > /etc/s-box/warp_domains_raw.log
        local json_arr="["
        local first=1
        for dom in $input_domains; do
            if [[ $first -eq 1 ]]; then
                json_arr="${json_arr}\"${dom}\""
                first=0
            else
                json_arr="${json_arr},\"${dom}\""
            fi
        done
        json_arr="${json_arr}]"
        echo "$json_arr" > /etc/s-box/warp_domains.log
        green "WARP IPv6 分流域名已成功设置为: $input_domains"
    fi

    local port uuid
    port=$(cat /etc/s-box/port.log 2>/dev/null || echo "8088")
    uuid=$(cat /etc/s-box/uuid.log 2>/dev/null)
    generate_config "$port" "$uuid"
    setup_service
    green "Sing-box 服务已重新加载新路由规则！"
}

# 7. 配置服务项
setup_service() {
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
    fi
}

# 8. 启动/配置 Argo 隧道
setup_argo() {
    install_cloudflared
    local port
    port=$(cat /etc/s-box/port.log 2>/dev/null || echo "8088")

    echo
    green "选择 Argo 隧道模式："
    yellow "1. 启动临时 Argo 隧道 (TryCloudflare)"
    yellow "2. 配置固定 Argo 隧道 (Zero Trust Token)"
    readp "请选择【1-2】: " argo_menu

    if [[ "$argo_menu" == "2" ]]; then
        readp "请输入 Cloudflare Zero Trust Tunnel Token: " argotoken
        readp "请输入分配给该隧道的自定义域名: " argoym

        if [[ -n "$argotoken" && -n "$argoym" ]]; then
            pkill -f "cloudflared" 2>/dev/null
            cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/etc/s-box/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${argotoken}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable argo >/dev/null 2>&1
            systemctl restart argo
            echo "$argoym" > /etc/s-box/argoym.log
            echo "VMess-Argo-TLS-Fixed" > /etc/s-box/ps_tag.log
            green "固定 Argo 隧道配置成功！"
        else
            red "Token 或 域名为空，未能设置固定隧道。"
        fi
    else
        pkill -f "cloudflared" 2>/dev/null
        nohup /etc/s-box/cloudflared tunnel --url http://localhost:${port} --edge-ip-version auto --no-autoupdate --protocol http2 > /etc/s-box/argo.log 2>&1 &
        green "正在生成临时 Argo 域名，请等待 10 秒……"
        sleep 10
        local temp_domain
        temp_domain=$(grep -a -oE "https://[a-zA-Z0-9.-]+\\.trycloudflare\\.com" /etc/s-box/argo.log | head -n 1 | sed "s|https://||")
        if [[ -n "$temp_domain" ]]; then
            echo "$temp_domain" > /etc/s-box/argoym.log
            echo "VMess-Argo-TLS-Temp" > /etc/s-box/ps_tag.log
            green "临时 Argo 域名生成成功: ${temp_domain}"
        else
            echo "VMess-Argo-TLS-Temp" > /etc/s-box/ps_tag.log
            red "临时 Argo 域名生成超时，请稍后再次检查。"
        fi
    fi
    update_subscription_files
}

# 9. 设置 CDN 优选域名 / IP
set_cdn_ip() {
    echo
    green "当前优选域名/IP: $(cat /etc/s-box/cdn.log 2>/dev/null || echo "cloudflare-ech.com")"
    yellow "推荐常见 Cloudflare 优选域名/IP："
    blue "  cloudflare-ech.com"
    blue "  www.visa.com.sg"
    blue "  www.wto.org"
    blue "  www.shopify.com"
    blue "  或任意 Cloudflare 优选 IP (例如 104.16.160.1)"
    echo
    readp "请输入自定义 CDN 优选域名/IP (回车保持当前): " cdn_input
    if [[ -n "$cdn_input" ]]; then
        echo "$cdn_input" > /etc/s-box/cdn.log
        green "CDN 优选地址已成功更新为: $cdn_input"
    fi
    update_subscription_files
}

# 10. 核心：生成三种格式订阅文件 (.txt, .json, .yaml)
update_subscription_files() {
    local uuid port path argo_domain cdn_ip ps_tag
    uuid=$(cat /etc/s-box/uuid.log 2>/dev/null)
    port=$(cat /etc/s-box/port.log 2>/dev/null)
    path=$(cat /etc/s-box/path.log 2>/dev/null)
    argo_domain=$(cat /etc/s-box/argoym.log 2>/dev/null)
    cdn_ip=$(cat /etc/s-box/cdn.log 2>/dev/null || echo "cloudflare-ech.com")
    ps_tag=$(cat /etc/s-box/ps_tag.log 2>/dev/null || echo "VMess-Argo-TLS-Temp")

    if [[ -z "$argo_domain" && -f /etc/s-box/argo.log ]]; then
        argo_domain=$(grep -a -oE "[a-zA-Z0-9.-]+\\.trycloudflare\\.com" /etc/s-box/argo.log | head -n 1)
    fi

    local sni_host="${argo_domain:-example.com}"

    mkdir -p /etc/s-box/web

    # --------------------------------------------------------------------------
    # 格式 1: .txt 聚合分享链接 (VMess 链接文件 jhsub.txt)
    # --------------------------------------------------------------------------
    local vmess_json vmess_json_compact vmess_base64 vmess_link
    vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "${ps_tag}",
  "add": "${cdn_ip}",
  "port": "8443",
  "id": "${uuid}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${sni_host}",
  "path": "/${path}",
  "tls": "tls",
  "sni": "${sni_host}",
  "fp": "chrome"
}
EOF
)
    vmess_json_compact=$(echo "$vmess_json" | jq -c .)
    vmess_base64=$(echo -n "$vmess_json_compact" | base64 -w 0)
    vmess_link="vmess://${vmess_base64}"

    echo "$vmess_link" > /etc/s-box/web/jhsub.txt

    # --------------------------------------------------------------------------
    # 格式 2: .json (Sing-box 客户端完整配置 sbox.json)
    # 包含 DoH DNS、Fake-IP 隔离、download_detour: direct 防死锁及 PacketAddr
    # --------------------------------------------------------------------------
    cat > /etc/s-box/web/sbox.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "./cache.db",
      "store_fakeip": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui",
      "default_mode": "Rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "aliDns",
        "type": "https",
        "server": "dns.alidns.com",
        "path": "/dns-query",
        "domain_resolver": "local"
      },
      {
        "tag": "local",
        "type": "udp",
        "server": "223.5.5.5"
      },
      {
        "tag": "proxyDns",
        "type": "https",
        "server": "dns.google",
        "path": "/dns-query",
        "domain_resolver": "aliDns",
        "detour": "proxy"
      },
      {
        "type": "fakeip",
        "tag": "fakeip",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "clash_mode": "Rule",
        "server": "aliDns"
      },
      {
        "clash_mode": "Direct",
        "server": "local"
      },
      {
        "clash_mode": "Global",
        "server": "proxyDns"
      },
      {
        "query_type": ["A", "AAAA"],
        "server": "fakeip"
      }
    ],
    "final": "proxyDns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fd00::1/126"],
      "auto_route": true,
      "strict_route": true
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "tun-in",
        "action": "sniff"
      },
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          { "port": 53 },
          { "protocol": "dns" }
        ],
        "action": "hijack-dns"
      },
      {
        "clash_mode": "Global",
        "outbound": "proxy"
      },
      {
        "rule_set": ["geosite-telegram", "geoip-telegram"],
        "clash_mode": "Rule",
        "outbound": "proxy"
      },
      {
        "rule_set": "geosite-cn",
        "clash_mode": "Rule",
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-cn",
        "clash_mode": "Rule",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "clash_mode": "Rule",
        "outbound": "direct"
      },
      {
        "clash_mode": "Direct",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geosite-telegram",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/telegram.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geoip-telegram",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/telegram.srs",
        "download_detour": "direct"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "aliDns"
    }
  },
  "outbounds": [
    {
      "type": "vmess",
      "tag": "proxy-vmess",
      "server": "${cdn_ip}",
      "server_port": 8443,
      "uuid": "${uuid}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "transport": {
        "type": "ws",
        "path": "/${path}",
        "headers": {
          "Host": ["${sni_host}"]
        }
      },
      "tls": {
        "enabled": true,
        "server_name": "${sni_host}",
        "insecure": false,
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "tag": "proxy",
      "type": "selector",
      "default": "auto",
      "outbounds": [
        "auto",
        "proxy-vmess"
      ]
    },
    {
      "tag": "auto",
      "type": "urltest",
      "outbounds": [
        "proxy-vmess"
      ],
      "url": "http://www.gstatic.com/generate_204",
      "interval": "10m",
      "tolerance": 50
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # --------------------------------------------------------------------------
    # 格式 3: .yaml (Mihomo / Clash Meta 客户端完整配置 clmi.yaml)
    # 包含 unified-delay、fake-ip-filter、DoH DNS 与完整 GEOSITE+GEOIP 分流
    # --------------------------------------------------------------------------
    cat > /etc/s-box/web/clmi.yaml <<EOF
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
dns:
  enable: true 
  listen: "0.0.0.0:1053"
  ipv6: false
  prefer-h3: false
  respect-rules: true
  use-system-hosts: false
  cache-algorithm: "arc"
  enhanced-mode: "fake-ip"
  fake-ip-range: "198.18.0.1/16"
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
    - "localhost.sec.qq.com"
    - "+.in-addr.arpa"
    - "+.ip6.arpa"
    - "time.*.com"
    - "time.*.gov"
    - "pool.ntp.org"
    - "localhost.work.weixin.qq.com"
  default-nameserver: ["223.5.5.5", "119.29.29.29"]
  nameserver:
    - "https://208.67.222.222/dns-query"
    - "https://1.1.1.1/dns-query"
    - "https://8.8.4.4/dns-query"
  proxy-server-nameserver:
    - "https://223.5.5.5/dns-query"
    - "https://doh.pub/dns-query"
  nameserver-policy:
    "geosite:private,cn":
      - "https://223.5.5.5/dns-query"
      - "https://doh.pub/dns-query"

proxies:
  - name: "${ps_tag}"
    type: vmess
    server: "${cdn_ip}"
    port: 8443
    uuid: "${uuid}"
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: "${sni_host}"
    network: ws
    ws-opts:
      path: "/${path}"
      headers:
        Host: "${sni_host}"

proxy-groups:
  - name: 负载均衡
    type: load-balance
    url: https://www.gstatic.com/generate_204
    interval: 300
    strategy: round-robin
    proxies:
      - "${ps_tag}"

  - name: 自动选择
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
      - "${ps_tag}"

  - name: 🌍选择代理节点
    type: select
    proxies:
      - 负载均衡
      - 自动选择
      - DIRECT
      - "${ps_tag}"

rules:
  - GEOIP,LAN,DIRECT
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🌍选择代理节点
EOF
}

# 11. 管理本地 IP 订阅服务
manage_local_sub() {
    echo
    green "【 本地 IP 订阅管理 】"
    yellow "1. 开启 / 更新本地 IP 订阅"
    yellow "2. 停止本地 IP 订阅"
    readp "请选择【1-2】: " sub_choice

    if [[ "$sub_choice" == "1" ]]; then
        local sub_port sub_token
        sub_port=$(shuf -i 10000-65535 -n 1)
        readp "请输入订阅端口 (回车默认随机使用 ${sub_port}): " user_sub_port
        sub_port=${user_sub_port:-$sub_port}
        
        readp "请输入订阅路径 Token (回车默认使用 UUID): " sub_token
        sub_token=${sub_token:-$(cat /etc/s-box/uuid.log 2>/dev/null)}

        pkill -f "httpd.*s-box" 2>/dev/null
        pkill -f "python3 -m http.server" 2>/dev/null

        local public_ip
        public_ip=$(get_public_ip)

        mkdir -p "/etc/s-box/web/${sub_token}"
        cp /etc/s-box/web/sbox.json "/etc/s-box/web/${sub_token}/sbox.json"
        cp /etc/s-box/web/clmi.yaml "/etc/s-box/web/${sub_token}/clmi.yaml"
        cp /etc/s-box/web/jhsub.txt "/etc/s-box/web/${sub_token}/jhsub.txt"

        if command -v busybox >/dev/null 2>&1; then
            nohup busybox httpd -f -p "${sub_port}" -h /etc/s-box/web >/dev/null 2>&1 &
        else
            nohup python3 -m http.server "${sub_port}" --directory /etc/s-box/web >/dev/null 2>&1 &
        fi

        echo "$sub_port" > /etc/s-box/sub_port.log
        echo "$sub_token" > /etc/s-box/sub_token.log

        green "本地 IP 订阅服务已启动！三种格式地址如下："
        white "------------------------------------------------------------------"
        echo -e "1. 节点链接 (.txt)   : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/jhsub.txt${plain}"
        echo -e "2. Sing-box (.json)  : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/sbox.json${plain}"
        echo -e "3. Mihomo   (.yaml)  : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/clmi.yaml${plain}"
        white "------------------------------------------------------------------"
    else
        pkill -f "httpd.*s-box" 2>/dev/null
        pkill -f "python3 -m http.server" 2>/dev/null
        green "本地 IP 订阅服务已停止。"
    fi
}

# 12. 管理 GitLab 私有订阅
manage_gitlab_sub() {
    echo
    green "【 GitLab 私有订阅管理 】"
    green "请确保在 GitLab 官网上已创建项目并生成了访问令牌 (Access Token)"
    readp "请输入登录 Email: " git_email
    readp "请输入 Access Token: " git_token
    readp "请输入 GitLab 用户名: " git_user
    readp "请输入 项目名称 (Repository Name): " git_repo
    readp "请输入 分支名称 (默认 main): " git_branch
    git_branch=${git_branch:-main}

    if [[ -z "$git_token" || -z "$git_user" || -z "$git_repo" ]]; then
        red "信息不完整，无法配置 GitLab 订阅。" && return
    fi

    update_subscription_files

    cd /etc/s-box/web || exit
    rm -rf .git
    git init >/dev/null 2>&1
    git config user.email "${git_email:-admin@example.com}"
    git config user.name "${git_user}"
    git add sbox.json clmi.yaml jhsub.txt
    git commit -m "update sub $(date)" >/dev/null 2>&1
    git branch -M "${git_branch}" >/dev/null 2>&1
    git remote add origin "https://${git_user}:${git_token}@gitlab.com/${git_user}/${git_repo}.git" >/dev/null 2>&1

    green "正在推送订阅配置至 GitLab……"
    if git push -u origin "${git_branch}" --force >/dev/null 2>&1; then
        green "GitLab 订阅推送成功！三种格式地址如下："
        white "------------------------------------------------------------------"
        echo -e "1. 节点链接 (.txt)   : ${yellow}https://gitlab.com/api/v4/projects/${git_user}%2F${git_repo}/repository/files/jhsub.txt/raw?ref=${git_branch}&private_token=${git_token}${plain}"
        echo -e "2. Sing-box (.json)  : ${yellow}https://gitlab.com/api/v4/projects/${git_user}%2F${git_repo}/repository/files/sbox.json/raw?ref=${git_branch}&private_token=${git_token}${plain}"
        echo -e "3. Mihomo   (.yaml)  : ${yellow}https://gitlab.com/api/v4/projects/${git_user}%2F${git_repo}/repository/files/clmi.yaml/raw?ref=${git_branch}&private_token=${git_token}${plain}"
        white "------------------------------------------------------------------"
    else
        red "GitLab 推送失败，请检查 Token 权限或仓库名称是否正确。"
    fi
    cd /root || exit
}

# 13. 显示节点信息、二维码与三种格式订阅
show_node() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        red "Sing-box 未安装或未生成配置！" && return
    fi

    update_subscription_files

    local uuid port path argo_domain cdn_ip ps_tag
    uuid=$(cat /etc/s-box/uuid.log 2>/dev/null)
    port=$(cat /etc/s-box/port.log 2>/dev/null)
    path=$(cat /etc/s-box/path.log 2>/dev/null)
    argo_domain=$(cat /etc/s-box/argoym.log 2>/dev/null)
    cdn_ip=$(cat /etc/s-box/cdn.log 2>/dev/null || echo "cloudflare-ech.com")
    ps_tag=$(cat /etc/s-box/ps_tag.log 2>/dev/null || echo "VMess-Argo-TLS-Temp")

    if [[ -z "$argo_domain" && -f /etc/s-box/argo.log ]]; then
        argo_domain=$(grep -a -oE "[a-zA-Z0-9.-]+\\.trycloudflare\\.com" /etc/s-box/argo.log | head -n 1)
    fi

    local sni_host="${argo_domain:-example.com}"

    white "=================================================================="
    blue "🚀【 VMess + WebSocket + TLS + Cloudflare Argo 】节点信息："
    white "=================================================================="
    echo -e "节点名称 (PS): ${yellow}${ps_tag}${plain}"
    echo -e "UUID         : ${yellow}${uuid}${plain}"
    echo -e "监听端口     : ${yellow}${port}${plain}"
    echo -e "传输协议     : ${yellow}WebSocket (ws)${plain}"
    echo -e "Path 路径    : ${yellow}/${path}${plain}"
    echo -e "Argo 域名    : ${yellow}${argo_domain:-未获取到}${plain}"
    echo -e "优选域名/IP  : ${yellow}${cdn_ip}${plain}"
    echo -e "TLS 端口     : ${yellow}8443${plain}"
    white "------------------------------------------------------------------"

    local vmess_link
    vmess_link=$(cat /etc/s-box/web/jhsub.txt 2>/dev/null)

    echo -e "分享链接 (.txt 格式)："
    echo -e "${yellow}${vmess_link}${plain}"
    echo
    echo -e "二维码："
    qrencode -o - -t ANSIUTF8 "${vmess_link}" 2>/dev/null
    white "=================================================================="

    # 如果启动了本地订阅，打印三种格式链接
    if [[ -f /etc/s-box/sub_port.log && -f /etc/s-box/sub_token.log ]]; then
        local sub_port sub_token public_ip
        sub_port=$(cat /etc/s-box/sub_port.log)
        sub_token=$(cat /etc/s-box/sub_token.log)
        public_ip=$(get_public_ip)
        echo -e "本地 IP 三种格式订阅 URL :"
        echo -e " 1. 节点链接 (.txt)  : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/jhsub.txt${plain}"
        echo -e " 2. Sing-box (.json) : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/sbox.json${plain}"
        echo -e " 3. Mihomo   (.yaml) : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/clmi.yaml${plain}"
        white "=================================================================="
    fi
}

# 14. 一键安装全流程
install_all() {
    install_dependencies
    install_singbox
    readp "设置 VMess 本地监听端口 (默认 8088): " user_port
    user_port=${user_port:-8088}
    
    generate_config "$user_port"
    setup_service
    setup_argo
    show_node
}

# 15. 卸载函数
uninstall_all() {
    systemctl stop sing-box argo 2>/dev/null
    systemctl disable sing-box argo 2>/dev/null
    pkill -f "httpd.*s-box" 2>/dev/null
    pkill -f "python3 -m http.server" 2>/dev/null
    rm -rf /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
    systemctl daemon-reload 2>/dev/null
    pkill -f "cloudflared" 2>/dev/null
    pkill -f "sing-box" 2>/dev/null
    rm -rf /etc/s-box
    green "Sing-box (VMess + Argo TLS) 及订阅服务已完全卸载！"
}

# 主菜单
main_menu() {
    clear
    white "=================================================================="
    blue "     Sing-box (VMess + WS + TLS + Cloudflare Argo) 极简全能版     "
    white "=================================================================="
    green " 1. 一键安装/重置 VMess + Argo TLS"
    green " 2. 查看节点信息与三格式订阅 (.txt / .json / .yaml)"
    green " 3. 设置/修改 CDN 优选域名/IP (针对 Argo TLS 套 CDN)"
    green " 4. 重置 / 切换 Argo 隧道模式 (临时 / 固定)"
    green " 5. 重置 / 设置 WARP WireGuard IPv6 优先分流域名"
    green " 6. 管理本地 IP 三格式订阅服务 (.txt / .json / .yaml)"
    green " 7. 管理 GitLab 私有三格式订阅推送 (.txt / .json / .yaml)"
    green " 8. 重启 Sing-box 服务"
    green " 9. 停止 Sing-box 服务"
    green "10. 查看 Sing-box 运行日志"
    green "11. 卸载 Sing-box 与 Argo"
    white "------------------------------------------------------------------"
    green " 0. 退出脚本"
    white "=================================================================="
    
    readp "请输入选项 [0-11]: " choice
    case "$choice" in
        1) install_all ;;
        2) show_node ;;
        3) set_cdn_ip && show_node ;;
        4) setup_argo && show_node ;;
        5) reset_warp_v6_domains ;;
        6) manage_local_sub ;;
        7) manage_gitlab_sub ;;
        8) systemctl restart sing-box && green "服务已重启" ;;
        9) systemctl stop sing-box && green "服务已停止" ;;
        10) journalctl -u sing-box.service -o cat -f ;;
        11) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

main_menu
