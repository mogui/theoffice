# `the-office` - specification

A generator skill that installs an **office** on a target repo: one Coordinator plus 3-5 specialised Roles that work a backlog continuously through Orca orchestration.

Vocabulary is defined in [CONTEXT.md](./CONTEXT.md). Decisions are recorded in [docs/adr/](./docs/adr/). This spec says what gets built; it does not restate the reasoning behind the decisions.

## 1. Guiding principle

The skill is an **installer, not a runtime**. It runs once (or again to update the roster), writes files into the target repo, and gets out of the way. If a work cycle needs the skill in order to run, the scaffold is wrong: the office's logic has ended up in the skill instead of in `OFFICE.md`.

An office is a repo, not an installation. Everything essential is reproducible from `office.config.json` by the scripts copied into `.office/scripts/`.

The installer **never decides the stack**. `commands.*` and every `writes` path presuppose a language, a framework, a layout and a test runner; on a repo with code those are read from the repo, and on a greenfield repo they must already be fixed by a spec, an ADR or a tech-design doc. A concept or an idea is not one. When nothing fixes the stack, the run stops: choosing it is an architectural decision with its own process, not a question asked in passing between two installer steps.

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
  "schema_version": 3,
  "office": "acme-api",
  "mandate": "Keep the public API documented, tested and typed; done means green suite and no undocumented endpoint.",
  "cadence": "on-demand",
  "backlog": "tracker",
  "tracker_skills": ["to-tickets", "triage"],
  "default_branch": "main",
  "integration_branch_prefix": "integration/",
  "commands": {
    "install": "pnpm install",
    "build": "pnpm build",
    "test": "pnpm test",
    "lint": "pnpm lint"
  },
  "coordinator": {
    "agent": "claude",
    "time": "09:00",
    "writes": ["OFFICE.md", "OFFICE-LOG.md", "package.json", "pnpm-lock.yaml", ".github/"]
  },
  "roles": [
    {
      "id": "role-api",
      "name": "Jim",
      "title": "API Engineer",
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
| `schema_version` | yes | Integer. `3` for this spec. A schema 2 config is refused with the edit it needs: drop `merge_authority`, give every Role a `review` block. A schema 1 config is refused with its own two: per-Role `name`/`title`, and `integration_branch` renamed to `integration_branch_prefix`. |
| `office` | yes | Slug, used in generated titles. |
| `mandate` | yes | One sentence: what the office produces and what done means. |
| `cadence` | yes | `on-demand` \| `hourly` \| `daily`. Drives the automation trigger. |
| `backlog` | yes | `tracker` \| `board`. See §5. |
| `tracker_skills` | no | Names of installed skills that write to the tracker. Checked only when `backlog` is `tracker`; absent or empty disables the check. |
| `default_branch` | no | Defaults to `main`. What is allowed to reach it is decided per Role, in `roles[].review`. |
| `integration_branch_prefix` | no | Absent, every delivery waits for a human merge. Present, each Role gets its **own** integration branch `<prefix><role-slug>`: the Coordinator lands that Role's gate-passed deliveries there and closes it the way that Role's `review` says. Lowercase, must end in `/`, must differ from `default_branch`. See §4b. |
| `commands` | yes | Office-level `install` / `build` / `test` / `lint`. Any may be `null`. |
| `max_tasks_per_cycle` | no | Defaults to `3`. The cap the generated ordering rule states. |
| `coordinator.agent` | when scheduled | Passed to `automations create --provider`. Required unless `cadence` is `on-demand`, which schedules nothing. |
| `coordinator.time` | no | `HH:MM` for the `daily` trigger. Omitted, Orca picks the preset's own time. |
| `coordinator.writes` | yes | Board files **and** shared project files, per [ADR 0002](./docs/adr/0002-one-writer-per-path.md). |
| `roles[]` | yes | 1-5 entries. |
| `roles[].id` | yes | Matches `^role-[a-z0-9-]+$`. Becomes the skill directory name, the skill's `name`, the write-set gate's key and the stem of the Role's integration branch. |
| `roles[].name` | yes | The Role's person: one capitalised word, 2-16 letters, unique in the office. It names the Role's standing worktree, its delivery branch and its Orca display name, so a Worker row reads `Jim (API Engineer)` instead of `role-api-09`. |
| `roles[].title` | yes | Short job title a human would put on a badge, shown next to the name. |
| `roles[].review` | yes | How this Role's integration branch is closed. There is no office-wide merge authority to fall back on. See §4c. |
| `roles[].review.mode` | yes | `auto` \| `human`. `human` means a person approves that branch and nothing else merges it. `auto` means the Coordinator gates it, has a sub-agent review it, and merges on `approve`. |
| `roles[].review.with` | yes | Non-empty, ordered. Who reviews: a skill name, a tool on `PATH`, or `builtin:<name>` for an agent built-in. Preflight resolves each entry in `.claude/skills/` then on `PATH` and **fails** when it resolves to neither; a `builtin:` entry is reported unverified instead. |
| `roles[].persona` | yes | Short human label. |
| `roles[].mandate` | yes | One sentence. |
| `roles[].reads` | yes | Write paths (§4) the Role may read. Informational: reading is never restricted. |
| `roles[].writes` | yes | Write paths the Role owns. Must be non-empty. |
| `roles[].skills` | yes | Passthrough skill names, possibly empty. See §6. |
| `roles[].commands` | no | Overrides individual keys of the office-level `commands`. |
| `roles[].done` | yes | Definition of done, in the Role's own terms. |
| `roles[].agent` | yes | Passed to `worker-start --agent`. |
| `roles[].model` | no | Passed to `worker-start --model` when non-null. |

`OFFICE-INBOX.md` is **deliberately absent** too: the Coordinator owns the inbox by construction, so the scaffold adds it to `coordinator.writes` as rendered and to every Role's `never_writes`, and `preflight.sh` refuses a config in which a Role declares it. A Role able to rewrite the inbox could rewrite what a human asked for, which is the one thing the channel must not allow.

`never_writes` is **deliberately absent**: it is derived at scaffold time as the union of every other Role's `writes` plus `coordinator.writes`. Authoring it by hand is a bug.

## 4. Write paths and the one-writer invariant

A **write path** is either a directory prefix (ends with `/`) or an exact file path. Globs are not accepted.

Two write paths **conflict** when they are equal, or when one is a directory prefix of the other. `preflight.sh` computes every pairwise conflict across all Roles and the Coordinator and refuses to scaffold when any exists.

Shared project files (manifests, lockfiles, migrations, CI config, changelogs) belong to `coordinator.writes`. A Role that needs a dependency reports a Finding; the Coordinator applies it on `current`.

The tracker, when `backlog` is `tracker`, is itself a write path: **at most one** Role may declare a skill listed in `tracker_skills`. Preflight enforces this, and skips the check when the list is absent or empty - the skill knows no particular skill set, so the names come from the config.

## 4b. Merge pressure

Deliveries are branches, so unmerged work compounds: a Worker branching from a stale base re-implements what is already sitting on another branch. This is not theoretical - it appeared on the second cycle of the dry run, where a Role had to re-implement its predecessor's function because that delivery had never landed.

Two modes, one optional field:

**Without `integration_branch_prefix`** - Workers branch from `default_branch`. `pending-merges.sh` exits non-zero while any delivery is unmerged, and the cycle **does not dispatch**: it reports the wait. The office's real cadence is the cadence at which the human merges, and the scaffold makes that visible rather than letting it degrade quietly.

**With `integration_branch_prefix`** - each Role gets its own integration branch, `<prefix><role-slug>`, and its Workers branch from that one. A delivery that passes the write-set gate is landed there by `integrate.sh`. One branch per Role is one **review** per Role: an ops delivery and a design delivery are not read in the same frame of mind, and a single shared branch forced them into one diff.

How an integration branch reaches `default_branch` is §4c. A branch that conflicts is left untouched either way: the office does not resolve conflicts.

### 4c. Review authority, per Role

Each Role declares its own in `review`. There is no office-wide setting, because the honest answer is not uniform: a pure domain package and a deploy playbook do not deserve the same gate, and one field for both means one of them is wrong.

**`mode: "human"`** - `review-integration.sh <role-id>` opens a Plannotator session on that one branch. An approval is the merge and the only thing that is; feedback, a closed tab, or no Plannotator on the machine leave the branch untouched and the merge manual.

**`mode: "auto"`** - three steps, and skipping one is not allowed:

1. `gate.sh <role-id>` runs the office's `install`/`build`/`lint`/`test`, with that Role's own overrides, on the integration branch in a throwaway worktree. A non-zero exit **is** a `block:quality` and no reviewer is invoked: a model asked to simulate a compiler that is already installed is a wasted review.
2. The Coordinator invokes a Claude Code **sub-agent** - not an Orca dispatch, so worker depth is not involved - on that branch alone, with the reviewers named in `review.with`, and gives it the spec, the glossary, the ADRs and the originating ticket. Without those four it can judge quality but never intent.
3. The verdict is exactly one of:
   - `approve` - `merge-integration.sh <role-id> "<basis>"` lands it, recording in the merge message what authorised it.
   - `block:quality` - the code is wrong or incomplete. A `ready-for-agent` ticket carries the Findings back to that Role; the branch stays, and the Role's next Worker starts from it.
   - `block:decision` - the code is correct but settles something the spec does not. A `needs-info` ticket carries the question to a human; the branch stays.

The test that separates the two blocks: **derivable from the spec, the glossary or an existing ADR - proceed; would have to be invented - stop.** It is the intake step's test applied to a diff instead of a request.

A `block:quality` blocks nothing. A `block:decision` takes its Role out of the next dispatch until a person answers: every commit stacked on an unanswered decision is built on a premise that may be rejected. That is the only place an office waits for a human.

Preflight **fails** on a `review.with` entry it cannot resolve rather than degrading. Degrading to `human` stops the office waiting for a review nobody was told to do; degrading to `auto` merges with less scrutiny than was declared. Both are worse than an install that refuses to finish.

In both modes a superseded delivery branch still counts as pending. The Coordinator neither merges nor deletes it - it reports it, and a human chooses.

`integrate.sh` merges inside a throwaway git worktree so the Coordinator's own checkout is never disturbed, and runs the write-set gate against the integration branch before merging: a delivery that broke its write set cannot land.

## 5. Backlog

One field, two branches, one template fork:

- `tracker`: the backlog is whatever `docs/agents/issue-tracker.md` declares. `preflight.sh` requires that file to exist. `BACKLOG.md` is not created. The ambiguity sink is the `needs-info` triage label.
- `board`: the backlog is `BACKLOG.md` in the repo, one item per line, `- [ ] BL-007 (role-api) title`, with optional `blocked:question` / `blocked:dep` tags. The ambiguity sink is the `blocked:question` tag. Created if absent, **never** overwritten.

No script parses the backlog. It is read and written by models only.

## 5b. Input channel

Per [ADR 0004](./docs/adr/0004-the-inbox-is-the-input-channel.md). The backlog is what the office works; the **inbox** is how work gets there in the first place.

`OFFICE-INBOX.md` is generated from a template on first scaffold and **never** overwritten afterwards. Anyone appends an entry in prose - a human, or a Claude Code session opened in the repo. Each entry carries `Status` (`new` | `queued: <ids>` | `needs-info: <question>` | `closed`) and `Urgent` (`yes` | `no`).

The Coordinator consumes it at **step 0 of the cycle, before the merge gate**, so an input is never lost while deliveries are unmerged. It turns each entry into backlog items, moves the entry's `Status`, and never edits what the human wrote. An entry implying a non-reversible decision does not become a backlog item: it comes back as a request for an ADR.

The scaffold also appends a marked section (`<!-- office:claude-md -->`) to the target repo's `CLAUDE.md`, creating the file if absent and recognising its own marker so a second run appends nothing. Without it a session opened in the repo implements product work itself, on paths that belong to Roles, and the next delivery is born in conflict. `CLAUDE.md` is the only file every session reads unprompted, which is why the pointer lives there and not in a skill.

There is no chat channel to the Coordinator, and schema 1 does not want one: the automation opens a fresh session per cycle, so anything not in the repo is not in the office's memory.

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
OFFICE-INBOX.md                       created if absent, never overwritten
CLAUDE.md                             appended with a marked office pointer, once
BACKLOG.md                            created if absent and backlog == board, never overwritten
.gitignore                            appended with `.orca/` if missing, never rewritten
.claude/skills/<role-id>/SKILL.md     generated, overwritten except keep block
.office/scripts/preflight.sh          copied
.office/scripts/scaffold.sh           copied
.office/scripts/check-writes.sh       copied
.office/scripts/pending-merges.sh     copied
.office/scripts/prepare-worktrees.sh  copied
.office/scripts/integrate.sh          copied
.office/scripts/review-integration.sh copied
.office/scripts/automation.sh         copied
.office/templates/                    copied
```

Keep blocks are delimited by `<!-- office:keep -->` / `<!-- /office:keep -->` under a trailing `## Notes` heading, and are carried over verbatim on every regeneration.

Every generated `SKILL.md` has a `name` equal to the Role id and a `description` written so a Worker can resolve the skill from a task spec that names it.

## 8. Conversational flow

0. **Agent trust** - Claude Code stops on its folder-trust dialog before accepting input in a path it does not trust, and the dispatch then fails with `agent_prompt_stalled` at `stage: dispatch_input` rather than doing anything useful. Trust covers nested paths: trusting the repo root once covers every worktree Orca creates under `<repo>/.orca/workspaces/`. This is a human, per-machine action like the experimental toggle - see §14 - and `preflight.sh` cannot verify it, because the worktree paths do not exist yet. Accepting the dialog by hand inside a Worker's terminal marks it taken over, and `worker-release` then reports `retained / user_takeover`.
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
.office/scripts/prepare-worktrees.sh
orca orchestration run-create --objective "<cycle objective>" --json
orca orchestration task-create --spec "<spec naming the role skill>" --task-title "<title>" --display-name "<Name> (<Title>) - <item id>" --deps '["task_x"]' --json
orca orchestration worker-start --task <task_id> --worktree branch:<person> --agent <agent> --json
orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json
orca orchestration worker-release --dispatch <dispatch_id> --json
```

Rules the template must carry:

- `run-create` **requires** `--objective`.
- A Worker dispatched into a fresh worktree stalls on the agent's folder-trust dialog until that path is trusted (§8, step 0). Raise `--timeout-ms` above the 60s default for the first dispatch into a new worktree; a stall there is a trust problem, not a slow agent.
- `--deps` takes a **JSON array** of task ids, not a comma list.
- A task spec opens with an imperative line naming the Role skill (`Invoke the role-api skill and follow it.`). The skill is never passed as a flag; there is no such flag.
- `check --wait` emits `_keepalive` JSON on **stderr** every 15s. Filter with `jq 'select(._keepalive|not)'` when merging streams. A timeout is a checkpoint, not a failure: coding tasks run 15-60 minutes, so repeat the check.
- Heartbeat and terminal activity mean alive, not finished. Never close a Worker for being quiet.
- `worker-release` for settled Workers. A Worker that exits without reporting (`fallbackReason: session_not_reported`) can **never** be cleared by release - it returns `retained / identity_unproven` from any caller. Settle it with `worker-abandon` and leave its `residualResources` to a human. See [ADR 0003](./docs/adr/0003-automation-drives-the-coordinator.md).
- **One standing worktree per Role, reused every cycle.** `prepare-worktrees.sh` creates the Role's integration branch, its worktree and its Orca label - all named after its person - and fast-forwards the worktree onto the integration branch when it is clean. A Worker is then started with `--worktree branch:<person>` and no creation flags: `--name`, `--base-branch`, `--display-name` and `--setup` are rejected for an existing worktree. A dirty or unlanded desk is reported and not dispatched. `--worktree current` is never an option: that is the Coordinator's own checkout.
- **A Worker row carries a person, not an id.** `Jim (API Engineer)` on the worktree, `Jim (API Engineer) - BL-012` on the Task. `role-api-09` told a reviewer nothing, and the numbering only ever counted how many times the office had run.
- After each accepted `worker_done`, run `check-writes.sh <role-id> <worktree-path> <base-ref>`: paths outside the Role's write set reject the delivery, and the fix is re-dispatched to the Role that owns them. It reads both the branch diff and the worktree's uncommitted changes, because a Worker that reports without committing is the common case and a branch-only gate passes it blindly.
- **A delivery is a branch.** The Role template tells the Worker to commit on its own branch and stop. What happens to that branch afterwards is §4c's business, never a Worker's.
- A Role reporting Findings does not authorise the Coordinator to edit those files.
- A Role that must read another's work in progress reads it from that worktree or the pushed branch. Nothing is visible on `current` until it lands.
- Merge authority is human.
- **Step 0 is intake, and it runs before the merge gate**: consume `OFFICE-INBOX.md` into backlog items even when `pending-merges.sh` will refuse the cycle. Losing an input to a blocked cycle is worse than a cycle that dispatches nothing.
- **The order is a rule, not a judgement.** The Coordinator starts from nothing every cycle, so the template states the order: urgent inbox entries first, then one effort at a time (the group holding the oldest open item, lowest number inside it), blocked items skipped, at most `max_tasks_per_cycle` Tasks and never two on the same Role. "Nothing dispatchable" is a legitimate outcome to record in `OFFICE-LOG.md`.
- Unresolvable ambiguity never blocks the cycle: the item is parked in the backlog (§5) and the cycle continues. Local, reversible ambiguity may be resolved and recorded instead.

## 10. Coordinator driver

An Orca automation, per [ADR 0003](./docs/adr/0003-automation-drives-the-coordinator.md). A `/loop`-driven Coordinator in a user terminal is documented in `OFFICE.md` as the supervised fallback, not implemented as a second code path.

`automation.sh` registers it, and is re-runnable: it looks the automation up by name (`office-<office>-coordinator`) and edits it rather than creating a duplicate. What it sets, and why:

| Setting | Value | Reason |
|---|---|---|
| `--trigger` | `cadence`, plus `--time` from `coordinator.time` | `on-demand` schedules nothing: the script says so and exits 0. |
| `--provider` | `coordinator.agent` | The automation launches an agent, not a shell command. |
| `--workspace path:<repo>` + `--workspace-mode existing` | the office repo itself | The Coordinator is the only actor on the default branch, so it must not get a fresh worktree per run. |
| `--fresh-session` | always | A cycle starts from the board, not from the previous run's context. |
| `--precheck` | `grep -qE '^- \[ \] ' BACKLOG.md`, only when `backlog` is `board` | A non-zero precheck records a skipped run instead of burning a cycle on an empty board. A tracker backlog has no portable query, so it gets no precheck. |
| `--disabled` | always | Enabling an unattended office is a human decision. |

The prompt names the intake step and the ordering rule by name and then points at `OFFICE.md` for both: a Coordinator that skipped intake would leave the office deaf. It deliberately does not restate the cycle. An automation prompt that carried the procedure would be a second copy to keep in sync, and the office's logic belongs in the repo.

## 11. Skill layout

```
skills/the-office/SKILL.md
skills/the-office/templates/role.SKILL.md.tmpl
skills/the-office/templates/OFFICE.md.tmpl
skills/the-office/scripts/{preflight,scaffold,check-writes,pending-merges,integrate,automation}.sh
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
8. `check-writes.sh` gates committed changes, uncommitted changes, and a no-change delivery.
9. `.orca/` is ignored, so Worker worktrees cannot be staged as embedded repos.
10. `pending-merges.sh` passes a clean base, ignores a role branch with no commits, and refuses to dispatch while a delivery is unmerged.
11. `integrate.sh` refuses an office with no `integration_branch_prefix`, lands a gate-passed delivery on that Role's own integration branch, creates no branch for a Role that delivered nothing, leaves `default_branch` untouched, and refuses a delivery that broke its write set without moving the integration branch.
11b. `preflight.sh` refuses a schema 1 config, a prefix that does not end in `/`, a prefix equal to `default_branch`, and two Roles sharing a name.
12. `automation.sh` schedules nothing for an on-demand office and refuses to run before `scaffold.sh`.
13. `OFFICE-INBOX.md` is generated, survives regeneration, and lands in every Role's `never_writes` without being authored; `preflight.sh` refuses a Role that declares it.
14. The `CLAUDE.md` pointer is appended exactly once across repeated scaffolds.

`preflight.sh` honours `OFFICE_SKIP_ORCA=1` to skip every Orca probe. It exists so the suite runs on a machine with no Orca runtime; never set it when installing a real office.

## 13. Build order

1. ~~`preflight.sh`, `scaffold.sh`, `role.SKILL.md.tmpl`, `OFFICE.md.tmpl`, `check-writes.sh`, `tests/e2e.sh` - the walking skeleton, verified on the synthetic repo.~~ Done.
2. ~~`SKILL.md` conversational flow and `automation.sh`.~~ Done.
3. ~~Dry run on a synthetic project: two supervised cycles, then one cycle driven end to end by the automation with no human in the loop.~~ Done. It found the merge-pressure gap in §4b, plus a false-positive write-set gate, a missing delivery rule, and `.orca/` staging itself.
4. `pending-merges.sh` and `integrate.sh` - done, and the second cycle's deliveries were landed on an integration branch with the suite green.
5. Dry run on this repo: the office implementing itself.

## 14. Out of scope for schema 3

- Nested worker depth 2. The design must not depend on it.
- Roles writing `.claude/skills/**`. Only the installer writes role skills.
- Exporting Runs, Tasks or Dispatches. Portability is: repo via git, automations recreated by `automation.sh`, experimental settings by hand.
