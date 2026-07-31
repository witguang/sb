#!/bin/bash
# ==============================================================================
# Sing-box VMess + WebSocket + TLS + Cloudflare Argo 专一优化版
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

mkdir -p /etc/s-box

# 2. 安装必要依赖
install_dependencies() {
    green "检查并安装必要依赖……"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl jq tar wget unzip procps psmisc qrencode
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y curl jq tar wget unzip procps psmisc qrencode epel-release
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
        dnf install -y curl jq tar wget unzip procps psmisc qrencode
    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add bash curl jq tar wget unzip procps qrencode
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

# 5. 生成配置文件
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
            green "临时 Argo 域名生成成功: ${temp_domain}"
        else
            red "临时 Argo 域名生成超时，请稍后执行菜单 [2] 查看。"
        fi
    fi
}

# 8. 显示节点信息与二维码
show_node() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        red "Sing-box 未安装或未生成配置！" && return
    fi

    local uuid port path argo_domain
    uuid=$(cat /etc/s-box/uuid.log 2>/dev/null)
    port=$(cat /etc/s-box/port.log 2>/dev/null)
    path=$(cat /etc/s-box/path.log 2>/dev/null)
    argo_domain=$(cat /etc/s-box/argoym.log 2>/dev/null)

    if [[ -z "$argo_domain" && -f /etc/s-box/argo.log ]]; then
        argo_domain=$(grep -a -oE "[a-zA-Z0-9.-]+\.trycloudflare\.com" /etc/s-box/argo.log | head -n 1)
    fi

    local sni_host="${argo_domain:-example.com}"

    white "=================================================================="
    blue "🚀【 VMess + WebSocket + TLS + Cloudflare Argo 】节点信息："
    white "=================================================================="
    echo -e "UUID       : ${yellow}${uuid}${plain}"
    echo -e "监听端口   : ${yellow}${port}${plain}"
    echo -e "传输协议   : ${yellow}WebSocket (ws)${plain}"
    echo -e "Path 路径  : ${yellow}/${path}${plain}"
    echo -e "Argo 域名  : ${yellow}${argo_domain:-未获取到}${plain}"
    white "------------------------------------------------------------------"

    # 构建 VMess JSON
    local vmess_json
    vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "VMess-Argo-TLS-${HOSTNAME:-vps}",
  "add": "cloudflare-ech.com",
  "port": "443",
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
    local vmess_json_compact vmess_base64 vmess_link
    vmess_json_compact=$(echo "$vmess_json" | jq -c .)
    vmess_base64=$(echo -n "$vmess_json_compact" | base64 -w 0)
    vmess_link="vmess://${vmess_base64}"

    echo -e "分享链接："
    echo -e "${yellow}${vmess_link}${plain}"
    echo
    echo -e "二维码："
    qrencode -o - -t ANSIUTF8 "${vmess_link}" 2>/dev/null
    white "=================================================================="
}

# 9. 一键安装全流程
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

# 10. 卸载函数
uninstall_all() {
    systemctl stop sing-box argo 2>/dev/null
    systemctl disable sing-box argo 2>/dev/null
    rm -rf /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
    systemctl daemon-reload 2>/dev/null
    pkill -f "cloudflared" 2>/dev/null
    pkill -f "sing-box" 2>/dev/null
    rm -rf /etc/s-box
    green "Sing-box (VMess + Argo TLS) 已完全卸载！"
}

# 主菜单
main_menu() {
    clear
    white "=================================================================="
    blue "     Sing-box (VMess + WS + TLS + Cloudflare Argo) 专一优化版     "
    white "=================================================================="
    green " 1. 一键安装/重置 VMess + Argo TLS"
    green " 2. 查看当前节点信息 & 二维码"
    green " 3. 重置 / 切换 Argo 隧道模式 (临时 / 固定)"
    green " 4. 重启 Sing-box 服务"
    green " 5. 停止 Sing-box 服务"
    green " 6. 查看 Sing-box 运行日志"
    green " 7. 卸载 Sing-box 与 Argo"
    white "------------------------------------------------------------------"
    green " 0. 退出脚本"
    white "=================================================================="
    
    readp "请输入选项 [0-7]: " choice
    case "$choice" in
        1) install_all ;;
        2) show_node ;;
        3) setup_argo && show_node ;;
        4) systemctl restart sing-box && green "服务已重启" ;;
        5) systemctl stop sing-box && green "服务已停止" ;;
        6) journalctl -u sing-box.service -o cat -f ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

main_menu
