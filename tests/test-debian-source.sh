#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/sources.sh"
source "$REPO_ROOT/lib/naming.sh"
source "$REPO_ROOT/lib/toolchain.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >"$scratch/expected-error" 2>&1; then fail "Unexpected success: $*"; fi; }

printf '13.1\n' >"$scratch/debian-version"
[[ "$(mx_debian_kernel_series "$scratch/debian-version")" == 6.12 ]]
printf '12.12\n' >"$scratch/debian-version"
[[ "$(mx_debian_kernel_series "$scratch/debian-version")" == 6.1 ]]
printf 'forky/sid\n' >"$scratch/debian-version"
expect_failure mx_debian_kernel_series "$scratch/debian-version"

# Two genuine tiny Debian packages, containing a kernel archive and the three
# config flavours. The production path must select only standard amd64.
mkdir -p "$scratch/fixture/linux-source-6.12/scripts" "$scratch/source/DEBIAN" "$scratch/source/usr/src"
cat >"$scratch/fixture/linux-source-6.12/scripts/config" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
file="$2" operation="$3" symbol="$4"
sed -i -E "/^(CONFIG_${symbol}=.*|# CONFIG_${symbol} is not set)$/d" "$file"
case "$operation" in
    --set-str) printf 'CONFIG_%s="%s"\n' "$symbol" "$5" >>"$file" ;;
    --disable) printf '# CONFIG_%s is not set\n' "$symbol" >>"$file" ;;
    *) exit 1 ;;
esac
SCRIPT
chmod +x "$scratch/fixture/linux-source-6.12/scripts/config"
printf 'VERSION = 6\nPATCHLEVEL = 12\nSUBLEVEL = 107\n' >"$scratch/fixture/linux-source-6.12/Makefile"
printf '#!/bin/sh\ncase "$1" in gcc) echo 5.1;; binutils) echo 2.25;; esac\n' >"$scratch/fixture/linux-source-6.12/scripts/min-tool-version.sh"
tar -cJf "$scratch/source/usr/src/linux-source-6.12.tar.xz" -C "$scratch/fixture" linux-source-6.12
printf 'Package: linux-source-6.12\nVersion: 6.12.107-1\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: Test Debian kernel source\n' >"$scratch/source/DEBIAN/control"
dpkg-deb --build --root-owner-group "$scratch/source" "$scratch/source.deb" >/dev/null
mkdir -p "$scratch/config/DEBIAN" "$scratch/config/usr/src/linux-config-6.12"
printf 'CONFIG_X86_64=y\n# CONFIG_PREEMPT_RT is not set\nCONFIG_PREEMPT_VOLUNTARY=y\nCONFIG_LTO_NONE=y\nCONFIG_MOUSE_PS2=m\nCONFIG_RMI4_SMB=m\nCONFIG_DRM_I915=m\n' >"$scratch/standard.config"
xz -c "$scratch/standard.config" >"$scratch/config/usr/src/linux-config-6.12/config.amd64_none_amd64.xz"
printf 'CONFIG_PREEMPT_RT=y\n' | xz -c >"$scratch/config/usr/src/linux-config-6.12/config.amd64_rt_amd64.xz"
printf 'CONFIG_CLOUD=y\n' | xz -c >"$scratch/config/usr/src/linux-config-6.12/config.amd64_none_cloud-amd64.xz"
printf 'Package: linux-config-6.12\nVersion: 6.12.107-1\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nDescription: Test Debian kernel configuration\n' >"$scratch/config/DEBIAN/control"
dpkg-deb --build --root-owner-group "$scratch/config" "$scratch/config.deb" >/dev/null
source_digest="$(sha256sum "$scratch/source.deb" | cut -d' ' -f1)"
config_digest="$(sha256sum "$scratch/config.deb" | cut -d' ' -f1)"
candidate=6.12.107-1
mx_debian_kernel_series() { printf '6.12\n'; }
mx_refresh_apt_lists() { :; }
apt-cache() {
    case "$1" in
        policy) printf '  Candidate: %s\n' "$candidate" ;;
        show)
            case "$2" in
                linux-source-6.12=6.12.107-1) printf 'SHA256: %s\n' "$source_digest" ;;
                linux-config-6.12=6.12.107-1) printf 'SHA256: %s\n' "$config_digest" ;;
                *) return 100 ;;
            esac ;;
        *) return 1 ;;
    esac
}
mx_resolve_debian_kernel
[[ "$KF_DEBIAN_VERSION" == 6.12.107-1 && "$KF_VARIANT" == linux-debian-6.12 ]]
candidate=6.12.95-1~bpo12+1
expect_failure mx_resolve_debian_kernel
candidate=7.2.9-1
expect_failure mx_resolve_debian_kernel
candidate=6.12.111-1
expect_failure mx_resolve_debian_kernel
candidate=6.12.107-1
mx_resolve_debian_kernel >/dev/null

