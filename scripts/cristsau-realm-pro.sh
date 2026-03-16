#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob
LC_ALL=C

VERSION="v1.0"
APP_NAME="cristsau"
DISPLAY_NAME="cristsau一键转发管理脚本"
REALM_BIN="/usr/local/bin/realm"
REALM_ROOT="/etc/realm"
REALM_CONFIG_DIR="${REALM_ROOT}/config"
REALM_BASE_CONFIG="${REALM_CONFIG_DIR}/00-base.toml"
REALM_ENDPOINT_CONFIG_DIR="${REALM_CONFIG_DIR}/endpoints"
REALM_STATE_DIR="${REALM_ROOT}/state/endpoints"
REALM_SNAPSHOT="${REALM_ROOT}/rendered-config.toml"

REALM_SERVICE_NAME="realm-forward.service"
REALM_SERVICE_FILE="/etc/systemd/system/${REALM_SERVICE_NAME}"

BACKUP_DIR="/root/.cristsau-realm-backups"
SYSCTL_FILE="/etc/sysctl.d/99-cristsau-realm-forward.conf"
SHARE_DIR="${REALM_ROOT}/share"
DEFAULT_COMMAND_NAME="cristsau"

WATCH_SCRIPT="/usr/local/bin/realm-forward-watch.sh"
WATCH_SERVICE_NAME="realm-forward-watch.service"
WATCH_SERVICE_FILE="/etc/systemd/system/${WATCH_SERVICE_NAME}"
WATCH_TIMER_NAME="realm-forward-watch.timer"
WATCH_TIMER_FILE="/etc/systemd/system/${WATCH_TIMER_NAME}"

LOCK_FILE="/run/lock/${APP_NAME}.lock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

TEMP_PATHS=()

cleanup() {
    local path
    for path in "${TEMP_PATHS[@]:-}"; do
        [ -e "$path" ] && rm -rf "$path"
    done
}

trap cleanup EXIT

msg() {
    local color="$1"
    shift
    printf '%b%s%b\n' "$color" "$*" "$NC"
}

die() {
    msg "$RED" "$*"
    exit 1
}

pause() {
    read -r -p "Press Enter to continue..."
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

mktemp_file() {
    local path
    path="$(mktemp)"
    TEMP_PATHS+=("$path")
    printf '%s' "$path"
}

mktemp_dir() {
    local path
    path="$(mktemp -d)"
    TEMP_PATHS+=("$path")
    printf '%s' "$path"
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "root privileges are required"
    fi
}

need_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another ${APP_NAME} process is already running"
}

validate_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_timeout() {
    [ -z "${1:-}" ] || [[ "$1" =~ ^[0-9]+$ ]]
}

validate_host() {
    local host="${1:-}"
    [ -n "$host" ] || return 1
    [[ "$host" != *[[:space:]]* ]] || return 1
    [[ "$host" != *\"* ]] || return 1
    [[ "$host" != *\'* ]] || return 1
    [[ "$host" != *\\* ]] || return 1
}

validate_socket_literal() {
    normalize_socket_literal "${1:-}" >/dev/null
}

validate_protocol() {
    [[ "${1:-}" =~ ^(all|tcp|udp)$ ]]
}

validate_csv_remotes() {
    local csv="${1:-}"
    local item
    [ -z "$csv" ] && return 0
    IFS=',' read -r -a items <<< "$csv"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [ -z "$item" ] && continue
        normalize_socket_literal "$item" >/dev/null || return 1
    done
}

strip_ipv6_brackets() {
    local host="${1:-}"
    host="${host#[}"
    host="${host%]}"
    printf '%s' "$host"
}

is_ipv6_host() {
    local host
    host="$(strip_ipv6_brackets "${1:-}")"
    [[ "$host" == *:* ]]
}

format_socket_address() {
    local host port clean_host
    host="${1:-}"
    port="${2:-}"
    clean_host="$(strip_ipv6_brackets "$host")"
    if is_ipv6_host "$clean_host"; then
        printf '[%s]:%s' "$clean_host" "$port"
    else
        printf '%s:%s' "$clean_host" "$port"
    fi
}

normalize_socket_literal() {
    local value host port
    value="$(trim "${1:-}")"
    [ -n "$value" ] || return 1

    if [[ "$value" == \[*\]:* ]]; then
        host="${value#\[}"
        host="${host%%\]:*}"
        port="${value##*:}"
    else
        host="${value%:*}"
        port="${value##*:}"
    fi

    validate_host "$host" || return 1
    validate_port "$port" || return 1
    format_socket_address "$host" "$port"
}

state_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

state_unescape() {
    printf '%b' "${1:-}"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_any_cmd() {
    local cmd
    for cmd in "$@"; do
        if have_cmd "$cmd"; then
            return 0
        fi
    done
    die "missing required command; need one of: $*"
}

ensure_layout() {
    mkdir -p "$REALM_CONFIG_DIR" "$REALM_ENDPOINT_CONFIG_DIR" "$REALM_STATE_DIR" "$BACKUP_DIR"
}

write_atomic_file() {
    local target="$1"
    local tmp
    tmp="$(mktemp_file)"
    cat > "$tmp"
    install -d "$(dirname "$target")"
    mv "$tmp" "$target"
}

ensure_kernel_tuning() {
    write_atomic_file "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
}

ensure_base_config() {
    ensure_layout
    write_atomic_file "$REALM_BASE_CONFIG" <<'EOF'
[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = true
tcp_timeout = 5
udp_timeout = 30
tcp_keepalive = 15
tcp_keepalive_probe = 3
EOF
}

ensure_service_file() {
    write_atomic_file "$REALM_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Forward Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG_DIR}/
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

detect_arch_file() {
    case "$(uname -m)" in
        x86_64) printf '%s' "realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64|arm64) printf '%s' "realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *)
            return 1
            ;;
    esac
}

download_cmd() {
    if command -v curl >/dev/null 2>&1; then
        printf '%s' "curl"
    elif command -v wget >/dev/null 2>&1; then
        printf '%s' "wget"
    else
        return 1
    fi
}

fetch_latest_tag() {
    local downloader
    downloader="$(download_cmd)" || return 1
    if [ "$downloader" = "curl" ]; then
        curl -fsSL "https://api.github.com/repos/zhboner/realm/releases/latest" \
            | grep -m1 '"tag_name"' \
            | cut -d '"' -f 4
    else
        wget -qO- "https://api.github.com/repos/zhboner/realm/releases/latest" \
            | grep -m1 '"tag_name"' \
            | cut -d '"' -f 4
    fi
}

fetch_latest_realm_url() {
    local file downloader
    file="$(detect_arch_file)" || return 1
    downloader="$(download_cmd)" || return 1
    if [ "$downloader" = "curl" ]; then
        curl -fsSL "https://api.github.com/repos/zhboner/realm/releases/latest" \
            | grep "browser_download_url.*${file}" \
            | head -n 1 \
            | cut -d '"' -f 4
    else
        wget -qO- "https://api.github.com/repos/zhboner/realm/releases/latest" \
            | grep "browser_download_url.*${file}" \
            | head -n 1 \
            | cut -d '"' -f 4
    fi
}

installed_realm_version() {
    [ -x "$REALM_BIN" ] || return 1
    "$REALM_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

resolve_self_path() {
    readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0"
}

validate_command_name() {
    printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._-]+$'
}

install_launch_command() {
    local self_path target_name install_mode target_path answer

    self_path="$(resolve_self_path)"
    [ -f "$self_path" ] || die "unable to resolve current script path"

    read -r -p "Command name [${DEFAULT_COMMAND_NAME}]: " target_name
    target_name="${target_name:-$DEFAULT_COMMAND_NAME}"
    validate_command_name "$target_name" || die "command name can only contain letters, digits, dot, underscore, and dash"

    echo "1) Symlink (recommended)"
    echo "2) Copy"
    read -r -p "Install mode [1]: " install_mode
    install_mode="${install_mode:-1}"

    target_path="/usr/local/bin/${target_name}"
    if [ -e "$target_path" ] || [ -L "$target_path" ]; then
        read -r -p "${target_path} already exists. Overwrite? [y/N]: " answer
        [[ "${answer:-N}" =~ ^[Yy]$ ]] || return 0
        rm -f "$target_path"
    fi

    chmod 0755 "$self_path"
    case "$install_mode" in
        1) ln -s "$self_path" "$target_path" ;;
        2) install -m 0755 "$self_path" "$target_path" ;;
        *) die "invalid install mode" ;;
    esac

    msg "$GREEN" "launch command installed: ${target_name}"
    msg "$CYAN" "you can start the menu with: ${target_name}"
}

remove_launch_command() {
    local target_name target_path answer

    read -r -p "Command name to remove [${DEFAULT_COMMAND_NAME}]: " target_name
    target_name="${target_name:-$DEFAULT_COMMAND_NAME}"
    validate_command_name "$target_name" || die "command name is invalid"

    target_path="/usr/local/bin/${target_name}"
    [ -e "$target_path" ] || [ -L "$target_path" ] || die "command not found: ${target_path}"

    read -r -p "Remove ${target_path}? [y/N]: " answer
    [[ "${answer:-N}" =~ ^[Yy]$ ]] || return 0
    rm -f "$target_path"
    msg "$GREEN" "launch command removed: ${target_name}"
}

launch_command_menu() {
    echo "1) Install or update launch command"
    echo "2) Remove launch command"
    read -r -p "Select [1]: " action
    action="${action:-1}"
    case "$action" in
        1) install_launch_command ;;
        2) remove_launch_command ;;
        *) msg "$RED" "invalid selection" ;;
    esac
}

