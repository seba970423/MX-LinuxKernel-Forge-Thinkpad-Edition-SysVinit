"""Exercise live status, exact logs, prompts, failures and cancellation."""

import errno
import importlib.util
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("progress", ROOT / "lib/progress.py")
PROGRESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROGRESS)


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.log = self.directory / "build.log"

    def shell(self, command, **options):
        return subprocess.run(
            ["bash", "-c", command, "_", str(ROOT), str(self.log)],
            capture_output=True,
            timeout=10,
            **options,
        )

    def test_elapsed_format_and_default_interval(self):
        self.assertEqual(PROGRESS.elapsed_text(30), "0m 30s")
        self.assertEqual(PROGRESS.elapsed_text(3631), "60m 31s")
        result = self.shell(
            'source "$1/lib/progress.sh"; '
            'python3() { printf "%s\\n" "${@: -1}" > "$2.interval"; cat >> "$2"; }; '
            'kernelforge_run_logged Build "$2" printf diagnostic'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(str(self.log) + ".interval").read_text(), "30\n")

    def test_quiet_output_and_complete_binary_log(self):
        self.log.write_bytes(b"previous stage\n")
        result = self.shell(
            'source "$1/lib/progress.sh"; '
            'kernelforge_run_logged Build "$2" python3 -c '
            + shlex.quote("import os; os.write(1,b'compiler stdout\\r\\n'); os.write(2,b'compiler stderr\\x00\\xff')")
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"compiler stdout", result.stderr)
        self.assertEqual(
            self.log.read_bytes(),
            b"previous stage\ncompiler stdout\r\ncompiler stderr\x00\xff",
        )

    def test_heartbeat_for_silent_and_busy_commands(self):
        for noisy in (False, True):
            with self.subTest(noisy=noisy):
                # Leave startup margin when CI is also compiling a kernel.
                producer = (
                    "import os,time\n"
                    "end=time.monotonic()+2.5\n"
                    "while time.monotonic()<end:\n"
                    + (" os.write(1,b'CC kernel/object.o\\n')\n" if noisy else "")
                    + " time.sleep(0.01)\n"
                )
                result = self.shell(
                    'source "$1/lib/progress.sh"; KERNELFORGE_PROGRESS_INTERVAL=1 '
                    'kernelforge_run_logged Build "$2" python3 -c ' + shlex.quote(producer)
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"Build still running... 0m 01s elapsed", result.stderr)
                self.assertNotIn(b"CC kernel/object.o", result.stderr)

    def test_command_failure_survives_without_pipefail(self):
        result = self.shell(
            'set +o pipefail; source "$1/lib/progress.sh"; '
            'if kernelforge_run_logged Build "$2" bash -c "echo dependency-error >&2; exit 7"; '
            'then exit 99; else exit "$?"; fi'
        )
        self.assertEqual(result.returncode, 7)
        self.assertIn(b"dependency-error", result.stderr)
        self.assertIn(b"failed (exit 7)", result.stderr)
        self.assertEqual(self.log.read_text(), "dependency-error\n")

    def test_failed_logger_stops_the_run(self):
        result = self.shell(
            'source "$1/lib/progress.sh"; '
            'kernelforge_run_logged Build /dev/full printf diagnostic'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Could not save command output", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)

    def test_invalid_interval_does_not_start_command(self):
        for interval in ("0", "-1", "oops"):
            result = self.shell(
                'source "$1/lib/progress.sh"; KERNELFORGE_PROGRESS_INTERVAL='
                + shlex.quote(interval)
                + ' kernelforge_run_logged Build "$2" touch "$2.started"'
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(Path(str(self.log) + ".started").exists())

    def test_ctrl_c_stops_command_and_reporter(self):
        marker = self.directory / "child.pid"
        producer = (
            "import os,time; from pathlib import Path; "
            f"Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(60)"
        )
        process = subprocess.Popen(
            [
                "bash", "-c",
                'source "$1/lib/progress.sh"; kernelforge_run_logged Build "$2" python3 -c "$3"',
                "_", str(ROOT), str(self.log), producer,
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 3
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists(), "Producer did not start")
            child = int(marker.read_text())
            os.killpg(process.pid, signal.SIGINT)
            _, error = process.communicate(timeout=3)
            self.assertIn(process.returncode, (130, -signal.SIGINT), error)
            self.assertNotIn(b"Traceback", error)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)

    def test_preparation_failure_excerpt_is_bounded(self):
        package = self.directory / "checkout/linux-debian-6.12"
        package.mkdir(parents=True)
        result = self.shell(
            'set -euo pipefail; source "$1/lib/sources.sh"; '
            'KF_DEBIAN_VERSION=6.12.107-1 KF_DEBIAN_SERIES=6.12; '
            "mx_download_debian_packages() { bash -c 'for ((i=0;i<200;i++)); do echo compiler-line-$i; done; echo actual-prepare-error >&2; exit 7'; }; "
            f"prepare_debian_source {shlex.quote(str(package))} mx-thinkpad-debian"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"actual-prepare-error", result.stderr)
        self.assertNotIn(b"compiler-line-0\n", result.stderr)
        self.assertLess(len(result.stderr.splitlines()), 100)
        log = (package / ".kernelforge-prepare.log").read_text()
        self.assertIn("compiler-line-0\n", log)
        self.assertIn("compiler-line-199\n", log)
        self.assertLess(len(log.splitlines()), 300)

    def test_preparation_prompt_remains_visible_before_answer(self):
        package = self.directory / "prompt-test"
        package.mkdir()
        command = (
            'set -euo pipefail; source "$1/lib/debian.sh"; source "$1/lib/progress.sh"; test_log="$2"; '
            'dpkg-query() { [[ "${!#}" == libdw-dev ]] || printf installed; }; '
            'mx_as_root() { kernelforge_run_logged Dependencies "$test_log" printf "unreadable-compiler-chatter\\n"; }; '
            'mx_ensure_base_dependencies; printf "RESULT=dependencies-ready\\n"'
        )
        pid, terminal = pty.fork()
        if pid == 0:
            os.execlp("bash", "bash", "-c", command, "_", str(ROOT), str(self.log))
        output = b""
        try:
            deadline = time.monotonic() + 5
            answered = False
            while time.monotonic() < deadline:
                if not select.select([terminal], [], [], 0.1)[0]:
                    continue
                try:
                    data = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                output += data
                if b"[Y/n]: " in output and not answered:
                    os.write(terminal, b"y\n")
                    answered = True
            self.assertTrue(answered, output)
            self.assertIn(b"RESULT=dependencies-ready", output)
            self.assertNotIn(b"unreadable-compiler-chatter", output)
            log = self.log.read_text()
            self.assertIn("unreadable-compiler-chatter", log)
            self.assertIn(b"Install these dependencies through APT?", output)
        finally:
            os.close(terminal)
            waited, _ = os.waitpid(pid, os.WNOHANG)
            if not waited:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)


if __name__ == "__main__":
    unittest.main()
