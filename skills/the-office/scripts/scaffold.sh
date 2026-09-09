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
    INBOX_INTAKE='write the tickets on the tracker as `docs/agents/issue-tracker.md` describes: one file per ticket, labelled `ready-for-agent` only when it is completely specified and `needs-info` otherwise. A ticket names the Role that must take it.'
    BACKLOG_ORDER='among the tickets that are `ready-for-agent`, unblocked and unresolved: **one effort at a time** - the ticket group holding the oldest open ticket - and inside it, the lowest ticket number first.'
    ;;
  board)
    BACKLOG_SECTION='The backlog is `BACKLOG.md`, one item per line as `- [ ] BL-007 (role-api) title`, optionally tagged `blocked:question` or `blocked:dep`. Only the Coordinator writes it. No script parses it.'
    AMBIGUITY_SINK='Report the ambiguity as a Finding and stop. The Coordinator parks the backlog item with the `blocked:question` tag. Ambiguity that is local and reversible you may resolve yourself, recording the choice in your report.'
    INBOX_INTAKE='append one `- [ ] BL-NNN (role-id) title` line per unit of work to `BACKLOG.md`, tagged `blocked:question` when it is not fully specified.'
    BACKLOG_ORDER='the topmost unchecked, untagged line of `BACKLOG.md` first: the file order **is** the priority order, so the Coordinator reorders the file rather than picking out of order.'
    ;;
esac

# The inbox is the human input channel: the Coordinator owns it by construction, so it is
# never authored in the config and always lands in every Role's never-writes.
INBOX='OFFICE-INBOX.md'

PREFIX=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")
DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")

# One integration branch per Role, <prefix><role-slug>. A reviewer opens one Role's work
# at a time: an ops delivery and a design delivery are not read in the same frame of mind.
role_branch() {
  if [ -z "$PREFIX" ]; then printf '%s' "$DEFAULT_BRANCH"; else printf '%s%s' "$PREFIX" "${1#role-}"; fi
}
role_mode() { jq -r --arg id "$1" '.roles[] | select(.id == $id) | .review.mode' "$CONFIG"; }
role_branch_note() {
  if [ -z "$PREFIX" ]; then
    printf 'Your branch was cut from `%s`. Every delivery waits for a human merge; nothing lands without one.' "$DEFAULT_BRANCH"
  elif [ "$(role_mode "$1")" = "human" ]; then
    printf 'Your branch was cut from `%s`, your Role'"'"'s own integration branch. The Coordinator lands your delivery there, and a person reviews that branch on its own - only your work, never mixed with another Role'"'"'s.' "$(role_branch "$1")"
  else
    printf 'Your branch was cut from `%s`, your Role'"'"'s own integration branch. The Coordinator lands your delivery there, runs this office'"'"'s build and tests on it, and has a reviewer read it before it reaches `%s`. A branch that does not build never gets read, so leave it green.' "$(role_branch "$1")" "$DEFAULT_BRANCH"
  fi
}

if [ -n "$PREFIX" ]; then
  MERGE_SECTION="Every Role has its **own** integration branch, \`${PREFIX}<role-slug>\`. Its Workers branch from it, not from \`$DEFAULT_BRANCH\`, and a delivery that passes the write-set gate is landed there by the Coordinator with \`.office/scripts/integrate.sh\`, so the next cycle starts from work that already exists instead of re-implementing it.

One branch per Role means one review per Role: $(jq -r '[.roles[] | .name + "\u0027s"] | join(", ")' "$CONFIG" | sed 's/, \([^,]*\)$/ and \1/') work is read separately, each in the frame of mind that work asks for, and never as one mixed diff.

