#!/bin/bash

# ==========================================
# Realm 一键转发脚本 v3.2.6 (Alpine-only fork)
# 基于 wcwq98/realm 原版脚本裁剪:
# 1. 仅保留 Alpine Linux / OpenRC 支持
# 2. 移除 Debian / Ubuntu / CentOS 的 apt / yum 与 systemd 分支
# 3. 移除 Web 面板相关功能
# 4. Realm 安装与配置初始化逻辑与原版保持一致
# ==========================================

# --- 基础配置 ---
sh_ver="3.2.6"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 路径定义
REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
CONFIG_DIR="/root/.realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
REALM_OPENRC_SERVICE_FILE="/etc/init.d/realm"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_alpine() {
    [ -f /etc/alpine-release ]
}

detect_init_system() {
    if [ -n "${REALM_INIT_SYSTEM:-}" ]; then
        echo "$REALM_INIT_SYSTEM"
        return
    fi
    echo "openrc"
}

detect_package_manager() {
    if [ -n "${REALM_PACKAGE_MANAGER:-}" ]; then
        echo "$REALM_PACKAGE_MANAGER"
        return
    fi
    echo "apk"
}

is_musl_system() {
    is_alpine || { command_exists ldd && ldd --version 2>&1 | grep -qi musl; }
}

select_realm_filename() {
    local arch=${1:-$(uname -m)}
    local libc=${REALM_LIBC:-gnu}
    if [ -z "${REALM_LIBC:-}" ] && is_musl_system; then
        libc="musl"
    fi

    case "$arch" in
        x86_64) echo "realm-x86_64-unknown-linux-${libc}.tar.gz" ;;
        aarch64|arm64) echo "realm-aarch64-unknown-linux-${libc}.tar.gz" ;;
        *) return 1 ;;
    esac
}

service_action() {
    local service_name=$1
    local action=$2
    local manager
    manager=$(detect_init_system)

    case "$manager" in
        openrc)
            case "$action" in
                enable) rc-update add "$service_name" default ;;
                disable) rc-update del "$service_name" default >/dev/null 2>&1 || true ;;
                daemon-reload) return 0 ;;
                is-active) rc-service "$service_name" status >/dev/null 2>&1 ;;
                *) rc-service "$service_name" "$action" ;;
            esac
            ;;
        *)
            echo -e "${RED}错误: 不支持的服务管理器，请安装 OpenRC。${PLAIN}"
            return 1
            ;;
    esac
}

service_start() { service_action "$1" start; }
service_stop() { service_action "$1" stop; }
service_restart() { service_action "$1" restart; }
service_enable() { service_action "$1" enable; }
service_disable() { service_action "$1" disable; }
service_daemon_reload() { service_action "" daemon-reload; }
service_is_active() { service_action "$1" is-active >/dev/null 2>&1; }

# --- 状态检测函数 ---

