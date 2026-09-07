#!/usr/bin/env bash
# check-writes.sh - reject a delivery that touched paths outside the Role's write set.
# Usage: check-writes.sh <role-id> <worktree-path|ref> [base-ref] [repo-root]
#
# Given a worktree, looks at both what the Worker committed on its branch and what it
# left uncommitted there: a Worker that never commits is the common case, and a gate
# that only diffs the branch passes everything. Given a ref instead, checks the
# committed diff alone - which is all a landed delivery has.
# Exit 0: every changed path is inside the write set. Exit 1: it is not.
set -euo pipefail

ROLE="${1:?usage: check-writes.sh <role-id> <worktree-path|ref> [base-ref] [repo-root]}"
TARGET="${2:?usage: check-writes.sh <role-id> <worktree-path|ref> [base-ref] [repo-root]}"
BASE="${3:-main}"
REPO="${4:-$PWD}"
CONFIG="$REPO/office.config.json"

fail() { printf 'check-writes: %s\n' "$1" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
jq -e --arg id "$ROLE" 'any(.roles[]; .id == $id)' "$CONFIG" >/dev/null \
  || fail "unknown role: $ROLE"

# mapfile is bash 4+; macOS ships bash 3.2, so read the write set the portable way.
WRITES=()
while IFS= read -r w; do
  [ -n "$w" ] && WRITES+=("$w")
done < <(jq -r --arg id "$ROLE" '.roles[] | select(.id == $id) | .writes[]' "$CONFIG")

if [ -d "$TARGET" ]; then
  committed=$(git -C "$TARGET" diff --name-only "$BASE...HEAD" 2>/dev/null || true)
  # --porcelain columns 1-2 are status, 3 is a space; renames appear as "old -> new".
  uncommitted=$(git -C "$TARGET" status --porcelain 2>/dev/null \
    | cut -c4- | sed 's/.* -> //' || true)
elif git -C "$REPO" rev-parse --verify --quiet "$TARGET" >/dev/null; then
  committed=$(git -C "$REPO" diff --name-only "$BASE...$TARGET" 2>/dev/null || true)
  uncommitted=""
else
  fail "not a worktree and not a ref: $TARGET"
fi

changed=$(printf '%s\n%s\n' "$committed" "$uncommitted" | sed '/^$/d' | sort -u)

if [ -z "$changed" ]; then
  printf 'check-writes: %s changed nothing. Fine for a review-only task; suspicious otherwise.\n' "$ROLE"
  exit 0
fi

violations=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  allowed=0
  for w in "${WRITES[@]}"; do
    if [ "$path" = "$w" ]; then allowed=1; break; fi
    # A directory prefix ends in / and matches anything beneath it.
    if [ "${w%/}" != "$w" ] && [ "${path#"$w"}" != "$path" ]; then allowed=1; break; fi
  done
  [ "$allowed" -eq 1 ] || violations="$violations  $path"$'\n'
done <<< "$changed"

if [ -n "$violations" ]; then
  printf 'check-writes: %s wrote outside its write set:\n%s' "$ROLE" "$violations" >&2
  printf 'Reject the delivery and re-dispatch the fix to the Role that owns those paths.\n' >&2
  exit 1
fi

printf 'check-writes: %s stayed inside its write set (%s changed paths)\n' \
  "$ROLE" "$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"
