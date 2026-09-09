#!/usr/bin/env bash
# automation.sh - register (or re-sync) the Coordinator's Orca automation.
# Usage: automation.sh [repo-root]
#
# Always creates the automation DISABLED. Enabling it is a human action: an office
# that dispatches on a schedule with nobody watching is a decision, not a default.
# Re-running syncs the existing automation instead of creating a second one.
set -euo pipefail

REPO="${1:-$PWD}"
CONFIG="$REPO/office.config.json"

fail() { printf 'automation: %s\n' "$1" >&2; exit 1; }

for bin in jq orca; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin is not on PATH"
done
[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
[ -f "$REPO/OFFICE.md" ] || fail "no OFFICE.md at $REPO; run scaffold.sh first"

OFFICE=$(jq -r '.office' "$CONFIG")
CADENCE=$(jq -r '.cadence' "$CONFIG")
BACKLOG=$(jq -r '.backlog' "$CONFIG")
AGENT=$(jq -r '.coordinator.agent // empty' "$CONFIG")
TIME=$(jq -r '.coordinator.time // empty' "$CONFIG")
NAME="office-$OFFICE-coordinator"

if [ "$CADENCE" = "on-demand" ]; then
  cat <<MSG
automation: cadence is 'on-demand', so there is nothing to schedule.
Run the cycle in OFFICE.md by hand from a Coordinator terminal. Set cadence to
hourly or daily and re-run this script to register a scheduled Coordinator.
MSG
  exit 0
fi

[ -n "$AGENT" ] || fail "coordinator.agent is required when cadence is not 'on-demand'"

# The Coordinator is the only actor on the default branch, so it runs in the repo's
# own worktree, not a fresh one per run, and each run is submitted to the standing
# Coordinator session when it is still live instead of opening a new tab per cycle.
PROMPT="Run one work cycle for the $OFFICE office.

First, so the next run can start on a clean context in this same tab, record this
session: printf '%s\\n' \"\$ORCA_TERMINAL_HANDLE\" > .office/.coordinator-terminal

Read OFFICE.md at the repo root and follow it exactly: it is the whole procedure, and this
prompt deliberately does not repeat it. Start at the intake step - consume OFFICE-INBOX.md
into backlog items - then apply the ordering rule, then run the work cycle. You are the
Coordinator.
You are the only actor on the default branch. You never merge, you never edit a path
owned by a Role, and you turn Findings into backlog items rather than fixing them.

Stop after one cycle. A check --wait timeout is a checkpoint, not a failure: repeat
the check rather than closing a Worker that is still working."

ARGS=(
  --name "$NAME"
  --prompt "$PROMPT"
  --provider "$AGENT"
  --workspace "path:$REPO"
  --workspace-mode existing
  --reuse-session
  --disabled
  --trigger "$CADENCE"
)
if [ -n "$TIME" ]; then
  ARGS+=(--time "$TIME")
fi

# The precheck runs while the reused session is still idle, which is the only moment
# it can be cleared. A cycle with an empty board is also a wasted dispatch, so with a
# board backlog the same precheck gates on it: a non-zero exit records a skipped run.
# With a tracker backlog there is no portable query, so only the clear runs.
PRECHECK="bash .office/scripts/reset-session.sh"
if [ "$BACKLOG" = "board" ]; then
  PRECHECK="$PRECHECK && grep -qE '^- \[ \] ' BACKLOG.md"
fi
ARGS+=(--precheck "$PRECHECK")

EXISTING=$(orca automations list --json 2>/dev/null \
  | jq -r --arg n "$NAME" '.result.automations[]? | select(.name == $n) | .id' | head -1)

if [ -n "$EXISTING" ]; then
  printf 'automation: syncing existing automation %s\n' "$EXISTING"
  orca automations edit "$EXISTING" "${ARGS[@]}" --json >/dev/null \
    || fail "could not edit automation $EXISTING"
  ID="$EXISTING"
else
  ID=$(orca automations create "${ARGS[@]}" --json | jq -r '.result.automation.id')
  if [ -z "$ID" ] || [ "$ID" = "null" ]; then
    fail "automation was not created"
  fi
  printf 'automation: created %s\n' "$ID"
fi

cat <<MSG

  name:      $NAME
  trigger:   $CADENCE${TIME:+ at $TIME}
  provider:  $AGENT
  workspace: $REPO (existing)
  state:     DISABLED

Two human actions remain, per machine, and no script can do them for you:

  1. Enable it:  orca automations enable is not a CLI action - use the Orca UI,
     or 'orca automations edit $ID --enabled' once you have watched a cycle.
  2. Trust the repo for your agent CLI. A Worker dispatched into a worktree the
     agent does not trust stalls on the folder-trust dialog and the dispatch fails
     with agent_prompt_stalled. Trust covers nested paths, so trusting $REPO once
     covers the worktrees Orca creates under .orca/workspaces/.

Watch one supervised cycle before enabling. 'orca automations run $ID' runs it now.
MSG
