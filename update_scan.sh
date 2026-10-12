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
#   STATUS|ok|updates | STATUS|error|<reason>   one trailing frame
#
# Nothing here is ever executed. The lines are data the panel compares against
# its installed-package snapshot to decide what an update actually is — the
# scan reports what is OFFERED; the panel confirms what is INSTALLED.
set -u

HELPER="$1"

# --- pacman repo packages ----------------------------------------------------
# `checkupdates` prints "name old_version -> new_version". The fourth field is
# the version that would be installed; the second is what is on the machine.
# Filter on the literal "->" so a stray warning line cannot masquerade as a
# package row.
if command -v checkupdates >/dev/null 2>&1; then
  checkupdates 2>/dev/null |
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
  flatpak remote-ls --updates --columns=application,version 2>/dev/null |
    awk -F'\t' '$1 != "" { print "UPD|flatpak|" $1 "|" $2 }'
fi

# STATUS contract. The scan is advisory: a missing tool contributes no rows
# rather than failing, so "ok" means "the scan ran", not "every source was
# reachable". A total absence of rows is the healthy state, not an error.
echo "STATUS|ok|updates"