How an integration branch reaches \`$DEFAULT_BRANCH\` is the Role's own business, declared in its Review column and spelled out below. A branch that conflicts is left untouched either way: the office does not resolve conflicts.

\`.office/scripts/pending-merges.sh\` refuses to let a cycle dispatch while a delivery has not landed on its Role's integration branch. It measures a delivery against its integration branch, not that branch against \`$DEFAULT_BRANCH\`, so a branch held back by a review does not stall the next cycle."
else
  MERGE_SECTION="Workers branch from \`$DEFAULT_BRANCH\`, and every delivery waits for a human merge. \`.office/scripts/pending-merges.sh\` therefore refuses to let a cycle dispatch while any delivery is unmerged: a Worker branching from a stale \`$DEFAULT_BRANCH\` would re-implement work that is already sitting on a branch.

This makes the office's real cadence the cadence at which you merge. To decouple the two, declare an \`integration_branch_prefix\` in \`office.config.json\`: each Role then gets its own integration branch, the Coordinator lands gate-passed deliveries there, and you review one Role at a time."
fi

# How each Role's branch is closed. Review authority is per Role, so this section is the
# only place that says what "merged" is allowed to mean, and the Roster column points here.
if [ -n "$PREFIX" ]; then
  REVIEW_SECTION="## Review

Each Role declares how its integration branch is reviewed. The Roster's **Review** column is the whole configuration: there is no office-wide merge authority to fall back on.

**\`human\`** - \`.office/scripts/review-integration.sh <role-id>\` opens a Plannotator session on that one branch. An approval is the merge and the only thing that is; feedback, a closed tab, or no Plannotator on the machine all leave the branch untouched and the merge manual.

**\`auto\`** - the Coordinator closes it in three steps, and skipping one is not allowed:

1. \`.office/scripts/gate.sh <role-id>\` runs this office's install, build, lint and test commands - with the Role's own overrides - on the integration branch, in a throwaway worktree. A non-zero exit **is** a \`block:quality\`, and no reviewer is invoked: asking a model to simulate a compiler that is already installed is a wasted review.
2. The Coordinator invokes a **Claude Code sub-agent** - not an Orca dispatch, so depth is not a problem - on that branch alone, carrying the skills named in that Role's \`review.with\`. It gives it \`spec.md\`, \`CONTEXT.md\`, \`docs/adr/\` and the originating ticket. Without those four inputs a reviewer can only judge quality, never intent.
3. The sub-agent returns exactly one verdict:
   - **\`approve\`** - \`.office/scripts/merge-integration.sh <role-id> \"<basis>\"\` lands it on \`$DEFAULT_BRANCH\`.
   - **\`block:quality\`** - the code is wrong or incomplete. The Coordinator opens a \`ready-for-agent\` ticket for that Role carrying the Findings, and the branch stays where it is. The Role's next Worker starts from that branch and fixes it, because the desk is levelled with the integration branch every cycle.
   - **\`block:decision\`** - the code is correct, but it settles something the spec does not. The Coordinator opens a \`needs-info\` ticket holding the question, and the branch stays.

The test that separates the two blocks, and the only one: **if the answer is derivable from \`spec.md\`, \`CONTEXT.md\` or an existing ADR, proceed; if you would have to invent it, stop.** It is the same test the intake step applies to an inbox entry, applied to a diff instead of a request.

A \`block:quality\` holds nothing up. A \`block:decision\` takes its Role out of the next dispatch until a human answers - the one place this office waits for a person, and the right one."
else
  REVIEW_SECTION="## Review

This office declares no \`integration_branch_prefix\`, so there are no integration branches and nothing for the Coordinator to close: every delivery branch waits for a person to review and merge it. Declare a prefix to give each Role a branch of its own and a Review setting to go with it."
fi

# The dispatch table is what the Coordinator copies from: who a Worker is called, where it
# branches from. Names are the whole point - `Jim (Platform Engineer)` on a Worker row says
# what `role-platform-09` never did.
DISPATCH_TABLE=$(jq -r --arg prefix "$PREFIX" --arg default "$DEFAULT_BRANCH" '
  "| Role skill | Worker display name | `--name` | `--base-branch` |\n|---|---|---|---|\n"
  + ([.roles[]
      | "| `" + .id + "` | " + .name + " (" + .title + ") | `" + (.name | ascii_downcase) + "` | `"
        + (if $prefix == "" then $default else $prefix + (.id | sub("^role-"; "")) end) + "` |"]
     | join("\n"))' "$CONFIG")

echo "office: $OFFICE"

# --- role skills -------------------------------------------------------------

