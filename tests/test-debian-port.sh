#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/toolchain.sh"
source "$REPO_ROOT/lib/packages.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }
expect_failure() { if ( "$@" ) > /dev/null 2>&1; then fail "Unexpected success: $*"; fi; }

# Kernel bindeb-pkg declares libdw-dev:native even when the other build tools
# are already installed. Detect and offer it before fetching/preparing sources.
(
    dpkg-query() {
        if [[ "${!#}" != libdw-dev ]]; then printf 'installed'; fi
    }
    mx_as_root() { printf '%s\n' "$*" >>"$scratch/base-dependency-apt-calls"; }
    mx_ensure_base_dependencies <<< y >"$scratch/base-dependency-output" 2>&1
    [[ -f "$scratch/base-dependency-apt-calls" ]] || fail 'Missing libdw-dev was not detected.'
    grep -qx 'apt-get update' "$scratch/base-dependency-apt-calls" || fail 'APT metadata was not refreshed.'
    grep -qx 'apt-get --simulate --no-remove --no-install-recommends install libdw-dev' \
        "$scratch/base-dependency-apt-calls" || fail 'libdw-dev installation was not simulated.'
    grep -qx 'apt-get --no-remove --no-install-recommends install libdw-dev' \
        "$scratch/base-dependency-apt-calls" || fail 'libdw-dev was not offered for installation.'

    mx_as_root() { touch "$scratch/declined-base-dependency-apt"; }
    expect_failure mx_ensure_base_dependencies <<< n
    [[ ! -e "$scratch/declined-base-dependency-apt" ]] || fail 'Declined dependencies reached APT.'

    dpkg-query() { printf 'installed'; }
    mx_ensure_base_dependencies </dev/null
    [[ ! -e "$scratch/declined-base-dependency-apt" ]] || fail 'Installed dependencies reached APT.'
)

# Toolchain feature loss is checked against the unmodified Debian config.
printf 'CONFIG_DEBUG_INFO_BTF=y\nCONFIG_LTO_NONE=y\n' >"$scratch/original"
cp "$scratch/original" "$scratch/final"
mx_validate_toolchain_features "$scratch/original" "$scratch/final"
printf '# CONFIG_DEBUG_INFO_BTF is not set\nCONFIG_LTO_NONE=y\n' >"$scratch/final"
expect_failure mx_validate_toolchain_features "$scratch/original" "$scratch/final"
mx_version_at_least 13.3.0 5.1
expect_failure mx_version_at_least 4.9.0 5.1

# Exercise the real .deb collection/selection using tiny genuine Debian packages.
checkout="$scratch/upstream"
variant=linux-debian-6.12
package_dir="$checkout/$variant"
tree="$package_dir/src/linux-test"
test_release=6.12.107-mx-thinkpad-debian
release="$test_release"
mkdir -p "$tree" "$scratch/tmp"
TMPDIR="$scratch/tmp"
printf 'CONFIG_MODULES=y\n' >"$tree/.config"
printf '6.12.107-1\n' >"$package_dir/.kernelforge-source-version"
create_deb() {
    local name="$1" staging="$scratch/staging-$1"
    mkdir -p "$staging/DEBIAN"
    printf 'Package: %s\nVersion: 6.12.107-1+mx1\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nDescription: Test kernel artifact\n' "$name" >"$staging/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$staging" "$package_dir/src/$name.deb" >/dev/null
}
make() {
    if [[ "$*" == *syncconfig* ]]; then touch "$scratch/config-synchronized"; return 0; fi
    if [[ "$*" == *kernelrelease* ]]; then
        [[ -f "$scratch/config-synchronized" ]] || return 15
        printf '%s\n' "$test_release"; return 0
    fi
    [[ "$*" == *bindeb-pkg* ]] || return 1
    create_deb "linux-image-$release"
    create_deb "linux-headers-$release"
    create_deb "linux-image-$release-dbg"
    create_deb linux-libc-dev
}
compile_selected_kernel "$checkout" "$variant" "$tree" >"$scratch/build-output"
[[ "$(wc -l <"$package_dir/.kernelforge-built-packages")" == 2 ]] || fail 'Wrong install manifest.'
! grep -Eq 'libc|dbg' "$package_dir/.kernelforge-built-packages" || fail 'Userspace headers/debug selected for install.'
[[ -f "$package_dir/packages/linux-libc-dev.deb" ]] || fail 'Extra artifact was not retained.'
cmp "$tree/.config" "$package_dir/.kernelforge-validated.config"
unset -f make

# Stop the installer at the APT boundary and inspect the exact transaction.
update-grub() { :; }
update-initramfs() { :; }
mx_as_root() { printf '%s\n' "$@" >"$scratch/install-arguments"; return 1; }
expect_failure install_built_kernel "$checkout" "$variant"
[[ -f "$scratch/install-arguments" ]] || fail 'APT boundary was not reached.'
grep -qx -- '--no-remove' "$scratch/install-arguments" || fail 'APT remove guard missing.'
! grep -Eq 'libc|dbg' "$scratch/install-arguments" || fail 'Installer selected unrelated packages.'
printf 'tamper' >>"$package_dir/packages/linux-image-$release.deb"
mx_as_root() { touch "$scratch/tampered-reached-apt"; return 1; }
expect_failure install_built_kernel "$checkout" "$variant"
[[ ! -e "$scratch/tampered-reached-apt" ]] || fail 'Modified package reached APT.'

# SysVinit MX and Debian hosts are accepted; Arch and Ubuntu are rejected.
(
    test_id=mx
    test_like=debian
    source() {
        if [[ "$1" == /etc/os-release ]]; then
            ID="$test_id" ID_LIKE="$test_like" PRETTY_NAME='Fixture MX (SysVinit)'
        else builtin source "$@"; fi
    }
    dpkg() { printf 'amd64\n'; }
    cat() { if [[ "$1" == /proc/1/comm ]]; then printf 'init\n'; else command cat "$@"; fi; }
    mx_require_host >"$scratch/host-output"
    grep -q 'PID 1: init' "$scratch/host-output" || fail 'SysVinit host not reported.'
    test_id=debian
    mx_require_host >/dev/null
    test_id=arch test_like=''
    expect_failure mx_require_host
    test_id=ubuntu test_like=debian
    expect_failure mx_require_host
)

# A failed dependency simulation prevents the real APT transaction.
mx_as_root() { printf '%s\n' "$*" >>"$scratch/apt-calls"; return 1; }
expect_failure mx_apt_install bison
[[ "$(wc -l <"$scratch/apt-calls")" == 1 ]] || fail 'APT ran after a failed simulation.'
grep -q -- '--simulate --no-remove' "$scratch/apt-calls" || fail 'Unsafe dependency transaction.'

printf 'MX/Debian source, toolchain and package tests passed.\n'
