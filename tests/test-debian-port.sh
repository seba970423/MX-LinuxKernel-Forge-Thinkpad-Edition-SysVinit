#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/toolchain.sh"
source "$REPO_ROOT/lib/sources.sh"
source "$REPO_ROOT/lib/packages.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >"$scratch/expected-failure.log" 2>&1; then fail "Unexpected success: $*"; fi; }

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

# Native metadata evaluation handles current upstream defaults and ignores
# inherited overrides that would prune the universal hardware profile.
mkdir "$scratch/recipe"
cat >"$scratch/recipe/PKGBUILD" <<'RECIPE'
: "${_localmodcfg:=no}"
: "${_use_llvm_lto:=none}"
_srcname=linux-test
pkgver=7.3.0
pkgrel=1
source=('https://example.invalid/linux-test.tar.gz' config)
sha256sums=('SKIP' 'SKIP')
validpgpkeys=(E8B9AA39F054E30E8290D492C3C4820857F654FE)
[[ "$_localmodcfg" == no ]] || exit 9
prepare() { yes '' 2>/dev/null | head -1 >/dev/null; cp ../config .config; }
RECIPE
_localmodcfg=yes mx_recipe_metadata "$scratch/recipe" >"$scratch/recipe/.kernelforge-recipe"
grep -q 'KF_SOURCE_TREE=linux-test' "$scratch/recipe/.kernelforge-recipe" || fail 'Recipe metadata failed.'
mkdir -p "$scratch/recipe/src/linux-test"
printf 'CONFIG_RUST=y\nCONFIG_DEBUG_INFO_BTF=y\n' >"$scratch/recipe/config"
ln -s "$scratch/recipe/config" "$scratch/recipe/src/config"
# Match the real upstream prepare convention of changing into _srcname.
sed -i 's/prepare() { /prepare() { cd "$_srcname"; /' "$scratch/recipe/PKGBUILD"
bash "$REPO_ROOT/lib/recipe.sh" prepare "$scratch/recipe"
cmp "$scratch/recipe/config" "$scratch/recipe/src/linux-test/.config"

# Real digest verification rejects corrupt input and mismatched array lengths.
checksum="$(sha256sum "$scratch/recipe/config")"
printf 'declare -a source=(config)\ndeclare -a sha256sums=(%q)\n' "${checksum%% *}" >"$scratch/recipe/.kernelforge-recipe"
mx_verify_checksums "$scratch/recipe"
printf 'corrupt\n' >>"$scratch/recipe/config"
expect_failure mx_verify_checksums "$scratch/recipe"
printf 'declare -a source=(config other)\ndeclare -a sha256sums=(abc)\n' >"$scratch/recipe/.kernelforge-recipe"
expect_failure mx_verify_checksums "$scratch/recipe"
expect_failure mx_source_filename '../bad'
expect_failure mx_source_filename 'https://example.invalid/file?query'

# A valid cryptographic signature is insufficient unless its key is pinned.
printf 'data\n' >"$scratch/recipe/archive"
printf 'signature\n' >"$scratch/recipe/archive.asc"
cat >"$scratch/recipe/.kernelforge-recipe" <<'META'
declare -a source=(archive archive.asc)
declare -a validpgpkeys=(E8B9AA39F054E30E8290D492C3C4820857F654FE)
META
gpg() { printf '[GNUPG:] VALIDSIG %s 2026-10-24 0 0 4 0 1 10 00 %s\n' "$test_signer" "$test_primary"; }
test_signer=0123456789012345678901234567890123456789
test_primary=E8B9AA39F054E30E8290D492C3C4820857F654FE
mx_verify_signatures "$scratch/recipe"
test_primary=0123456789012345678901234567890123456789
expect_failure mx_verify_signatures "$scratch/recipe"
unset -f gpg

# Detect features disappearing while olddefconfig evaluates older tools.
printf 'CONFIG_RUST=y\nCONFIG_DEBUG_INFO_BTF=y\n' >"$scratch/original"
cp "$scratch/original" "$scratch/final"
mx_validate_toolchain_features "$scratch/original" "$scratch/final"
printf '# CONFIG_RUST is not set\nCONFIG_DEBUG_INFO_BTF=y\n' >"$scratch/final"
expect_failure mx_validate_toolchain_features "$scratch/original" "$scratch/final"
printf 'KF_LTO=thin\n' >"$scratch/recipe/.kernelforge-recipe"
printf 'CONFIG_LTO_CLANG_THIN=y\n' >"$scratch/lto-config"
mx_validate_lto_mode "$scratch/recipe" "$scratch/lto-config"
printf 'CONFIG_LTO_NONE=y\n' >"$scratch/lto-config"
expect_failure mx_validate_lto_mode "$scratch/recipe" "$scratch/lto-config"
mx_version_at_least 1.85.0 1.85.0
expect_failure mx_version_at_least 1.84.9 1.85.0

