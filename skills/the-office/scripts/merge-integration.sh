#!/usr/bin/env bash
# merge-integration.sh - land one Role's integration branch on the default branch.
# Usage: merge-integration.sh <role-id> <basis> [repo-root]
#
# The git half of closing an integration, and nothing else: it does not decide, it records.
# <basis> is why this merge is allowed - "plannotator approval" for a Role reviewed by a
# human, "gate + code-review approve" for one reviewed automatically. It is required, and it
# goes in the merge message, so the log always says what authorised the merge.
#
# Never call this without the basis actually being true. The three guards below protect the
# repo, not the decision: the decision is the caller's.
#
# Exit 0: merged, or there was nothing to merge.
# Exit 1: the request or the repo state is wrong, or the branch conflicts.
set -euo pipefail

ROLE="${1:?usage: merge-integration.sh <role-id> <basis> [repo-root]}"
BASIS="${2:?usage: merge-integration.sh <role-id> <basis> [repo-root] - say what authorised this merge}"
REPO="${3:-$PWD}"
CONFIG="$REPO/office.config.json"

fail() { printf 'merge: %s\n' "$1" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
PREFIX=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")
DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")

[ -n "$PREFIX" ] || fail "this office declares no integration_branch_prefix; there is nothing to merge here"
jq -e --arg id "$ROLE" 'any(.roles[]; .id == $id)' "$CONFIG" >/dev/null || fail "unknown role '$ROLE'"

DISPLAY=$(jq -r --arg id "$ROLE" '.roles[] | select(.id == $id) | .name + " (" + .title + ")"' "$CONFIG")
INTEGRATION="$PREFIX${ROLE#role-}"

git -C "$REPO" rev-parse --verify --quiet "$INTEGRATION" >/dev/null \
  || { printf 'merge: %s does not exist yet; nothing to merge.\n' "$INTEGRATION"; exit 0; }

ahead=$(git -C "$REPO" rev-list --count "$DEFAULT_BRANCH..$INTEGRATION")
if [ "$ahead" -eq 0 ]; then
  printf 'merge: %s carries nothing that %s does not already have.\n' "$INTEGRATION" "$DEFAULT_BRANCH"
  exit 0
fi

# Only the Coordinator's own checkout can carry this merge: the default branch cannot be
# checked out twice, and a dirty tree would mix someone else's work into the merge commit.
head_ref=$(git -C "$REPO" symbolic-ref --quiet --short HEAD || echo "")
[ "$head_ref" = "$DEFAULT_BRANCH" ] \
  || fail "this checkout is on '$head_ref', not '$DEFAULT_BRANCH'; merge $INTEGRATION by hand"
[ -z "$(git -C "$REPO" status --porcelain)" ] \
  || fail "the working tree is dirty; merge $INTEGRATION by hand"

if git -C "$REPO" merge --no-ff --no-edit \
     -m "office: $DISPLAY - merge $INTEGRATION ($BASIS)" "$INTEGRATION" >/dev/null 2>&1; then
  printf 'merge: %s -> %s (%s) on %s\n' \
    "$INTEGRATION" "$DEFAULT_BRANCH" "$(git -C "$REPO" rev-parse --short HEAD)" "$BASIS"
else
  git -C "$REPO" merge --abort >/dev/null 2>&1 || true
  fail "$INTEGRATION conflicts with $DEFAULT_BRANCH. A human resolves this, not the office."
fi
