#!/bin/bash
# Resolve icons for Arch repo packages from the AppStream catalog that Arch
# publishes at sources.archlinux.org. Usage:
#   appstream_icons.sh ensure <cacheRoot>
#   appstream_icons.sh resolve <cacheRoot> <pkg> [<pkg> ...]
#
# `ensure` downloads the icons-48x48.tar.gz tarball for each repo at the newest
# *verified* catalog release, extracts it into <cacheRoot>/catalog/<date>/<repo>/,
# and records the date. ~2.7MB once; refreshed only when the catalog is stale.
#
# `resolve` looks up each pkg's icon by its "<pkg>_<appid>.png" prefix, which is
# how the catalog names every entry — no XML needed. Emits "I|<pkg>|<path>" per
# arg (empty path when the pkg ships no icon in the catalog).
#
# Security: the artifact version is taken from the official Arch GitLab
# PKGBUILD for archlinux-appstream-data (a trusted, signed package) and every
# downloaded tarball is verified against that PKGBUILD's published sha256sum
# BEFORE any extraction. Downloads are capped (Content-Length and actual
# reads), decompression is bounded, and tar members are validated against
# absolute / ".." traversal / symlink / hardlink entries plus per-file,
# total-size and member count quotas. Extraction happens in a private temp dir
# and is swapped into place atomically. Overridable (defaults are hardened):
#   ARCH_BASE, ARCH_PKGBUILD_URL, FOSSFETCH_MAX_RAW, FOSSFETCH_MAX_ICON,
#   FOSSFETCH_MAX_ICON_TOTAL, FOSSFETCH_MAX_ICON_COUNT

set -u

BASE="${ARCH_BASE:-https://sources.archlinux.org/other/packages/archlinux-appstream-data}"
PKGBUILD_URL="${ARCH_PKGBUILD_URL:-https://gitlab.archlinux.org/archlinux/packaging/packages/archlinux-appstream-data/-/raw/main/PKGBUILD}"
REPOS="core extra multilib"
SIZE="48x48"
STALE_DAYS=32

mode="${1:-}"
cache="${2:-$HOME/.cache/fossfetch}"
STORE="$cache/catalog"
mkdir -p "$STORE"

# Newest *verified* pkgver of archlinux-appstream-data, read from the official
# Arch GitLab PKGBUILD (bounded fetch). Empty on any failure.
pkgver_of() {
  python3 - "$PKGBUILD_URL" <<'PY'
import re
import sys
import urllib.request

url = sys.argv[1]
cap = 262144
try:
    with urllib.request.urlopen(url, timeout=20) as r:
        declared = r.headers.get("Content-Length")
        if declared is not None:
            try:
                if int(declared) > cap:
                    sys.exit(2)
            except ValueError:
                pass
        data = bytearray()
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > cap:
                sys.exit(2)
except Exception:
    sys.exit(2)
m = re.search(rb"^pkgver=([0-9]+)$", data, re.M)
sys.stdout.write(m.group(1).decode() if m else "")
PY
}

ensure_catalog() {
  marker="$STORE/current"

  # Fresh enough? Skip the network round-trip.
  if [ -f "$marker" ]; then
    mtime=$(date -d "$(cat "$marker")" +%s 2>/dev/null || echo "")
    if [ -n "$mtime" ] && [ -d "$STORE/$(cat "$marker")" ]; then
      now=$(date +%s)
      age=$(( (now - mtime) / 86400 ))
      [ "$age" -lt "$STALE_DAYS" ] && return 0
    fi
  fi

  ver=$(pkgver_of)
  case "$ver" in
    ''|*[!0-9]*) echo "could not resolve a verified appstream catalog version" >&2; return 1 ;;
  esac

  target="$STORE/$ver"
  if [ ! -d "$target" ]; then
    tmpdir=$(mktemp -d "$STORE/.tmp.XXXXXX") || { echo "mktemp failed" >&2; return 1; }
    export ARCH_BASE PKGBUILD_URL
    if ! python3 - "$BASE" "$PKGBUILD_URL" "$ver" "$SIZE" "$REPOS" "$tmpdir" <<'PY'
import gzip
import hashlib
import io
import os
import re
import sys
import tarfile
import urllib.request

BASE, PKGBUILD_URL, ver, size, repos, tmpdir = sys.argv[1:7]

MAX_RAW    = int(os.environ.get("FOSSFETCH_MAX_RAW", "67108864"))        # 64 MiB / archive
MAX_MEMBER = int(os.environ.get("FOSSFETCH_MAX_ICON", "1048576"))        # 1 MiB / icon
MAX_TOTAL  = int(os.environ.get("FOSSFETCH_MAX_ICON_TOTAL", "134217728"))
MAX_COUNT  = int(os.environ.get("FOSSFETCH_MAX_ICON_COUNT", "20000"))
MAX_PB     = 262144


