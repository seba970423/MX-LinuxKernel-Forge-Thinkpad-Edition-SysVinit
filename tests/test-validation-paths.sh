#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REFERENCE="$REPO_ROOT/profiles/reference/thinkpad-t590-cachyos-7.1.8.config"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-validation-test.XXXXXX)"
BASELINE="$TEST_TMPDIR/baseline.config"
FINAL="$TEST_TMPDIR/final.config"

trap 'rm -rf -- "$TEST_TMPDIR"' EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/profiles/thinkpad.conf"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/kconfig.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/validate.sh"

cp "$REFERENCE" "$BASELINE"
cp "$REFERENCE" "$FINAL"

# Model the profile changes after olddefconfig without requiring a complete
# kernel source tree in this unit test.
sed -i \
    -e 's/^# CONFIG_X86_NATIVE_CPU is not set$/CONFIG_X86_NATIVE_CPU=y/' \
    -e 's/^CONFIG_NO_HZ_FULL=y$/# CONFIG_NO_HZ_FULL is not set/' \
    -e 's/^# CONFIG_NO_HZ_IDLE is not set$/CONFIG_NO_HZ_IDLE=y/' \
    "$FINAL"

for symbol in "${DISABLE_NON_THINKPAD_PLATFORM[@]}"; do
    sed -i -E \
        "s/^CONFIG_${symbol}=[ym]$/# CONFIG_${symbol} is not set/" \
        "$FINAL"
done

CPU_VENDOR="intel"
KEEP_KVM="yes"
KEEP_INTEL_TDX="yes"
KEEP_AMD_SEV="yes"
KERNEL_HZ="upstream"
KEEP_NVME_FABRICS="yes"
KEEP_NVME_TARGET="yes"

mkdir -p "$TEST_TMPDIR/tree"
cp "$FINAL" "$TEST_TMPDIR/tree/.config"
validate_kernel_policy "$TEST_TMPDIR/tree" "$BASELINE" >/dev/null

# RT-style absence of THP is preserved, not forced on.
sed -i \
    -e 's/^# CONFIG_PREEMPT_RT is not set$/CONFIG_PREEMPT_RT=y/' \
    -e '/^CONFIG_TRANSPARENT_HUGEPAGE/d' \
    -e '/^# CONFIG_TRANSPARENT_HUGEPAGE/d' \
    "$BASELINE" "$TEST_TMPDIR/tree/.config"
validate_kernel_policy "$TEST_TMPDIR/tree" "$BASELINE" >/dev/null

cp "$REFERENCE" "$BASELINE"
cp "$FINAL" "$TEST_TMPDIR/tree/.config"
CPU_VENDOR="intel"
KEEP_KVM="yes"
KEEP_INTEL_TDX="yes"
KEEP_AMD_SEV="yes"
KERNEL_HZ="upstream"
KEEP_NVME_FABRICS="yes"
KEEP_NVME_TARGET="yes"
validate_kernel_policy "$TEST_TMPDIR/tree" "$BASELINE" >/dev/null

# Exercise the explicit-removal validation branch.
sed -i \
    -e 's/^CONFIG_KVM_INTEL=m$/# CONFIG_KVM_INTEL is not set/' \
    -e 's/^CONFIG_KVM_INTEL_TDX=y$/# CONFIG_KVM_INTEL_TDX is not set/' \
    -e 's/^CONFIG_NVME_FABRICS=m$/# CONFIG_NVME_FABRICS is not set/' \
    -e 's/^CONFIG_NVME_RDMA=m$/# CONFIG_NVME_RDMA is not set/' \
    -e 's/^CONFIG_NVME_FC=m$/# CONFIG_NVME_FC is not set/' \
    -e 's/^CONFIG_NVME_TCP=m$/# CONFIG_NVME_TCP is not set/' \
    -e 's/^CONFIG_NVME_TARGET=m$/# CONFIG_NVME_TARGET is not set/' \
    "$TEST_TMPDIR/tree/.config"

KEEP_KVM="no"
KEEP_INTEL_TDX="no"
KEEP_NVME_FABRICS="no"
KEEP_NVME_TARGET="no"
validate_kernel_policy "$TEST_TMPDIR/tree" "$BASELINE" >/dev/null

# A variant may intentionally disable a baseline-state facility. That disabled
# state is valid as long as KernelForge leaves it unchanged.
sed -i 's/^CONFIG_HIBERNATION=y$/# CONFIG_HIBERNATION is not set/' "$BASELINE"
sed -i 's/^CONFIG_HIBERNATION=y$/# CONFIG_HIBERNATION is not set/' \
    "$TEST_TMPDIR/tree/.config"
validate_kernel_policy "$TEST_TMPDIR/tree" "$BASELINE" >/dev/null

# Changing a baseline-state facility in either direction remains a regression.
sed -i 's/^# CONFIG_HIBERNATION is not set$/CONFIG_HIBERNATION=y/' \
    "$TEST_TMPDIR/tree/.config"
if validate_kernel_policy "$TEST_TMPDIR/tree" "$BASELINE" >/dev/null 2>&1; then
    printf 'ERROR: Changed baseline-state symbol passed validation.\n' >&2
    exit 1
fi
sed -i 's/^CONFIG_HIBERNATION=y$/# CONFIG_HIBERNATION is not set/' \
    "$TEST_TMPDIR/tree/.config"

# A protected driver that does not exist in an older/LTS source tree is valid.
validate_protected_symbol \
    "$TEST_TMPDIR/tree" "$BASELINE" "$TEST_TMPDIR/tree/.config" \
    FUTURE_THINKPAD_DRIVER >/dev/null

# If that symbol exists in the selected source but its baseline is disabled,
# protection is not being provided and validation must fail.
printf 'config FUTURE_THINKPAD_DRIVER\n    tristate "Future ThinkPad driver"\n' \
    >"$TEST_TMPDIR/tree/Kconfig"
printf '# CONFIG_FUTURE_THINKPAD_DRIVER is not set\n' >>"$BASELINE"
printf '# CONFIG_FUTURE_THINKPAD_DRIVER is not set\n' >>"$TEST_TMPDIR/tree/.config"
if validate_protected_symbol \
    "$TEST_TMPDIR/tree" "$BASELINE" "$TEST_TMPDIR/tree/.config" \
    FUTURE_THINKPAD_DRIVER >/dev/null 2>&1
then
    printf 'ERROR: Existing but disabled protected symbol passed validation.\n' >&2
    exit 1
fi

printf 'Validation path tests passed.\n'
