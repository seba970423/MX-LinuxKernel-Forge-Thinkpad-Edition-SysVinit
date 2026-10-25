#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$REPO_ROOT/lib/profile.sh"
source "$REPO_ROOT/lib/policy.sh"
source "$REPO_ROOT/lib/kconfig.sh"
source "$REPO_ROOT/lib/validate.sh"
source "$REPO_ROOT/lib/debug-compression.sh"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-tuning-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
TREE="$TEST_TMPDIR/tree"
BASELINE="$TEST_TMPDIR/baseline"
OUTPUT="$TEST_TMPDIR/output"
mkdir -p "$TREE/scripts"
touch "$TREE/Makefile"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >/dev/null 2>&1; then fail "Unexpected success: $*"; fi; }
load_profile "$REPO_ROOT" >/dev/null

# Stand-in for the external kernel scripts/config command.
cat > "$TREE/scripts/config" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
file="$2" operation="$3" symbol="$4"
sed -i -E "/^(CONFIG_${symbol}=.*|# CONFIG_${symbol} is not set)$/d" "$file"
case "$operation" in
    --enable) printf 'CONFIG_%s=y\n' "$symbol" >> "$file" ;;
    --disable) printf '# CONFIG_%s is not set\n' "$symbol" >> "$file" ;;
    *) exit 1 ;;
esac
SCRIPT
chmod +x "$TREE/scripts/config"
cat > "$TREE/Kconfig" <<'KCONFIG'
config SCHED_AUTOGROUP
    bool
menuconfig TRANSPARENT_HUGEPAGE
    bool
config TRANSPARENT_HUGEPAGE_MADVISE
    bool
config TRANSPARENT_HUGEPAGE_ALWAYS
    bool
config TRANSPARENT_HUGEPAGE_NEVER
    bool
config HZ
    int
config HZ_1000
    bool
KCONFIG
cat > "$BASELINE" <<'CONFIG'
# CONFIG_PREEMPT_RT is not set
# CONFIG_SCHED_ALT is not set
# CONFIG_SCHED_AUTOGROUP is not set
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
# CONFIG_TRANSPARENT_HUGEPAGE_MADVISE is not set
# CONFIG_TRANSPARENT_HUGEPAGE_NEVER is not set
CONFIG_TRANSPARENT_HUGEPAGE_DEFERRED_SPLIT=y
CONFIG_HZ_1000=y
CONFIG_HZ=1000
CONFIG_HAVE_ARCH_TRANSPARENT_HUGEPAGE=y
CONFIG_USB_HID=y
CONFIG_DRM_I915=m
CONFIG_HIBERNATION=y
CONFIG_BLK_DEV_NVME=m

CONFIG

# Only the external olddefconfig command is mocked. It models a symbol whose
# dependencies are unsatisfied even though its declaration exists in Kconfig.
make() {
    local config="$TREE/.config" arg
    for arg in "$@"; do
        [[ "$arg" != KCONFIG_CONFIG=* ]] || config="${arg#KCONFIG_CONFIG=}"
    done
    [[ "${PROBE_FAIL:-no}" != yes ]] || return 2
    if [[ "${BLOCK_AUTOGROUP:-no}" == yes ]]; then
        "$TREE/scripts/config" --file "$config" --disable SCHED_AUTOGROUP
    fi
    if [[ "${BLOCK_THP:-no}" == yes || "$(kconfig_state "$config" PREEMPT_RT)" == y ]]; then
        "$TREE/scripts/config" --file "$config" --disable TRANSPARENT_HUGEPAGE
        "$TREE/scripts/config" --file "$config" --disable TRANSPARENT_HUGEPAGE_MADVISE
    fi
}
reset_config() { cp "$BASELINE" "$TREE/.config"; }
check_preserved() {
    cmp "$BASELINE" "$TREE/.config" || fail 'Declined tuning changed baseline.'
    validate_tick_frequency "$BASELINE" "$TREE/.config" >/dev/null
}

for answers in $'upstream\nn\nn' $'\n\n\n' ''; do
    reset_config
    resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< "$answers" > "$OUTPUT"
    [[ "$AUTOGROUP_SUPPORTED" == yes && "$THP_SUPPORTED" == yes ]] || fail 'Supported prompts missing.'
    [[ "$ENABLE_AUTOGROUP" == no && "$ENABLE_THP_MADVISE" == no ]] || fail 'Default enabled tuning.'
    kconfig_apply_optional_tuning "$TREE"
    check_preserved