def fetch(url, cap):
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            declared = r.headers.get("Content-Length")
            if declared is not None:
                try:
                    if int(declared) > cap:
                        return None
                except ValueError:
                    pass
            data = bytearray()
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                data += chunk
                if len(data) > cap:
                    return None
    except Exception:
        return None
    return bytes(data)


def pkgbuild_checksums(text, want_ver):
    m = re.search(r"^pkgver=([0-9]+)$", text, re.M)
    if not m or m.group(1) != want_ver:
        return None
    block = re.search(r"sha256sums=\((.*?)\)", text, re.S)
    if not block:
        return None
    sums = re.findall(r"['\"`]?([0-9a-fA-F]{64})['\"`]?", block.group(1))
    if len(sums) != 12:
        return None
    return [s.lower() for s in sums]


# The raw (compressed) archive is already bounded to MAX_RAW by `fetch`, and
# the *decompressed* quota is enforced below through member validation: every
# tar member's declared size is checked (per-file + aggregate) and its body is
# only read after that check passes, so a gzip bomb is never buffered or
# written. Member count is capped too.
REPO_ORDER = ["core", "extra", "multilib"]
# sha256sums() in the PKGBUILD lists per repo: xml, icons-48x48, icons-64x64,
# icons-128x128 — slot index = repo_index * 4 + 1 for icons-48x48.
SLOT_48 = 1
SAFE_RE = re.compile(r"[A-Za-z0-9_.+~-]+\.png\Z")

pb = fetch(PKGBUILD_URL, MAX_PB)
if pb is None:
    sys.exit(2)
sums = pkgbuild_checksums(pb.decode("utf-8", "replace"), ver)
if sums is None:
    sys.exit(3)

total = 0
count = 0
for repo in repos.split():
    if repo not in REPO_ORDER:
        sys.exit(4)
    slot = REPO_ORDER.index(repo) * 4 + SLOT_48
    raw = fetch("%s/%s/%s/icons-%s.tar.gz" % (BASE, ver, repo, size), MAX_RAW)
    if raw is None:
        sys.exit(5)
    if hashlib.sha256(raw).hexdigest() != sums[slot]:
        sys.exit(6)  # checksum mismatch -> never extract unverified data

    outdir = os.path.join(tmpdir, repo)
    os.makedirs(outdir, mode=0o755, exist_ok=True)
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
            for member in tf:
                name = member.name or ""
                if name.startswith("/"):
                    sys.exit(7)  # absolute path
                parts = name.split("/")
                if any(p in ("", ".", "..") for p in parts):
                    sys.exit(8)  # traversal / empty component
                if member.isdir() and not member.issym():
                    continue
                if not member.isfile() or member.issym() or member.islnk():
                    sys.exit(9)  # symlinks/hardlinks/device/fifo rejected
                if not name.lower().endswith(".png") or not SAFE_RE.match(name):
                    sys.exit(10)  # only plain basename .png icons
                if member.size > MAX_MEMBER or total + member.size > MAX_TOTAL:
                    sys.exit(11)  # decompressed-bytes cap (per-file + total)
                count += 1
                if count > MAX_COUNT:
                    sys.exit(12)
                src = tf.extractfile(member)
                if src is None:
                    sys.exit(13)
                dst = os.path.join(outdir, os.path.basename(name))
                with open(dst, "wb") as out:
                    while True:
                        chunk = src.read(65536)
                        if not chunk:
                            break
                        out.write(chunk)
                total += member.size
    except (tarfile.TarError, gzip.BadGzipFile, EOFError, OSError, ValueError):
        sys.exit(14)

sys.exit(0)
PY
    then
      rm -rf "$tmpdir"
      rm -rf "$STORE"/.tmp.* "$STORE"/*.old 2>/dev/null || true
      echo "appstream icon catalog fetch/verify failed (version $ver)" >&2
      return 1
    fi
    # Atomic swap: keep the previous good tree until the new one is in place.
    if [ -d "$target" ]; then mv "$target" "$tmpdir.old" 2>/dev/null || rm -rf "$target"; fi
    mv "$tmpdir" "$target" || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir.old" 2>/dev/null || true
  fi

  echo "$ver" > "$marker"
  return 0
}

resolve_icons() {
  date_dir=$(cat "$STORE/current" 2>/dev/null || true)
  if [ -z "$date_dir" ] || [ ! -d "$STORE/$date_dir" ]; then
    for pkg in "${@:3}"; do echo "I|$pkg|"; done
    return 0
  fi

  for pkg in "${@:3}"; do
    hit=$(find "$STORE/$date_dir" -type f -name "${pkg}_*" 2>/dev/null | sort | head -1)
    [ -n "$hit" ] && [ -f "$hit" ] && echo "I|$pkg|$hit" || echo "I|$pkg|"
  done
}

case "$mode" in
  ensure)  ensure_catalog ;;
  resolve) ensure_catalog; resolve_icons "${@:-}" ;;
  *) echo "I||"; exit 1 ;;
esac