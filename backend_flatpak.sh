#!/bin/sh
# Flatpak search backend for the FossFetch panel. Bundled as a file (not an
# inline `sh -c` string in Panel.qml) so it can be regression-tested directly.
#
# Usage: sh backend_flatpak.sh <query> <cacheRoot> <flathub_groups.py>
#
# Emits, on stdout only:
#   G|name\tdesc\tappid\tversion\treleased   group rows from the Flathub index
#   <normal flatpak search output>
#   STATUS|ok|flatpak | STATUS|error|<reason>    one trailing frame
#
# The query is passed as $1 — never interpolated into the script text.
set -u

Q="$1"; C="$2"; GS="$3"

python3 "$GS" resolve "$C" "$Q" 2>/dev/null |
  awk -F'\t' '{print "G|"$2"\t"$3"\t"$1"\t"$4"\t"$5}'

OUT=$(flatpak search --columns=name,description,application,version "$Q" 2>/dev/null)

printf '%s\n' "$OUT" |
  awk -F'\t' -v idx="$C/flathub/appids.tsv" '
    BEGIN { while ((getline l < idx) > 0) { split(l, a, "\t"); d[a[1]] = a[2] } close(idx) }
    NF >= 4 { print $0 (d[$3] != "" ? "\t" d[$3] : "") }'

# STATUS contract. `flatpak search` exits 1 both when it matches nothing (the
# common, expected case for a query that finds no app) and when the lookup
# genuinely fails, so the exit code alone cannot be read as "error" — doing so
# reports every legitimate miss as "Lookup failed".
#
#   flatpak absent   -> STATUS|error (binary missing)
#   rows emitted     -> STATUS|ok (it clearly ran and matched)
#   otherwise        -> STATUS|ok (ran, matched nothing)
#
# The ambiguous "non-zero exit, no rows" case is resolved with a cheap LOCAL
# `command -v` probe rather than by re-running the search: unlike the pacman
# backend's stderr re-query, a second `flatpak search` would double a remote
# round trip on every miss, and misses are the common case.
#
# Accepted limitation: with a working binary, a Flathub network outage is
# reported as "no matches" rather than "lookup failed". That is the milder of
# the two wrong answers; the reverse would misreport every real miss.
if ! command -v flatpak >/dev/null 2>&1; then
  echo "STATUS|error|flatpak binary missing"
else
  echo "STATUS|ok|flatpak"
fi
