#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

app_name="X-MILI"
repo_raw_base="${X_MILI_RAW_BASE:=https://raw.githubusercontent.com/2728816908/X-MILI/main}"
lang_file="${X_MILI_LANG_FILE:=/etc/x-mili/lang}"

load_language() {
    if [[ -z "$X_MILI_LANG" && -f "$lang_file" ]]; then
        X_MILI_LANG=$(cat "$lang_file")
    fi
}

is_zh() {
    [[ "$X_MILI_LANG" == "zh_CN" ]]
}

choose_language() {
    load_language
    [[ -n "$X_MILI_LANG" ]] && return
    echo -e "${green}1.${plain} English"
    echo -e "${green}2.${plain} 简体中文"
    read -rp "Please choose language / 请选择语言 [1-2]: " lang_choice
    if [[ "$lang_choice" == "2" ]]; then
        X_MILI_LANG="zh_CN"
    else
        X_MILI_LANG="en_US"
    fi
    mkdir -p "$(dirname "$lang_file")"
    echo "$X_MILI_LANG" > "$lang_file"
}

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# Port helpers: detect listener and owning process (best effort)
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# Simple helpers for domain/IP validation
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

load_language

# check root
if [[ $EUID -ne 0 ]]; then
    is_zh && LOGE "错误：请使用 root 运行此脚本！\n" || LOGE "ERROR: You must be root to run this script! \n"
    exit 1
fi

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    if is_zh; then
        echo "检测系统发行版失败，请联系维护者！" >&2
    else
        echo "Failed to check the system OS, please contact the author!" >&2
    fi
    exit 1
fi
is_zh && echo "系统发行版: $release" || echo "The OS release is: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

# Declare Variables
xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    local default_label="Default"
    is_zh && default_label="默认"
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [${default_label} $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    if is_zh; then
        confirm "是否重启面板？注意：重启面板也会重启 Xray" "y"
    else
        confirm "Restart the panel, Attention: Restarting the panel will also restart xray" "y"
    fi
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    if is_zh; then
        echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read -r temp
    else
        echo && echo -n -e "${yellow}Press enter to return to the main menu: ${plain}" && read -r temp
    fi
    show_menu
}

install() {
    bash <(curl -Ls "${repo_raw_base}/install.sh")
}

update() {
    bash <(curl -Ls "${repo_raw_base}/update.sh")
}

update_menu() {
    curl -fLRo /usr/bin/ml "${repo_raw_base}/x-ui.sh"
    chmod +x /usr/bin/ml 2> /dev/null || true
    if [[ $? == 0 ]]; then
        is_zh && LOGI "$app_name 菜单更新完成。请重新运行 ml。" || LOGI "$app_name menu updated. Please rerun ml."
    else
        is_zh && LOGE "更新 $app_name 菜单失败。" || LOGE "Failed to update $app_name menu."
        return 1
    fi
}

# Function to handle the deletion of the script file
delete_script() {
    rm -f /usr/bin/ml /usr/bin/x-ui
    exit 0
}

uninstall() {
    if is_zh; then
        confirm "确定要彻底卸载面板吗？面板数据、Xray、VPNGate/OpenVPN、证书和日志都会清理。" "n"
    else
        confirm "Fully uninstall the panel? Panel data, Xray, VPNGate/OpenVPN, certificates and logs will be removed." "n"
    fi
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop 2> /dev/null || true
        rc-update del x-ui 2> /dev/null || true
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui 2> /dev/null || true
        systemctl disable x-ui 2> /dev/null || true
        rm ${xui_service}/x-ui.service -f
        rm /etc/systemd/system/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    # Kill running panel, OpenVPN and Xray instances
    pkill -9 x-ui 2>/dev/null || true
    pkill -9 openvpn 2>/dev/null || true
    pkill -9 openvpn3 2>/dev/null || true
    pkill -9 xray 2>/dev/null || true
    pkill -9 xray-linux 2>/dev/null || true

    # Uninstall OpenVPN package installed for VPNGate
    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y openvpn openvpn3 >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk del openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Rns --noconfirm openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper -q remove -y openvpn openvpn3 >/dev/null 2>&1 || true
    fi

    rm /etc/x-ui/ -rf
    rm /etc/x-mili/ -rf
    rm /var/log/x-ui/ -rf
    rm /root/cert/ -rf
    rm /root/.acme.sh/ -rf
    rm ${xui_folder}/ -rf
    rm -rf /usr/local/etc/x-ui /var/lib/x-ui /tmp/x-mili-* /tmp/vpngate-check-*.ovpn

    if [ -d "/etc/fail2ban" ]; then
        rm -f /etc/fail2ban/filter.d/3x-ipl.conf
        rm -f /etc/fail2ban/action.d/3x-ipl.conf
        rm -f /etc/fail2ban/jail.d/3x-ipl.conf
        systemctl restart fail2ban >/dev/null 2>&1 || true
    fi

    rm -f /usr/bin/ml /usr/bin/x-ui

    echo ""
    if is_zh; then
        echo -e "卸载完成。\n"
        echo "重新安装: bash <(curl -Ls ${repo_raw_base}/install.sh)"
    else
        echo -e "Uninstalled Successfully.\n"
        echo "Reinstall with: bash <(curl -Ls ${repo_raw_base}/install.sh)"
    fi
    echo ""
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    if is_zh; then
        confirm "确定要重置面板用户名和密码吗？" "n"
    else
        confirm "Are you sure to reset the username and password of the panel?" "n"
    fi
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if is_zh; then
        read -rp "请输入登录用户名 [留空则随机生成]: " config_account
    else
        read -rp "Please set the login username [default is a random username]: " config_account
    fi
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    if is_zh; then
        read -rp "请输入登录密码 [留空则随机生成]: " config_password
    else
        read -rp "Please set the login password [default is a random password]: " config_password
    fi
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    if is_zh; then
        read -rp "是否关闭当前已配置的两步验证？(y/n): " twoFactorConfirm
    else
        read -rp "Do you want to disable currently configured two-factor authentication? (y/n): " twoFactorConfirm
    fi
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor false > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor true > /dev/null 2>&1
        is_zh && echo -e "两步验证已关闭。" || echo -e "Two factor authentication has been disabled."
    fi

    if is_zh; then
        echo -e "面板登录用户名已重置为: ${green}${config_account}${plain}"
        echo -e "面板登录密码已重置为: ${green}${config_password}${plain}"
        echo -e "${green}请使用新的用户名和密码访问 ${app_name} 面板，并妥善保存。${plain}"
    else
        echo -e "Panel login username has been reset to: ${green} ${config_account} ${plain}"
        echo -e "Panel login password has been reset to: ${green} ${config_password} ${plain}"
        echo -e "${green} Please use the new login username and password to access the $app_name panel. Also remember them! ${plain}"
    fi
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    is_zh && echo -e "${yellow}正在重置面板访问路径${plain}" || echo -e "${yellow}Resetting Web Base Path${plain}"

    if is_zh; then
        read -rp "确定要重置面板访问路径吗？(y/n): " confirm
    else
        read -rp "Are you sure you want to reset the web base path? (y/n): " confirm
    fi
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        is_zh && echo -e "${yellow}操作已取消。${plain}" || echo -e "${yellow}Operation canceled.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    if is_zh; then
        echo -e "面板访问路径已重置为: ${green}/${config_webBasePath}/${plain}"
        echo -e "${green}请使用新的访问路径进入面板。${plain}"
    else
        echo -e "Web base path has been reset to: ${green}${config_webBasePath}${plain}"
        echo -e "${green}Please use the new web base path to access the panel.${plain}"
    fi
    restart
}

