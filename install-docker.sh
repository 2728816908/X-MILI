#!/usr/bin/env bash
set -euo pipefail

APP_NAME="X-MILI"
REPO="https://github.com/2728816908/X-MILI"
RAW_BASE="https://raw.githubusercontent.com/2728816908/X-MILI/main"
INSTALL_ROOT="${X_MILI_DOCKER_ROOT:-/opt/x-mili-docker}"
SRC_DIR="${X_MILI_DOCKER_SOURCE_DIR:-${INSTALL_ROOT}/src}"
DATA_DIR="${X_MILI_DOCKER_DATA_DIR:-/etc/x-ui}"
CERT_DIR="${X_MILI_DOCKER_CERT_DIR:-/root/cert}"
CONTAINER_NAME="${X_MILI_DOCKER_CONTAINER:-ml_app}"
IMAGE_NAME="${X_MILI_DOCKER_IMAGE:-x-mili:latest}"
COMPOSE_FILE="${INSTALL_ROOT}/docker-compose.yml"
LANG_DIR="/etc/x-mili"
LANG_FILE="${LANG_DIR}/lang"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log() { echo -e "${green}[X-MILI Docker]${plain} $*"; }
warn() { echo -e "${yellow}[X-MILI Docker]${plain} $*"; }
fail() { echo -e "${red}[X-MILI Docker]${plain} $*" >&2; exit 1; }
step() { echo -e "${green}[X-MILI Docker]${plain} ${yellow}[$1/$2]${plain} $3"; }

[[ ${EUID} -ne 0 ]] && fail "请使用 root 运行 / Please run as root"

choose_language() {
    [[ -f "${LANG_FILE}" ]] && X_MILI_LANG=$(cat "${LANG_FILE}")
    if [[ -z "${X_MILI_LANG:-}" ]]; then
        echo -e "${green}1.${plain} English"
        echo -e "${green}2.${plain} 简体中文"
        read -rp "Please choose language / 请选择语言 [1-2]: " choice
        [[ "${choice}" == "2" ]] && X_MILI_LANG="zh_CN" || X_MILI_LANG="en_US"
        mkdir -p "${LANG_DIR}"
        echo "${X_MILI_LANG}" > "${LANG_FILE}"
    fi
}

is_zh() { [[ "${X_MILI_LANG}" == "zh_CN" ]]; }

install_base_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=1800 update
        apt-get -o DPkg::Lock::Timeout=1800 install -y ca-certificates curl git
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl git
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl git
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl git
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm ca-certificates curl git
    elif command -v zypper >/dev/null 2>&1; then
        zypper refresh
        zypper -q install -y ca-certificates curl git
    else
        fail "Unsupported package manager / 不支持的包管理器"
    fi
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        is_zh && log "正在安装 Docker" || log "Installing Docker"
        curl -fsSL https://get.docker.com -o /tmp/x-mili-get-docker.sh
        sh /tmp/x-mili-get-docker.sh
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi
    docker info >/dev/null 2>&1 || fail "Docker daemon is not running / Docker 服务未运行"
    docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is missing / 缺少 docker compose 插件"
}

prepare_tun() {
    mkdir -p /dev/net
    if [[ ! -c /dev/net/tun ]]; then
        mknod /dev/net/tun c 10 200
    fi
    chmod 600 /dev/net/tun
}

prepare_source() {
    mkdir -p "${INSTALL_ROOT}" "${DATA_DIR}" "${CERT_DIR}"
    if [[ -d "${SRC_DIR}/.git" ]]; then
        git -C "${SRC_DIR}" fetch --depth=1 origin main
        git -C "${SRC_DIR}" reset --hard origin/main
    else
        rm -rf "${SRC_DIR}"
        git clone --depth=1 "${REPO}" "${SRC_DIR}"
    fi
}