done
resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 < /dev/null > "$OUTPUT"
kconfig_apply_optional_tuning "$TREE"
check_preserved

# Enabled baselines are preserved as well; no does not mean disable.
sed -i 's/# CONFIG_SCHED_AUTOGROUP is not set/CONFIG_SCHED_AUTOGROUP=y/' "$BASELINE"
reset_config
resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< $'upstream\nn\nn' > "$OUTPUT"
kconfig_apply_optional_tuning "$TREE"
check_preserved
sed -i 's/CONFIG_SCHED_AUTOGROUP=y/# CONFIG_SCHED_AUTOGROUP is not set/' "$BASELINE"

# A supported but disabled THP baseline stays disabled on no/Enter.
cp "$BASELINE" "$TEST_TMPDIR/enabled-baseline"
sed -i '/TRANSPARENT_HUGEPAGE/d' "$BASELINE"
printf '# CONFIG_TRANSPARENT_HUGEPAGE is not set\n' >> "$BASELINE"
reset_config
resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< $'upstream\nn\nn' > "$OUTPUT"
[[ "$THP_SUPPORTED" == yes ]] || fail 'Disabled baseline was mistaken for unsupported THP.'
kconfig_apply_optional_tuning "$TREE"
check_preserved
cp "$TEST_TMPDIR/enabled-baseline" "$BASELINE"

for answers in $'upstream\ny\nn' $'upstream\nn\ny' $'upstream\ny\ny'; do
    reset_config
    resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< "$answers" > "$OUTPUT"
    cmp "$BASELINE" "$TREE/.config" || fail 'Support probing modified real config.'
    kconfig_apply_optional_tuning "$TREE"
    make -C "$TREE" olddefconfig
    validate_tick_frequency "$BASELINE" "$TREE/.config" >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" USB_HID >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" BLK_DEV_NVME >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" HIBERNATION >/dev/null
    validate_preserved "$BASELINE" "$TREE/.config" TRANSPARENT_HUGEPAGE_DEFERRED_SPLIT >/dev/null
done

# An unsupported prompt must not consume the next answer.
reset_config
printf 'upstream\ny\nsentinel\n' > "$TEST_TMPDIR/answers"
exec 3< "$TEST_TMPDIR/answers"
"$TREE/scripts/config" --file "$TREE/.config" --enable SCHED_ALT
resolve_kernel_tuning_policy "$TREE" linux-fixture-alt <&3 > "$OUTPUT"
read -r remaining <&3
exec 3<&-
[[ "$AUTOGROUP_SUPPORTED" == no && "$ENABLE_AUTOGROUP" == no && "$ENABLE_THP_MADVISE" == yes && "$remaining" == sentinel ]] || fail 'BMQ prompt consumed wrong input.'
! grep -q 'Enable scheduler autogrouping?' "$OUTPUT" || fail 'BMQ showed autogroup prompt.'
kconfig_apply_optional_tuning "$TREE"
validate_tick_frequency "$BASELINE" "$TREE/.config" >/dev/null

for variant in linux-fixture-rt linux-fixture-rt linux-debian-6.12; do
    reset_config
    "$TREE/scripts/config" --file "$TREE/.config" --enable PREEMPT_RT
    make -C "$TREE" olddefconfig
    cp "$TREE/.config" "$TEST_TMPDIR/rt-baseline"
    resolve_kernel_tuning_policy "$TREE" "$variant" <<< $'upstream\ny' > "$OUTPUT"
    [[ "$AUTOGROUP_SUPPORTED" == yes && "$THP_SUPPORTED" == no && "$ENABLE_AUTOGROUP" == yes && "$ENABLE_THP_MADVISE" == no ]] || fail 'RT support detection failed.'
    ! grep -q 'Enable transparent hugepages' "$OUTPUT" || fail 'RT showed THP prompt.'
    kconfig_apply_optional_tuning "$TREE"
    validate_tick_frequency "$TEST_TMPDIR/rt-baseline" "$TREE/.config" >/dev/null
done
# Alternative scheduling is excluded even under a renamed variant.
reset_config
"$TREE/scripts/config" --file "$TREE/.config" --enable SCHED_ALT
kconfig_detect_tuning_support "$TREE" linux-custom
[[ "$AUTOGROUP_SUPPORTED" == no ]] || fail 'Alternative scheduler guard failed.'

