#!/usr/bin/env bash

set -euo pipefail

validation_error() {
    printf 'VALIDATION ERROR: %s\n' "$*" >&2
    return 1
}

config_state() {
    local config="$1"
    local symbol="$2"

    if grep -q "^CONFIG_${symbol}=y$" "$config"; then
        printf 'y'
    elif grep -q "^CONFIG_${symbol}=m$" "$config"; then
        printf 'm'
    elif grep -q "^# CONFIG_${symbol} is not set$" "$config"; then
        printf 'n'
    else
        printf 'absent'
    fi
}

validate_disabled() {
    local config="$1"
    local symbol="$2"
    local state

    state="$(config_state "$config" "$symbol")"

    if [[ "$state" != "n" && "$state" != "absent" ]]; then
        validation_error \
            "CONFIG_${symbol} should be disabled, but resolved to '${state}'."
        return 1
    fi

    printf '    OK  CONFIG_%s disabled (%s)\n' "$symbol" "$state"
}

validate_enabled_bool() {
    local config="$1"
    local symbol="$2"
    local state

    state="$(config_state "$config" "$symbol")"

    if [[ "$state" != "y" ]]; then
        validation_error \
            "CONFIG_${symbol} should be enabled, but resolved to '${state}'."
        return 1
    fi

    printf '    OK  CONFIG_%s = y\n' "$symbol"
}

validate_enabled_any() {
    local config="$1"
    local symbol="$2"
    local state

    state="$(config_state "$config" "$symbol")"

    if [[ "$state" != "y" && "$state" != "m" ]]; then
        validation_error \
            "CONFIG_${symbol} should be enabled, but resolved to '${state}'."
        return 1
    fi

    printf '    OK  CONFIG_%s enabled as %s\n' "$symbol" "$state"
}

validate_preserved() {
    local baseline="$1"
    local config="$2"
    local symbol="$3"
    local before
    local after

    before="$(config_state "$baseline" "$symbol")"
    after="$(config_state "$config" "$symbol")"

    if [[ "$before" != "$after" ]]; then
        validation_error \
            "CONFIG_${symbol} changed unexpectedly: '${before}' -> '${after}'."
        return 1
    fi

    printf '    OK  CONFIG_%s preserved as %s\n' "$symbol" "$after"
}

validate_protected_symbol() {
    local tree="$1"
    local baseline="$2"
    local config="$3"
    local symbol="$4"
    local before

    before="$(config_state "$baseline" "$symbol")"

    if [[ "$before" == "y" || "$before" == "m" ]]; then
        validate_preserved "$baseline" "$config" "$symbol"
        return
    fi

    # Debian's disabled driver and transport choices are deliberate too.
    # Preserve them instead of forcing the old source provider's defaults.
    if ! kconfig_symbol_exists "$tree" "$symbol" && [[ "$before" == absent ]]; then
        printf '    OK  CONFIG_%s unavailable in this Debian kernel version\n' "$symbol"
    fi
    validate_preserved "$baseline" "$config" "$symbol"

}

validate_profile_invariants() {
    local config="$1"
    local symbol

    for symbol in "${REQUIRE_ENABLED_BOOL[@]}"; do
        validate_enabled_bool "$config" "$symbol" || return 1
    done

    for symbol in "${REQUIRE_DISABLED[@]}"; do
        validate_disabled "$config" "$symbol" || return 1
    done
}

# Compare complete symbol lines, including numeric values and choice members.
validate_config_group_preserved() {
    local baseline="$1" config="$2" pattern="$3" label="$4"
    local before after
    before="$(grep -E "$pattern" "$baseline" | LC_ALL=C sort || true)"
    after="$(grep -E "$pattern" "$config" | LC_ALL=C sort || true)"
    if [[ "$before" != "$after" ]]; then
        validation_error "$label changed unexpectedly."
        return 1
    fi
    printf '    OK  %s preserved\n' "$label"
}

