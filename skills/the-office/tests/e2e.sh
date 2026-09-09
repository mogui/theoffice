#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok/bad only tally; A && ok || bad is intentional here.
# e2e.sh - verify the determinism contract of the scaffold on a synthetic repo.
# Usage: tests/e2e.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export OFFICE_SKIP_ORCA=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

# --- synthetic repo ----------------------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO"/{src,tests}
git -C "$REPO" init -q
git -C "$REPO" config user.email office@example.com
git -C "$REPO" config user.name Office
for skill in implement tdd; do
  mkdir -p "$REPO/.claude/skills/$skill"
  printf -- '---\nname: %s\ndescription: fake %s for tests\n---\n' "$skill" "$skill" \
    > "$REPO/.claude/skills/$skill/SKILL.md"
done

write_config() {
  cat > "$REPO/office.config.json" <<CFG
{
  "schema_version": 3,
  "office": "widget",
  "mandate": "Keep the widget library working; done means a green suite.",
  "cadence": "on-demand",
  "backlog": "board",
  "commands": { "install": "npm ci", "build": null, "test": "npm test", "lint": null },
  "coordinator": { "writes": ["OFFICE.md", "OFFICE-LOG.md", "BACKLOG.md", "package.json"] },
  "roles": [
    {
      "id": "role-src",
      "name": "Sam",
      "title": "Library Engineer",
      "persona": "Library implementer",
      "mandate": "Implement widget behaviour.",
      "reads": ["tests/"],
      "writes": ["src/"],
      "skills": ["implement", "tdd"],
      "review": { "mode": "auto", "with": ["implement"] },
      "done": "The behaviour works and the suite is green.",
      "agent": "claude",
      "model": null
    },
    {
      "id": "role-tests",
      "name": "Tess",
      "title": "Test Engineer",
      "persona": "Test author",
      "mandate": "Cover widget behaviour with tests.",
      "reads": ["src/"],
      "writes": ["tests/"],
      "skills": ["tdd"],
      "review": { "mode": "human", "with": ["tdd"] },
      "commands": { "test": "npm test -- tests" },
      "done": "Every public behaviour has a test.",
      "agent": "claude",
      "model": null
    }
  ]
}
CFG
}
write_config

# --- 1. preflight accepts a valid office -------------------------------------

if "$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1; then
  ok "preflight accepts a valid config"
else
  bad "preflight rejected a valid config"
  "$ROOT/scripts/preflight.sh" "$REPO" || true
fi

# --- 2. scaffold produces the expected tree ----------------------------------

"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
for f in \
  OFFICE.md \
  OFFICE-LOG.md \
  OFFICE-INBOX.md \
  CLAUDE.md \
  BACKLOG.md \
  .claude/skills/role-src/SKILL.md \
  .claude/skills/role-tests/SKILL.md \
  .office/scripts/scaffold.sh \
  .office/scripts/preflight.sh \
  .office/scripts/check-writes.sh \
  .office/scripts/automation.sh \
  .office/scripts/pending-merges.sh \
  .office/scripts/integrate.sh \
  .office/templates/role.SKILL.md.tmpl \
  .gitignore
do
  [ -f "$REPO/$f" ] && ok "generated $f" || bad "missing $f"
done

unrendered=$(grep -rl '{{' "$REPO/OFFICE.md" "$REPO/.claude/skills/role-src/SKILL.md" "$REPO/.claude/skills/role-tests/SKILL.md" 2>/dev/null || true)
[ -z "$unrendered" ] \
  && ok "no unrendered placeholders in the generated files" \
  || bad "unrendered placeholders in: $unrendered"

grep -qE '^\.orca/?$' "$REPO/.gitignore" \
  && ok ".gitignore ignores .orca/" || bad ".gitignore does not ignore .orca/"

# --- 3. never_writes is derived, not authored --------------------------------

