#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_TMPDIR="$(mktemp -d --tmpdir kernelforge-naming-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT
source "$REPO_ROOT/lib/naming.sh"
[[ "$(prompt_kernel_name </dev/null)" == mx-thinkpad-debian ]]
[[ "$(printf 'y\nlinux-seba-debian\n' | prompt_kernel_name)" == seba-debian ]]
[[ "$(printf 'y\nBAD NAME\nseba-debian\n' | prompt_kernel_name)" == seba-debian ]]
if prompt_kernel_name <<< y; then echo 'ERROR: Missing custom name accepted.' >&2; exit 1; fi
for invalid in '' '../bad' 'UPPER' 'has space' '-prefix'; do
    if mx_valid_kernel_name "$invalid"; then echo 'ERROR: Invalid name accepted.' >&2; exit 1; fi
done
printf 'Kernel naming tests passed.\n'
