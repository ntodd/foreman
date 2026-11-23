"""Run a short CLI command with real terminal descriptors and report each stream separately."""
import os
import pty
import subprocess
import sys
from contextlib import ExitStack


def terminal(stack):
    master, slave = pty.openpty()
    stack.callback(os.close, master)
    stack.callback(os.close, slave)
    os.set_blocking(master, False)
    return master, slave


def output(master):
    # The slave is still open, so an empty queue ends the read on either OS.
    chunks = []
    while True:
        try:
            chunk = os.read(master, 8192)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
        except BlockingIOError:
            return b"".join(chunks)


with ExitStack() as stack:
    stdout, stdio = terminal(stack)
    stderr, diagnostic = terminal(stack)
    # 'me' emits a small document and at most one notice, both fit the PTY buffers.
    result = subprocess.run(sys.argv[1:], stdin=stdio, stdout=stdio, stderr=diagnostic, timeout=10)
    sys.stdout.buffer.write(output(stdout))
    sys.stderr.buffer.write(output(stderr))
    sys.exit(result.returncode)
