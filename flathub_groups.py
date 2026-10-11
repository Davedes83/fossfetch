#!/usr/bin/env python3
# Build and query a category->Flathub-apps index from Flathub's published
# AppStream catalog. Usage:
#   flathub_groups.py ensure <cacheRoot>
#   flathub_groups.py resolve <cacheRoot> <keyword...>
#
# `ensure` downloads Flathub's appstream.xml.gz, extracts every <category> ->
# <appid> edge (with the app's display name + summary) into a compact merged
# file, <cacheRoot>/flathub/groups.tsv, reusing the same 32-day staleness
# marker as the Arch AppStream catalog. The raw XML is discarded.
#
# `resolve` maps a natural-language keyword (via the shared groups.keywords
# table) to AppStream categories and prints "appid<TAB>name<TAB>summary" per
# matching app, deduplicated. Prints nothing when the keyword matches no group.

import gzip
import io
import os
import re
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

BASE = os.environ.get(
    "FLATHUB_APPSTREAM_URL",
    "https://dl.flathub.org/repo/appstream/x86_64/appstream.xml.gz",
)
STALE_DAYS = 32
MAX_RAW = int(os.environ.get("FOSSFETCH_MAX_RAW", "67108864"))  # 64 MiB compressed
MAX_OUT = int(os.environ.get("FOSSFETCH_MAX_OUT", "536870912"))  # 512 MiB decompressed


def fetch_bytes(url, cap, timeout=90):
    """Bounded download: rejects a declared Content-Length over `cap` and
    aborts once `cap` actual bytes have been read (covers chunked responses)."""
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        declared = resp.headers.get("Content-Length")
        if declared is not None:
            try:
                if int(declared) > cap:
                    return None
            except ValueError:
                pass
        data = bytearray()
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > cap:
                return None
    return bytes(data)


class _QuotaExceeded(Exception):
    pass


class _BoundedReader:
    """Read wrapper that refuses to hand out more than `cap` decompressed bytes.

    This is what replaces the old "decompress the whole thing into a bytearray"
    step: the parser pulls chunks on demand, so peak memory is the chunk size
    plus whatever the parser retains (a single <component>), not the whole
    ~48 MiB catalogue. The quota is still enforced, so a gzip bomb aborts
    instead of filling RAM.
    """

    def __init__(self, stream, cap):
        self._stream = stream
        self._cap = cap
        self._seen = 0

    def read(self, size=-1):
        # Clamp the request: iterparse normally asks for 16 KiB, but a caller
        # asking for -1 would otherwise pull the entire decompression bomb into
        # one buffer before the quota could be checked.
        if size is None or size < 0 or size > 65536:
            size = 65536
        chunk = self._stream.read(size)
        self._seen += len(chunk)
        if self._seen > self._cap:
            raise _QuotaExceeded()
        return chunk

    # iterparse only needs read(), but be explicit for anything else.
    def readable(self):
        return True

    def close(self):
        self._stream.close()


def _drop_component(tree_root, elem):
    """Release a finished <component> so the parser does not retain the document.

    stdlib ElementTree keeps every element attached to its parent, so clear()
    alone still grows the tree to the full catalogue size. The finished element
    is always the first child of the root (we visit in document order), so
    dropping index 0 keeps the remaining list short.
    """
    elem.clear()
    if tree_root is None:
        return
    children = list(tree_root)
    if children and children[0] is elem:
        del tree_root[0]


def iter_components(raw, cap):
    """Yield every desktop <component> element from a gzipped AppStream catalogue.

    Streams the archive through a bounded reader and an XMLPullParser, so peak
    memory is one chunk plus one component instead of the whole ~48 MiB
    document. Raises _QuotaExceeded if the stream passes `cap` decompressed
    bytes, so a gzip bomb aborts rather than filling RAM.
    """
    stream = gzip.GzipFile(fileobj=io.BytesIO(raw), mode="rb")
    reader = _BoundedReader(stream, cap)
    parser = ET.XMLPullParser(events=("start", "end"))
    tree_root = None
    try:
        while True:
            chunk = reader.read(65536)
            if not chunk:
                break
            parser.feed(chunk)
            for event, elem in parser.read_events():
                if event == "start":
                    if tree_root is None:
                        tree_root = elem
                    continue
                if elem.tag != "component":
                    continue
                wanted = elem.get("type") in ("desktop-application", "desktop")
                if wanted:
                    yield elem
                _drop_component(tree_root, elem)
        parser.close()
    finally:
        try:
            stream.close()
        except Exception:
            pass


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


