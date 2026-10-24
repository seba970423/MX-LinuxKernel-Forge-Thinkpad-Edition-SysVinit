#!/usr/bin/env bash
# MX/Debian host and APT integration. No service-manager operations are needed.

mx_require_host() {
    export PATH="$PATH:/usr/sbin:/sbin"
    local ID='' ID_LIKE='' PRETTY_NAME='' VERSION_CODENAME=''
    [[ -r /etc/os-release ]] || { echo 'ERROR: Missing /etc/os-release.' >&2; return 1; }
    source /etc/os-release
    case "$ID" in
        mx|mxlinux|debian|antix) ;;
        *)
            case " $ID_LIKE " in
                *' debian '*)
                    [[ "$ID" != ubuntu && "$ID_LIKE" != *ubuntu* ]] || {
                        echo 'ERROR: This edition supports MX/Debian, not Ubuntu.' >&2; return 1;
                    } ;;
                *) echo 'ERROR: This edition requires an MX/Debian host.' >&2; return 1 ;;
            esac ;;
    esac
    [[ "$(dpkg --print-architecture)" == amd64 ]] || {
        echo 'ERROR: The ThinkPad profile requires Debian amd64.' >&2; return 1;
    }
    printf '==> Host: %s\n' "$PRETTY_NAME"
    printf '==> PID 1: %s (init system is kept as configured)\n' "$(cat /proc/1/comm)"
}

mx_as_root() {
    if (( EUID == 0 )); then "$@"; else sudo -- "$@"; fi
}

mx_apt_candidate() {
    apt-cache policy "$1" | awk '/Candidate:/ && $2 != "(none)" {print $2; exit}'
}

mx_apt_install() {
    (( $# > 0 )) || return 0
    printf '==> APT dependency plan:\n' >&2
    # APT itself displays the transaction and requests confirmation. --no-remove
    # prevents a build dependency from displacing an installed init or package.
    mx_as_root apt-get --simulate --no-remove --no-install-recommends install "$@" >&2 || return 1
    mx_as_root apt-get --no-remove --no-install-recommends install "$@" >&2
}

mx_base_packages() {
    printf '%s\n' build-essential git ca-certificates curl gnupg dirmngr \
        bc bison flex m4 libssl-dev libelf-dev libdw-dev libncurses-dev zlib1g-dev \
        libzstd-dev libxxhash-dev pahole cpio rsync xz-utils zstd lz4 \
        gettext pkg-config python3 perl patch fakeroot dpkg-dev debhelper kmod
}

mx_ensure_base_dependencies() {
    local package answer status
    local -a missing=()
    while IFS= read -r package; do
        status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
        [[ "$status" == installed ]] || missing+=("$package")
    done < <(mx_base_packages)
    (( ${#missing[@]} > 0 )) || return 0
    printf '==> Missing Debian build dependencies:\n' >&2
    printf '    %s\n' "${missing[@]}" >&2
    if ! read -r -p 'Install these dependencies through APT? [Y/n]: ' answer; then answer=n; fi
    case "${answer:-y}" in
        y|Y|yes|YES|Yes)
            mx_as_root apt-get update >&2 || return 1
            mx_apt_install "${missing[@]}" || return 1 ;;
        *) echo 'ERROR: Required build dependencies are missing.' >&2; return 1 ;;
    esac
}

mx_require_build_user() {
    (( EUID != 0 )) || {
        echo 'ERROR: Run the builder as your regular user. It requests sudo only for APT/install.' >&2
        return 1
    }
}