install_or_update_realm() {
    local file downloader url latest_tag current_version tmp_dir archive extracted installed_version

    file="$(detect_arch_file)" || die "unsupported architecture: $(uname -m)"
    downloader="$(download_cmd)" || die "curl or wget is required to download realm"
    need_cmd tar

    latest_tag="$(fetch_latest_tag || true)"
    current_version="$(installed_realm_version || true)"
    if [ -n "$latest_tag" ] && [ -n "$current_version" ] && [ "${latest_tag#v}" = "$current_version" ]; then
        msg "$GREEN" "realm is already up to date (${current_version})"
        return 0
    fi

    url="$(fetch_latest_realm_url || true)"
    if [ -z "$url" ]; then
        url="https://github.com/zhboner/realm/releases/latest/download/${file}"
    fi

    tmp_dir="$(mktemp_dir)"
    archive="${tmp_dir}/${file}"

    msg "$YELLOW" "downloading realm from ${url}"
    if [ "$downloader" = "curl" ]; then
        curl -fL "$url" -o "$archive" >/dev/null
    else
        wget -qO "$archive" "$url"
    fi

    tar -xzf "$archive" -C "$tmp_dir"
    extracted="$(find "$tmp_dir" -maxdepth 2 -type f -name realm | head -n 1)"
    [ -n "$extracted" ] || die "realm binary was not found in the downloaded archive"

    install -m 0755 "$extracted" "$REALM_BIN"

    installed_version="$(installed_realm_version || true)"
    if [ -z "$installed_version" ]; then
        die "realm was installed but version verification failed"
    fi

    msg "$GREEN" "realm installed successfully (${installed_version})"
}

endpoint_state_file() {
    printf '%s/%s.env' "$REALM_STATE_DIR" "$1"
}

endpoint_fragment_file() {
    printf '%s/%s.toml' "$REALM_ENDPOINT_CONFIG_DIR" "$1"
}

list_state_files() {
    find "$REALM_STATE_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null | sort -V
}

has_endpoints() {
    list_state_files | grep -q .
}

load_state_file() {
    local file="$1"
    local line key value

    unset LOCAL_PORT REMOTE_HOST REMOTE_PORT PROTOCOL DESCRIPTION THROUGH INTERFACE_NAME
    unset LISTEN_INTERFACE EXTRA_REMOTES BALANCE TCP_TIMEOUT UDP_TIMEOUT

    [ -f "$file" ] || die "state file not found: $file"

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || die "invalid state file line in ${file}: ${line}"

        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            LOCAL_PORT|REMOTE_HOST|REMOTE_PORT|PROTOCOL|DESCRIPTION|THROUGH|INTERFACE_NAME|LISTEN_INTERFACE|EXTRA_REMOTES|BALANCE|TCP_TIMEOUT|UDP_TIMEOUT)
                printf -v "$key" '%s' "$(state_unescape "$value")"
                ;;
            *)
                die "unsupported key in state file ${file}: ${key}"
                ;;
        esac
    done < "$file"

    validate_port "${LOCAL_PORT:-}" || die "invalid LOCAL_PORT in ${file}"
    validate_host "${REMOTE_HOST:-}" || die "invalid REMOTE_HOST in ${file}"
    validate_port "${REMOTE_PORT:-}" || die "invalid REMOTE_PORT in ${file}"
    validate_protocol "${PROTOCOL:-}" || die "invalid PROTOCOL in ${file}"
    validate_csv_remotes "${EXTRA_REMOTES:-}" || die "invalid EXTRA_REMOTES in ${file}"
    [ -z "${THROUGH:-}" ] || validate_host "$THROUGH" || die "invalid THROUGH in ${file}"
    [ -z "${INTERFACE_NAME:-}" ] || validate_host "$INTERFACE_NAME" || die "invalid INTERFACE_NAME in ${file}"
    [ -z "${LISTEN_INTERFACE:-}" ] || validate_host "$LISTEN_INTERFACE" || die "invalid LISTEN_INTERFACE in ${file}"
    validate_timeout "${TCP_TIMEOUT:-}" || die "invalid TCP_TIMEOUT in ${file}"
    validate_timeout "${UDP_TIMEOUT:-}" || die "invalid UDP_TIMEOUT in ${file}"
}