def clean(value):
    """Flatten a value into a single TSV-safe field.

    Every field written to groups.tsv / appids.tsv comes from remote AppStream
    metadata, which may legally contain tabs, CRs or newlines. Those would
    silently corrupt the line-oriented index: a newline in a <name> or <summary>
    splits one record into two, and resolve() would then emit the tail as a
    phantom row with a garbage appid. Collapse all whitespace that would break
    the format, mirroring aur_search.py's cleanup().
    """
    return re.sub(r"[\t\r\n]+", " ", str(value or "")).strip()


def load_synonyms():
    syn = {}
    path = os.path.join(script_dir(), "groups.keywords")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "\t" not in line:
                    continue
                word, cats = line.split("\t", 1)
                syn[word.strip()] = [c.strip() for c in cats.split(",") if c.strip()]
    except OSError:
        pass
    return syn


def cache_root(arg):
    return arg if arg else os.path.expanduser("~/.cache/fossfetch")


def stale(root):
    marker = os.path.join(root, "flathub", "current")
    if not os.path.exists(marker):
        return True
    try:
        age = (time.time() - os.path.getmtime(marker)) / 86400
        return age > STALE_DAYS
    except Exception:
        return True


def _flathub_dir(root):
    return os.path.join(root, "flathub")


def _touch(root, name):
    try:
        os.makedirs(_flathub_dir(root), exist_ok=True)
        with open(os.path.join(_flathub_dir(root), name), "a"):
            pass
    except OSError:
        pass


def _drop(root, name):
    try:
        os.unlink(os.path.join(_flathub_dir(root), name))
    except OSError:
        pass


def build_running(root):
    return os.path.exists(os.path.join(_flathub_dir(root), ".building"))


def failure_count(root):
    try:
        with open(os.path.join(_flathub_dir(root), ".failed")) as fh:
            n = int(fh.read().strip() or "0")
        return max(0, n)
    except (OSError, ValueError):
        return 0


def mark_failed(root):
    # Read the count BEFORE opening for write: open(..., "w") truncates, so
    # counting first would pin the marker at 1 and freeze the backoff at base.
    n = failure_count(root) + 1
    try:
        os.makedirs(_flathub_dir(root), exist_ok=True)
        with open(os.path.join(_flathub_dir(root), ".failed"), "w") as fh:
            fh.write(str(n))
    except OSError:
        pass


def backoff_window(root):
    """Retry window for the current failure count: base * 2^(n-1), clamped.

    Grows rather than sitting at a fixed maximum so a brief outage costs a
    minute of staleness instead of locking the index out for hours, while a
    sustained outage is not retried on every single search.
    """
    n = failure_count(root)
    if n <= 0:
        return 0.0
    base = float(os.environ.get("FOSSFETCH_CATALOG_BACKOFF_SECONDS", "60"))
    cap = float(os.environ.get("FOSSFETCH_CATALOG_BACKOFF_MAX_SECONDS", "21600"))
    return min(base * (2 ** (n - 1)), cap)


def backoff_active(root):
    """True when a recent build attempt failed inside the retry window.

    Without this an offline machine re-attempts a ~10 MB download on EVERY
    search — resolve() runs on the search path — so a missing network turns
    every keystroke into a stalled panel instead of a served local index.
    """
    marker = os.path.join(_flathub_dir(root), ".failed")
    window = backoff_window(root)
    if window <= 0:
        return False
    try:
        return (time.time() - os.path.getmtime(marker)) < window
    except OSError:
        return False


