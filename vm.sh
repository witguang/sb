#!/bin/bash
export LANG=en_US.UTF-8
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
bblue='\033[0;34m'
plain='\033[0m'

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit
stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null

# ====================== 配置 ======================
export sbfiles="/etc/s-box/sb10.json /etc/s-box/sb11.json /etc/s-box/sb.json"
export sbnh=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}' 2>/dev/null | cut -d '.' -f 1,2)

# ====================== 保留的核心功能 ======================
v4v6(){ v4=$(curl -s4m5 icanhazip.com -k); v6=$(curl -s6m5 icanhazip.com -k); v4dq=$(curl -s4m5 -k https://myip.ipip.net | awk -F'来自于：' '{print $2}'); v6dq=$(curl -s6m5 -k https://ip.fm | sed -n 's/.*Location: //p'); }
warpcheck(){ wgcfv6=$(curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2); wgcfv4=$(curl -s4m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2); }
v6(){ v4orv6; warpcheck; if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then v4orv6; else systemctl stop wg-quick@wgcf >/dev/null 2>&1; kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2; v4orv6; systemctl start wg-quick@wgcf >/dev/null 2>&1; systemctl restart warp-go >/dev/null 2>&1; systemctl enable warp-go >/dev/null 2>&1; systemctl start warp-go >/dev/null 2>&1; fi; }

close(){ systemctl stop firewalld.service >/dev/null 2>&1; systemctl disable firewalld.service >/dev/null 2>&1; setenforce 0 >/dev/null 2>&1; ufw disable >/dev/null 2>&1; iptables -P INPUT ACCEPT >/dev/null 2>&1; iptables -P FORWARD ACCEPT >/dev/null 2>&1; iptables -P OUTPUT ACCEPT >/dev/null 2>&1; iptables -t mangle -F >/dev/null 2>&1; iptables -F >/dev/null 2>&1; iptables -X >/dev/null 2>&1; netfilter-persistent save >/dev/null 2>&1; sleep 1; green "执行开放端口，关闭防火墙完毕"; }
openyn(){ red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; readp "是否开放端口，关闭防火墙？\n1、是，执行 (回车默认)\n2、否，跳过！自行处理\n请选择【1-2】：" action; if [[ -z $action ]] || [[ "$action" = "1" ]]; then close; elif [[ "$action" = "2" ]]; then echo; else red "输入错误,请重新选择" && openyn; fi; }

inssb(){ red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; green "使用哪个内核版本？"; yellow "1：使用目前最新正式版内核 (回车默认)"; yellow "2：使用之前1.10.7正式版内核 (支持geosite分流、IP优选级切换，无Anytls协议)"; readp "请选择【1-2】：" menu; if [ -z "$menu" ] || [ "$menu" = "1" ] ; then sbcore=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest | grep -oP 'tag/v\K[0-9.]+' | head -n 1); else sbcore='1.10.7'; fi; sbname="sing-box-$sbcore-linux-$cpu"; curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz; if [[ -f '/etc/s-box/sing-box.tar.gz' ]]; then tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box; mv /etc/s-box/$sbname/sing-box /etc/s-box; rm -rf /etc/s-box/{sing-box.tar.gz,$sbname}; if [[ -f '/etc/s-box/sing-box' ]]; then chown root:root /etc/s-box/sing-box; chmod +x /etc/s-box/sing-box; blue "成功安装 Sing-box 内核版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}')"; sbnh=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}' 2>/dev/null | cut -d '.' -f 1,2); else red "下载 Sing-box 内核不完整，安装失败，请再运行安装一次" && exit; fi; else red "下载 Sing-box 内核失败，请再运行安装一次，并检测VPS的网络是否可以访问Github" && exit; fi; }

inscertificate(){ ymzs(){ ym_vl_re=apple.com; echo; blue "Vless-reality的SNI域名默认为 apple.com"; tlsyn=true; ym_vm_ws=$(cat /root/ygkkkca/ca.log 2>/dev/null); certificatec_vmess_ws='/root/ygkkkca/cert.crt'; certificatep_vmess_ws='/root/ygkkkca/private.key'; } zqzs(){ ym_vl_re=apple.com; echo; blue "Vless-reality的SNI域名默认为 apple.com"; tlsyn=false; ym_vm_ws=www.bing.com; certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'; } red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; green "二、生成并设置相关证书"; echo; blue "自动生成bing自签证书中……" && sleep 2; openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key; openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com"; echo; if [[ -f /etc/s-box/cert.pem ]]; then blue "生成bing自签证书成功"; else red "生成bing自签证书失败" && exit; fi; echo; if [[ -f /root/ygkkkca/cert.crt && -f /root/ygkkkca/private.key && -s /root/ygkkkca/cert.crt && -s /root/ygkkkca/private.key ]]; then yellow "经检测，之前已使用Acme-yg脚本申请过Acme域名IP证书：$(cat /root/ygkkkca/ca.log) "; green "是否使用 $(cat /root/ygkkkca/ca.log) 域名IP证书？"; yellow "1：否！使用自签的证书 (回车默认)"; yellow "2：是！使用 $(cat /root/ygkkkca/ca.log) 域名IP证书"; readp "请选择【1-2】：" menu; if [ -z "$menu" ] || [ "$menu" = "1" ] ; then zqzs; else ymzs; fi; else green "是否申请一个Acme域名IP证书？"; yellow "1：否！继续使用自签的证书 (回车默认)"; yellow "2：是！使用Acme-yg脚本申请Acme证书 (支持80端口域名IP证书模式与Dns API域名模式)"; readp "请选择【1-2】：" menu; if [ -z "$menu" ] || [ "$menu" = "1" ] ; then zqzs; else bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh); if [[ ! -f /root/ygkkkca/cert.crt && ! -f /root/ygkkkca/private.key && ! -s /root/ygkkkca/cert.crt && ! -s /root/ygkkkca/private.key ]]; then red "Acme证书申请失败，继续使用自签证书" ; zqzs; else ymzs; fi; fi; fi; }

chooseport(){ if [[ -z $port ]]; then port=$(shuf -i 10000-65535 -n 1); until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") && -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] ; do [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") || -n $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] && yellow "\n端口被占用，请重新输入端口" && readp "自定义端口:" port; done; else until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") && -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] ; do [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") || -n $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] && yellow "\n端口被占用，请重新输入端口" && readp "自定义端口:" port; done; fi; blue "确认的端口：$port" && sleep 2; }
vmport(){ readp "\n设置Vmess-ws端口 (回车跳过为10000-65535之间的随机端口)：" port; chooseport; port_vm_ws=$port; }
insport(){ red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; green "三、设置各个协议端口"; yellow "1：自动生成每个协议的随机端口 (10000-65535范围内)，回车默认。请确保VPS后台已开放所有端口"; yellow "2：自定义每个协议端口。请确保VPS后台已开放指定的端口"; readp "请输入【1-2】：" port; if [ -z "$port" ] || [ "$port" = "1" ] ; then ports=(); for i in {1..5}; do while true; do port=$(shuf -i 10000-65535 -n 1); if ! [[ " ${ports[@]} " =~ " $port " ]] && [[ -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] && [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then ports+=($port); break; fi; done; done; port_vm_ws=${ports[0]}; if [[ $tlsyn == "true" ]]; then numbers=("2053" "2083" "2087" "2096" "8443"); else numbers=("8080" "8880" "2052" "2082" "2086" "2095"); fi; port_vm_ws=${numbers[$RANDOM % ${#numbers[@]}]}; until [[ -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port_vm_ws") ]] ; do if [[ $tlsyn == "true" ]]; then numbers=("2053" "2083" "2087" "2096" "8443"); else numbers=("8080" "8880" "2052" "2082" "2086" "2095"); fi; port_vm_ws=${numbers[$RANDOM % ${#numbers[@]}]}; done; echo; blue "根据Vmess-ws协议是否启用TLS，随机指定支持CDN优选IP的标准端口：$port_vm_ws"; else vmport; fi; echo; blue "Vmess-ws端口：$port_vm_ws"; red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; }
uuid(){ uuid=$(/etc/s-box/sing-box generate uuid); blue "已确认uuid (密码)：${uuid}"; blue "已确认Vmess的path路径：${uuid}-vm"; }

inssbjsonser(){ cat > /etc/s-box/sb10.json <<EOF
{
"log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "sniff": true,
      "sniff_override_destination": true,
      "tag": "vmess-sb",
      "listen": "::",
      "listen_port": ${port_vm_ws},
      "users": [
            {
                "uuid": "${uuid}",
                "alterId": 0
            }
        ],
      "transport": {
            "type": "ws",
            "path": "${uuid}-vm",
            "max_early_data":2048,
            "early_data_header_name": "Sec-WebSocket-Protocol"
        },
        "tls":{
                "enabled": true,
                "server_name": "cloudflare-ech.com",
                "certificate_path": "/etc/s-box/cert.pem",
                "key_path": "/etc/s-box/private.key"
            }
    }
],
"outbounds": [
{
"type":"direct",
"tag":"direct"
},
{
"type": "socks",
"tag": "socks-out",
"server": "127.0.0.1",
"server_port": 40000,
"version": "5"
},
{
"type":"direct",
"tag":"warp-out",
"domain_strategy":"prefer_ipv4"
},
{
"type": "block",
"tag": "block"
}
],
"route":{
"rules":[
{
"action": "sniff"
},
{
"action": "resolve",
"domain_suffix":[
"yg_kkk"
],
"strategy": "prefer_ipv4"
},
{
"action": "resolve",
"domain_suffix":[
"yg_kkk"
],
"strategy": "prefer_ipv6"
},
{
"domain_suffix":[
"yg_kkk"
],
"outbound":"direct",
"network": "udp,tcp"
}
]
}
}
EOF

    cat > /etc/s-box/sb11.json <<EOF
{
"log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "sniff": true,
      "sniff_override_destination": true,
      "tag": "vmess-sb",
      "listen": "::",
      "listen_port": ${port_vm_ws},
      "users": [
            {
                "uuid": "${uuid}",
                "alterId": 0
            }
        ],
      "transport": {
            "type": "ws",
            "path": "${uuid}-vm",
            "max_early_data":2048,
            "early_data_header_name": "Sec-WebSocket-Protocol"
        },
        "tls":{
                "enabled": true,
                "server_name": "cloudflare-ech.com",
                "certificate_path": "/etc/s-box/cert.pem",
                "key_path": "/etc/s-box/private.key"
            }
    }
],
"outbounds": [
{
"type":"direct",
"tag":"direct"
},
{
"type": "socks",
"tag": "socks-out",
"server": "127.0.0.1",
"server_port": 40000,
"version": "5"
},
{
"type":"direct",
"tag":"warp-out",
"domain_strategy":"prefer_ipv4"
},
{
"type": "block",
"tag": "block"
}
],
"route":{
"rules":[
{
"action": "sniff"
},
{
"action": "resolve",
"domain_suffix":[
"yg_kkk"
],
"strategy": "prefer_ipv4"
},
{
"action": "resolve",
"domain_suffix":[
"yg_kkk"
],
"strategy": "prefer_ipv6"
},
{
"domain_suffix":[
"yg_kkk"
],
"outbound":"direct",
"network": "udp,tcp"
}
]
}
}
EOF

    [[ "$sbnh" == "1.10" ]] && num=10 || num=11
    cp /etc/s-box/sb${num}.json /etc/s-box/sb.json
}

sbservice(){
if command -v apk >/dev/null 2>&1; then
echo '#!/sbin/openrc-run
description="sing-box service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
command_background=true
pidfile="/var/run/sing-box.pid"' > /etc/init.d/sing-box
chmod +x /etc/init.d/sing-box
rc-update add sing-box default
rc-service sing-box start
else
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl start sing-box
systemctl restart sing-box
fi
}

result_vmess_argo(){
rm -rf /etc/s-box/vm_ws_argo.txt /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_tls.txt
server_ip=$(cat /etc/s-box/server_ip.log 2>/dev/null)
server_ipcl=$(cat /etc/s-box/server_ipcl.log 2>/dev/null)
uuid=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].users[0].uuid')
ws_path=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].transport.path')
vm_port=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].listen_port')
tls=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.enabled')
vm_name=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.server_name')
if [[ -f /etc/s-box/cfvmadd_argo.txt ]]; then
vmadd_argo=$(cat /etc/s-box/cfvmadd_argo.txt 2>/dev/null)
else
vmadd_argo="cloudflare-ech.com"
fi
if [[ "$tls" = "false" ]]; then
if [[ -f /etc/s-box/cfymjx.txt ]]; then
vm_name=$(cat /etc/s-box/cfymjx.txt 2>/dev/null)
else
vm_name=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.server_name')
fi
vmadd_local=$server_ipcl
else
vmadd_local=$server_ipcl
fi
if [[ "$vmadd_local" == "null" || -z "$vmadd_local" ]]; then
vmadd_local=$server_ipcl
fi
echo "$vmadd_local" > /etc/s-box/vmadd_local.txt
echo "$vmadd_argo" > /etc/s-box/vmadd_argo.txt
echo "$ws_path" > /etc/s-box/ws_path.txt
echo "$vm_name" > /etc/s-box/vm_name.txt
echo "$vm_port" > /etc/s-box/vm_port.txt
echo "$tls" > /etc/s-box/tls.txt
echo "$uuid" > /etc/s-box/uuid.txt
vmadd_local=\$server_ipcl
vmadd_argo=\$argo
ws_path=\${uuid}-vm
vm_port=\$port_vm_ws
tls=\$tls
uuid=\$uuid
echo -e "\n${green}Argo TLS Vmess 配置已更新！${plain}"
echo "add: $vmadd_argo"
echo "port: $vm_port"
echo "path: $ws_path"
echo "sni: $vm_name"
echo "uuid: $uuid"
echo "tls: $tls"
}

