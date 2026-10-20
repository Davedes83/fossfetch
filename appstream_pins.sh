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
PINNED_PKGVER='20261017'
PINNED_SHA256SUMS=(
  'bc06c251da2da941afb1579168bf5bce28d5b34f9a4e67f3c1ce7cc986bed581' # core     xml
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core     icons-48x48
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core     icons-64x64
  '7989bb311baa38ef545250282aa065d23281c46dfb8faabe4c653487bdbded5c' # core     icons-128x128
  '3422355b84833bb71ab495e5b994844fd8e3bd9361d7e335f218c40b2ed75f7e' # extra    xml
  '1aff115a28e62fbd1f978dab398dd532643fd1bea4ee0f90e2031e052e232978' # extra    icons-48x48
  '8bf13d29b7d89f61e6945f836655f95e007d9ea649b18393363d37f5f65d4ab2' # extra    icons-64x64
  '6a75765dcbb0986a9996b79ed2aca88600196e121b85b0f46623189f24396f07' # extra    icons-128x128
  '26fc66ee7c0649d4c710b87e8a83f7ace3ff3a5d9c10b9d2160580f6d414f282' # multilib xml
  '32cd219eae6e0035f53245c9b785493db9387f9f5ae94e2a75ca4778ca978551' # multilib icons-48x48
  '971cf619e46dfe6ec11d80a13277163f28fc34339301e348b88e1af696db914a' # multilib icons-64x64
  'ef07fc8ace613ef56052003a7850a5b2bb948dd28a6f601d595530bfc863dfb3' # multilib icons-128x128
)