def refresh_in_background(root):
    """Kick off a detached rebuild so the NEXT search sees fresh data.

    Never blocks the caller: the current (stale) index is served immediately
    and this picks up the result later.
    """
    if build_running(root) or backoff_active(root):
        return
    _touch(root, ".building")
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "ensure", root],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception:
        _drop(root, ".building")


def ensure(root):
    groups_dir = _flathub_dir(root)
    os.makedirs(groups_dir, exist_ok=True)
    target = os.path.join(groups_dir, "groups.tsv")
    # names.tsv is part of the build output now, so its absence (a cache made
    # by an older version) must force one rebuild.
    if os.path.exists(target) and os.path.exists(os.path.join(groups_dir, "names.tsv")) \
            and not stale(root):
        print("flathub groups fresh", file=sys.stderr)
        return True
    if build_running(root):
        return False
    if backoff_active(root):
        print("flathub groups: backing off after a recent failed build", file=sys.stderr)
        return False
    _touch(root, ".building")
    ok = _build(root)
    _drop(root, ".building")
    if ok:
        _drop(root, ".failed")
    else:
        mark_failed(root)
    return ok


XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"


def _child_text(elem, tag):
    """Flattened text of a direct child element, or "" when absent.

    Two catalogue details this has to get right:

    * <name>/<summary> are repeated per language as <name xml:lang="pl">. The
      untranslated one is the one the index wants — picking the first child
      returned e.g. the Arabic display name for an app named "Dialect".
    * The old regex pass matched only bare `<name>` tags, so it naturally
      skipped the translated ones; this reproduces that explicitly.
    """
    child = elem.find(tag)
    if child is None:
        return ""
    for candidate in elem.findall(tag):
        if candidate.get(XML_LANG) is None:
            child = candidate
            break
    return "".join(child.itertext()).strip()


def _first_release(elem):
    """First <release> anywhere in the subtree, or None.

    Flathub wraps releases in <releases>, so a direct-child lookup finds
    nothing and every app would lose its version and release date. Releases are
    listed newest-first, matching the old first-match regex behaviour.
    """
    return next(elem.iter("release"), None)