save_state_file() {
    local file="$1"
    local tmp
    tmp="$(mktemp_file)"
    {
        printf 'LOCAL_PORT=%s\n' "$(state_escape "$LOCAL_PORT")"
        printf 'REMOTE_HOST=%s\n' "$(state_escape "$REMOTE_HOST")"
        printf 'REMOTE_PORT=%s\n' "$(state_escape "$REMOTE_PORT")"
        printf 'PROTOCOL=%s\n' "$(state_escape "$PROTOCOL")"
        printf 'DESCRIPTION=%s\n' "$(state_escape "${DESCRIPTION:-}")"
        printf 'THROUGH=%s\n' "$(state_escape "${THROUGH:-}")"
        printf 'INTERFACE_NAME=%s\n' "$(state_escape "${INTERFACE_NAME:-}")"
        printf 'LISTEN_INTERFACE=%s\n' "$(state_escape "${LISTEN_INTERFACE:-}")"
        printf 'EXTRA_REMOTES=%s\n' "$(state_escape "${EXTRA_REMOTES:-}")"
        printf 'BALANCE=%s\n' "$(state_escape "${BALANCE:-}")"
        printf 'TCP_TIMEOUT=%s\n' "$(state_escape "${TCP_TIMEOUT:-}")"
        printf 'UDP_TIMEOUT=%s\n' "$(state_escape "${UDP_TIMEOUT:-}")"
    } > "$tmp"
    mv "$tmp" "$file"
}

endpoint_exists() {
    [ -f "$(endpoint_state_file "$1")" ]
}

local_port_in_config() {
    endpoint_exists "$1"
}

port_in_use_by_system() {
    local port="$1"
    ss -ltnuH "( sport = :${port} )" 2>/dev/null | grep -q .
}

normalize_extra_remotes() {
    local csv="${1:-}"
    local item
    local output=()
    [ -z "$csv" ] && return 0
    IFS=',' read -r -a items <<< "$csv"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [ -n "$item" ] && output+=("$(normalize_socket_literal "$item")")
    done
    printf '%s\n' "${output[@]}"
}

