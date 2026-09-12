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

# --- 命令行参数 ---

cli_usage() {
    cat <<EOF
用法:
  realm.sh                                     进入交互菜单
  realm.sh --set-forward <规则> [选项]          非交互式设置转发

规则格式: <本机端口>:<远程IP或域名>:<远程端口>
  443:1.2.3.4:8443          转发本机 443 到 1.2.3.4 的 8443
  80:example.com:8080       远程地址支持域名
  443:[2001:db8::1]:8443    IPv6 远程地址需加方括号

选项:
  --set-forward <规则>   设置转发规则，可重复指定多条
  --listen-addr <地址>   本机监听地址，默认 [::]（双栈，兼顾 IPv4）
  --no-restart           仅写配置，不启用/重启服务
  -h, --help             显示本帮助

行为:
  - 端口不存在时新增规则
  - 端口已存在且远程地址相同则跳过（可重复执行，幂等）
  - 端口已存在但远程地址不同则替换该条规则
  - 默认自动 rc-update add realm default 并重启 realm 服务

示例:
  realm.sh --set-forward 443:1.2.3.4:8443
  realm.sh --set-forward 80:example.com:8080 --set-forward 443:1.2.3.4:8443
  realm.sh --set-forward 443:1.2.3.4:8443 --no-restart
EOF
}

