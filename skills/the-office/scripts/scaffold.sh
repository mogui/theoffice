#!/usr/bin/env bash
# scaffold.sh - render an office from office.config.json.
# Usage: scaffold.sh [repo-root]
#
# Pure and idempotent: the generated tree is a function of office.config.json alone.
# The only carried-over state is each file's keep block. OFFICE-LOG.md and BACKLOG.md
# are created when absent and never overwritten.
set -euo pipefail

REPO="${1:-$PWD}"
CONFIG="$REPO/office.config.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TEMPLATES="$ROOT/templates"

fail() { printf 'scaffold: %s\n' "$1" >&2; exit 1; }
warn() { printf 'scaffold: warning: %s\n' "$1" >&2; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
[ -d "$TEMPLATES" ] || fail "templates not found at $TEMPLATES"

"$HERE/preflight.sh" "$REPO" >/dev/null || fail "preflight failed; run it directly to see why"

KEEP_OPEN='<!-- office:keep -->'
KEEP_CLOSE='<!-- /office:keep -->'

# Everything between the keep markers of an existing file, or empty.
keep_block() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  # "open"/"close" are awk built-ins; the variables must not shadow them.
  awk -v marker_open="$KEEP_OPEN" -v marker_close="$KEEP_CLOSE" '
    $0 == marker_open { inside = 1; next }
    $0 == marker_close { inside = 0; next }
    inside { print }
  ' "$file"
}

# render <template> <vars-json> -> stdout
render() {
  jq -rn --rawfile tmpl "$1" --argjson vars "$2" '
    reduce ($vars | to_entries[]) as $e
      ($tmpl; gsub("\\{\\{" + $e.key + "\\}\\}"; $e.value))
  '
}

# Write only when the content differs, so an unchanged run touches no mtimes.
write_if_changed() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    printf '  unchanged  %s\n' "${path#"$REPO"/}"
  else
    mkdir -p "$(dirname "$path")"
    mv "$tmp" "$path"
    printf '  written    %s\n' "${path#"$REPO"/}"
  fi
}

OFFICE=$(jq -r '.office' "$CONFIG")
BACKLOG=$(jq -r '.backlog' "$CONFIG")

case "$BACKLOG" in
  tracker)
    BACKLOG_SECTION='The backlog is the issue tracker declared in `docs/agents/issue-tracker.md`. This office keeps no board file of its own. An item nobody can resolve is parked with the `needs-info` triage label.'
    AMBIGUITY_SINK='Report the ambiguity as a Finding and stop. The Coordinator parks the item on the tracker with the `needs-info` label. Ambiguity that is local and reversible you may resolve yourself, recording the choice in your report.'
    ;;
  board)
    BACKLOG_SECTION='The backlog is `BACKLOG.md`, one item per line as `- [ ] BL-007 (role-api) title`, optionally tagged `blocked:question` or `blocked:dep`. Only the Coordinator writes it. No script parses it.'
    AMBIGUITY_SINK='Report the ambiguity as a Finding and stop. The Coordinator parks the backlog item with the `blocked:question` tag. Ambiguity that is local and reversible you may resolve yourself, recording the choice in your report.'
    ;;
esac

INTEGRATION=$(jq -r '.integration_branch // empty' "$CONFIG")
DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")

if [ -n "$INTEGRATION" ]; then
  WORKER_BASE_FLAG=" --base-branch $INTEGRATION"
else
  WORKER_BASE_FLAG=" --base-branch $DEFAULT_BRANCH"
fi

if [ -n "$INTEGRATION" ]; then
  MERGE_SECTION="Workers branch from \`$INTEGRATION\`, not from \`$DEFAULT_BRANCH\`. A delivery that passes the write-set gate is landed there by the Coordinator with \`.office/scripts/integrate.sh\`, so the next cycle starts from work that already exists instead of re-implementing it.

