#!/bin/bash
# Autonomous Executor — Lock Manager
# Usage: ./executor.sh [start|status|stop|force|health]
#
# This script manages the lock file that prevents overlapping
# autonomous executor sessions.

set -e

PROJECT="${EXECUTOR_PROJECT:-poem-of-the-day}"
LOCK_FILE="${EXECUTOR_LOCK_FILE:-/Users/jonathan/.openclaw/workspace/reports/${PROJECT}-gsd.lock}"
LOG_FILE="${EXECUTOR_LOG_FILE:-/Users/jonathan/.openclaw/workspace/reports/${PROJECT}-gsd-executor.log}"
LOCK_TIMEOUT="${EXECUTOR_LOCK_TIMEOUT:-600}"  # seconds; 600=10min (recommended), 1800=30min

NOW=$(date +%s)
mkdir -p "$(dirname "$LOCK_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

get_lock_age() {
  stat -f%Sm -t%s "$LOCK_FILE" 2>/dev/null || echo "0"
}

acquire_lock() {
  local age
  age=$(get_lock_age)
  local age_diff=$((NOW - age))

  if [ "$age_diff" -lt "$LOCK_TIMEOUT" ]; then
    log "Lock ACTIVE (age=${age_diff}s, timeout=${LOCK_TIMEOUT}s) — skipping"
    echo "SKIP: executor still active (lock age: ${age_diff}s)"
    return 1
  fi

  echo "$NOW" > "$LOCK_FILE"
  log "Lock ACQUIRED"
  echo "OK: lock acquired"
  return 0
}

release_lock() {
  if [ -f "$LOCK_FILE" ]; then
    rm -f "$LOCK_FILE"
    log "Lock RELEASED"
    echo "OK: lock released"
  else
    echo "WARN: no lock file to release"
  fi
}

cmd_status() {
  local age
  age=$(get_lock_age)
  local age_diff=$((NOW - age))

  echo "Lock file: $LOCK_FILE"
  echo "Lock age:  ${age_diff}s"
  echo "Timeout:   ${LOCK_TIMEOUT}s"

  if [ "$age_diff" -lt "$LOCK_TIMEOUT" ]; then
    echo "Status:    ACTIVE — executor is running"
    return 0
  else
    echo "Status:    STALE — safe to run"
    return 1
  fi
}

cmd_health() {
  local port="${HEALTH_PORT:-3000}"
  local url="http://localhost:${port}/health"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

  echo "Health check: $url"
  echo "HTTP code:    $http_code"

  if [ "$http_code" = "200" ]; then
    echo "Status:       HEALTHY"
    return 0
  else
    echo "Status:       DOWN — restart recommended"
    return 1
  fi
}

case "${1:-status}" in
  start)
    acquire_lock
    ;;
  stop)
    release_lock
    ;;
  force)
    echo "$NOW" > "$LOCK_FILE"
    log "Lock FORCE UPDATED to $NOW"
    echo "OK: lock forced to now"
    ;;
  status)
    cmd_status
    ;;
  health)
    cmd_health
    ;;
  *)
    echo "Usage: $0 {start|stop|status|force|health}"
    echo "  start   — acquire lock if stale, exit if active"
    echo "  stop    — remove lock file"
    echo "  force   — force-lock regardless of age"
    echo "  status  — show lock age and status"
    echo "  health  — check backend health endpoint"
    exit 1
    ;;
esac
