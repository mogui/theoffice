#!/usr/bin/env bash
# preflight.sh - validate the environment and office.config.json before scaffolding.
# Usage: preflight.sh [repo-root]
# Exit 0: scaffolding may proceed. Non-zero: a diagnostic on stderr says why.
set -euo pipefail

REPO="${1:-$PWD}"
CONFIG="$REPO/office.config.json"

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

# Plannotator is optional: with it, the Coordinator closes an integration with a human
# review session; without it, the review and the merge stay manual.
if command -v plannotator >/dev/null 2>&1; then
  note "plannotator: $(plannotator --version 2>/dev/null || echo present) - integration review is automated"
else
  note "plannotator: not installed - integration review and merge stay manual"
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
case "$schema" in
  3) ;;
  2) fail "schema_version 2 office: review authority moved from the office to the Role. Drop 'merge_authority', give every role a 'review' block - {\"mode\": \"auto\"|\"human\", \"with\": [\"code-review\"]} - and set schema_version to 3." ;;
  1) fail "schema_version 1 office: per-role integration branches and role names are schema 2. Give every role a 'name' and a 'title', replace 'integration_branch' with 'integration_branch_prefix' (e.g. \"integration/\"), and set schema_version to 2, then migrate to 3." ;;
  *) fail "unsupported schema_version: '${schema:-missing}' (expected 3)" ;;
esac

# There is no office-wide merge authority in schema 3: each Role declares its own review.
jq -e 'has("merge_authority")' "$CONFIG" >/dev/null \
  && fail "merge_authority is gone in schema 3. Review authority is per Role: drop the field and give every role a 'review' block."

for field in office mandate cadence backlog; do
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
# Every Role gets its own integration branch: <prefix><role-slug>, where the slug is the
# role id without its `role-` prefix. One branch per Role means one review per Role, and a
# reviewer opens a design delivery in a different frame of mind than an ops one.
prefix=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")
if [ -n "$prefix" ]; then
  printf '%s' "$prefix" | grep -Eq '^[a-z0-9][a-z0-9._/-]*/$' \
    || fail "integration_branch_prefix must be a lowercase branch prefix ending in '/' (got '$prefix')"
  case "$default_branch/" in
    "$prefix") fail "integration_branch_prefix must not be the default branch ('$default_branch'): the office would hold merge authority" ;;
  esac
fi

# --- roles -------------------------------------------------------------------

while IFS= read -r id; do
  case "$id" in
    role-*) ;;
    *) fail "role id must match ^role-[a-z0-9-]+$ (got '$id')" ;;
  esac
  printf '%s' "$id" | grep -Eq '^role-[a-z0-9-]+$' || fail "role id must match ^role-[a-z0-9-]+$ (got '$id')"
  for field in name title persona mandate reads writes skills 'done' agent review; do
    jq -e --arg id "$id" --arg f "$field" \
      '.roles[] | select(.id == $id) | has($f) and (.[$f] != null)' "$CONFIG" >/dev/null \
      || fail "role $id is missing required field: $field"
  done
  jq -e --arg id "$id" '.roles[] | select(.id == $id) | .writes | length >= 1' "$CONFIG" >/dev/null \
    || fail "role $id has an empty write set"
  # The name is what a human sees on a Worker row and what the worktree is called, so it
  # has to survive being a branch segment and being told apart from every other Role.
  name=$(jq -r --arg id "$id" '.roles[] | select(.id == $id) | .name' "$CONFIG")
  printf '%s' "$name" | grep -Eq '^[A-Z][a-zA-Z]{1,15}$' \
    || fail "role $id: name must be one capitalised word, 2-16 letters (got '$name')"

  # Review authority is per Role: 'human' means a person approves that branch, 'auto' means
  # the Coordinator gates it, has a sub-agent review it, and merges on approve.
  mode=$(jq -r --arg id "$id" '.roles[] | select(.id == $id) | .review.mode // empty' "$CONFIG")
  case "$mode" in
    auto|human) ;;
    *) fail "role $id: review.mode must be 'auto' or 'human' (got '${mode:-missing}')" ;;
  esac
  jq -e --arg id "$id" '.roles[] | select(.id == $id) | (.review.with | type == "array") and (.review.with | length >= 1)' "$CONFIG" >/dev/null \
    || fail "role $id: review.with must be a non-empty array naming who reviews (a skill, or a tool on PATH)"
done < <(jq -r '.roles[].id' "$CONFIG")

dupe_names=$(jq -r '.roles[].name' "$CONFIG" | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
[ -z "$dupe_names" ] || fail "two Roles share a name ($dupe_names): names are worktree names, they must be unique"

# The inbox is the human input channel and the Coordinator consumes it. A Role owning it
# could rewrite what a human asked for, which is the one thing the channel must not allow.
if jq -e 'any(.roles[]; any(.writes[]; . == "OFFICE-INBOX.md"))' "$CONFIG" >/dev/null; then
  fail "no Role may write OFFICE-INBOX.md: the inbox is the Coordinator's intake, and the scaffold adds it to every Role's never-writes"
fi

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

# --- review authority ---------------------------------------------------------

# Each Role names who reviews it in `review.with`. An entry resolves either to an installed
# skill or to a tool on PATH; one name for one question, so the two never drift apart.
# A name that resolves to neither is a hard failure here rather than a silent degrade:
# degrading to 'human' stops the office waiting for a review nobody was told to do, and
# degrading to 'auto' merges into the default branch with less scrutiny than was declared.
echo "review authority"
unresolved=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  mode=$(jq -r --arg id "$id" '.roles[] | select(.id == $id) | .review.mode' "$CONFIG")
  with=$(jq -r --arg id "$id" '.roles[] | select(.id == $id) | .review.with | join(" ")' "$CONFIG")
  unverified=""
  for reviewer in $with; do
    # A Claude Code built-in - /security-review, say - lives inside the agent binary and
    # is on no filesystem, so nothing here can check it. `builtin:` is the caller saying
    # so out loud: the name stays unverified, but it is unverified on the record rather
    # than by accident, which is the whole difference from a silent degrade.
    case "$reviewer" in
      builtin:*) unverified="$unverified ${reviewer#builtin:}"; continue ;;
    esac
    if skill_path "$reviewer" >/dev/null 2>&1; then continue; fi
    command -v "$reviewer" >/dev/null 2>&1 && continue
    unresolved="$unresolved $id:$reviewer"
  done
  note "$id -> $mode: $with"
  [ -z "$unverified" ] || note "  unverified (agent built-in, not checkable from here):$unverified"
done < <(jq -r '.roles[].id' "$CONFIG")
[ -z "$unresolved" ] || fail "review.with names something that is neither an installed skill nor a tool on PATH:$unresolved"

# The tracker is a write path: at most one Role may write to it.
if [ "$backlog" = "tracker" ]; then
  tracker_skills=$(jq -r '.tracker_skills[]? ' "$CONFIG")
  if [ -z "$tracker_skills" ]; then
    note "backlog=tracker, tracker_skills empty: no tracker-writer check"
  else
    writers=""
    for skill in $tracker_skills; do
      while IFS= read -r id; do
        [ -n "$id" ] && writers="$writers$id\n"
      done < <(jq -r --arg s "$skill" '.roles[] | select(.skills[]? == $s) | .id' "$CONFIG")
    done
    count=$(printf '%b' "$writers" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
      fail "more than one Role declares a tracker-writing skill ($(printf '%s' "$tracker_skills" | tr '\n' ' ')): $(printf '%b' "$writers" | sed '/^$/d' | sort -u | tr '\n' ' ')"
    fi
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
