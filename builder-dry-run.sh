#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/toolchain.sh"
source "$REPO_ROOT/lib/sources.sh"
source "$REPO_ROOT/lib/packages.sh"
source "$REPO_ROOT/lib/upstream.sh"
source "$REPO_ROOT/lib/pgp.sh"
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

    resolve_policy
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

    fetch_upstream "$checkout"

    printf '\n'
    variant="$(select_kernel_variant "$checkout")"
    printf '==> Selected kernel variant: %s\n' "$variant"

    validate_kernel_variant "$checkout" "$variant"

    custom_name="$(prompt_kernel_name "$variant")"
    apply_custom_kernel_name "$checkout" "$variant" "$custom_name"

    install_upstream_prepare_compat "$checkout" "$variant"

    tree="$(prepare_upstream_source "$checkout" "$variant")"

    printf '==> Prepared kernel tree: %s\n' "$tree"

    # shellcheck source=/dev/null
    source "$checkout/$variant/.kernelforge-toolchain-env"
    configure_and_validate_kernel "$tree" "$variant" "$checkout/$variant/.kernelforge-config.log"

    printf '\n'
    printf '==> DRY-RUN PASSED.\n'
    printf '==> Kernel variant: %s\n' "$variant"
    printf '==> Kernel release suffix: %s\n' "$custom_name"
    printf '==> No kernel packages were built or installed.\n'
    printf '==> Prepared work tree kept for inspection: %s\n' "$workdir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
