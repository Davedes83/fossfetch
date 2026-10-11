#!/bin/bash
# Resolve icons for Arch repo packages from the AppStream catalog. Usage:
#   appstream_icons.sh ensure <cacheRoot>
#   appstream_icons.sh resolve <cacheRoot> <pkg> [<pkg> ...]
#
# `ensure` builds <cacheRoot>/catalog/<version>/<repo>/png/ from one of two
# trust anchors, in order:
#
#   1. LOCAL (preferred): the distribution's already verified AppStream data
#      installed by pacman as `archlinux-appstream-data`
#      (/usr/share/swcatalog/icons/archlinux-arch-<repo>/48x48). These files
#      are authenticated by the Arch package manager's keyring; nothing is
#      downloaded. The catalog is versioned by `pacman -Q` output and refreshes
#      automatically when the package is updated.
#
#   2. NETWORK (fallback): the immutable catalog release pinned in
#      appstream_pins.sh (FOSSFETCH_PINNED_VER + FOSSFETCH_PINNED_SUMS). Each
#      icons-48x48.tar.gz is fetched from sources.archlinux.org and verified
#      against its pinned sha256 BEFORE any extraction. The pin is committed to
#      and reviewed together with this source; it is never obtained or derived
#      from a remote at runtime, and a mismatch is an unauthorized change that
#      is refused, not parsed.
#
# Downloads are capped (Content-Length and actual reads), decompression is
# bounded by per-member/aggregate/count tar validation (a gzip bomb is never
# buffered), and members are checked against absolute / ".." / symlink /
# hardlink entries. Extraction happens in a private temp dir and is swapped
# into place atomically. Overridable (defaults are hardened):
#   ARCH_BASE, FOSSFETCH_SWCATALOG, FOSSFETCH_PINNED_VER, FOSSFETCH_PINNED_SUMS,
#   FOSSFETCH_MAX_RAW, FOSSFETCH_MAX_ICON, FOSSFETCH_MAX_ICON_TOTAL,
#   FOSSFETCH_MAX_ICON_COUNT
#
# `resolve` emits "I|<pkg>|<path>" per arg (empty path when no icon).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=appstream_pins.sh
. "$SCRIPT_DIR/appstream_pins.sh"
STATE_PY="$SCRIPT_DIR/appstream_state.py"

# Every write/replace/delete on the user cache goes through the owner-checked,
# no-follow dirfd transaction helper (see appstream_state.py). We never mkdir,
# mktemp, mv, or rm on unchecked HOME paths; the helper pins the directory with
# O_NOFOLLOW|O_DIRECTORY and refuses symlinked or foreign-owned components.

# Network pin: use the reviewed constants unless a maintainer/test explicitly
# overrides them (shipping defaults remain immutable).
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
SIZE="48x48"
STALE_DAYS=32

mode="${1:-}"
cache="${2:-$HOME/.cache/fossfetch}"
STORE="$cache/catalog"
python3 "$STATE_PY" ensure "$cache" || { echo "unsafe or unusable appstream cache path: $cache" >&2; exit 1; }

# Build-state markers + growing retry backoff. See catalog_markers.sh for why
# these exist and how the window is computed.
# shellcheck source=catalog_markers.sh
. "$SCRIPT_DIR/catalog_markers.sh"
BUILD_MARKER="$STORE/.building"
FAILED_MARKER="$STORE/.failed"

# The tied (config, pacman-installed) local source of truth, used when the
# archlinux-appstream-data package is present.
#
# local_version is TOTAL: it prints a non-empty version and returns 0, or
# returns non-zero without printing. local_available depends on that rather than
# short-circuiting, so a sealed source with no derivable version is treated as
# unavailable — we then fall back to the checksum-pinned network source instead
# of building under an empty version (see the want= guard in ensure_catalog).
local_available() {
  [ -d "$SWCATALOG/icons" ] && [ -d "$SWCATALOG/xml" ] || return 1
  local_version >/dev/null
}

# Cached pacman -Q result: the query is invoked several times per ensure, and
# each call forks a process plus a pipe.
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

# The catalog version to build, or "" when the local source cannot supply one.
expected_version() {
  if local_available; then local_version; else printf '%s\n' "$PINNED_VER"; fi
}

