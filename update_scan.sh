#!/bin/sh
# Update scan for the FossFetch panel. Bundled as a file (not an inline `sh -c`
# string in Panel.qml) so it can be regression-tested directly.
#
# Usage: sh update_scan.sh <aurHelper>
#
# Emits, on stdout only:
#   UPD|pacman|<name>|<available>     repo packages with a newer version
#   UPD|<helper>|<name>|<available>   AUR packages (helper = yay | paru)
#   UPD|flatpak|<appid>|<available>   Flathub apps with a newer version
#   SCANFAIL|<source>|<reason>                a source that could not answer
#   STATUS|ok|updates | STATUS|degraded|updates   one trailing frame
#
# Nothing here is ever executed. The lines are data the panel compares against
# its installed-package snapshot to decide what an update actually is — the
# scan reports what is OFFERED; the panel confirms what is INSTALLED.
set -u

HELPER="$1"

# How many sources failed to answer. A source that could not be reached is NOT
# the same as a source with nothing to report, and the difference matters:
# reporting "no updates" for a check that never ran makes the Updates tab and the
# badge disappear exactly when they are most wanted.
FAILED=0

# --- pacman repo packages ----------------------------------------------------
# `checkupdates` prints "name old_version -> new_version". The fourth field is
# the version that would be installed; the second is what is on the machine.
# Filter on the literal "->" so a stray warning line cannot masquerade as a
# package row.
if command -v checkupdates >/dev/null 2>&1; then
  # stderr is captured rather than discarded. `checkupdates` copies the sync
  # databases to a temp dir first, so it fails outright while anything holds the
  # pacman lock — which is exactly what happens in the seconds after a shell
  # start, when this scan first runs. Swallowing that turned a transient lock
  # into a confident "STATUS|ok" with zero rows, and the badge went quiet until
  # the next five-minute tick.
  cu_out=$(checkupdates 2>&1)
  cu_rc=$?
  if [ "$cu_rc" -ne 0 ]; then
    cu_reason=$(printf '%s\n' "$cu_out" | grep -m1 -i "error\|lock\|failed" | cut -c1-120)
    [ -n "$cu_reason" ] || cu_reason="exit $cu_rc"
    echo "SCANFAIL|checkupdates|$cu_reason"
    FAILED=$((FAILED + 1))
  fi
  # The awk filter still requires a literal "->", so a captured error or warning
  # line can never be mistaken for a package row.
  printf '%s\n' "$cu_out" |
    awk '$3 == "->" && $1 != "" { print "UPD|pacman|" $1 "|" $4 }'
fi

# --- AUR packages ------------------------------------------------------------
# yay and paru both answer `-Qua` with the same "name old -> new" shape. The
# helper name is passed in rather than probed so the panel stays the single
# place that decides which one is in use.
if [ -n "$HELPER" ] && command -v "$HELPER" >/dev/null 2>&1; then
  "$HELPER" -Qua 2>/dev/null |
    awk -v h="$HELPER" '$3 == "->" && $1 != "" { print "UPD|" h "|" $1 "|" $4 }'
fi

# --- Flathub -----------------------------------------------------------------
# remote-ls --updates prints "appid<TAB>version" for apps that have a newer
# build on the remote. The installed version comes from the panel's snapshot,
# so only the available one is emitted here.
if command -v flatpak >/dev/null 2>&1; then
  fk_out=$(flatpak remote-ls --updates --columns=application,version 2>&1)
  fk_rc=$?
  if [ "$fk_rc" -ne 0 ]; then
    echo "SCANFAIL|flatpak|exit $fk_rc"
    FAILED=$((FAILED + 1))
  fi
  printf '%s\n' "$fk_out" |
    awk -F'\t' '$1 != "" && $1 !~ /^[A-Z]+:/ { print "UPD|flatpak|" $1 "|" $2 }'
fi

# STATUS contract. The scan is advisory: a missing tool contributes no rows
# rather than failing, so "ok" means "the scan ran", not "every source was
# reachable". A total absence of rows is the healthy state, not an error.
if [ "$FAILED" -gt 0 ]; then
  echo "STATUS|degraded|updates"
else
  echo "STATUS|ok|updates"
fi
