#!/bin/bash
# Shared catalog build-state markers, sourced by appstream_icons.sh and
# appstream_groups.sh. (Keep this dependency-free — it must not source
# anything else, so both scripts can use it without an import cycle.)
#
# Why these exist: the panel reaches `ensure` from the SEARCH path, so without
# them a stale catalog puts a ~10-20 MB download between the user and their
# results, and an offline machine re-attempts that download on every keystroke.
#
#   .building  touched before a build starts, removed when it finishes.
#              Keeps a second build from racing the first (the panel warms in
#              the background while the user is already typing).
#   .failed    holds the consecutive-failure count, removed on success.
#              Retry window grows exponentially from
#              FOSSFETCH_CATALOG_BACKOFF_SECONDS (60) up to
#              FOSSFETCH_CATALOG_BACKOFF_MAX_SECONDS (21600), so a brief outage
#              costs one minute of staleness while a long one is not retried on
#              every keystroke.

CATALOG_BACKOFF_BASE_SECONDS="${FOSSFETCH_CATALOG_BACKOFF_SECONDS:-60}"
CATALOG_BACKOFF_MAX_SECONDS="${FOSSFETCH_CATALOG_BACKOFF_MAX_SECONDS:-21600}"
# A build that has not touched .building in this long is presumed dead.
CATALOG_BUILD_STALE_SECONDS="${FOSSFETCH_CATALOG_BUILD_STALE_SECONDS:-900}"

# True when $1 exists and is younger than $2 seconds.
catalog_marker_fresh() {
  [ -f "$1" ] || return 1
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  [ $(( $(date +%s) - m )) -lt "$2" ]
}

catalog_mark_building() {
  : > "$1" 2>/dev/null || true
}

catalog_clear_building() {
  rm -f "$1" 2>/dev/null || true
}

# Consecutive failures recorded in the marker (0 when absent or malformed).
catalog_failure_count() {
  local n
  n=$(cat "$1" 2>/dev/null) || n=0
  case "$n" in
    ''|*[!0-9]*) n=0 ;;
  esac
  [ "$n" -gt 0 ] || n=0
  printf '%s\n' "$n"
}

catalog_mark_failed() {
  local n
  n=$(( $(catalog_failure_count "$1") + 1 ))
  printf '%s\n' "$n" > "$1" 2>/dev/null || true
}

catalog_clear_failed() {
  rm -f "$1" 2>/dev/null || true
}

# Retry window in seconds for the current failure count: base * 2^(n-1),
# clamped to the maximum. Zero when there is no recorded failure.
catalog_backoff_window() {
  local n w
  n=$(catalog_failure_count "$1")
  [ "$n" -gt 0 ] || { echo 0; return 0; }
  w=$CATALOG_BACKOFF_BASE_SECONDS
  n=$((n - 1))
  while [ "$n" -gt 0 ] && [ "$w" -lt "$CATALOG_BACKOFF_MAX_SECONDS" ]; do
    w=$((w * 2))
    n=$((n - 1))
  done
  [ "$w" -gt "$CATALOG_BACKOFF_MAX_SECONDS" ] && w=$CATALOG_BACKOFF_MAX_SECONDS
  printf '%s\n' "$w"
}

# True while the caller should skip an *automatic* rebuild because a recent one
# failed. An explicit, user-initiated rebuild may still force past this.
catalog_backoff_active() {
  local marker="$1" window
  [ -f "$marker" ] || return 1
  window=$(catalog_backoff_window "$marker")
  [ "$window" -gt 0 ] || return 1
  catalog_marker_fresh "$marker" "$window"
}