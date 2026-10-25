#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/flavours.sh"
source "$REPO_ROOT/lib/naming.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
KF_DEBIAN_VERSION=6.12.107-1
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >"$scratch/expected-error" 2>&1; then fail "Unexpected success: $*"; fi; }

# Independent answers, default decline, invalid input retry and input boundaries.
for combination in no:no yes:no no:yes yes:yes; do
    (
        KF_DEBIAN_SERIES=6.12
        first="${combination%:*}" second="${combination#*:}"
        case "$combination" in no:no) suffix='';; yes:no) suffix=-rt;; no:yes) suffix=-bore;; yes:yes) suffix=-rt-bore;; esac
        {
            mx_choose_kernel_flavour >"$scratch/prompts"
            read -r sentinel
        } <<< "$first"$'\n'"$second"$'\nsentinel'
        [[ "$KF_PREEMPT_RT:$KF_BORE" == "$combination" && "$sentinel" == sentinel ]] || fail 'Selections consumed the wrong answers.'
        [[ "$KF_VARIANT" == "linux-debian-6.12$suffix" ]] || fail 'Wrong workspace variant.'
        [[ "$(mx_default_kernel_name)" == "mx-thinkpad-debian$suffix" ]] || fail 'Flavour names would collide.'
        grep -q 'Enable PREEMPT_RT real-time preemption?' "$scratch/prompts" || fail 'RT prompt missing.'
        grep -q 'Apply the BORE scheduler patch?' "$scratch/prompts" || fail 'BORE prompt missing.'
    )
done
(
    KF_DEBIAN_SERIES=6.12
    mx_choose_kernel_flavour <<< $'\n\n' >/dev/null
    [[ "$KF_PREEMPT_RT:$KF_BORE" == no:no ]] || fail 'Defaults enabled optional features.'
    mx_choose_kernel_flavour </dev/null >/dev/null
    [[ "$KF_PREEMPT_RT:$KF_BORE" == no:no ]] || fail 'EOF enabled optional features.'
    mx_choose_kernel_flavour <<< $'invalid\ny\nn' >"$scratch/prompts"
    [[ "$KF_PREEMPT_RT:$KF_BORE" == yes:no ]] || fail 'Invalid input was not retried.'
    grep -q 'Please answer yes or no' "$scratch/prompts" || fail 'Invalid answer was accepted.'
    KF_DEBIAN_SERIES=6.1
    { mx_choose_kernel_flavour >/dev/null; read -r sentinel; } <<< sentinel
    [[ "$KF_PREEMPT_RT:$KF_BORE" == no:no && "$sentinel" == sentinel ]] || fail 'Unsupported series consumed a feature answer.'
    KF_PREEMPT_RT=yes
    expect_failure mx_validate_flavour_selection
    KF_DEBIAN_SERIES=6.12 KF_PREEMPT_RT=invalid
    expect_failure mx_validate_flavour_selection
)

# Every selected feature must survive, and declined features must stay absent.
for combination in no:no yes:no no:yes yes:yes; do
    KF_PREEMPT_RT="${combination%:*}" KF_BORE="${combination#*:}"
    printf 'CONFIG_DRM_I915=m\nCONFIG_MOUSE_PS2=m\nCONFIG_RMI4_SMB=m\nCONFIG_GENERIC_CPU=y\n' >"$scratch/config"
    if [[ "$KF_PREEMPT_RT" == yes ]]; then printf 'CONFIG_PREEMPT_RT=y\n'; else printf '# CONFIG_PREEMPT_RT is not set\nCONFIG_PREEMPT_VOLUNTARY=y\n'; fi >>"$scratch/config"
    if [[ "$KF_BORE" == yes ]]; then printf 'CONFIG_SCHED_BORE=y\n'; else printf '# CONFIG_SCHED_BORE is not set\n'; fi >>"$scratch/config"
    cp "$scratch/config" "$scratch/baseline"
    mx_validate_debian_config "$scratch/baseline" "$scratch/config" >/dev/null
    for symbol in PREEMPT_RT SCHED_BORE DRM_I915 RMI4_SMB; do
        cp "$scratch/baseline" "$scratch/config"
        sed -i -E "/^(CONFIG_${symbol}=.*|# CONFIG_${symbol} is not set)$/d" "$scratch/config"
        if grep -qx "CONFIG_${symbol}=y" "$scratch/baseline"; then
            printf '# CONFIG_%s is not set\n' "$symbol" >>"$scratch/config"
        else printf 'CONFIG_%s=y\n' "$symbol" >>"$scratch/config"; fi
        expect_failure mx_validate_debian_config "$scratch/baseline" "$scratch/config"
    done
