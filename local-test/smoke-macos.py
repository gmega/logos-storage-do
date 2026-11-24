"""Drive the installed TUI through a terminal on the native macOS runner."""
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path

root = Path(sys.argv[1])
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 100, 0, 0))
env = os.environ.copy()
env.pop("LOGOS_DEVNET_HOME", None)  # Discover the installation beside the binary.
env["TERM"] = "xterm"
proc = subprocess.Popen([root / "logos-devnet"], stdin=slave, stdout=slave, stderr=slave, env=env)
os.close(slave)


def wait_for(predicate, seconds=100):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.25)[0]:
            os.read(master, 65536)
        if predicate():
            return
        if proc.poll() is not None:
            break
    raise RuntimeError("TUI did not reach expected state")


try:
    os.write(master, b"s")
    status = root / "status.txt"
    wait_for(lambda: status.exists() and "DHT peers" in status.read_text())
    os.write(master, b"x")
    wait_for(lambda: "Daemon shutting down" in (root / "daemon.log").read_text())
    time.sleep(1)
    os.write(master, b"q")
    assert proc.wait(timeout=10) == 0
except Exception:
    log = root / "daemon.log"
    if log.exists():
        print(log.read_text(errors="replace")[-6000:])
    raise
finally:
    if proc.poll() is None:
        proc.terminate()
    os.close(master)