# Native optimization retains the Rust compiler level of the source baseline,
# including constraints stricter than the kernel's generic minimum.
mkdir -p "$scratch/rust-tree/scripts"
printf '#!/bin/sh\necho 1.85.0\n' >"$scratch/rust-tree/scripts/min-tool-version.sh"
printf 'CONFIG_RUST=y\nCONFIG_RUSTC_VERSION_TEXT="rustc 1.98.0 (fixture)"\n' >"$scratch/rust-baseline"
[[ "$(mx_required_rust_version "$scratch/rust-tree" "$scratch/rust-baseline")" == 1.98.0 ]] || fail 'Native Rust requirement was downgraded.'
printf '# CONFIG_RUST is not set\n' >"$scratch/rust-baseline"
[[ "$(mx_required_rust_version "$scratch/rust-tree" "$scratch/rust-baseline")" == 1.85.0 ]] || fail 'Generic Rust requirement incorrect.'

# Private LLVM acquisition verifies the publisher digest before extraction.
(
    llvm_name='LLVM-22.1.8-Linux-X64'
    llvm_fixture="$scratch/llvm-fixture"
    mkdir -p "$llvm_fixture/$llvm_name/bin" "$llvm_fixture/$llvm_name/lib"
    printf '#!/bin/sh\necho "clang version 22.1.8"\n' >"$llvm_fixture/$llvm_name/bin/clang"
    printf '#!/bin/sh\nexit 0\n' >"$llvm_fixture/$llvm_name/bin/ld.lld"
    cp "$llvm_fixture/$llvm_name/bin/ld.lld" "$llvm_fixture/$llvm_name/bin/llvm-objcopy"
    chmod +x "$llvm_fixture/$llvm_name/bin/"*
    touch "$llvm_fixture/$llvm_name/lib/libclang.so.22"
    tar -cJf "$scratch/llvm-archive.tar.xz" -C "$llvm_fixture" "$llvm_name"
    digest="$(sha256sum "$scratch/llvm-archive.tar.xz")"
    digest="${digest%% *}"
    llvm_json() {
        printf '[{"tag_name":"llvmorg-22.1.8","assets":[{"name":"%s.tar.xz","browser_download_url":"https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.8/%s.tar.xz","digest":"sha256:%s","size":1024}]}]\n' \
            "$llvm_name" "$llvm_name" "$digest"
    }
    curl() {
        local argument destination='' previous=''
        for argument in "$@"; do
            if [[ "$previous" == -o ]]; then destination="$argument"; fi
            previous="$argument"
        done
        if [[ -n "$destination" ]]; then cp "$scratch/llvm-archive.tar.xz" "$destination"; else llvm_json; fi
    }
    mx_isolated_llvm 22 "$scratch/llvm-private" <<< y
    mx_select_llvm 22.0.0 22
    [[ "$(mx_version clang --version)" == 22.1.8 ]] || fail 'Private LLVM was not selected.'
    digest="$(printf '%064d' 0)"
    expect_failure mx_isolated_llvm 22 "$scratch/llvm-tampered" <<< y
    [[ ! -e "$scratch/llvm-tampered/$llvm_name" ]] || fail 'Bad LLVM checksum reached extraction.'
    llvm_json | python3 "$REPO_ROOT/lib/llvm-release.py" 22 >/dev/null
    expect_failure bash -c 'printf "[]" | python3 "$1" 22' _ "$REPO_ROOT/lib/llvm-release.py"
)

# Exercise the real .deb collection/selection using tiny genuine Debian packages.
checkout="$scratch/upstream"
variant=linux-cachyos-rt-bore
package_dir="$checkout/$variant"
tree="$package_dir/src/linux-test"
test_release=7.3.0-1-mx-thinkpad-rt-bore
release="$test_release"
mkdir -p "$tree" "$scratch/tmp"
TMPDIR="$scratch/tmp"
printf 'CONFIG_MODULES=y\n' >"$tree/.config"
printf 'KF_PACKAGE_VERSION=7.3.0-1\n' >"$package_dir/.kernelforge-recipe"
create_deb() {
    local name="$1" staging="$scratch/staging-$1"
    mkdir -p "$staging/DEBIAN"
    printf 'Package: %s\nVersion: 7.3.0-1+mx1\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nDescription: Test kernel artifact\n' "$name" >"$staging/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$staging" "$package_dir/src/$name.deb" >/dev/null
}
make() {
    if [[ "$*" == *kernelrelease* ]]; then printf '%s\n' "$test_release"; return 0; fi
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
