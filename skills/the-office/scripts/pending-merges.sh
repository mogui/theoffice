#!/usr/bin/env bash
# pending-merges.sh - report deliveries that have not landed on their Role's base.
# Usage: pending-merges.sh [repo-root]
# Exit 0: every base is current, the cycle may dispatch.
# Exit 1: deliveries are pending. An office cannot go faster than whoever merges.
set -euo pipefail

REPO="${1:-$PWD}"
CONFIG="$REPO/office.config.json"

fail() { printf 'pending-merges: %s\n' "$1" >&2; exit 2; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")
PREFIX=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")

git -C "$REPO" rev-parse --verify --quiet "$DEFAULT_BRANCH" >/dev/null \
  || fail "default branch '$DEFAULT_BRANCH' does not exist"

pending=""
while IFS= read -r role; do
  [ -n "$role" ] || continue
  name=$(jq -r --arg id "$role" '.roles[] | select(.id == $id) | .name' "$CONFIG" | tr '[:upper:]' '[:lower:]')

  # Each Role has its own base: its integration branch when the office declares a prefix
  # and the branch already exists, the default branch otherwise.
  base="$DEFAULT_BRANCH"
  if [ -n "$PREFIX" ]; then
    candidate="$PREFIX${role#role-}"
    if git -C "$REPO" rev-parse --verify --quiet "$candidate" >/dev/null; then
      base="$candidate"
    fi
  fi

  # A Worker's branch is named after its worktree, which the cycle names after the Role's
  # person. Older deliveries carry the role id instead; both still count as pending.
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    [ "$branch" = "$base" ] && continue
    ahead=$(git -C "$REPO" rev-list --count "$base..$branch" 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] || continue
    pending="$pending  $branch ($ahead commit(s) not in $base)"$'\n'
  done < <(git -C "$REPO" for-each-ref --format='%(refname:short)' \
             "refs/heads/$role*" "refs/heads/$name" "refs/heads/$name-*" | sort -u)
done < <(jq -r '.roles[].id' "$CONFIG")

if [ -z "$pending" ]; then
  printf 'pending-merges: none. Every Role base is current; the cycle may dispatch.\n'
  exit 0
fi

printf 'pending-merges: deliveries not landed on their Role base:\n%s' "$pending" >&2
if [ -n "$PREFIX" ]; then
  printf 'Integrate them with .office/scripts/integrate.sh before dispatching again.\n' >&2
else
  printf 'Do not dispatch. A Worker branching from %s would re-implement this work.\n' "$DEFAULT_BRANCH" >&2
  printf 'Merge authority is human: ask for a merge, and report the wait.\n' >&2
fi
exit 1