while IFS= read -r id; do
  target="$REPO/.claude/skills/$id/SKILL.md"
  keep="$(keep_block "$target")"

  vars=$(jq -c \
    --arg id "$id" \
    --arg office "$OFFICE" \
    --arg inbox "$INBOX" \
    --arg keep "$keep" \
    --arg sink "$AMBIGUITY_SINK" \
    --arg branch "$(role_branch "$id")" \
    --arg branch_note "$(role_branch_note "$id")" '
    . as $cfg
    | (.roles[] | select(.id == $id)) as $r
    | ((.commands // {}) + ($r.commands // {})) as $cmds
    | ([.roles[] | select(.id != $id) | .writes[]] + .coordinator.writes + [$inbox] | sort | unique) as $never
    | {
        ROLE_ID: $id,
        OFFICE: $office,
        ROLE_NAME: $r.name,
        ROLE_TITLE: $r.title,
        ROLE_DISPLAY: ($r.name + " (" + $r.title + ")"),
        ROLE_BRANCH: $branch,
        ROLE_BRANCH_NOTE: $branch_note,
        ROLE_PERSONA: $r.persona,
        ROLE_MANDATE: $r.mandate,
        ROLE_DESCRIPTION: (
          $r.name + ", " + $r.title + ": " + $r.persona + " for the " + $office + " office. " + $r.mandate
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
  --arg inbox "$INBOX" \
  --arg inbox_intake "$INBOX_INTAKE" \
  --arg backlog_order "$BACKLOG_ORDER" \
  --arg merge_section "$MERGE_SECTION" \
  --arg review_section "$REVIEW_SECTION" \
  --arg dispatch_table "$DISPATCH_TABLE" \
  --arg default_branch "$DEFAULT_BRANCH" \
  --arg backlog_section "$BACKLOG_SECTION" '
  {
    OFFICE: .office,
    OFFICE_MANDATE: .mandate,
    CADENCE: .cadence,
    BACKLOG_SECTION: $backlog_section,
    INBOX_INTAKE: $inbox_intake,
    BACKLOG_ORDER: $backlog_order,
    MERGE_SECTION: $merge_section,
    REVIEW_SECTION: $review_section,
    DISPATCH_TABLE: $dispatch_table,
    DEFAULT_BRANCH: $default_branch,
    ROSTER_TABLE: (
      "| Who | Role | Persona | Writes | Skills | Review | Done |\n|---|---|---|---|---|---|---|\n"
      + ([.roles[] | "| **" + .name + "** (" + .title + ") | `" + .id + "` | " + .persona
          + " | " + (.writes | sort | map("`" + . + "`") | join(", "))
          + " | " + (if (.skills | length) == 0 then "-" else (.skills | sort | join(", ")) end)
          + " | **" + .review.mode + "**: " + (.review.with | join(", "))
          + " | " + .done + " |"] | join("\n"))
    ),
    COORDINATOR_WRITES: (.coordinator.writes + [$inbox] | sort | unique | map("- `" + . + "`") | join("\n")),
    KEEP: $keep
  }' "$CONFIG")
render "$TEMPLATES/OFFICE.md.tmpl" "$office_vars" | write_if_changed "$REPO/OFFICE.md"

# --- never-overwritten board files -------------------------------------------

if [ ! -f "$REPO/$INBOX" ]; then
  render "$TEMPLATES/OFFICE-INBOX.md.tmpl" "$(jq -cn --arg o "$OFFICE" '{OFFICE: $o}')" > "$REPO/$INBOX"
  printf '  written    %s\n' "$INBOX"
else
  printf '  kept       %s\n' "$INBOX"
fi

# Any Claude Code session opened in the repo must learn that the office exists and that
# product work goes to the inbox instead of being implemented on the spot. CLAUDE.md is
# the only file every session reads unprompted, so the pointer lives there, appended once
# and recognised by its marker.
CLAUDE_MARKER='<!-- office:claude-md -->'
if [ ! -f "$REPO/CLAUDE.md" ] || ! grep -qF "$CLAUDE_MARKER" "$REPO/CLAUDE.md"; then
  if [ -s "$REPO/CLAUDE.md" ]; then printf '\n' >> "$REPO/CLAUDE.md"; fi
  cat >> "$REPO/CLAUDE.md" <<CLAUDEMD
$CLAUDE_MARKER
## Office

This repo is worked by an office of agents: \`OFFICE.md\` (the cycle and its rules),
\`office.config.json\` (the only source; everything else is generated), \`OFFICE-LOG.md\`
(the Coordinator's diary). The Roles write the code, each inside its own write set - this
session does not.

When the user asks for product work - a feature, a fix, a deploy, a screen, a piece of
content - **do not implement it**: append an entry to \`$INBOX\` in the format that file
declares, tell the user, and stop. The Coordinator picks it up at the intake step of the
next cycle. Do not write backlog items by hand: the backlog belongs to the Coordinator.

Questions, reading, explanations and reviews stay ordinary work for this session. Editing a
path that \`OFFICE.md\` assigns to a Role is only safe while no delivery is in flight,
because otherwise the next one is born in conflict.
CLAUDEMD
  printf '  appended   CLAUDE.md (office pointer)\n'
else
  printf '  ok         CLAUDE.md already points at the office\n'
fi

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
    office.config.json OFFICE.md OFFICE-LOG.md "$INBOX" CLAUDE.md .office .claude/skills .gitignore >/dev/null 2>&1 || true
  if [ "$BACKLOG" = "board" ]; then
    git -C "$REPO" add -A BACKLOG.md >/dev/null 2>&1 || true
  fi
fi

echo "scaffold: ok"
