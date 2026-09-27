#!/bin/bash
# Maintainer-only helper for appstream_pins.sh. NEVER called at runtime: the
# shipping pins are committed, reviewed source and are the trust anchor. This
# tool exists so the constants are machine-derived (and verifiable) rather than
# hand-typed, and so the pin-bump procedure is one auditable command.
#
# The authoritative source of every checksum is the `sha256sums=(...)` array in
# the upstream packaging PKGBUILD:
#   https://gitlab.archlinux.org/archlinux/packaging/packages/archlinux-appstream-data
# (sources.archlinux.org publishes no sha256sums file for this package.)
#
# Slot order matches the PKGBUILD `source+=()` loop and appstream_pins.sh:
#   per repo (core, extra, multilib): xml, 48x48, 64x64, 128x128
#   => repo*4+0 xml, repo*4+1 48x48, repo*4+2 64x64, repo*4+3 128x128
#
# Usage:
#   tools/update_pins.sh verify            re-check the committed pins against
#                                           freshly downloaded upstream artifacts
#                                           (no network trust beyond verifying
#                                           bytes match the committed trust anchor)
#   tools/update_pins.sh bump <pkgver>     regenerate PINNED_PKGVER + the 12 pins
#                                           from the packaging PKGBUILD, when its
#                                           pkgver equals <pkgver>
#
# After a `bump`, review the diff and commit it — that commit is the trust event.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$TOOLS_DIR")"
PINS_FILE="$PLUGIN_DIR/appstream_pins.sh"

PKGBUILD_URL="https://gitlab.archlinux.org/archlinux/packaging/packages/archlinux-appstream-data/-/raw"
ARTIFACT_BASE="https://sources.archlinux.org/other/packages/archlinux-appstream-data"

REPOS=(core extra multilib)
KINDS=(xml icons-48x48 icons-64x64 icons-128x128)

die() { echo "update_pins: $*" >&2; exit 1; }

# The 12 artifacts in slot order: "repo<TAB>artifact-filename<TAB>PKGBUILD-slot-index"
artifact_table() {
  local repo kind idx=0
  for repo in "${REPOS[@]}"; do
    for kind in "${KINDS[@]}"; do
      case "$kind" in
        xml)            printf '%s\t%s\t%s\n' "$repo" "Components-x86_64.xml.gz" "$idx" ;;
        icons-*)        printf '%s\t%s\t%s\n' "$repo" "${kind}.tar.gz" "$idx" ;;
      esac
      idx=$((idx + 1))
    done
  done
}

# Pull the 12-entry sha256sums=(...) array out of a PKGBUILD (read on stdin),
# in source order.
parse_pkgbuild_sums() {
  # Strip comments, then collect the quoted hex literals inside sha256sums=( ... ).
  sed -n '/^sha256sums=(/,/^[[:space:]]*)/p' \
    | grep -oE "'[0-9a-f]{64}'" \
    | tr -d "'"
}

read_committed_pins() {
  # Emit one pin per line, in slot order, from the committed pins file.
  local line
  while IFS= read -r line; do
    case "$line" in
      *\'[0-9a-f][0-9a-f]*\'*) printf '%s\n' "$line" | grep -oE "'[0-9a-f]{64}'" | tr -d "'" ;;
    esac
  done < "$PINS_FILE"
}

read_committed_ver() {
  sed -n "s/^PINNED_PKGVER='\([0-9]\{8\}\)'.*/\1/p" "$PINS_FILE" | head -1
}

count_pins() {
  read_committed_pins | grep -c . || true
}

# Fetch the packaging PKGBUILD. The Arch packaging repo only carries the latest
# release on 'main', so a per-tag ref does not resolve; we always read 'main' and
# require its pkgver to equal the requested target.
fetch_pkgbuild() {
  curl -sSfL --max-time 60 "$PKGBUILD_URL/main/PKGBUILD" \
    || die "could not fetch PKGBUILD from 'main'"
}

