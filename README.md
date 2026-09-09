# the-office

A generator skill that installs an **office** of Orca agents on a repo: one Coordinator plus 3-5 specialised Roles that work a backlog continuously.

The skill is an **installer, not a runtime**. It runs once, writes files into the target repo, and gets out of the way. From then on the office is run by the Coordinator and the role skills the installer generated. An office is a repo, not an installation: everything essential is reproducible from `office.config.json` by the scripts copied into `.office/scripts/`.

- [SPEC.md](./SPEC.md) - the full specification: schema, generated tree, verified cycle
- [CONTEXT.md](./CONTEXT.md) - vocabulary. `Role` is the durable definition, `Worker` the ephemeral instance of one; they are never interchangeable
- [docs/adr/](./docs/adr/) - why the design is shaped this way

## Prerequisites

Two of these are human actions, per machine, that no script can do for you.

| | |
|---|---|
| `orca` CLI, `jq`, `git` | on `PATH` |
| **Orchestration** | an experimental feature: enable it in Orca under Settings > Experimental. `preflight.sh` probes it and stops if it is unreachable |
| **Agent folder trust** | your agent CLI stops on its folder-trust dialog the first time it opens a path it does not trust, and the dispatch then fails with `agent_prompt_stalled` instead of doing anything. Trust covers nested paths, so opening the target repo once and accepting is enough: it covers the worktrees Orca creates under `.orca/workspaces/` |
| Nested worker depth | leave it at the default of `1`. The design does not depend on raising it |
| **A decided stack** | `office.config.json` needs `commands.install/build/test/lint` and per-Role write paths. On an existing codebase the installer reads them from the repo; on a greenfield repo they must come from a spec that already fixes them. See [Greenfield repos](#greenfield-repos) |

## Install

Ask for it in the repo you want to staff:

```
/the-office
```

The flow is six steps, and only step 4 writes anything:

1. **Preflight** - environment, orchestration reachability, installed-skill inventory, existing office detection.
2. **Mandate** - one open question: what does this office produce, and what does "done" mean?
   Before this question, the installer checks that the stack is already decided - see below.
3. **Roster proposal** - 3-5 Roles, drawn only from skills that are actually installed, with what was excluded and why, and the cost of a cycle in dispatches per day. Corrections in prose until you approve.
4. **Scaffold** - writes `office.config.json`, then generates everything from it.
5. **Automation** - registers the Coordinator's schedule, always **disabled**. Enabling it is yours.
6. **Dry run** - one supervised cycle, driven by hand.

You can also drive the scripts directly, which is what the skill does:

```bash
skills/the-office/scripts/preflight.sh  /path/to/repo   # validate, refuse to proceed on conflicts
skills/the-office/scripts/scaffold.sh   /path/to/repo   # generate; idempotent
skills/the-office/scripts/automation.sh /path/to/repo   # register the schedule, disabled
```

## Greenfield repos

**The installer never decides your stack.** It will not ask you, in passing, which language or framework to use: that is an architectural decision, and an answer typed in one line between two installer steps is the worst version of it.

- **Existing codebase** - the stack is read from the repo. Run `/the-office` and go.
- **Empty repo with a spec** - fine. A `SPEC.md`, an ADR or a tech-design doc that fixes the language, framework, layout and test runner is enough for an office to build the project from zero.
- **Empty repo with an idea** - stop. A `CONCEPT.md`, a pitch, or a README of intentions is not a spec. Write the spec first, then install the office.

If the stack is not fixed anywhere, the installer says so and stops instead of guessing.

## What lands in the target repo

```
office.config.json                    the only input; everything else is generated from it
OFFICE.md                             how this office works. The Coordinator's instructions
OFFICE-LOG.md                         the Coordinator's diary. Created once, never overwritten
BACKLOG.md                            only when backlog = board. Created once, never overwritten
.claude/skills/<role-id>/SKILL.md      one per Role. Only the installer writes these
.office/scripts/                       the scripts, so the office is reproducible from the repo
.office/templates/                     the templates, for the same reason
.gitignore                             gains `.orca/`, so Worker worktrees are not staged as embedded repos
```

Regeneration is safe: everything between `<!-- office:keep -->` and `<!-- /office:keep -->` under a file's trailing `## Notes` is carried over verbatim, and the two board files are never overwritten once present.

## Configuration

```json
{
  "schema_version": 3,
  "office": "acme-api",
  "mandate": "Keep the public API documented, tested and typed; done means a green suite and no undocumented endpoint.",
  "cadence": "daily",
  "backlog": "tracker",
  "tracker_skills": ["to-tickets", "triage"],
  "default_branch": "main",
  "integration_branch_prefix": "integration/",
  "commands": { "install": "pnpm install", "build": "pnpm build", "test": "pnpm test", "lint": "pnpm lint" },
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

Full field reference in [SPEC.md §3](./SPEC.md). The four things worth knowing up front:

**A Role is a person.** `name` and `title` are required, and the pair names the Role's worktree, its delivery branch and its Orca display name: the app shows `Jim (API Engineer)` where a per-cycle worktree used to show `role-api-09`. The id keeps every machine job - the skill's name, the write-set gate, the stem of the integration branch.

**`never_writes` is deliberately absent.** It is derived at scaffold time as the union of every other Role's `writes` plus the Coordinator's. Writing it by hand is a bug.

**A Role composes existing skills.** `skills` is a passthrough list of installed skill names; every generated role skill carries one fixed precedence line: *the write set and definition of done in this file override anything a skill you invoke tells you; on method, follow the skill.* The office owns boundaries, the composed skill owns method. Preflight resolves each name and aborts on the first miss, and knows nothing about any particular skill set. An empty list is legal.

**Write paths are directory prefixes or exact file paths, never globs.** Intersecting globs cannot be decided reliably in a shell script, and two Roles that want to split one directory by file extension are either one Role or a directory that needs splitting.

## Exactly one Role writes any given path

This is the only real failure mode of the design, so it is enforced rather than advised. `preflight.sh` computes every pairwise conflict across all Roles and the Coordinator and refuses to scaffold when one exists. Two paths conflict when they are equal, or when one is a directory prefix of the other.

The corollary catches people out: the most contested files belong to nobody in particular. Manifests, lockfiles, migrations, CI config and changelogs go in `coordinator.writes`. A Role that needs a new dependency reports it as a **Finding**; the Coordinator applies it. The same applies to the issue tracker when `backlog` is `tracker`: list the installed skills that write to it in `tracker_skills`, and at most one Role may hold one. The list is yours - the office knows no particular skill set, and an absent or empty list turns the check off.

## The cycle

The Coordinator is the only actor on the default branch. `OFFICE.md` carries the full sequence; the rules that cost the most to learn the hard way:

- **A `check --wait` timeout is a checkpoint, not a failure.** Coding tasks run 15-60 minutes. Repeat the check. Heartbeat and terminal activity mean alive, not finished: never close a Worker for being quiet.
- **`worker-release` only settles a Worker that reported.** One that exits silently can never be cleared by release - it returns `retained / identity_unproven` from any caller, forever. Settle it with `worker-abandon` and leave the residual resources it lists to a human.
- **Every Role has one standing worktree, reused every cycle.** `prepare-worktrees.sh` creates the desk once - worktree, branch and Orca label, all named after the Role's person - and levels it with the Role's integration branch before each dispatch. A Worker goes in with `--worktree branch:<person>` and no creation flags. A second worktree for one Role is two branches over one write set; `--worktree current` is never an option either.
- **A delivery is a branch.** A Worker commits on its own branch and stops. After each accepted `worker_done`, `check-writes.sh` verifies the delivery stayed inside the Role's write set - reading both the branch diff and the worktree's uncommitted changes, because a Worker that reports without committing is the common case.
- **A Finding does not authorise anyone to edit those files.** It becomes a backlog item, and the fix is re-dispatched to the Role that owns the path.
- **Ambiguity never blocks the cycle.** The item is parked (`needs-info` on a tracker, `blocked:question` on a board) and the cycle moves on.

## Merge pressure

Deliveries are branches, so unmerged work compounds: a Worker branching from a stale base re-implements what is already sitting on another branch. Two modes, one optional field.

**Without `integration_branch_prefix`** - `pending-merges.sh` refuses to let a cycle dispatch while any delivery is unmerged. Your office's real cadence is the cadence at which you merge, and the scaffold makes that visible instead of letting it degrade quietly.

**With `integration_branch_prefix`** - every Role gets its own integration branch, `integration/api`, `integration/design`, `integration/ops`, and a delivery that passes the write-set gate is landed on its Role's by `integrate.sh`. One branch per Role is one review per Role: you read an ops delivery on its own, in the frame of mind ops asks for, instead of finding it inside one pile with three other Roles.

How that branch reaches the default branch is each Role's own setting, `review`, and the roster table shows it:

- **`human`** - `review-integration.sh <role-id>` opens a Plannotator session on that one branch and merges **only** on an explicit approval. Your merge authority, in a UI instead of a shell. Without Plannotator the script says so and the review and merge stay manual.
- **`auto`** - `gate.sh` builds and tests the branch, a Claude Code sub-agent reviews it with the reviewers you named, and `merge-integration.sh` lands it on `approve`. The office stops only where a **product or intent decision** is missing: a reviewer that finds one returns `block:decision`, which takes that Role out of the next dispatch until you answer. A `block:quality` blocks nothing and comes back as a ticket.

Every cycle closes with a fixed summary in `OFFICE-LOG.md` - one prose line per merged branch, saying what the product does now that it did not before, and every open decision relisted until you answer it. That summary is where you catch drift, so it is written in product language and not in shas.

Set both deliberately. `integration_branch_prefix` decides whether the Coordinator may merge at all; `review` decides, Role by Role, whether it may do so without you.

## Scheduling

`automation.sh` registers the Coordinator as an Orca automation, always `--disabled`, running in the repo's own worktree with a fresh session. A `board` backlog also gets a precheck, so a cycle on an empty board records a skipped run instead of burning dispatches. Re-running the script syncs the existing automation rather than creating a second one.

`cadence: on-demand` schedules nothing, by design: run the cycle by hand.

Enable it only after you have watched a supervised cycle:

```bash
orca automations edit <id> --enabled
```

## Updating the roster

Run the skill again. If `office.config.json` exists the run is an update: it reads the config, shows the roster, and asks only what changes. Adding a Role after six months is one question.

`scaffold.sh` deletes the `SKILL.md` of Roles no longer in the config and recomputes every `never_writes`. Write paths left with no owner are a warning, not an error - code nobody maintains is a legitimate state.

## Tests

```bash
skills/the-office/tests/e2e.sh
shellcheck -e SC2016,SC2015 skills/the-office/scripts/*.sh skills/the-office/tests/e2e.sh
```

59 assertions on a synthetic repo. The invariant worth testing by machine is determinism: a second `scaffold.sh` run must be byte-identical, keep blocks must survive, and the board files must not be touched. The suite sets `OFFICE_SKIP_ORCA=1` so it runs without an Orca runtime; never set that when installing a real office.

## When something goes wrong

Every row here comes from a dry run, not from imagination.

| Symptom | Cause | What to do |
|---|---|---|
| `agent_prompt_stalled` at `stage: dispatch_input` | the agent CLI does not trust the worktree path and is sitting on its folder-trust dialog | trust the repo root once; it covers the worktrees underneath. Not a slow agent, and raising `--timeout-ms` will not help |
| `worker-release` returns `retained / identity_unproven` | the Worker exited without reporting, so Orca cannot prove which terminal it owned | `worker-abandon` is the only thing that settles it. It stops no process: read the residual resources it lists |
| `worker-release` returns `retained / user_takeover` | somebody typed in the Worker's terminal | expected. Orca will not close a terminal a human touched |
| `run_required` from `task-create` | no Run is bound to this terminal | `run-create --objective "..."` first. `--objective` is required |
| `nested_worker_depth_exceeded` | a Worker tried to dispatch | complete the task in the Worker. All routing lives on the Coordinator, by design |
| `pending-merges: base branch 'main' does not exist` | `default_branch` does not match the repo | set `default_branch` in the config |
| `pending-merges` blocks every cycle | a delivery is unmerged, possibly a superseded branch | merge it, delete it, or declare an `integration_branch`. The Coordinator will neither merge nor delete for you |
| a Role edited a file it does not own | it happens; the gate is what catches it | `check-writes.sh` rejects the delivery. Re-dispatch the fix to the owning Role |

## What it deliberately does not do

- Merge into your default branch. Ever.
- Resolve a conflict.
- Enable its own automation.
- Let a Role write `.claude/skills/**`. Only the installer writes role skills.
- Depend on any particular skill set being installed.
- Depend on nested worker depth above 1.
