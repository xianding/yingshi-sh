#!/usr/bin/env bash

# =========================================================
# Realm 端口转发全自动管理脚本 (至简美化·高可读配色版)
# =========================================================

# 字体颜色定义 (仅用于状态和核心提示)
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 全局路径定义
REALM_DIR="/etc/realm"
REALM_BIN="/usr/local/bin/realm"
REALM_CONF="${REALM_DIR}/config.toml"
SYSTEMD_FILE="/etc/systemd/system/realm.service"
OPENRC_FILE="/etc/init.d/realm"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}" && exit 1

# 全局网络环境标记与状态
SUPPORT_IPV6=true
REMOTE_TYPE="" 

# --- 1. 环境与依赖检测 ---
check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    elif [[ -f /etc/alpine-release ]]; then
        release="alpine"
    else
        release="unknown"
    fi

    arch=$(uname -m)
    case ${arch} in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) echo -e "${RED}暂不支持当前系统架构: ${arch}${PLAIN}" && exit 1 ;;
    esac

    if [ ! -f /proc/net/if_inet6 ]; then
        SUPPORT_IPV6=false
    fi
}

_require_installed() {
    if [[ ! -f "${REALM_BIN}" ]]; then
        echo -e "${RED}错误: 检测到 Realm 未安装，请先选择选项 1 进行安装！${PLAIN}"
        return 1
    fi
    return 0
}

_pause() {
    echo -e "\n${BLUE}[*] 正在刷新后台运行状态...${PLAIN}"
    check_sys
    echo -e "按下任意键立即返回主菜单..."
    read -n 1
}

install_dependencies() {
    echo -e "${BLUE}[*] 正在安装必要依赖...${PLAIN}"
    if [[ "${release}" == "centos" ]]; then
        yum install -y wget curl jq tar wget
    elif [[ "${release}" == "alpine" ]]; then
        apk add --no-cache curl jq tar wget bash openrc
    else
        apt-get update && apt-get install -y wget curl jq tar wget
    fi
}

# --- 2. 安装、更新与卸载 ---
install_realm() {
    check_sys
    if [[ -f "${REALM_BIN}" ]]; then
        echo -e "${YELLOW}[!] Realm 已安装，无需重复安装。${PLAIN}"
        return
    fi
    install_dependencies
    
    mkdir -p "${REALM_DIR}"
    
    echo -e "${BLUE}[*] 正在获取 Realm 最新版本号...${PLAIN}"
    latest_version=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | jq -r .tag_name)
    if [[ -z "${latest_version}" || "${latest_version}" == "null" ]]; then
        latest_version="v2.6.0" 
    fi
    
    if [[ "${release}" == "alpine" ]]; then
        download_url="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-${arch}-unknown-linux-musl.tar.gz"
    else
        download_url="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-${arch}-unknown-linux-gnu.tar.gz"
    fi
    
    echo -e "${BLUE}[*] 正在下载 Realm (${latest_version})...${PLAIN}"
    wget -O /tmp/realm.tar.gz "${download_url}"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[-] 下载 Realm 失败，请检查网络！${PLAIN}"
        exit 1
    fi
    
    tar -zxf /tmp/realm.tar.gz -C /tmp/
    mv /tmp/realm "${REALM_BIN}"
    chmod +x "${REALM_BIN}"
    rm -f /tmp/realm.tar.gz
    
    if [[ ! -f "${REALM_CONF}" ]]; then
        cat > "${REALM_CONF}" <<EOF
[network]
no_delay = true
use_proxy_protocol = false
EOF
    fi
    
    if [[ "${release}" == "alpine" ]]; then
        write_openrc
    else
        write_systemd
    fi
    
    echo -e "${GREEN}[+] Realm 安装成功！${PLAIN}"
}

write_systemd() {
    cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=Realm Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${REALM_CONF}
Restart=always
RestartSec=5
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm
}

write_openrc() {
    cat > "${OPENRC_FILE}" <<EOF
#!/sbin/openrc-run
description="Realm Port Forwarding Service"
command="${REALM_BIN}"
command_args="-c ${REALM_CONF}"
pidfile="/run/realm.pid"
command_background=true
rc_after="networking"

depend() {
    need net
}
EOF
    chmod +x "${OPENRC_FILE}"
    rc-update add realm default
    rc-service realm start
}

