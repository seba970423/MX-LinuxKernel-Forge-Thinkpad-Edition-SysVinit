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
    for cmd in git make find cp mktemp yes awk mv sort basename tail grep gpg mkdir curl tar dpkg dpkg-deb sha256sum b2sum; do
        require_command "$cmd" || return 1
    done
}

find_kernel_tree() {
    local package_dir="$1"
    local -a matches=()
    local scripts_config

    while IFS= read -r scripts_config; do
        matches+=("$scripts_config")
    done < <(
        find "$package_dir/src" -maxdepth 4 -type f -path '*/scripts/config' -print
    )

    if (( ${#matches[@]} == 0 )); then
        printf 'ERROR: Could not locate a prepared kernel scripts/config under %s/src\n' \
            "$package_dir" >&2
        return 1
    fi

    if (( ${#matches[@]} > 1 )); then
        printf 'ERROR: Multiple prepared kernel trees were found; refusing to guess:\n' >&2
        printf '  %s\n' "${matches[@]}" >&2
        return 1
    fi

    dirname "$(dirname "${matches[0]}")"
}

prepare_upstream_source() {
    local checkout="$1"
    local variant="$2"
    local package_dir="$checkout/$variant"
    local log_file="$package_dir/.kernelforge-prepare.log"

    # This function is used in command substitution. Keep stdout reserved
    # exclusively for the final kernel-tree path.
    printf '==> Verifying and preparing %s sources (no kernel package build)...\n' "$variant" >&2
    printf '==> Detailed prepare log: %s\n' "$log_file" >&2
    printf '==> Tool output is saved in the log; long steps report elapsed time every %s seconds.\n' \
        "${KERNELFORGE_PROGRESS_INTERVAL:-30}" >&2

    : >"$log_file"
    # Unattended tools append their diagnostics directly; foreground questions
    # and summaries remain live and are also retained by tee in append mode.
    if ! KERNELFORGE_PREPARE_LOG="$log_file" bash "$REPO_ROOT/lib/prepare.sh" "$package_dir" \
        2>&1 | tee -a "$log_file" >&2; then
        printf 'ERROR: %s source preparation failed.\n' "$variant" >&2
        printf '%s\n' '--- Last 40 lines of prepare log ---' >&2
        tail -n 40 "$log_file" >&2 || true
        return 1
    fi

    printf '==> %s sources prepared successfully.\n' "$variant" >&2
    find_kernel_tree "$package_dir"
}

configure_and_validate_kernel() {
    local tree="$1" variant="$2"
    local baseline="$tree/.config.kernelforge-normalized-baseline"
    local log_file="${3:-$tree/.kernelforge-config.log}"

    kconfig_require_tree "$tree"
    : >"$log_file"
    printf '==> Detailed configuration checks: %s\n' "$log_file"

    kernelforge_run_logged 'Preparing baseline configuration' "$log_file" make -C "$tree" olddefconfig || return 1
    cp "$tree/.config" "$baseline"

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
        validate_kernel_policy "$tree" "$baseline" || return 1
    printf '==> ThinkPad hardware and feature checks passed.\n'
    kernelforge_validate_dwarf_zstd "$baseline" "$tree/.config" || return 1
    mx_validate_toolchain_features "$baseline" "$tree/.config" || return 1
}
