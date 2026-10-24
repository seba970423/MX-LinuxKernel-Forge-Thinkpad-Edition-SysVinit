"""Save a command's complete output while reporting elapsed time every 30s."""

import os
import selectors
import sys
import time


def elapsed_text(seconds):
    seconds = int(seconds)
    return f"{seconds // 60}m {seconds % 60:02d}s"


def monitor(source, log_path, label, interval=30):
    started = time.monotonic()
    deadline = started + interval
    # Unbuffered append also permits the preparation wrapper's tee -a to
    # record foreground questions/status messages in the same log safely.
    with open(log_path, "ab", buffering=0) as log, selectors.DefaultSelector() as events:
        events.register(source, selectors.EVENT_READ)
        while True:
            ready = events.select(max(0, deadline - time.monotonic()))
            if ready:
                data = os.read(source.fileno(), 65536)
                if not data:
                    return
                view = memoryview(data)
                while view:
                    written = log.write(view)
                    if not written:
                        raise OSError("The log could not be written")
                    view = view[written:]
            now = time.monotonic()
            if now >= deadline:
                print(
                    f"==> {label} still running... {elapsed_text(now - started)} elapsed",
                    flush=True,
                )
                deadline = now + interval


def main():
    log_path, label, interval = sys.argv[1:]
    try:
        monitor(sys.stdin.buffer, log_path, label, int(interval))
    except KeyboardInterrupt:
        return 130
    except OSError as error:
        print(f"ERROR: Could not save command output to {log_path}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
