#!/usr/bin/env bash
# check-writes.sh - reject a delivery that touched paths outside the Role's write set.
# Usage: check-writes.sh <role-id> <ref> [base-ref] [repo-root]
# Exit 0: every changed path is inside the write set. Exit 1: it is not, and the
# offending paths are listed. The fix is re-dispatched to the Role that owns them.
set -euo pipefail

ROLE="${1:?usage: check-writes.sh <role-id> <ref> [base-ref] [repo-root]}"
REF="${2:?usage: check-writes.sh <role-id> <ref> [base-ref] [repo-root]}"
BASE="${3:-HEAD}"
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

changed=$(git -C "$REPO" diff --name-only "$BASE...$REF") \
  || fail "cannot diff $BASE...$REF"

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
  "$ROLE" "$(printf '%s' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"
