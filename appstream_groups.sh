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
STATE_PY="$SCRIPT_DIR/appstream_state.py"

# State/cache writes go through the owner-checked, no-follow dirfd helper
# (appstream_state.py), like the icon catalog.

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

mode="${1:-}"
cache="${2:-$HOME/.cache/fossfetch}"
STORE="$cache/catalog"
KEYWORDS="$SCRIPT_DIR/groups.keywords"

# Build-state markers + growing retry backoff (see catalog_markers.sh).
# shellcheck source=catalog_markers.sh
. "$SCRIPT_DIR/catalog_markers.sh"
GROUPS_BUILD_MARKER="$STORE/.groups-building"
GROUPS_FAILED_MARKER="$STORE/.groups-failed"

local_available() {
  [ -d "$SWCATALOG/icons" ] && [ -d "$SWCATALOG/xml" ] || return 1
  local_version >/dev/null
}

# Cached pacman -Q result (see appstream_icons.sh for the shared rationale).
PACMAN_VER=""
pacman_appstream_version() {
  if [ -z "$PACMAN_VER" ]; then
    if command -v pacman >/dev/null 2>&1; then
      PACMAN_VER=$(pacman -Q archlinux-appstream-data 2>/dev/null | awk '{print $2}')
    else
      PACMAN_VER="__no_pacman__"
    fi
  fi
  [ "$PACMAN_VER" != "__no_pacman__" ] || return 1
  [ -n "$PACMAN_VER" ] || return 1
  printf '%s\n' "$PACMAN_VER"
}

local_version() {
  if [ -n "${FOSSFETCH_SWCATALOG_VER:-}" ]; then
    printf '%s\n' "$FOSSFETCH_SWCATALOG_VER"
    return 0
  fi
  pacman_appstream_version
}

# The version string becomes a path component, so it must be a plain version.
valid_version() {
  case "$1" in
    '')            return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *)             return 0 ;;
  esac
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

# Wrapper: gates the group build on its own build/failure markers, mirroring
# appstream_icons.sh. `ensure` is reachable from the search path (and from the
# detached background spawn), so without these a failing build would be retried
# on every search and a slow one would pile up behind itself.
ensure_groups() {
  if catalog_marker_fresh "$GROUPS_BUILD_MARKER" "$CATALOG_BUILD_STALE_SECONDS"; then
    echo "group index: a build is already running" >&2
    return 1
  fi
  if catalog_backoff_active "$GROUPS_FAILED_MARKER"; then
    echo "group index: backing off after a recent failed build" >&2
    return 1
  fi
  catalog_mark_building "$GROUPS_BUILD_MARKER"
  if build_groups; then
    catalog_clear_building "$GROUPS_BUILD_MARKER"
    catalog_clear_failed "$GROUPS_FAILED_MARKER"
    return 0
  fi
  catalog_clear_building "$GROUPS_BUILD_MARKER"
  catalog_mark_failed "$GROUPS_FAILED_MARKER"
  return 1
}

