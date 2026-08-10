#!/usr/bin/env python3
"""Drive `age` through a pty so secretsd can own the passphrase prompt.

`age --passphrase` insists on reading from a terminal and echoes nothing, which
is exactly the confusing behaviour we are replacing. This spawns age on a pty and
supplies the passphrase, so the user types once into secretsd's own masked prompt
— with visible feedback — instead of into two silent age prompts.

The passphrase arrives on THIS process's stdin and is written straight to the
pty. It is never an argument (argv is world-readable via ps) and never an
environment variable (readable via /proc on Linux).

usage: agepty.py encrypt IN OUT      # passphrase on stdin
       agepty.py decrypt IN OUT      # passphrase on stdin
"""
import os, pty, select, sys, time

def run(mode, src, dst):
    passphrase = sys.stdin.buffer.readline().rstrip(b"\r\n")
    if not passphrase:
        sys.stderr.write("no passphrase supplied\n"); return 2

    args = (["age", "--passphrase", "-o", dst, src] if mode == "encrypt"
            else ["age", "-d", "-o", dst, src])

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(args[0], args)

    sent = 0
    expect = 2 if mode == "encrypt" else 1   # encrypt asks twice (confirm)
    out = b""
    deadline = time.time() + 120
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            # age prompts with "passphrase" (case varies by version)
            low = chunk.lower()
            if b"passphrase" in low and sent < expect:
                os.write(fd, passphrase + b"\n")
                sent += 1
        else:
            pid_done, status = os.waitpid(pid, os.WNOHANG)
            if pid_done:
                rc = os.waitstatus_to_exitcode(status)
                break
    else:
        os.kill(pid, 9); sys.stderr.write("age timed out\n"); return 3

    try:
        _, status = os.waitpid(pid, 0)
        rc = os.waitstatus_to_exitcode(status)
    except ChildProcessError:
        pass

    passphrase = b""
    if rc != 0:
        tail = out.decode("utf-8", "replace").strip().splitlines()[-3:]
        for line in tail:
            if "passphrase" not in line.lower():
                sys.stderr.write(line + "\n")
    return rc

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__); sys.exit(64)
    sys.exit(run(sys.argv[1], sys.argv[2], sys.argv[3]))
