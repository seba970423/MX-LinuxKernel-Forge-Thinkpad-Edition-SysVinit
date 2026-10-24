#!/usr/bin/env bash
# Read requirements from the selected source, never from a fixed kernel version.

# shellcheck source=lib/bindgen.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/bindgen.sh"

mx_version() {
    "$@" 2>/dev/null | sed -n '1p' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sed -n '1p'
}

mx_version_at_least() {
    [[ -n "$1" && -n "$2" ]] && dpkg --compare-versions "$1" ge "$2"
}

mx_min_tool_version() {
    local tree="$1" tool="$2"
    ARCH=x86_64 SRCARCH=x86 sh "$tree/scripts/min-tool-version.sh" "$tool"
}

mx_upgrade_tool() {
    local package="$1" minimum="$2" version best=''
    while read -r version; do
        if dpkg --compare-versions "$version" ge "$minimum" &&
            { [[ -z "$best" ]] || dpkg --compare-versions "$version" gt "$best"; }; then best="$version"; fi
    done < <(apt-cache madison "$package" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
    [[ -n "$best" ]] || {
        printf 'ERROR: %s >= %s is unavailable in enabled APT repositories.\n' "$package" "$minimum" >&2
        printf 'Enable an appropriate MX/Debian repository or install a compatible toolchain, then retry.\n' >&2
        return 1
    }
    mx_apt_install "$package=$best"
}

mx_select_llvm() {
    local minimum="$1" required_major="${2:-}" private_root="${3:-}" major installed available best=0 directory
    if [[ -n "${KERNELFORGE_LLVM_ROOT:-}" ]]; then
        directory="$KERNELFORGE_LLVM_ROOT/bin"
        [[ -x "$directory/clang" && -x "$directory/ld.lld" && -x "$directory/llvm-objcopy" ]] || {
            echo 'ERROR: KERNELFORGE_LLVM_ROOT does not contain a complete LLVM suite.' >&2; return 1;
        }
        installed="$(mx_version "$directory/clang" --version)"
        mx_version_at_least "$installed" "$minimum" || {
            printf 'ERROR: Custom LLVM %s is too old; need %s.\n' "$installed" "$minimum" >&2; return 1;
        }
        compgen -G "$KERNELFORGE_LLVM_ROOT/lib/libclang.so*" >/dev/null || {
            echo 'ERROR: Custom LLVM is missing its libclang shared library.' >&2; return 1;
        }
        [[ -z "$required_major" || "${installed%%.*}" == "$required_major" ]] || {
            printf 'ERROR: Rust LTO requires LLVM %s; custom LLVM provides %s.\n' "$required_major" "$installed" >&2; return 1;
        }
        export PATH="$directory:$PATH" LIBCLANG_PATH="$KERNELFORGE_LLVM_ROOT/lib"
        return 0
    fi
    # Include versioned tools installed outside APT, while keeping one LLVM suite.
    for directory in /usr/lib/llvm-*/bin; do
        [[ -x "$directory/clang" && -x "$directory/ld.lld" ]] || continue
        installed="$(mx_version "$directory/clang" --version)"
        if mx_version_at_least "$installed" "$minimum"; then
            major="${installed%%.*}"
            [[ -z "$required_major" || "$major" == "$required_major" ]] || continue
            (( major <= best )) || best="$major"
        fi
    done
    while IFS= read -r available; do
        major="${available#clang-}"
        [[ "$major" =~ ^[0-9]+$ ]] || continue
        [[ -z "$required_major" || "$major" == "$required_major" ]] || continue
        (( major > best )) || continue
        installed="$(mx_apt_candidate "$available")"
        [[ -n "$installed" ]] || continue
        if dpkg --compare-versions "$installed" ge "$minimum"; then best="$major"; fi
    done < <(apt-cache pkgnames | grep -E '^clang-[0-9]+$' | sort -Vu)
    (( best > 0 )) || {
        printf '==> Required LLVM >= %s%s is unavailable in enabled APT repositories.\n' \
            "$minimum" "${required_major:+ (major $required_major)}" >&2
        if [[ -n "$private_root" ]]; then
            mx_isolated_llvm "${required_major:-${minimum%%.*}}" "$private_root" || return 1
            mx_select_llvm "$minimum" "$required_major" || return 1
            return 0
        fi
        printf 'A compatible private LLVM installation can be selected with KERNELFORGE_LLVM_ROOT.\n' >&2
        return 1
    }
    directory="/usr/lib/llvm-$best/bin"
    if [[ ! -x "$directory/clang" || ! -x "$directory/ld.lld" || ! -x "$directory/llvm-objcopy" ||
          ! -f "/usr/lib/llvm-$best/lib/libclang.so" ]]; then
        mx_apt_install "clang-$best" "llvm-$best" "lld-$best" "libclang-$best-dev" || return 1
    fi
    export PATH="$directory:$PATH"
    export LIBCLANG_PATH="/usr/lib/llvm-$best/lib"
    printf '==> LLVM suite: %s\n' "$directory" >&2
}

mx_isolated_llvm() {
    local major="$1" root="$2" metadata name url checksum size answer actual destination staging
    metadata="$(curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        'https://api.github.com/repos/llvm/llvm-project/releases?per_page=100' |
        python3 "$REPO_ROOT/lib/llvm-release.py" "$major")" || return 1
    IFS=$'\t' read -r name url checksum size <<<"$metadata"
    [[ "$size" =~ ^[0-9]+$ && "$checksum" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '==> Official private LLVM toolchain: %s (download approximately %s MiB).\n' "$name" "$((size/1024/1024))" >&2
    printf '==> This stays in the build directory and does not change system compiler packages.\n' >&2
    if ! read -r -p 'Download and extract this LLVM toolchain? [Y/n]: ' answer; then answer=n; fi
    case "${answer:-y}" in y|Y|yes|YES|Yes) ;; *) return 1 ;; esac
    mkdir -p "$root" || return 1
    destination="$root/${name%.tar.xz}"
    [[ ! -e "$destination" ]] || { echo 'ERROR: Private LLVM destination already exists.' >&2; return 1; }
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$url" -o "$root/$name.part" || return 1
    actual="$(sha256sum "$root/$name.part")" || return 1
    [[ "${actual%% *}" == "$checksum" ]] || { echo 'ERROR: Official LLVM archive checksum mismatch.' >&2; return 1; }
    mv "$root/$name.part" "$root/$name" || return 1
    staging="$(mktemp -d "$root/.llvm-extract.XXXXXX")" || return 1
    tar --extract --file "$root/$name" --directory "$staging" --strip-components=1 \
        --no-same-owner --no-same-permissions || return 1
    [[ -x "$staging/bin/clang" && -x "$staging/bin/ld.lld" && -x "$staging/bin/llvm-objcopy" ]] || {
        echo 'ERROR: Official LLVM archive has an unexpected layout.' >&2; return 1;
    }
    "$staging/bin/clang" --version >/dev/null || {
        echo 'ERROR: This official LLVM binary cannot run on the host userspace.' >&2; return 1;
    }
    mv "$staging" "$destination" || return 1
    export KERNELFORGE_LLVM_ROOT="$destination"
}

