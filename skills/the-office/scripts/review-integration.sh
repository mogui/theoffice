#!/usr/bin/env bash
# review-integration.sh - close one Role's integration with a human review.
# Usage: review-integration.sh <role-id> [repo-root]
#
# Only for a Role whose review.mode is "human". Opens that Role's integration branch in a
# Plannotator review session; an approval is the human merge authority exercised through the
# UI, so an approved branch is handed to merge-integration.sh. Anything else - feedback, a
# closed tab, no Plannotator installed - leaves every branch untouched and the merge manual.
#
# A Role whose review.mode is "auto" is closed the other way: gate.sh, then a sub-agent
# review by the Coordinator, then merge-integration.sh on approve.
#
# Exit 0: merged, or nothing to review, or handed back to a human with instructions.
# Exit 1: something is wrong with the request or the repo state.
set -euo pipefail

ROLE="${1:?usage: review-integration.sh <role-id> [repo-root]}"
REPO="${2:-$PWD}"
CONFIG="$REPO/office.config.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf 'review: %s\n' "$1" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
PREFIX=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")
DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")

[ -n "$PREFIX" ] || fail "this office declares no integration_branch_prefix; there is nothing to review here"
jq -e --arg id "$ROLE" 'any(.roles[]; .id == $id)' "$CONFIG" >/dev/null || fail "unknown role '$ROLE'"

DISPLAY=$(jq -r --arg id "$ROLE" '.roles[] | select(.id == $id) | .name + " (" + .title + ")"' "$CONFIG")
MODE=$(jq -r --arg id "$ROLE" '.roles[] | select(.id == $id) | .review.mode // "human"' "$CONFIG")
INTEGRATION="$PREFIX${ROLE#role-}"

[ "$MODE" = "human" ] || fail "$DISPLAY is reviewed automatically (review.mode: $MODE). Close it with gate.sh, a sub-agent review, then merge-integration.sh."

git -C "$REPO" rev-parse --verify --quiet "$INTEGRATION" >/dev/null \
  || { printf 'review: %s does not exist yet; nothing to review.\n' "$INTEGRATION"; exit 0; }

ahead=$(git -C "$REPO" rev-list --count "$DEFAULT_BRANCH..$INTEGRATION")
if [ "$ahead" -eq 0 ]; then
  printf 'review: %s carries nothing that %s does not already have.\n' "$INTEGRATION" "$DEFAULT_BRANCH"
  exit 0
fi

manual() {
  printf 'review: %s - %s is %s commit(s) ahead of %s.\n' "$DISPLAY" "$INTEGRATION" "$ahead" "$DEFAULT_BRANCH"
  printf 'review: %s The merge stays manual: a human reviews %s and merges it into %s.\n' "$1" "$INTEGRATION" "$DEFAULT_BRANCH"
  exit 0
}

command -v plannotator >/dev/null 2>&1 || manual "plannotator is not installed."

TMP="$(mktemp -d)"
cleanup() { git -C "$REPO" worktree remove --force "$TMP/wt" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$REPO" worktree add --quiet "$TMP/wt" "$INTEGRATION" \
  || fail "could not check out $INTEGRATION (is it checked out in another worktree?)"

# Plannotator blocks until the reviewer submits, approves or closes the tab. One session
# per Role is the whole point: the reviewer sees an ops delivery on its own, not mixed in.
printf 'review: opening a Plannotator session on %s for %s\n' "$INTEGRATION" "$DISPLAY" >&2
verdict="$(cd "$TMP/wt" && plannotator review --git)" || fail "plannotator exited nonzero; nothing was merged"

if ! printf '%s' "$verdict" | grep -qi 'approved'; then
  printf 'review: not approved. %s stays as it is; nothing reached %s.\n' "$INTEGRATION" "$DEFAULT_BRANCH"
  printf 'review: reviewer feedback follows.\n'
  printf '%s\n' "${verdict:-(the session was closed without feedback)}"
  exit 0
fi

# An approval is the human merge. The git half, and its three guards, live in one place.
# The worktree this script opened must go first: it holds the branch being merged.
cleanup
trap - EXIT

"$HERE/merge-integration.sh" "$ROLE" "plannotator approval" "$REPO" \
  || fail "approved, but the merge did not go through; see above"
[ -n "$verdict" ] && printf 'review: reviewer notes: %s\n' "$verdict"
exit 0
