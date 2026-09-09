#!/usr/bin/env bash
# reset-session.sh - clear the reused Coordinator session before a scheduled run.
#
# The automation keeps one Orca tab (--reuse-session) instead of opening a new one
# per cycle, so its context would otherwise pile up across cycles. This sends /clear
# to that session while it is still idle, just before the run's prompt is submitted.
# The handle is written by the Coordinator itself at the start of every cycle.
#
# It never fails a run: a session that cannot be cleared is worse than a dirty one
# only if it also skips the cycle, so every path exits 0.
set -uo pipefail

FILE="${1:-.office/.coordinator-terminal}"
[ -f "$FILE" ] || exit 0

HANDLE=$(tr -d '[:space:]' < "$FILE")
[ -n "$HANDLE" ] || exit 0
command -v orca >/dev/null 2>&1 || exit 0

orca terminal send --terminal "$HANDLE" --text "/clear" --enter --json >/dev/null 2>&1 || true
exit 0
