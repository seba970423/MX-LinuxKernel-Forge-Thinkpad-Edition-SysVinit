#!/usr/bin/env bash
# Use the distribution GCC/binutils. No private compiler downloads are needed.

mx_version() {
    "$@" 2>/dev/null | sed -n '1p' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sed -n '1p'
}

mx_version_at_least() {
    [[ -n "$1" && -n "$2" ]] && dpkg --compare-versions "$1" ge "$2"
}

mx_min_tool_version() {
    ARCH=x86_64 SRCARCH=x86 sh "$1/scripts/min-tool-version.sh" "$2"
}

mx_prepare_toolchain() {
    local package_dir="$1" tree="$2" minimum current variable
    [[ -f "$tree/scripts/min-tool-version.sh" ]] || return 1
    # Ignore inherited build flags from another kernel or a previous Forge run.
    # Explicit distribution tools also avoid accidentally reusing private LLVM.
    unset RUSTUP_TOOLCHAIN RUSTUP_HOME CARGO_HOME RUST_LIB_SRC LIBCLANG_PATH BINDGEN RUSTC CARGO
    unset LLVM LLVM_IAS CLANG_TRIPLE CROSS_COMPILE ARCH SRCARCH KBUILD_OUTPUT
    unset KCONFIG_CONFIG KCONFIG_ALLCONFIG KCONFIG_SEED KCONFIG_NOSILENTUPDATE
    unset KCFLAGS KCPPFLAGS CFLAGS_KERNEL CFLAGS_MODULE KAFLAGS LDFLAGS
    unset KBUILD_EXTRA_SYMBOLS LOCALVERSION MAKEFLAGS MFLAGS
    export CC=/usr/bin/gcc HOSTCC=/usr/bin/gcc LD=/usr/bin/ld HOSTLD=/usr/bin/ld
    export AR=/usr/bin/ar NM=/usr/bin/nm STRIP=/usr/bin/strip
    export OBJCOPY=/usr/bin/objcopy OBJDUMP=/usr/bin/objdump READELF=/usr/bin/readelf
    export HOSTCXX=/usr/bin/g++ KBUILD_BUILD_HOST=mx-debian
    minimum="$(mx_min_tool_version "$tree" gcc)" || return 1
    current="$(mx_version "$CC" --version)" || return 1
    mx_version_at_least "$current" "$minimum" || {
        printf 'ERROR: Distribution GCC %s is too old; need %s.\n' "$current" "$minimum" >&2; return 1;
    }
    minimum="$(mx_min_tool_version "$tree" binutils)" || return 1
    mx_version_at_least "$(mx_version "$LD" --version)" "$minimum" || {
        printf 'ERROR: Distribution binutils must be >= %s.\n' "$minimum" >&2; return 1;
    }
    if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$package_dir/config"; then
        minimum="$(awk '$1 == "pahole" && $2 ~ /^[0-9]+\./ {print $2; exit}' "$tree/Documentation/process/changes.rst")"
        [[ -n "$minimum" ]] && mx_version_at_least "$(mx_version pahole --version)" "$minimum" || {
            printf 'ERROR: A compatible distribution pahole is required (minimum %s).\n' "${minimum:-unknown}" >&2
            return 1
        }
    fi
    if grep -qx 'CONFIG_RUST=y' "$package_dir/config"; then
        echo 'ERROR: This builder expects a supported Debian GCC configuration with Rust disabled.' >&2
        return 1
    fi
    {
        for variable in CC HOSTCC LD HOSTLD AR NM STRIP OBJCOPY OBJDUMP READELF HOSTCXX KBUILD_BUILD_HOST; do
            printf 'export %s=%q\n' "$variable" "${!variable}"
        done
        printf 'unset RUSTUP_TOOLCHAIN RUSTUP_HOME CARGO_HOME RUST_LIB_SRC LIBCLANG_PATH BINDGEN RUSTC CARGO\n'
        printf 'unset LLVM LLVM_IAS CLANG_TRIPLE CROSS_COMPILE ARCH SRCARCH KBUILD_OUTPUT\n'
        printf 'unset KCONFIG_CONFIG KCONFIG_ALLCONFIG KCONFIG_SEED KCONFIG_NOSILENTUPDATE\n'
        printf 'unset KCFLAGS KCPPFLAGS CFLAGS_KERNEL CFLAGS_MODULE KAFLAGS LDFLAGS\n'
        printf 'unset KBUILD_EXTRA_SYMBOLS LOCALVERSION MAKEFLAGS MFLAGS\n'
    } >"$package_dir/.kernelforge-toolchain-env"
    printf '==> Distribution GCC %s and binutils checked.\n' "$current" >&2
}

mx_validate_toolchain_features() {
    local original="$1" config="$2" symbol
    for symbol in RUST DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES CFI_CLANG LTO_NONE; do
        if grep -qx "CONFIG_$symbol=y" "$original" && ! grep -qx "CONFIG_$symbol=y" "$config"; then
            printf 'ERROR: CONFIG_%s was lost while resolving the Debian toolchain.\n' "$symbol" >&2
            return 1
        fi
    done
}
