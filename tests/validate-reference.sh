#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REFERENCE="$REPO_ROOT/profiles/reference/debian-6.12.107-amd64.config"

# shellcheck source=/dev/null
source "$REPO_ROOT/profiles/thinkpad.conf"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/validate.sh"

[[ -f "$REFERENCE" ]] || {
    printf 'ERROR: Missing T590 reference config: %s\n' "$REFERENCE" >&2
    exit 1
}

failed=0
declare -A protected_symbols=()
for symbol in "${PRESERVE_ENABLED[@]}"; do
    if [[ -n "${protected_symbols[$symbol]:-}" ]]; then
        printf 'ERROR: Duplicate protected symbol CONFIG_%s.\n' "$symbol" >&2
        failed=1
    fi
    protected_symbols["$symbol"]=1

    # The Debian state is protected, including disabled or version-absent
    # drivers; hardware inventory must never select another source baseline.

done


for symbol in "${PRESERVE_BASELINE_STATE[@]}"; do
    if [[ -n "${protected_symbols[$symbol]:-}" ]]; then
        printf 'ERROR: Duplicate protected symbol CONFIG_%s.\n' "$symbol" >&2
        exit 1
    fi
    protected_symbols["$symbol"]=1
done

declare -A removed_symbols=()
for symbol in "${DISABLE_NON_THINKPAD_PLATFORM[@]}"; do
    if [[ -n "${removed_symbols[$symbol]:-}" ]]; then
        printf 'ERROR: Duplicate removal symbol CONFIG_%s.\n' "$symbol" >&2
        failed=1
    fi
    removed_symbols["$symbol"]=1

    if [[ -n "${protected_symbols[$symbol]:-}" ]]; then
        printf 'ERROR: CONFIG_%s is both protected and removed.\n' "$symbol" >&2
        failed=1
    fi


done

for symbol in X86_64 THINKPAD_ACPI DRM_I915 MOUSE_PS2 RMI4_SMB; do
    validate_enabled_any "$REFERENCE" "$symbol" >/dev/null || failed=1
done
validate_enabled_bool "$REFERENCE" PREEMPT_VOLUNTARY >/dev/null || failed=1
validate_disabled "$REFERENCE" PREEMPT_RT >/dev/null || failed=1
(( failed == 0 )) || exit 1

printf 'ThinkPad reference validation passed (%d protected, %d audited removals).\n' \
    "${#protected_symbols[@]}" "${#DISABLE_NON_THINKPAD_PLATFORM[@]}"