get_status() {
    if service_is_active realm; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

# --- 核心校验函数 ---

validate_port() {
    local port
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    port=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        echo -e "${RED}错误: 端口必须是 1-65535 之间的数字。${PLAIN}"
        return 1
    fi
}

validate_ip() {
    local ip
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    ip=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if [[ -z "$ip" ]]; then
        echo -e "${RED}错误: 地址不能为空。${PLAIN}"
        return 1
    fi
    if [[ "$ip" =~ ^[][a-zA-Z0-9.:-]+$ ]]; then
        return 0
    else
        echo -e "${RED}错误: 无效的 IP 或域名格式。${PLAIN}"
        return 1
    fi
}

check_port_available() {
    local port
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    port=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if command -v ss >/dev/null; then
        if ss -tulpn | grep ":${port} " | grep -qv "realm"; then
            echo -e "${RED}错误: 本机端口 ${port} 已被其他程序占用。${PLAIN}"
            return 1
        fi
    fi
    return 0
}

check_rule_exists() {
    local port
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    port=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if [ -f "$CONFIG_FILE" ]; then
        if grep -qE "listen = \"(\\[::]:${port}|0\\.0\\.0\\.0:${port})\"" "$CONFIG_FILE"; then
            echo -e "${RED}错误: 端口 ${port} 的规则已存在。${PLAIN}"
            return 0
        fi
    fi
    return 1
}

# --- 基础功能 ---

init_env() {
    mkdir -p "$REALM_DIR"
    mkdir -p "$CONFIG_DIR"
    [ ! -f "$CONFIG_FILE" ] && write_config_header
}

write_config_header() {
    cat <<EOF > "$CONFIG_FILE"
[network]
no_tcp = false
use_udp = true

EOF
}

add_package() {
    local package=$1
    local existing
    for existing in "${packages[@]}"; do
        [ "$existing" = "$package" ] && return
    done
    packages+=("$package")
}

require_command_package() {
    local command_name=$1
    local package_name=$2
    command_exists "$command_name" || add_package "$package_name"
}

check_dependencies() {
    local packages=()

    require_command_package bash bash
    require_command_package wget wget
    require_command_package tar tar
    require_command_package sed sed
    require_command_package grep grep
    require_command_package curl curl
    require_command_package ss iproute2
    require_command_package update-ca-certificates ca-certificates
    require_command_package rc-service openrc
    require_command_package rc-update openrc

    if [ ${#packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}安装依赖: ${packages[*]} ...${PLAIN}"
        apk add --no-cache "${packages[@]}"
    fi
}

set_service_file_permissions() {
    local file_path=$1
    local mode=$2
    chown root:root "$file_path" 2>/dev/null || true
    chmod "$mode" "$file_path"
}

write_realm_service() {
    case "$(detect_init_system)" in
        openrc)
            cat <<EOF > "$REALM_OPENRC_SERVICE_FILE"
#!/sbin/openrc-run
name="Realm Forwarding Service"
description="Realm Forwarding Service"
supervisor="supervise-daemon"
command="${REALM_BIN}"
command_args="-c ${CONFIG_FILE}"
directory="${REALM_DIR}"
command_user="root"
respawn_delay=5
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
            set_service_file_permissions "$REALM_OPENRC_SERVICE_FILE" 0755
            ;;
        *)
            echo -e "${RED}无法创建服务文件: 不支持的服务管理器。${PLAIN}"
            return 1
            ;;
    esac
}

install_realm() {
    echo -e "${GREEN}> 部署 Realm...${PLAIN}"
    check_dependencies; init_env
    local version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$version" ] && version="v2.6.0"

    local arch=$(uname -m)
    local filename
    if ! filename=$(select_realm_filename "$arch"); then
        echo -e "${RED}不支持架构: $arch${PLAIN}"
        return 1
    fi

    wget -O "/tmp/realm.tar.gz" "https://github.com/zhboner/realm/releases/download/${version}/${filename}" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
    tar -xvf /tmp/realm.tar.gz -C "$REALM_DIR" && rm -f /tmp/realm.tar.gz
    chmod +x "$REALM_BIN"

    write_realm_service || return 1
    service_daemon_reload
    service_enable realm
    service_restart realm
    echo -e "${GREEN}安装完成${PLAIN}"
}

uninstall_realm() {
    read -p "确定卸载 Realm? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    service_stop realm
    service_disable realm
    rm -f "$REALM_OPENRC_SERVICE_FILE"
    service_daemon_reload
    rm -rf "$REALM_DIR"
    read -p "删除配置? [y/N]: " del_conf
    [[ "$del_conf" == "y" || "$del_conf" == "Y" ]] && rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}已卸载${PLAIN}"
}

# --- 转发管理 (已添加重试限制) ---

add_forward() {
    echo -e "${YELLOW}>>> 添加转发 (连续错误2次自动返回)${PLAIN}"
    
    # 1. 本机端口
    local attempt=0
    while true; do
        read -e -p "本机端口: " lp
        # 依次校验：格式、占用、重复
        if ! validate_port "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if ! check_port_available "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if check_rule_exists "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    # 2. 落地IP
    attempt=0
    while true; do
        read -e -p "落地IP/域名: " rip
        if ! validate_ip "$rip"; then
             ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
             continue
        fi
        break
    done

    # 3. 落地端口
    attempt=0
    while true; do
        read -e -p "落地端口: " rp
        if ! validate_port "$rp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "[::]:$lp"
remote = "$rip:$rp"
EOF
    restart_service
}

