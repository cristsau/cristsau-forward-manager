#!/usr/bin/env bash

set -Eeuo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/cristsau/cristsau-forward-manager/main"
SCRIPT_URL="${REPO_RAW_BASE}/scripts/cristsau-realm-pro.sh"
INSTALL_PATH="/usr/local/bin/cristsau"

msg() {
    printf '%s\n' "$*"
}

die() {
    msg "$*"
    exit 1
}

need_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "请使用 root 运行，或改用: sudo bash <(curl -fsSL ${REPO_RAW_BASE}/install.sh)"
    fi
}

download_to() {
    local target="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$SCRIPT_URL" -o "$target"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$target" "$SCRIPT_URL"
    else
        die "缺少 curl 或 wget，无法下载安装脚本"
    fi
}

main() {
    local tmp

    need_root
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    msg "正在下载 cristsau 一键转发管理脚本..."
    download_to "$tmp"

    bash -n "$tmp" || die "下载到的脚本语法校验失败，已终止安装"

    install -m 0755 "$tmp" "$INSTALL_PATH"

    msg "安装完成: $INSTALL_PATH"
    msg "现在可以直接运行: cristsau"
}

main "$@"