grep -qF '`tests/`' "$REPO/.claude/skills/role-src/SKILL.md" \
  && grep -A20 '## Never write' "$REPO/.claude/skills/role-src/SKILL.md" | grep -qF 'package.json' \
  && ok "never_writes unions the other Role and the Coordinator" \
  || bad "never_writes is wrong for role-src"
grep -qF 'never_writes' "$REPO/office.config.json" \
  && bad "never_writes leaked into the config" \
  || ok "never_writes absent from the config"

# --- 4. idempotence: a second run changes nothing ----------------------------

snapshot() {
  (cd "$REPO" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum) 
}
before="$(snapshot)"
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
after="$(snapshot)"
check "$([ "$before" = "$after" ] && echo same || echo different)" "same" "second scaffold run is byte-identical"

# --- 5. keep blocks and board files survive regeneration ---------------------

python3 - "$REPO/.claude/skills/role-src/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("<!-- office:keep -->\n\n", "<!-- office:keep -->\nHAND WRITTEN NOTE\n")
open(p, "w").write(s)
PY
printf 'a human wrote this\n' >> "$REPO/OFFICE-LOG.md"
printf '## 2026-01-31 09:00 - a human asked for something\nStatus: new\n' >> "$REPO/OFFICE-INBOX.md"
printf -- '- [ ] BL-001 (role-src) first item\n' >> "$REPO/BACKLOG.md"
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
grep -qF 'HAND WRITTEN NOTE' "$REPO/.claude/skills/role-src/SKILL.md" \
  && ok "keep block carried over" || bad "keep block lost"
grep -qF 'a human wrote this' "$REPO/OFFICE-LOG.md" \
  && ok "OFFICE-LOG.md never overwritten" || bad "OFFICE-LOG.md was overwritten"
grep -qF 'BL-001' "$REPO/BACKLOG.md" \
  && ok "BACKLOG.md never overwritten" || bad "BACKLOG.md was overwritten"
grep -qF 'a human asked for something' "$REPO/OFFICE-INBOX.md" \
  && ok "OFFICE-INBOX.md never overwritten" || bad "OFFICE-INBOX.md was overwritten"
check "$(grep -cF 'office:claude-md' "$REPO/CLAUDE.md")" "1" "CLAUDE.md pointer appended exactly once"
grep -qF 'OFFICE-INBOX.md' "$REPO/.claude/skills/role-src/SKILL.md" \
  && ok "the inbox lands in a Role's never-writes without being authored" \
  || bad "the inbox is missing from role-src's never-writes"

# --- 5b. no Role may own the inbox -------------------------------------------

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["roles"][0]["writes"].append("OFFICE-INBOX.md")
json.dump(c, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a Role owning OFFICE-INBOX.md" \
  || ok "preflight refuses a Role owning OFFICE-INBOX.md"
write_config
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null

# --- 6. removing a Role deletes its skill ------------------------------------

python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"] = [r for r in cfg["roles"] if r["id"] != "role-tests"]
cfg["coordinator"]["writes"].append("tests/")
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/scaffold.sh" "$REPO" 2>/dev/null >/dev/null
[ -d "$REPO/.claude/skills/role-tests" ] \
  && bad "removed Role's skill still present" \
  || ok "removed Role's skill deleted"

# --- 7. overlapping write sets are refused ----------------------------------

write_config
python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][1]["writes"] = ["src/"]
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted overlapping write sets" \
  || ok "preflight refuses overlapping write sets"

# --- 8. a nested path counts as an overlap ----------------------------------

python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][1]["writes"] = ["src/widget/inner/"]
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a nested write path" \
  || ok "preflight refuses a nested write path"

# --- 9. a declared skill that is not installed is refused -------------------

write_config
python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][0]["skills"] = ["implement", "not-installed"]
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a missing skill" \
  || ok "preflight refuses a declared skill that is not installed"

# --- 10. backlog: tracker requires a configured tracker ---------------------

