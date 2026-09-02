#!/usr/bin/env python3
"""Safe state file I/O for the PinRoutes shell plugin.

read <path>   -- print the file's content (nothing if it doesn't exist)
write <path>  -- atomically replace the file with stdin's content

Hardening: the parent directory is opened once (O_DIRECTORY|O_NOFOLLOW) and
validated (a directory, owned by the current user, not group/other-writable);
every subsequent operation is anchored to that held directory fd, so no
component of the path is re-resolved between check and use. The file itself
is opened with O_NOFOLLOW|O_NONBLOCK relative to the held fd and must be a
regular, self-owned, single-link file. Writes are atomic (O_EXCL temp +
rename within the held fd) and an over-limit payload is a hard error, never
a silent truncation.
"""
import errno
import fcntl
import os
import stat
import sys

LIMIT = 1024 * 1024


class Refused(Exception):
    pass


def open_parent(path: str, create: bool) -> int:
    directory = os.path.dirname(path) or "."
    if create:
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            pass
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise Refused(f"not a directory: {directory}")
        if st.st_uid != os.getuid():
            raise Refused(f"directory not owned by current user: {directory}")
        if st.st_mode & 0o022:
            raise Refused(f"directory writable by group/other: {directory}")
    except BaseException:
        os.close(fd)
        raise
    return fd


def open_state(dirfd: int, name: str) -> int:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dirfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Refused(f"not a regular file: {name}")
        if st.st_uid != os.getuid():
            raise Refused(f"not owned by current user: {name}")
        if st.st_nlink != 1:
            raise Refused(f"unexpected hard links: {name}")
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
    name = os.path.basename(path)
    if name in ("", ".", ".."):
        print(f"stateio: invalid file name: {path}", file=sys.stderr)
        return 2

    try:
        if mode == "read":
            try:
                dirfd = open_parent(path, create=False)
            except FileNotFoundError:
                return 0
            try:
                try:
                    fd = open_state(dirfd, name)
                except FileNotFoundError:
                    return 0
                with os.fdopen(fd, "r") as f:
                    content = f.read(LIMIT + 1)
                if len(content) > LIMIT:
                    raise Refused(f"state file exceeds limit: {name}")
                sys.stdout.write(content)
            finally:
                os.close(dirfd)
            return 0

        data = sys.stdin.read(LIMIT + 1)
        if len(data) > LIMIT:
            print("stateio: payload exceeds limit, refusing to write", file=sys.stderr)
            return 1
        dirfd = open_parent(path, create=True)
        try:
            tmpname = f".{name}.tmp.{os.getpid()}"
            fd = os.open(tmpname, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=dirfd)
            try:
                with os.fdopen(fd, "w") as f:
                    f.write(data)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmpname, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
            except BaseException:
                try:
                    os.unlink(tmpname, dir_fd=dirfd)
                except OSError:
                    pass
                raise
        finally:
            os.close(dirfd)
        return 0
    except Refused as e:
        print(f"stateio: refusing: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        if e.errno == errno.ELOOP:
            print(f"stateio: refusing: symlink in path: {path}", file=sys.stderr)
            return 1
        print(f"stateio: error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
