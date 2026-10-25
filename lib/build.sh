#!/usr/bin/env bash

# Shared source-preparation layer used by both the dry-run and full builder.
# Keeping this path in one file prevents a dry-run from validating behavior
# that differs from the eventual compilation path.

source "$(dirname -- "${BASH_SOURCE[0]}")/progress.sh"

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: Required command not found: %s\n' "$cmd" >&2
        return 1
    }
}

require_build_commands() {
    local cmd
    for cmd in make find cp mktemp awk mv sort basename tail grep mkdir tar xz patch dpkg dpkg-deb dpkg-query apt-cache apt-get sha256sum python3 realpath findmnt; do
        require_command "$cmd" || return 1
    done
}

configure_and_validate_kernel() {
    local tree="$1" variant="$2"
    local baseline="$tree/.config.kernelforge-normalized-baseline"
    local log_file="${3:-$tree/.kernelforge-config.log}"
    local distribution_config="${4:-$baseline}"

    kconfig_require_tree "$tree"
    : >"$log_file"
    printf '==> Detailed configuration checks: %s\n' "$log_file"

    kernelforge_run_logged 'Preparing baseline configuration' "$log_file" make -C "$tree" olddefconfig || return 1
    cp "$tree/.config" "$baseline"
    mx_validate_toolchain_features "$distribution_config" "$tree/.config" || return 1
    kernelforge_run_logged 'Checking selected Debian flavour and hardware defaults' "$log_file" \
        mx_validate_debian_config "$distribution_config" "$tree/.config" || return 1

    resolve_kernel_tuning_policy "$tree" "$variant"
    kernelforge_choose_dwarf_zstd "$tree" || return 1
    print_policy_summary
    printf '==> Optional DWARF Zstd compression selected: %s\n' "${KERNELFORGE_DWARF_ZSTD:-no}"
    printf '\n'

    printf '==> Applying universal ThinkPad profile...\n'
    kconfig_apply_profile "$tree"

    printf '==> Applying resolved feature policy...\n'
    kconfig_apply_policy "$tree"
    kernelforge_apply_dwarf_zstd "$tree" || return 1

    kernelforge_run_logged 'Resolving configuration dependencies' "$log_file" make -C "$tree" olddefconfig || return 1

    kernelforge_run_logged 'Checking ThinkPad hardware and feature settings' "$log_file" \
        validate_kernel_policy "$tree" "$distribution_config" || return 1
    printf '==> ThinkPad hardware and feature checks passed.\n'
    kernelforge_validate_dwarf_zstd "$baseline" "$tree/.config" || return 1
    mx_validate_toolchain_features "$distribution_config" "$tree/.config" || return 1
    kernelforge_run_logged 'Checking selected Debian flavour and hardware defaults' "$log_file" \
        mx_validate_debian_config "$distribution_config" "$tree/.config" || return 1
}
