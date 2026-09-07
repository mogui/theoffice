#!/usr/bin/env bash
# integrate.sh - land one gate-passed delivery on the office's integration branch.
# Usage: integrate.sh <role-id> <delivery-branch> [repo-root]
#
# Only for an office that declares integration_branch. It never touches the default
# branch: the human still merges the integration branch, once per N cycles instead of
# once per delivery. A conflict is left to a human, not resolved here.
set -euo pipefail

ROLE="${1:?usage: integrate.sh <role-id> <delivery-branch> [repo-root]}"
BRANCH="${2:?usage: integrate.sh <role-id> <delivery-branch> [repo-root]}"
REPO="${3:-$PWD}"
CONFIG="$REPO/office.config.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf 'integrate: %s\n' "$1" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
INTEGRATION=$(jq -r '.integration_branch // empty' "$CONFIG")
DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$CONFIG")

[ -n "$INTEGRATION" ] || fail "this office declares no integration_branch; merge authority is human only"
git -C "$REPO" rev-parse --verify --quiet "$BRANCH" >/dev/null \
  || fail "delivery branch '$BRANCH' does not exist"

if ! git -C "$REPO" rev-parse --verify --quiet "$INTEGRATION" >/dev/null; then
  git -C "$REPO" branch "$INTEGRATION" "$DEFAULT_BRANCH"
  printf 'integrate: created %s from %s\n' "$INTEGRATION" "$DEFAULT_BRANCH"
fi

# The gate runs against the integration branch, not the default branch: that is the
# base this delivery is landing on.
"$HERE/check-writes.sh" "$ROLE" "$BRANCH" "$INTEGRATION" "$REPO" \
  || fail "write-set gate rejected $BRANCH; nothing was merged"

# Merge in a throwaway worktree so the Coordinator's own checkout is never disturbed.
TMP="$(mktemp -d)"
cleanup() { git -C "$REPO" worktree remove --force "$TMP/wt" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$REPO" worktree add --quiet "$TMP/wt" "$INTEGRATION" \
  || fail "could not check out $INTEGRATION (is it checked out in another worktree?)"

if git -C "$TMP/wt" merge --no-ff --no-edit -m "office: integrate $BRANCH ($ROLE)" "$BRANCH" >/dev/null 2>&1; then
  head=$(git -C "$TMP/wt" rev-parse --short HEAD)
  printf 'integrate: %s landed on %s (%s)\n' "$BRANCH" "$INTEGRATION" "$head"
else
  git -C "$TMP/wt" merge --abort >/dev/null 2>&1 || true
  fail "$BRANCH conflicts with $INTEGRATION. Left untouched: a human resolves this, not the office."
fi