done
KF_PREEMPT_RT=no KF_BORE=no

# The shipped patch inputs have the pinned bytes; archives contain only the
# original Debian series and its regular patch files, with no executable data.
mx_checked_flavour_file rt >/dev/null
mx_checked_flavour_file bore >/dev/null
(
    for version in 6.12.111-1 6.12.113-1; do KF_DEBIAN_VERSION="$version" mx_checked_flavour_file rt >/dev/null; done
    KF_DEBIAN_VERSION=6.12.999-1
    expect_failure mx_checked_flavour_file rt
)
python3 - "$REPO_ROOT/patches/debian-6.12.107-1-rt.tar.xz" "$REPO_ROOT/patches/debian-6.12.111-113-rt.tar.xz" <<'PYTHON'
from pathlib import PurePosixPath
import sys
import tarfile
for filename in sys.argv[1:]:
    with tarfile.open(filename) as archive:
        members = archive.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            assert member.isfile() and len(path.parts) == 2 and path.parts[0] == 'debian-rt'
            assert '..' not in path.parts and member.mode == 0o644
        series = archive.extractfile('debian-rt/series').read().decode().splitlines()
        assert len(series) in (42,43) and len(members) == len(series) + 1
        assert all('debian-rt/' + name in archive.getnames() for name in series)
PYTHON

# Tampering with either selected input stops before RT extraction or patching.
mkdir -p "$scratch/isolated/lib" "$scratch/isolated/patches" "$scratch/work/downloads" "$scratch/tree"
cp "$REPO_ROOT/lib/flavours.sh" "$scratch/isolated/lib/"
cp "$REPO_ROOT/patches/"* "$scratch/isolated/patches/"
(
    source "$scratch/isolated/lib/flavours.sh"
    KF_DEBIAN_SERIES=6.12 KF_PREEMPT_RT=yes KF_BORE=yes
    printf 'tampered\n' >>"$scratch/isolated/patches/linux-6.12-bore-7.0.0.patch"
    expect_failure mx_prepare_flavour_sources "$scratch/work" "$scratch/tree" "$scratch/prepare.log"
    [[ ! -e "$scratch/work/debian-rt" ]] || fail 'RT was applied before BORE integrity checking.'
)

# Native patch behaviour: successful application, no reverse/reapplication,
# rejection before mutation, and no fuzzy match for changed context.
mkdir -p "$scratch/patch-tree"
printf 'one\ntwo\nthree\nfour\nfive\n' >"$scratch/patch-tree/sample"
cat >"$scratch/change.patch" <<'PATCH'
--- a/sample
+++ b/sample
@@ -1,5 +1,5 @@
 one
 two
-three
+changed
 four
 five
PATCH
mx_apply_patch_file "$scratch/patch-tree" "$scratch/change.patch" >"$scratch/patch-log"
grep -qx changed "$scratch/patch-tree/sample" || fail 'Patch not applied.'
expect_failure mx_apply_patch_file "$scratch/patch-tree" "$scratch/change.patch"
printf 'different\ntwo\nthree\nfour\nfive\n' >"$scratch/patch-tree/sample"
cp "$scratch/patch-tree/sample" "$scratch/before"
expect_failure mx_apply_patch_file "$scratch/patch-tree" "$scratch/change.patch"
cmp "$scratch/before" "$scratch/patch-tree/sample" || fail 'Failed dry-run changed source.'
[[ ! -e "$scratch/patch-tree/sample.rej" ]] || fail 'Dry-run left a rejected source file.'
printf 'Independent RT/BORE prompts, patch integrity and flavour validation tests passed.\n'