add_range_forward() {
    echo -e "${YELLOW}>>> 端口段转发 (连续错误2次自动返回)${PLAIN}"
    local attempt=0
    
    while true; do read -e -p "落地IP: " rip; validate_ip "$rip" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "起始端口: " sp; validate_port "$sp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "结束端口: " ep; validate_port "$ep" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "落地基准端口: " rbp; validate_port "$rbp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done

    [ "$sp" -ge "$ep" ] && { echo -e "${RED}起始必须小于结束${PLAIN}"; return; }

    echo "生成中..."
    local rp=$rbp
    for ((p=$sp; p<=$ep; p++)); do
        if ! grep -Fq "listen = \"[::]:$p\"" "$CONFIG_FILE"; then
            cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "[::]:$p"
remote = "$rip:$rp"
EOF
        fi
        ((rp++))
    done
    restart_service
}

delete_forward() {
    [ ! -f "$CONFIG_FILE" ] && return
    local listens=($(grep "listen =" "$CONFIG_FILE" | awk -F'"' '{print $2}'))
    local remotes=($(grep "remote =" "$CONFIG_FILE" | awk -F'"' '{print $2}'))
    [ ${#listens[@]} -eq 0 ] && { echo "无规则"; return; }

    echo "==============="
    for ((i=0; i<${#listens[@]}; i++)); do
        echo -e "${GREEN}$((i+1)).${PLAIN} ${listens[i]} -> ${remotes[i]}"
    done
    echo "==============="
    read -p "删除序号(0取消): " c
    [[ "$c" == "0" || -z "$c" ]] && return
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#listens[@]}" ]; then
        echo -e "${RED}无效序号${PLAIN}"; return
    fi
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"; write_config_header
    local del_idx=$((c-1))
    for ((i=0; i<${#listens[@]}; i++)); do
        if [ $i -ne $del_idx ]; then
            cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "${listens[i]}"
remote = "${remotes[i]}"
EOF
        fi
    done
    restart_service
}

# --- 服务控制 ---
start_service() {
    service_start realm && echo "已启动" || echo -e "${RED}启动失败${PLAIN}"
}

stop_service() {
    service_stop realm && echo "已停止" || echo -e "${RED}停止失败${PLAIN}"
}

restart_service() {
    service_daemon_reload
    service_restart realm
    sleep 1
    service_is_active realm && echo -e "${GREEN}重启成功${PLAIN}" || echo -e "${RED}重启失败${PLAIN}"
}

# --- 脚本更新 ---
Update_Shell() {
    local url="https://raw.githubusercontent.com/zincles/realm-alpine-cli/main/realm.sh"
    local new_ver=$(wget -qO- "$url" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | tr -d '"' | head -1)
    [[ -z "$new_ver" ]] && { echo -e "${RED}检测失败${PLAIN}"; return; }
    [[ "$new_ver" == "$sh_ver" ]] && { echo "已是最新"; return; }
    read -p "更新到 $new_ver? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && wget -N "$url" -O realm.sh && chmod +x realm.sh && echo "已更新" && exit 0
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "################################################"
    echo "#        Realm 一键转发脚本 (v${sh_ver})         #"
    echo "################################################"
    echo -e " Realm 状态: $(get_status)"
    echo "------------------------------------------------"
    echo "  1. 安装 / 重置 Realm"
    echo "  2. 卸载 Realm"
    echo "------------------------------------------------"
    echo "  3. 添加转发规则"
    echo "  4. 添加端口段转发"
    echo "  5. 删除转发规则"
    echo "  6. 查看当前配置"
    echo "------------------------------------------------"
    echo "  7. 启动服务"
    echo "  8. 停止服务"
    echo "  9. 重启服务"
    echo "------------------------------------------------"
    echo "  10. 更新脚本"
    echo "  0. 退出脚本"
    echo "################################################"
}

main() {
    check_dependencies; init_env
    while true; do
        show_menu
        read -p "选择 [0-10]: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_forward ;;
            4) add_range_forward ;;
            5) delete_forward ;;
            6) cat "$CONFIG_FILE" ;;
            7) start_service ;;
            8) stop_service ;;
            9) restart_service ;;
            10) Update_Shell ;;
            0) exit 0 ;;
            *) echo "无效" ;;
        esac
        [ "$opt" != "0" ] && read -p "按回车返回..."
    done
}

if [ "${REALM_TESTING:-0}" != "1" ]; then
    main
fi
