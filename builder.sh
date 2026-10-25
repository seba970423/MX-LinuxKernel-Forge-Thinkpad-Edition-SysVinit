#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/toolchain.sh"
source "$REPO_ROOT/lib/sources.sh"
source "$REPO_ROOT/lib/packages.sh"
source "$REPO_ROOT/lib/build.sh"
source "$REPO_ROOT/lib/naming.sh"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/hardware.sh"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
source "$REPO_ROOT/lib/debug-compression.sh"
source "$REPO_ROOT/lib/cleanup.sh"

ask_compile() {
    local answer

    printf '\n'
    read -r -p "Compile selected kernel now? [y/N]: " answer

    case "${answer:-n}" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ask_install() {
    local answer
    printf '\n'
    if ! read -r -p "Install this build's Debian kernel image and headers? [y/N]: " answer; then answer=n; fi
    case "${answer:-n}" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}


main() {
    if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
        printf 'KernelForge ThinkPad MX/Debian edition\nRun as your regular user; APT and installation request sudo when needed.\n'
        return 0
    fi
    [[ $# == 0 ]] || { echo 'ERROR: Unknown argument (use --help).' >&2; return 1; }
    mx_require_build_user
    mx_require_host
    mx_ensure_base_dependencies
    require_build_commands

    printf '==> KernelForge ThinkPad MX/Debian Edition\n'
    printf '==> Configuration is prepared and validated before the main kernel package build.\n\n'

    load_profile "$REPO_ROOT"
    validate_profile

    detect_hardware
    print_hardware_summary
    printf '\n'

    mx_resolve_debian_kernel
    mx_choose_kernel_flavour
    printf '\n'

    local workdir
    local checkout
    local variant
    local custom_name
    local tree

    workdir="$(mktemp -d --tmpdir=/var/tmp kernelforge-mx-build.XXXXXX)"
    printf 'kernelforge-workdir-v1\n' >"$workdir/.kernelforge-workdir"
    checkout="$workdir/upstream"

    mkdir -p "$workdir/tmp"
    export TMPDIR="$workdir/tmp"

    printf '==> Work directory: %s\n' "$workdir"
    printf '==> Compiler temporary directory: %s\n' "$TMPDIR"

    variant="$KF_VARIANT"
    custom_name="$(prompt_kernel_name)"
    tree="$(prepare_debian_source "$checkout/$variant" "$custom_name")"

    printf '==> Prepared kernel tree: %s\n' "$tree"

    # shellcheck source=/dev/null
    source "$checkout/$variant/.kernelforge-toolchain-env"
    resolve_policy "$tree"
    configure_and_validate_kernel "$tree" "$variant" "$checkout/$variant/.kernelforge-config.log" "$checkout/$variant/config"

    printf '\n'
    printf '==> CONFIGURATION VALIDATION PASSED.\n'
    printf '==> Kernel variant: %s\n' "$variant"
    printf '==> Kernel release suffix: %s\n' "$custom_name"
    printf '==> Prepared work tree: %s\n' "$workdir"

    if ask_compile; then
        compile_selected_kernel "$checkout" "$variant" "$tree"

        printf '\n'
        printf '==> BUILD PASSED.\n'
        printf '==> Kernel variant: %s\n' "$variant"
        printf '==> Kernel release suffix: %s\n' "$custom_name"

        if ask_install; then
            install_built_kernel "$checkout" "$variant"

            printf '\n'
            printf '==> INSTALLATION PASSED.\n'
            printf '==> Installed kernel release suffix: %s\n' "$custom_name"
            printf '==> Reboot manually when you are ready to boot the new kernel.\n'
            kernelforge_offer_postinstall_cleanup "$workdir" "$variant" "$tree"
        else
            printf '==> Installation skipped.\n'
            printf '==> Packages remain available in the work tree.\n'
        fi

        if [[ "$KERNELFORGE_CLEANUP_PERFORMED" == 1 ]]; then
            printf '==> Retained kernel packages, source packages, logs and configurations: %s\n' "$workdir"
        else
            printf '==> Work tree kept for inspection: %s\n' "$workdir"
        fi
    else
        printf '\n'
        printf '==> Compilation skipped.\n'
        printf '==> Nothing was installed.\n'
        printf '==> Work tree kept for inspection: %s\n' "$workdir"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
