#!/bin/bash
# Build and query a category->Arch-packages index from the AppStream catalog
# that Arch publishes at sources.archlinux.org (same source as
# appstream_icons.sh). Usage:
#   appstream_groups.sh ensure <cacheRoot>
#   appstream_groups.sh resolve <cacheRoot> <keyword...>
#
# `ensure` downloads each repo's Components-x86_64.xml.gz at the newest
# catalog date and extracts every <category> -> <pkgname> edge into a single
# compact merged file, <cacheRoot>/catalog/<date>/groups.tsv. The raw XML is
# discarded (download ~20MB once, index stays a few hundred KB). Reuses the
# same verified `current` marker + 32-day staleness as the icon catalog, so it
# only rebuilds when the icons are refreshed.
#
# `resolve` maps a natural-language keyword (via the shared groups.keywords
# synonym table) to one or more AppStream categories and prints the merged,
# de-duplicated package names, one per line. Prints nothing when the keyword
# matches no group.
#
# Security: the catalog version and per-artifact sha256 checksums are taken
# from the archlinux-appstream-data PKGBUILD on official Arch GitLab (the same
# trusted package that ships these files). Every Components XML download is
# verified against that checksum and downloads/decompression are bounded. The
# icon catalog `ensure` (also checksum-verified) provides the version marker.
# Overridable: ARCH_BASE, ARCH_PKGBUILD_URL, FOSSFETCH_MAX_RAW, FOSSFETCH_MAX_XML.

set -u

BASE="${ARCH_BASE:-https://sources.archlinux.org/other/packages/archlinux-appstream-data}"
PKGBUILD_URL="${ARCH_PKGBUILD_URL:-https://gitlab.archlinux.org/archlinux/packaging/packages/archlinux-appstream-data/-/raw/main/PKGBUILD}"
REPOS="core extra multilib"
ARCH="x86_64"

mode="${1:-}"
cache="${2:-$HOME/.cache/fossfetch}"
STORE="$cache/catalog"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYWORDS="$SCRIPT_DIR/groups.keywords"

# map a normalized keyword (lower-cased, spaces for _ -) to categories
keyword_categories() {
  local k="$1"
  while IFS=$'\t' read -r word cats; do
    [ -z "$word" ] && continue
    case "$word" in \#*) continue ;; esac
    [ "$k" = "$word" ] && { echo "$cats"; return 0; }
  done < "$KEYWORDS"
  return 1
}

ensure_groups() {
  # The verified catalog version marker is produced by the (checksum-verified)
  # icon catalog ensure — single source of truth for the release + checksums.
  "$SCRIPT_DIR/appstream_icons.sh" ensure "$cache" || return 1

  [ -f "$STORE/current" ] || { echo "no appstream catalog; run appstream_icons.sh ensure first" >&2; return 1; }
  date_dir=$(cat "$STORE/current" 2>/dev/null)
  target="$STORE/$date_dir/groups.tsv"
  groups_mtime=$(stat -c %Y "$target" 2>/dev/null || echo 0)
  marker_mtime=$(stat -c %Y "$STORE/current" 2>/dev/null || echo 0)
  [ "$groups_mtime" -ge "$marker_mtime" ] && [ -s "$target" ] && return 0

  tmp="$target.tmp"
  : > "$tmp"
  for repo in $REPOS; do
    if ! python3 - "$BASE" "$PKGBUILD_URL" "$date_dir" "$repo" >> "$tmp" <<'PY'
import hashlib
import os
import re
import sys
import urllib.request
import zlib

BASE, PKGBUILD_URL, ver, repo = sys.argv[1:5]

MAX_RAW = int(os.environ.get("FOSSFETCH_MAX_RAW", "67108864"))            # 64 MiB / file
MAX_XML = int(os.environ.get("FOSSFETCH_MAX_XML", "268435456"))           # 256 MiB decompressed
MAX_PB  = 262144


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


REPO_ORDER = ["core", "extra", "multilib"]
SLOT_XML = 0  # sha256sums() slot 0 per repo = Components-x86_64.xml.gz
if repo not in REPO_ORDER:
    sys.exit(2)

pb = fetch(PKGBUILD_URL, MAX_PB)
if pb is None:
    sys.exit(2)
sums = pkgbuild_checksums(pb.decode("utf-8", "replace"), ver)
if sums is None:
    sys.exit(3)

raw = fetch("%s/%s/%s/Components-%s.xml.gz" % (BASE, ver, repo, "x86_64"), MAX_RAW)
if raw is None:
    sys.exit(4)
slot = REPO_ORDER.index(repo) * 4 + SLOT_XML
if hashlib.sha256(raw).hexdigest() != sums[slot]:
    sys.exit(5)  # checksum mismatch -> never parse unverified data

# Bounded streaming decompression: a gzip bomb aborts once the decompressed
# quota is exceeded instead of being buffered in full.
d = zlib.decompressobj(16 + zlib.MAX_WBITS)
out = bytearray()
i = 0
while i < len(raw):
    out += d.decompress(raw[i:i + 65536])
    i += 65536
    if len(out) > MAX_XML:
        sys.exit(6)
if not d.eof or d.unused_data:
    sys.exit(7)

xml = bytes(out)
for m in re.finditer(rb"<component type=\"desktop-application\".*?</component>", xml, re.S):
    blk = m.group(0)
    pkg = re.search(rb"<pkgname>(.*?)</pkgname>", blk)
    if not pkg:
        continue
    p = pkg.group(1).decode()
    for c in re.findall(rb"<category>(.*?)</category>", blk):
        sys.stdout.write(c.decode() + "\t" + p + "\n")
sys.exit(0)
PY
    then
      rm -f "$tmp"
      echo "group index build failed for $repo" >&2
      return 1
    fi
  done
  sort -u "$tmp" -o "$tmp"
  mv "$tmp" "$target"
  echo "built groups index: $(wc -l < "$target") entries" >&2
}

resolve_groups() {
  local kw
  [ "$#" -ge 3 ] || return 0
  kw=$(echo "$3" | tr '[:upper:]' '[:lower:]' | sed 's/[_-]/ /g' | tr -s ' ' | xargs)
  [ -n "$kw" ] || return 0

  local cats
  cats=$(keyword_categories "$kw")
  [ -n "$cats" ] || return 0

  # Fresh catalog check is a single stat; only downloads/rebuilds when stale.
  ensure_groups

  [ -f "$STORE/current" ] || return 0
  date_dir=$(cat "$STORE/current" 2>/dev/null)
  index="$STORE/$date_dir/groups.tsv"
  [ -f "$index" ] || return 0

  local cat
  for cat in $(echo "$cats" | tr ',' ' '); do
    awk -F'\t' -v c="$cat" '$1 == c { print $2 }' "$index"
  done | sort -u
}

case "$mode" in
  ensure) ensure_groups ;;
  resolve) resolve_groups "$@" ;;
  *) echo "usage: $0 ensure|resolve <cacheRoot> [keyword...]" >&2; exit 1 ;;
esac