mx_rust_library() {
    local sysroot path version
    command -v rustc >/dev/null || return 1
    sysroot="$(rustc --print sysroot)" || return 1
    version="$(mx_version rustc --version)" || return 1
    for path in "${RUST_LIB_SRC:-/nonexistent}" "$sysroot/lib/rustlib/src/rust/library" \
        "/usr/src/rustc-$version/library"; do
        [[ ! -f "$path/core/src/lib.rs" ]] || { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

mx_isolated_rust() {
    local minimum="$1" root="$2" answer checksum actual installer
    printf '==> A Rust toolchain with its matching sources is required (minimum %s).\n' "$minimum" >&2
    printf '==> It can be installed privately under %s.\n' "$root" >&2
    printf '==> This uses official Rust downloads and keeps your global compiler/default unchanged.\n' >&2
    if ! read -r -p 'Download the isolated Rust toolchain? [Y/n]: ' answer; then answer=n; fi
    case "${answer:-y}" in y|Y|yes|YES|Yes) ;; *) return 1 ;; esac
    mkdir -p "$root"
    export CARGO_HOME="$root/cargo" RUSTUP_HOME="$root/rustup"
    installer="$root/rustup-init"
    curl --fail --location --proto '=https' --proto-redir '=https' \
        'https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init' -o "$installer" || return 1
    checksum="$(curl --fail --location --proto '=https' --proto-redir '=https' \
        'https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256')" || return 1
    checksum="${checksum%% *}"
    [[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    actual="$(sha256sum "$installer")"
    [[ "${actual%% *}" == "$checksum" ]] || { echo 'ERROR: Rust installer checksum mismatch.' >&2; return 1; }
    chmod 700 "$installer"
    RUSTUP_INIT_SKIP_PATH_CHECK=yes "$installer" -y --no-modify-path --profile minimal \
        --default-toolchain "$minimum" --component rust-src --component rustfmt >&2 || return 1
    export PATH="$CARGO_HOME/bin:$PATH" RUSTUP_TOOLCHAIN="$minimum"
    export RUST_LIB_SRC="$RUSTUP_HOME/toolchains/$minimum-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library"
}

mx_required_rust_version() {
    local tree="$1" reference_config="$2" minimum baseline_rust
    minimum="$(mx_min_tool_version "$tree" rustc)" || return 1
    # The ThinkPad native profile can require newer Rust features than the
    # kernel's generic minimum (e.g. RUSTC_HAS_APXF). Use the compiler level
    # recorded by the selected baseline to preserve its native/Rust combination.
    if grep -qx 'CONFIG_RUST=y' "$reference_config"; then
        baseline_rust="$(sed -nE 's/^CONFIG_RUSTC_VERSION_TEXT="rustc ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$reference_config")"
        [[ -n "$baseline_rust" ]] || {
            echo 'ERROR: Rust-enabled baseline has no compiler version; cannot resolve native-profile requirements.' >&2; return 1;
        }
        if dpkg --compare-versions "$baseline_rust" gt "$minimum"; then minimum="$baseline_rust"; fi
    fi
    printf '%s\n' "$minimum"
}

mx_select_rust() {
    local tree="$1" root="$2" reference_config="$3" minimum current library candidate
    minimum="$(mx_required_rust_version "$tree" "$reference_config")" || return 1
    current="$(mx_version rustc --version || true)"
    library="$(mx_rust_library || true)"
    if ! mx_version_at_least "$current" "$minimum" || [[ -z "$library" ]]; then
        candidate="$(mx_apt_candidate rustc)"
        if [[ -n "$candidate" ]] && dpkg --compare-versions "$candidate" ge "$minimum" &&
            [[ -n "$(mx_apt_candidate rust-src)" ]]; then
            mx_apt_install rustc rust-src cargo rustfmt || return 1
            current="$(mx_version rustc --version || true)"
            library="$(mx_rust_library || true)"
        fi
        if ! mx_version_at_least "$current" "$minimum" || [[ -z "$library" ]]; then
            mx_isolated_rust "$minimum" "$root/rust" || return 1
            library="$(mx_rust_library)" || return 1
        fi
    fi
    export RUST_LIB_SRC="$library"
    mx_version_at_least "$(mx_version rustc --version)" "$minimum" || return 1
}

mx_prepare_toolchain() {
    local package_dir="$1" tree="$2" minimum current rust_needed=0 rust_llvm
    local KF_LTO='' KF_SOURCE_TREE='' KF_PACKAGE_VERSION=''
    source "$package_dir/.kernelforge-recipe"
    [[ -f "$tree/scripts/min-tool-version.sh" ]] || {
        echo 'ERROR: Source has no toolchain requirements script.' >&2; return 1;
    }
    minimum="$(mx_min_tool_version "$tree" gcc)" || return 1
    current="$(mx_version gcc --version)"
    mx_version_at_least "$current" "$minimum" || {
        printf 'ERROR: GCC %s is too old; kernel requires %s.\n' "$current" "$minimum" >&2; return 1;
    }
    minimum="$(mx_min_tool_version "$tree" binutils)" || return 1
    mx_version_at_least "$(mx_version ld --version)" "$minimum" || {
        printf 'ERROR: binutils must be >= %s.\n' "$minimum" >&2; return 1;
    }
    if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$package_dir/config"; then
        minimum="$(awk '$1 == "pahole" && $2 ~ /^[0-9]+\./ {print $2; exit}' "$tree/Documentation/process/changes.rst")"
        [[ -n "$minimum" ]] || { echo 'ERROR: Cannot determine source pahole requirement.' >&2; return 1; }
        if ! mx_version_at_least "$(mx_version pahole --version || true)" "$minimum"; then
            mx_upgrade_tool pahole "$minimum" || return 1
        fi
        mx_version_at_least "$(mx_version pahole --version)" "$minimum" || return 1
    fi
    # Rust-enabled kernel and host QR-code generator both need Rust sources.
    if grep -Eq '^CONFIG_(RUST|DRM_PANIC_SCREEN_QR_CODE)=y$' "$package_dir/config" || [[ "$KF_LTO" == none ]]; then
        rust_needed=1
    fi
    if [[ "$KF_LTO" != none || "$rust_needed" == 1 ]]; then
        minimum="$(mx_min_tool_version "$tree" llvm)" || return 1
        mx_select_llvm "$minimum" '' "$package_dir/toolchain" || return 1
    fi
    if [[ "$rust_needed" == 1 ]]; then
        mx_select_rust "$tree" "$package_dir/toolchain" "$package_dir/config" || return 1
        if [[ "$KF_LTO" != none ]] && grep -qx 'CONFIG_RUST=y' "$package_dir/config"; then
            rust_llvm="$(rustc -vV | awk '/^LLVM version:/ {split($3, version, "."); print version[1]}')"
            [[ "$rust_llvm" =~ ^[0-9]+$ ]] || return 1
            mx_select_llvm "$rust_llvm.0.0" "$rust_llvm" "$package_dir/toolchain" || return 1
        fi
        # Rust LTO can change the LLVM suite. Probe bindgen only after that final
        # selection so both prepare() and all subsequent makes use a tested pair.
        mx_select_bindgen "$tree" "$package_dir/toolchain" "$package_dir/config" || return 1
    fi
    if [[ "$KF_LTO" != none ]]; then export LLVM=1 LLVM_IAS=1; else unset LLVM LLVM_IAS; fi
    export KBUILD_BUILD_HOST=mx-debian
    # Every olddefconfig/probe/package submake sees the same compiler selection.
    # Save it outside src/ so retained .deb/header troubleshooting is repeatable.
    {
        printf 'export PATH=%q\n' "$PATH"
        printf 'export LIBCLANG_PATH=%q\n' "${LIBCLANG_PATH:-}"
        printf 'export RUST_LIB_SRC=%q\n' "${RUST_LIB_SRC:-}"
        printf 'export KBUILD_BUILD_HOST=mx-debian\n'
        for current in BINDGEN CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN KERNELFORGE_LLVM_ROOT LLVM LLVM_IAS; do
            if [[ -v "$current" ]]; then printf 'export %s=%q\n' "$current" "${!current}"; else printf 'unset %s\n' "$current"; fi
        done
    } >"$package_dir/.kernelforge-toolchain-env"
    printf '==> Compiler/toolchain checks complete.\n' >&2
}

mx_validate_toolchain_features() {
    local original="$1" config="$2" symbol
    for symbol in RUST DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES CFI_CLANG \
        LTO_CLANG_THIN LTO_CLANG_FULL LTO_CLANG_THIN_DIST; do
        if grep -qx "CONFIG_$symbol=y" "$original" && ! grep -qx "CONFIG_$symbol=y" "$config"; then
            printf 'ERROR: CONFIG_%s was lost while resolving the MX/Debian toolchain.\n' "$symbol" >&2
            printf 'Install compatible tools; this builder will not silently remove the feature.\n' >&2
            return 1
        fi
    done
}

mx_validate_lto_mode() (
    local package_dir="$1" config="$2" symbol
    source "$package_dir/.kernelforge-recipe"
    case "$KF_LTO" in
        none) symbol=LTO_NONE ;;
        thin) symbol=LTO_CLANG_THIN ;;
        full) symbol=LTO_CLANG_FULL ;;
        thin-dist) symbol=LTO_CLANG_THIN_DIST ;;
        *) printf 'ERROR: Unsupported upstream LTO mode: %s\n' "$KF_LTO" >&2; return 1 ;;
    esac
    grep -qx "CONFIG_$symbol=y" "$config" || {
        printf 'ERROR: Selected compiler could not preserve CONFIG_%s.\n' "$symbol" >&2; return 1;
    }
)
