#!/usr/bin/env bash

# ============================================================
# Snell v6.0.0rc2 Debian 一键管理脚本
#
# 支持：
#   install    安装
#   update     更新/重新安装固定版本
#   uninstall  卸载
#   status     查看状态
#   start      启动
#   stop       停止
#   restart    重启
#   logs       查看日志
#   config     查看配置
#   port       修改端口
#   psk        重新生成 PSK
#
# 固定版本：
#   v6.0.0rc2
# ============================================================

set -Eeuo pipefail

# ============================================================
# 基础配置
# ============================================================

SNELL_VERSION="v6.0.0rc2"

SNELL_BIN="/usr/local/bin/snell-server"
SNELL_DIR="/etc/snell"
SNELL_CONF="${SNELL_DIR}/snell-server.conf"

SERVICE_NAME="snell"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

TMP_DIR="/tmp/snell-install"

# ============================================================
# 颜色
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ============================================================
# 输出函数
# ============================================================

info() {
    echo -e "${BLUE}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[OK]${RESET} $*"
}

warning() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

die() {
    error "$*"
    exit 1
}

# ============================================================
# 检查 root
# ============================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 权限运行，例如：sudo bash $0"
    fi
}

# ============================================================
# 检查 Debian
# ============================================================

check_debian() {
    if [[ ! -f /etc/debian_version ]]; then
        warning "当前系统不是标准 Debian，脚本仍会继续运行。"
    fi
}

# ============================================================
# 检查 systemd
# ============================================================

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        die "当前系统没有 systemd，无法创建 Snell systemd 服务。"
    fi
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    info "检查必要软件..."

    local packages=()

    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v unzip >/dev/null 2>&1 || packages+=("unzip")

    if [[ ${#packages[@]} -eq 0 ]]; then
        success "curl / unzip 已安装"
        return
    fi

    info "安装依赖：${packages[*]}"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y "${packages[@]}"

    success "依赖安装完成"
}

# ============================================================
# 检测 CPU 架构
# ============================================================

get_arch() {

    local arch
    arch="$(uname -m)"

    case "$arch" in

        x86_64|amd64)
            echo "amd64"
            ;;

        aarch64|arm64)
            echo "aarch64"
            ;;

        i386|i686)
            echo "i386"
            ;;

        armv7l|armv7)
            die "Snell v6 不支持当前 ARMv7 架构：$arch"
            ;;

        *)
            die "不支持的 CPU 架构：$arch"
            ;;

    esac
}

# ============================================================
# 获取下载地址
# ============================================================

get_download_url() {

    local arch
    arch="$(get_arch)"

    echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${arch}.zip"
}

# ============================================================
# 下载 Snell
# ============================================================

download_snell() {

    local url="$1"

    mkdir -p "$TMP_DIR"

    rm -f "${TMP_DIR}/snell.zip"

    info "下载 Snell ${SNELL_VERSION}"
    info "URL: ${url}"

    curl \
        --fail \
        --location \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 300 \
        -o "${TMP_DIR}/snell.zip" \
        "$url"

    [[ -s "${TMP_DIR}/snell.zip" ]] || die "Snell 下载失败"

    success "Snell 下载完成"
}

# ============================================================
# 安装二进制
# ============================================================

install_binary() {

    info "安装 Snell 二进制文件..."

    mkdir -p /usr/local/bin

    unzip -o "${TMP_DIR}/snell.zip" -d /usr/local/bin >/dev/null

    [[ -f "$SNELL_BIN" ]] || die "找不到 ${SNELL_BIN}"

    chmod 755 "$SNELL_BIN"

    success "Snell 二进制安装完成"

    echo
    info "当前版本："

    "$SNELL_BIN" -v || true
}

# ============================================================
# 创建配置目录
# ============================================================

create_config_dir() {

    mkdir -p "$SNELL_DIR"

    chmod 755 "$SNELL_DIR"
}

# ============================================================
# 生成配置
# ============================================================

create_config() {

    if [[ -f "$SNELL_CONF" ]]; then

        warning "检测到已有配置："
        echo "  $SNELL_CONF"
        echo

        read -r -p "是否保留现有配置？[Y/n]: " answer

        answer="${answer:-Y}"

        if [[ "$answer" =~ ^[Nn]$ ]]; then

            cp -a "$SNELL_CONF" \
                "${SNELL_CONF}.backup.$(date +%Y%m%d%H%M%S)"

            info "已创建配置备份"

            rm -f "$SNELL_CONF"

        else

            success "保留现有配置"

            return
        fi
    fi

    echo
    info "使用 Snell 官方 wizard 创建配置..."
    echo

    "$SNELL_BIN" --wizard -c "$SNELL_CONF"

    [[ -f "$SNELL_CONF" ]] || die "配置文件创建失败"

    chmod 644 "$SNELL_CONF"

    success "配置文件创建完成"
}

