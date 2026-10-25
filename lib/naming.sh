#!/usr/bin/env bash

mx_default_kernel_name() { printf 'mx-thinkpad-debian\n'; }

mx_valid_kernel_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9.+-]{0,47}$ ]]; }

prompt_kernel_name() {
    local default_name answer custom_name
    default_name="$(mx_default_kernel_name)"
    printf '\n==> Default kernel suffix: %s\n' "$default_name" >&2
    if ! read -r -p 'Rename this Debian-based kernel? [y/N]: ' answer; then answer=n; fi
    case "${answer:-n}" in
        y|Y|yes|YES|Yes)
            while true; do
                if ! read -r -p "Custom kernel name (without 'linux-'): " custom_name; then return 1; fi
                custom_name="${custom_name#linux-}"
                if mx_valid_kernel_name "$custom_name"; then printf '%s\n' "$custom_name"; return 0; fi
                printf 'Invalid name: use 1-48 lowercase letters, digits, ., + or -; start with a letter or digit.\n' >&2
            done ;;
        *) printf '%s\n' "$default_name" ;;
    esac
}

apply_custom_kernel_name() {
    local tree="$1" custom_name="$2"
    mx_valid_kernel_name "$custom_name" || { echo 'ERROR: Invalid kernel suffix.' >&2; return 1; }
    "$tree/scripts/config" --file "$tree/.config" --set-str LOCALVERSION "-$custom_name" || return 1
    "$tree/scripts/config" --file "$tree/.config" --disable LOCALVERSION_AUTO || return 1
    printf '==> Custom kernel suffix: %s\n' "$custom_name"
}
