#!/usr/bin/env bash
# Debian's linux-source archive already includes the Debian kernel patches.
# Download binary source/config packages through authenticated APT metadata;
# deb-src entries and a third-party kernel recipe are not needed.

source "$(dirname -- "${BASH_SOURCE[0]}")/progress.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/flavours.sh"

mx_debian_kernel_series() {
    local version
    version="$(cat "${1:-/etc/debian_version}")" || return 1
    case "$version" in
        12|12.*) printf '6.1\n' ;;
        13|13.*) printf '6.12\n' ;;
        *)
            printf 'ERROR: Unsupported Debian base %s; supported bases are Debian 12 and 13.\n' "$version" >&2
            return 1 ;;
    esac
}

mx_apt_package_digest() {
    local package="$1" version="$2" digest
    digest="$(apt-cache show "$package=$version" | awk '/^SHA256:/ {print $2}' | sort -u)" || return 1
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || {
        printf 'ERROR: No unique APT SHA256 for %s=%s. Refresh APT package lists and retry.\n' "$package" "$version" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

mx_resolve_debian_kernel() {
    mx_refresh_apt_lists || return 1
    KF_DEBIAN_SERIES="$(mx_debian_kernel_series /etc/debian_version)" || return 1
    KF_DEBIAN_SOURCE="linux-source-$KF_DEBIAN_SERIES"
    KF_DEBIAN_CONFIG="linux-config-$KF_DEBIAN_SERIES"
    KF_DEBIAN_VERSION="$(mx_apt_candidate "$KF_DEBIAN_SOURCE")" || return 1
    [[ "$KF_DEBIAN_VERSION" == "$KF_DEBIAN_SERIES".* && "$KF_DEBIAN_VERSION" != *~bpo* ]] &&
        dpkg --validate-version "$KF_DEBIAN_VERSION" || {
            printf 'ERROR: No stable %s candidate in enabled APT repositories. Refresh package lists and retry.\n' "$KF_DEBIAN_SOURCE" >&2
            return 1
        }
    KF_DEBIAN_SOURCE_SHA256="$(mx_apt_package_digest "$KF_DEBIAN_SOURCE" "$KF_DEBIAN_VERSION")" || return 1
    KF_DEBIAN_CONFIG_SHA256="$(mx_apt_package_digest "$KF_DEBIAN_CONFIG" "$KF_DEBIAN_VERSION")" || return 1
    KF_VARIANT="linux-debian-$KF_DEBIAN_SERIES"
    printf '==> Debian kernel source: %s=%s\n' "$KF_DEBIAN_SOURCE" "$KF_DEBIAN_VERSION"
    printf '==> Matching configuration package: %s.\n' "$KF_DEBIAN_CONFIG"
}

mx_download_debian_packages() (
    local directory="$1"
    cd -- "$directory" || return 1
    # APT verifies repository authentication and package hashes. No sudo, APT
    # source edits, package installation, or unauthenticated override is used.
    apt-get download "$KF_DEBIAN_SOURCE=$KF_DEBIAN_VERSION" "$KF_DEBIAN_CONFIG=$KF_DEBIAN_VERSION"
)

mx_find_debian_package() {
    local directory="$1" expected="$2" architecture="$3" digest="$4"
    local file name version arch actual match=''
    for file in "$directory/"*.deb; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        name="$(dpkg-deb -f "$file" Package)" || return 1
        [[ "$name" == "$expected" ]] || continue
        version="$(dpkg-deb -f "$file" Version)" || return 1
        arch="$(dpkg-deb -f "$file" Architecture)" || return 1
        [[ "$version" == "$KF_DEBIAN_VERSION" && "$arch" == "$architecture" && -z "$match" ]] || {
            printf 'ERROR: Ambiguous or mismatched Debian source/config package: %s\n' "$file" >&2
            return 1
        }
        actual="$(sha256sum -- "$file")" || return 1
        [[ "${actual%% *}" == "$digest" ]] || {
            printf 'ERROR: Debian source/config package SHA256 mismatch: %s\n' "$file" >&2
            return 1
        }
        match="$file"
    done
    [[ -n "$match" ]] || { printf 'ERROR: Missing downloaded package %s.\n' "$expected" >&2; return 1; }
    printf '%s\n' "$match"
}

prepare_debian_source() {
    local package_dir="$1" custom_name="$2"
    local log_file="$package_dir/.kernelforge-prepare.log"
    local unpack="$package_dir/src/debian-packages" tree="$package_dir/src/linux-source-$KF_DEBIAN_SERIES"
    local source_deb config_deb archive config config_name standard_config
    mx_validate_flavour_selection || return 1
    mkdir -p -- "$package_dir/downloads" "$unpack" || return 1
    : >"$log_file"
    printf '==> Preparing Debian %s sources (no kernel package build)...\n' "$KF_DEBIAN_VERSION" >&2
    printf '==> Detailed prepare log: %s\n' "$log_file" >&2
    kernelforge_run_logged 'Downloading Debian source and configuration' "$log_file" \
        mx_download_debian_packages "$package_dir/downloads" || return 1
    source_deb="$(mx_find_debian_package "$package_dir/downloads" "$KF_DEBIAN_SOURCE" all "$KF_DEBIAN_SOURCE_SHA256")" || return 1
    config_deb="$(mx_find_debian_package "$package_dir/downloads" "$KF_DEBIAN_CONFIG" amd64 "$KF_DEBIAN_CONFIG_SHA256")" || return 1
    kernelforge_run_logged 'Unpacking Debian source package' "$log_file" dpkg-deb --extract "$source_deb" "$unpack" || return 1
    kernelforge_run_logged 'Unpacking Debian configuration package' "$log_file" dpkg-deb --extract "$config_deb" "$unpack" || return 1
    archive="$unpack/usr/src/linux-source-$KF_DEBIAN_SERIES.tar.xz"
    config_name="$(mx_debian_config_filename)"
    config="$unpack/usr/src/linux-config-$KF_DEBIAN_SERIES/$config_name"
    standard_config="$unpack/usr/src/linux-config-$KF_DEBIAN_SERIES/config.amd64_none_amd64.xz"
    [[ -f "$archive" && -f "$config" && -f "$standard_config" && ! -e "$tree" ]] || {
        echo 'ERROR: Unexpected Debian source/config package layout or existing source tree.' >&2
        return 1
    }
    kernelforge_run_logged 'Extracting Debian kernel' "$log_file" tar --extract --file "$archive" \
        --directory "$package_dir/src" --no-same-owner --no-same-permissions || return 1
    xz --decompress --stdout -- "$config" >"$package_dir/config" || return 1
    xz --decompress --stdout -- "$standard_config" >"$package_dir/config.standard" || return 1
    grep -qx 'CONFIG_X86_64=y' "$package_dir/config" || {
        echo 'ERROR: Expected Debian amd64 configuration.' >&2; return 1;
    }
    if [[ "${KF_PREEMPT_RT:-no}" == yes ]]; then
        grep -qx 'CONFIG_PREEMPT_RT=y' "$package_dir/config" || {
            echo 'ERROR: Matching Debian RT configuration is missing PREEMPT_RT.' >&2; return 1;
        }
        kernelforge_run_logged 'Checking Debian RT graphics and input configuration' "$log_file" \
            mx_validate_debian_hardware "$package_dir/config.standard" "$package_dir/config" || return 1
    elif grep -qx 'CONFIG_PREEMPT_RT=y' "$package_dir/config"; then
        echo 'ERROR: Expected Debian standard non-RT configuration.' >&2; return 1
    fi
    [[ -x "$tree/scripts/config" && -f "$tree/Makefile" ]] || return 1
    mx_prepare_flavour_sources "$package_dir" "$tree" "$log_file" >&2 || {
        printf 'ERROR: Selected patches do not match Debian %s; source preparation stopped. See %s.\n' "$KF_DEBIAN_VERSION" "$log_file" >&2
        return 1
    }
    cp -- "$package_dir/config" "$tree/.config" || return 1
    mx_configure_flavour "$tree" >&2 || return 1
    printf '%s\n' "$KF_DEBIAN_VERSION" >"$package_dir/.kernelforge-source-version"
    {
        printf 'source=%s\nconfig=%s\nversion=%s\n' "$KF_DEBIAN_SOURCE" "$KF_DEBIAN_CONFIG" "$KF_DEBIAN_VERSION"
        printf 'source_sha256=%s\nconfig_sha256=%s\n' "$KF_DEBIAN_SOURCE_SHA256" "$KF_DEBIAN_CONFIG_SHA256"
        cat -- "$package_dir/.kernelforge-flavour"
    } >"$package_dir/.kernelforge-source-info"
    apply_custom_kernel_name "$tree" "$custom_name" >&2 || return 1
    # Debian's archive signing keys are not shipped in linux-source. Keep
    # module signing, generating a local build key instead of using Debian's
    # private signing paths. This does not enroll keys for Secure Boot.
    "$tree/scripts/config" --file "$tree/.config" --set-str SYSTEM_TRUSTED_KEYS '' || return 1
    "$tree/scripts/config" --file "$tree/.config" --set-str SYSTEM_REVOCATION_KEYS '' || return 1
    "$tree/scripts/config" --file "$tree/.config" --set-str MODULE_SIG_KEY certs/signing_key.pem || return 1
    mx_prepare_toolchain "$package_dir" "$tree" >&2 || return 1
    printf '==> Debian sources and configuration prepared.\n' >&2
    printf '%s\n' "$tree"
}
