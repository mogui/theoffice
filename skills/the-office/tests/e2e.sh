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
  "schema_version": 1,
  "office": "widget",
  "mandate": "Keep the widget library working; done means a green suite.",
  "cadence": "on-demand",
  "backlog": "board",
  "merge_authority": "human",
  "commands": { "install": "npm ci", "build": null, "test": "npm test", "lint": null },
  "coordinator": { "writes": ["OFFICE.md", "OFFICE-LOG.md", "BACKLOG.md", "package.json"] },
  "roles": [
    {
      "id": "role-src",
      "persona": "Library implementer",
      "mandate": "Implement widget behaviour.",
      "reads": ["tests/"],
      "writes": ["src/"],
      "skills": ["implement", "tdd"],
      "done": "The behaviour works and the suite is green.",
      "agent": "claude",
      "model": null
    },
    {
      "id": "role-tests",
      "persona": "Test author",
      "mandate": "Cover widget behaviour with tests.",
      "reads": ["src/"],
      "writes": ["tests/"],
      "skills": ["tdd"],
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
  BACKLOG.md \
  .claude/skills/role-src/SKILL.md \
  .claude/skills/role-tests/SKILL.md \
  .office/scripts/scaffold.sh \
  .office/scripts/preflight.sh \
  .office/scripts/check-writes.sh \
  .office/templates/role.SKILL.md.tmpl
do
  [ -f "$REPO/$f" ] && ok "generated $f" || bad "missing $f"
done

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
printf -- '- [ ] BL-001 (role-src) first item\n' >> "$REPO/BACKLOG.md"
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
grep -qF 'HAND WRITTEN NOTE' "$REPO/.claude/skills/role-src/SKILL.md" \
  && ok "keep block carried over" || bad "keep block lost"
grep -qF 'a human wrote this' "$REPO/OFFICE-LOG.md" \
  && ok "OFFICE-LOG.md never overwritten" || bad "OFFICE-LOG.md was overwritten"
grep -qF 'BL-001' "$REPO/BACKLOG.md" \
  && ok "BACKLOG.md never overwritten" || bad "BACKLOG.md was overwritten"

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

# --- 11. check-writes gates a delivery --------------------------------------

write_config
"$ROOT/scripts/scaffold.sh" "$REPO" >/dev/null
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm "office"
git -C "$REPO" checkout -qb worker/role-src
printf 'ok\n' > "$REPO/src/widget.js"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "inside write set"
"$ROOT/scripts/check-writes.sh" role-src worker/role-src main "$REPO" >/dev/null 2>&1 \
  && ok "check-writes accepts a delivery inside the write set" \
  || bad "check-writes rejected a valid delivery"
printf 'nope\n' > "$REPO/tests/sneaky.js"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "outside write set"
"$ROOT/scripts/check-writes.sh" role-src worker/role-src main "$REPO" >/dev/null 2>&1 \
  && bad "check-writes accepted a write outside the write set" \
  || ok "check-writes rejects a write outside the write set"

# --- report ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