# 取指定本机端口已配置的 remote（无匹配则无输出）
cli_get_remote() {
    local port=$1
    [ -f "$CONFIG_FILE" ] || return 0
    awk -v p="$port" '
        function reset() { inblk = 0; hit = 0 }
        /^\[\[endpoints\]\]/ { reset(); inblk = 1; next }
        /^\[/ { reset(); next }
        inblk && /^listen =/ { hit = ($0 ~ ("^listen = \"[^\"]*:" p "\"$")) ? 1 : 0 }
        inblk && hit && /^remote =/ {
            line = $0
            sub(/^remote = "/, "", line)
            sub(/"$/, "", line)
            print line
            exit
        }
    ' "$CONFIG_FILE"
}

# 删除指定本机端口所在的整个 [[endpoints]] 段，其余内容原样保留
# 仅用 awk 实现（busybox cat 不支持 -s 等 GNU 专有选项）
cli_remove_endpoint() {
    local port=$1 tmp
    tmp=$(mktemp) || return 1
    awk -v p="$port" '
        # 延迟输出空行：仅在其后有内容时才输出，避免删除段落后留下多余空行
        function emit(line) {
            if (line == "") { pending++; return }
            while (pending > 0) { print ""; pending-- }
            print line
        }
        function flush() {
            if (inblk) {
                if (!hit) { n = split(buf, arr, "\n"); for (i = 1; i <= n; i++) emit(arr[i]) }
                buf = ""; hit = 0; inblk = 0
            }
        }
        /^\[\[endpoints\]\]/ { flush(); inblk = 1; buf = $0 "\n"; next }
        /^\[/ { flush(); emit($0); next }
        {
            if (inblk) {
                buf = buf $0 "\n"
                if ($0 ~ ("^listen = \"[^\"]*:" p "\"$")) hit = 1
            } else {
                emit($0)
            }
        }
        END { flush() }
    ' "$CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; echo -e "${RED}错误: 处理配置后为空，已中止${PLAIN}"; return 1; }
    mv "$tmp" "$CONFIG_FILE"
}

# 删除文件尾部空行（busybox 下无 tac，用 awk）
cli_trim_trailing_blanks() {
    local tmp
    tmp=$(mktemp) || return 1
    awk '
        { lines[NR] = $0 }
        END {
            last = NR
            while (last > 0 && lines[last] == "") last--
            for (i = 1; i <= last; i++) print lines[i]
        }
    ' "$CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$CONFIG_FILE"
}

cli_validate_listen_addr() {
    local addr=$1
    if [[ "$addr" == *:* ]] && [[ ! "$addr" =~ ^\[[0-9a-fA-F:]+\]$ ]]; then
        echo -e "${RED}错误: --listen-addr 只能是 IP 或 [IPv6]，不能包含端口: $addr${PLAIN}"
        return 1
    fi
    validate_ip "$addr"
}

run_cli() {
    local listen_addr="[::]"
    local do_restart=1
    local -a specs=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --set-forward)
                [ -z "${2:-}" ] && { echo -e "${RED}错误: --set-forward 需要一个参数${PLAIN}"; return 1; }
                specs+=("$2"); shift 2 ;;
            --set-forward=*)
                specs+=("${1#*=}"); shift ;;
            --listen-addr)
                [ -z "${2:-}" ] && { echo -e "${RED}错误: --listen-addr 需要一个参数${PLAIN}"; return 1; }
                listen_addr="$2"; shift 2 ;;
            --listen-addr=*)
                listen_addr="${1#*=}"; shift ;;
            --no-restart)
                do_restart=0; shift ;;
            -h|--help)
                cli_usage; return 0 ;;
            *)
                echo -e "${RED}错误: 未知参数: $1${PLAIN}"
                cli_usage
                return 1 ;;
        esac
    done

    if [ ${#specs[@]} -eq 0 ]; then
        echo -e "${RED}错误: 缺少 --set-forward 参数${PLAIN}"
        cli_usage
        return 1
    fi

    cli_validate_listen_addr "$listen_addr" || return 1

    # 第一遍：全部解析校验通过后才落盘，避免半途失败留下残缺配置
    # 注意: validate_port / validate_ip 内部也用 [[ =~ ]]，会覆盖 BASH_REMATCH，
    # 因此必须先把捕获组存入局部变量再校验。
    local -a lp_arr=() rip_arr=() rp_arr=()
    local spec lp rip rp
    for spec in "${specs[@]}"; do
        if [[ ! "$spec" =~ ^([0-9]+):(\[[0-9a-fA-F:]+\]|[^:]+):([0-9]+)$ ]]; then
            echo -e "${RED}错误: 规则格式无效: $spec${PLAIN}"
            echo "  应为 <本机端口>:<远程IP或域名>:<远程端口>，例: 443:1.2.3.4:8443"
            return 1
        fi
        lp="${BASH_REMATCH[1]}"
        rip="${BASH_REMATCH[2]}"
        rp="${BASH_REMATCH[3]}"
        validate_port "$lp" || return 1
        validate_port "$rp" || return 1
        validate_ip "$rip" || return 1
        lp_arr+=("$lp")
        rip_arr+=("$rip")
        rp_arr+=("$rp")
    done

    init_env

    # 第二遍：应用规则（幂等：相同则跳过，不同则替换）
    local i remote existing
    for i in "${!lp_arr[@]}"; do
        remote="${rip_arr[$i]}:${rp_arr[$i]}"
        existing=$(cli_get_remote "${lp_arr[$i]}")

        if [ "$existing" = "$remote" ]; then
            echo -e "${GREEN}规则已存在，跳过: ${listen_addr}:${lp_arr[$i]} -> ${remote}${PLAIN}"
            continue
        fi

        if [ -n "$existing" ]; then
            echo -e "${YELLOW}替换规则: ${listen_addr}:${lp_arr[$i]} -> ${remote}（原 ${existing}）${PLAIN}"
            cli_remove_endpoint "${lp_arr[$i]}" || { echo -e "${RED}错误: 更新配置失败${PLAIN}"; return 1; }
        else
            echo -e "${GREEN}添加规则: ${listen_addr}:${lp_arr[$i]} -> ${remote}${PLAIN}"
        fi

        # 去掉尾部空行后统一以 "\n[[endpoints]]" 追加，保证段间恰好一个空行
        cli_trim_trailing_blanks || { echo -e "${RED}错误: 写入配置失败${PLAIN}"; return 1; }
        printf '\n[[endpoints]]\nlisten = "%s:%s"\nremote = "%s:%s"\n' \
            "$listen_addr" "${lp_arr[$i]}" "${rip_arr[$i]}" "${rp_arr[$i]}" >> "$CONFIG_FILE" \
            || { echo -e "${RED}错误: 写入配置失败${PLAIN}"; return 1; }
    done

    if [ "$do_restart" -eq 0 ]; then
        echo -e "${YELLOW}已跳过服务启用/重启（--no-restart）${PLAIN}"
        return 0
    fi

    if [ ! -x "$REALM_BIN" ]; then
        echo -e "${YELLOW}未检测到 realm 二进制，先执行安装...${PLAIN}"
        install_realm || return 1
    else
        service_enable realm
        service_restart realm
    fi

    if service_is_active realm; then
        echo -e "${GREEN}服务已启用并重启${PLAIN}"
        return 0
    fi

    echo -e "${RED}服务未运行，请检查: rc-service realm status${PLAIN}"
    return 1
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

# 有参数时走非交互式命令行模式，无参数时保持原有交互菜单行为
if [ "${REALM_TESTING:-0}" != "1" ]; then
    if [ $# -gt 0 ]; then
        run_cli "$@"
        exit $?
    fi
    main
fi
