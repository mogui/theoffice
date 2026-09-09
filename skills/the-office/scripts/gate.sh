#!/usr/bin/env bash
# gate.sh - build and test one Role's integration branch before it is reviewed.
# Usage: gate.sh <role-id> [repo-root]
#
# The deterministic half of closing an integration. A branch that does not build, or whose
# tests fail, is a block:quality on its own evidence: no reviewer is invoked for it, because
# asking a model to simulate a compiler that is already installed is a waste of a review.
#
# Runs in a throwaway worktree, so the Coordinator's own checkout is never disturbed.
#
# Exit 0: the branch builds and its tests pass; it is worth a review.
# Exit 1: it does not. That is a block:quality.
# Exit 2: the request or the repo state is wrong.
set -euo pipefail

ROLE="${1:?usage: gate.sh <role-id> [repo-root]}"
REPO="${2:-$PWD}"
CONFIG="$REPO/office.config.json"

fail() { printf 'gate: %s\n' "$1" >&2; exit 2; }

[ -f "$CONFIG" ] || fail "office.config.json not found at $REPO"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"
jq -e --arg id "$ROLE" 'any(.roles[]; .id == $id)' "$CONFIG" >/dev/null || fail "unknown role '$ROLE'"

PREFIX=$(jq -r '.integration_branch_prefix // empty' "$CONFIG")
[ -n "$PREFIX" ] || fail "this office declares no integration_branch_prefix; there is no integration branch to gate"
INTEGRATION="$PREFIX${ROLE#role-}"

git -C "$REPO" rev-parse --verify --quiet "$INTEGRATION" >/dev/null \
  || { printf 'gate: %s does not exist yet; nothing to gate.\n' "$INTEGRATION"; exit 0; }

# The Role's own command overrides the office's for the same key: Vera runs the domain
# package's tests, which are faster and are the ones her definition of done names.
# bash 3.2 has no mapfile, and macOS ships 3.2: keep the steps in a file, not an array.
STEPS="$(mktemp)"
jq -r --arg id "$ROLE" '
  ((.commands // {}) + ((.roles[] | select(.id == $id) | .commands) // {})) as $c
  | ["install", "build", "lint", "test"]
  | map(select($c[.] != null and $c[.] != "") | . + "\t" + $c[.])
  | .[]' "$CONFIG" > "$STEPS"

if [ ! -s "$STEPS" ]; then
  rm -f "$STEPS"
  printf 'gate: this office declares no commands; nothing to run on %s.\n' "$INTEGRATION"
  exit 0
fi

TMP="$(mktemp -d)"
cleanup() { git -C "$REPO" worktree remove --force "$TMP/wt" >/dev/null 2>&1 || true; rm -rf "$TMP" "$STEPS"; }
trap cleanup EXIT

git -C "$REPO" worktree add --quiet --detach "$TMP/wt" "$INTEGRATION" \
  || fail "could not check out $INTEGRATION"

printf 'gate: %s (%s)\n' "$INTEGRATION" "$(git -C "$TMP/wt" rev-parse --short HEAD)"
while IFS= read -r step; do
  [ -n "$step" ] || continue
  key="${step%%$'\t'*}"; cmd="${step#*$'\t'}"
  printf 'gate: %-8s %s\n' "$key" "$cmd"
  if ! ( cd "$TMP/wt" && eval "$cmd" ); then
    printf 'gate: FAILED at %s on %s. This is a block:quality; do not invoke a reviewer.\n' "$key" "$INTEGRATION" >&2
    exit 1
  fi
done < "$STEPS"

printf 'gate: passed. %s is worth a review.\n' "$INTEGRATION"