reset_config() {
    if is_zh; then
        confirm "确定要重置所有面板设置吗？账号数据不会丢失，用户名和密码不会改变" "n"
    else
        confirm "Are you sure you want to reset all panel settings, Account data will not be lost, Username and password will not change" "n"
    fi
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    is_zh && echo -e "所有面板设置已重置为默认值。" || echo -e "All panel settings have been reset to default."
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        is_zh && LOGE "获取当前设置失败，请检查日志" || LOGE "get current settings error, please check logs"
        show_menu
        return
    fi

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local has_default_credential=$(echo "$info" | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 3 https://4.ident.me)
    fi
    [[ -n "$server_ip" ]] || server_ip="服务器IP"

    if is_zh; then
        echo -e "${green}当前面板设置:${plain}"
        echo -e "端口: ${green}${existing_port}${plain}"
        echo -e "访问路径: ${green}${existing_webBasePath}${plain}"
        if [[ "$has_default_credential" == "true" ]]; then
            echo -e "默认账号: ${red}是，请使用菜单 6 立即重置用户名和密码${plain}"
        else
            echo -e "默认账号: ${green}否${plain}"
        fi
    else
        LOGI "${info}"
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            is_zh && echo -e "${green}访问地址: https://${domain}:${existing_port}${existing_webBasePath}${plain}" || echo -e "${green}Access URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            is_zh && echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}" || echo -e "${green}Access URL: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        if is_zh; then
            echo -e "${yellow}访问地址: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}当前未配置 SSL。如需 HTTPS，请在菜单 19 中配置 SSL 证书。${plain}"
        else
            echo -e "${yellow}Access URL: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}No SSL certificate configured. Configure SSL via option 19 when needed.${plain}"
        fi
    fi
}

set_port() {
    if is_zh; then
        echo -n "请输入端口号 [1-65535]: "
    else
        echo -n "Enter port number[1-65535]: "
    fi
    read -r port
    if [[ -z "${port}" ]]; then
        is_zh && LOGD "已取消" || LOGD "Cancelled"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        if is_zh; then
            echo -e "端口已设置，请重启面板后使用新端口 ${green}${port}${plain} 访问 Web 面板"
        else
            echo -e "The port is set, Please restart the panel now, and use the new port ${green}${port}${plain} to access web panel"
        fi
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "Panel is running, No need to start again, If you need to restart, please select restart"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui Started Successfully"
        else
            LOGE "panel Failed to start, Probably because it takes longer than two seconds to start, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "Panel stopped, No need to stop again!"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui and xray stopped successfully"
        else
            LOGE "Panel stop failed, Probably because the stop time exceeds two seconds, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui and xray Restarted successfully"
    else
        LOGE "Panel restart failed, Probably because it takes longer than two seconds to start, Please check the log information later"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    systemctl reload x-ui
    LOGI "xray-core Restart signal sent successfully, Please check the log information to confirm whether xray restarted successfully"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Set to boot automatically on startup successfully"
    else
        LOGE "x-ui Failed to set Autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Autostart Cancelled successfully"
    else
        LOGE "x-ui Failed to cancel autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "Choose an option: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t2.${plain} Clear All logs"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "Choose an option: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "All Logs cleared."
                restart
                ;;
            *)
                echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
                show_log
                ;;
        esac
    fi
}

bbr_menu() {
    if is_zh; then
        echo -e "${green}\t1.${plain} 启用 BBR"
        echo -e "${green}\t2.${plain} 禁用 BBR"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
    echo -e "${green}\t1.${plain} Enable BBR"
    echo -e "${green}\t2.${plain} Disable BBR"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    fi
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        is_zh && echo -e "${yellow}当前未启用 BBR。${plain}" || echo -e "${yellow}BBR is not currently enabled.${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
        sysctl --system
    else
        # Replace BBR with CUBIC configurations
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        is_zh && echo -e "${green}BBR 已成功替换为 CUBIC。${plain}" || echo -e "${green}BBR has been replaced with CUBIC successfully.${plain}"
    else
        is_zh && echo -e "${red}无法将 BBR 替换为 CUBIC。请检查系统配置。${plain}" || echo -e "${red}Failed to replace BBR with CUBIC. Please check your system configuration.${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        is_zh && echo -e "${green}BBR 已经启用！${plain}" || echo -e "${green}BBR is already enabled!${plain}"
        before_show_menu
    fi

    # Enable BBR
    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        if [ -f "/etc/sysctl.conf" ]; then
            # Backup old settings from sysctl.conf, if any
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        sysctl --system
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
        sysctl -p
    fi

    # Verify that BBR is enabled
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        is_zh && echo -e "${green}BBR 已成功启用。${plain}" || echo -e "${green}BBR has been enabled successfully.${plain}"
    else
        is_zh && echo -e "${red}启用 BBR 失败。请检查系统配置。${plain}" || echo -e "${red}Failed to enable BBR. Please check your system configuration.${plain}"
    fi
}

update_shell() {
    curl -fLRo /usr/bin/ml "${repo_raw_base}/x-ui.sh"
    chmod +x /usr/bin/ml 2> /dev/null || true
    is_zh && LOGI "$app_name 脚本更新完成。请重新运行 ml。" || LOGI "$app_name shell updated. Please rerun ml."
    before_show_menu
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        is_zh && LOGE "面板已安装，请不要重复安装" || LOGE "Panel installed, Please do not reinstall"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        is_zh && LOGE "请先安装面板" || LOGE "Please install the panel first"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            if is_zh; then
                echo -e "面板状态: ${green}运行中${plain}"
            else
                echo -e "Panel state: ${green}Running${plain}"
            fi
            show_enable_status
            ;;
        1)
            if is_zh; then
                echo -e "面板状态: ${yellow}未运行${plain}"
            else
                echo -e "Panel state: ${yellow}Not Running${plain}"
            fi
            show_enable_status
            ;;
        2)
            if is_zh; then
                echo -e "面板状态: ${red}未安装${plain}"
            else
                echo -e "Panel state: ${red}Not Installed${plain}"
            fi
            ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        if is_zh; then
            echo -e "开机自启: ${green}已开启${plain}"
        else
            echo -e "Start automatically: ${green}Yes${plain}"
        fi
    else
        if is_zh; then
            echo -e "开机自启: ${red}未开启${plain}"
        else
            echo -e "Start automatically: ${red}No${plain}"
        fi
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        if is_zh; then
            echo -e "Xray 状态: ${green}运行中${plain}"
        else
            echo -e "xray state: ${green}Running${plain}"
        fi
    else
        if is_zh; then
            echo -e "Xray 状态: ${red}未运行${plain}"
        else
            echo -e "xray state: ${red}Not Running${plain}"
        fi
    fi
}

firewall_menu() {
    if is_zh; then
        echo -e "${green}\t1.${plain} ${green}安装${plain}防火墙"
        echo -e "${green}\t2.${plain} 查看端口列表"
        echo -e "${green}\t3.${plain} ${green}开放${plain}端口"
        echo -e "${green}\t4.${plain} ${red}删除${plain}端口规则"
        echo -e "${green}\t5.${plain} ${green}启用${plain}防火墙"
        echo -e "${green}\t6.${plain} ${red}停用${plain}防火墙"
        echo -e "${green}\t7.${plain} 防火墙状态"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
    echo -e "${green}\t1.${plain} ${green}Install${plain} Firewall"
    echo -e "${green}\t2.${plain} Port List [numbered]"
    echo -e "${green}\t3.${plain} ${green}Open${plain} Ports"
    echo -e "${green}\t4.${plain} ${red}Delete${plain} Ports from List"
    echo -e "${green}\t5.${plain} ${green}Enable${plain} Firewall"
    echo -e "${green}\t6.${plain} ${red}Disable${plain} Firewall"
    echo -e "${green}\t7.${plain} Firewall Status"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    fi
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            ufw status numbered
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            ufw enable
            firewall_menu
            ;;
        6)
            ufw disable
            firewall_menu
            ;;
        7)
            ufw status verbose
            firewall_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo "ufw firewall is not installed. Installing now..."
        apt-get update
        apt-get install -y ufw
    else
        echo "ufw firewall is already installed"
    fi

    # Check if the firewall is inactive
    if ufw status | grep -q "Status: active"; then
        echo "Firewall is already active"
    else
        echo "Activating firewall..."
        # Open the necessary ports
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #webPort
        ufw allow 2096/tcp #subport

        # Enable the firewall
        ufw --force enable
    fi
}

