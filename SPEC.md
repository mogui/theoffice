# `the-office` - specification

A generator skill that installs an **office** on a target repo: one Coordinator plus 3-5 specialised Roles that work a backlog continuously through Orca orchestration.

Vocabulary is defined in [CONTEXT.md](./CONTEXT.md). Decisions are recorded in [docs/adr/](./docs/adr/). This spec says what gets built; it does not restate the reasoning behind the decisions.

## 1. Guiding principle

The skill is an **installer, not a runtime**. It runs once (or again to update the roster), writes files into the target repo, and gets out of the way. If a work cycle needs the skill in order to run, the scaffold is wrong: the office's logic has ended up in the skill instead of in `OFFICE.md`.

An office is a repo, not an installation. Everything essential is reproducible from `office.config.json` by the scripts copied into `.office/scripts/`.

## 2. Determinism contract

Per [ADR 0001](./docs/adr/0001-config-is-the-only-scaffold-input.md):

- The **model** authors `office.config.json` and nothing else.
- `scaffold.sh` is a pure, idempotent function from `office.config.json` to generated files.
- Anything a Role needs to know has a **field** in the config. Prose the model improvises is a bug.
- Two exceptions, both explicit: **keep blocks** are carried over verbatim, and `OFFICE-LOG.md` / `BACKLOG.md` are never overwritten once present.

Verified by the idempotence test (§9): a second `scaffold.sh` run must produce a byte-identical tree.

## 3. `office.config.json`

At the repo root.

```json
{
  "schema_version": 1,
  "office": "acme-api",
  "mandate": "Keep the public API documented, tested and typed; done means green suite and no undocumented endpoint.",
  "cadence": "on-demand",
  "backlog": "tracker",
  "merge_authority": "human",
  "commands": {
    "install": "pnpm install",
    "build": "pnpm build",
    "test": "pnpm test",
    "lint": "pnpm lint"
  },
  "coordinator": {
    "writes": ["OFFICE.md", "OFFICE-LOG.md", "package.json", "pnpm-lock.yaml", ".github/"]
  },
  "roles": [
    {
      "id": "role-api",
      "persona": "API implementer",
      "mandate": "Implement and maintain the HTTP layer.",
      "reads": ["src/", "docs/"],
      "writes": ["src/api/"],
      "skills": ["implement", "tdd"],
      "commands": { "test": "pnpm test src/api" },
      "done": "Endpoint implemented, its tests pass, and the suite is green.",
      "agent": "claude",
      "model": null
    }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | Integer. `1` for this spec. |
| `office` | yes | Slug, used in generated titles. |
| `mandate` | yes | One sentence: what the office produces and what done means. |
| `cadence` | yes | `on-demand` \| `hourly` \| `daily`. Drives the automation trigger. |
| `backlog` | yes | `tracker` \| `board`. See §5. |
| `merge_authority` | yes | Always `"human"` in schema 1. Present so a future value is a schema change, not a surprise. |
| `commands` | yes | Office-level `install` / `build` / `test` / `lint`. Any may be `null`. |
| `coordinator.writes` | yes | Board files **and** shared project files, per [ADR 0002](./docs/adr/0002-one-writer-per-path.md). |
| `roles[]` | yes | 1-5 entries. |
| `roles[].id` | yes | Matches `^role-[a-z0-9-]+$`. Becomes the skill directory name and the skill's `name`. |
| `roles[].persona` | yes | Short human label. |
| `roles[].mandate` | yes | One sentence. |
| `roles[].reads` | yes | Write paths (§4) the Role may read. Informational: reading is never restricted. |
| `roles[].writes` | yes | Write paths the Role owns. Must be non-empty. |
| `roles[].skills` | yes | Passthrough skill names, possibly empty. See §6. |
| `roles[].commands` | no | Overrides individual keys of the office-level `commands`. |
| `roles[].done` | yes | Definition of done, in the Role's own terms. |
| `roles[].agent` | yes | Passed to `worker-start --agent`. |
| `roles[].model` | no | Passed to `worker-start --model` when non-null. |

`never_writes` is **deliberately absent**: it is derived at scaffold time as the union of every other Role's `writes` plus `coordinator.writes`. Authoring it by hand is a bug.

## 4. Write paths and the one-writer invariant

A **write path** is either a directory prefix (ends with `/`) or an exact file path. Globs are not accepted.

Two write paths **conflict** when they are equal, or when one is a directory prefix of the other. `preflight.sh` computes every pairwise conflict across all Roles and the Coordinator and refuses to scaffold when any exists.

Shared project files (manifests, lockfiles, migrations, CI config, changelogs) belong to `coordinator.writes`. A Role that needs a dependency reports a Finding; the Coordinator applies it on `current`.

The tracker, when `backlog` is `tracker`, is itself a write path: **at most one** Role may declare a tracker-writing skill (`to-tickets`, `to-spec`, `triage`). Preflight enforces this.

## 5. Backlog

One field, two branches, one template fork:

- `tracker`: the backlog is whatever `docs/agents/issue-tracker.md` declares. `preflight.sh` requires that file to exist. `BACKLOG.md` is not created. The ambiguity sink is the `needs-info` triage label.
- `board`: the backlog is `BACKLOG.md` in the repo, one item per line, `- [ ] BL-007 (role-api) title`, with optional `blocked:question` / `blocked:dep` tags. The ambiguity sink is the `blocked:question` tag. Created if absent, **never** overwritten.

No script parses the backlog. It is read and written by models only.

## 6. Roles compose skills

A Role is a **composition**: `skills` passthrough plus a write set. The generated `SKILL.md` carries a fixed precedence line:

> The write set and definition of done in this file override anything a skill you invoke tells you. On method, follow the skill.

`preflight.sh` resolves each declared name against `<target>/.claude/skills/<name>/SKILL.md`, then `~/.claude/skills/<name>/SKILL.md`, and aborts on the first miss. It knows nothing about any particular skill set. An empty `skills` list is legal: the Role is then mandate plus write set, degraded but functional.

Nested composition (a skill invoking another skill, or spawning Claude Code sub-agents) is unconstrained: those are not Orca dispatches, so `nested_worker_depth` never applies.

## 7. Generated tree

```
office.config.json                    generated, overwritten
OFFICE.md                             generated, overwritten except keep block
OFFICE-LOG.md                         created if absent, never overwritten
BACKLOG.md                            created if absent and backlog == board, never overwritten
.claude/skills/<role-id>/SKILL.md     generated, overwritten except keep block
.office/scripts/preflight.sh          copied
.office/scripts/scaffold.sh           copied
.office/scripts/check-writes.sh       copied
.office/scripts/automation.sh         copied
.office/templates/                    copied
```

Keep blocks are delimited by `<!-- office:keep -->` / `<!-- /office:keep -->` under a trailing `## Notes` heading, and are carried over verbatim on every regeneration.