build_groups() {
  # The verified catalog version marker is produced by the icon catalog ensure
  # (local-pacman or pinned-network) — single source of truth for the release.
  "$SCRIPT_DIR/appstream_icons.sh" ensure "$cache" || return 1

  [ -f "$STORE/current" ] || { echo "no appstream catalog; run appstream_icons.sh ensure first" >&2; return 1; }
  date_dir=$(cat "$STORE/current" 2>/dev/null)
  # The marker is written by appstream_icons.sh, which validates it, but it is
  # read back from disk and used to build a path — re-check it here so a
  # hand-edited or corrupted marker can never steer the build outside the
  # catalog root.
  if ! valid_version "$date_dir"; then
    echo "refusing group index build: unusable catalog version '$date_dir'" >&2
    return 1
  fi
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

  tmprel=$(python3 "$STATE_PY" tmpfile "$cache" "$date_dir" "__groups.tmp") || { echo "cannot create group index temp" >&2; return 1; }
  tmp="$STORE/$tmprel"
  for repo in $REPOS; do
    if [ "$src_mode" = "local" ]; then
      [ -f "$SWCATALOG/xml/$repo.xml.gz" ] || { python3 "$STATE_PY" rmtree "$cache" "$tmprel" >/dev/null 2>&1 || true; echo "local appstream xml missing: $SWCATALOG/xml/$repo.xml.gz" >&2; return 1; }
    fi
    if ! python3 - "$src_mode" "$BASE" "$date_dir" "$repo" "$SWCATALOG" >> "$tmp" <<'PY'
import hashlib
import gzip
import io
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET

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


class _QuotaExceeded(Exception):
    pass


class _BoundedReader:
    """Read wrapper that refuses to hand out more than `cap` decompressed bytes.

    The request is clamped as well as checked: a caller asking for -1 would
    otherwise pull an entire decompression bomb into one buffer before the quota
    could be applied.
    """

    def __init__(self, stream, cap):
        self._stream = stream
        self._cap = cap
        self._seen = 0

    def read(self, size=-1):
        if size is None or size < 0 or size > 65536:
            size = 65536
        chunk = self._stream.read(size)
        self._seen += len(chunk)
        if self._seen > self._cap:
            raise _QuotaExceeded()
        return chunk

    def readable(self):
        return True


def parse(raw):
    """Emit "<category>\\t<pkgname>" for every desktop component, streaming.

    The Arch Components XML is ~27 MiB per repo decompressed. This used to
    buffer the whole thing and regex it; a pull parser plus a bounded reader
    keeps peak memory at one chunk plus one component while still aborting a
    gzip bomb at the quota.
    """
    stream = gzip.GzipFile(fileobj=io.BytesIO(raw), mode="rb")
    reader = _BoundedReader(stream, MAX_XML)
    parser = ET.XMLPullParser(events=("start", "end"))
    tree_root = None
    out = sys.stdout
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
                if elem.get("type") == "desktop-application":
                    pkg_el = elem.find("pkgname")
                    pkg = "".join(pkg_el.itertext()).strip() if pkg_el is not None else ""
                    if pkg:
                        for cat_el in elem.iter("category"):
                            cat = "".join(cat_el.itertext()).strip()
                            if cat:
                                out.write(cat + "\t" + pkg + "\n")
                elem.clear()
                children = list(tree_root) if tree_root is not None else []
                if children and children[0] is elem:
                    del tree_root[0]
        parser.close()
    finally:
        try:
            stream.close()
        except Exception:
            pass


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
    try:
        parse(raw)
    except (_QuotaExceeded, ET.ParseError, OSError):
        sys.exit(3)
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

try:
    parse(raw)
except (_QuotaExceeded, ET.ParseError, OSError):
    sys.exit(6)
sys.exit(0)
PY
    then
      python3 "$STATE_PY" rmtree "$cache" "$tmprel" >/dev/null 2>&1 || true
      echo "group index build failed for $repo" >&2
      return 1
    fi
  done
  sort -u "$tmp" -o "$tmp"
  python3 "$STATE_PY" swap "$cache" "$tmprel" "$date_dir/groups.tsv" || {
    python3 "$STATE_PY" rmtree "$cache" "$tmprel" >/dev/null 2>&1 || true
    echo "group index swap failed" >&2
    return 1
  }
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

  # Never let a catalog rebuild stand between the user and their results.
  # `resolve` runs on the search path, so:
  #   * no index yet  -> build once here (still bounded by the failure backoff,
  #                      so an offline machine fails fast instead of retrying on
  #                      every keystroke);
  #   * index present -> serve it immediately. If it is stale, kick off a
  #                      detached rebuild whose output lands for the NEXT
  #                      search rather than stalling this one.
  if [ -f "$STORE/current" ]; then
    groups_stale && ensure_groups_background
  else
    ensure_groups >/dev/null 2>&1
  fi

  [ -f "$STORE/current" ] || return 0
  date_dir=$(cat "$STORE/current" 2>/dev/null)
  index="$STORE/$date_dir/groups.tsv"
  [ -f "$index" ] || return 0

  local cat
  for cat in $(echo "$cats" | tr ',' ' '); do
    awk -F'\t' -v c="$cat" '$1 == c { print $2 }' "$index"
  done | sort -u
}

# The group index is older than the catalog marker -> worth rebuilding, but only
# in the background.
groups_stale() {
  [ -f "$STORE/current" ] || return 0
  local g m
  g=$(stat -c %Y "$STORE/current/groups.tsv" 2>/dev/null || echo 0)
  m=$(stat -c %Y "$STORE/current" 2>/dev/null || echo 0)
  [ -s "$STORE/current/groups.tsv" ] || return 0
  [ "$g" -lt "$m" ]
}

# Detached rebuild. setsid (util-linux) puts the child in its own session so it
# survives the panel's search process being killed between keystrokes; the
# stdio redirects keep it from holding the caller's pipe open.
ensure_groups_background() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SCRIPT_DIR/appstream_groups.sh" ensure "$cache" </dev/null >/dev/null 2>&1 &
  else
    "$SCRIPT_DIR/appstream_groups.sh" ensure "$cache" </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
  return 0
}

case "$mode" in
  ensure) ensure_groups ;;
  resolve) resolve_groups "$@" ;;
  *) echo "usage: $0 ensure|resolve <cacheRoot> [keyword...]" >&2; exit 1 ;;
esac