write_compose() {
    cat > "${COMPOSE_FILE}" <<EOF
services:
  ml:
    build:
      context: ${SRC_DIR}
      dockerfile: Dockerfile
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    volumes:
      - ${DATA_DIR}:/etc/x-ui
      - ${CERT_DIR}:/root/cert
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      XUI_ENABLE_FAIL2BAN: "false"
    tty: true
    # Xray/WARP/VPNGate need host networking and /dev/net/tun; this intentionally trades container isolation for VPN routing.
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    restart: unless-stopped
EOF
}

compose() {
    docker compose -f "${COMPOSE_FILE}" "$@"
}

exec_container() {
    if [[ -t 0 ]]; then
        docker exec -it "${CONTAINER_NAME}" "$@"
    else
        docker exec "${CONTAINER_NAME}" "$@"
    fi
}

gen_random_string() {
    local length="$1"
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${length}"
}

normalize_web_path() {
    local path="$1"
    [[ -n "${path}" ]] || path="/"
    [[ "${path}" == /* ]] || path="/${path}"
    [[ "${path}" == */ ]] || path="${path}/"
    echo "${path}"
}

extract_setting() {
    local info="$1"
    local key="$2"
    echo "${info}" | awk -v k="${key}:" '$1 == k {print $2; exit}'
}

container_setting() {
    docker exec "${CONTAINER_NAME}" /app/x-ui setting "$@" 2>/dev/null || true
}

panel_needs_initialization() {
    local info
    info=$(container_setting -show true)
    [[ -z "${info}" ]] && return 0
    echo "${info}" | grep -q "hasDefaultCredential: true"
}

read_panel_port() {
    local current_port="${1:-2053}"
    while true; do
        if is_zh; then
            read -rp "请设置登录面板的端口 [默认 ${current_port}]: " panel_port
        else
            read -rp "Panel port [default ${current_port}]: " panel_port
        fi
        panel_port="${panel_port:-$current_port}"
        if [[ "${panel_port}" =~ ^[0-9]+$ ]] && ((panel_port >= 1 && panel_port <= 65535)); then
            return
        fi
        is_zh && warn "端口必须是 1-65535" || warn "Port must be 1-65535"
    done
}

init_panel_settings() {
    panel_credentials_initialized=0
    if ! panel_needs_initialization; then
        is_zh && log "检测到已有非默认面板账号，保留现有登录信息" || log "Existing non-default panel account detected, keeping current login"
        return
    fi

    local info current_port
    info=$(container_setting -show true)
    current_port=$(extract_setting "${info}" "port")
    current_port="${current_port:-2053}"

    panel_username="${X_MILI_USERNAME:-}"
    panel_password="${X_MILI_PASSWORD:-}"
    panel_web_path="${X_MILI_WEB_BASE_PATH:-}"
    panel_port="${X_MILI_PANEL_PORT:-}"

    if [[ -t 0 ]]; then
        echo ""
        if is_zh; then
            echo -e "${green}Docker 首次安装向导：直接回车将随机生成，更安全。${plain}"
            read -rp "请设置登录面板的账号 [随机]: " panel_username
            read -rp "请设置登录面板的密码 [随机]: " panel_password
            [[ -n "${X_MILI_PANEL_PORT:-}" ]] || read_panel_port "${current_port}"
            read -rp "请设置登录面板的安全后缀 [随机，例如 /$(gen_random_string 8)/]: " panel_web_path
        else
            echo -e "${green}Docker first-time setup: press Enter to generate secure random values.${plain}"
            read -rp "Panel username [random]: " panel_username
            read -rp "Panel password [random]: " panel_password
            [[ -n "${X_MILI_PANEL_PORT:-}" ]] || read_panel_port "${current_port}"
            read -rp "Panel secure URL suffix [random, e.g. /$(gen_random_string 8)/]: " panel_web_path
        fi
    fi

    panel_username="${panel_username:-$(gen_random_string 10)}"
    panel_password="${panel_password:-$(gen_random_string 18)}"
    panel_web_path="${panel_web_path:-$(gen_random_string 18)}"
    panel_web_path=$(normalize_web_path "${panel_web_path}")
    panel_port="${panel_port:-$current_port}"

    docker exec "${CONTAINER_NAME}" /app/x-ui setting \
        -username "${panel_username}" \
        -password "${panel_password}" \
        -port "${panel_port}" \
        -resetTwoFactor true >/dev/null
    docker exec "${CONTAINER_NAME}" /app/x-ui setting -webBasePath "${panel_web_path}" >/dev/null
    docker restart "${CONTAINER_NAME}" >/dev/null
    panel_credentials_initialized=1
}

