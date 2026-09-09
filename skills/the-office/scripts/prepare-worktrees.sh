#!/usr/bin/env bash
# prepare-worktrees.sh - one durable worktree per Role, ready for this cycle's dispatch.
# Usage: prepare-worktrees.sh [repo-root]
#
# A Role is a person, and a person has one desk. The worktree, its branch and its Orca
# display name are all named after that person and are reused for every dispatch, so the
# app shows `Jim (Platform Engineer)` once instead of a new `role-platform-09` per cycle.
#
# Per Role, idempotent:
#   integration branch <prefix><role-slug>   created from the default branch when missing
#   worktree + branch <person>               created from the integration branch when missing,
#                                            otherwise fast-forwarded onto it
#
# Nothing is ever reset or discarded: a dirty worktree, or one holding a delivery that has
# not landed yet, is reported and left exactly as it is.
set -euo pipefail

# Orca selectors are absolute: `path:.` resolves to nothing.
REPO="$(cd "${1:-$PWD}" && pwd)"
CONFIG="$REPO/office.config.json"

fail() { printf 'prepare: %s\n' "$1" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
PREFIX=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")
DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")

git -C "$REPO" rev-parse --verify --quiet "$DEFAULT_BRANCH" >/dev/null \
  || fail "default branch '$DEFAULT_BRANCH' does not exist"

# OFFICE_SKIP_ORCA=1 keeps the git half runnable on a machine with no Orca runtime.
HAS_ORCA=1
if [ "${OFFICE_SKIP_ORCA:-0}" = "1" ] || ! command -v orca >/dev/null 2>&1; then
  HAS_ORCA=0
fi

# Every orca call reads </dev/null: this loop's stdin is the role list, and a CLI that
# touches stdin would eat it.
worktree_path_for_branch() {
  orca worktree list --json </dev/null 2>/dev/null \
    | jq -r --arg b "refs/heads/$1" '.result.worktrees[] | select(.branch == $b) | .path' \
    | head -1
}

while IFS= read -r role; do
  [ -n "$role" ] || continue
  person=$(jq -r --arg id "$role" '.roles[] | select(.id == $id) | .name' "$CONFIG")
  display=$(jq -r --arg id "$role" '.roles[] | select(.id == $id) | .name + " (" + .title + ")"' "$CONFIG")
  branch=$(printf '%s' "$person" | tr '[:upper:]' '[:lower:]')

  base="$DEFAULT_BRANCH"
  if [ -n "$PREFIX" ]; then
    base="$PREFIX${role#role-}"
    git -C "$REPO" rev-parse --verify --quiet "$base" >/dev/null \
      || { git -C "$REPO" branch "$base" "$DEFAULT_BRANCH"; printf '  created  %s (from %s)\n' "$base" "$DEFAULT_BRANCH"; }
  fi

  if [ "$HAS_ORCA" -eq 0 ]; then
    git -C "$REPO" rev-parse --verify --quiet "$branch" >/dev/null \
      || { git -C "$REPO" branch "$branch" "$base"; printf '  created  %s (from %s)\n' "$branch" "$base"; }
    printf '  git-only %s -> %s (no Orca runtime; the worktree is not managed here)\n' "$display" "$branch"
    continue
  fi

  wt="$(worktree_path_for_branch "$branch")"
  if [ -z "$wt" ]; then
    orca worktree create --name "$branch" --repo "path:$REPO" --base-branch "$base" --setup run --json </dev/null >/dev/null \
      || fail "could not create the worktree for $display"
    wt="$(worktree_path_for_branch "$branch")"
    [ -n "$wt" ] || fail "created the worktree for $display but cannot find it by branch '$branch'"
    orca worktree set --worktree "path:$wt" --display-name "$display" --json </dev/null >/dev/null
    printf '  created  %s at %s\n' "$display" "$wt"
    continue
  fi

  # The label is what the app shows; keep it on the person even if something renamed it.
  current_label="$(orca worktree list --json </dev/null | jq -r --arg p "$wt" '.result.worktrees[] | select(.path == $p) | .displayName')"
  if [ "$current_label" != "$display" ]; then
    orca worktree set --worktree "path:$wt" --display-name "$display" --json </dev/null >/dev/null
    printf '  renamed  %s (was %s)\n' "$display" "$current_label"
  fi

  # The desk already exists. Bring it level with the Role's integration branch when that
  # is free of charge, and say why when it is not.
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    printf '  dirty    %s has uncommitted work; left untouched\n' "$display"
  elif [ "$(git -C "$REPO" rev-list --count "$base..$branch")" -gt 0 ]; then
    printf '  pending  %s holds a delivery not yet landed on %s; left untouched\n' "$display" "$base"
  elif [ "$(git -C "$REPO" rev-list --count "$branch..$base")" -gt 0 ]; then
    git -C "$wt" merge --ff-only "$base" >/dev/null \
      || fail "$display could not fast-forward $branch onto $base"
    printf '  updated  %s fast-forwarded onto %s\n' "$display" "$base"
  else
    printf '  ok       %s\n' "$display"
  fi
done < <(jq -r '.roles[].id' "$CONFIG")