reset_config
BLOCK_AUTOGROUP=yes BLOCK_THP=yes resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< 'upstream' > "$OUTPUT"
[[ "$AUTOGROUP_SUPPORTED" == no && "$THP_SUPPORTED" == no ]] || fail 'Dependency-blocked symbols were offered.'
! grep -q 'Enable scheduler\|Enable transparent' "$OUTPUT" || fail 'Unavailable prompt appeared.'
kconfig_apply_optional_tuning "$TREE"
check_preserved
PROBE_FAIL=yes expect_failure resolve_kernel_tuning_policy "$TREE" linux-debian-6.12
cmp "$BASELINE" "$TREE/.config" || fail 'Failed support probe modified config.'

# Missing declarations are skipped rather than synthesized.
mv "$TREE/Kconfig" "$TEST_TMPDIR/Kconfig"
printf 'config HZ\n    int\nconfig HZ_1000\n    bool\n' > "$TREE/Kconfig"
resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< 'upstream' > "$OUTPUT"
[[ "$AUTOGROUP_SUPPORTED" == no && "$THP_SUPPORTED" == no ]] || fail 'Missing feature was offered.'
mv "$TEST_TMPDIR/Kconfig" "$TREE/Kconfig"

# Dependency resolution dropping a requested setting must fail validation.
reset_config
resolve_kernel_tuning_policy "$TREE" linux-debian-6.12 <<< $'upstream\ny\ny' > "$OUTPUT"
kconfig_apply_optional_tuning "$TREE"
"$TREE/scripts/config" --file "$TREE/.config" --disable SCHED_AUTOGROUP
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"
"$TREE/scripts/config" --file "$TREE/.config" --enable SCHED_AUTOGROUP
"$TREE/scripts/config" --file "$TREE/.config" --disable TRANSPARENT_HUGEPAGE_MADVISE
expect_failure validate_tick_frequency "$BASELINE" "$TREE/.config"

# Both production launchers use the same Debian preparation/configuration flow.
for entry in builder.sh builder-dry-run.sh; do
    (
        source "$REPO_ROOT/lib/build.sh"
        eval "$(awk '/^main\(\) \{/ {printing=1} /^if \[\[/ {printing=0} printing' "$REPO_ROOT/$entry")"
        mx_require_build_user() { :; }
        mx_require_host() { :; }
        mx_ensure_base_dependencies() { :; }
        mx_validate_toolchain_features() { :; }
        require_build_commands() { :; }
        detect_hardware() { CPU_VENDOR=intel; }
        print_hardware_summary() { :; }
        mx_resolve_debian_kernel() { KF_VARIANT=linux-debian-6.12; printf 'TEST: kernel selected\n'; }
        prompt_kernel_name() { printf 'mx-thinkpad-debian\n'; }
        prepare_debian_source() {
            mkdir -p "$1"
            : >"$1/.kernelforge-toolchain-env"
            cp "$TREE/.config" "$1/config"
            printf 'TEST: sources prepared\n' >&2
            printf '%s\n' "$TREE"
        }
        ask_compile() { return 1; }
        mktemp() {
            if [[ "$*" == *--tmpdir* ]]; then
                mkdir -p "$TEST_TMPDIR/work"
                printf '%s\n' "$TEST_TMPDIR/work"
            else command mktemp "$@"; fi
        }
        kconfig_apply_profile() { :; }
        kconfig_apply_policy() {
            kconfig_apply_tick_frequency "$1"
            kconfig_apply_optional_tuning "$1"
        }
        validate_kernel_policy() { validate_tick_frequency "$2" "$1/.config"; }
        reset_config
        main <<< $'y\ny\ny\nupstream\ny\ny' >"$OUTPUT" 2>&1
        selected=$(awk '/TEST: kernel selected/ {print NR; exit}' "$OUTPUT")
        prepared=$(awk '/TEST: sources prepared/ {print NR; exit}' "$OUTPUT")
        tuning=$(awk '/Optional tuning for/ {print NR; exit}' "$OUTPUT")
        [[ -n "$selected" && -n "$prepared" && -n "$tuning" && "$selected" -lt "$prepared" && "$prepared" -lt "$tuning" ]] || fail 'Tuning prompted before Debian sources were prepared.'
        grep -q 'Enable scheduler autogrouping?' "$OUTPUT" || fail 'Workflow missed autogrouping.'
        grep -q 'Enable transparent hugepages' "$OUTPUT" || fail 'Workflow missed THP.'
    )
done
printf 'Optional tuning tests passed (%s).\n' "$PROFILE_NAME"