Every generated `SKILL.md` has a `name` equal to the Role id and a `description` written so a Worker can resolve the skill from a task spec that names it.

## 8. Conversational flow

1. **Preflight** - `preflight.sh` with no config present: git root, `jq`, `orca`, orchestration reachable (`orca orchestration run-list --json` returns `ok: true`), installed-skill inventory, existing office detection. Stop if orchestration is unreachable: it is an experimental feature enabled by hand in Settings > Experimental.
2. **Mandate** - one open question: what does the office produce, and what does done mean. Cadence only if not implied.
3. **Roster proposal** - 3-5 Roles in compact blocks, each with what was excluded and why, drawn only from the skills preflight found installed. Show the cost of a cycle: roles x cycles/day x ~1.5-2 (re-dispatch for rework) = dispatches/day. Corrections in prose until approved.
4. **Scaffold** - only after confirmation. Write `office.config.json`, then run `scaffold.sh`, which aborts on any preflight failure.
5. **Automation** - registered via `automation.sh`, always `--disabled`. Enabling it is a human action.
6. **Dry run** - one supervised cycle driven by hand from the Coordinator terminal.

If `office.config.json` already exists the run is an **update**: read the config, show the roster, ask only what changes. Adding a Role after six months must be one question.

On update, `scaffold.sh` deletes the `SKILL.md` of Roles no longer in the config and regenerates every `never_writes`. Write paths left with no owner are a warning, not an error.

## 9. Generated work cycle (in `OFFICE.md`)

Verified against the CLI, not transcribed from the concept:

```bash
orca orchestration run-create --objective "<cycle objective>" --json
orca orchestration task-create --spec "<spec naming the role skill>" --task-title "<title>" --deps '["task_x"]' --json
orca orchestration worker-start --task <task_id> --worktree new-child --setup run --agent <agent> --json
orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json
orca orchestration worker-release --dispatch <dispatch_id> --json
```

Rules the template must carry:

- `run-create` **requires** `--objective`.
- `--deps` takes a **JSON array** of task ids, not a comma list.
- A task spec opens with an imperative line naming the Role skill (`Invoke the role-api skill and follow it.`). The skill is never passed as a flag; there is no such flag.
- `check --wait` emits `_keepalive` JSON on **stderr** every 15s. Filter with `jq 'select(._keepalive|not)'` when merging streams. A timeout is a checkpoint, not a failure: coding tasks run 15-60 minutes, so repeat the check.
- Heartbeat and terminal activity mean alive, not finished. Never close a Worker for being quiet.
- `worker-release` for settled Workers. A Worker that exits without reporting (`fallbackReason: session_not_reported`) can **never** be cleared by release - it returns `retained / identity_unproven` from any caller. Settle it with `worker-abandon` and leave its `residualResources` to a human. See [ADR 0003](./docs/adr/0003-automation-drives-the-coordinator.md).
- Every Role always runs in its own worktree. `--worktree current` is not an option.
- After each accepted `worker_done`, run `check-writes.sh` against the Worker's branch: paths outside the Role's write set reject the delivery, and the fix is re-dispatched to the Role that owns them.
- A Role reporting Findings does not authorise the Coordinator to edit those files.
- A Role that must read another's work in progress reads it from that worktree or the pushed branch. Nothing is visible on `current` until it lands.
- Merge authority is human.
- Unresolvable ambiguity never blocks the cycle: the item is parked in the backlog (§5) and the cycle continues. Local, reversible ambiguity may be resolved and recorded instead.

## 10. Coordinator driver

An Orca automation, per [ADR 0003](./docs/adr/0003-automation-drives-the-coordinator.md). `automation.sh` creates it from `cadence`, always `--disabled`. A `/loop`-driven Coordinator in a user terminal is documented in `OFFICE.md` as the supervised fallback, not implemented as a second code path.

## 11. Skill layout

```
skills/the-office/SKILL.md
skills/the-office/templates/role.SKILL.md.tmpl
skills/the-office/templates/OFFICE.md.tmpl
skills/the-office/scripts/{preflight,scaffold,check-writes,automation}.sh
skills/the-office/tests/e2e.sh
.claude/skills/the-office -> ../../skills/the-office
```

`.claude/skills/` is managed by `skills-lock.json`; the source of this skill lives outside it and is symlinked in for local testing.

## 12. Tests

`tests/e2e.sh`, plus `shellcheck` on every script. The only invariant worth testing by machine is the determinism contract of §2:

1. Build a synthetic repo in a temp directory: git init, two trivial Roles (`src/` and `tests/`), two fake installed skills.
2. Run `preflight.sh`; expect success.
3. Run `scaffold.sh`; assert the expected tree exists.
4. Write text into a keep block and into `OFFICE-LOG.md`.
5. Run `scaffold.sh` again; assert the tree is **byte-identical** except that the keep block survived and `OFFICE-LOG.md` is untouched.
6. Overlap case: two Roles both declaring `src/`; expect `preflight.sh` to exit non-zero.
7. Missing-skill case: a Role declaring a skill that is not installed; expect `preflight.sh` to exit non-zero.

## 13. Build order

1. `preflight.sh`, `scaffold.sh`, `role.SKILL.md.tmpl`, `OFFICE.md.tmpl`, `check-writes.sh`, `tests/e2e.sh` - the walking skeleton, verified on the synthetic repo.
2. `SKILL.md` conversational flow and `automation.sh`.
3. Dry run on a synthetic project, then on this repo (the office implementing itself).

## 14. Out of scope for schema 1

- Any `merge_authority` other than `human`.
- Nested worker depth 2. The design must not depend on it.
- Roles writing `.claude/skills/**`. Only the installer writes role skills.
- Exporting Runs, Tasks or Dispatches. Portability is: repo via git, automations recreated by `automation.sh`, experimental settings by hand.