# ============================================================
# 创建 systemd 服务
# ============================================================

create_systemd_service() {

    info "创建 systemd 服务..."

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Snell Proxy Service
Documentation=https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=nobody
Group=nogroup

ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf

Restart=on-failure
RestartSec=3

LimitNOFILE=65535

AmbientCapabilities=CAP_NET_BIND_SERVICE

NoNewPrivileges=true

StandardOutput=journal
StandardError=journal

SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload

    success "systemd 服务创建完成"
}

# ============================================================
# 启动服务
# ============================================================

start_service() {

    info "启动 Snell..."

    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true

    systemctl restart "$SERVICE_NAME"

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "Snell 已启动"
    else
        error "Snell 启动失败"
        echo
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        exit 1
    fi
}

# ============================================================
# 获取配置值
# ============================================================

get_config_value() {

    local key="$1"

    if [[ ! -f "$SNELL_CONF" ]]; then
        return 0
    fi

    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SNELL_CONF" \
        | head -n 1 \
        | sed -E "s/^[^=]*=[[:space:]]*//" \
        | tr -d '"' \
        | tr -d "'"
}

# ============================================================
# 获取端口
# ============================================================

get_port() {

    local port

    port="$(get_config_value "listen" || true)"

    if [[ "$port" =~ :([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi

    echo "未知"
}

# ============================================================
# 获取 PSK
# ============================================================

get_psk() {

    get_config_value "psk" || true
}

# ============================================================
# 获取公网 IPv4
# ============================================================

get_public_ipv4() {

    local ip=""

    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    fi

    echo "$ip"
}

# ============================================================
# 检查监听端口
# ============================================================

check_listen_port() {

    local port="$1"

    if [[ "$port" == "未知" || -z "$port" ]]; then
        return
    fi

    if command -v ss >/dev/null 2>&1; then

        if ss -lntup 2>/dev/null | grep -q ":${port} "; then
            success "端口 ${port} 正在监听"
        else
            warning "没有检测到端口 ${port} 正在监听"
        fi
    fi
}

# ============================================================
# UFW 防火墙
# ============================================================

configure_ufw() {

    local port="$1"

    if ! command -v ufw >/dev/null 2>&1; then
        return
    fi

    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        return
    fi

    echo
    warning "检测到 UFW 正在运行。"

    read -r -p "是否开放 Snell TCP 端口 ${port}？[Y/n]: " answer

    answer="${answer:-Y}"

    if [[ "$answer" =~ ^[Yy]$ ]]; then

        ufw allow "${port}/tcp"

        success "已开放 TCP ${port}"
    fi
}

# ============================================================
# 显示节点信息
# ============================================================

show_node_info() {

    local port
    local psk
    local ip

    port="$(get_port)"
    psk="$(get_psk)"
    ip="$(get_public_ipv4)"

    echo
    echo "============================================================"
    echo "                 Snell v6.0.0rc2"
    echo "============================================================"
    echo

    echo "版本："
    echo "  ${SNELL_VERSION}"

    echo
    echo "服务器 IPv4："
    echo "  ${ip:-获取失败}"

    echo
    echo "监听端口："
    echo "  ${port}"

    echo
    echo "PSK："
    echo "  ${psk:-未找到}"

    echo
    echo "Surge 节点："

    if [[ -n "$ip" && "$port" != "未知" && -n "$psk" ]]; then
        echo "  Snell-V6 = snell, ${ip}, ${port}, psk=${psk}, version=6"
    fi

    echo
    echo "配置文件："
    echo "  ${SNELL_CONF}"

    echo
    echo "服务："
    echo "  ${SERVICE_NAME}"

    echo
    echo "============================================================"
}

# ============================================================
# 安装
# ============================================================

install_snell() {

    echo
    echo "============================================================"
    echo "        Snell v6.0.0rc2 Debian 一键安装"
    echo "============================================================"
    echo

    if [[ -f "$SNELL_BIN" ]]; then
        warning "检测到 Snell 已经安装。"

        "$SNELL_BIN" -v || true

        echo
        read -r -p "继续重新安装 v6.0.0rc2？[y/N]: " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "已取消"
            exit 0
        fi
    fi

    check_debian
    check_systemd
    install_dependencies

    local arch
    local url

    arch="$(get_arch)"
    url="$(get_download_url)"

    echo
    info "CPU 架构：${arch}"
    info "Snell 版本：${SNELL_VERSION}"
    info "下载地址：${url}"

    download_snell "$url"

    install_binary

    create_config_dir

    create_config

    create_systemd_service

    start_service

    local port
    port="$(get_port)"

    configure_ufw "$port"

    rm -rf "$TMP_DIR"

    show_node_info

    echo
    success "Snell v6.0.0rc2 安装完成！"
}

# ============================================================
# 更新
# ============================================================

update_snell() {

    echo
    echo "============================================================"
    echo "        更新 Snell 到固定版本 v6.0.0rc2"
    echo "============================================================"
    echo

    check_systemd
    install_dependencies

    local arch
    local url

    arch="$(get_arch)"
    url="$(get_download_url)"

    info "CPU 架构：${arch}"
    info "目标版本：${SNELL_VERSION}"

    if [[ -f "$SNELL_CONF" ]]; then

        cp -a "$SNELL_CONF" \
            "${SNELL_CONF}.backup.$(date +%Y%m%d%H%M%S)"

        success "已备份现有配置"
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    download_snell "$url"

    install_binary

    create_config_dir
    create_systemd_service

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl start "$SERVICE_NAME"

    sleep 2

    rm -rf "$TMP_DIR"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "更新完成"
    else
        error "更新后 Snell 未正常运行"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        exit 1
    fi

    show_node_info
}

# ============================================================
# 卸载
# ============================================================

uninstall_snell() {

    echo
    warning "即将卸载 Snell v6.0.0rc2"
    echo

    read -r -p "确定卸载？[y/N]: " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "已取消"
        exit 0
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload

    rm -f "$SNELL_BIN"

    echo
    read -r -p "是否删除配置目录 ${SNELL_DIR}？[y/N]: " delete_config

    if [[ "$delete_config" =~ ^[Yy]$ ]]; then

        rm -rf "$SNELL_DIR"

        success "配置已删除"

    else

        success "保留配置目录：${SNELL_DIR}"
    fi

    rm -rf "$TMP_DIR"

    success "Snell 已卸载"
}

# ============================================================
# 状态
# ============================================================

status_snell() {

    echo
    echo "============================================================"
    echo "                    Snell 状态"
    echo "============================================================"
    echo

    if [[ -f "$SNELL_BIN" ]]; then
        echo "版本："
        "$SNELL_BIN" -v || true
    else
        warning "Snell 二进制不存在"
    fi

    echo

    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then

        systemctl --no-pager --full status "$SERVICE_NAME" || true

    else

        warning "systemd 服务不存在"
    fi

    echo

    if [[ -f "$SNELL_CONF" ]]; then

        local port
        port="$(get_port)"

        echo "监听端口：${port}"

        check_listen_port "$port"

    fi
}

# ============================================================
# 启动
# ============================================================

start_snell() {

    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl start "$SERVICE_NAME"

    success "Snell 已启动"
}

# ============================================================
# 停止
# ============================================================

stop_snell() {

    systemctl stop "$SERVICE_NAME"

    success "Snell 已停止"
}

# ============================================================
# 重启
# ============================================================

restart_snell() {

    systemctl restart "$SERVICE_NAME"

    sleep 1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "Snell 已重启"
    else
        error "Snell 重启失败"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        exit 1
    fi
}

# ============================================================
# 日志
# ============================================================

logs_snell() {

    echo
    info "显示 Snell 实时日志，按 Ctrl+C 退出"
    echo

    journalctl -u "$SERVICE_NAME" -f
}

# ============================================================
# 配置
# ============================================================

show_config() {

    if [[ ! -f "$SNELL_CONF" ]]; then
        die "配置文件不存在：${SNELL_CONF}"
    fi

    echo
    echo "============================================================"
    echo "                  Snell 配置文件"
    echo "============================================================"
    echo

    cat "$SNELL_CONF"

    echo
    echo "============================================================"
}

# ============================================================
# 修改端口
# ============================================================

change_port() {

    [[ -f "$SNELL_CONF" ]] || die "配置文件不存在"

    local old_port
    local new_port

    old_port="$(get_port)"

    echo
    echo "当前端口：${old_port}"
    echo

    read -r -p "请输入新的端口： " new_port

    if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then
        die "端口必须是数字"
    fi

    if (( new_port < 1 || new_port > 65535 )); then
        die "端口范围必须是 1-65535"
    fi

    if [[ "$old_port" == "$new_port" ]]; then
        info "端口没有变化"
        exit 0
    fi

    cp -a "$SNELL_CONF" \
        "${SNELL_CONF}.backup.$(date +%Y%m%d%H%M%S)"

    sed -i -E \
        "s|^([[:space:]]*listen[[:space:]]*=[[:space:]]*[^:]*:)[0-9]+|\1${new_port}|" \
        "$SNELL_CONF"

    systemctl restart "$SERVICE_NAME"

    sleep 1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "端口已修改为 ${new_port}"
    else
        error "修改端口后 Snell 启动失败"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        exit 1
    fi

    configure_ufw "$new_port"

    show_node_info
}

# ============================================================
# 生成随机 PSK
# ============================================================

generate_psk() {

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
        return
    fi

    if [[ -r /dev/urandom ]]; then
        od -An -N16 -tx1 /dev/urandom \
            | tr -d ' \n'
        return
    fi

    die "无法生成随机 PSK"
}

# ============================================================
# 修改 PSK
# ============================================================

change_psk() {

    [[ -f "$SNELL_CONF" ]] || die "配置文件不存在"

    echo
    warning "修改 PSK 后，客户端节点也必须同步修改。"
    echo

    local new_psk

    new_psk="$(generate_psk)"

    echo "新的 PSK："
    echo
    echo "  ${new_psk}"
    echo

    read -r -p "确认使用这个 PSK？[y/N]: " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "已取消"
        exit 0
    fi

    cp -a "$SNELL_CONF" \
        "${SNELL_CONF}.backup.$(date +%Y%m%d%H%M%S)"

    if grep -qE "^[[:space:]]*psk[[:space:]]*=" "$SNELL_CONF"; then

        sed -i -E \
            "s|^[[:space:]]*psk[[:space:]]*=.*$|psk = ${new_psk}|" \
            "$SNELL_CONF"

    else

        printf '\npsk = %s\n' "$new_psk" >> "$SNELL_CONF"

    fi

    systemctl restart "$SERVICE_NAME"

    sleep 1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "PSK 已修改"
    else
        error "修改 PSK 后 Snell 启动失败"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        exit 1
    fi

    show_node_info
}

# ============================================================
# 菜单
# ============================================================

show_menu() {

    echo
    echo "============================================================"
    echo "              Snell v6.0.0rc2 管理脚本"
    echo "============================================================"
    echo
    echo "  1) 安装 Snell"
    echo "  2) 更新 Snell"
    echo "  3) 卸载 Snell"
    echo "  4) 查看状态"
    echo "  5) 启动"
    echo "  6) 停止"
    echo "  7) 重启"
    echo "  8) 查看日志"
    echo "  9) 查看配置"
    echo " 10) 修改端口"
    echo " 11) 修改 PSK"
    echo "  0) 退出"
    echo
    echo "============================================================"
    echo

    read -r -p "请选择 [0-11]: " choice

    case "$choice" in

        1)  install_snell ;;
        2)  update_snell ;;
        3)  uninstall_snell ;;
        4)  status_snell ;;
        5)  start_snell ;;
        6)  stop_snell ;;
        7)  restart_snell ;;
        8)  logs_snell ;;
        9)  show_config ;;
        10) change_port ;;
        11) change_psk ;;
        0)  exit 0 ;;

        *)
            error "无效选项"
            exit 1
            ;;

    esac
}

# ============================================================
# 命令行参数
# ============================================================

main() {

    check_root

    case "${1:-menu}" in

        install)
            install_snell
            ;;

        update)
            update_snell
            ;;

        uninstall|remove)
            uninstall_snell
            ;;

        status)
            status_snell
            ;;

        start)
            start_snell
            ;;

        stop)
            stop_snell
            ;;

        restart)
            restart_snell
            ;;

        logs|log)
            logs_snell
            ;;

        config)
            show_config
            ;;

        port)
            change_port
            ;;

        psk)
            change_psk
            ;;

        menu)
            show_menu
            ;;

        *)
            echo
            echo "Snell v6.0.0rc2 管理脚本"
            echo
            echo "用法："
            echo
            echo "  $0 install"
            echo "  $0 update"
            echo "  $0 uninstall"
            echo "  $0 status"
            echo "  $0 start"
            echo "  $0 stop"
            echo "  $0 restart"
            echo "  $0 logs"
            echo "  $0 config"
            echo "  $0 port"
            echo "  $0 psk"
            echo
            echo "不带参数进入管理菜单："
            echo
            echo "  $0"
            echo
            exit 1
            ;;

    esac
}

main "$@"