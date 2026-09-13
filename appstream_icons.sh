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

# The tied (config, pacman-installed) local source of truth, used when the
# archlinux-appstream-data package is present.
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

expected_version() {
  if local_available; then local_version; else echo "$PINNED_VER"; fi
}

ensure_catalog() {
  marker="$STORE/current"
  want=$(expected_version) || want="$PINNED_VER"

  # Fresh + same version + tree present? Skip the build.
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$want" ] && [ -d "$STORE/$want" ]; then
    mtime=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ]; then
      now=$(date +%s)
      age=$(( (now - mtime) / 86400 ))
      [ "$age" -lt "$STALE_DAYS" ] && return 0
    fi
  fi

  target="$STORE/$want"
  tmpname=$(python3 "$STATE_PY" tmpdir "$cache") || { echo "mktemp failed" >&2; return 1; }
  tmpdir="$STORE/$tmpname"

  cleanup_tmp() {
    python3 "$STATE_PY" rmtree "$cache" "$tmpname" >/dev/null 2>&1 || true
  }

  if local_available && [ "$want" = "$(local_version)" ]; then
    # Pacman-verified local data: copy (dereferenced) so the cache holds only
    # regular PNG files; rebuilds whenever `pacman -Q` version changes.
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

  # Prune older catalog versions only after a successful build (via dirfds;
  # foreign-owned or symlinked entries are refused, never followed), so a
  # failed build never destroys the last good catalog.
  python3 "$STATE_PY" prune "$cache" "$want" || { cleanup_tmp; return 1; }

  # Atomic swap of the freshly built catalog into place via the pinned dirfd.
  python3 "$STATE_PY" swap "$cache" "$tmpname" "$want" || { cleanup_tmp; return 1; }

  printf '%s\n' "$want" | python3 "$STATE_PY" put "$cache" current || return 1
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