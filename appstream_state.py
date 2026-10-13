#!/usr/bin/env python3
"""Owner-checked, no-follow state/cache transactions for FossFetch.

Every write, atomic replace, and recursive delete that FossFetch performs under
the user's home lives here.  Paths are never used blindly: the full chain is
walked one directory descriptor at a time with O_NOFOLLOW (a symlink anywhere
in the chain is refused) and every directory is verified to be owned by the
effective user, or a non-writable system directory above the user's first
writable one.  No directory is ever opened without that check, so an attacker
who can only plant symlinks/foreign dirs in shared locations cannot redirect
writes or lure a recursive delete outside the catalog.

Commands (cacheRoot is the script cache root, usually $HOME/.cache/fossfetch):

  ensure <cacheRoot>                create <cacheRoot>/catalog owner-checked.
  tmpdir <cacheRoot>                create <cacheRoot>/catalog/.tmp.<rand> (0700),
                                    print the basename.
  tmpfile <cacheRoot> <ver> <prefix>  create <catalog>/<ver>/<prefix>.<rand>
                                    (0600, O_EXCL), print "<ver>/<basename>".
  put <cacheRoot> <rel>             atomically write stdin to catalog/<rel>
                                    (temp + rename, never following a symlink).
  swap <cacheRoot> <src> <dst>      atomically move catalog/<src> onto
                                    catalog/<dst> (old <dst> to <src>.old then
                                    dropped); both <dst> and <src> are rel to
                                    catalog/.
  rmtree <cacheRoot> <rel>          recursively delete catalog/<rel> via fds,
                                    never following symlinks, and only entries
                                    owned by the effective user.
  rmtmp <cacheRoot>                 delete stale catalog/.tmp.* and catalog/*.old.
                                    Callers run it to complete a build: after
                                    the new catalog is swapped in and "current"
                                    is written, so a fresh marker never coexists
                                    with transient build leftovers.
  prune <cacheRoot> <keep>          delete every owned catalog entry except
                                    <keep> (and transient .tmp.* / *.old).
                                    Transients are the reap's job, run after the
                                    swap commits (see rmtmp).
  write-options <path>              atomically write stdin to <path>
                                    (default $HOME/.local/state/omarchy/settings/
                                    davedes.fossfetch.json), owner-checked.
"""

import errno
import os
import secrets
import stat
import sys

ROOT = "/"
O_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
EUID = os.geteuid()


def fail(msg):
    sys.stderr.write("appstream_state: %s\n" % msg)
    sys.exit(1)


def _open_at(fd, name, flags=O_DIR, create=False, mode=0o700):
    try:
        if fd is None:
            return os.open(name, flags)
        return os.open(name, flags, dir_fd=fd)
    except OSError as e:
        if e.errno != errno.ENOENT or not create:
            raise
    if fd is not None:
        os.mkdir(name, mode, dir_fd=fd)
    else:
        os.mkdir(name, mode)
    return os.open(name, flags, dir_fd=fd) if fd is not None else os.open(name, flags)


def _check_owned(st, label):
    if not stat.S_ISDIR(st.st_mode):
        raise OSError(errno.ENOTDIR, "%s is not a directory" % label)
    if st.st_uid == EUID:
        return
    # Not owned by us: acceptable only if a current-user write cannot reach it,
    # i.e. no group/other write bit, otherwise a shared dir could be tampered.
    if stat.S_IMODE(st.st_mode) & 0o022:
        raise OSError(errno.EACCES,
                      "%s is not owned by user %d and is writable by others" %
                      (label, EUID))


def open_chain(path, create=False):
    """Walk an absolute path with O_NOFOLLOW dirfds, owner-checking each dir.

    Returns the final directory fd (or an OSError).  Missing components are
    created only when `create` is set, each as a fresh 0700 dir owned by us.
    """
    if not isinstance(path, str) or not os.path.isabs(path):
        raise OSError(errno.EINVAL, "absolute path required")
    parts = [p for p in path.split("/") if p]
    if not parts:
        return _open_at(None, ROOT)
    fd = _open_at(None, ROOT)
    try:
        for i, part in enumerate(parts):
            try:
                nfd = _open_at(fd, part, create=create, mode=0o700)
            except OSError as e:
                if e.errno == errno.ELOOP:
                    raise OSError(errno.ELOOP,
                                  "symlink component in path: .../%s" % part)
                raise OSError(e.errno,
                              "cannot open .../%s: %s" % (part, e.strerror or e))
            _check_owned(os.fstat(nfd), ".../%s" % part)
            os.close(fd)
            fd = nfd
        return fd
    except Exception:
        os.close(fd)
        raise


def open_catalog(cache_root, create=False):
    return open_chain(os.path.join(cache_root, "catalog"), create=create)


