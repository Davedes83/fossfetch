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
# same `current` marker + 32-day staleness as the icon catalog, so it only
# rebuilds when the icons are refreshed.
#
# `resolve` maps a natural-language keyword (via the shared groups.keywords
# synonym table) to one or more AppStream categories and prints the merged,
# de-duplicated package names, one per line. Prints nothing when the keyword
# matches no group.

set -u

BASE="https://sources.archlinux.org/other/packages/archlinux-appstream-data"
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
  [ -f "$STORE/current" ] || { echo "no appstream catalog; run appstream_icons.sh ensure first" >&2; return 1; }
  date_dir=$(cat "$STORE/current" 2>/dev/null)
  target="$STORE/$date_dir/groups.tsv"
  groups_mtime=$(stat -c %Y "$target" 2>/dev/null || echo 0)
  marker_mtime=$(stat -c %Y "$STORE/current" 2>/dev/null || echo 0)
  [ "$groups_mtime" -ge "$marker_mtime" ] && [ -s "$target" ] && return 0

  tmp="$target.tmp"
  : > "$tmp"
  for repo in $REPOS; do
    url="$BASE/$date_dir/$repo/Components-$ARCH.xml.gz"
    curl -fsSL --max-time 60 "$url" 2>/dev/null | python3 -c '
import sys, gzip, re
data = sys.stdin.buffer.read()
xml = gzip.decompress(data)
for m in re.finditer(rb"<component type=\"desktop-application\".*?</component>", xml, re.S):
    blk = m.group(0)
    pkg = re.search(rb"<pkgname>(.*?)</pkgname>", blk)
    if not pkg: continue
    p = pkg.group(1).decode()
    for c in re.findall(rb"<category>(.*?)</category>", blk):
        print(c.decode() + "\t" + p)
' >> "$tmp"
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