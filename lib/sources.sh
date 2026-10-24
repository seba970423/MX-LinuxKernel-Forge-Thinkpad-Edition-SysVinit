#!/usr/bin/env bash
# Native source acquisition. The upstream recipe supplies metadata and patches;
# Debian tools verify, extract and build it without makepkg or pacman.

source "$(dirname -- "${BASH_SOURCE[0]}")/progress.sh"

mx_recipe_metadata() {
    bash "$REPO_ROOT/lib/recipe.sh" metadata "$1"
}

mx_source_filename() {
    local entry="$1" name
    if [[ "$entry" != https://* && "$entry" != *::* && "$entry" == */* ]]; then
        echo 'ERROR: Local sources must have plain filenames.' >&2; return 1
    fi
    if [[ "$entry" == *::* ]]; then name="${entry%%::*}"; else name="${entry##*/}"; fi
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ && "$name" != '.' && "$name" != '..' ]] || {
        printf 'ERROR: Unsupported upstream source filename: %s\n' "$name" >&2; return 1;
    }
    printf '%s\n' "$name"
}

mx_verify_checksums() (
    local package_dir="$1" algorithm file i expected actual checked=0
    local -a source=() b2sums=() sha256sums=() sha512sums=() sha1sums=() md5sums=()
    source "$package_dir/.kernelforge-recipe"
    for algorithm in b2 sha256 sha512 sha1 md5; do
        local -n sums="${algorithm}sums"
        (( ${#sums[@]} > 0 )) || continue
        (( ${#sums[@]} == ${#source[@]} )) || {
            printf 'ERROR: Upstream %ssums/source count mismatch.\n' "$algorithm" >&2; return 1;
        }
        for i in "${!source[@]}"; do
            expected="${sums[$i]}"
            [[ "$expected" != SKIP ]] || continue
            file="$(mx_source_filename "${source[$i]}")" || return 1
            actual="$("${algorithm}sum" "$package_dir/$file")" || return 1
            actual="${actual%% *}"
            [[ "${actual,,}" == "${expected,,}" ]] || {
                printf 'ERROR: %s checksum mismatch: %s\n' "$algorithm" "$file" >&2; return 1;
            }
            ((checked+=1))
        done
    done
    (( checked > 0 )) || { echo 'ERROR: Upstream provided no checked sources.' >&2; return 1; }
)

mx_verify_signatures() (
    local package_dir="$1" entry name target status signer primary pin valid count=0
    local -a source=() validpgpkeys=()
    source "$package_dir/.kernelforge-recipe"
    (( ${#validpgpkeys[@]} > 0 )) || { echo 'ERROR: Missing pinned upstream PGP keys.' >&2; return 1; }
    for entry in "${source[@]}"; do
        name="$(mx_source_filename "$entry")" || return 1
        case "$name" in *.asc|*.sig|*.sign) ;; *) continue ;; esac
        target="${name%.*}"
        [[ -f "$package_dir/$target" ]] || { echo 'ERROR: Signature has no matching source.' >&2; return 1; }
        status="$(gpg --batch --status-fd=1 --verify "$package_dir/$name" "$package_dir/$target")" || return 1
        valid=0
        while read -r signer primary; do
            for pin in "${validpgpkeys[@]}"; do
                if [[ "${signer^^}" == "${pin^^}" || "${primary^^}" == "${pin^^}" ]]; then valid=1; fi
            done
        done < <(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print $3, $NF}' <<<"$status")
        (( valid == 1 )) || { echo 'ERROR: Signature does not match a pinned upstream fingerprint.' >&2; return 1; }
        ((count+=1))
    done
    (( count > 0 )) || { echo 'ERROR: No signed source archive was found.' >&2; return 1; }
)

mx_acquire_sources() (
    set -e
    local package_dir="$1" entry name url file tree
    local -a source=() validpgpkeys=()
    mx_recipe_metadata "$package_dir" >"$package_dir/.kernelforge-recipe"
    source "$package_dir/.kernelforge-recipe"
    [[ "$KF_SOURCE_TREE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || return 1
    [[ ! -e "$package_dir/src" ]] || { echo 'ERROR: Refusing to overwrite an existing source tree.' >&2; return 1; }
    local -A seen=()
    for entry in "${source[@]}"; do
        name="$(mx_source_filename "$entry")"
        [[ -z "${seen[$name]:-}" ]] || { echo 'ERROR: Duplicate upstream source filename.' >&2; return 1; }
        seen[$name]=1
        url="${entry#*::}"
        case "$url" in
            https://*)
                printf '==> Downloading %s\n' "$name" >&2
                kernelforge_run_logged 'Source download' "${KERNELFORGE_PREPARE_LOG:-$package_dir/.kernelforge-prepare.log}" \
                    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
                    --output "$package_dir/$name.part" "$url"
                mv -- "$package_dir/$name.part" "$package_dir/$name" ;;
            *)
                [[ "$entry" == "$name" && -f "$package_dir/$name" ]] || {
                    printf 'ERROR: Unsupported upstream source: %s\n' "$entry" >&2; return 1;
                } ;;
        esac
    done
    mx_verify_checksums "$package_dir"
    ensure_upstream_pgp_keys "$package_dir"
    kernelforge_run_logged 'Verifying source signatures' \
        "${KERNELFORGE_PREPARE_LOG:-$package_dir/.kernelforge-prepare.log}" mx_verify_signatures "$package_dir"
    printf '==> Source signatures verified against the pinned signing keys.\n' >&2
    mkdir -- "$package_dir/src"
    for entry in "${source[@]}"; do
        name="$(mx_source_filename "$entry")"
        file="$package_dir/$name"
        ln -s -- "$file" "$package_dir/src/$name"
        case "$name" in
            *.tar.gz|*.tar.xz|*.tar.zst|*.tar.bz2)
                kernelforge_run_logged 'Extracting kernel source' \
                    "${KERNELFORGE_PREPARE_LOG:-$package_dir/.kernelforge-prepare.log}" \
                    tar --extract --file "$file" --directory "$package_dir/src" --no-same-owner --no-same-permissions ;;
            *.patch.zst) zstd -dc -- "$file" >"$package_dir/src/${name%.zst}" ;;
        esac
    done
    tree="$package_dir/src/$KF_SOURCE_TREE"
    [[ -f "$tree/Makefile" && -x "$tree/scripts/config" ]] || {
        echo 'ERROR: Verified archive has no expected kernel tree.' >&2; return 1;
    }
)
