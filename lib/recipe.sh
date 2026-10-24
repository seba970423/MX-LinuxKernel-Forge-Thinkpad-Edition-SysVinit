#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Execute trusted upstream recipe metadata/prepare only; never its package hooks.
set -e
# Upstream prepare uses yes | make config; only the make exit status matters.
set +o pipefail
mode="$1"
package_dir="$2"
cd -- "$package_dir"
startdir="$package_dir"
srcdir="$package_dir/src"
CARCH=x86_64
BUILD_FLAGS=()
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# Ignore user/CI build overrides that would prune the universal profile or
# introduce Arch-specific external module packages.
for option in ${!_@}; do
    case "$option" in
        _use_*|_build_*|_localmodcfg*|_processor_opt|_tickrate|_cpusched|_cachy_config|_cc_harder|_per_gov|_tcp_bbr3|_HZ_ticks|_preempt|_hugepage|_autofdo*|_propeller*|_makenconfig|_makexconfig)
            unset "$option" ;;
    esac
done
export CI='' GITHUB_RUN_ID=''
error() { printf 'ERROR: %s\n' "$*" >&2; }
warning() { printf 'WARNING: %s\n' "$*" >&2; }
msg2() { printf '==> %s\n' "$*" >&2; }
source ./PKGBUILD
export KBUILD_BUILD_HOST=mx-debian

case "$mode" in
    metadata)
        for variable in source validpgpkeys b2sums sha256sums sha512sums sha1sums md5sums; do
            if declare -p "$variable" >/dev/null 2>&1; then declare -p "$variable"; fi
        done
        printf 'KF_SOURCE_TREE=%q\n' "$_srcname"
        printf 'KF_LTO=%q\n' "$_use_llvm_lto"
        printf 'KF_PACKAGE_VERSION=%q\n' "$pkgver-$pkgrel"
        ;;
    prepare)
        cd "$srcdir"
        prepare
        ;;
    *) error 'Unknown recipe operation'; exit 1 ;;
esac