get_server_ip() {
    local ip
    ip=$(curl -s --max-time 3 https://api.ipify.org || true)
    [[ -n "${ip}" ]] || ip=$(curl -s --max-time 3 https://4.ident.me || true)
    [[ -n "${ip}" ]] && echo "${ip}" || echo "服务器IP"
}

write_host_menu() {
    cat > /usr/bin/ml <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/x-mili-docker"
COMPOSE_FILE="${ROOT}/docker-compose.yml"
CONTAINER="ml_app"
RAW_INSTALL="https://raw.githubusercontent.com/2728816908/X-MILI/main/install-docker.sh"

green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
plain='\033[0m'

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

exec_container() {
    if [[ -t 0 ]]; then
        docker exec -it "${CONTAINER}" "$@"
    else
        docker exec "${CONTAINER}" "$@"
    fi
}

need_compose() {
    [[ -f "${COMPOSE_FILE}" ]] || { echo -e "${red}Docker 版 X-MILI 未安装。${plain}"; exit 1; }
}

show_menu() {
    while true; do
        echo -e "
╔──────────────────────────────────────────────╗
│   ${green}X-MILI Docker 管理菜单${plain}                    │
│   ${green}1.${plain} 启动容器                               │
│   ${green}2.${plain} 停止容器                               │
│   ${green}3.${plain} 重启面板                               │
│   ${green}4.${plain} 重启 Xray                              │
│   ${green}5.${plain} 查看状态                               │
│   ${green}6.${plain} 查看面板设置                           │
│   ${green}7.${plain} 查看日志                               │
│   ${green}8.${plain} 进入容器 Shell                         │
│   ${green}9.${plain} 更新 Docker 版                         │
│  ${green}10.${plain} 卸载 Docker 版                         │
│   ${green}0.${plain} 退出                                   │
╚──────────────────────────────────────────────╝"
        read -rp "请输入选项 [0-10]: " num
        case "${num}" in
            1) ml start ;;
            2) ml stop ;;
            3) ml restart ;;
            4) ml restart-xray ;;
            5) ml status ;;
            6) ml settings ;;
            7) ml log ;;
            8) ml shell ;;
            9) ml update ;;
            10) ml uninstall ;;
            0) exit 0 ;;
            *) echo -e "${red}无效选项${plain}" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)
        need_compose
        show_menu
        ;;
    start)
        need_compose
        compose up -d
        ;;
    stop)
        need_compose
        compose stop
        ;;
    restart)
        need_compose
        compose restart
        ;;
    restart-xray)
        docker kill -s USR1 "${CONTAINER}" >/dev/null
        echo "Xray restart signal sent."
        ;;
    status)
        need_compose
        compose ps
        docker exec "${CONTAINER}" /app/x-ui setting -show true 2>/dev/null || true
        ;;
    settings)
        exec_container /app/x-ui setting -show true
        ;;
    log|logs)
        docker logs -f --tail=200 "${CONTAINER}"
        ;;
    shell)
        exec_container sh
        ;;
    exec)
        shift
        exec_container "$@"
        ;;
    update)
        curl -fsSL "${RAW_INSTALL}" | bash
        ;;
    uninstall)
        need_compose
        read -rp "确定卸载 Docker 版 X-MILI？数据目录 /etc/x-ui 会保留 [y/N]: " yn
        [[ "${yn}" == "y" || "${yn}" == "Y" ]] || exit 0
        compose down
        rm -rf "${ROOT}"
        rm -f /usr/bin/ml
        echo "已卸载 Docker 版 X-MILI，数据目录 /etc/x-ui 已保留。"
        ;;
    *)
        exec_container /app/x-ui "$@"
        ;;
