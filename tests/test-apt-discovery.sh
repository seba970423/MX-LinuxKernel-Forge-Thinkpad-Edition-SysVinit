#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/debian.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mkdir -p "$scratch/bin"
export KF_APT_FIXTURE_DIR="$scratch"
export KF_TEST_POLICY_MODE=valid
export PATH="$scratch/bin:$PATH"

# A real producer must finish writing its version table. The old awk `exit`
# closes the pipe early and kills this process with SIGPIPE under pipefail.
cat >"$scratch/bin/apt-cache" <<'PYTHON'
#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)
root = Path(os.environ['KF_APT_FIXTURE_DIR'])
mode = os.environ.get('KF_TEST_POLICY_MODE', 'valid')
if sys.argv[1] == 'policy':
    if os.environ.get('LC_ALL') != 'C':
        raise SystemExit('Candidate parser did not request stable APT output.')
    if mode == 'error':
        print('E: Fixture APT metadata failure', file=sys.stderr)
        raise SystemExit(100)
    print(sys.argv[2] + ':')
    print('  Installed: (none)')
    if mode != 'missing':
        print('  Candidate: ' + ('(none)' if mode == 'none' else '6.12.107-1'))
    print('  Version table:')
    for index in range(4096):
        print('     6.12.107-1 500 ' + str(index) + ' repository metadata ' * 8)
    sys.stdout.flush()
    (root / 'policy-complete').write_text('yes\n')
    if mode == 'partial-error':
        print('E: Fixture failure after candidate output', file=sys.stderr)
        raise SystemExit(42)
elif sys.argv[1] == 'show':
    if sys.argv[2] not in ('linux-source-6.12=6.12.107-1', 'linux-config-6.12=6.12.107-1'):
        raise SystemExit(100)
    print('SHA256: ' + 'a' * 64)
else:
    raise SystemExit('Unexpected APT operation')
PYTHON
cat >"$scratch/bin/apt-get" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == update ]] || { printf 'Unexpected APT operation\n' >&2; exit 100; }
printf 'update\n' >>"$KF_APT_FIXTURE_DIR/updates"
if [[ "${KF_TEST_UPDATE_FAIL:-0}" == 1 ]]; then
    printf 'E: Fixture update failure\n' >&2
    exit 100
fi
printf 'Reading package lists... Done\n'
SCRIPT
chmod +x "$scratch/bin/apt-cache" "$scratch/bin/apt-get"

candidate="$(mx_apt_candidate linux-source-6.12)"
[[ "$candidate" == 6.12.107-1 ]] || fail 'Long policy output changed the candidate.'
[[ -f "$scratch/policy-complete" ]] || fail 'Candidate lookup did not drain the producer.'

for mode in none missing error partial-error; do
    export KF_TEST_POLICY_MODE="$mode"
    if mx_apt_candidate linux-source-6.12 >"$scratch/candidate" 2>"$scratch/diagnostic"; then
        fail "Accepted invalid APT metadata: $mode"
    fi
    [[ ! -s "$scratch/candidate" ]] || fail 'Failed lookup leaked a usable-looking candidate.'
    grep -q 'ERROR:.*linux-source-6.12' "$scratch/diagnostic" || fail "Missing actionable diagnostic: $mode"
done
export KF_TEST_POLICY_MODE=valid

# Exercise both actual main functions through successful refresh, real candidate
# parsing, digest lookup and the source-preparation boundary. Host privileges,
# hardware and source download are isolated; no system package state is changed.
cat >"$scratch/workflow.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
mx_require_build_user() { :; }
mx_require_host() { :; }
mx_ensure_base_dependencies() { :; }
require_build_commands() { :; }
load_profile() { :; }
validate_profile() { :; }
detect_hardware() { :; }
print_hardware_summary() { :; }
mx_as_root() { "$@"; }
mx_debian_kernel_series() { printf '6.12\n'; }
mktemp() { mkdir -p "$KF_APT_FIXTURE_DIR/work"; printf '%s/work\n' "$KF_APT_FIXTURE_DIR"; }
prepare_debian_source() {
    printf 'SOURCE_PREPARATION_REACHED\n' >&2
    printf 'FLAVOUR_SELECTION %s %s %s\n' "$KF_PREEMPT_RT" "$KF_BORE" "$2" >&2
    return 73
}
main
SCRIPT
for entry in builder.sh builder-dry-run.sh; do
    if bash "$scratch/workflow.sh" "$REPO_ROOT/$entry" >"$scratch/workflow-output" 2>&1; then
        fail 'Workflow passed the fixture source-preparation boundary.'
    else status=$?; fi
    [[ "$status" == 73 ]] || { cat "$scratch/workflow-output" >&2; fail "$entry stopped before source preparation ($status)."; }
    grep -q 'Reading package lists... Done' "$scratch/workflow-output" || fail 'Refresh was not exercised.'
    grep -q 'Debian kernel source: linux-source-6.12=6.12.107-1' "$scratch/workflow-output" || fail 'Source selection was not reached.'
    grep -qx 'SOURCE_PREPARATION_REACHED' "$scratch/workflow-output" || fail 'Source-preparation boundary was not reached.'

    for combination in no:no yes:no no:yes yes:yes; do
        first="${combination%:*}" second="${combination#*:}"
        case "$combination" in no:no) suffix='';; yes:no) suffix=-rt;; no:yes) suffix=-bore;; yes:yes) suffix=-rt-bore;; esac
        if bash "$scratch/workflow.sh" "$REPO_ROOT/$entry" <<< "$first"$'\n'"$second"$'\nn' >"$scratch/workflow-output" 2>&1; then
            fail 'Workflow passed the fixture source-preparation boundary.'
        else status=$?; fi
        [[ "$status" == 73 ]] || { cat "$scratch/workflow-output" >&2; fail "$entry did not reach source preparation for $combination."; }
        grep -qx "FLAVOUR_SELECTION $first $second mx-thinkpad-debian$suffix" "$scratch/workflow-output" || fail 'Prompt selections or flavour name were lost.'
    done

    for mode in none partial-error; do
        if KF_TEST_POLICY_MODE="$mode" bash "$scratch/workflow.sh" "$REPO_ROOT/$entry" >"$scratch/workflow-output" 2>&1; then
            fail "$entry accepted missing/failed APT metadata."
        fi
        grep -q 'ERROR:.*linux-source-6.12' "$scratch/workflow-output" || fail 'Workflow failed without a candidate diagnostic.'
        ! grep -q 'SOURCE_PREPARATION_REACHED' "$scratch/workflow-output" || fail 'Failed metadata reached source preparation.'
    done
done

if KF_TEST_UPDATE_FAIL=1 bash "$scratch/workflow.sh" "$REPO_ROOT/builder.sh" >"$scratch/workflow-output" 2>&1; then
    fail 'Failed refresh was accepted.'
fi
grep -q 'E: Fixture update failure' "$scratch/workflow-output" || fail 'APT refresh failure was hidden.'
! grep -q 'SOURCE_PREPARATION_REACHED' "$scratch/workflow-output" || fail 'Failed refresh reached source preparation.'
printf 'APT candidate parsing and builder discovery tests passed.\n'
