#!/usr/bin/env bash
# preflight.sh - validate the environment and office.config.json before scaffolding.
# Usage: preflight.sh [repo-root]
# Exit 0: scaffolding may proceed. Non-zero: a diagnostic on stderr says why.
set -euo pipefail

REPO="${1:-$PWD}"
CONFIG="$REPO/office.config.json"
TRACKER_SKILLS="to-tickets to-spec triage"

fail() { printf 'preflight: %s\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }

# --- environment -------------------------------------------------------------

for bin in git jq; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin is not on PATH"
done
# OFFICE_SKIP_ORCA=1 skips every Orca probe. It exists for the test suite, which must
# run on a machine with no Orca runtime; never set it when installing a real office.
if [ "${OFFICE_SKIP_ORCA:-0}" != "1" ]; then
  command -v orca >/dev/null 2>&1 || fail "orca is not on PATH"
fi

[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || fail "$REPO is not a git worktree root"

echo "environment"
note "repo: $REPO"
if [ "${OFFICE_SKIP_ORCA:-0}" = "1" ]; then
  note "orca: probes skipped (OFFICE_SKIP_ORCA=1)"
else
  note "orca: $(orca --version 2>/dev/null || echo unknown)"
  # Orchestration is an experimental feature toggled by hand in Settings > Experimental.
  # There is no field for it in `orca status`; run-list is the cheapest read-only probe.
  if ! orca orchestration run-list --json >/dev/null 2>&1; then
    fail "orca orchestration is not reachable. Enable it in Settings > Experimental, then re-run."
  fi
  note "orchestration: reachable"
fi

# --- installed skill inventory ----------------------------------------------

skill_path() {
  local name="$1"
  if [ -f "$REPO/.claude/skills/$name/SKILL.md" ]; then
    echo "$REPO/.claude/skills/$name/SKILL.md"
  elif [ -f "$HOME/.claude/skills/$name/SKILL.md" ]; then
    echo "$HOME/.claude/skills/$name/SKILL.md"
  else
    return 1
  fi
}

echo "installed skills"
INVENTORY=""
for dir in "$REPO/.claude/skills" "$HOME/.claude/skills"; do
  [ -d "$dir" ] || continue
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    INVENTORY="$INVENTORY $(basename "$(dirname "$skill_md")")"
  # -L follows symlinks: a skill directory symlinked into .claude/skills is a
  # normal install pattern, and without it the skill is invisible here.
  done < <(find -L "$dir" -maxdepth 2 -name SKILL.md 2>/dev/null | sort)
done
if [ -z "$INVENTORY" ]; then
  note "none found. Roles will carry no composed skills."
else
  note "$(echo "$INVENTORY" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
fi

# --- config ------------------------------------------------------------------

if [ ! -f "$CONFIG" ]; then
  echo "office: not installed - this run is an install"
  exit 0
fi

# An office is installed once OFFICE.md exists; a config with no OFFICE.md is a
# first scaffold, which is what step 4 of the flow looks like from here.
if [ -f "$REPO/OFFICE.md" ]; then
  echo "office: installed - this run is an update"
else
  echo "office: config written, not yet scaffolded"
fi
jq -e . "$CONFIG" >/dev/null 2>&1 || fail "office.config.json is not valid JSON"

schema=$(jq -r '.schema_version // empty' "$CONFIG")
[ "$schema" = "1" ] || fail "unsupported schema_version: '${schema:-missing}' (expected 1)"

for field in office mandate cadence backlog merge_authority; do
  jq -e --arg f "$field" 'has($f) and (.[$f] != null)' "$CONFIG" >/dev/null \
    || fail "missing required field: $field"
done

cadence=$(jq -r '.cadence' "$CONFIG")
case "$cadence" in
  on-demand|hourly|daily) ;;
  *) fail "cadence must be on-demand, hourly or daily (got '$cadence')" ;;
esac

backlog=$(jq -r '.backlog' "$CONFIG")
case "$backlog" in
  tracker|board) ;;
  *) fail "backlog must be tracker or board (got '$backlog')" ;;
esac

authority=$(jq -r '.merge_authority' "$CONFIG")
[ "$authority" = "human" ] || fail "schema 1 supports merge_authority 'human' only (got '$authority')"

if [ "$backlog" = "tracker" ] && [ ! -f "$REPO/docs/agents/issue-tracker.md" ]; then
  fail "backlog is 'tracker' but docs/agents/issue-tracker.md is missing. Configure a tracker, or set backlog to 'board'."
fi

jq -e '(.roles | type == "array") and (.roles | length >= 1) and (.roles | length <= 5)' "$CONFIG" >/dev/null \
  || fail "roles must be an array of 1 to 5 entries"

