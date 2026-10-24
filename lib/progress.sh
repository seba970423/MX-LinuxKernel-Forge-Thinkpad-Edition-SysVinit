#!/usr/bin/env bash
# Only wrap unattended commands. APT transactions and all questions stay in
# the foreground so their prompts remain visible and stdin stays connected.

kernelforge_run_logged() {
    local label="$1" log_file="$2" interval="${KERNELFORGE_PROGRESS_INTERVAL:-30}"
    local reporter excerpt
    local -a status=()
    shift 2
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || {
        echo 'ERROR: KERNELFORGE_PROGRESS_INTERVAL must be a positive number of seconds.' >&2
        return 1
    }
    mkdir -p -- "$(dirname -- "$log_file")" || return 1
    reporter="$(dirname -- "${BASH_SOURCE[0]}")/progress.py"
    printf '==> %s...\n' "$label" >&2
    # This foreground pipeline has no detached timer to survive completion or
    # Ctrl+C. Preserve both exit codes even when the caller disables pipefail.
    if "$@" 2>&1 | python3 "$reporter" "$log_file" "$label" "$interval" >&2; then
        status=("${PIPESTATUS[@]}")
    else
        status=("${PIPESTATUS[@]}")
    fi
    if (( status[0] == 130 || status[1] == 130 )); then
        printf '==> %s interrupted. Log: %s\n' "$label" "$log_file" >&2
        return 130
    fi
    if (( status[0] == 143 || status[1] == 143 )); then
        printf '==> %s interrupted. Log: %s\n' "$label" "$log_file" >&2
        return 143
    fi
    if (( status[1] != 0 )); then
        printf 'ERROR: Could not record %s output; stopping.\n' "$label" >&2
        return 1
    fi
    if (( status[0] != 0 )); then
        printf 'ERROR: %s failed (exit %s). Full log: %s\n' "$label" "${status[0]}" "$log_file" >&2
        printf '%s\n' '--- Last 40 log lines ---' >&2
        # Finish reading before printing: the preparation tee may append this
        # excerpt to the same file. Never stream a file back into itself.
        excerpt="$(tail -n 40 -- "$log_file")" || true
        printf '%s\n' "$excerpt" >&2
        return "${status[0]}"
    fi
}