open_ports() {
    # Prompt the user to enter the ports they want to open
    read -rp "Enter the ports you want to open (e.g. 80,443,2053 or range 400-500): " ports

    # Check if the input is valid
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "Error: Invalid input. Please enter a comma-separated list of ports or a range of ports (e.g. 80,443,2053 or 400-500)." >&2
        exit 1
    fi

    # Open the specified ports using ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Split the range into start and end ports
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Open the port range
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Open the single port
            ufw allow "$port"
        fi
    done

    # Confirm that the ports are opened
    echo "Opened the specified ports:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Check if the port range has been successfully opened
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Check if the individual port has been successfully opened
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Display current rules with numbers
    echo "Current UFW rules:"
    ufw status numbered

    # Ask the user how they want to delete rules
    echo "Do you want to delete rules by:"
    echo "1) Rule numbers"
    echo "2) Ports"
    read -rp "Enter your choice (1 or 2): " choice

    if [[ $choice -eq 1 ]]; then
        # Deleting by rule numbers
        read -rp "Enter the rule numbers you want to delete (1, 2, etc.): " rule_numbers

        # Validate the input
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "Error: Invalid input. Please enter a comma-separated list of rule numbers." >&2
            exit 1
        fi

        # Split numbers into an array
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Delete the rule by number
            ufw delete "$rule_number" || echo "Failed to delete rule number $rule_number"
        done

        echo "Selected rules have been deleted."

    elif [[ $choice -eq 2 ]]; then
        # Deleting by ports
        read -rp "Enter the ports you want to delete (e.g. 80,443,2053 or range 400-500): " ports

        # Validate the input
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "Error: Invalid input. Please enter a comma-separated list of ports or a range of ports (e.g. 80,443,2053 or 400-500)." >&2
            exit 1
        fi

        # Split ports into an array
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Split the port range
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Delete the port range
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Delete a single port
                ufw delete allow "$port"
            fi
        done

        # Confirmation of deletion
        echo "Deleted the specified ports:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Check if the port range has been deleted
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Check if the individual port has been deleted
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}Error:${plain} Invalid choice. Please enter 1 or 2." >&2
        exit 1
    fi
}

update_all_geofiles() {
    update_geofiles "main"
    update_geofiles "IR"
    update_geofiles "RU"
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
    esac
    for dat in "${dat_files[@]}"; do
        # Remove suffix for remote filename (e.g., geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        curl -fLRo ${xui_folder}/bin/${dat}.dat -z ${xui_folder}/bin/${dat}.dat \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat
    done
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} All"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            update_geofiles "main"
            echo -e "${green}Loyalsoldier datasets have been updated successfully!${plain}"
            restart
            ;;
        2)
            update_geofiles "IR"
            echo -e "${green}chocolate4u datasets have been updated successfully!${plain}"
            restart
            ;;
        3)
            update_geofiles "RU"
            echo -e "${green}runetfreedom datasets have been updated successfully!${plain}"
            restart
            ;;
        4)
            update_all_geofiles
            echo -e "${green}All geo files have been updated successfully!${plain}"
            restart
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}

install_acme() {
    # Check if acme.sh is already installed
    if command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh is already installed."
        return 0
    fi

    LOGI "Installing acme.sh..."
    cd ~ || return 1 # Ensure you can change to the home directory

    curl -s https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "Installation of acme.sh failed."
        return 1
    else
        LOGI "Installation of acme.sh succeeded."
    fi

    return 0
}

ssl_cert_issue_main() {
    if is_zh; then
        echo -e "${green}\t1.${plain} 获取 SSL 证书 (域名)"
        echo -e "${green}\t2.${plain} 吊销证书"
        echo -e "${green}\t3.${plain} 强制更新"
        echo -e "${green}\t4.${plain} 显示已有的域名证书"
        echo -e "${green}\t5.${plain} 为面板设置证书路径"
        echo -e "${green}\t6.${plain} 获取 IP 地址的 SSL 证书 (短期证书，自动续签)"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
        echo -e "${green}\t1.${plain} Get SSL (Domain)"
        echo -e "${green}\t2.${plain} Revoke"
        echo -e "${green}\t3.${plain} Force Renew"
        echo -e "${green}\t4.${plain} Show Existing Domains"
        echo -e "${green}\t5.${plain} Set Cert paths for the panel"
        echo -e "${green}\t6.${plain} Get SSL for IP Address (6-day cert, auto-renews)"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "Choose an option: " choice
    fi

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            ssl_cert_issue
            ssl_cert_issue_main
            ;;
        2)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                is_zh && echo "未找到可吊销的的证书。" || echo "No certificates found to revoke."
            else
                is_zh && echo "已存在域名:" || echo "Existing domains:"
                echo "$domains"
                is_zh && read -rp "请输入列表中要吊销证书的域名: " domain || read -rp "Please enter a domain from the list to revoke the certificate: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --revoke -d ${domain}
                    is_zh && LOGI "域名 $domain 的证书已吊销。" || LOGI "Certificate revoked for domain: $domain"
                else
                    is_zh && echo "输入的域名无效。" || echo "Invalid domain entered."
                fi
            fi
            ssl_cert_issue_main
            ;;
        3)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                is_zh && echo "未找到可更新的证书。" || echo "No certificates found to renew."
            else
                is_zh && echo "已存在域名:" || echo "Existing domains:"
                echo "$domains"
                is_zh && read -rp "请输入列表中要更新 SSL 证书的域名: " domain || read -rp "Please enter a domain from the list to renew the SSL certificate: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --renew -d ${domain} --force
                    is_zh && LOGI "域名 $domain 的证书已强制更新。" || LOGI "Certificate forcefully renewed for domain: $domain"
                else
                    is_zh && echo "输入的域名无效。" || echo "Invalid domain entered."
                fi
            fi
            ssl_cert_issue_main
            ;;
        4)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                is_zh && echo "未找到任何证书。" || echo "No certificates found."
            else
                is_zh && echo "已存在域名及其路径:" || echo "Existing domains and their paths:"
                for domain in $domains; do
                    local cert_path="/root/cert/${domain}/fullchain.pem"
                    local key_path="/root/cert/${domain}/privkey.pem"
                    if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                        echo -e "Domain: ${domain}"
                        is_zh && echo -e "\t证书路径: ${cert_path}" || echo -e "\tCertificate Path: ${cert_path}"
                        is_zh && echo -e "\t私钥路径: ${key_path}" || echo -e "\tPrivate Key Path: ${key_path}"
                    else
                        is_zh && echo -e "域名: ${domain} - 证书或私钥丢失。" || echo -e "Domain: ${domain} - Certificate or Key missing."
                    fi
                done
            fi
            ssl_cert_issue_main
            ;;
        5)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                is_zh && echo "未找到任何证书。" || echo "No certificates found."
            else
                is_zh && echo "可用域名:" || echo "Available domains:"
                echo "$domains"
                is_zh && read -rp "请选择一个域名来设置面板证书路径: " domain || read -rp "Please choose a domain to set the panel paths: " domain

                if echo "$domains" | grep -qw "$domain"; then
                    local webCertFile="/root/cert/${domain}/fullchain.pem"
                    local webKeyFile="/root/cert/${domain}/privkey.pem"

                    if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                        if is_zh; then
                            echo "已成功设置域名 $domain 的面板证书路径:"
                            echo "  - 证书文件: $webCertFile"
                            echo "  - 私钥文件: $webKeyFile"
                        else
                            echo "Panel paths set for domain: $domain"
                            echo "  - Certificate File: $webCertFile"
                            echo "  - Private Key File: $webKeyFile"
                        fi
                        restart
                    else
                        is_zh && echo "未找到域名 $domain 的证书或私钥。" || echo "Certificate or private key not found for domain: $domain."
                    fi
                else
                    is_zh && echo "输入的域名无效。" || echo "Invalid domain entered."
                fi
            fi
            ssl_cert_issue_main
            ;;
        6)
            if is_zh; then
                echo -e "${yellow}申请 IP 地址的 Let's Encrypt SSL 证书${plain}"
                echo -e "这将使用短效凭证配置来获取服务器公网 IP 的 SSL 证书。"
                echo -e "${yellow}证书有效期约为 6 天，通过 acme.sh 定时任务自动续签。${plain}"
                echo -e "${yellow}注意：TCP 80 端口必须处于开启且可以公开访问的状态。${plain}"
                confirm "是否继续？" "y"
            else
                echo -e "${yellow}Let's Encrypt SSL Certificate for IP Address${plain}"
                echo -e "This will obtain a certificate for your server's IP using the shortlived profile."
                echo -e "${yellow}Certificate valid for ~6 days, auto-renews via acme.sh cron job.${plain}"
                echo -e "${yellow}Port 80 must be open and accessible from the internet.${plain}"
                confirm "Do you want to proceed?" "y"
            fi
            if [[ $? == 0 ]]; then
                ssl_cert_issue_for_ip
            fi
            ssl_cert_issue_main
            ;;

        *)
            is_zh && echo -e "${red}无效选项。请选择正确的数字。${plain}\n" || echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            ssl_cert_issue_main
            ;;
    esac
}

