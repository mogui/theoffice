#!/usr/bin/env bash
# pending-merges.sh - report deliveries that have not landed on the cycle's base.
# Usage: pending-merges.sh [repo-root]
# Exit 0: the base is current, the cycle may dispatch.
# Exit 1: deliveries are pending. An office cannot go faster than whoever merges.
set -euo pipefail

REPO="${1:-$PWD}"
CONFIG="$REPO/office.config.json"

fail() { printf 'pending-merges: %s\n' "$1" >&2; exit 2; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")
INTEGRATION=$(jq -r '.integration_branch // empty' "$CONFIG")

# Workers branch from the integration branch when there is one; that is the whole
# point of having one. Without it they branch from the default branch, and every
# unmerged delivery makes the next cycle start from a staler base.
BASE="${INTEGRATION:-$DEFAULT_BRANCH}"

git -C "$REPO" rev-parse --verify --quiet "$BASE" >/dev/null \
  || fail "base branch '$BASE' does not exist"

pending=""
while IFS= read -r role; do
  [ -n "$role" ] || continue
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    ahead=$(git -C "$REPO" rev-list --count "$BASE..$branch" 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] || continue
    pending="$pending  $branch ($ahead commit(s) not in $BASE)"$'\n'
  done < <(git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/$role*")
done < <(jq -r '.roles[].id' "$CONFIG")

if [ -z "$pending" ]; then
  printf 'pending-merges: none. %s is current; the cycle may dispatch.\n' "$BASE"
  exit 0
fi

printf 'pending-merges: deliveries not landed on %s:\n%s' "$BASE" "$pending" >&2
if [ -n "$INTEGRATION" ]; then
  printf 'Integrate them with .office/scripts/integrate.sh before dispatching again.\n' >&2
else
  printf 'Do not dispatch. A Worker branching from %s would re-implement this work.\n' "$BASE" >&2
  printf 'Merge authority is human: ask for a merge, and report the wait.\n' >&2
fi
exit 1