esac
EOF
    chmod +x /usr/bin/ml
    sed -i \
        -e "s|ROOT=\"/opt/x-mili-docker\"|ROOT=\"${INSTALL_ROOT}\"|" \
        -e "s|CONTAINER=\"ml_app\"|CONTAINER=\"${CONTAINER_NAME}\"|" \
        -e "s|数据目录 /etc/x-ui 会保留|数据目录 ${DATA_DIR} 会保留|" \
        -e "s|数据目录 /etc/x-ui 已保留|数据目录 ${DATA_DIR} 已保留|" \
        /usr/bin/ml
}

save_installer_copy() {
    if [[ -f "$0" && "$(basename "$0")" == "install-docker.sh" ]]; then
        install -m 755 "$0" "${INSTALL_ROOT}/install-docker.sh" 2>/dev/null || true
    else
        curl -fsSL "${RAW_BASE}/install-docker.sh" -o "${INSTALL_ROOT}/install-docker.sh" || true
        chmod +x "${INSTALL_ROOT}/install-docker.sh" 2>/dev/null || true
    fi
}

print_guide() {
    local info port web_path server_ip
    info=$(container_setting -show true)
    port=$(extract_setting "${info}" "port")
    web_path=$(extract_setting "${info}" "webBasePath")
    port="${port:-2053}"
    web_path=$(normalize_web_path "${web_path}")
    server_ip=$(get_server_ip)

    echo ""
    echo -e "${green}================ X-MILI Docker 安装完成 ================${plain}"
    echo -e "管理命令: ${green}ml${plain}"
    echo -e "面板地址: ${green}http://${server_ip}:${port}${web_path}${plain}"
    if [[ "${panel_credentials_initialized:-0}" == "1" ]]; then
        echo -e "登录账号: ${green}${panel_username}${plain}"
        echo -e "登录密码: ${green}${panel_password}${plain}"
        echo -e "安全后缀: ${green}${web_path}${plain}"
    else
        echo -e "登录信息: ${yellow}已保留现有账号和密码${plain}"
    fi
    echo -e "数据目录: ${yellow}${DATA_DIR}${plain}"
    echo -e "容器名称: ${yellow}${CONTAINER_NAME}${plain}"
    echo -e "${green}=========================================================${plain}"
    echo ""
}

choose_language
is_zh && log "开始安装/更新 Docker 版 ${APP_NAME}" || log "Installing/updating Docker ${APP_NAME}"
is_zh && step 1 6 "安装基础依赖" || step 1 6 "Installing base dependencies"
install_base_deps
is_zh && step 2 6 "安装并检查 Docker" || step 2 6 "Installing/checking Docker"
install_docker
is_zh && step 3 6 "准备 TUN 设备和项目源码" || step 3 6 "Preparing TUN device and source"
prepare_tun
prepare_source
is_zh && step 4 6 "写入 Docker Compose 配置" || step 4 6 "Writing Docker Compose config"
write_compose
save_installer_copy
is_zh && step 5 6 "构建并启动容器" || step 5 6 "Building and starting container"
is_zh && warn "Docker 版会使用 host 网络和 TUN 设备，以支持 Xray/WARP/VPNGate 路由" || warn "Docker uses host network and TUN for Xray/WARP/VPNGate routing"
compose up -d --build
is_zh && step 6 6 "写入主机 ml 菜单并初始化面板" || step 6 6 "Writing host ml menu and initializing panel"
write_host_menu
init_panel_settings
print_guide

if [[ "${panel_credentials_initialized:-0}" == "1" && -t 0 ]]; then
    /usr/bin/ml
fi