write_config
python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["backlog"] = "tracker"
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted backlog=tracker with no tracker config" \
  || ok "preflight refuses backlog=tracker without docs/agents/issue-tracker.md"

# --- 10b. tracker_skills gates the tracker write path ----------------------

mkdir -p "$REPO/docs/agents"; printf 'local files under .scratch/\n' > "$REPO/docs/agents/issue-tracker.md"
write_config
python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["backlog"] = "tracker"
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && ok "preflight skips the tracker-writer check when tracker_skills is absent" \
  || bad "preflight refused a tracker office with no tracker_skills"

python3 - "$REPO/office.config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["tracker_skills"] = ["tdd"]   # both roles declare it
json.dump(cfg, open(p, "w"), indent=2)
PY
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted two Roles holding a tracker-writing skill" \
  || ok "preflight refuses two Roles holding a skill listed in tracker_skills"

rm -rf "$REPO/docs"

# --- 11. check-writes gates a delivery -------------------------------------

write_config
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm "office"
git -C "$REPO" checkout -qb worker/role-src
printf 'ok\n' > "$REPO/src/widget.js"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "inside write set"
"$ROOT/scripts/check-writes.sh" role-src "$REPO" main "$REPO" >/dev/null 2>&1 \
  && ok "check-writes accepts a committed delivery inside the write set" \
  || bad "check-writes rejected a valid committed delivery"
printf 'nope\n' > "$REPO/tests/sneaky.js"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "outside write set"
"$ROOT/scripts/check-writes.sh" role-src "$REPO" main "$REPO" >/dev/null 2>&1 \
  && bad "check-writes accepted a committed write outside the write set" \
  || ok "check-writes rejects a committed write outside the write set"

# --- 12. uncommitted work is gated too --------------------------------------
# A Worker that reports without committing is the common case; a gate that only
# diffs the branch passes it blindly.

git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb worker/role-src-dirty
mkdir -p "$REPO/tests"
printf 'sneaky\n' > "$REPO/tests/uncommitted.js"
"$ROOT/scripts/check-writes.sh" role-src "$REPO" main "$REPO" >/dev/null 2>&1 \
  && bad "check-writes missed an uncommitted write outside the write set" \
  || ok "check-writes rejects an uncommitted write outside the write set"
rm -f "$REPO/tests/uncommitted.js"
mkdir -p "$REPO/src"
printf 'fine\n' > "$REPO/src/inside.js"
"$ROOT/scripts/check-writes.sh" role-src "$REPO" main "$REPO" >/dev/null 2>&1 \
  && ok "check-writes accepts an uncommitted write inside the write set" \
  || bad "check-writes rejected a valid uncommitted delivery"
rm -f "$REPO/src/inside.js"

# --- 13. a delivery that changed nothing is not a failure -------------------

"$ROOT/scripts/check-writes.sh" role-src "$REPO" main "$REPO" >/dev/null 2>&1 \
  && ok "check-writes passes a review-only delivery with no changes" \
  || bad "check-writes failed a no-change delivery"

# --- 14. pending-merges gates the cycle on a stale base ---------------------

git -C "$REPO" checkout -q main
write_config
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm "office for merge tests" >/dev/null 2>&1 || true
"$ROOT/scripts/pending-merges.sh" "$REPO" >/dev/null 2>&1 \
  && ok "pending-merges passes a clean base" \
  || bad "pending-merges blocked a clean base"

# An empty role branch is not a delivery: nothing was committed on it.
git -C "$REPO" branch role-src-empty
"$ROOT/scripts/pending-merges.sh" "$REPO" >/dev/null 2>&1 \
  && ok "pending-merges ignores a role branch with no commits" \
  || bad "pending-merges counted an empty branch as a delivery"

