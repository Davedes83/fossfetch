#!/bin/sh
# Install FossFetch's global hotkey into the user's Hyprland config, once.
#
# Usage: sh install_hotkey.sh <hyprConfigDir> <combo>
#
# A plugin with no keyboard shortcut is not a launcher, but every other launcher
# on the desktop is bound to a chord already, and the obvious ones are taken:
# `SUPER + SHIFT + F` is Omarchy's "open files" and `SUPER + ALT + F` its
# "full width". So the binding is installed for the user rather than left in a
# README for them to copy, and it uses a combo nothing else claims.
#
# Deliberately conservative:
#   * Appends only. A user's hyprland.lua is theirs; this never rewrites one.
#   * Idempotent, by marker AND by scanning: a binding the user already has
#     (in bindings.lua, say, or a hand-edited combo of their own) is left
#     alone, so this never fights their configuration.
#   * Refuses to touch anything that is not a regular file, rather than
#     following a symlink or creating a directory somewhere unexpected.
set -eu

DIR="${1:-$HOME/.config/hypr}"
COMBO="${2:-SUPER + CTRL + SHIFT + F}"
FILE="$DIR/hyprland.lua"
MARK="fossfetch:hotkey"

# $COMBO is written into hyprland.lua verbatim, and hyprland.lua is LUA: a combo
# carrying a quote or a bracket closes the string and appends arbitrary code to
# the user's config. A Hyprland combo is only ever modifier/key names joined by
# " + ", so anything outside that alphabet is refused rather than escaped --
# there is no legitimate combo that needs one.
# A bracket range in a case pattern admits a newline as a member of [:space:],
# and a newline is exactly what would smuggle a second line into the config. So
# this trims every character a real combo may contain and requires the remainder
# to be empty; a leftover newline, quote, bracket or semicolon all land here.
if [ -n "$(printf '%s' "$COMBO" | tr -d 'A-Za-z0-9_+ ')" ]; then
  echo "STATUS|bad-combo"
  exit 0
fi
# tr works line by line and command substitution eats trailing newlines, so a
# value that is two valid lines can leave nothing behind to catch. Count them:
# a combo has no line breaks at all.
if [ "$(printf '%s' "$COMBO" | wc -l)" -ne 0 ]; then
  echo "STATUS|bad-combo"
  exit 0
fi
# Not empty, not pure whitespace, and bounded: the longest real combo is a
# handful of modifiers plus a key.
if [ -z "$(printf '%s' "$COMBO" | tr -d ' ')" ] || [ "${#COMBO}" -gt 64 ]; then
  echo "STATUS|bad-combo"
  exit 0
fi

# Something already binds this combo to FossFetch, anywhere in the config dir.
if grep -rqs "omarchy-shell fossfetch toggle" "$DIR" 2>/dev/null; then
  echo "STATUS|already-bound"
  exit 0
fi

if [ ! -d "$DIR" ]; then
  echo "STATUS|no-config-dir"
  exit 0
fi

if [ -e "$FILE" ] && [ ! -f "$FILE" ]; then
  # A symlink to somewhere, or a directory named hyprland.lua.
  echo "STATUS|not-a-regular-file"
  exit 0
fi

if [ ! -f "$FILE" ]; then
  # No hyprland.lua to append to. Omarchy creates one on first run; creating
  # it here would mean guessing the rest of its contents.
  echo "STATUS|no-config-file"
  exit 0
fi

if ! grep -q "$MARK" "$FILE" 2>/dev/null; then
  {
    printf '\n-- %s (added by the FossFetch plugin; safe to delete or change)\n' "$MARK"
    printf 'o.bind("%s", "FossFetch", "omarchy-shell fossfetch toggle")\n' "$COMBO"
  } >> "$FILE" || { echo "STATUS|write-failed"; exit 0; }
  echo "STATUS|installed"
else
  echo "STATUS|already-installed"
fi