update_realm() {
    _require_installed || return
    
    echo -e "${BLUE}[*] 正在拉取云端和本地的版本数据...${PLAIN}"
    
    local local_ver_raw=$(${REALM_BIN} --version 2>&1 | awk '{print $2}')
    local local_ver=$(echo "${local_ver_raw}" | sed 's/[vV]//g')
    
    local current_latest_tag=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | jq -r .tag_name)
    if [[ -z "${current_latest_tag}" || "${current_latest_tag}" == "null" ]]; then
        echo -e "${RED}错误: 无法连接至 GitHub API 获取最新版本，请稍后再试。${PLAIN}"
        return 1
    fi
    local latest_ver=$(echo "${current_latest_tag}" | sed 's/[vV]//g')
    
    echo -e "${BLUE}[*] 本地已安装版本: ${YELLOW}${local_ver}${PLAIN}"
    echo -e "${BLUE}[*] 云端最新发布版: ${YELLOW}${latest_ver}${PLAIN}"
    
    if [ "${local_ver}" = "${latest_ver}" ]; then
        echo -e "${GREEN}[+] 当前安装的 Realm 已是最新版本 (${local_ver})，无需重复更新。${PLAIN}"
        return 0
    fi
    
    echo -e "${YELLOW}[!] 检测到有新版本可用！即将开始平滑无缝升级...${PLAIN}"
    
    check_sys
    if [[ "${release}" == "alpine" ]]; then
        download_url="https://github.com/zhboner/realm/releases/download/${current_latest_tag}/realm-${arch}-unknown-linux-musl.tar.gz"
    else
        download_url="https://github.com/zhboner/realm/releases/download/${current_latest_tag}/realm-${arch}-unknown-linux-gnu.tar.gz"
    fi
    
    wget -O /tmp/realm_update.tar.gz "${download_url}"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[-] 下载新版本组件失败，更新被安全强行中止！${PLAIN}"
        return 1
    fi
    
    tar -zxf /tmp/realm_update.tar.gz -C /tmp/
    
    if [[ "${release}" == "alpine" ]]; then
        rc-service realm stop >/dev/null 2>&1
    else
        systemctl stop realm >/dev/null 2>&1
    fi
    
    mv -f /tmp/realm "${REALM_BIN}"
    chmod +x "${REALM_BIN}"
    rm -f /tmp/realm_update.tar.gz
    
    if [[ "${release}" == "alpine" ]]; then
        rc-service realm start >/dev/null 2>&1
    else
        systemctl start realm >/dev/null 2>&1
    fi
    sleep 1.2
    echo -e "${GREEN}[+] Realm 已成功跃升至最新版本: ${current_latest_tag}!${PLAIN}"
}

uninstall_realm() {
    _require_installed || return
    echo -e "${YELLOW}[!] 确定要卸载 Realm 吗？所有转发配置将被删除！(y/n)${PLAIN}"
    read -r -p "请输入: " confirm
    if [[ "${confirm}" == "y" || "${confirm}" == "Y" ]]; then
        check_sys
        if [[ "${release}" == "alpine" ]]; then
            rc-service realm stop 2>/dev/null
            rc-update del realm default 2>/dev/null
            rm -f "${OPENRC_FILE}"
        else
            systemctl stop realm 2>/dev/null
            systemctl disable realm 2>/dev/null
            rm -f "${SYSTEMD_FILE}"
            systemctl daemon-reload
        fi
        rm -rf "${REALM_DIR}"
        rm -f "${REALM_BIN}"
        echo -e "${GREEN}[+] Realm 卸载成功。${PLAIN}"
    else
        echo -e "${BLUE}[*] 已取消卸载。${PLAIN}"
    fi
}