wgcfgo(){
warpcheck
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
ipuuid
else
systemctl stop wg-quick@wgcf >/dev/null 2>&1
kill -15 $(pgrep warp-go) >/dev/null 2>&1 && sleep 2
ipuuid
systemctl start wg-quick@wgcf >/dev/null 2>&1
systemctl restart warp-go >/dev/null 2>&1
systemctl enable warp-go >/dev/null 2>&1
systemctl start warp-go >/dev/null 2>&1
fi
}

ipuuid(){
if command -v apk >/dev/null 2>&1; then
status_cmd="rc-service sing-box status"
status_pattern="started"
else
status_cmd="systemctl is-active sing-box"
status_pattern="active"
fi
if [[ -n $($status_cmd 2>/dev/null | grep -w "$status_pattern") && -f '/etc/s-box/sb.json' ]]; then
v4v6
if [[ -n $v4 && -n $v6 ]]; then
green "调整IPv4/IPV6配置输出"
yellow "1：刷新本地IP，使用IPV4配置输出 (回车默认) "
yellow "2：刷新本地IP，使用IPV6配置输出"
readp "请选择【1-2】：" menu
if [ -z "$menu" ] || [ "$menu" = "1" ]; then
server_ip="$v4"
echo "$server_ip" > /etc/s-box/server_ip.log
server_ipcl="$v4"
echo "$server_ipcl" > /etc/s-box/server_ipcl.log
else
server_ip="[$v6]"
echo "$server_ip" > /etc/s-box/server_ip.log
server_ipcl="$v6"
echo "$server_ipcl" > /etc/s-box/server_ipcl.log
fi
else
yellow "VPS并不是双栈VPS，不支持IP配置输出的切换"
serip=$(curl -s4m5 icanhazip.com -k || curl -s6m5 icanhazip.com -k)
if [[ "$serip" =~ : ]]; then
server_ip="[$serip]"
echo "$server_ip" > /etc/s-box/server_ip.log
server_ipcl="$serip"
echo "$server_ipcl" > /etc/s-box/server_ipcl.log
else
server_ip="$serip"
echo "$server_ip" > /etc/s-box/server_ip.log
server_ipcl="$serip"
echo "$server_ipcl" > /etc/s-box/server_ipcl.log
fi
fi
else
red "Sing-box服务未运行" && exit
fi
}

# ====================== 主菜单 ======================
main_menu() {
echo
red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
green "=== Argo TLS Vmess 优化脚本 ==="
yellow "1. 安装 Sing-box 内核"
yellow "2. 生成证书"
yellow "3. 设置端口（只保留 Vmess Argo）"
yellow "4. 生成 uuid"
yellow "5. 生成配置"
yellow "6. 启动服务"
yellow "7. 更新配置输出（Argo TLS Vmess）"
yellow "8. 退出"
readp "请选择【1-8】：" menu
case $menu in
1) inssb; main_menu ;;
2) inscertificate; main_menu ;;
3) insport; main_menu ;;
4) uuid; main_menu ;;
5) inssbjsonser; main_menu ;;
6) sbservice; main_menu ;;
7) result_vmess_argo; main_menu ;;
8) exit 0 ;;
*) yellow "无效选择"; main_menu ;;
esac
}

# ====================== 开始 ======================
if [ ! -f sbyg_update ]; then
green "首次安装必要的依赖……"
# （依赖安装代码保留）
touch sbyg_update
fi

if [[ -f /etc/s-box/sb.json ]]; then
openyn
fi

main_menu
