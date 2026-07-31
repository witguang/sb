#!/bin/bash
# ==============================================================================
# Sing-box VMess + WebSocket + TLS + Cloudflare Argo 极简全能版
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
        apt-get install -y curl jq tar wget unzip procps psmisc qrencode git busybox
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y curl jq tar wget unzip procps psmisc qrencode git busybox epel-release
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
        dnf install -y curl jq tar wget unzip procps psmisc qrencode git busybox
    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add bash curl jq tar wget unzip procps qrencode git busybox
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

# 5. 生成服务端配置文件
generate_config() {
    local port=${1:-8080}
    local uuid=${2:-$(/etc/s-box/sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
    local ws_path=${3:-"${uuid}-vm"}

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
    }
  ]
}
EOF
    echo "$port" > /etc/s-box/port.log
    echo "$uuid" > /etc/s-box/uuid.log
    echo "$ws_path" > /etc/s-box/path.log
    if [[ ! -f /etc/s-box/cdn.log ]]; then
        echo "cloudflare-ech.com" > /etc/s-box/cdn.log
    fi
}

# 6. 配置服务项
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

# 7. 启动/配置 Argo 隧道
setup_argo() {
    install_cloudflared
    local port
    port=$(cat /etc/s-box/port.log 2>/dev/null || echo "8080")

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
        temp_domain=$(grep -a -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" /etc/s-box/argo.log | head -n 1 | sed "s|https://||")
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

# 8. 设置 CDN 优选域名 / IP
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

# 9. 生成客户端订阅文件 (sbox.json, clmi.yaml, jhsub.txt)
update_subscription_files() {
    local uuid port path argo_domain cdn_ip ps_tag
    uuid=$(cat /etc/s-box/uuid.log 2>/dev/null)
    port=$(cat /etc/s-box/port.log 2>/dev/null)
    path=$(cat /etc/s-box/path.log 2>/dev/null)
    argo_domain=$(cat /etc/s-box/argoym.log 2>/dev/null)
    cdn_ip=$(cat /etc/s-box/cdn.log 2>/dev/null || echo "cloudflare-ech.com")
    ps_tag=$(cat /etc/s-box/ps_tag.log 2>/dev/null || echo "VMess-Argo-TLS-Temp")

    if [[ -z "$argo_domain" && -f /etc/s-box/argo.log ]]; then
        argo_domain=$(grep -a -oE "[a-zA-Z0-9.-]+\.trycloudflare\.com" /etc/s-box/argo.log | head -n 1)
    fi

    local sni_host="${argo_domain:-example.com}"

    # 1) 生成 VMess 节点链接 (端口 8443)
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

    mkdir -p /etc/s-box/web

    # 2) 聚合链接文件
    echo "$vmess_link" > /etc/s-box/web/jhsub.txt

    # 3) Sing-box 客户端 sbox.json
    cat > /etc/s-box/web/sbox.json <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-remote", "address": "https://dns.google/dns-query", "detour": "proxy" },
      { "tag": "dns-direct", "address": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [
      { "outbound": "any", "server": "dns-direct" }
    ]
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "inet4_address": "172.19.0.1/30", "auto_route": true, "strict_route": true }
  ],
  "outbounds": [
    {
      "type": "vmess",
      "tag": "proxy",
      "server": "${cdn_ip}",
      "server_port": 8443,
      "uuid": "${uuid}",
      "security": "auto",
      "transport": {
        "type": "ws",
        "path": "/${path}",
        "headers": { "Host": "${sni_host}" }
      },
      "tls": {
        "enabled": true,
        "server_name": "${sni_host}",
        "insecure": false,
        "utls": { "enabled": true, "fingerprint": "chrome" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

    # 4) Mihomo / Clash Meta 客户端 clmi.yaml
    cat > /etc/s-box/web/clmi.yaml <<EOF
port: 7890
allow-lan: true
mode: rule
log-level: info
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
  - name: 🚀 节点选择
    type: select
    proxies:
      - "${ps_tag}"
      - DIRECT
rules:
  - GEOIP,LAN,DIRECT
  - MATCH,🚀 节点选择
EOF
}

# 10. 管理本地 IP 订阅服务
manage_local_sub() {
    echo
    green "【 本地 IP 订阅管理 】"
    yellow "1. 开启 / 更新本地 IP 订阅"
    yellow "2. 停止本地 IP 订阅"
    readp "请选择【1-2】: " sub_choice

    if [[ "$sub_choice" == "1" ]]; then
        readp "请输入订阅端口 (默认 8888): " sub_port
        sub_port=${sub_port:-8888}
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

        green "本地 IP 订阅服务已启动！"
        white "------------------------------------------------------------------"
        echo -e "Sing-box 订阅  : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/sbox.json${plain}"
        echo -e "Mihomo/Clash   : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/clmi.yaml${plain}"
        echo -e "聚合节点链接   : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/jhsub.txt${plain}"
        white "------------------------------------------------------------------"
    else
        pkill -f "httpd.*s-box" 2>/dev/null
        pkill -f "python3 -m http.server" 2>/dev/null
        green "本地 IP 订阅服务已停止。"
    fi
}

# 11. 管理 GitLab 私有订阅
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
        green "GitLab 订阅推送成功！"
        white "------------------------------------------------------------------"
        echo -e "Sing-box 订阅  : ${yellow}https://gitlab.com/api/v4/projects/${git_user}%2F${git_repo}/repository/files/sbox.json/raw?ref=${git_branch}&private_token=${git_token}${plain}"
        echo -e "Mihomo/Clash   : ${yellow}https://gitlab.com/api/v4/projects/${git_user}%2F${git_repo}/repository/files/clmi.yaml/raw?ref=${git_branch}&private_token=${git_token}${plain}"
        echo -e "聚合节点链接   : ${yellow}https://gitlab.com/api/v4/projects/${git_user}%2F${git_repo}/repository/files/jhsub.txt/raw?ref=${git_branch}&private_token=${git_token}${plain}"
        white "------------------------------------------------------------------"
    else
        red "GitLab 推送失败，请检查 Token 权限或仓库名称是否正确。"
    fi
    cd /root || exit
}

# 12. 显示节点信息与二维码
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

    echo -e "分享链接："
    echo -e "${yellow}${vmess_link}${plain}"
    echo
    echo -e "二维码："
    qrencode -o - -t ANSIUTF8 "${vmess_link}" 2>/dev/null
    white "=================================================================="

    # 如果启动了本地订阅，额外打印订阅链接
    if [[ -f /etc/s-box/sub_port.log && -f /etc/s-box/sub_token.log ]]; then
        local sub_port sub_token public_ip
        sub_port=$(cat /etc/s-box/sub_port.log)
        sub_token=$(cat /etc/s-box/sub_token.log)
        public_ip=$(get_public_ip)
        echo -e "本地 IP 订阅 URL :"
        echo -e " - Sing-box  : ${yellow}http://${public_ip}:${sub_port}/${sub_token}/sbox.json${plain}"
        echo -e " - Mihomo/Clash: ${yellow}http://${public_ip}:${sub_port}/${sub_token}/clmi.yaml${plain}"
        white "=================================================================="
    fi
}

# 13. 一键安装全流程
install_all() {
    install_dependencies
    install_singbox
    readp "设置 VMess 本地监听端口 (默认 8080): " user_port
    user_port=${user_port:-8080}
    
    generate_config "$user_port"
    setup_service
    setup_argo
    show_node
}

# 14. 卸载函数
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
    green " 2. 查看当前节点信息 & 二维码"
    green " 3. 设置/修改 CDN 优选域名/IP (针对 Argo TLS 套 CDN)"
    green " 4. 重置 / 切换 Argo 隧道模式 (临时 / 固定)"
    green " 5. 管理本地 IP 订阅服务 (httpd / Python HTTP)"
    green " 6. 管理 GitLab 私有订阅推送"
    green " 7. 重启 Sing-box 服务"
    green " 8. 停止 Sing-box 服务"
    green " 9. 查看 Sing-box 运行日志"
    green "10. 卸载 Sing-box 与 Argo"
    white "------------------------------------------------------------------"
    green " 0. 退出脚本"
    white "=================================================================="
    
    readp "请输入选项 [0-10]: " choice
    case "$choice" in
        1) install_all ;;
        2) show_node ;;
        3) set_cdn_ip && show_node ;;
        4) setup_argo && show_node ;;
        5) manage_local_sub ;;
        6) manage_gitlab_sub ;;
        7) systemctl restart sing-box && green "服务已重启" ;;
        8) systemctl stop sing-box && green "服务已停止" ;;
        9) journalctl -u sing-box.service -o cat -f ;;
        10) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

main_menu
