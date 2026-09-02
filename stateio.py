#!/usr/bin/env python3
"""Safe state file I/O for the PinRoutes shell plugin.

read <path>   -- print the file's content (nothing if it doesn't exist)
write <path>  -- atomically replace the file with stdin's content

Hardening: opens with O_NOFOLLOW|O_NONBLOCK so a symlink is refused and a
planted FIFO cannot block the shell; after opening, fstat must show a regular
file owned by the current user with a single hard link. Payloads are bounded,
and writes go through a same-directory temp file + rename so a crash
mid-write never corrupts the config.
"""
import fcntl
import os
import stat
import sys
import tempfile

LIMIT = 1024 * 1024


def open_checked(path: str) -> int:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(f"not a regular file: {path}")
        if st.st_uid != os.getuid():
            raise OSError(f"not owned by current user: {path}")
        if st.st_nlink != 1:
            raise OSError(f"unexpected hard links: {path}")
        # Regular-file reads never block; drop O_NONBLOCK now that the type
        # check passed so nothing downstream trips over the flag.
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("read", "write"):
        print("usage: stateio.py read|write <path>", file=sys.stderr)
        return 2
    mode, path = sys.argv[1], sys.argv[2]

    if mode == "read":
        try:
            fd = open_checked(path)
        except FileNotFoundError:
            return 0
        except OSError as e:
            print(f"stateio: refusing to read: {e}", file=sys.stderr)
            return 1
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