validate_tick_frequency() {
    local baseline="$1" config="$2"
    local hz="${KERNEL_HZ:-upstream}"
    local line count=0

    case "$hz" in
        upstream)
            validate_config_group_preserved "$baseline" "$config" \
                '^(CONFIG_HZ(=[0-9]+|_[0-9]+=.*)|# CONFIG_HZ(_[0-9]+)? is not set)$' \
                'Upstream tick frequency' || return 1
            ;;
        100|250|300|1000)
            validate_enabled_bool "$config" "HZ_$hz" || return 1
            if ! grep -qx "CONFIG_HZ=$hz" "$config"; then
                validation_error "CONFIG_HZ did not resolve to requested frequency $hz."
                return 1
            fi
            while read -r line; do
                [[ -n "$line" ]] || continue
                count=$((count + 1))
            done < <(grep -E '^CONFIG_HZ_[0-9]+=y$' "$config" || true)
            if [[ "$count" != 1 ]]; then
                validation_error "Expected exactly one enabled HZ frequency choice, found $count."
                return 1
            fi
            printf '    OK  CONFIG_HZ = %s\n' "$hz"
            ;;
        *) validation_error "Invalid KERNEL_HZ: $hz"; return 1 ;;
    esac


    if [[ "${ENABLE_AUTOGROUP:-no}" == yes ]]; then
        validate_enabled_bool "$config" SCHED_AUTOGROUP || return 1
    else
        validate_config_group_preserved "$baseline" "$config" \
            '^(CONFIG_SCHED_AUTOGROUP=.*|# CONFIG_SCHED_AUTOGROUP is not set)$' \
            'Scheduler autogrouping' || return 1
    fi
    if [[ "${ENABLE_THP_MADVISE:-no}" == yes ]]; then
        validate_disabled "$config" PREEMPT_RT || return 1
        validate_enabled_bool "$config" TRANSPARENT_HUGEPAGE || return 1
        validate_enabled_bool "$config" TRANSPARENT_HUGEPAGE_MADVISE || return 1
        validate_disabled "$config" TRANSPARENT_HUGEPAGE_ALWAYS || return 1
        validate_disabled "$config" TRANSPARENT_HUGEPAGE_NEVER || return 1
    else
        validate_config_group_preserved "$baseline" "$config" \
            '^(CONFIG_TRANSPARENT_HUGEPAGE[A-Z0-9_]*=.*|# CONFIG_TRANSPARENT_HUGEPAGE[A-Z0-9_]* is not set)$' \
            'Transparent hugepage configuration' || return 1
    fi

}

