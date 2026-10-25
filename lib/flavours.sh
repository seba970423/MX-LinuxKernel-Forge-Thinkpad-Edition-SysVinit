#!/usr/bin/env bash
# Optional features on Debian sources. Patch inputs are bundled and pinned;
# neither selection downloads CachyOS recipes or another toolchain.

mx_validate_flavour_selection() {
    case "${KF_PREEMPT_RT:-no}:${KF_BORE:-no}" in
        no:no|yes:no|no:yes|yes:yes) ;;
        *) printf 'ERROR: Invalid RT/BORE selection.\n' >&2; return 1 ;;
    esac
    if [[ "${KF_PREEMPT_RT:-no}" == yes || "${KF_BORE:-no}" == yes ]]; then
        [[ "${KF_DEBIAN_SERIES:-}" == 6.12 ]] || {
            printf 'ERROR: Optional RT/BORE support is currently available for Debian 6.12 sources only.\n' >&2
            return 1
        }
    fi
}

mx_choose_kernel_flavour() {
    KF_PREEMPT_RT=no
    KF_BORE=no
    KF_FLAVOUR_SUFFIX=''
    printf '\n==> Optional Debian kernel features (Enter keeps standard Debian).\n'
    case "$KF_DEBIAN_SERIES" in
        6.12)
            if ask_yes_no 'Enable PREEMPT_RT real-time preemption?' no; then KF_PREEMPT_RT=yes; fi
            if ask_yes_no 'Apply the BORE scheduler patch?' no; then KF_BORE=yes; fi
            ;;
        6.1) printf '==> Debian 6.1 keeps the standard flavour; optional RT/BORE patches are provided for 6.12.\n' ;;
        *) printf 'ERROR: Unsupported Debian kernel series.\n' >&2; return 1 ;;
    esac
    mx_validate_flavour_selection || return 1
    if [[ "$KF_PREEMPT_RT" == yes ]]; then mx_checked_flavour_file rt >/dev/null || return 1; fi
    if [[ "$KF_BORE" == yes ]]; then mx_checked_flavour_file bore >/dev/null || return 1; fi
    case "$KF_PREEMPT_RT:$KF_BORE" in
        yes:no) KF_FLAVOUR_SUFFIX=-rt ;;
        no:yes) KF_FLAVOUR_SUFFIX=-bore ;;
        yes:yes) KF_FLAVOUR_SUFFIX=-rt-bore ;;
    esac
    KF_VARIANT="linux-debian-$KF_DEBIAN_SERIES$KF_FLAVOUR_SUFFIX"
    printf '==> Selected features: PREEMPT_RT=%s, BORE=%s\n' "$KF_PREEMPT_RT" "$KF_BORE"
}

mx_debian_config_filename() {
    if [[ "${KF_PREEMPT_RT:-no}" == yes ]]; then
        printf 'config.amd64_rt_amd64.xz\n'
    else
        printf 'config.amd64_none_amd64.xz\n'
    fi
}

mx_checked_flavour_file() {
    local kind="$1" filename expected root actual
    root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../patches" && pwd)" || return 1
    case "$kind" in
        rt)
            case "${KF_DEBIAN_VERSION:-}" in
                6.12.107-1)
                    filename=debian-6.12.107-1-rt.tar.xz
                    expected=5438f4cc417e318580a65473bc5a317c4267ac5839f9e73fda98c5986d72b6c0 ;;
                6.12.111-1|6.12.113-1)
                    filename=debian-6.12.111-113-rt.tar.xz
                    expected=7d96e5e2dee684a5096cb79d8897d9e9f3395c28e12d24373711ad616d33436b ;;
                *)
                    printf 'ERROR: No verified Debian RT patch series for %s. Update KernelForge or choose standard/BORE without RT.\n' "${KF_DEBIAN_VERSION:-unknown}" >&2
                    return 1 ;;
            esac ;;
        bore)
            filename=linux-6.12-bore-7.0.0.patch
            expected=4362579319376f47d0c38e2aa30347082d73e6f122d32442def194462243e2c6 ;;
        *) printf 'ERROR: Unknown flavour patch.\n' >&2; return 1 ;;
    esac
    [[ -f "$root/$filename" && ! -L "$root/$filename" ]] || {
        printf 'ERROR: Missing bundled %s patch input. Update the complete repository and retry.\n' "$kind" >&2
        return 1
    }
    actual="$(sha256sum -- "$root/$filename")" || return 1
    [[ "${actual%% *}" == "$expected" ]] || {
        printf 'ERROR: Bundled %s patch checksum mismatch.\n' "$kind" >&2
        return 1
    }
    printf '%s\n' "$root/$filename"
}

