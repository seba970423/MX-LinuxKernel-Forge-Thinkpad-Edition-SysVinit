#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/debian.sh"
source "$REPO_ROOT/lib/toolchain.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ( "$@" ) >"$scratch/expected-failure.log" 2>&1; then fail "Unexpected success: $*"; fi; }
mkdir -p "$scratch/tree/scripts" "$scratch/bin"
cat >"$scratch/tree/scripts/min-tool-version.sh" <<'SCRIPT'
#!/bin/sh
case "$1" in
    gcc) echo 8.1.0 ;;
    binutils) echo 2.30.0 ;;
    llvm) echo 17.0.1 ;;
    rustc) echo 1.85.0 ;;
    bindgen) echo "${TEST_KERNEL_BINDGEN_MIN:-0.71.1}" ;;
    *) exit 1 ;;
esac
SCRIPT
printf 'CONFIG_RUST=y\nCONFIG_RUSTC_VERSION_TEXT="rustc 1.98.0 (fixture)"\n' >"$scratch/reference"
export PATH="$scratch/bin:$PATH" TEST_CLANG_MAJOR=22

write_bindgen() {
    local destination="$1" fixture_version="$2" fixture_mode="$3"
    mkdir -p "${destination%/*}"
    {
        printf '#!/usr/bin/env bash\nversion=%q\nmode=%q\n' "$fixture_version" "$fixture_mode"
        cat <<'SCRIPT'
set -euo pipefail
if [[ "${1:-}" == --version ]]; then printf 'bindgen %s\n' "$version"; exit 0; fi
[[ "$mode" != error ]] || { echo 'fixture: libclang could not be loaded' >&2; exit 42; }
output=''
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == --output ]]; then ((i+=1)); output="${!i}"; fi
done
[[ -n "$output" ]]
printf 'KERNELFORGE_LIBCLANG=%s.1.8\n' "$TEST_CLANG_MAJOR" >&2
if [[ "$mode" == patched ]] || { [[ "$mode" != opaque ]] && { (( TEST_CLANG_MAJOR < 22 )) || dpkg --compare-versions "$version" ge 0.72.1; }; }; then
    printf 'pub struct kernelforge_bindgen_probe { pub kernelforge_member: i32, }\n' >"$output"
else
    printf 'pub struct kernelforge_bindgen_probe { pub _address: u8, }\n' >"$output"
fi
SCRIPT
    } >"$destination"
    chmod +x "$destination"
}
clang() { printf 'clang version %s.1.8\n' "$TEST_CLANG_MAJOR"; }
mx_apt_candidate() { printf '%s\n' "${TEST_APT_BINDGEN:-0.71.1-6}"; }
mx_apt_install() { fail 'Unexpected APT installation.'; }
cargo() {
    printf '%s\n' "$*" >>"$scratch/cargo-calls"
    local root='' version=''
    while (( $# )); do
        case "$1" in
            --root) root="$2"; shift ;;
            --version) version="$2"; shift ;;
        esac
        shift
    done
    [[ -n "$root" && -n "$version" ]] || fail 'Unpinned private Cargo installation.'
    write_bindgen "$root/bin/bindgen" "$version" "${TEST_PRIVATE_MODE:-normal}"
}

# Reproduce the forward-declaration defect and check the versioned repair.
(
    write_bindgen "$scratch/bin/bindgen" 0.71.1 normal
    expect_failure mx_probe_bindgen "$scratch/probe-bad"
    [[ "$(mx_bindgen_minimum "$scratch/tree" "$scratch/probe-bad")" == 0.72.1 ]] || fail 'LLVM 22 compatibility floor missing.'
    mx_select_bindgen "$scratch/tree" "$scratch/private-fixed" "$scratch/reference" >"$scratch/fixed.log" 2>&1
    [[ "$BINDGEN" == "$scratch/private-fixed/bindgen/bin/bindgen" ]] || fail 'Private bindgen not exported.'
    grep -q -- '--locked.*--version 0.72.1' "$scratch/cargo-calls" || fail 'Wrong private bindgen version.'
    grep -q 'pub kernelforge_member' "$scratch/private-fixed/bindgen-probe/bindings.rs" || fail 'Opaque bindings survived the repair.'
)

