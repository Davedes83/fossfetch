#!/bin/sh
# Pacman search backend for the FossFetch panel. Bundled as a file (not an
# inline `sh -c` string in Panel.qml) so it can be regression-tested directly.
#
# Usage: sh backend_pacman.sh <query> <cacheRoot> <appstream_groups.sh>
#
# Emits, on stdout only:
#   G|pkg1|pkg2|...        category members for this query (optional)
#   <normal pacman -Ss output>
#   STATUS|ok|pacman | STATUS|error|<reason>    one trailing frame
#
# The package names in the G| marker come only from the local groups index
# (never from user input), and the query is passed as $1 — never interpolated
# into the script text — so no shell injection surface is introduced.
set -u

Q="$1"; C="$2"; GS="$3"

P=$("$GS" resolve "$C" "$Q" 2>/dev/null)
if [ -n "$P" ]; then
  R=$(printf '%s' "$P" | tr '\n' '|' | sed 's/|$//')
  echo "G|$R"
fi

pacman -Ss "$Q"
RC=$?

# `pacman -Ss` exits 0 on a hit and 1 on no-match, but genuine failures also
# exit 1 — so only re-query stderr when the exit is non-zero. An empty stderr
# means "no match"; an "error:" line means a real failure. 127 = binary absent.
if [ "$RC" -eq 0 ]; then
  echo "STATUS|ok|pacman"
elif [ "$RC" -eq 127 ]; then
  echo "STATUS|error|pacman binary missing (exit 127)"
else
  E=$(pacman -Ss "$Q" 2>&1 >/dev/null)
  if [ -z "$E" ]; then
    echo "STATUS|ok|pacman"
  else
    echo "STATUS|error|pacman: $E"
  fi
fi