A human still merges \`$INTEGRATION\` into \`$DEFAULT_BRANCH\`, once per several cycles rather than once per delivery. The Coordinator never touches \`$DEFAULT_BRANCH\`, and a delivery that conflicts with \`$INTEGRATION\` is left untouched for a human: the office does not resolve conflicts.

\`.office/scripts/pending-merges.sh\` refuses to let a cycle dispatch while a delivery has not landed on \`$INTEGRATION\`."
else
  MERGE_SECTION="Workers branch from \`$DEFAULT_BRANCH\`, and every delivery waits for a human merge. \`.office/scripts/pending-merges.sh\` therefore refuses to let a cycle dispatch while any delivery is unmerged: a Worker branching from a stale \`$DEFAULT_BRANCH\` would re-implement work that is already sitting on a branch.

This makes the office's real cadence the cadence at which you merge. To decouple the two, declare an \`integration_branch\` in \`office.config.json\`: the Coordinator then lands gate-passed deliveries there and you merge that one branch when you choose."
fi

echo "office: $OFFICE"

# --- role skills -------------------------------------------------------------

while IFS= read -r id; do
  target="$REPO/.claude/skills/$id/SKILL.md"
  keep="$(keep_block "$target")"

  vars=$(jq -c \
    --arg id "$id" \
    --arg office "$OFFICE" \
    --arg keep "$keep" \
    --arg sink "$AMBIGUITY_SINK" '
    . as $cfg
    | (.roles[] | select(.id == $id)) as $r
    | ((.commands // {}) + ($r.commands // {})) as $cmds
    | ([.roles[] | select(.id != $id) | .writes[]] + .coordinator.writes | sort | unique) as $never
    | {
        ROLE_ID: $id,
        OFFICE: $office,
        ROLE_PERSONA: $r.persona,
        ROLE_MANDATE: $r.mandate,
        ROLE_DESCRIPTION: (
          $r.persona + " for the " + $office + " office. " + $r.mandate
          + " Invoke this skill when a task spec names " + $id + "."
          | tojson
        ),
        ROLE_SKILLS: (
          if ($r.skills | length) == 0
          then "None. This Role is its mandate and its write set."
          else ($r.skills | sort | map("- Invoke `/" + . + "` and follow it on method.") | join("\n"))
          end
        ),
        ROLE_WRITES: ($r.writes | sort | map("- `" + . + "`") | join("\n")),
        ROLE_NEVER_WRITES: ($never | map("- `" + . + "`") | join("\n")),
        ROLE_READS: (
          if ($r.reads | length) == 0
          then "Nothing beyond your own write set."
          else ($r.reads | sort | map("- `" + . + "`") | join("\n"))
          end
        ),
        ROLE_COMMANDS: (
          ($cmds | to_entries | map(select(.value != null)) | sort_by(.key)) as $c
          | if ($c | length) == 0
            then "None declared."
            else ($c | map("- " + .key + ": `" + .value + "`") | join("\n"))
            end
        ),
        ROLE_DONE: $r.done,
        AMBIGUITY_SINK: $sink,
        KEEP: $keep
      }' "$CONFIG")

  render "$TEMPLATES/role.SKILL.md.tmpl" "$vars" | write_if_changed "$target"
done < <(jq -r '.roles[].id' "$CONFIG")

# --- stale role skills -------------------------------------------------------

if [ -d "$REPO/.claude/skills" ]; then
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    id="$(basename "$dir")"
    if jq -e --arg id "$id" 'any(.roles[]; .id == $id)' "$CONFIG" >/dev/null; then
      continue
    fi
    # Only ever delete a file this scaffold generated.
    if grep -qF "$KEEP_OPEN" "$dir/SKILL.md" 2>/dev/null; then
      rm -rf "$dir"
      printf '  removed    %s\n' "${dir#"$REPO"/}"
      warn "role $id was removed; its write paths are now unowned. Reassign them if that code is still maintained."
    else
      warn "$dir looks hand-written, not generated by this office; left alone."
    fi
  done < <(find "$REPO/.claude/skills" -maxdepth 1 -type d -name 'role-*' 2>/dev/null | sort)
fi

# --- OFFICE.md ---------------------------------------------------------------

office_keep="$(keep_block "$REPO/OFFICE.md")"
office_vars=$(jq -c \
  --arg keep "$office_keep" \
  --arg merge_section "$MERGE_SECTION" \
  --arg worker_base_flag "$WORKER_BASE_FLAG" \
  --arg default_branch "$DEFAULT_BRANCH" \
  --arg backlog_section "$BACKLOG_SECTION" '
  {
    OFFICE: .office,
    OFFICE_MANDATE: .mandate,
    CADENCE: .cadence,
    BACKLOG_SECTION: $backlog_section,
    MERGE_SECTION: $merge_section,
    WORKER_BASE_FLAG: $worker_base_flag,
    DEFAULT_BRANCH: $default_branch,
    ROSTER_TABLE: (
      "| Role | Persona | Writes | Skills | Done |\n|---|---|---|---|---|\n"
      + ([.roles[] | "| `" + .id + "` | " + .persona
          + " | " + (.writes | sort | map("`" + . + "`") | join(", "))
          + " | " + (if (.skills | length) == 0 then "-" else (.skills | sort | join(", ")) end)
          + " | " + .done + " |"] | join("\n"))
    ),
    COORDINATOR_WRITES: (.coordinator.writes | sort | map("- `" + . + "`") | join("\n")),
    KEEP: $keep
  }' "$CONFIG")
render "$TEMPLATES/OFFICE.md.tmpl" "$office_vars" | write_if_changed "$REPO/OFFICE.md"

# --- never-overwritten board files -------------------------------------------

if [ ! -f "$REPO/OFFICE-LOG.md" ]; then
  printf '# Office log\n\nThe Coordinator'"'"'s diary: why work was re-dispatched, why a delivery was rejected, what a cycle decided. Architectural decisions belong in `docs/adr/`, not here.\n' \
    > "$REPO/OFFICE-LOG.md"
  printf '  written    OFFICE-LOG.md\n'
else
  printf '  kept       OFFICE-LOG.md\n'
fi

if [ "$BACKLOG" = "board" ]; then
  if [ ! -f "$REPO/BACKLOG.md" ]; then
    printf '# Backlog\n\nOne item per line: `- [ ] BL-001 (role-id) title`. Tag a parked item `blocked:question` or `blocked:dep`. Only the Coordinator writes this file.\n\n' \
      > "$REPO/BACKLOG.md"
    printf '  written    BACKLOG.md\n'
  else
    printf '  kept       BACKLOG.md\n'
  fi
fi

# --- .gitignore --------------------------------------------------------------

# Orca creates Worker worktrees under <repo>/.orca/workspaces/. Untracked, any
# `git add -A` by the Coordinator or a Role stages them as embedded git repos.
if [ ! -f "$REPO/.gitignore" ] || ! grep -qE '^\.orca/?$' "$REPO/.gitignore"; then
  if [ -s "$REPO/.gitignore" ]; then
    printf '\n' >> "$REPO/.gitignore"
  fi
  printf '# Orca worktrees for this office (Worker workspaces).\n.orca/\n' >> "$REPO/.gitignore"
  printf '  appended   .gitignore (.orca/)\n'
else
  printf '  ok         .gitignore already ignores .orca/\n'
fi

# --- bootstrap scripts and templates come with the repo ----------------------

mkdir -p "$REPO/.office/scripts" "$REPO/.office/templates"
for f in "$HERE"/*.sh; do
  install -m 755 "$f" "$REPO/.office/scripts/$(basename "$f")"
done
for f in "$TEMPLATES"/*.tmpl; do
  install -m 644 "$f" "$REPO/.office/templates/$(basename "$f")"
done
printf '  synced     .office/\n'

# --- stage -------------------------------------------------------------------

if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" add -A \
    office.config.json OFFICE.md OFFICE-LOG.md .office .claude/skills .gitignore >/dev/null 2>&1 || true
  if [ "$BACKLOG" = "board" ]; then
    git -C "$REPO" add -A BACKLOG.md >/dev/null 2>&1 || true
  fi
fi

echo "scaffold: ok"
