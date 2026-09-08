#!/bin/bash
# Build and query a category->Arch-packages index from the AppStream catalog
# (same source/trust model as appstream_icons.sh). Usage:
#   appstream_groups.sh ensure <cacheRoot>
#   appstream_groups.sh resolve <cacheRoot> <keyword...>
#
# `ensure` extracts every <category> -> <pkgname> edge from each repo's
# Components XML into a single merged, de-duplicated file,
# <cacheRoot>/catalog/<version>/groups.tsv. The raw XML is discarded (download
# ~20MB once, index stays a few hundred KB). Reuses the same version marker +
# 32-day staleness as the icon catalog, so it only rebuilds when the icons are
# refreshed.
#
# `resolve` maps a natural-language keyword (via groups.keywords) to one or
# more AppStream categories and prints the merged package names, one per line.
#
# Security / trust: identical to appstream_icons.sh —
#   * LOCAL (preferred): parse the pacman-verified /usr/share/swcatalog/xml
#     files installed by `archlinux-appstream-data`; nothing is downloaded.
#   * NETWORK (fallback): fetch Components-x86_64.xml.gz only for the version
#     pinned in appstream_pins.sh and verify every file against its immutable,
#     committed sha256 BEFORE parsing. The pin is never fetched or derived from
#     a remote at runtime; a mismatch is an unauthorized change and is refused.
# Downloads and decompression are bounded (a gzip bomb aborts at the quota).
# Overridable: ARCH_BASE, FOSSFETCH_SWCATALOG, FOSSFETCH_PINNED_VER,
#   FOSSFETCH_PINNED_SUMS, FOSSFETCH_MAX_RAW, FOSSFETCH_MAX_XML.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=appstream_pins.sh
. "$SCRIPT_DIR/appstream_pins.sh"

PINNED_VER="${FOSSFETCH_PINNED_VER:-$PINNED_PKGVER}"
if [ -n "${FOSSFETCH_PINNED_SUMS:-}" ]; then
  read -r -a SRC_PINS <<< "$FOSSFETCH_PINNED_SUMS"
else
  SRC_PINS=("${PINNED_SHA256SUMS[@]}")
fi
export FOSSFETCH_PINNED_SUMS="${SRC_PINS[*]}"

BASE="${ARCH_BASE:-https://sources.archlinux.org/other/packages/archlinux-appstream-data}"
SWCATALOG="${FOSSFETCH_SWCATALOG:-/usr/share/swcatalog}"
REPOS="core extra multilib"
ARCH="x86_64"

mode="${1:-}"
cache="${2:-$HOME/.cache/fossfetch}"
STORE="$cache/catalog"
KEYWORDS="$SCRIPT_DIR/groups.keywords"

local_available() {
  [ -d "$SWCATALOG/icons" ] && [ -d "$SWCATALOG/xml" ] || return 1
  if [ -n "${FOSSFETCH_SWCATALOG:-}" ]; then return 0; fi # explicit test/sealed path
  command -v pacman >/dev/null 2>&1 || return 1
  pacman -Q archlinux-appstream-data >/dev/null 2>&1
}

local_version() {
  if [ -n "${FOSSFETCH_SWCATALOG_VER:-}" ]; then
    echo "$FOSSFETCH_SWCATALOG_VER"
  else
    pacman -Q archlinux-appstream-data 2>/dev/null | awk '{print $2}'
  fi
}

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
  # The verified catalog version marker is produced by the icon catalog ensure
  # (local-pacman or pinned-network) — single source of truth for the release.
  "$SCRIPT_DIR/appstream_icons.sh" ensure "$cache" || return 1

  [ -f "$STORE/current" ] || { echo "no appstream catalog; run appstream_icons.sh ensure first" >&2; return 1; }
  date_dir=$(cat "$STORE/current" 2>/dev/null)
  target="$STORE/$date_dir/groups.tsv"
  groups_mtime=$(stat -c %Y "$target" 2>/dev/null || echo 0)
  marker_mtime=$(stat -c %Y "$STORE/current" 2>/dev/null || echo 0)
  [ "$groups_mtime" -ge "$marker_mtime" ] && [ -s "$target" ] && return 0

  if [ "$date_dir" = "$(local_version)" ] && local_available; then
    src_mode="local"
  elif [ "$date_dir" = "$PINNED_VER" ]; then
    src_mode="network"
  else
    echo "no verified appstream data for catalog version $date_dir" >&2
    return 1
  fi

  tmp="$target.tmp"
  : > "$tmp"
  for repo in $REPOS; do
    if [ "$src_mode" = "local" ]; then
      [ -f "$SWCATALOG/xml/$repo.xml.gz" ] || { rm -f "$tmp"; echo "local appstream xml missing: $SWCATALOG/xml/$repo.xml.gz" >&2; return 1; }
    fi
    if ! python3 - "$src_mode" "$BASE" "$date_dir" "$repo" "$SWCATALOG" >> "$tmp" <<'PY'
import hashlib
import os
import re
import sys
import urllib.request
import zlib

src_mode, BASE, ver, repo, swcatalog = sys.argv[1:6]

MAX_RAW = int(os.environ.get("FOSSFETCH_MAX_RAW", "67108864"))            # 64 MiB / file
MAX_XML = int(os.environ.get("FOSSFETCH_MAX_XML", "268435456"))           # 256 MiB decompressed


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


def gunzip_bounded(raw, cap):
    # Streaming decompression: a gzip bomb aborts once the decompressed quota
    # is exceeded instead of being buffered in full.
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


def parse(xml):
    for m in re.finditer(rb"<component type=\"desktop-application\".*?</component>", xml, re.S):
        blk = m.group(0)
        pkg = re.search(rb"<pkgname>(.*?)</pkgname>", blk)
        if not pkg:
            continue
        p = pkg.group(1).decode()
        for c in re.findall(rb"<category>(.*?)</category>", blk):
            sys.stdout.write(c.decode() + "\t" + p + "\n")


REPO_ORDER = ["core", "extra", "multilib"]
SLOT_XML = 0  # sha256sums() slot 0 per repo = Components-x86_64.xml.gz
if repo not in REPO_ORDER:
    sys.exit(2)

if src_mode == "local":
    # Pacman-verified local data: authoritative by construction, no hash needed.
    with open(os.path.join(swcatalog, "xml", repo + ".xml.gz"), "rb") as fh:
        raw = fh.read()
    if len(raw) > MAX_RAW:
        sys.exit(2)
    xml = gunzip_bounded(raw, MAX_XML)
    if xml is None:
        sys.exit(3)
    parse(xml)
    sys.exit(0)

sums = os.environ.get("FOSSFETCH_PINNED_SUMS", "").split()
if len(sums) != 12:
    sys.exit(2)

raw = fetch("%s/%s/%s/Components-%s.xml.gz" % (BASE, ver, repo, "x86_64"), MAX_RAW)
if raw is None:
    sys.exit(4)
slot = REPO_ORDER.index(repo) * 4 + SLOT_XML
# Verify against the immutable, reviewed pin BEFORE parsing. This is the trust
# anchor: the pin is committed source, never a runtime fetch.
if hashlib.sha256(raw).hexdigest() != sums[slot]:
    sys.exit(5)  # unauthorized/checksum-mismatched file -> refused

xml = gunzip_bounded(raw, MAX_XML)
if xml is None:
    sys.exit(6)
parse(xml)
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