render_endpoint_fragment() {
    local state_file="$1"
    local fragment_dir="$2"
    local fragment_file tmp
    local idx
    local network_parts=()
    local extra_remote
    local first=true

    load_state_file "$state_file"
    install -d "$fragment_dir"
    fragment_file="${fragment_dir}/${LOCAL_PORT}.toml"
    tmp="$(mktemp_file)"

    case "$PROTOCOL" in
        tcp) network_parts+=("use_udp = false") ;;
        udp)
            network_parts+=("no_tcp = true")
            network_parts+=("use_udp = true")
            ;;
    esac
    [ -n "${TCP_TIMEOUT:-}" ] && network_parts+=("tcp_timeout = ${TCP_TIMEOUT}")
    [ -n "${UDP_TIMEOUT:-}" ] && network_parts+=("udp_timeout = ${UDP_TIMEOUT}")

    {
        printf '[[endpoints]]\n'
        printf 'listen = "0.0.0.0:%s"\n' "$(toml_escape "$LOCAL_PORT")"
        printf 'remote = "%s"\n' "$(toml_escape "$(format_socket_address "$REMOTE_HOST" "$REMOTE_PORT")")"

        if [ -n "${THROUGH:-}" ]; then
            printf 'through = "%s"\n' "$(toml_escape "$THROUGH")"
        fi
        if [ -n "${INTERFACE_NAME:-}" ]; then
            printf 'interface = "%s"\n' "$(toml_escape "$INTERFACE_NAME")"
        fi
        if [ -n "${LISTEN_INTERFACE:-}" ]; then
            printf 'listen_interface = "%s"\n' "$(toml_escape "$LISTEN_INTERFACE")"
        fi
        if [ -n "${EXTRA_REMOTES:-}" ]; then
            printf 'extra_remotes = ['
            while IFS= read -r extra_remote; do
                [ -z "$extra_remote" ] && continue
                if [ "$first" = true ]; then
                    first=false
                else
                    printf ', '
                fi
                printf '"%s"' "$(toml_escape "$extra_remote")"
            done < <(normalize_extra_remotes "$EXTRA_REMOTES")
            printf ']\n'
        fi
        if [ -n "${BALANCE:-}" ]; then
            printf 'balance = "%s"\n' "$(toml_escape "$BALANCE")"
        fi
        if [ "${#network_parts[@]}" -gt 0 ]; then
            printf 'network = { '
            printf '%s' "${network_parts[0]}"
            for ((idx = 1; idx < ${#network_parts[@]}; idx++)); do
                printf ', %s' "${network_parts[idx]}"
            done
            printf ' }\n'
        fi
        printf '\n'
    } > "$tmp"

    mv "$tmp" "$fragment_file"
}

render_snapshot() {
    local base_config="$1"
    local fragment_dir="$2"
    local snapshot_file="$3"
    local tmp fragment
    tmp="$(mktemp_file)"
    cat "$base_config" > "$tmp"
    printf '\n' >> "$tmp"
    for fragment in "$fragment_dir"/*.toml; do
        [ -e "$fragment" ] || continue
        cat "$fragment" >> "$tmp"
    done
    mv "$tmp" "$snapshot_file"
}

render_all_endpoints() {
    local base_config="$1"
    local fragment_dir="$2"
    local snapshot_file="$3"
    local state_file

    rm -f "$fragment_dir"/*.toml
    while IFS= read -r state_file; do
        [ -n "$state_file" ] || continue
        render_endpoint_fragment "$state_file" "$fragment_dir"
    done < <(list_state_files)

    render_snapshot "$base_config" "$fragment_dir" "$snapshot_file"
}

validate_rendered_config() {
    local snapshot_file="$1"

    if have_cmd python3; then
        python3 - "$snapshot_file" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit(0)

path = sys.argv[1]
with open(path, "rb") as fh:
    tomllib.load(fh)
PY
        return $?
    fi

    if have_cmd python; then
        python - "$snapshot_file" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit(0)

path = sys.argv[1]
with open(path, "rb") as fh:
    tomllib.load(fh)
PY
        return $?
    fi

    msg "$YELLOW" "python tomllib not available; skipping TOML syntax validation"
    return 0
}

service_is_active() {
    systemctl is-active --quiet "$REALM_SERVICE_NAME"
}

apply_runtime_state() {
    local stage_root stage_config_dir stage_endpoint_dir stage_snapshot

    ensure_kernel_tuning
    ensure_base_config
    ensure_service_file

    stage_root="$(mktemp_dir)"
    stage_config_dir="${stage_root}/config"
    stage_endpoint_dir="${stage_config_dir}/endpoints"
    stage_snapshot="${stage_root}/rendered-config.toml"
    install -d "$stage_endpoint_dir"
    cp "$REALM_BASE_CONFIG" "${stage_config_dir}/00-base.toml"

    render_all_endpoints "${stage_config_dir}/00-base.toml" "$stage_endpoint_dir" "$stage_snapshot"
    if ! validate_rendered_config "$stage_snapshot"; then
        msg "$RED" "generated configuration failed validation; runtime files were not changed"
        return 1
    fi

    install -d "$REALM_CONFIG_DIR" "$REALM_ENDPOINT_CONFIG_DIR"
    cp "${stage_config_dir}/00-base.toml" "$REALM_BASE_CONFIG"
    rm -f "$REALM_ENDPOINT_CONFIG_DIR"/*.toml
    if compgen -G "${stage_endpoint_dir}/*.toml" >/dev/null; then
        cp "${stage_endpoint_dir}/"*.toml "$REALM_ENDPOINT_CONFIG_DIR/"
    fi
    cp "$stage_snapshot" "$REALM_SNAPSHOT"

    if ! has_endpoints; then
        systemctl disable --now "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
        msg "$YELLOW" "no endpoints configured; service has been stopped"
        return 0
    fi

    systemctl enable "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    if systemctl restart "$REALM_SERVICE_NAME"; then
        sleep 1
        if service_is_active; then
            msg "$GREEN" "realm service is active"
            return 0
        fi
    fi

    msg "$RED" "realm service failed to start; recent logs:"
    if have_cmd journalctl; then
        journalctl -u "$REALM_SERVICE_NAME" --no-pager -n 50 || true
    fi
    return 1
}

validate_endpoint_options() {
    validate_host "$REMOTE_HOST" || die "remote host is invalid"
    validate_port "$REMOTE_PORT" || die "remote port is invalid"
    validate_port "$LOCAL_PORT" || die "listen port is invalid"
    validate_protocol "$PROTOCOL" || die "protocol must be all, tcp, or udp"
    validate_csv_remotes "${EXTRA_REMOTES:-}" || die "extra remotes must be a comma-separated host:port list"
    [ -z "${THROUGH:-}" ] || validate_host "$THROUGH" || die "through address is invalid"
    [ -z "${INTERFACE_NAME:-}" ] || validate_host "$INTERFACE_NAME" || die "interface is invalid"
    [ -z "${LISTEN_INTERFACE:-}" ] || validate_host "$LISTEN_INTERFACE" || die "listen interface is invalid"
    validate_timeout "${TCP_TIMEOUT:-}" || die "tcp timeout must be empty or numeric"
    validate_timeout "${UDP_TIMEOUT:-}" || die "udp timeout must be empty or numeric"
    [ -z "${BALANCE:-}" ] || validate_host "$BALANCE" || die "balance string contains unsupported characters"
}

add_endpoint() {
    validate_endpoint_options

    if local_port_in_config "$LOCAL_PORT"; then
        die "listen port ${LOCAL_PORT} already exists"
    fi
    if port_in_use_by_system "$LOCAL_PORT"; then
        die "listen port ${LOCAL_PORT} is already used by another process"
    fi
    [ -x "$REALM_BIN" ] || install_or_update_realm

    save_state_file "$(endpoint_state_file "$LOCAL_PORT")"
    apply_runtime_state
    msg "$GREEN" "endpoint ${LOCAL_PORT} -> $(format_socket_address "$REMOTE_HOST" "$REMOTE_PORT") added"
}

remove_endpoint() {
    local local_port="$1"
    validate_port "$local_port" || die "listen port is invalid"
    endpoint_exists "$local_port" || die "listen port ${local_port} was not found"
    rm -f "$(endpoint_state_file "$local_port")" "$(endpoint_fragment_file "$local_port")"
    apply_runtime_state
    msg "$GREEN" "endpoint ${local_port} removed"
}

list_endpoints() {
    local state_file status desc
    if ! has_endpoints; then
        msg "$DIM" "no endpoints configured"
        return 0
    fi

    printf '%-10s %-8s %-28s %-10s %s\n' "PORT" "PROTO" "REMOTE" "STATUS" "DESCRIPTION"
    printf '%-10s %-8s %-28s %-10s %s\n' "----------" "--------" "----------------------------" "----------" "-----------"
    while IFS= read -r state_file; do
        [ -n "$state_file" ] || continue
        load_state_file "$state_file"
        if port_in_use_by_system "$LOCAL_PORT"; then
            status="listening"
        else
            status="stopped"
        fi
        desc="${DESCRIPTION:-"-"}"
        printf '%-10s %-8s %-28s %-10s %s\n' \
            "$LOCAL_PORT" "$PROTOCOL" "$(format_socket_address "$REMOTE_HOST" "$REMOTE_PORT")" "$status" "$desc"
    done < <(list_state_files)
}

probe_ping() {
    local host="$1"
    local ping_host="$host"
    have_cmd ping || return 2
    ping_host="${ping_host#[}"
    ping_host="${ping_host%]}"
    ping -c 1 -W 1 "$ping_host" 2>/dev/null | awk -F'/' '/min\/avg\/max/ {print $5}' | cut -d. -f1
}

probe_tcp() {
    local host="$1"
    local port="$2"
    local probe_host="$host"
    probe_host="${probe_host#[}"
    probe_host="${probe_host%]}"

    if have_cmd nc; then
        if is_ipv6_host "$probe_host"; then
            nc -6 -z -w 2 "$probe_host" "$port" >/dev/null 2>&1
        else
            nc -4 -z -w 2 "$probe_host" "$port" >/dev/null 2>&1
        fi
        return $?
    fi

    have_cmd timeout || return 2
    if is_ipv6_host "$probe_host"; then
        return 2
    fi
    timeout 2 bash -c 'exec 3<>/dev/tcp/$1/$2' bash "$probe_host" "$port" >/dev/null 2>&1
}

show_health() {
    local state_file ping_ms local_state remote_state remote_label

    echo -e "${CYAN}${BOLD}Service${NC}"
    systemctl --no-pager --full status "$REALM_SERVICE_NAME" 2>/dev/null | sed -n '1,12p' || true
    echo

    echo -e "${CYAN}${BOLD}Listening sockets${NC}"
    ss -ltnup 2>/dev/null | grep -F "realm" || msg "$DIM" "no listening sockets found"
    echo

    echo -e "${CYAN}${BOLD}Endpoint probes${NC}"
    if ! has_endpoints; then
        msg "$DIM" "no endpoints configured"
        return 0
    fi

    printf '%-10s %-28s %-12s %-12s %s\n' "PORT" "REMOTE" "LOCAL" "REMOTE" "PING"
    while IFS= read -r state_file; do
        [ -n "$state_file" ] || continue
        load_state_file "$state_file"

        if port_in_use_by_system "$LOCAL_PORT"; then
            local_state="listening"
        else
            local_state="closed"
        fi

        if probe_tcp "$REMOTE_HOST" "$REMOTE_PORT"; then
            remote_state="tcp-ok"
        else
            case $? in
                2) remote_state="n/a" ;;
                *) remote_state="tcp-fail" ;;
            esac
        fi

        ping_ms="$(probe_ping "$REMOTE_HOST" || true)"
        [ -n "${ping_ms:-}" ] || ping_ms="n/a"
        remote_label="$(format_socket_address "$REMOTE_HOST" "$REMOTE_PORT")"
        printf '%-10s %-28s %-12s %-12s %s\n' \
            "$LOCAL_PORT" "$remote_label" "$local_state" "$remote_state" "$ping_ms"
    done < <(list_state_files)
}

show_recent_logs() {
    need_cmd journalctl
    journalctl -u "$REALM_SERVICE_NAME" --no-pager -n 100
}

edit_base_config() {
    local editor="${EDITOR:-vi}"
    local tmp_base tmp_root tmp_config_dir tmp_endpoint_dir tmp_snapshot
    ensure_base_config

    tmp_base="$(mktemp_file)"
    cp "$REALM_BASE_CONFIG" "$tmp_base"
    "$editor" "$tmp_base"

    tmp_root="$(mktemp_dir)"
    tmp_config_dir="${tmp_root}/config"
    tmp_endpoint_dir="${tmp_config_dir}/endpoints"
    tmp_snapshot="${tmp_root}/rendered-config.toml"
    install -d "$tmp_endpoint_dir"
    cp "$tmp_base" "${tmp_config_dir}/00-base.toml"
    render_all_endpoints "${tmp_config_dir}/00-base.toml" "$tmp_endpoint_dir" "$tmp_snapshot"
    validate_rendered_config "$tmp_snapshot" || die "base config validation failed; changes were not applied"

    cp "$tmp_base" "$REALM_BASE_CONFIG"
    apply_runtime_state
}

edit_endpoint_state() {
    local local_port="$1"
    local editor="${EDITOR:-vi}"
    local original_file tmp_file
    endpoint_exists "$local_port" || die "listen port ${local_port} was not found"
    original_file="$(endpoint_state_file "$local_port")"
    tmp_file="$(mktemp_file)"
    cp "$original_file" "$tmp_file"
    "$editor" "$tmp_file"
    load_state_file "$tmp_file" >/dev/null
    mv "$tmp_file" "$original_file"
    apply_runtime_state
}

uri_encode() {
    local input="$1"
    local output=""
    local i char hex
    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) output+="$char" ;;
            *)
                printf -v hex '%%%02X' "'$char"
                output+="$hex"
                ;;
        esac
    done
    printf '%s' "$output"
}

base64_url_nopad() {
    need_cmd base64
    printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

save_share_result() {
    local uri="$1"
    mkdir -p "$SHARE_DIR"
    printf '%s\n' "$uri" > "${SHARE_DIR}/last-share.txt"
}

show_share_result() {
    local uri="$1"
    echo
    echo "Import link:"
    printf '%s\n' "$uri"
    save_share_result "$uri"
    echo
    if command -v qrencode >/dev/null 2>&1; then
        echo "QR code:"
        qrencode -t ANSIUTF8 "$uri"
    else
        msg "$YELLOW" "qrencode is not installed; link saved to ${SHARE_DIR}/last-share.txt"
    fi
}

read_pasted_blob() {
    local line
    local blob=""
    echo "Paste text or URI below. End input with a single EOF line."
    while IFS= read -r line; do
        [ "$line" = "EOF" ] && break
        blob+="${line}"$'\n'
    done
    printf '%s' "$blob"
}

extract_first_proxy_uri() {
    printf '%s' "$1" \
        | tr -d '\r' \
        | grep -Eo '(ss|vless|vmess|trojan)://[^[:space:]]+' \
        | sed 's/[),.;]+$//' \
        | head -n 1
}

extract_labeled_value() {
    local text="$1"
    local label_re="$2"
    printf '%s\n' "$text" | awk -v IGNORECASE=1 -v re="$label_re" '
        $0 ~ re {
            line=$0
            sub(/^[^:：]*[:：][[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    '
}

detect_host_like() {
    printf '%s' "$1" \
        | grep -Eo '([A-Za-z0-9-]+\.)+[A-Za-z]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | head -n 1
}

detect_port_like() {
    local text="$1"
    local port
    port="$(extract_labeled_value "$text" '^[[:space:]]*(Port|Listen Port|Remote Port|端口)[[:space:]]*[:：]')" || true
    if validate_port "${port:-}"; then
        printf '%s' "$port"
        return 0
    fi
    printf '%s' "$text" | grep -Eo ':[0-9]{2,5}' | tr -d ':' | head -n 1
}

detect_cipher_like() {
    printf '%s' "$1" | grep -Eio '2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305' | head -n 1
}

build_ss_uri() {
    local host="$1"
    local port="$2"
    local method="$3"
    local password="$4"
    local tag="${5:-}"
    local userinfo
    local uri

    validate_host "$host" || die "share host is invalid"
    validate_port "$port" || die "share port is invalid"
    [ -n "$method" ] || die "cipher is required"
    [ -n "$password" ] || die "password is required"

    userinfo="$(base64_url_nopad "${method}:${password}")"
    uri="ss://${userinfo}@${host}:${port}"
    if [ -n "$tag" ]; then
        uri="${uri}#$(uri_encode "$tag")"
    fi
    printf '%s' "$uri"
}

rewrite_userinfo_uri() {
    local uri="$1"
    local new_host="$2"
    local new_port="$3"
    local new_tag="$4"
    local scheme body fragment query creds rest hostport result

    scheme="${uri%%://*}"
    body="${uri#*://}"
    [ "$body" != "$uri" ] || {
        printf '%s' "$uri"
        return 0
    }

    fragment=""
    if [[ "$body" == *#* ]]; then
        fragment="${body#*#}"
        body="${body%%#*}"
    fi

    if [[ "$body" != *@* ]]; then
        printf '%s' "$uri"
        return 0
    fi

    creds="${body%%@*}"
    rest="${body#*@}"
    query=""
    if [[ "$rest" == *\?* ]]; then
        hostport="${rest%%\?*}"
        query="?${rest#*\?}"
    else
        hostport="$rest"
    fi

    if [ -n "$new_host" ] && [ -n "$new_port" ]; then
        hostport="${new_host}:${new_port}"
    fi

    result="${scheme}://${creds}@${hostport}${query}"
    if [ -n "$new_tag" ]; then
        result="${result}#$(uri_encode "$new_tag")"
    elif [ -n "$fragment" ]; then
        result="${result}#${fragment}"
    fi
    printf '%s' "$result"
}

share_from_detected_uri() {
    local uri="$1"
    local host_override="" port_override="" tag_override="" updated_uri

    echo "Detected URI:"
    printf '%s\n' "$uri"
    echo
    read -r -p "Override host (blank keeps original): " host_override
    read -r -p "Override port (blank keeps original): " port_override
    read -r -p "Override tag (blank keeps original): " tag_override

    if [ -n "$port_override" ] && ! validate_port "$port_override"; then
        die "override port is invalid"
    fi
    if [ -n "$host_override" ] && ! validate_host "$host_override"; then
        die "override host is invalid"
    fi
    if { [ -n "$host_override" ] && [ -z "$port_override" ]; } || { [ -z "$host_override" ] && [ -n "$port_override" ]; }; then
        die "host and port overrides must be provided together"
    fi

    updated_uri="$(rewrite_userinfo_uri "$uri" "$host_override" "$port_override" "$tag_override")"
    show_share_result "$updated_uri"
}

manual_ss_share_menu() {
    local host port method password tag
    read -r -p "Host: " host
    read -r -p "Port: " port
    read -r -p "Cipher/Method: " method
    read -r -p "Password: " password
    read -r -p "Tag (optional): " tag
    show_share_result "$(build_ss_uri "$host" "$port" "$method" "$password" "$tag")"
}

share_from_pasted_text() {
    local blob uri host port method password tag

    blob="$(read_pasted_blob)"
    [ -n "$blob" ] || die "no input provided"

    uri="$(extract_first_proxy_uri "$blob" || true)"
    if [ -n "$uri" ]; then
        share_from_detected_uri "$uri"
        return 0
    fi

    host="$(extract_labeled_value "$blob" '^[[:space:]]*(Public Host|Host|Address|Server|公网地址|地址|服务器|域名)[[:space:]]*[:：]')" || true
    [ -n "$host" ] || host="$(detect_host_like "$blob" || true)"

    port="$(detect_port_like "$blob" || true)"
    method="$(extract_labeled_value "$blob" '^[[:space:]]*(Method|Cipher|Encryption|Encrypt Method|加密方式|加密)[[:space:]]*[:：]')" || true
    [ -n "$method" ] || method="$(detect_cipher_like "$blob" || true)"

    password="$(extract_labeled_value "$blob" '^[[:space:]]*(Password|Passwd|Secret|密码)[[:space:]]*[:：]')" || true
    tag="$(extract_labeled_value "$blob" '^[[:space:]]*(Tag|Name|Node Name|备注|节点名)[[:space:]]*[:：]')" || true
    [ -n "$tag" ] || tag="${host:-imported-node}"

    echo "Detected SS fields. Press Enter to keep the detected value."
    read -r -p "Host [${host:-}]: " REPLY
    host="${REPLY:-$host}"
    read -r -p "Port [${port:-}]: " REPLY
    port="${REPLY:-$port}"
    read -r -p "Cipher [${method:-}]: " REPLY
    method="${REPLY:-$method}"
    read -r -p "Password [${password:-}]: " REPLY
    password="${REPLY:-$password}"
    read -r -p "Tag [${tag:-}]: " REPLY
    tag="${REPLY:-$tag}"

    show_share_result "$(build_ss_uri "$host" "$port" "$method" "$password" "$tag")"
}

node_share_menu() {
    echo "1) Paste node text or URI and auto-detect"
    echo "2) Build Shadowsocks link manually"
    read -r -p "Select [1]: " action
    action="${action:-1}"
    case "$action" in
        1) share_from_pasted_text ;;
        2) manual_ss_share_menu ;;
        *) msg "$RED" "invalid selection" ;;
    esac
}

create_backup() {
    local stamp dir
    stamp="$(date +%Y%m%d_%H%M%S)"
    dir="${BACKUP_DIR}/${stamp}"
    mkdir -p "$dir"

    [ -d "$REALM_ROOT" ] && cp -a "$REALM_ROOT" "$dir/realm"
    [ -f "$REALM_SERVICE_FILE" ] && cp "$REALM_SERVICE_FILE" "$dir/"
    [ -f "$WATCH_SERVICE_FILE" ] && cp "$WATCH_SERVICE_FILE" "$dir/"
    [ -f "$WATCH_TIMER_FILE" ] && cp "$WATCH_TIMER_FILE" "$dir/"
    [ -f "$WATCH_SCRIPT" ] && cp "$WATCH_SCRIPT" "$dir/"
    [ -f "$SYSCTL_FILE" ] && cp "$SYSCTL_FILE" "$dir/"
    [ -x "$REALM_BIN" ] && cp "$REALM_BIN" "$dir/realm.bin"

    msg "$GREEN" "backup created: ${dir}"
}

select_backup_dir() {
    local backups=()
    local idx dir

    mapfile -t backups < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
    [ "${#backups[@]}" -gt 0 ] || die "no backups available"

    echo -e "${CYAN}Available backups${NC}"
    idx=1
    for dir in "${backups[@]}"; do
        printf ' %d) %s\n' "$idx" "$dir"
        idx=$((idx + 1))
    done
    read -r -p "Select number: " idx
    [[ "$idx" =~ ^[0-9]+$ ]] || die "invalid selection"
    [ "$idx" -ge 1 ] && [ "$idx" -le "${#backups[@]}" ] || die "invalid selection"
    printf '%s' "${backups[$((idx - 1))]}"
}

restore_backup() {
    local dir="${1:-}"
    [ -n "$dir" ] || dir="$(select_backup_dir)"
    [ -d "$dir" ] || die "backup directory not found: ${dir}"

    create_backup >/dev/null

    rm -rf "$REALM_ROOT"
    mkdir -p "$REALM_ROOT"
    [ -d "$dir/realm" ] && cp -a "$dir/realm/." "$REALM_ROOT/"
    [ -f "$dir/${REALM_SERVICE_NAME}" ] && cp "$dir/${REALM_SERVICE_NAME}" "$REALM_SERVICE_FILE"
    [ -f "$dir/${WATCH_SERVICE_NAME}" ] && cp "$dir/${WATCH_SERVICE_NAME}" "$WATCH_SERVICE_FILE"
    [ -f "$dir/${WATCH_TIMER_NAME}" ] && cp "$dir/${WATCH_TIMER_NAME}" "$WATCH_TIMER_FILE"
    [ -f "$dir/$(basename "$WATCH_SCRIPT")" ] && cp "$dir/$(basename "$WATCH_SCRIPT")" "$WATCH_SCRIPT"
    [ -f "$dir/$(basename "$SYSCTL_FILE")" ] && cp "$dir/$(basename "$SYSCTL_FILE")" "$SYSCTL_FILE"
    [ -f "$dir/realm.bin" ] && install -m 0755 "$dir/realm.bin" "$REALM_BIN"

    chmod 0755 "$WATCH_SCRIPT" 2>/dev/null || true
    systemctl daemon-reload
    apply_runtime_state
    msg "$GREEN" "backup restored from ${dir}"
}

write_watchdog_files() {
    write_atomic_file "$WATCH_SCRIPT" <<EOF
#!/usr/bin/env bash
systemctl is-active --quiet ${REALM_SERVICE_NAME} || systemctl restart ${REALM_SERVICE_NAME}
EOF
    chmod 0755 "$WATCH_SCRIPT"

    write_atomic_file "$WATCH_SERVICE_FILE" <<EOF
[Unit]
Description=Realm service watchdog

[Service]
Type=oneshot
ExecStart=${WATCH_SCRIPT}
EOF

    write_atomic_file "$WATCH_TIMER_FILE" <<EOF
[Unit]
Description=Run Realm watchdog every minute

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Unit=${WATCH_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
}

enable_watchdog() {
    write_watchdog_files
    systemctl enable --now "$WATCH_TIMER_NAME"
    msg "$GREEN" "watchdog enabled"
}

disable_watchdog() {
    systemctl disable --now "$WATCH_TIMER_NAME" >/dev/null 2>&1 || true
    rm -f "$WATCH_SCRIPT" "$WATCH_SERVICE_FILE" "$WATCH_TIMER_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$WATCH_SERVICE_NAME" "$WATCH_TIMER_NAME" >/dev/null 2>&1 || true
    msg "$GREEN" "watchdog disabled"
}

service_actions() {
    echo "1) Start"
    echo "2) Stop"
    echo "3) Restart"
    echo "4) Status"
    read -r -p "Select: " action
    case "$action" in
        1)
            if has_endpoints; then
                systemctl enable --now "$REALM_SERVICE_NAME"
            else
                msg "$YELLOW" "no endpoints configured"
            fi
            ;;
        2) systemctl stop "$REALM_SERVICE_NAME" ;;
        3) apply_runtime_state ;;
        4) systemctl --no-pager --full status "$REALM_SERVICE_NAME" ;;
        *) msg "$RED" "invalid selection" ;;
    esac
}

uninstall_stack() {
    local answer
    read -r -p "Backup and uninstall the full Realm stack? [y/N]: " answer
    [[ "${answer:-N}" =~ ^[Yy]$ ]] || return 0

    create_backup
    disable_watchdog >/dev/null 2>&1 || true
    systemctl disable --now "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$REALM_SERVICE_FILE"
    rm -rf "$REALM_ROOT"
    rm -f "$REALM_BIN"
    systemctl daemon-reload
    msg "$GREEN" "Realm stack removed. Kernel tuning file kept at ${SYSCTL_FILE}"
}

show_menu() {
    clear
    echo -e "${BLUE}============================================================${NC}"
    echo -e " ${BOLD}${DISPLAY_NAME}${NC} ${VERSION}"
    echo -e "${BLUE}============================================================${NC}"
    if service_is_active; then
        echo -e " Service: ${GREEN}active${NC}"
    else
        echo -e " Service: ${RED}inactive${NC}"
    fi
    echo -e " Config dir: ${REALM_CONFIG_DIR}"
    echo -e "${BLUE}============================================================${NC}"
    echo " 1) Install or update Realm"
    echo " 2) List endpoints"
    echo " 3) Add endpoint"
    echo " 4) Remove endpoint"
    echo " 5) Edit one endpoint"
    echo " 6) Service actions"
    echo " 7) Health check"
    echo " 8) Show logs"
    echo " 9) Edit base config"
    echo "10) Backup"
    echo "11) Restore backup"
    echo "12) Enable watchdog"
    echo "13) Disable watchdog"
    echo "14) Install custom launch command"
    echo "15) Generate import link / QR"
    echo "16) Regenerate config and restart"
    echo "17) Uninstall stack"
    echo " 0) Exit"
    echo
}

prompt_add_endpoint() {
    local description="" protocol="all" through="" iface="" listen_iface=""
    local extra_remotes="" balance="" tcp_timeout="" udp_timeout=""

    read -r -p "Remote host: " REMOTE_HOST
    read -r -p "Remote port: " REMOTE_PORT
    read -r -p "Listen port: " LOCAL_PORT
    read -r -p "Protocol [all/tcp/udp, default all]: " protocol
    read -r -p "Description (optional): " description
    read -r -p "Through address (optional): " through
    read -r -p "Outgoing interface (optional): " iface
    read -r -p "Incoming interface (optional): " listen_iface
    read -r -p "Extra remotes host:port CSV (optional): " extra_remotes
    read -r -p "Balance string (optional): " balance
    read -r -p "TCP timeout override seconds (optional): " tcp_timeout
    read -r -p "UDP timeout override seconds (optional): " udp_timeout

    PROTOCOL="${protocol:-all}"
    DESCRIPTION="${description:-}"
    THROUGH="${through:-}"
    INTERFACE_NAME="${iface:-}"
    LISTEN_INTERFACE="${listen_iface:-}"
    EXTRA_REMOTES="${extra_remotes:-}"
    BALANCE="${balance:-}"
    TCP_TIMEOUT="${tcp_timeout:-}"
    UDP_TIMEOUT="${udp_timeout:-}"

    add_endpoint
}

prompt_remove_endpoint() {
    local local_port
    list_endpoints
    echo
    read -r -p "Listen port to remove: " local_port
    remove_endpoint "$local_port"
}

prompt_edit_endpoint() {
    local local_port
    list_endpoints
    echo
    read -r -p "Listen port to edit: " local_port
    edit_endpoint_state "$local_port"
}

show_usage() {
    cat <<'EOF'
Usage:
  cristsau-realm-pro.sh                Start the interactive menu
  cristsau-realm-pro.sh menu
  cristsau-realm-pro.sh install
  cristsau-realm-pro.sh list
  cristsau-realm-pro.sh command-menu
  cristsau-realm-pro.sh share-menu
  cristsau-realm-pro.sh health
  cristsau-realm-pro.sh logs
  cristsau-realm-pro.sh backup
  cristsau-realm-pro.sh restore [backup_dir]
  cristsau-realm-pro.sh watchdog-enable
  cristsau-realm-pro.sh watchdog-disable
  cristsau-realm-pro.sh regenerate
  cristsau-realm-pro.sh remove <listen_port>
  cristsau-realm-pro.sh edit-endpoint <listen_port>
  cristsau-realm-pro.sh add --host HOST --remote-port PORT --listen-port PORT
                         [--protocol all|tcp|udp]
                         [--description TEXT]
                         [--through ADDRESS]
                         [--interface DEVICE]
                         [--listen-interface DEVICE]
                         [--extra-remotes host1:port,host2:port]
                         [--balance STRING]
                         [--tcp-timeout SECONDS]
                         [--udp-timeout SECONDS]
EOF
}

parse_add_cli() {
    REMOTE_HOST=""
    REMOTE_PORT=""
    LOCAL_PORT=""
    PROTOCOL="all"
    DESCRIPTION=""
    THROUGH=""
    INTERFACE_NAME=""
    LISTEN_INTERFACE=""
    EXTRA_REMOTES=""
    BALANCE=""
    TCP_TIMEOUT=""
    UDP_TIMEOUT=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --host)
                REMOTE_HOST="${2:-}"
                shift 2
                ;;
            --remote-port)
                REMOTE_PORT="${2:-}"
                shift 2
                ;;
            --listen-port|--local-port)
                LOCAL_PORT="${2:-}"
                shift 2
                ;;
            --protocol)
                PROTOCOL="${2:-}"
                shift 2
                ;;
            --description)
                DESCRIPTION="${2:-}"
                shift 2
                ;;
            --through)
                THROUGH="${2:-}"
                shift 2
                ;;
            --interface)
                INTERFACE_NAME="${2:-}"
                shift 2
                ;;
            --listen-interface)
                LISTEN_INTERFACE="${2:-}"
                shift 2
                ;;
            --extra-remotes)
                EXTRA_REMOTES="${2:-}"
                shift 2
                ;;
            --balance)
                BALANCE="${2:-}"
                shift 2
                ;;
            --tcp-timeout)
                TCP_TIMEOUT="${2:-}"
                shift 2
                ;;
            --udp-timeout)
                UDP_TIMEOUT="${2:-}"
                shift 2
                ;;
            *)
                die "unknown add option: $1"
                ;;
        esac
    done

    add_endpoint
}

run_menu() {
    while true; do
        show_menu
        read -r -p "Select [2]: " action
        action="${action:-2}"
        case "$action" in
            1) install_or_update_realm; ensure_base_config; ensure_service_file; pause ;;
            2) list_endpoints; pause ;;
            3) prompt_add_endpoint; pause ;;
            4) prompt_remove_endpoint; pause ;;
            5) prompt_edit_endpoint; pause ;;
            6) service_actions; pause ;;
            7) show_health; pause ;;
            8) show_recent_logs; pause ;;
            9) edit_base_config ;;
            10) create_backup; pause ;;
            11) restore_backup; pause ;;
            12) enable_watchdog; pause ;;
            13) disable_watchdog; pause ;;
            14) launch_command_menu; pause ;;
            15) node_share_menu; pause ;;
            16) apply_runtime_state; pause ;;
            17) uninstall_stack; pause ;;
            0) exit 0 ;;
            *) msg "$RED" "invalid selection"; pause ;;
        esac
    done
}

main() {
    require_root
    need_cmd awk
    need_cmd bash
    need_cmd find
    need_cmd flock
    need_cmd grep
    need_cmd install
    need_cmd mktemp
    need_cmd sed
    need_cmd sort
    need_cmd ss
    need_cmd systemctl
    need_cmd uname
    acquire_lock

    case "${1:-menu}" in
        menu)
            run_menu
            ;;
        install)
            install_or_update_realm
            ensure_base_config
            ensure_service_file
            ;;
        list)
            list_endpoints
            ;;
        command-menu)
            launch_command_menu
            ;;
        add)
            shift
            parse_add_cli "$@"
            ;;
        share-menu)
            node_share_menu
            ;;
        remove)
            [ "$#" -eq 2 ] || die "usage: $0 remove <listen_port>"
            remove_endpoint "$2"
            ;;
        edit-endpoint)
            [ "$#" -eq 2 ] || die "usage: $0 edit-endpoint <listen_port>"
            edit_endpoint_state "$2"
            ;;
        health)
            show_health
            ;;
        logs)
            show_recent_logs
            ;;
        backup)
            create_backup
            ;;
        restore)
            shift
            restore_backup "${1:-}"
            ;;
        watchdog-enable)
            enable_watchdog
            ;;
        watchdog-disable)
            disable_watchdog
            ;;
        regenerate)
            apply_runtime_state
            ;;
        help|-h|--help)
            show_usage
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