# A catalog version becomes a path component ("$STORE/$want") and is handed to
# the state helper, so it must be a plain version string and nothing else.
valid_version() {
  case "$1" in
    '')            return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *)             return 0 ;;
  esac
}

# Wrapper around the real build: gates it on the build-state markers so a
# search never waits behind another build, and an offline machine does not retry
# the download on every keystroke. The body (build_catalog) keeps the original
# freshness short-circuit, so a warm catalog still costs a couple of stats.
ensure_catalog() {
  local want
  want=$(expected_version)
  if valid_version "$want" && [ -f "$STORE/current" ] && [ "$(cat "$STORE/current" 2>/dev/null)" = "$want" ] && [ -d "$STORE/$want" ]; then
    local mtime now age
    mtime=$(stat -c %Y "$STORE/current" 2>/dev/null || echo 0)
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ]; then
      now=$(date +%s)
      age=$(( (now - mtime) / 86400 ))
      [ "$age" -lt "$STALE_DAYS" ] && return 0
    fi
  fi

  if catalog_marker_fresh "$BUILD_MARKER" "$CATALOG_BUILD_STALE_SECONDS"; then
    echo "appstream catalog: a build is already running" >&2
    return 1
  fi
  if catalog_backoff_active "$FAILED_MARKER"; then
    echo "appstream catalog: backing off after a recent failed build" >&2
    return 1
  fi
  catalog_mark_building "$BUILD_MARKER"

  if build_catalog "$want"; then
    catalog_clear_building "$BUILD_MARKER"
    catalog_clear_failed "$FAILED_MARKER"
    return 0
  fi
  catalog_clear_building "$BUILD_MARKER"
  catalog_mark_failed "$FAILED_MARKER"
  return 1
}

build_catalog() {
  local want="$1"
  marker="$STORE/current"

  # An empty or otherwise unusable version must never reach the state helper.
  # `prune "$cache" ""` in particular would match no entry to keep and delete
  # the whole catalog, then `swap` would fail on the empty path component —
  # losing the last good build. Refuse before anything is created or removed.
  if ! valid_version "$want"; then
    echo "appstream catalog: refusing to build, unusable version '$want'" >&2
    return 1
  fi

  # Fresh + same version + tree present? Skip the build.
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$want" ] && [ -d "$STORE/$want" ]; then
    mtime=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ]; then
      now=$(date +%s)
      age=$(( (now - mtime) / 86400 ))
      [ "$age" -lt "$STALE_DAYS" ] && return 0
    fi
  fi

  tmpname=$(python3 "$STATE_PY" tmpdir "$cache") || { echo "mktemp failed" >&2; return 1; }
  tmpdir="$STORE/$tmpname"

  cleanup_tmp() {
    python3 "$STATE_PY" rmtree "$cache" "$tmpname" >/dev/null 2>&1 || true
  }

  if local_available; then
    # Pacman-verified local data: copy (dereferenced) so the cache holds only
    # regular PNG files; rebuilds whenever `pacman -Q` version changes. `want`
    # is exactly local_version here (expected_version returned it), and it has
    # already been validated, so there is no second lookup to race against.
    for repo in core extra multilib; do
      src="$SWCATALOG/icons/archlinux-arch-$repo/$SIZE"
      if [ ! -d "$src" ]; then
        echo "local appstream icons missing: $src" >&2
        cleanup_tmp
        return 1
      fi
      mkdir -p "$tmpdir/$repo"
      if ! cp -aL "$src"/. "$tmpdir/$repo"/ 2>/dev/null; then
        echo "failed to copy local appstream icons from $src" >&2
        cleanup_tmp
        return 1
      fi
    done
  else
    # Network fallback: pinned (immutable) release, checksum-verified before use.
    export ARCH_BASE
    if ! python3 - "$BASE" "$want" "$SIZE" "$REPOS" "$tmpdir" <<'PY'
import hashlib
import io
import os
import re
import sys
import tarfile
import urllib.request

BASE, ver, size, repos, tmpdir = sys.argv[1:6]

MAX_RAW    = int(os.environ.get("FOSSFETCH_MAX_RAW", "67108864"))        # 64 MiB / archive
MAX_MEMBER = int(os.environ.get("FOSSFETCH_MAX_ICON", "1048576"))        # 1 MiB / icon
MAX_TOTAL  = int(os.environ.get("FOSSFETCH_MAX_ICON_TOTAL", "134217728"))
MAX_COUNT  = int(os.environ.get("FOSSFETCH_MAX_ICON_COUNT", "20000"))

