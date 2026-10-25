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

    printf '==> KernelForge ThinkPad MX/Debian Edition dry-run\n'
    printf '==> This run will NOT build or install kernel packages.\n\n'

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

    workdir="$(mktemp -d --tmpdir=/var/tmp kernelforge-thinkpad-dryrun.XXXXXX)"
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
    printf '==> DRY-RUN PASSED.\n'
    printf '==> Kernel variant: %s\n' "$variant"
    printf '==> Kernel release suffix: %s\n' "$custom_name"
    printf '==> No kernel packages were built or installed.\n'
    printf '==> Prepared work tree kept for inspection: %s\n' "$workdir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
