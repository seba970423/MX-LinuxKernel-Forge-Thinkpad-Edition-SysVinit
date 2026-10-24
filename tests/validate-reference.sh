#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REFERENCE="$REPO_ROOT/profiles/reference/thinkpad-t590-cachyos-7.1.8.config"

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

    state="$(config_state "$REFERENCE" "$symbol")"
    if [[ "$state" != "y" && "$state" != "m" ]]; then
        printf 'ERROR: T590 reference does not enable CONFIG_%s (%s).\n' \
            "$symbol" "$state" >&2
        failed=1
    fi
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

    state="$(config_state "$REFERENCE" "$symbol")"
    if [[ "$state" == "absent" ]]; then
        printf 'ERROR: Non-ThinkPad platform audit symbol CONFIG_%s is absent from the reference.\n' \
            "$symbol" >&2
        failed=1
    fi
done

(( failed == 0 )) || exit 1

printf 'ThinkPad reference validation passed (%d protected, %d audited removals).\n' \
    "${#protected_symbols[@]}" "${#DISABLE_NON_THINKPAD_PLATFORM[@]}"