jq -e '.coordinator.writes | type == "array" and length >= 1' "$CONFIG" >/dev/null \
  || fail "coordinator.writes must be a non-empty array"

# A scheduled Coordinator is launched by an Orca automation, which needs a provider.
# An on-demand office has no automation, so it needs no agent.
if [ "$cadence" != "on-demand" ]; then
  jq -e '.coordinator.agent // empty | length > 0' "$CONFIG" >/dev/null \
    || fail "coordinator.agent is required when cadence is not 'on-demand'"
fi

default_branch=$(jq -r '.default_branch // "main"' "$CONFIG")
integration=$(jq -r '.integration_branch // empty' "$CONFIG")
if [ -n "$integration" ] && [ "$integration" = "$default_branch" ]; then
  fail "integration_branch must not be the default branch ('$default_branch'): the office would hold merge authority"
fi

# --- roles -------------------------------------------------------------------

while IFS= read -r id; do
  case "$id" in
    role-*) ;;
    *) fail "role id must match ^role-[a-z0-9-]+$ (got '$id')" ;;
  esac
  printf '%s' "$id" | grep -Eq '^role-[a-z0-9-]+$' || fail "role id must match ^role-[a-z0-9-]+$ (got '$id')"
  for field in persona mandate reads writes skills 'done' agent; do
    jq -e --arg id "$id" --arg f "$field" \
      '.roles[] | select(.id == $id) | has($f) and (.[$f] != null)' "$CONFIG" >/dev/null \
      || fail "role $id is missing required field: $field"
  done
  jq -e --arg id "$id" '.roles[] | select(.id == $id) | .writes | length >= 1' "$CONFIG" >/dev/null \
    || fail "role $id has an empty write set"
done < <(jq -r '.roles[].id' "$CONFIG")

dupes=$(jq -r '.roles[].id' "$CONFIG" | sort | uniq -d)
[ -z "$dupes" ] || fail "duplicate role ids: $dupes"

# --- declared skills exist ---------------------------------------------------

echo "declared skills"
missing=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  id="${entry%% *}"
  skill="${entry#* }"
  if path=$(skill_path "$skill"); then
    note "$id -> $skill ($path)"
  else
    missing="$missing $id:$skill"
  fi
done < <(jq -r '.roles[] | .id as $i | .skills[]? | "\($i) \(.)"' "$CONFIG")
[ -z "$missing" ] || fail "declared skills not installed:$missing"

# The tracker is a write path: at most one Role may write to it.
if [ "$backlog" = "tracker" ]; then
  writers=""
  for skill in $TRACKER_SKILLS; do
    while IFS= read -r id; do
      [ -n "$id" ] && writers="$writers$id\n"
    done < <(jq -r --arg s "$skill" '.roles[] | select(.skills[]? == $s) | .id' "$CONFIG")
  done
  count=$(printf '%b' "$writers" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
  if [ "$count" -gt 1 ]; then
    fail "more than one Role declares a tracker-writing skill ($TRACKER_SKILLS): $(printf '%b' "$writers" | sed '/^$/d' | sort -u | tr '\n' ' ')"
  fi
fi

# --- one writer per path -----------------------------------------------------

# A write path is a directory prefix (trailing /) or an exact file path.
# Two paths conflict when they are equal, or one is a directory prefix of the other.
owners=$(jq -r '
  (.coordinator.writes[] | "coordinator\t" + .),
  (.roles[] | .id as $i | .writes[] | $i + "\t" + .)
' "$CONFIG" | sort)

conflict=0
while IFS= read -r a; do
  owner_a="${a%%$'\t'*}"; path_a="${a#*$'\t'}"
  while IFS= read -r b; do
    owner_b="${b%%$'\t'*}"; path_b="${b#*$'\t'}"
    [ "$owner_a" \< "$owner_b" ] || continue
    if [ "$path_a" = "$path_b" ] \
      || { [ "${path_a%/}" != "$path_a" ] && [ "${path_b#"$path_a"}" != "$path_b" ]; } \
      || { [ "${path_b%/}" != "$path_b" ] && [ "${path_a#"$path_b"}" != "$path_a" ]; }; then
      printf 'preflight: write set conflict: %s owns %s, %s owns %s\n' \
        "$owner_a" "$path_a" "$owner_b" "$path_b" >&2
      conflict=1
    fi
  done <<< "$owners"
done <<< "$owners"

[ "$conflict" -eq 0 ] || fail "write sets must not overlap. Exactly one Role writes any given path."

echo "write sets: no conflicts"
echo "preflight: ok"