# A backported distro fix is valid even when its numeric version is older.
(
    cargo() { fail 'Patched distro bindgen should be reused.'; }
    write_bindgen "$scratch/bin/bindgen" 0.71.1 patched
    mx_select_bindgen "$scratch/tree" "$scratch/backported" "$scratch/reference" >/dev/null
)

# Old libclang does not require upgrading an otherwise compatible bindgen.
(
    export TEST_CLANG_MAJOR=19
    cargo() { fail 'Compatible libclang 19 pair should be reused.'; }
    write_bindgen "$scratch/bin/bindgen" 0.71.1 normal
    mx_select_bindgen "$scratch/tree" "$scratch/llvm19" "$scratch/reference" >/dev/null
    [[ "$(mx_bindgen_minimum "$scratch/tree" "$scratch/llvm19/bindgen-probe")" == 0.71.1 ]]
)

# Prefer an adequate APT version before privately compiling another copy.
(
    TEST_APT_BINDGEN=0.72.1-1
    write_bindgen "$scratch/bin/bindgen" 0.71.1 normal
    mx_apt_install() { [[ "$*" == bindgen ]]; write_bindgen "$scratch/bin/bindgen" 0.72.1 normal; }
    cargo() { fail 'Working APT bindgen should be preferred.'; }
    mx_select_bindgen "$scratch/tree" "$scratch/apt-fixed" "$scratch/reference" >/dev/null
)

# A compiler invocation error is distinct from the opaque-struct defect.
(
    write_bindgen "$scratch/bin/bindgen" 0.71.1 error
    cargo() { fail 'A libclang loading error must not trigger a blind upgrade.'; }
    expect_failure mx_select_bindgen "$scratch/tree" "$scratch/loading-error" "$scratch/reference"
    grep -q 'could not run its compatibility check' "$scratch/expected-failure.log" || fail 'Probe error was misclassified.'
)

# Even a new version is rejected if its generated bindings remain incomplete.
(
    write_bindgen "$scratch/bin/bindgen" 0.71.1 normal
    export TEST_PRIVATE_MODE=opaque
    expect_failure mx_select_bindgen "$scratch/tree" "$scratch/still-broken" "$scratch/reference"
    grep -q 'Private bindgen failed' "$scratch/expected-failure.log" || fail 'Broken private bindings were accepted.'
)

# Never lower a newer requirement declared by the selected kernel.
(
    export TEST_KERNEL_BINDGEN_MIN=0.73.1
    write_bindgen "$scratch/bin/bindgen" 0.71.1 normal
    mx_select_bindgen "$scratch/tree" "$scratch/newer-minimum" "$scratch/reference" >/dev/null
    [[ "$(mx_version bindgen --version)" == 0.73.1 ]]
)

# Probe after the final LLVM selection, including Rust-LTO major matching.
(
    package_dir="$scratch/lto-package"
    mkdir -p "$package_dir"
    printf 'KF_LTO=thin\n' >"$package_dir/.kernelforge-recipe"
    cp "$scratch/reference" "$package_dir/config"
    mx_select_llvm() { TEST_CLANG_MAJOR="${2:-19}"; printf 'llvm %s\n' "$TEST_CLANG_MAJOR" >>"$scratch/lto-order"; }
    mx_select_rust() { :; }
    rustc() { printf 'LLVM version: 22.1.8\n'; }
    mx_select_bindgen() {
        [[ "$TEST_CLANG_MAJOR" == 22 ]] || fail 'Bindgen was probed before the final LLVM selection.'
        printf 'bindgen %s\n' "$TEST_CLANG_MAJOR" >>"$scratch/lto-order"
    }
    mx_prepare_toolchain "$package_dir" "$scratch/tree" >/dev/null
    [[ "$(cat "$scratch/lto-order")" == $'llvm 19\nllvm 22\nbindgen 22' ]] || fail 'Wrong toolchain selection order.'
)

printf 'Bindgen/libclang compatibility tests passed.\n'