git -C "$REPO" checkout -qb role-src-bl001
mkdir -p "$REPO/src"; printf 'delivered\n' > "$REPO/src/a.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "delivery"
git -C "$REPO" checkout -q main
"$ROOT/scripts/pending-merges.sh" "$REPO" >/dev/null 2>&1 \
  && bad "pending-merges let a cycle dispatch onto a stale base" \
  || ok "pending-merges refuses to dispatch while a delivery is unmerged"

# --- 15. integrate.sh lands a delivery without touching the default branch --

"$ROOT/scripts/integrate.sh" role-src role-src-bl001 "$REPO" >/dev/null 2>&1 \
  && bad "integrate.sh ran for an office with no integration_branch_prefix" \
  || ok "integrate.sh refuses an office that declares no integration_branch_prefix"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["integration_branch_prefix"] = "integration/"
json.dump(cfg, open(p, "w"), indent=2)
PY2
main_before=$(git -C "$REPO" rev-parse main)
"$ROOT/scripts/integrate.sh" role-src role-src-bl001 "$REPO" >/dev/null 2>&1 \
  && ok "integrate.sh lands a gate-passed delivery" \
  || bad "integrate.sh refused a valid delivery"
check "$(git -C "$REPO" rev-parse main)" "$main_before" "integrate.sh leaves the default branch untouched"
git -C "$REPO" rev-parse --verify --quiet integration/src >/dev/null \
  && ok "integrate.sh created the Role's own integration branch" \
  || bad "integration branch integration/src missing"
git -C "$REPO" rev-parse --verify --quiet integration/tests >/dev/null \
  && bad "integrate.sh created a branch for a Role that delivered nothing" \
  || ok "integrate.sh touches only the delivering Role's branch"
"$ROOT/scripts/pending-merges.sh" "$REPO" >/dev/null 2>&1 \
  && ok "pending-merges clears once the delivery landed" \
  || bad "pending-merges still blocked after integration"

# A delivery that writes outside the write set must not reach the integration branch.
git -C "$REPO" checkout -q -b role-src-bad main
mkdir -p "$REPO/tests"; printf 'nope\n' > "$REPO/tests/stolen.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "outside write set"
git -C "$REPO" checkout -q main
int_before=$(git -C "$REPO" rev-parse integration/src)
"$ROOT/scripts/integrate.sh" role-src role-src-bad "$REPO" >/dev/null 2>&1 \
  && bad "integrate.sh landed a delivery that broke the write set" \
  || ok "integrate.sh refuses a delivery that broke the write set"
check "$(git -C "$REPO" rev-parse integration/src)" "$int_before" "a rejected delivery leaves the integration branch untouched"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["integration_branch_prefix"] = cfg.get("default_branch", "main") + "/"
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a prefix equal to the default branch" \
  || ok "preflight refuses an integration prefix equal to the default branch"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["integration_branch_prefix"] = "integration"
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a prefix that is not a branch prefix" \
  || ok "preflight refuses an integration prefix that does not end in /"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][1]["name"] = cfg["roles"][0]["name"]
cfg.pop("integration_branch_prefix", None)
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted two Roles sharing a name" \
  || ok "preflight refuses two Roles with the same name"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["schema_version"] = 1
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted schema_version 1" \
  || ok "preflight refuses a schema 1 config"

# --- 15b. review authority is per Role, and must resolve ---------------------

write_config
python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
del cfg["roles"][0]["review"]
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a Role with no review block" \
  || ok "preflight refuses a Role that declares no review authority"

write_config
python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][0]["review"]["mode"] = "sometimes"
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted an unknown review.mode" \
  || ok "preflight refuses a review.mode that is neither auto nor human"

write_config
python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][0]["review"]["with"] = ["no-such-reviewer-anywhere"]
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a reviewer that is neither a skill nor on PATH" \
  || ok "preflight refuses an unresolvable review.with entry"

write_config
python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["merge_authority"] = "human"
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a leftover merge_authority field" \
  || ok "preflight refuses merge_authority, which schema 3 replaced with per-Role review"

