#!/bin/bash
# Immutable pins for the Arch AppStream catalog. These constants ARE the trust
# anchor for the network download path: they are committed to the reviewed
# plugin source and verified by the approval process, and are never fetched or
# derived from a remote at runtime. They correspond to the official Arch
# `archlinux-appstream-data` package at pkgver 20260821.
#
# Authoritative source of these values: the `sha256sums=(...)` array in the
# upstream packaging PKGBUILD,
#   https://gitlab.archlinux.org/archlinux/packaging/packages/archlinux-appstream-data
# at the tag for this pkgver. Note that sources.archlinux.org does NOT publish a
# `sha256sums` file for this package (it 404s) — the PKGBUILD array is the only
# authoritative source. The artifacts themselves live at
#   https://sources.archlinux.org/other/packages/archlinux-appstream-data/$pkgver/<repo>/
# All 12 values below were re-verified against those downloaded artifacts on
# 2026-09-27 and are correct as committed. `tools/update_pins.sh verify` re-runs
# that check; `tools/update_pins.sh bump <pkgver>` regenerates this file.
#
# sha256sums order — per repo (core, extra, multilib), four artifacts each,
# matching the PKGBUILD `source+=()` ordering:
#   repo*4+0 = Components-x86_64.xml.gz
#   repo*4+1 = icons-48x48.tar.gz
#   repo*4+2 = icons-64x64.tar.gz
#   repo*4+3 = icons-128x128.tar.gz
#
# NOTE: for this pkgver the upstream `core` icons-48x48.tar.gz and
# icons-128x128.tar.gz are genuinely byte-identical (both hash 7989bb31...), as
# published by Arch. This is a verified upstream property of the release, NOT a
# copy-paste error here — do not "fix" it. (Upstream 20260910 goes further and
# publishes all three core icon sizes with a single identical hash.) Only slots 0
# (xml) and 1 (48x48) are read at runtime; slots 2 and 3 document the full
# upstream sums and are covered by the well-formedness test.
#
# When Arch bumps pkgver/checksums, update this file in a new reviewed commit
# (the shell keeps the previous, still-valid catalog until then). Prefer the
# distribution's already verified data: if `archlinux-appstream-data` is
# installed by pacman, /usr/share/swcatalog is used instead and these pins are
# irrelevant. Tests may override via FOSSFETCH_PINNED_VER / FOSSFETCH_PINNED_SUMS
# (documents the exact pin under test; shipping defaults remain these constants).
PINNED_PKGVER='20260821'
PINNED_SHA256SUMS=(
  '170ef4957375bbcc323742b52c7bca6ad87dcf15ce6a5b0ef57992c3e0f19bee' # core     xml
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core   48x48
  'eeb7667241ac81e266de1c8246384ec25722ed2b942293bb4d2009178b7fc4f2' # core   64x64
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core  128x128
  '60716951977b405d9dea4b8c3c64dc73eab40d777a60cf22633fb149af3bbb93' # extra     xml
  'ca1abf84f1c05f407cf64b6f3d096b736b420931af685ff4dadadb49d1057f40' # extra   48x48
  '0afb0aaacb5ef3fa988d54ca3d062ce82e14f14feac8385981c6ba2b0db650a6' # extra   64x64
  '272ab715b8f629e5245f892cfb3938f6630f2d9ffbe6dd7ab70a17bce4c79e3a' # extra  128x128
  '483b5dbf75ca736388d98dc1845538238a3d210dda825f6315c4341ee0761f9c' # multilib  xml
  '1b5c3906201fcf47e78969262c4c4de3567819765e5611745384583c32c61761' # multilib 48x48
  '63fc7af8ad16dbecea0477ddd0257518a1c8f411432db87d8254e8431464c3d0' # multilib 64x64
  'c83722fc4d223ae4a7cb64e030b3f94812ca69d133aa768cef01f50102f2e737' # multilib128x128
)