sums = os.environ.get("FOSSFETCH_PINNED_SUMS", "").split()
if len(sums) != 12:
    sys.exit(2)


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


REPO_ORDER = ["core", "extra", "multilib"]
# sha256sums() slot per repo: 0 = xml, 1 = icons-48x48, 2 = 64x64, 3 = 128x128.
SLOT_48 = 1
SAFE_RE = re.compile(r"[A-Za-z0-9_.+~-]+\.png\Z")

# The raw (compressed) archive is already bounded to MAX_RAW by `fetch`, and
# the *decompressed* quota is enforced through member validation: every tar
# member's declared size is checked (per-file + aggregate) and its body is only
# read after that check passes, so a gzip bomb is never buffered or written.
# Member count is capped too.
total = 0
count = 0
for repo in repos.split():
    if repo not in REPO_ORDER:
        sys.exit(3)
    slot = REPO_ORDER.index(repo) * 4 + SLOT_48
    raw = fetch("%s/%s/%s/icons-%s.tar.gz" % (BASE, ver, repo, size), MAX_RAW)
    if raw is None:
        sys.exit(4)
    # Verify against the immutable, reviewed pin BEFORE any extraction. This is
    # the trust anchor: the pin is committed source, never a runtime fetch.
    if hashlib.sha256(raw).hexdigest() != sums[slot]:
        sys.exit(5)  # unauthorized/checksum-mismatched archive -> refused

    outdir = os.path.join(tmpdir, repo)
    os.makedirs(outdir, mode=0o755, exist_ok=True)
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
            for member in tf:
                name = member.name or ""
                if name.startswith("/"):
                    sys.exit(6)  # absolute path
                parts = name.split("/")
                if any(p in ("", ".", "..") for p in parts):
                    sys.exit(7)  # traversal / empty component
                if member.isdir() and not member.issym():
                    continue
                if not member.isfile() or member.issym() or member.islnk():
                    sys.exit(8)  # symlinks/hardlinks/device/fifo rejected
                if not name.lower().endswith(".png") or not SAFE_RE.match(name):
                    sys.exit(9)  # only plain basename .png icons
                if member.size > MAX_MEMBER or total + member.size > MAX_TOTAL:
                    sys.exit(10)  # decompressed-bytes cap (per-file + total)
                count += 1
                if count > MAX_COUNT:
                    sys.exit(11)
                src = tf.extractfile(member)
                if src is None:
                    sys.exit(12)
                dst = os.path.join(outdir, os.path.basename(name))
                with open(dst, "wb") as out:
                    while True:
                        chunk = src.read(65536)
                        if not chunk:
                            break
                        out.write(chunk)
                total += member.size
    except (tarfile.TarError, EOFError, OSError, ValueError):
        sys.exit(13)

sys.exit(0)
PY
    then
      cleanup_tmp
      python3 "$STATE_PY" rmtmp "$cache" >/dev/null 2>&1 || true
      echo "appstream icon catalog fetch/verify failed (version $want)" >&2
      return 1
    fi
  fi

  # Atomic swap of the freshly built catalog into place via the pinned dirfd.
  # This runs BEFORE the prune: swap parks any existing catalog as <src>.old
  # and only drops it once the new tree is in position, so a failure here still
  # leaves the last good catalog recoverable. Pruning first would delete the
  # old versions and then lose the new build if the swap failed.
  python3 "$STATE_PY" swap "$cache" "$tmpname" "$want" || { cleanup_tmp; return 1; }

  printf '%s\n' "$want" | python3 "$STATE_PY" put "$cache" current || return 1

  # Now that the new catalog is committed, drop superseded versions (via dirfs;
  # foreign-owned or symlinked entries are refused, never followed).
  python3 "$STATE_PY" prune "$cache" "$want" >/dev/null 2>&1 || true

  # Commit the transient reap in the same build transaction: stale .tmp.* /
  # *.old left by earlier interrupted builds must not linger next to a fresh
  # "current" marker (failure paths reap; the success path now finishes the
  # reap too, so a done-marker never coexists with build garbage).
  python3 "$STATE_PY" rmtmp "$cache" >/dev/null 2>&1 || true
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