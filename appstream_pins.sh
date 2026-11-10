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
PINNED_PKGVER='20260910'
PINNED_SHA256SUMS=(
  '8a13a89c7ea73ab81d39b2d121f53cdd32919defa001fc1e303d13ba44033146' # core     xml
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core     icons-48x48
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core     icons-64x64
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core     icons-128x128
  '477329002e53b24500bdb1a0447464545ca44536c46b65ebe9630a28ac8d50e8' # extra    xml
  '4ce96bd9bc0a83df1a8b8d0e545a4bcfe996f0acb2d5e5d7ce5809a41eeb0866' # extra    icons-48x48
  '5683fd93baefda2a4310d977a1af4e6c66331cd70aee388240700ab88c994929' # extra    icons-64x64
  '16c3fd11dba41c9d4d78e460a81ec7f92edb6663e033f63e19f111e43213022d' # extra    icons-128x128
  '8baafd3d360efc33c40d0e3215ff10182ecbc02476cb1e2c8179f184e9266d2e' # multilib xml
  'b8eafb7612638a02813a9d3d092fcebf89c7369b114ac69d1f1b3d31de92377a' # multilib icons-48x48
  'b22c32091f089e87adb25a2c9b741996e8ea69b8e52aca2fd28bebe4ee3a2021' # multilib icons-64x64
  '347971518bb28fc585dca290c081ebf5dd039c53f7d1924e0c132028ad0ea9a0' # multilib icons-128x128
)