def open_sub(fd, rel):
    """Open a pre-existing subdirectory path relative to catalog using fds.

    Each component is opened from the descriptor of the previous one, and every
    intermediate descriptor is released as soon as its child is in hand — the
    previous version reassigned the loop variable without closing it, leaking one
    fd per path component. The descriptor the caller passes in is left open:
    callers still own it and close it themselves.
    """
    current = fd
    opened = []
    try:
        for part in rel.split("/"):
            if not part or part in (".", ".."):
                raise OSError(errno.EINVAL, "bad relative component: %r" % part)
            nfd = _open_at(current, part)
            _check_owned(os.fstat(nfd), ".../" + part)
            if current is not fd:
                os.close(current)
            current = nfd
            opened.append(nfd)
    except Exception:
        # Close only what this call opened — never the caller's descriptor.
        for nfd in opened:
            try:
                os.close(nfd)
            except OSError:
                pass
        raise
    return current


def check_rel(rel, what="path"):
    """Reject a catalog-relative path that could climb out of the catalog.

    The fd-based openers already refuse a ".."/"." component (O_NOFOLLOW plus
    open_sub's own check), but a relative path is also passed straight to
    os.lstat/os.unlink/os.open by name, so the NAME has to be sane before it is
    used at all. Leading "/" and empty components are refused too: an empty
    component means "//" or a trailing "/", neither of which names a real entry.
    """
    if not isinstance(rel, str) or rel == "":
        raise OSError(errno.EINVAL, "empty %s" % what)
    if rel.startswith("/"):
        raise OSError(errno.EINVAL, "%s must be relative to the catalog: %r" % (what, rel))
    for c in rel.split("/"):
        if c in ("", ".", ".."):
            raise OSError(errno.EINVAL, "bad %s component in %r" % (what, rel))
    return rel


def check_simple(name, what):
    """A single path component: no separator, no traversal, no hidden surprise."""
    check_rel(name, what)
    if "/" in name:
        raise OSError(errno.EINVAL, "%s must be a single name: %r" % (what, name))
    return name


def need_args(args, n, usage):
    if len(args) < n:
        fail("usage: appstream_state.py %s" % usage)


def exists(fd, name):
    try:
        os.lstat(name, dir_fd=fd)
        return True
    except OSError as e:
        if e.errno == errno.ENOENT:
            return False
        raise


def lstat_owned(fd, name):
    st = os.lstat(name, dir_fd=fd)
    if not stat.S_ISLNK(st.st_mode) and st.st_uid != EUID:
        raise OSError(errno.EACCES,
                      "refusing to touch %r: owned by uid %d" % (name, st.st_uid))
    return st


def rmtree(fd, name):
    """Recursively delete <name> inside fd, never following symlinks, only
    deleting entries owned by the effective user."""
    st = lstat_owned(fd, name)
    if stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode):
        sub = _open_at(fd, name)
        try:
            for child in os.listdir(sub):
                rmtree(sub, child)
        finally:
            os.close(sub)
        if st.st_uid == EUID:
            os.rmdir(name, dir_fd=fd)
    else:
        os.unlink(name, dir_fd=fd)


def write_file_at(fd, name, data, mode=0o600):
    """Atomic replace of <name> inside fd: fresh temp + rename, O_NOFOLLOW.
    Rename replaces a pre-existing symlink entry itself (never its target)."""
    tmp = ".fossfetch." + secrets.token_hex(8) + ".tmp"
    try:
        tf = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=fd)
    except OSError as e:
        # Unwritable placeholder?  refuse rather than write through it.
        fail("cannot create temp in dir: %s" % e)
    try:
        view = memoryview(data)
        while view:
            n = os.write(tf, view)
            view = view[n:]
    except OSError as e:
        os.close(tf)
        os.unlink(tmp, dir_fd=fd)
        fail("write failed: %s" % e)
    try:
        os.fsync(tf)
    except OSError:
        pass
    os.close(tf)
    os.chmod(tmp, mode, dir_fd=fd)
    os.rename(tmp, name, src_dir_fd=fd, dst_dir_fd=fd)


def cmd_ensure(args):
    fd = open_catalog(args[0], create=True)
    os.close(fd)


def cmd_tmpdir(args):
    fd = open_catalog(args[0])
    name = ".tmp." + secrets.token_hex(6)
    _open_at(fd, name, create=True, mode=0o700)
    print(name)
    os.close(fd)


def cmd_tmpfile(args):
    need_args(args, 3, "tmpfile <cacheRoot> <ver> <prefix>")
    cache, ver, prefix = args[:3]
    # Both names become entries inside the catalog: <ver> is opened as a
    # directory, <prefix> as the stem of a new file. A "../" in either would
    # land the file outside the catalog, so they are checked before any open.
    check_simple(ver, "version")
    check_simple(prefix, "prefix")
    store = open_catalog(cache)
    vfd = _open_at(store, ver, create=True, mode=0o700)
    _check_owned(os.fstat(vfd), ".../" + ver)
    name = "%s.%s" % (prefix, secrets.token_hex(6))
    try:
        tf = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=vfd)
        os.close(tf)
    except OSError as e:
        os.close(vfd)
        os.close(store)
        fail("tmpfile: %s" % e)
    print("%s/%s" % (ver, name))
    os.close(vfd)
    os.close(store)


