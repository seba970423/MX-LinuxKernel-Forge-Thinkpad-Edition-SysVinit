#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/lib/debian.sh"
mx_require_host
mx_ensure_base_dependencies
printf '==> Base Debian build dependencies are installed.\n'
printf '==> Source-specific compiler and Rust requirements are checked by the builder.\n'
