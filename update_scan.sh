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
  # Exit 2 is NOT a failure: `checkupdates` only reaches it from its empty
  # branch (the `else` of `if (( ${#updates[@]} ))`, the last lines of
  # /usr/bin/checkupdates), which is how it says "your system is up to date".
  # A real failure is 1, from `die 'Cannot fetch updates'` — the pacman lock.
  #
  # Reading 2 as failure made the common case wrong: an up-to-date machine, which
  # is most machines most of the time, reported degraded forever, and the panel
  # kept that state by retrying the whole three-source scan every 25 seconds,
  # indefinitely — each retry running `fakeroot pacman -Sy` over the network.
  if [ "$cu_rc" -ne 0 ] && [ "$cu_rc" -ne 2 ]; then
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
  # Same treatment as checkupdates above: a helper that could not answer (db
  # locked right after a shell start, broken git state, no network) exits
  # non-zero and prints nothing on stdout. Treating that as "no AUR updates"
  # reported a clean scan while the check never ran, which is the one thing
  # FAILED exists to prevent.
  au_out=$("$HELPER" -Qua 2>&1)
  au_rc=$?
  if [ "$au_rc" -ne 0 ]; then
    au_reason=$(printf '%s\n' "$au_out" | grep -m1 -i "error\|lock\|failed\|fatal" | cut -c1-120)
    [ -n "$au_reason" ] || au_reason="exit $au_rc"
    echo "SCANFAIL|$HELPER|$au_reason"
    FAILED=$((FAILED + 1))
  fi
  printf '%s\n' "$au_out" |
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