# --- 3. 服务状态控制 ---
_is_process_running() {
    local rules=$(get_rules_count)
    if [ "$rules" -eq 0 ]; then
        return 1
    fi

    check_sys
    if [[ "${release}" == "alpine" ]]; then
        if rc-service realm status | grep -q "started"; then
            return 0
        else
            return 1
        fi
    else
        if systemctl is-active --quiet realm; then
            return 0
        else
            return 1
        fi
    fi
}

start_realm() {
    _require_installed || return
    
    local total_rules=$(get_rules_count)
    if [ "$total_rules" -eq 0 ]; then
        echo -e "${YELLOW}[!] 当前转发规则为空，Realm 无法维持运行。请先选择选项 5 添加规则。${PLAIN}"
        stop_realm >/dev/null 2>&1
        return
    fi

    if _is_process_running; then
        echo -e "${YELLOW}[!] Realm 已经在运行中，无需重复启动。${PLAIN}"
        return
    fi

    check_sys
    echo -e "${BLUE}[*] 正在尝试启动 Realm 服务...${PLAIN}"
    if [[ "${release}" == "alpine" ]]; then
        rc-service realm start >/dev/null 2>&1
    else
        systemctl start realm >/dev/null 2>&1
    fi
    
    sleep 1.5
    if _is_process_running; then
        echo -e "${GREEN}[+] Realm 成功启动并正常运行！${PLAIN}"
    else
        echo -e "${RED}错误: Realm 启动失败！请检查端口是否被占用或配置是否正确。${PLAIN}"
    fi
}

stop_realm() {
    _require_installed || return
    check_sys
    echo -e "${BLUE}[*] 正在停止 Realm 服务...${PLAIN}"
    if [[ "${release}" == "alpine" ]]; then
        rc-service realm stop >/dev/null 2>&1
    else
        systemctl stop realm >/dev/null 2>&1
    fi
    sleep 0.5
    echo -e "${GREEN}[+] Realm 服务执行了停止指令。${PLAIN}"
}

restart_realm() {
    _require_installed || return
    
    local total_rules=$(get_rules_count)
    if [ "$total_rules" -eq 0 ]; then
        echo -e "${YELLOW}[!] 当前没有配置任何规则，已自动拦截重启并将服务安全关闭。${PLAIN}"
        stop_realm >/dev/null 2>&1
        return
    fi

    check_sys
    echo -e "${BLUE}[*] 正在尝试重启 Realm 服务...${PLAIN}"
    if [[ "${release}" == "alpine" ]]; then
        rc-service realm restart >/dev/null 2>&1
    else
        systemctl restart realm >/dev/null 2>&1
    fi
    
    sleep 1.5
    if _is_process_running; then
        echo -e "${GREEN}[+] Realm 重启成功并已恢复运行！${PLAIN}"
    else
        echo -e "${RED}错误: Realm 重启后发生闪退，未能正常跑起来！${PLAIN}"
    fi
}

get_status() {
    if [[ ! -f "${REALM_BIN}" ]]; then
        echo -e "${RED}未安装${PLAIN}"
        return
    fi
    
    if _is_process_running; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        local total_rules=$(get_rules_count)
        if [ "$total_rules" -eq 0 ]; then
            echo -e "${YELLOW}未运行 (配置文件无转发规则，请先添加规则)${PLAIN}"
        else
            echo -e "${RED}未运行 (有配置规则但进程终止，可能端口冲突/闪退)${PLAIN}"
        fi
    fi
}

# --- 4. 输入合法性绝对严谨校验模块 ---
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

