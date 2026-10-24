#!/usr/bin/env bash
# Dedicated process keeps errexit semantics independent of the caller's if/!.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/pgp.sh"
source "$REPO_ROOT/lib/sources.sh"
source "$REPO_ROOT/lib/toolchain.sh"
package_dir="$1"
export KERNELFORGE_PREPARE_LOG="${KERNELFORGE_PREPARE_LOG:-$package_dir/.kernelforge-prepare.log}"
mx_acquire_sources "$package_dir"
source "$package_dir/.kernelforge-recipe"
mx_prepare_toolchain "$package_dir" "$package_dir/src/$KF_SOURCE_TREE"
kernelforge_run_logged 'Source preparation' "$KERNELFORGE_PREPARE_LOG" \
    bash "$REPO_ROOT/lib/recipe.sh" prepare "$package_dir" < <(yes '')
mx_validate_lto_mode "$package_dir" "$package_dir/src/$KF_SOURCE_TREE/.config"
mx_validate_toolchain_features "$package_dir/config" "$package_dir/src/$KF_SOURCE_TREE/.config"
