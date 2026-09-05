#!/bin/bash
# Resolve icons for Arch repo packages from the AppStream catalog that Arch
# publishes at sources.archlinux.org. Usage:
#   appstream_icons.sh ensure <cacheRoot>
#   appstream_icons.sh resolve <cacheRoot> <pkg> [<pkg> ...]
#
# `ensure` downloads the icons-48x48.tar.gz tarball for each repo at the newest
# catalog date, extracts it into <cacheRoot>/catalog/<date>/<repo>/, and records
# the date. ~2.7MB once; refreshed only when the catalog is over a month old.
#
# `resolve` looks up each pkg's icon by its "<pkg>_<appid>.png" prefix, which is
# how the catalog names every entry — no XML needed. Emits "I|<pkg>|<path>" per
# arg (empty path when the pkg ships no icon in the catalog).

set -u

BASE="https://sources.archlinux.org/other/packages/archlinux-appstream-data"
REPOS="core extra multilib"
SIZE="48x48"
STALE_DAYS=32

mode="${1:-}"
cache="${2:-$HOME/.cache/fossfetch}"
STORE="$cache/catalog"
mkdir -p "$STORE"

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

  newest=$(curl -fsSL --max-time 20 "$BASE/" 2>/dev/null | grep -oE '[0-9]{8}/' - | sort -r | head -1)
  newest="${newest%/}"
  [ -z "$newest" ] && return 1

  target="$STORE/$newest"
  if [ ! -d "$target" ]; then
    tmpdir="$STORE/.tmp-$newest"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    for repo in $REPOS; do
      url="$BASE/$newest/$repo/icons-$SIZE.tar.gz"
      tmp="$tmpdir/$repo.tar.gz"
      curl -fsSL --max-time 60 -o "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; continue; }
      bsdtar -xf "$tmp" -C "$tmpdir" 2>/dev/null
      rm -f "$tmp"
    done
    rm -rf "$STORE"/*-* 2>/dev/null
    mv "$tmpdir" "$target"
  fi

  echo "$newest" > "$marker"
  return 0
}

resolve_icons() {
  date_dir=$(cat "$STORE/current" 2>/dev/null || true)
  if [ -z "$date_dir" ] || [ ! -d "$STORE/$date_dir" ]; then
    for pkg in "${@:3}"; do echo "I|$pkg|"; done
    return 0
  fi

  for pkg in "${@:3}"; do
    hit=$(find "$STORE/$date_dir" -maxdepth 1 -type f -name "${pkg}_*" 2>/dev/null | sort | head -1)
    [ -n "$hit" ] && [ -f "$hit" ] && echo "I|$pkg|$hit" || echo "I|$pkg|"
  done
}

case "$mode" in
  ensure)  ensure_catalog ;;
  resolve) ensure_catalog; resolve_icons "${@:-}" ;;
  *) echo "I||"; exit 1 ;;
esac