def cmd_put(args):
    need_args(args, 2, "put <cacheRoot> <rel>")
    data = sys.stdin.buffer.read()
    # Validate before opening anything, so a bad name costs no descriptor.
    rel = check_rel(args[1], "put path")
    store = open_catalog(args[0])
    if "/" in rel:
        parts = rel.rsplit("/", 1)
        sub = open_sub(store, parts[0])
        write_file_at(sub, parts[1], data)
        os.close(sub)
    else:
        write_file_at(store, rel, data)
    os.close(store)


def _ensure_absent(fd, name):
    if exists(fd, name):
        rmtree(fd, name)


def cmd_swap(args):
    need_args(args, 3, "swap <cacheRoot> <src> <dst>")
    cache, src, dst = args[:3]
    # Same check as the rest of the catalog operations, so swap's rule is one
    # helper rather than a loop that can drift from the others.
    check_rel(src, "swap source")
    check_rel(dst, "swap destination")
    store = open_catalog(cache)
    _ensure_absent(store, src + ".old")
    if exists(store, dst):
        os.rename(dst, src + ".old", src_dir_fd=store, dst_dir_fd=store)
    try:
        if not exists(store, src):
            # Nothing to swap in: restore dst if we moved it aside.
            if exists(store, src + ".old"):
                os.rename(src + ".old", dst, src_dir_fd=store, dst_dir_fd=store)
            os.close(store)
            fail("swap source missing: %s" % src)
        os.rename(src, dst, src_dir_fd=store, dst_dir_fd=store)
    except Exception as e:
        try:
            _ensure_absent(store, src)
            if exists(store, src + ".old"):
                os.rename(src + ".old", dst, src_dir_fd=store, dst_dir_fd=store)
        except OSError:
            pass
        os.close(store)
        fail("swap failed: %s" % e)
    _ensure_absent(store, src + ".old")
    os.close(store)


def cmd_rmtree(args):
    # Missing arguments used to raise ValueError out of the tuple unpack and
    # print a traceback; that is a usage error, so it says so and exits 1.
    need_args(args, 2, "rmtree <cacheRoot> <rel>")
    cache, rel = args[:2]
    check_rel(rel, "rmtree path")
    store = open_catalog(cache)
    try:
        if "/" in rel:
            parts = rel.rsplit("/", 1)
            sub = open_sub(store, parts[0])
            rmtree(sub, parts[1])
            os.close(sub)
        else:
            rmtree(store, rel)
    finally:
        os.close(store)


def cmd_rmtmp(args):
    store = open_catalog(args[0])
    try:
        for name in os.listdir(store):
            if name.startswith(".tmp.") or name.endswith(".old"):
                rmtree(store, name)
    finally:
        os.close(store)


def cmd_prune(args):
    need_args(args, 2, "prune <cacheRoot> <keep>")
    cache, keep = args[:2]
    check_rel(keep, "prune keep")
    store = open_catalog(cache)
    try:
        for name in os.listdir(store):
            if (name == keep or name == "current"
                    or name.startswith(".tmp.") or name.endswith(".old")):
                continue
            rmtree(store, name)
    finally:
        os.close(store)


def cmd_write_options(args):
    path = args[0] if args else os.path.join(
        os.environ.get("HOME", "/"),
        ".local", "state", "omarchy", "settings", "davedes.fossfetch.json")
    parent = os.path.dirname(path)
    fd = open_chain(parent, create=True)
    try:
        write_file_at(fd, os.path.basename(path), sys.stdin.buffer.read())
    finally:
        os.close(fd)


def main():
    try:
        if len(sys.argv) < 2:
            fail("usage: appstream_state.py <command> ...")
        cmd = sys.argv[1]
        args = sys.argv[2:]
        table = {
            "ensure": cmd_ensure,
            "tmpdir": cmd_tmpdir,
            "tmpfile": cmd_tmpfile,
            "put": cmd_put,
            "swap": cmd_swap,
            "rmtree": cmd_rmtree,
            "rmtmp": cmd_rmtmp,
            "prune": cmd_prune,
            "write-options": cmd_write_options,
        }
        if cmd not in table:
            fail("unknown command: %s" % cmd)
        table[cmd](args)
    except OSError as e:
        sys.stderr.write("appstream_state: %s\n" % (e.strerror or e))
        sys.exit(2)


if __name__ == "__main__":
    main()