# Exercise the actual APT download arguments and the real unpack/name/toolchain
# operations. Only network transfer is replaced by the tiny signed-metadata
# package fixtures above. APT exits nonzero on authentication/download failure.
apt-get() {
    printf '%s\n' "$*" >"$scratch/download-arguments"
    [[ "${download_status:-0}" == 0 ]] || return 100
    cp "$scratch/source.deb" ./source.deb
    cp "$scratch/config.deb" ./config.deb
}
package_dir="$scratch/work/upstream/linux-debian-6.12"
tree="$(prepare_debian_source "$package_dir" seba-debian)"
grep -qx 'download linux-source-6.12=6.12.107-1 linux-config-6.12=6.12.107-1' "$scratch/download-arguments"
cmp "$scratch/standard.config" "$package_dir/config"
grep -qx 'CONFIG_LOCALVERSION="-seba-debian"' "$tree/.config"
grep -qx 'CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"' "$tree/.config"
grep -qx 'CONFIG_SYSTEM_TRUSTED_KEYS=""' "$tree/.config"
grep -qx 'CONFIG_RMI4_SMB=m' "$tree/.config"
grep -q 'export CC=/usr/bin/gcc' "$package_dir/.kernelforge-toolchain-env"
mx_validate_debian_config "$package_dir/config" "$tree/.config" >/dev/null

# Changed transport/graphics/preemption choices cannot pass as Debian defaults.
for symbol in RMI4_SMB MOUSE_PS2 DRM_I915 PREEMPT_VOLUNTARY; do
    cp "$package_dir/config" "$scratch/changed.config"
    sed -i -E "s/^CONFIG_${symbol}=[ym]$/# CONFIG_${symbol} is not set/" "$scratch/changed.config"
    expect_failure mx_validate_debian_config "$package_dir/config" "$scratch/changed.config"
done

# A failed download or changed hash stops before unpacking untrusted contents.
download_status=100
expect_failure prepare_debian_source "$scratch/failed" seba-debian
[[ ! -d "$scratch/failed/src/linux-source-6.12" ]]
download_status=0
KF_DEBIAN_SOURCE_SHA256="$(printf '%064d' 0)"
expect_failure prepare_debian_source "$scratch/tampered" seba-debian
[[ ! -d "$scratch/tampered/src/linux-source-6.12" ]]
KF_DEBIAN_SOURCE_SHA256="$source_digest"
cp "$package_dir/downloads/config.deb" "$package_dir/downloads/duplicate-config.deb"
expect_failure mx_find_debian_package "$package_dir/downloads" linux-config-6.12 amd64 "$config_digest"
expect_failure mx_find_debian_package "$package_dir/downloads" linux-source-6.12 amd64 "$source_digest"

# Inherited overrides must not leak into the saved distribution environment.
LLVM=1 KCFLAGS=-march=native KCONFIG_CONFIG=/tmp/not-the-kernel-config
mx_prepare_toolchain "$package_dir" "$tree"
[[ ! -v LLVM && ! -v KCFLAGS && ! -v KCONFIG_CONFIG && "$CC" == /usr/bin/gcc ]]
printf 'Debian source/config acquisition and baseline protection tests passed.\n'
