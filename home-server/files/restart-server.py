#!/usr/bin/env python3
"""
Restart both Pis: first the ML Pi, then the main server.

The main server (this machine) goes last, otherwise the script would be
gone before the ML Pi is back.

The ML Pi is restarted with ~/.ssh/id_mlpi_reboot. On the ML Pi that key is
bound to "sudo systemctl reboot": every connection with it reboots the
ML Pi, whatever command is sent. It is useless for looking around.

Usage
-----
  ./restart-server.py              ask, then restart both
  ./restart-server.py --yes        no question
  ./restart-server.py --ml-only    only the ML Pi
  ./restart-server.py --here-only  only the main server
  ./restart-server.py --check      restart nothing, show the state
"""

import os
import socket
import subprocess
import sys
import time

# ---- adjust to your setup -------------------------------------------------
ML_HOST = "192.168.0.11"
ML_USER = "pi-admin"
ML_KEY = os.path.expanduser("~/.ssh/id_mlpi_reboot")
DOWN = 120   # seconds until the ML Pi has to be gone
UP = 300     # seconds until it should be back
# ---------------------------------------------------------------------------


def reachable(host, port=22, timeout=3):
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except OSError:
        return False


def wait(condition, seconds, text):
    end = time.time() + seconds
    while time.time() < end:
        if condition():
            return True
        print(f"  {text} ({int(end - time.time())}s)", end="\r", flush=True)
        time.sleep(3)
    return False


def running_containers():
    r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    return [c for c in r.stdout.split() if c]


def restart_ml():
    r = subprocess.run(["ssh", "-i", ML_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                        f"{ML_USER}@{ML_HOST}", "sudo -n /usr/bin/systemctl reboot"],
                       capture_output=True, text=True)
    # The reboot cuts the connection, so exit code 255 is expected.
    if r.returncode not in (0, 255):
        print(f"  SSH error ({r.returncode}): {(r.stderr or '').strip()[:200]}")
        return False
    if not wait(lambda: not reachable(ML_HOST), DOWN, "waiting for shutdown"):
        print("  ML Pi still answers, the reboot did not happen.")
        return False
    print("  ML Pi is shutting down.                  ")
    if wait(lambda: reachable(ML_HOST), UP, "waiting for boot"):
        print("  ML Pi is back.                         ")
        return True
    print(f"  ML Pi not back after {UP}s, check it yourself.")
    return False


def restart_here():
    print("  Restarting the main server now, the connection will drop.")
    sys.stdout.flush()
    r = subprocess.run(["sudo", "systemctl", "reboot"])
    if r.returncode != 0:
        sys.exit(f"Reboot failed (exit code {r.returncode}).")


def state():
    print(f"ML Pi {ML_HOST}: " + ("reachable" if reachable(ML_HOST) else "NOT reachable"))
    if not os.path.exists(ML_KEY):
        print(f"Reboot key {ML_KEY}: MISSING, the ML Pi cannot be restarted.")
    up = subprocess.run(["uptime", "-p"], capture_output=True, text=True).stdout.strip()
    print(f"Main server: {up}")
    print("Running containers: " + (", ".join(running_containers()) or "none"))


def main():
    args = set(sys.argv[1:])
    unknown = args - {"--yes", "--ml-only", "--here-only", "--check"}
    if unknown:
        sys.exit(f"Unknown option: {' '.join(sorted(unknown))}\n{__doc__}")

    state()
    if "--check" in args:
        return

    ml = "--here-only" not in args
    here = "--ml-only" not in args
    if ml and not os.path.exists(ML_KEY):
        sys.exit(f"Aborted: {ML_KEY} is missing.")
    what = " and ".join(x for x, on in (("ML Pi", ml), ("main server", here)) if on)

    if "--yes" not in args:
        if input(f"\nRestart {what}? [y/N] ").strip().lower() not in ("y", "yes"):
            sys.exit("Aborted.")

    if ml:
        print("\n== Restarting the ML Pi ==")
        if not reachable(ML_HOST):
            print(f"  {ML_HOST} is not reachable, skipped.")
        elif not restart_ml() and here and "--yes" not in args:
            if input("  Restart the main server anyway? [y/N] ").strip().lower() not in ("y", "yes"):
                sys.exit("Aborted.")

    if here:
        print("\n== Restarting the main server ==")
        restart_here()


if __name__ == "__main__":
    main()