ssl_cert_issue_for_ip() {
    LOGI "Starting automatic SSL certificate generation for server IP..."
    LOGI "Using Let's Encrypt shortlived profile (~6 days validity, auto-renews)"

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')

    # Get server IP
    local server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 3 https://4.ident.me)
    fi

    if [ -z "$server_ip" ]; then
        LOGE "Failed to get server IP address"
        return 1
    fi

    LOGI "Server IP detected: ${server_ip}"

    # Ask for optional IPv6
    local ipv6_addr=""
    read -rp "Do you have an IPv6 address to include? (leave empty to skip): " ipv6_addr
    ipv6_addr="${ipv6_addr// /}" # Trim whitespace

    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh not found, installing..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "Failed to install acme.sh"
            return 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Unsupported OS for automatic socat installation"
            ;;
    esac

    # Create certificate directory
    certPath="/root/cert/ip"
    mkdir -p "$certPath"

    # Build domain arguments
    local domain_args="-d ${server_ip}"
    if [[ -n "$ipv6_addr" ]] && is_ipv6 "$ipv6_addr"; then
        domain_args="${domain_args} -d ${ipv6_addr}"
        LOGI "Including IPv6 address: ${ipv6_addr}"
    fi

    # Choose port for HTTP-01 listener (default 80, allow override)
    local WebPort=""
    read -rp "Port to use for ACME HTTP-01 listener (default 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        LOGE "Invalid port provided. Falling back to 80."
        WebPort=80
    fi
    LOGI "Using port ${WebPort} to issue certificate for IP: ${server_ip}"
    if [[ "${WebPort}" -ne 80 ]]; then
        LOGI "Reminder: Let's Encrypt still reaches port 80; forward external port 80 to ${WebPort} for validation."
    fi

    while true; do
        if is_port_in_use "${WebPort}"; then
            LOGI "Port ${WebPort} is currently in use."

            local alt_port=""
            read -rp "Enter another port for acme.sh standalone listener (leave empty to abort): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                LOGE "Port ${WebPort} is busy; cannot proceed with issuance."
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                LOGE "Invalid port provided."
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            LOGI "Port ${WebPort} is free and ready for standalone validation."
            break
        fi
    done

    # Reload command - restarts panel after renewal
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null"

    # issue the certificate for IP with shortlived profile
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        LOGE "Failed to issue certificate for IP: ${server_ip}"
        LOGE "Make sure port ${WebPort} is open and the server is accessible from the internet"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    else
        LOGI "Certificate issued successfully for IP: ${server_ip}"
    fi

    # Install the certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert -d ${server_ip} \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certPath}/fullchain.pem" || ! -f "${certPath}/privkey.pem" ]]; then
        LOGE "Certificate files not found after installation"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    fi

    LOGI "Certificate files installed successfully"

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Set certificate paths for the panel
    local webCertFile="${certPath}/fullchain.pem"
    local webKeyFile="${certPath}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
        LOGI "Certificate configured for panel"
        LOGI "  - Certificate File: $webCertFile"
        LOGI "  - Private Key File: $webKeyFile"
        LOGI "  - Validity: ~6 days (auto-renews via acme.sh cron)"
        echo -e "${green}Access URL: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        LOGI "Panel will restart to apply SSL certificate..."
        restart
        return 0
    else
        LOGE "Certificate files not found after installation"
        return 1
    fi
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        is_zh && echo "未找到 acme.sh。我们现在开始安装它。" || echo "acme.sh could not be found. we will install it"
        install_acme
        if [ $? -ne 0 ]; then
            is_zh && LOGE "安装 acme 失败，请检查日志。" || LOGE "install acme failed, please check logs"
            exit 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            is_zh && LOGW "不支持的系统，无法自动安装 socat" || LOGW "Unsupported OS for automatic socat installation"
            ;;
    esac
    if [ $? -ne 0 ]; then
        is_zh && LOGE "安装 socat 失败，请检查日志。" || LOGE "install socat failed, please check logs"
        exit 1
    else
        is_zh && LOGI "安装 socat 成功..." || LOGI "install socat succeed..."
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        is_zh && read -rp "请输入您的域名: " domain || read -rp "Please enter your domain name: " domain
        domain="${domain// /}" # Trim whitespace

        if [[ -z "$domain" ]]; then
            is_zh && LOGE "域名不能为空，请重试。" || LOGE "Domain name cannot be empty. Please try again."
            continue
        fi

        if ! is_domain "$domain"; then
            is_zh && LOGE "域名格式无效: ${domain}。请重新输入。" || LOGE "Invalid domain format: ${domain}. Please enter a valid domain name."
            continue
        fi

        break
    done
    is_zh && LOGD "您的域名为: ${domain}，正在检查..." || LOGD "Your domain is: ${domain}, checking it..."
    SSL_ISSUED_DOMAIN="${domain}"

    # detect existing certificate and reuse it if present
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        is_zh && LOGI "发现 ${domain} 已有证书，将复用它。" || LOGI "Existing certificate found for ${domain}, will reuse it."
        [[ -n "${certInfo}" ]] && LOGI "${certInfo}"
    else
        is_zh && LOGI "您的域名准备好申请证书了..." || LOGI "Your domain is ready for issuing certificates now..."
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    is_zh && read -rp "请选择使用的端口 (默认 80): " WebPort || read -rp "Please choose which port to use (default is 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        is_zh && LOGE "输入的端口 ${WebPort} 无效，将使用默认的 80 端口。" || LOGE "Your input ${WebPort} is invalid, will use default port 80."
        WebPort=80
    fi
    is_zh && LOGI "将使用端口: ${WebPort} 进行证书签发，请确保该端口已开启。" || LOGI "Will use port: ${WebPort} to issue certificates. Please make sure this port is open."

    if [[ ${cert_exists} -eq 0 ]]; then
        # issue the certificate
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            is_zh && LOGE "签发证书失败，请检查日志。" || LOGE "Issuing certificate failed, please check logs."
            rm -rf ~/.acme.sh/${domain}
            exit 1
        else
            is_zh && LOGI "签发证书成功，正在安装证书..." || LOGE "Issuing certificate succeeded, installing certificates..."
        fi
    else
        is_zh && LOGI "使用已有证书，正在安装..." || LOGI "Using existing certificate, installing certificates..."
    fi

    reloadCmd="ml restart"

    if is_zh; then
        LOGI "ACME 的默认重载命令 --reloadcmd 为: ${yellow}ml restart${plain}"
        LOGI "此命令将在每次证书签发和续签时运行。"
        read -rp "您是否想要修改 ACME 的 --reloadcmd？(y/n): " setReloadcmd
    else
        LOGI "Default --reloadcmd for ACME is: ${yellow}ml restart${plain}"
        LOGI "This command will run on every certificate issue and renew."
        read -rp "Would you like to modify --reloadcmd for ACME? (y/n): " setReloadcmd
    fi
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        if is_zh; then
            echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; ml restart"
            echo -e "${green}\t2.${plain} 输入自定义命令"
            echo -e "${green}\t0.${plain} 保持默认重载命令"
            read -rp "请选择: " choice
        else
            echo -e "\n${green}\t1.${plain} Preset: systemctl reload nginx ; ml restart"
            echo -e "${green}\t2.${plain} Input your own command"
            echo -e "${green}\t0.${plain} Keep default reloadcmd"
            read -rp "Choose an option: " choice
        fi
        case "$choice" in
            1)
                is_zh && LOGI "重载命令设为: systemctl reload nginx ; ml restart" || LOGI "Reloadcmd is: systemctl reload nginx ; ml restart"
                reloadCmd="systemctl reload nginx ; ml restart"
                ;;
            2)
                if is_zh; then
                    LOGD "推荐在末尾放置 ml restart，以防其他服务失败时报错退出"
                    read -rp "请输入您的重载命令 (例如: systemctl reload nginx ; ml restart): " reloadCmd
                    LOGI "您的重载命令是: ${reloadCmd}"
                else
                    LOGD "It's recommended to put ml restart at the end, so it won't raise an error if other services fails"
                    read -rp "Please enter your reloadcmd (example: systemctl reload nginx ; ml restart): " reloadCmd
                    LOGI "Your reloadcmd is: ${reloadCmd}"
                fi
                ;;
            *)
                is_zh && LOGI "保持默认重载命令" || LOGI "Keep default reloadcmd"
                ;;
        esac
    fi

    # install the certificate
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        is_zh && LOGI "证书安装成功，正在开启自动更新..." || LOGI "Installing certificate succeeded, enabling auto renew..."
    else
        is_zh && LOGE "证书安装失败，退出。" || LOGE "Installing certificate failed, exiting."
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain}
        fi
        exit 1
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        if is_zh; then
            LOGE "开启证书自动更新失败，具体证书信息如下:"
        else
            LOGE "Auto renew failed, certificate details:"
        fi
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
        exit 1
    else
        if is_zh; then
            LOGI "证书安装完成且自动续签已开启。具体信息如下:"
        else
            LOGI "Auto renew succeeded, certificate details:"
        fi
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Prompt user to set panel paths after successful certificate installation
    if is_zh; then
        read -rp "是否想要将此证书设置为面板证书路径？(y/n): " setPanel
    else
        read -rp "Would you like to set this certificate for the panel? (y/n): " setPanel
    fi
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            if is_zh; then
                LOGI "面板证书路径已设置为域名: $domain"
                LOGI "  - 证书文件: $webCertFile"
                LOGI "  - 私钥文件: $webKeyFile"
                echo -e "${green}访问地址: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            else
                LOGI "Panel paths set for domain: $domain"
                LOGI "  - Certificate File: $webCertFile"
                LOGI "  - Private Key File: $webKeyFile"
                echo -e "${green}Access URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            fi
            restart
        else
            is_zh && LOGE "错误：未找到域名 $domain 的证书或私钥文件。" || LOGE "Error: Certificate or private key file not found for domain: $domain."
        fi
    else
        is_zh && LOGI "跳过设置面板证书路径。" || LOGI "Skipping panel path setting."
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    if is_zh; then
        LOGI "****** 使用说明 ******"
        LOGI "请按照以下步骤完成申请："
        LOGI "1. 准备 Cloudflare 注册邮箱。"
        LOGI "2. 准备 Cloudflare Global API Key。"
        LOGI "3. 准备要申请的域名。"
        LOGI "4. 证书签发成功后，会提示您是否将证书绑定到面板（可选）。"
        LOGI "5. 脚本在安装后支持 SSL 证书的自动续签。"
        confirm "您是否确认上述信息并希望继续？[y/n]" "y"
    else
        LOGI "****** Instructions for Use ******"
        LOGI "Follow the steps below to complete the process:"
        LOGI "1. Cloudflare Registered E-mail."
        LOGI "2. Cloudflare Global API Key."
        LOGI "3. The Domain Name."
        LOGI "4. Once the certificate is issued, you will be prompted to set the certificate for the panel (optional)."
        LOGI "5. The script also supports automatic renewal of the SSL certificate after installation."
        confirm "Do you confirm the information and wish to proceed? [y/n]" "y"
    fi

    if [ $? -eq 0 ]; then
        # Check for acme.sh first
        if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
            is_zh && echo "未找到 acme.sh。我们现在开始安装它。" || echo "acme.sh could not be found. We will install it."
            install_acme
            if [ $? -ne 0 ]; then
                is_zh && LOGE "安装 acme 失败，请检查日志。" || LOGE "Install acme failed, please check logs."
                exit 1
            fi
        fi

        CF_Domain=""

        if is_zh; then
            LOGD "请输入域名名称:"
            read -rp "输入您的域名: " CF_Domain
            LOGD "您的域名已设置为: ${CF_Domain}"
        else
            LOGD "Please set a domain name:"
            read -rp "Input your domain here: " CF_Domain
            LOGD "Your domain name is set to: ${CF_Domain}"
        fi

        # Set up Cloudflare API details
        CF_GlobalKey=""
        CF_AccountEmail=""
        if is_zh; then
            LOGD "请输入 API Key:"
            read -rp "输入您的 Global API Key: " CF_GlobalKey
            LOGD "您的 API Key 是: ${CF_GlobalKey}"

            LOGD "请输入 Cloudflare 注册邮箱:"
            read -rp "输入您的邮箱: " CF_AccountEmail
            LOGD "您的注册邮箱是: ${CF_AccountEmail}"
        else
            LOGD "Please set the API key:"
            read -rp "Input your key here: " CF_GlobalKey
            LOGD "Your API key is: ${CF_GlobalKey}"

            LOGD "Please set up registered email:"
            read -rp "Input your email here: " CF_AccountEmail
            LOGD "Your registered email address is: ${CF_AccountEmail}"
        fi

        # Set the default CA to Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        if [ $? -ne 0 ]; then
            is_zh && LOGE "设置默认 CA 失败，脚本退出..." || LOGE "Default CA, Let'sEncrypt fail, script exiting..."
            exit 1
        fi

        export CF_Key="${CF_GlobalKey}"
        export CF_Email="${CF_AccountEmail}"

        # Issue the certificate using Cloudflare DNS
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
        if [ $? -ne 0 ]; then
            is_zh && LOGE "证书签发失败，脚本退出..." || LOGE "Certificate issuance failed, script exiting..."
            exit 1
        fi

        # Install the certificate
        certPath="/root/cert/${CF_Domain}"
        if [ -d "$certPath" ]; then
            rm -rf ${certPath}
        fi

        mkdir -p ${certPath}
        if [ $? -ne 0 ]; then
            is_zh && LOGE "无法创建目录: ${certPath}" || LOGE "Failed to create directory: ${certPath}"
            exit 1
        fi

        reloadCmd="ml restart"

        if is_zh; then
            LOGI "ACME 的默认重载命令 --reloadcmd 为: ${yellow}ml restart${plain}"
            LOGI "此命令将在每次证书签发和续签时运行。"
            read -rp "您是否想要修改 ACME 的 --reloadcmd？(y/n): " setReloadcmd
        else
            LOGI "Default --reloadcmd for ACME is: ${yellow}ml restart${plain}"
            LOGI "This command will run on every certificate issue and renew."
            read -rp "Would you like to modify --reloadcmd for ACME? (y/n): " setReloadcmd
        fi
        if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
            if is_zh; then
                echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; ml restart"
                echo -e "${green}\t2.${plain} 输入自定义命令"
                echo -e "${green}\t0.${plain} 保持默认重载命令"
                read -rp "请选择: " choice
            else
                echo -e "\n${green}\t1.${plain} Preset: systemctl reload nginx ; ml restart"
                echo -e "${green}\t2.${plain} Input your own command"
                echo -e "${green}\t0.${plain} Keep default reloadcmd"
                read -rp "Choose an option: " choice
            fi
            case "$choice" in
                1)
                    is_zh && LOGI "重载命令设为: systemctl reload nginx ; ml restart" || LOGI "Reloadcmd is: systemctl reload nginx ; ml restart"
                    reloadCmd="systemctl reload nginx ; ml restart"
                    ;;
                2)
                    if is_zh; then
                        LOGD "推荐在末尾放置 ml restart，以防其他服务失败时报错退出"
                        read -rp "请输入您的重载命令 (例如: systemctl reload nginx ; ml restart): " reloadCmd
                        LOGI "您的重载命令是: ${reloadCmd}"
                    else
                        LOGD "It's recommended to put ml restart at the end, so it won't raise an error if other services fails"
                        read -rp "Please enter your reloadcmd (example: systemctl reload nginx ; ml restart): " reloadCmd
                        LOGI "Your reloadcmd is: ${reloadCmd}"
                    fi
                    ;;
                *)
                    is_zh && LOGI "保持默认重载命令" || LOGI "Keep default reloadcmd"
                    ;;
            esac
        fi
        ~/.acme.sh/acme.sh --installcert -d ${CF_Domain} -d *.${CF_Domain} \
            --key-file ${certPath}/privkey.pem \
            --fullchain-file ${certPath}/fullchain.pem --reloadcmd "${reloadCmd}"

        if [ $? -ne 0 ]; then
            is_zh && LOGE "证书安装失败，脚本退出..." || LOGE "Certificate installation failed, script exiting..."
            exit 1
        else
            if is_zh; then
                LOGI "证书安装完成且自动续签已开启。具体信息如下:"
            else
                LOGI "Certificate installed successfully, Turning on automatic updates..."
            fi
        fi

        # Enable auto-update
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            is_zh && LOGE "自动更新设置失败，脚本退出..." || LOGE "Auto update setup failed, script exiting..."
            exit 1
        else
            if is_zh; then
                LOGI "证书安装完成且自动续签已开启。具体信息如下:"
            else
                LOGI "The certificate is installed and auto-renewal is turned on. Specific information is as follows:"
            fi
            ls -lah ${certPath}/*
            chmod 600 ${certPath}/privkey.pem
            chmod 644 ${certPath}/fullchain.pem
        fi

        # Prompt user to set panel paths after successful certificate installation
        if is_zh; then
            read -rp "是否想要将此证书设置为面板证书路径？(y/n): " setPanel
        else
            read -rp "Would you like to set this certificate for the panel? (y/n): " setPanel
        fi
        if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
            local webCertFile="${certPath}/fullchain.pem"
            local webKeyFile="${certPath}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                if is_zh; then
                    LOGI "面板证书路径已设置为域名: $CF_Domain"
                    LOGI "  - 证书文件: $webCertFile"
                    LOGI "  - 私钥文件: $webKeyFile"
                    echo -e "${green}访问地址: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                else
                    LOGI "Panel paths set for domain: $CF_Domain"
                    LOGI "  - Certificate File: $webCertFile"
                    LOGI "  - Private Key File: $webKeyFile"
                    echo -e "${green}Access URL: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                fi
                restart
            else
                is_zh && LOGE "错误：未找到域名 $CF_Domain 的证书或私钥文件。" || LOGE "Error: Certificate or private key file not found for domain: $CF_Domain."
            fi
        else
            is_zh && LOGI "跳过设置面板证书路径。" || LOGI "Skipping panel path setting."
        fi
    fi
}

run_speedtest() {
    # Check if Speedtest is already installed
    if ! command -v speedtest &> /dev/null; then
        # If not installed, determine installation method
        if command -v snap &> /dev/null; then
            # Use snap to install Speedtest
            echo "Installing Speedtest using snap..."
            snap install speedtest
        else
            # Fallback to using package managers
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "Error: Package manager not found. You may need to install Speedtest manually."
                return 1
            else
                echo "Installing Speedtest using $pkg_manager..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    if is_zh; then
        echo -e "\n${green}\t1.${plain} 安装 Fail2ban 并配置 IP 限制"
        echo -e "${green}\t2.${plain} 修改封禁时长"
        echo -e "${green}\t3.${plain} 解除全部封禁"
        echo -e "${green}\t4.${plain} 查看封禁日志"
        echo -e "${green}\t5.${plain} 封禁一个 IP"
        echo -e "${green}\t6.${plain} 解封一个 IP"
        echo -e "${green}\t7.${plain} 实时日志"
        echo -e "${green}\t8.${plain} 服务状态"
        echo -e "${green}\t9.${plain} 重启服务"
        echo -e "${green}\t10.${plain} 卸载 Fail2ban 和 IP 限制"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
    echo -e "\n${green}\t1.${plain} Install Fail2ban and configure IP Limit"
    echo -e "${green}\t2.${plain} Change Ban Duration"
    echo -e "${green}\t3.${plain} Unban Everyone"
    echo -e "${green}\t4.${plain} Ban Logs"
    echo -e "${green}\t5.${plain} Ban an IP Address"
    echo -e "${green}\t6.${plain} Unban an IP Address"
    echo -e "${green}\t7.${plain} Real-Time Logs"
    echo -e "${green}\t8.${plain} Service Status"
    echo -e "${green}\t9.${plain} Service Restart"
    echo -e "${green}\t10.${plain} Uninstall Fail2ban and IP Limit"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    fi
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            if is_zh; then
                confirm "确定要安装 Fail2ban & 配置 IP 限制吗？" "y"
            else
                confirm "Proceed with installation of Fail2ban & IP Limit?" "y"
            fi
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            if is_zh; then
                read -rp "请输入新的封禁时长 (分钟) [默认 30]: " NUM
            else
                read -rp "Please enter new Ban Duration in Minutes [default 30]: " NUM
            fi
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                is_zh && echo -e "${red}${NUM} 不是一个有效的数字！请重试。${plain}" || echo -e "${red}${NUM} is not a number! Please, try again.${plain}"
            fi
            iplimit_main
            ;;
        3)
            if is_zh; then
                confirm "确定要解封所有的被限制 IP 吗？" "y"
            else
                confirm "Proceed with Unbanning everyone from IP Limit jail?" "y"
            fi
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                is_zh && echo -e "${green}所有用户均已成功解封。${plain}" || echo -e "${green}All users Unbanned successfully.${plain}"
                iplimit_main
            else
                is_zh && echo -e "${yellow}操作已取消。${plain}" || echo -e "${yellow}Cancelled.${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            is_zh && read -rp "请输入要封禁的 IP 地址: " ban_ip || read -rp "Enter the IP address you want to ban: " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                is_zh && echo -e "${green}IP 地址 ${ban_ip} 已成功封禁。${plain}" || echo -e "${green}IP Address ${ban_ip} has been banned successfully.${plain}"
            else
                is_zh && echo -e "${red}IP 地址格式无效！请重试。${plain}" || echo -e "${red}Invalid IP address format! Please try again.${plain}"
            fi
            iplimit_main
            ;;
        6)
            is_zh && read -rp "请输入要解封的 IP 地址: " unban_ip || read -rp "Enter the IP address you want to unban: " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                is_zh && echo -e "${green}IP 地址 ${unban_ip} 已成功解封。${plain}" || echo -e "${green}IP Address ${unban_ip} has been unbanned successfully.${plain}"
            else
                is_zh && echo -e "${red}IP 地址格式无效！请重试。${plain}" || echo -e "${red}Invalid IP address format! Please try again.${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            iplimit_main
            ;;
    esac
}

install_iplimit() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}Fail2ban is not installed. Installing now...!${plain}\n"

        # Install fail2ban together with nftables. Recent fail2ban packages
        # default to `banaction = nftables-multiport` in /etc/fail2ban/jail.conf,
        # but the `nftables` package isn't pulled in as a dependency on most
        # minimal server images (Debian 12+, Ubuntu 24+, fresh RHEL-family).
        # Without `nft` in PATH the default sshd jail fails to ban with
        #   stderr: '/bin/sh: 1: nft: not found'
        # even though our own 3x-ipl jail uses iptables. Bundling the binary
        # at install time prevents that confusing log spam for new installs.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 24 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                dnf -y update && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum update -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf -y update && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Syu --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}Unsupported operating system. Please check the script and install the necessary packages manually.${plain}\n"
                exit 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Fail2ban installation failed.${plain}\n"
            exit 1
        fi

        echo -e "${green}Fail2ban installed successfully!${plain}\n"
    else
        echo -e "${yellow}Fail2ban is already installed.${plain}\n"
    fi

    echo -e "${green}Configuring IP Limit...${plain}\n"

    # make sure there's no conflict for jail files
    iplimit_remove_conflicts

    # Check if log file exists
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Check if service log file exists so fail2ban won't return error
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Create the iplimit jail files
    # we didn't pass the bantime here to use the default value
    create_iplimit_jails

    # Launching fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}IP Limit installed and configured successfully!${plain}\n"
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} Only remove IP Limit configurations"
    echo -e "${green}\t2.${plain} Uninstall Fail2ban and IP Limit"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}Unsupported operating system. Please uninstall Fail2ban manually.${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban and IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}Checking ban logs...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Fail2ban service is not running!${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Fail2ban service is not running!${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}Recent system ban activities from fail2ban.log:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}No recent system ban activities found${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}3X-IPL ban log entries:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}No ban entries found${plain}"
        else
            echo -e "${yellow}Ban log file is empty${plain}"
        fi
    else
        echo -e "${red}Ban log file not found at: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}Current jail status:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Unable to get jail status${plain}"
}

create_iplimit_jails() {
    # Use default bantime if not passed => 30 minutes
    local bantime="${1:-30}"

    # Uncomment 'allowipv6 = auto' in fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # On Debian 12+ fail2ban's default backend should be changed to systemd
    if [[ "${release}" == "debian" && ${os_version} -ge 12 ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=2
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<name>

actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> ${iplimit_banned_log_path}

[Init]
name = default
protocol = tcp
chain = INPUT
EOF

    echo -e "${green}Ip Limit jail files created with a bantime of ${bantime} minutes.${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Check for [3x-ipl] config in jail file then remove it
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}Removing conflicts of [3x-ipl] in jail (${file})!${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
        if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        is_zh && echo -e "${green}面板已使用 SSL 证书加密，非常安全。${plain}" || echo -e "${green}Panel is secure with SSL.${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        if is_zh; then
            echo -e "\n${red}警告：未检测到 SSL 证书和私钥！面板目前处于未加密状态。${plain}"
            echo "建议您申请 SSL 证书，或者配置 SSH 端口转发以保障安全。"
        else
            echo -e "\n${red}Warning: No Cert and Key found! The panel is not secure.${plain}"
            echo "Please obtain a certificate or set up SSH port forwarding."
        fi
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        if is_zh; then
            echo -e "\n${green}当前 SSH 端口转发配置:${plain}"
            echo -e "标准 SSH 转发命令:"
            echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\n如果是使用 SSH 密钥连接:"
            echo -e "${yellow}ssh -i <密钥路径> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\n连接成功后，在浏览器访问本地地址打开面板:"
            echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
        else
            echo -e "\n${green}Current SSH Port Forwarding Configuration:${plain}"
            echo -e "Standard SSH command:"
            echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\nIf using SSH key:"
            echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\nAfter connecting, access the panel at:"
            echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
        fi
    fi

    if is_zh; then
        echo -e "\n请选择:"
        echo -e "${green}1.${plain} 设置监听 IP (Listen IP)"
        echo -e "${green}2.${plain} 清除监听 IP"
        echo -e "${green}0.${plain} 返回主菜单"
        read -rp "请选择: " num
    else
        echo -e "\nChoose an option:"
        echo -e "${green}1.${plain} Set listen IP"
        echo -e "${green}2.${plain} Clear listen IP"
        echo -e "${green}0.${plain} Back to Main Menu"
        read -rp "Choose an option: " num
    fi

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                if is_zh; then
                    echo -e "\n未配置监听 IP。请选择:"
                    echo -e "1. 使用默认 IP (127.0.0.1)"
                    echo -e "2. 设置自定义 IP"
                    read -rp "请选择 (1 或 2): " listen_choice
                else
                    echo -e "\nNo listenIP configured. Choose an option:"
                    echo -e "1. Use default IP (127.0.0.1)"
                    echo -e "2. Set a custom IP"
                    read -rp "Select an option (1 or 2): " listen_choice
                fi

                config_listenIP="127.0.0.1"
                if [[ "$listen_choice" == "2" ]]; then
                    is_zh && read -rp "请输入自定义监听 IP: " config_listenIP || read -rp "Enter custom IP to listen on: " config_listenIP
                fi

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                if is_zh; then
                    echo -e "${green}监听 IP 已成功设置为 ${config_listenIP}。${plain}"
                    echo -e "\n${green}SSH 端口转发配置:${plain}"
                    echo -e "标准 SSH 转发命令:"
                    echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\n如果是使用 SSH 密钥连接:"
                    echo -e "${yellow}ssh -i <密钥路径> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\n连接成功后，在浏览器访问本地地址打开面板:"
                    echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                else
                    echo -e "${green}listen IP has been set to ${config_listenIP}.${plain}"
                    echo -e "\n${green}SSH Port Forwarding Configuration:${plain}"
                    echo -e "Standard SSH command:"
                    echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\nIf using SSH key:"
                    echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\nAfter connecting, access the panel at:"
                    echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                fi
                restart
            else
                config_listenIP="${existing_listenIP}"
                is_zh && echo -e "${green}当前监听 IP 已设置为 ${config_listenIP}。${plain}" || echo -e "${green}Current listen IP is already set to ${config_listenIP}.${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            is_zh && echo -e "${green}监听 IP 已成功清除。${plain}" || echo -e "${green}Listen IP has been cleared.${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            is_zh && echo -e "${red}无效选项。请选择正确的数字。${plain}\n" || echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

show_usage() {
    if is_zh; then
        echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}X-MILI 控制菜单用法（子命令）:${plain}                              │
│                                                                │
│  ${blue}ml${plain}                        - 管理脚本                         │
│  ${blue}ml start${plain}                  - 启动                             │
│  ${blue}ml stop${plain}                   - 停止                             │
│  ${blue}ml restart${plain}                - 重启面板                         │
│  ${blue}ml restart-xray${plain}           - 重启 Xray                        │
│  ${blue}ml status${plain}                 - 查看状态                         │
│  ${blue}ml settings${plain}               - 查看当前设置                     │
│  ${blue}ml enable${plain}                 - 开机自启                         │
│  ${blue}ml disable${plain}                - 关闭开机自启                     │
│  ${blue}ml log${plain}                    - 查看日志                         │
│  ${blue}ml banlog${plain}                 - 查看封禁日志                     │
│  ${blue}ml update${plain}                 - 更新                             │
│  ${blue}ml update-all-geofiles${plain}    - 更新 Geo 文件                    │
│  ${blue}ml install${plain}                - 安装                             │
│  ${blue}ml uninstall${plain}              - 卸载                             │
└────────────────────────────────────────────────────────────────┘"
        return
    fi
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}X-MILI control menu usages (subcommands):${plain}                     │
│                                                                │
│  ${blue}ml${plain}                        - Admin Management Script           │
│  ${blue}ml start${plain}                  - Start                             │
│  ${blue}ml stop${plain}                   - Stop                              │
│  ${blue}ml restart${plain}                - Restart                           │
|  ${blue}ml restart-xray${plain}           - Restart Xray                      │
│  ${blue}ml status${plain}                 - Current Status                    │
│  ${blue}ml settings${plain}               - Current Settings                  │
│  ${blue}ml enable${plain}                 - Enable Autostart on OS Startup    │
│  ${blue}ml disable${plain}                - Disable Autostart on OS Startup   │
│  ${blue}ml log${plain}                    - Check logs                        │
│  ${blue}ml banlog${plain}                 - Check Fail2ban ban logs           │
│  ${blue}ml update${plain}                 - Update                            │
│  ${blue}ml update-all-geofiles${plain}    - Update all geo files              │
│  ${blue}ml install${plain}                - Install                           │
│  ${blue}ml uninstall${plain}              - Uninstall                         │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    choose_language
    if is_zh; then
        echo -e "
╔────────────────────────────────────────────────╗
│   ${green}X-MILI 面板管理脚本${plain}                         │
│   ${green}0.${plain} 退出脚本                                 │
│────────────────────────────────────────────────│
│   ${green}1.${plain} 安装                                     │
│   ${green}2.${plain} 更新                                     │
│   ${green}3.${plain} 更新菜单                                 │
│   ${green}4.${plain} 卸载                                     │
│────────────────────────────────────────────────│
│   ${green}5.${plain} 重置用户名和密码                         │
│   ${green}6.${plain} 重置面板访问路径                         │
│   ${green}7.${plain} 重置面板设置                             │
│   ${green}8.${plain} 修改端口                                 │
│   ${green}9.${plain} 查看当前设置                             │
│────────────────────────────────────────────────│
│  ${green}10.${plain} 启动                                     │
│  ${green}11.${plain} 停止                                     │
│  ${green}12.${plain} 重启面板                                 │
|  ${green}13.${plain} 重启 Xray                                │
│  ${green}14.${plain} 查看状态                                 │
│  ${green}15.${plain} 日志管理                                 │
│────────────────────────────────────────────────│
│  ${green}16.${plain} 开启开机自启                             │
│  ${green}17.${plain} 关闭开机自启                             │
│────────────────────────────────────────────────│
│  ${green}18.${plain} SSL 证书管理                             │
│  ${green}19.${plain} Cloudflare SSL 证书                      │
│  ${green}20.${plain} IP 限制管理                              │
│  ${green}21.${plain} 防火墙管理                               │
│  ${green}22.${plain} SSH 端口转发管理                         │
│────────────────────────────────────────────────│
│  ${green}23.${plain} 启用 BBR                                 │
│  ${green}24.${plain} 更新 Geo 文件                            │
│  ${green}25.${plain} Ookla 测速                               │
╚────────────────────────────────────────────────╝
"
        show_status
        echo && read -rp "请输入选项 [0-25]: " num
    else
    echo -e "
╔────────────────────────────────────────────────╗
│   ${green}X-MILI Panel Management Script${plain}                │
│   ${green}0.${plain} Exit Script                               │
│────────────────────────────────────────────────│
│   ${green}1.${plain} Install                                   │
│   ${green}2.${plain} Update                                    │
│   ${green}3.${plain} Update Menu                               │
│   ${green}4.${plain} Uninstall                                 │
│────────────────────────────────────────────────│
│   ${green}5.${plain} Reset Username & Password                 │
│   ${green}6.${plain} Reset Web Base Path                       │
│   ${green}7.${plain} Reset Settings                            │
│   ${green}8.${plain} Change Port                               │
│   ${green}9.${plain} View Current Settings                     │
│────────────────────────────────────────────────│
│  ${green}10.${plain} Start                                     │
│  ${green}11.${plain} Stop                                      │
│  ${green}12.${plain} Restart                                   │
|  ${green}13.${plain} Restart Xray                              │
│  ${green}14.${plain} Check Status                              │
│  ${green}15.${plain} Logs Management                           │
│────────────────────────────────────────────────│
│  ${green}16.${plain} Enable Autostart                          │
│  ${green}17.${plain} Disable Autostart                         │
│────────────────────────────────────────────────│
│  ${green}18.${plain} SSL Certificate Management                │
│  ${green}19.${plain} Cloudflare SSL Certificate                │
│  ${green}20.${plain} IP Limit Management                       │
│  ${green}21.${plain} Firewall Management                       │
│  ${green}22.${plain} SSH Port Forwarding Management            │
│────────────────────────────────────────────────│
│  ${green}23.${plain} Enable BBR                                │
│  ${green}24.${plain} Update Geo Files                          │
│  ${green}25.${plain} Speedtest by Ookla                        │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "Please enter your selection [0-25]: " num
    fi

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_menu
            ;;
        4)
            uninstall
            ;;
        5)
            check_install && reset_user
            ;;
        6)
            check_install && reset_webbasepath
            ;;
        7)
            check_install && reset_config
            ;;
        8)
            check_install && set_port
            ;;
        9)
            check_install && check_config
            ;;
        10)
            check_install && start
            ;;
        11)
            check_install && stop
            ;;
        12)
            check_install && restart
            ;;
        13)
            check_install && restart_xray
            ;;
        14)
            check_install && status
            ;;
        15)
            check_install && show_log
            ;;
        16)
            check_install && enable
            ;;
        17)
            check_install && disable
            ;;
        18)
            ssl_cert_issue_main
            ;;
        19)
            ssl_cert_issue_CF
            ;;
        20)
            iplimit_main
            ;;
        21)
            firewall_menu
            ;;
        22)
            SSH_port_forwarding
            ;;
        23)
            bbr_menu
            ;;
        24)
            update_geo
            ;;
        25)
            run_speedtest
            ;;
        *)
            is_zh && LOGE "请输入正确的选项 [0-25]" || LOGE "Please enter the correct number [0-25]"
            ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "update")
            check_install 0 && update 0
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            uninstall 0
            ;;
        "update-all-geofiles")
            check_install 0 && update_all_geofiles 0 && restart 0
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
