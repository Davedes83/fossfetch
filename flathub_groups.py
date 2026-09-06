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

import os
import re
import sys
import time
import urllib.request
import zlib

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


def gunzip_bounded(raw, cap):
    """Streaming gzip decompression that aborts once `cap` decompressed bytes
    are produced, so a gzip bomb cannot exhaust memory."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = bytearray()
    i = 0
    while i < len(raw):
        out += d.decompress(raw[i:i + 65536])
        i += 65536
        if len(out) > cap:
            return None
    if not d.eof or d.unused_data:
        return None
    return bytes(out)


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


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
    marker = os.path.join(root, "catalog", "current")
    if not os.path.exists(marker):
        return True
    try:
        age = (time.time() - os.path.getmtime(marker)) / 86400
        return age > STALE_DAYS
    except Exception:
        return True


def ensure(root):
    groups_dir = os.path.join(root, "flathub")
    os.makedirs(groups_dir, exist_ok=True)
    target = os.path.join(groups_dir, "groups.tsv")
    if os.path.exists(target) and not stale(root):
        print("flathub groups fresh", file=sys.stderr)
        return True

    try:
        raw = fetch_bytes(BASE, MAX_RAW)
        if raw is None:
            print("download exceeded size limits", file=sys.stderr)
            return False
        data = gunzip_bounded(raw, MAX_OUT)
        if data is None:
            print("decompressed data exceeded size limits", file=sys.stderr)
            return False
    except Exception as e:
        print("download failed: %s" % e, file=sys.stderr)
        return False

    index = {}
    for typ in (b"desktop-application", b"desktop"):
        for m in re.finditer(rb"<component type=\"" + typ + rb"\".*?</component>", data, re.S):
            blk = m.group(0)
            appid = re.search(rb"<id>(.*?)</id>", blk)
            if not appid:
                continue
            aid = appid.group(1).decode()
            name_m = re.search(rb"<name>(.*?)</name>", blk, re.S)
            sum_m = re.search(rb"<summary>(.*?)</summary>", blk, re.S)
            ver_m = re.search(rb"<release[^>]*version=\"([^\"]+)\"", blk)
            date_m = re.search(rb"<release[^>]*timestamp=\"([^\"]+)\"", blk)
            if name_m:
                name = re.sub(rb"<.*?>", b"", name_m.group(1)).decode().strip()
            else:
                name = aid
            if sum_m:
                summary = re.sub(rb"<.*?>", b"", sum_m.group(1)).decode().strip()
            else:
                summary = ""
            version = ver_m.group(1).decode() if ver_m else ""
            released = date_m.group(1).decode() if date_m else ""
            for c in re.findall(rb"<category>(.*?)</category>", blk):
                cat = c.decode()
                index.setdefault(cat, {})[aid] = (name, summary, version, released)

    with open(target + ".tmp", "w") as fh:
        for cat, apps in sorted(index.items()):
            for aid, (name, summary, version, released) in sorted(apps.items()):
                fh.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (cat, aid, name, summary.replace("\t", " "), version, released))
    os.replace(target + ".tmp", target)

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
            fh.write("%s\t%s\n" % (aid, released))
    os.replace(appid_target + ".tmp", appid_target)
    print("built flathub groups: %d categories, %d apps" % (len(index), sum(len(v) for v in index.values())), file=sys.stderr)
    return True


def resolve(root, keyword):
    ensure(root)
    target = os.path.join(root, "flathub", "groups.tsv")
    if not os.path.exists(target):
        return
    kw = keyword.strip().lower().replace("_", " ").replace("-", " ")
    kw = re.sub(r"\s+", " ", kw)
    if not kw:
        return
    syn = load_synonyms()
    cats = syn.get(kw)
    if not cats:
        for k, v in syn.items():
            if kw == k:
                cats = v
                break
    if not cats:
        return
    seen = set()
    with open(target, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t", 5)
            if len(parts) < 5:
                continue
            cat, aid, name, summary, version = parts[:5]
            released = parts[5] if len(parts) > 5 else ""
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