#!/usr/bin/env bash
# Check the actual bindings, not just the kernel's generic version minimum.
# LLVM 22 may expose forward declarations through clang_getTypeDeclaration();
# bindgen < 0.72.1 then emits opaque structs. See rust-bindgen PR 3278 and
# kernel commit dc01dfb37b34beeefcfe1c3055364d41a4070c7e.

# 0: working bindings; 1: missing member/opaque type; 2: invocation failure.
# Keep the small header, bindings and diagnostics alongside the toolchain.
mx_probe_bindgen() {
    local directory="$1"
    mkdir -p "$directory" || return 2
    cat >"$directory/forward-definition.h" <<'HEADER' || return 2
#define KF_STRINGIFY_1(x) #x
#define KF_STRINGIFY(x) KF_STRINGIFY_1(x)
#pragma message("KERNELFORGE_LIBCLANG=" KF_STRINGIFY(__clang_major__) "." KF_STRINGIFY(__clang_minor__) "." KF_STRINGIFY(__clang_patchlevel__))
struct kernelforge_bindgen_probe;
struct kernelforge_bindgen_probe { int kernelforge_member; };
HEADER
    : >"$directory/bindings.rs" || return 2
    if ! bindgen "$directory/forward-definition.h" \
        --allowlist-type kernelforge_bindgen_probe --no-layout-tests \
        --output "$directory/bindings.rs" -- -x c \
        >"$directory/stdout.log" 2>"$directory/stderr.log"; then
        return 2
    fi
    grep -Eq 'pub[[:space:]]+kernelforge_member[[:space:]]*:' "$directory/bindings.rs"
}

mx_bindgen_minimum() {
    local tree="$1" probe="$2" minimum clang_version major
    minimum="$(mx_min_tool_version "$tree" bindgen)" || return 1
    clang_version=''
    if [[ -f "$probe/stderr.log" ]]; then
        clang_version="$(sed -nE 's/.*KERNELFORGE_LIBCLANG=([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$probe/stderr.log" | sed -n '1p')"
    fi
    # An absent bindgen cannot report its libclang yet; use the chosen suite.
    if [[ -z "$clang_version" ]]; then clang_version="$(mx_version clang --version || true)"; fi
    major="${clang_version%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 22 )) &&
        dpkg --compare-versions "$minimum" lt 0.72.1; then
        minimum=0.72.1
    fi
    printf '%s\n' "$minimum"
}

mx_report_bindgen() {
    local probe="$1" version clang_version
    version="$(mx_version bindgen --version)" || return 1
    clang_version="$(sed -nE 's/.*KERNELFORGE_LIBCLANG=([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$probe/stderr.log" | sed -n '1p')"
    export BINDGEN
    BINDGEN="$(command -v bindgen)" || return 1
    printf '==> bindgen %s / libclang %s: forward-definition check passed.\n' \
        "$version" "${clang_version:-unknown}" >&2
}

mx_select_bindgen() {
    local tree="$1" root="$2" reference_config="$3" minimum current candidate status rust_minimum
    local probe="$root/bindgen-probe"
    minimum="$(mx_min_tool_version "$tree" bindgen)" || return 1
    current="$(mx_version bindgen --version || true)"
    if mx_version_at_least "$current" "$minimum"; then
        if mx_probe_bindgen "$probe"; then
            # Accept distro backports of the fix even with an older version.
            mx_report_bindgen "$probe"
            return $?
        else
            status=$?
            if [[ "$status" != 1 ]]; then
                printf 'ERROR: bindgen could not run its compatibility check. See %s/stderr.log\n' "$probe" >&2
                cat "$probe/stderr.log" >&2 || true
                return 1
            fi
            printf '==> Installed bindgen %s generated an opaque struct; selecting a compatible build.\n' "$current" >&2
        fi
    fi

    minimum="$(mx_bindgen_minimum "$tree" "$probe")" || return 1
    candidate="$(mx_apt_candidate bindgen)"
    if [[ -n "$candidate" ]] && dpkg --compare-versions "$candidate" ge "$minimum"; then
        mx_apt_install bindgen || return 1
        if mx_version_at_least "$(mx_version bindgen --version || true)" "$minimum" &&
            mx_probe_bindgen "$probe"; then
            mx_report_bindgen "$probe"
            return $?
        fi
        printf '==> APT bindgen did not pass the compatibility check; using a private build.\n' >&2
    fi

    if ! command -v cargo >/dev/null; then
        rust_minimum="$(mx_required_rust_version "$tree" "$reference_config")" || return 1
        mx_isolated_rust "$rust_minimum" "$root/rust" || return 1
    fi
    printf '==> Building compatible bindgen-cli %s in %s/bindgen...\n' "$minimum" "$root" >&2
    cargo install --locked --root "$root/bindgen" --version "$minimum" bindgen-cli >&2 || return 1
    export PATH="$root/bindgen/bin:$PATH"
    hash -r
    if ! mx_version_at_least "$(mx_version bindgen --version || true)" "$minimum" ||
        ! mx_probe_bindgen "$probe"; then
        printf 'ERROR: Private bindgen failed the compatibility check. See %s\n' "$probe" >&2
        cat "$probe/stderr.log" >&2 || true
        return 1
    fi
    mx_report_bindgen "$probe"
}