def _build(root):
    groups_dir = _flathub_dir(root)
    target = os.path.join(groups_dir, "groups.tsv")
    try:
        raw = fetch_bytes(BASE, MAX_RAW)
    except Exception as e:
        print("download failed: %s" % e, file=sys.stderr)
        return False
    if raw is None:
        print("download exceeded size limits", file=sys.stderr)
        return False

    index = {}
    # Every component's display name, whether or not it declares a <category>.
    # groups.tsv only carries categorised apps, so it is not a complete name ->
    # appid map; flatpak_icon.py needs one to resolve package names to Flathub
    # app ids without shelling out to `flatpak search` once per name.
    names = {}
    try:
        for comp in iter_components(raw, MAX_OUT):
            aid = _child_text(comp, "id")
            if not aid:
                continue
            name = _child_text(comp, "name") or aid
            summary = _child_text(comp, "summary")
            release = _first_release(comp)
            version = release.get("version", "") if release is not None else ""
            released = release.get("timestamp", "") if release is not None else ""
            if aid not in names:
                names[aid] = (name, released)
            for cat_el in comp.iter("category"):
                # Flathub nests these under a <categories> wrapper while the
                # Arch catalogue emits them as direct children, so search the
                # whole subtree rather than only direct children.
                cat = "".join(cat_el.itertext()).strip()
                if not cat:
                    continue
                index.setdefault(cat, {})[aid] = (name, summary, version, released)
    except _QuotaExceeded:
        print("decompressed data exceeded size limits", file=sys.stderr)
        return False
    except ET.ParseError as e:
        # A truncated or malformed catalogue must fail the build cleanly rather
        # than half-writing an index that later searches would treat as complete.
        print("appstream parse failed: %s" % e, file=sys.stderr)
        return False
    except OSError as e:
        print("appstream read failed: %s" % e, file=sys.stderr)
        return False

    groups_dir = os.path.join(root, "flathub")
    target = os.path.join(groups_dir, "groups.tsv")
    with open(target + ".tmp", "w") as fh:
        for cat, apps in sorted(index.items()):
            for aid, (name, summary, version, released) in sorted(apps.items()):
                # Every field is flattened: remote metadata may contain tabs or
                # newlines, which would break the one-record-per-line invariant.
                fh.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (
                    clean(cat), clean(aid), clean(name), clean(summary),
                    clean(version), clean(released)))
    os.replace(target + ".tmp", target)

    # Freshen the dedicated Flathub freshness marker (mtime = last successful
    # build), atomically, mirroring appstream_icons.sh's post-build freshen of
    # its own marker. Without this, stale() would report stale forever and the
    # catalog would be rebuilt on every panel open.
    marker = os.path.join(groups_dir, "current")
    with open(marker + ".tmp", "w") as fh:
        pass
    os.replace(marker + ".tmp", marker)

    # Flatpak search rows (not category-mapped) also want a "last updated"
    # date, so also emit a compact appid -> latest-release-date index the
    # panel's search script merges onto `flatpak search` output.
    appids = {}
    for cat, apps in index.items():
        for aid, (name, summary, version, released) in apps.items():
            if released and aid not in appids:
                appids[aid] = released
    appid_target = os.path.join(groups_dir, "appids.tsv")
    with open(appid_target + ".tmp", "w") as fh:
        for aid, released in sorted(appids.items()):
            fh.write("%s\t%s\n" % (clean(aid), clean(released)))
    os.replace(appid_target + ".tmp", appid_target)

    # Complete display-name -> app-id index for every component (not just the
    # categorised ones). flatpak_icon.py reads this instead of running
    # `flatpak search` up to three times per package name, which was the single
    # slowest thing the panel did on the search path.
    name_target = os.path.join(groups_dir, "names.tsv")
    with open(name_target + ".tmp", "w") as fh:
        for aid, (name, _released) in sorted(names.items()):
            fh.write("%s\t%s\n" % (clean(aid), clean(name)))
    os.replace(name_target + ".tmp", name_target)

    print("built flathub groups: %d categories, %d apps" % (len(index), sum(len(v) for v in index.values())), file=sys.stderr)
    return True


def resolve(root, keyword):
    target = os.path.join(root, "flathub", "groups.tsv")
    if not os.path.exists(target):
        # First run: there is nothing to serve yet, so build once here (still
        # bounded by the failure backoff so an offline machine fails fast
        # instead of retrying on every keystroke).
        ensure(root)
        if not os.path.exists(target):
            return
    elif stale(root):
        # A stale index is still a usable index. Serve it immediately and let a
        # detached rebuild refresh it for the next search — previously the
        # ~10 MB download ran inline, stalling every result list behind it.
        refresh_in_background(root)
    kw = keyword.strip().lower().replace("_", " ").replace("-", " ")
    kw = re.sub(r"\s+", " ", kw)
    if not kw:
        return
    syn = load_synonyms()
    cats = syn.get(kw)
    if not cats:
        return
    seen = set()
    with open(target, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t", 5)
            # Strict: the writer guarantees exactly six fields per record, so a
            # short line means a malformed/truncated file. Skipping it (rather
            # than tolerating it) is what stops a corrupted record from being
            # silently emitted as a partial row.
            if len(parts) != 6:
                continue
            cat, aid, name, summary, version, released = parts
            if cat in cats and aid not in seen:
                seen.add(aid)
                print("%s\t%s\t%s\t%s\t%s" % (aid, name, summary, version, released))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: %s ensure|resolve <cacheRoot> [keyword]" % sys.argv[0], file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1]
    root = cache_root(sys.argv[2] if len(sys.argv) > 2 else "")
    if mode == "ensure":
        ok = ensure(root)
        sys.exit(0 if ok else 1)
    elif mode == "resolve":
        if len(sys.argv) > 3:
            resolve(root, " ".join(sys.argv[3:]))
        else:
            print("no keyword", file=sys.stderr)
    else:
        print("unknown mode", file=sys.stderr)
        sys.exit(1)