mx_apply_patch_file() {
    local tree="$1" file="$2"
    # Allow line offsets, but never fuzzy context, reverse application or an
    # interactive attempt to guess which file/version should receive a patch.
    patch --directory="$tree" --strip=1 --batch --forward --fuzz=0 \
        --no-backup-if-mismatch --dry-run --input="$file" || return 1
    patch --directory="$tree" --strip=1 --batch --forward --fuzz=0 \
        --no-backup-if-mismatch --input="$file" || return 1
}

mx_apply_rt_series() {
    local tree="$1" directory="$2" expected_count="$3" entry count=0
    [[ -f "$directory/series" && ! -L "$directory/series" ]] || return 1
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" && "$entry" != \#* ]] || continue
        [[ "$entry" =~ ^[0-9]{4}-[A-Za-z0-9_.-]+\.patch$ &&
           -f "$directory/$entry" && ! -L "$directory/$entry" ]] || {
            printf 'ERROR: Invalid Debian RT patch series entry.\n' >&2
            return 1
        }
        mx_apply_patch_file "$tree" "$directory/$entry" || return 1
        count=$((count + 1))
    done <"$directory/series"
    [[ "$count" == "$expected_count" && "$count" -gt 0 ]] || { printf 'ERROR: Incomplete Debian RT patch series.\n' >&2; return 1; }
}

mx_prepare_flavour_sources() {
    local package_dir="$1" tree="$2" log_file="$3" rt_file='' bore_file='' rt_count
    mx_validate_flavour_selection || return 1
    # Validate every selected input before modifying the extracted source.
    if [[ "${KF_PREEMPT_RT:-no}" == yes ]]; then rt_file="$(mx_checked_flavour_file rt)" || return 1; fi
    if [[ "${KF_BORE:-no}" == yes ]]; then bore_file="$(mx_checked_flavour_file bore)" || return 1; fi
    if [[ -n "$rt_file" ]]; then
        [[ ! -e "$package_dir/debian-rt" && ! -L "$package_dir/debian-rt" ]] || return 1
        cp -- "$rt_file" "$package_dir/downloads/" || return 1
        rt_count="$(tar --extract --to-stdout --file "$rt_file" debian-rt/series | awk 'NF && $0 !~ /^#/ {n++} END {print n}')" || return 1
        tar --extract --file "$rt_file" --directory "$package_dir" --no-same-owner --no-same-permissions || return 1
        kernelforge_run_logged 'Applying Debian real-time support' "$log_file" \
            mx_apply_rt_series "$tree" "$package_dir/debian-rt" "$rt_count" || return 1
    fi
    if [[ -n "$bore_file" ]]; then
        cp -- "$bore_file" "$package_dir/downloads/" || return 1
        kernelforge_run_logged 'Applying BORE scheduler support' "$log_file" \
            mx_apply_patch_file "$tree" "$bore_file" || return 1
    fi
    {
        printf 'preempt_rt=%s\nbore=%s\n' "${KF_PREEMPT_RT:-no}" "${KF_BORE:-no}"
        printf 'configuration=%s\n' "$(mx_debian_config_filename)"
        if [[ -n "$rt_file" ]]; then printf 'rt_series=Debian-%s-rt15\n' "$KF_DEBIAN_VERSION"; sha256sum -- "$rt_file"; fi
        if [[ -n "$bore_file" ]]; then printf 'bore_version=7.0.0\n'; sha256sum -- "$bore_file"; fi
    } >"$package_dir/.kernelforge-flavour"
}

mx_configure_flavour() {
    local tree="$1"
    if [[ "${KF_PREEMPT_RT:-no}" == yes ]]; then
        "$tree/scripts/config" --file "$tree/.config" --enable PREEMPT_RT || return 1
    fi
    if [[ "${KF_BORE:-no}" == yes ]]; then
        kconfig_require_symbol "$tree" SCHED_BORE || return 1
        "$tree/scripts/config" --file "$tree/.config" --enable SCHED_BORE || return 1
    fi
}
