#!/usr/bin/env python3
"""Safe state file I/O for the PinRoutes shell plugin.

read <path>   -- print the file's content (nothing if it doesn't exist)
write <path>  -- atomically replace the file with stdin's content

Opens with O_NOFOLLOW so a symlinked state path is refused, bounds the
payload, and writes via a same-directory temp file + rename so a crash
mid-write never corrupts the config.
"""
import os
import sys
import tempfile

LIMIT = 1024 * 1024


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("read", "write"):
        print("usage: stateio.py read|write <path>", file=sys.stderr)
        return 2
    mode, path = sys.argv[1], sys.argv[2]

    if mode == "read":
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return 0
        with os.fdopen(fd, "r") as f:
            sys.stdout.write(f.read(LIMIT))
        return 0

    data = sys.stdin.read(LIMIT)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".pinroutes-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