# --- verify -----------------------------------------------------------------
# Re-download every artifact for the committed pkgver and compare its sha256 to
# the committed pin. Any drift (either a typo in the pin, or upstream changing a
# file) is reported and makes the command fail.
do_verify() {
  local ver; ver="$(read_committed_ver)"
  [ -n "$ver" ] || die "no PINNED_PKGVER found in $PINS_FILE"

  local committed; committed="$(read_committed_pins)"
  local n; n="$(printf '%s\n' "$committed" | grep -c .)"
  [ "$n" -eq 12 ] || die "expected 12 committed pins, found $n"

  echo "Verifying committed pins for archlinux-appstream-data $ver" >&2
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  local repo file idx actual want rc=0 slot=0
  while IFS=$'\t' read -r repo file idx; do
    slot=$((slot + 1))
    want="$(printf '%s\n' "$committed" | sed -n "${slot}p")"
    local out="$tmp/$file"
    if ! curl -sSfL --max-time 180 -o "$out" \
        "$ARTIFACT_BASE/$ver/$repo/$file"; then
      echo "  FAIL  $repo/$file  (download error)" >&2
      rc=1
      continue
    fi
    actual="$(sha256sum "$out" | cut -d' ' -f1)"
    if [ "$actual" = "$want" ]; then
      printf '  ok    %s/%s\n' "$repo" "$file" >&2
    else
      printf '  FAIL  %s/%s\n        committed %s\n        actual    %s\n' \
        "$repo" "$file" "$want" "$actual" >&2
      rc=1
    fi
  done < <(artifact_table)

  if [ "$rc" -eq 0 ]; then
    echo "All 12 committed pins match the published artifacts." >&2
  else
    echo "One or more pins do not match. Investigate before use." >&2
  fi
  return "$rc"
}

# --- bump -------------------------------------------------------------------
# Regenerate PINNED_PKGVER + the pin array from the packaging PKGBUILD, but only
# if that PKGBUILD describes exactly the requested <pkgver>. This guards against
# bumping to a checksum set that does not match the pkgver the URLs will fetch.
do_bump() {
  local want_ver="$1"
  local pkgbuild; pkgbuild="$(fetch_pkgbuild)"

  local ver
  ver="$(printf '%s\n' "$pkgbuild" | sed -n 's/^pkgver=\([0-9]\{8\}\).*/\1/p' | head -1)"
  [ -n "$ver" ] || die "could not parse pkgver from packaging PKGBUILD"
  [ "$ver" = "$want_ver" ] \
    || die "upstream 'main' PKGBUILD is pkgver=$ver, not the requested $want_ver" \
          "(the packaging repo only tracks the latest release)"

  local sums; sums="$(printf '%s\n' "$pkgbuild" | parse_pkgbuild_sums)"
  local n; n="$(printf '%s\n' "$sums" | grep -c . || true)"
  [ "$n" -eq 12 ] || die "expected 12 sha256 entries in PKGBUILD, found $n"

  # Render the new array body with the per-slot comments.
  local body; body="$(mktemp)"
  local repo kind idx=0 line label
  for repo in "${REPOS[@]}"; do
    for kind in "${KINDS[@]}"; do
      idx=$((idx + 1))
      case "$kind" in
        xml) label="xml" ;;
        *)   label="$kind" ;;
      esac
      line="$(printf '%s' "$sums" | sed -n "${idx}p")"
      printf "  '%s' # %-8s %s\n" "$line" "$repo" "$label" >> "$body"
    done
  done

  # Splice the new version + array into a copy of the pins file, preserving the
  # rest of the file (including the header). The body lives in its own file (not
  # an awk -v argument) so newlines survive intact.
  local tmp; tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' '$tmp.in' '$body'" EXIT

  local verline; verline="PINNED_PKGVER='$ver'"
  # 1) replace PINNED_PKGVER
  sed "s|^PINNED_PKGVER='[0-9]\{8\}'.*$|$verline|" "$PINS_FILE" > "$tmp.in"
  # 2) replace the block between 'PINNED_SHA256SUMS=(' and its first ')' line
  #    with the marker line, the body, then ')'.
  awk -v bodyfile="$body" '
    /^PINNED_SHA256SUMS=\($/ {
      print
      while ((getline l < bodyfile) > 0) print l
      close(bodyfile)
      inarray = 1
      next
    }
    inarray && /^\)$/ { inarray = 0; print; next }
    inarray { next }
    { print }
  ' "$tmp.in" > "$tmp"

  echo "Regenerated pins for pkgver $ver. Review the diff:" >&2
  diff -u "$PINS_FILE" "$tmp" >&2 || true
  echo >&2
  cp "$tmp" "$PINS_FILE.generated"
  echo "Wrote $PINS_FILE.generated (committed pin file left unchanged)." >&2
}

case "${1:-}" in
  verify) [ -z "${2:-}" ] || die "verify takes no arguments"; do_verify ;;
  bump)
    [ -n "${2:-}" ] || die "usage: $0 bump <pkgver>"
    do_bump "$2"
    ;;
  *)
    cat >&2 <<EOF
usage: $0 verify | bump <pkgver>

  verify           re-download the 12 artifacts for the committed PINNED_PKGVER
                   and confirm each matches its committed pin.
  bump <pkgver>    regenerate PINNED_PKGVER + the 12 pins from the upstream
                   packaging PKGBUILD, but only when its pkgver equals <pkgver>
                   (the packaging repo only tracks the latest release, so <pkgver>
                   must be the current one). Writes $PINS_FILE.generated for
                   review; it does not modify the committed pin file itself.
EOF
    exit 2
    ;;
esac