validate_kernel_policy() {
    local tree="$1"
    local baseline="$2"
    local config="$tree/.config"

    [[ -f "$baseline" ]] || {
        validation_error "Baseline config does not exist: $baseline"
        return 1
    }

    [[ -f "$config" ]] || {
        validation_error "Resolved config does not exist: $config"
        return 1
    }

    printf '==> Validating resolved kernel configuration...\n'

    # Portable profile invariants.
    validate_profile_invariants "$config" || return 1

    # Universal ThinkPad userspace/hardware contract. The current build host
    # is intentionally irrelevant; every listed facility must be enabled by
    # upstream and remain untouched by KernelForge.
    local symbol
    for symbol in "${PRESERVE_ENABLED[@]}"; do
        validate_protected_symbol "$tree" "$baseline" "$config" "$symbol" || return 1
    done

    # Some general laptop facilities are deliberate variant policy choices.
    # Preserve the normalized upstream state without requiring it to be on.
    for symbol in "${PRESERVE_BASELINE_STATE[@]}"; do
        validate_preserved "$baseline" "$config" "$symbol" || return 1
    done

    # General-purpose features are preserved by default and removed only after
    # the user explicitly answers no.
    case "${CPU_VENDOR:-unknown}" in
        intel)
            if [[ "${KEEP_KVM:-yes}" == "yes" ]]; then
                validate_preserved "$baseline" "$config" KVM_INTEL || return 1
            else
                validate_disabled "$config" KVM_INTEL || return 1
            fi

            if [[ "${KEEP_INTEL_TDX:-yes}" == "yes" ]]; then
                validate_preserved "$baseline" "$config" KVM_INTEL_TDX || return 1
            else
                validate_disabled "$config" KVM_INTEL_TDX || return 1
            fi
            ;;
        amd)
            if [[ "${KEEP_KVM:-yes}" == "yes" ]]; then
                validate_preserved "$baseline" "$config" KVM_AMD || return 1
            else
                validate_disabled "$config" KVM_AMD || return 1
            fi

            if [[ "${KEEP_AMD_SEV:-yes}" == "yes" ]]; then
                validate_preserved "$baseline" "$config" KVM_AMD_SEV || return 1
            else
                validate_disabled "$config" KVM_AMD_SEV || return 1
            fi
            ;;
    esac

    validate_tick_frequency "$baseline" "$config" || return 1

    if [[ "${KEEP_NVME_FABRICS:-yes}" == "yes" ]]; then
        for symbol in NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP; do
            validate_preserved "$baseline" "$config" "$symbol" || return 1
        done
    else
        for symbol in NVME_FABRICS NVME_RDMA NVME_FC NVME_TCP; do
            validate_disabled "$config" "$symbol" || return 1
        done
    fi

    if [[ "${KEEP_NVME_TARGET:-yes}" == "yes" ]]; then
        validate_preserved "$baseline" "$config" NVME_TARGET || return 1
    else
        validate_disabled "$config" NVME_TARGET || return 1
    fi

    validate_preserved "$baseline" "$config" BLK_DEV_NVME || return 1

    # Other vendors' host firmware/platform drivers are the first deliberately
    # removed hardware class. Consumer HID/USB devices are not included here.
    for symbol in "${DISABLE_NON_THINKPAD_PLATFORM[@]}"; do
        validate_disabled "$config" "$symbol" || return 1
    done

    printf '==> Kernel policy validation passed.\n'
}

# These groups cover the areas implicated in the reported desktop/input issues.
# Compare against the original distribution config, including the first
# normalization, so a changed toolchain cannot silently redefine the baseline.
mx_validate_debian_config() {
    local baseline="$1" config="$2"
    validate_disabled "$config" PREEMPT_RT || return 1
    validate_config_group_preserved "$baseline" "$config" \
        '^(CONFIG_PREEMPT[A-Z0-9_]*=.*|# CONFIG_PREEMPT[A-Z0-9_]* is not set)$' \
        'Debian preemption settings' || return 1
    validate_config_group_preserved "$baseline" "$config" \
        '^(CONFIG_(MOUSE_PS2[A-Z0-9_]*|RMI4[A-Z0-9_]*|HID_RMI|I2C_HID[A-Z0-9_]*)=.*|# CONFIG_(MOUSE_PS2[A-Z0-9_]*|RMI4[A-Z0-9_]*|HID_RMI|I2C_HID[A-Z0-9_]*) is not set)$' \
        'Debian touchpad and TrackPoint transport settings' || return 1
    validate_config_group_preserved "$baseline" "$config" \
        '^(CONFIG_DRM_I915[A-Z0-9_]*=.*|# CONFIG_DRM_I915[A-Z0-9_]* is not set)$' \
        'Debian Intel graphics settings' || return 1
    validate_config_group_preserved "$baseline" "$config" \
        '^(CONFIG_(GENERIC_CPU|MCORE2|MATOM|MK8|MPSC|MBARCELONA|X86_64_VERSION|X86_NATIVE_CPU)=.*|# CONFIG_(GENERIC_CPU|MCORE2|MATOM|MK8|MPSC|MBARCELONA|X86_64_VERSION|X86_NATIVE_CPU) is not set)$' \
        'Debian CPU target' || return 1
}