# --- 15c. gate.sh and merge-integration.sh -----------------------------------
# The two halves of closing an `auto` integration: the deterministic gate, and the merge
# that only ever runs on a basis the caller states out loud.

write_config
python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["integration_branch_prefix"] = "integration/"
cfg["commands"] = {"install": None, "build": "true", "test": "true", "lint": None}
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
git -C "$REPO" add -A >/dev/null && git -C "$REPO" commit -qm "gate fixture"
git -C "$REPO" branch -f integration/src main >/dev/null

"$ROOT/scripts/gate.sh" role-src "$REPO" >/dev/null 2>&1 \
  && ok "gate.sh passes a branch whose commands succeed" \
  || bad "gate.sh failed a branch whose commands all succeed"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["commands"]["test"] = "false"
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/gate.sh" role-src "$REPO" >/dev/null 2>&1 \
  && bad "gate.sh passed a branch whose test command fails" \
  || ok "gate.sh fails a branch whose test command fails"

# The Role's own command wins over the office's for the same key.
python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["roles"][0]["commands"] = {"test": "true"}
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/gate.sh" role-src "$REPO" >/dev/null 2>&1 \
  && ok "gate.sh lets a Role's own command override the office's" \
  || bad "gate.sh ignored the Role's own command override"

"$ROOT/scripts/merge-integration.sh" role-src "$REPO" >/dev/null 2>&1 \
  && bad "merge-integration.sh merged without being told the basis" \
  || ok "merge-integration.sh refuses to merge without a stated basis"

git -C "$REPO" checkout -q integration/src
mkdir -p "$REPO/src"
printf 'gated\n' > "$REPO/src/gated.txt"
git -C "$REPO" add -A >/dev/null && git -C "$REPO" commit -qm "role-src: a delivery"
git -C "$REPO" checkout -q main
"$ROOT/scripts/merge-integration.sh" role-src "gate + code-review approve" "$REPO" >/dev/null 2>&1 \
  && ok "merge-integration.sh lands the integration branch on the default branch" \
  || bad "merge-integration.sh did not merge an approved branch"
git -C "$REPO" log -1 --format=%s main | grep -q "gate + code-review approve" \
  && ok "merge-integration.sh records the basis in the merge message" \
  || bad "merge-integration.sh lost the basis"

out="$("$ROOT/scripts/review-integration.sh" role-src "$REPO" 2>&1 || true)"
printf '%s' "$out" | grep -q "reviewed automatically" \
  && ok "review-integration.sh refuses a Role that is reviewed automatically" \
  || bad "review-integration.sh opened a human review for an auto Role"

# --- 16. automation.sh refuses to guess -------------------------------------
# The create/edit path needs a live Orca runtime and is exercised by the dry run;
# what is testable offline is that the script never invents a schedule or a provider.

write_config
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
out="$("$ROOT/scripts/automation.sh" "$REPO" 2>&1)" && rc=0 || rc=$?
check "$rc" "0" "automation.sh exits 0 for an on-demand office"
printf '%s' "$out" | grep -q "nothing to schedule" \
  && ok "automation.sh schedules nothing for an on-demand office" \
  || bad "automation.sh did not explain the on-demand case"

python3 - "$REPO/office.config.json" <<'PY2'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["cadence"] = "hourly"
json.dump(cfg, open(p, "w"), indent=2)
PY2
"$ROOT/scripts/preflight.sh" "$REPO" >/dev/null 2>&1 \
  && bad "preflight accepted a scheduled office with no coordinator.agent" \
  || ok "preflight requires coordinator.agent once the office is scheduled"

rm -f "$REPO/OFFICE.md"
"$ROOT/scripts/automation.sh" "$REPO" >/dev/null 2>&1 \
  && bad "automation.sh ran against an unscaffolded office" \
  || ok "automation.sh refuses to run before scaffold.sh"

# --- report ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
