#!/bin/sh
# Restart the Omarchy shell, and make sure it actually comes back.
#
# Usage: sh restart_shell.sh
#
# Run this via `systemd-run --user`, never directly from the shell process.
#
# Why a wrapper at all: `omarchy restart shell` kills the shell first and then
# relaunches it with `hyprctl dispatch`, which needs the Hyprland session
# environment (HYPRLAND_INSTANCE_SIGNATURE). A child of Quickshell does not
# have it, so the relaunch silently did nothing and the session was left with
# no bar, no dock and no shell at all. Running under the user manager gives it
# the same environment the session itself has.
#
# Why the retry: this is triggered by a package update, unattended, with
# nothing watching. If the relaunch fails for any reason -- a crash on the
# way up, a stale lock -- the user is left looking at a bare compositor with
# no way back except logging in elsewhere. So this polls for the shell to
# answer, and restarts again if it does not. A restart that visibly flashes
# the desktop twice is a far better outcome than a desktop that never comes
# back.
set -u

wait_for_shell() {
  # Returns 0 as soon as the shell answers a ping.
  i=0
  while [ "$i" -lt 30 ]; do
    if OMARCHY_SHELL_IPC_TIMEOUT=0.5s omarchy-shell shell ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

attempt=1
while [ "$attempt" -le 3 ]; do
  omarchy restart shell >/dev/null 2>&1 || true

  # 15s of polling per attempt: a cold shell with every plugin loading is slow,
  # and giving up early is what strands the session.
  if wait_for_shell; then
    echo "STATUS|ok|attempt=$attempt"
    exit 0
  fi
  echo "STATUS|retry|attempt=$attempt"
  attempt=$((attempt + 1))
done

echo "STATUS|failed"
exit 1