validate_host() {
    local host=$1
    local clean_host=$(echo "$host" | sed 's/^\[//;s/\]$//')

    if [[ "$clean_host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        IFS='.' read -r -a octets <<< "$clean_host"
        if [ "${octets[0]}" -le 255 ] && [ "${octets[1]}" -le 255 ] && \
           [ "${octets[2]}" -le 255 ] && [ "${octets[3]}" -le 255 ]; then
            REMOTE_TYPE="ipv4"
            return 0
        fi
    fi

    if [[ "$clean_host" =~ : ]] && [[ "$clean_host" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        REMOTE_TYPE="ipv6"
        return 0
    fi

    if [[ "$clean_host" =~ ^([a-zA-Z0-9](([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+)+[a-zA-Z]{2,}$ ]]; then
        REMOTE_TYPE="domain"
        return 0
    fi

    return 1
}

format_ip() {
    local ip=$1
    if [[ "$ip" =~ ":" ]] && [[ ! "$ip" =~ ^\[.*\]$ ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

get_rules_count() {
    if [[ ! -f "${REALM_CONF}" ]]; then echo 0; return; fi
    grep -c '\[\[endpoints\]\]' "${REALM_CONF}"
}

list_rules() {
    _require_installed || return
    if [[ ! -f "${REALM_CONF}" ]]; then
        echo -e "${RED}[!] 配置文件不存在。${PLAIN}"
        return
    fi
    
    echo -e "\n${BLUE}========== 当前 Realm 转发规则列表 ==========${PLAIN}"
    awk '
    BEGIN { count=0; listen=""; remote="" }
    /\[\[endpoints\]\]/ { 
        if (listen != "" && remote != "") {
            count++;
            printf "%d. 监听: \033[0;32m%s\033[0m  ==>  目标: \033[0;36m%s\033[0m\n", count, listen, remote;
        }
        listen=""; remote=""; next; 
    }
    /listen[ \t]*=/ { split($0, a, "\""); listen=a[2] }
    /remote[ \t]*=/ { split($0, a, "\""); remote=a[2] }
    END { 
        if (listen != "" && remote != "") {
            count++;
            printf "%d. 监听: \033[0;32m%s\033[0m  ==>  目标: \033[0;36m%s\033[0m\n", count, listen, remote;
        }
        if (count == 0) print "暂无转发规则。";
    }
    ' "${REALM_CONF}"
    echo -e "${BLUE}==============================================${PLAIN}\n"
}

add_rule() {
    _require_installed || return

    echo -e "${BLUE}[添加规则]${PLAIN}"
    read -r -p "请输入本地监听端口: " local_port
    if ! validate_port "$local_port"; then
        echo -e "${RED}错误: 本地监听端口 [${local_port}] 不规范！必须是 1-65535 之间的数字。${PLAIN}"
        return
    fi

    read -r -p "请输入远程目标主机(IP/域名): " remote_host
    REMOTE_TYPE=""
    if ! validate_host "$remote_host"; then
        echo -e "${RED}错误: 远程目标主机 [${remote_host}] 格式完全错误！请输入合法的 IPv4、IPv6 或带后缀的域名。${PLAIN}"
        return
    fi

    read -r -p "请输入远程目标端口: " remote_port
    if ! validate_port "$remote_port"; then
        echo -e "${RED}错误: 远程目标端口 [${remote_port}] 不规范！必须是 1-65535 之间的数字。${PLAIN}"
        return
    fi
    
    local listen_ip="[::]"
    
    if [ "$SUPPORT_IPV6" = false ]; then
        if [ "$REMOTE_TYPE" = "ipv6" ]; then
            echo -e "${RED}错误: 当前系统内核已禁用 IPv6 协议栈，禁止转发至 IPv6 目标地址！${PLAIN}"
            return
        fi
        listen_ip="0.0.0.0"
    fi
    
    remote_host=$(format_ip "${remote_host}")
    
    cat >> "${REALM_CONF}" <<EOF

[[endpoints]]
listen = "${listen_ip}:${local_port}"
remote = "${remote_host}:${remote_port}"
EOF

    echo -e "${GREEN}[+] 规则已成功写入配置文件。${PLAIN}"
    restart_realm
}

delete_rule() {
    _require_installed || return
    local total_rules=$(get_rules_count)
    if [ "$total_rules" -eq 0 ]; then
        echo -e "${YELLOW}[!] 当前没有任何转发规则。${PLAIN}"
        return 1
    fi

    list_rules
    read -r -p "请输入要删除的规则序号 (输入 0 可直接取消并返回): " num
    
    if [[ "${num}" == "0" ]]; then
        echo -e "${BLUE}[*] 操作已取消，正在安全退出当前菜单...${PLAIN}"
        return 1
    fi
    
    if [[ -z "${num}" ]] || ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$total_rules" ]; then
        echo -e "${RED}错误: 输入的规则序号 [${num}] 不存在或不合法！${PLAIN}"
        return 1
    fi
    
    local temp_file="/tmp/realm_tmp.toml"
    
    sed -n '1,/\[\[endpoints\]\]/p' "${REALM_CONF}" | grep -v '\[\[endpoints\]\]' > "${temp_file}"
    
    awk -v target_idx="${num}" '
    BEGIN { RS="[[endpoints]]"; ORS=""; idx=0 }
    NR==1 { next }
    {
        idx++
        if (idx != target_idx) {
            print "[[endpoints]]" $0
        }
    }
    ' "${REALM_CONF}" >> "${temp_file}"
    
    mv "${temp_file}" "${REALM_CONF}"
    echo -e "${GREEN}[+] 规则 #${num} 已被剔除。${PLAIN}"
    restart_realm
    return 0
}

modify_rule() {
    _require_installed || return
    local total_rules=$(get_rules_count)
    if [ "$total_rules" -eq 0 ]; then
        echo -e "${YELLOW}[!] 当前没有任何转发规则可供修改。${PLAIN}"
        return
    fi
    echo -e "${YELLOW}[修改提示] 规则定位成功后，系统会帮您删掉旧配置，并无缝进入新字段填写。${PLAIN}"
    
    delete_rule
    if [ $? -ne 0 ]; then
        return
    fi
    
    local current_rules=$(get_rules_count)
    if [ "$current_rules" -lt "$total_rules" ]; then
        echo -e "${BLUE}---------------------------------------------${PLAIN}"
        add_rule
    fi
}

# --- 5. 交互式菜单主循环 ---
menu() {
    clear
    check_sys
    echo -e "=================================================="
    echo -e "           Realm 端口转发一键管理脚本             "
    echo -e "=================================================="
    echo -e " 当前状态 : $(get_status)"
    echo -e " 规则总数 : ${GREEN}$(get_rules_count) 条${PLAIN}"
    if [ "$SUPPORT_IPV6" = true ]; then
        echo -e " 内核网络 : ${GREEN}支持 IPv6 协议栈 (优先绑定 [::])${PLAIN}"
    else
        echo -e " 内核网络 : ${YELLOW}未启用 IPv6 协议栈 (强绑定 0.0.0.0)${PLAIN}"
    fi
    echo -e " 程序目录 : ${CYAN}${REALM_BIN}${PLAIN}"
    echo -e " 配置文件 : ${CYAN}${REALM_CONF}${PLAIN}"

    echo -e "--------------------------------------------------"
    echo -e "  ${BLUE}1.${PLAIN} 安装 Realm"
    echo -e "  ${BLUE}2.${PLAIN} 更新 Realm"
    echo -e "  ${BLUE}3.${PLAIN} 卸载 Realm"
    echo -e "--------------------------------------------------"
    echo -e "  ${BLUE}4.${PLAIN} 查看规则"
    echo -e "  ${BLUE}5.${PLAIN} 添加规则"
    echo -e "  ${BLUE}6.${PLAIN} 修改规则"
    echo -e "  ${BLUE}7.${PLAIN} 删除规则"
    echo -e "--------------------------------------------------"
    echo -e "  ${BLUE}8.${PLAIN} 启动服务"
    echo -e "  ${BLUE}9.${PLAIN} 停止服务"
    echo -e " ${BLUE}10.${PLAIN} 重启服务"
    echo -e "--------------------------------------------------"
    echo -e "  ${YELLOW}0.${PLAIN} 退出脚本"
    echo -e "=================================================="
    read -r -p "请输入对应的数字选项 [0-10]: " menu_num
    
    case "${menu_num}" in
        1) install_realm ; _pause ;;
        2) update_realm ; _pause ;;
        3) uninstall_realm ; _pause ;;
        4) list_rules ; _pause ;;
        5) add_rule ; _pause ;;
        6) modify_rule ; _pause ;;
        7) delete_rule ; _pause ;;
        8) start_realm ; _pause ;;
        9) stop_realm ; _pause ;;
        10) restart_realm ; _pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}" ; sleep 1 ;;
    esac
}

check_sys

while true; do
    menu
done