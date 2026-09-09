---
name: the-office
description: "Install an office of Orca agents on a repo: a coordinator plus 3-5 role skills working a backlog. Use when the user wants multi-agent orchestration set up, wants to add or remove a role from an existing office, or asks for 'the office'."
---

# The Office

Install an **office** on a target repo: `office.config.json`, one generated role skill per Role, board files, the input channel (`OFFICE-INBOX.md`), and the bootstrap scripts that reproduce all of it.

You are an **installer, not a runtime**. Run once, write files, get out of the way. A work cycle that would need you in order to run means the scaffold is wrong: the office's logic belongs in `OFFICE.md`.

**Role** is the durable definition, **Worker** the ephemeral instance of one. Keep them apart in everything you say and write: [CONTEXT.md](../../CONTEXT.md) is the glossary, and `docs/adr/` carries why the design is shaped this way.

## What you author

`office.config.json`, and nothing else. `scripts/scaffold.sh` is a pure function from that config to every generated file, so every fact a Role needs belongs in a config field. When a Role needs something the schema cannot express, say so and stop.

## Flow

### 1. Preflight

```bash
skills/the-office/scripts/preflight.sh <repo-root>
```

It reports the environment, whether orchestration is reachable, the installed skill inventory, and whether an office already exists. A non-zero exit names what to fix: fix that and re-run.

An existing `office.config.json` makes this run an **update**: read the config, show the roster, ask only what changes. Adding a Role after six months is one question.

### Precondition: a codebase, or a spec

The stack must already be decided. `commands.install/build/test/lint` and every Role's `writes` path presuppose a language, a framework, a layout and a test runner.

On a repo with code, read them from the repo. On a greenfield repo, take them from a document that already fixes them: a spec, an ADR, a tech design. A concept, a pitch or a README of intentions fixes nothing.

Choosing a stack is an architectural decision with its own process, so when nothing fixes it, stop and say so - the user writes the spec first, then runs the install again. A spec with no code yet is a fine starting point: an office can build a project from zero.

### 2. Mandate

Ask one open question: **what does this office produce, and what does "done" mean?** Ask about cadence only if the answer leaves it open.

### 3. Roster proposal

Propose 3-5 Roles in compact blocks: `name`, `title`, persona, one-sentence mandate, `reads`, `writes`, `skills`, `done`. Say what you excluded and why. Field reference: [SPEC.md](../../SPEC.md) §3.

- Every Role is a **person**: a `name` (one random human first name, unique in the office) and a short `title` a human would put on a badge - `Jim` + `Platform Engineer`, `Ann` + `Designer`. The name is the Role's worktree, its delivery branch and its Orca label, all reused for every dispatch, so the app shows one standing `Jim (Platform Engineer)` row instead of a new `role-platform-09` per cycle. On an update, rename what an earlier install left behind with `orca worktree set --worktree path:<path> --display-name "<...>"`, and remove the duplicates once their branches are merged. Generate the names yourself, do not ask; the id stays `role-<slug>` because it keys the skill, the write-set gate and the integration branch.
- Draw `skills` from the inventory preflight found, and only from there.
- `writes` is the part that deserves discussion. Exactly one Role writes any given path.
- Shared project files - manifests, lockfiles, migrations, CI config, changelogs - belong to `coordinator.writes`.
- When `backlog` is `tracker`, the tracker is a write path too: name the installed skills that write to it in `tracker_skills`, and give them to one Role at most.
- Price a cycle out loud: roles x cycles/day x ~1.5-2 for rework = dispatches/day.
- Name the **merge pressure** the cadence creates. With no `integration_branch_prefix` the cycle refuses to dispatch while a delivery is unmerged, so an `hourly` office needs an hourly merger, and `on-demand` is the honest cadence for someone who wants merge authority whole. An `integration_branch_prefix` (say `integration/`) gives every Role its own integration branch - `integration/platform`, `integration/design` - so the Coordinator can land deliveries and each Role's work is closed on its own. The user picks it explicitly.

### 3b. Review authority, Role by Role

**Ask this. Never assume it**, and never set it from the cadence: it decides what an unattended office is allowed to put on the default branch, and it is the one field a user regrets not being asked about.

Put it as one question - *which Roles may the office merge on its own, and which wait for you?* - and bring a proposed answer per Role, because the honest default is not uniform:

- `auto` fits a Role whose mistakes are **reversible with a revert**: a pure domain package, templates, copy nobody publishes without the user.
- `human` fits a Role whose output **acts outside the repo** - deploy playbooks, infrastructure, anything that has already changed a machine by the time you read the diff. A revert does not undo that.

Then propose *who* reviews, **only from what preflight actually found**. Never name a reviewer that is not installed: the whole point of asking is that the answer is executable.

- `mode: "human"` -> `plannotator` if preflight reported it. If it did not, say so plainly: that Role's review and merge stay manual, and the office will sit and wait.
- `mode: "auto"` -> `code-review` is the spine, because its two axes are the merge question itself: does this follow the repo's standards, and does it do what the ticket asked. Add a second reviewer only where the Role earns it - `security-review` for the Role that writes network or auth code - and leave the list at one otherwise. A reviewer that blocks on things which are not merge blockers gets learned as noise.

It lands in the config as one block per Role, and `with` is one list whether it names a skill or a tool on PATH - preflight resolves each entry in `.claude/skills/` first, then on `PATH`, and **fails** if it resolves to neither. An agent built-in such as `security-review` is on no filesystem, so it is written `builtin:security-review`: preflight then reports it as unverified instead of pretending to have checked it. Use the prefix only for a real built-in, never to silence a typo.

```json
{ "id": "role-domain",   "review": { "mode": "auto",  "with": ["code-review"] } }
{ "id": "role-platform", "review": { "mode": "auto",  "with": ["code-review", "builtin:security-review"] } }
{ "id": "role-ops",      "review": { "mode": "human", "with": ["plannotator"] } }
```

Say out loud what `auto` buys and what it costs: the office stops waiting on the user for code, and starts stopping only where a **product or intent decision** is missing. The verdict contract, the `derivable -> proceed, invent -> stop` test, and the end-of-cycle summary that gives the user a chance to catch drift are all in `templates/OFFICE.md.tmpl`; read them there before explaining them.

Take corrections in prose. The step ends on the user's approval, and the first file is written after it.

### 4. Scaffold

```bash
skills/the-office/scripts/scaffold.sh <repo-root>
```

Write `office.config.json` first. The scaffold re-runs preflight, carries over every keep block, and leaves `OFFICE-LOG.md` and `BACKLOG.md` alone once they exist. A second run must change nothing: a diff there is a bug in the scaffold.

### 4b. The input channel

The scaffold writes `OFFICE-INBOX.md` and appends a pointer to the target repo's `CLAUDE.md`. Say both out loud when you hand the office over, because an office nobody can talk to gets talked over instead:

- An instruction for the office is an **entry appended to `OFFICE-INBOX.md`**, in prose. The Coordinator consumes it at the intake step of the next cycle, turns it into backlog items, and answers by moving the entry's `Status`. There is no chat channel: the automation reuses the standing Coordinator session - one tab, cleared by its precheck before every cycle - and the repo is the office's memory.
- The `CLAUDE.md` pointer is what makes any Claude Code session opened in the repo write to the inbox instead of implementing the work itself.
- `max_tasks_per_cycle` (default 3) caps one cycle, and no cycle ever puts two Tasks on the same Role: two Workers of one Role share a write set, so the second delivery is born in conflict.

### 5. Automation

```bash
skills/the-office/scripts/automation.sh <repo-root>
```

Registers the Coordinator's schedule, always disabled, and prints the human actions that remain. Enabling it is one of them.

### 6. Dry run

Walk one cycle by hand from the Coordinator terminal, following the target repo's `OFFICE.md`. Done means: one Task dispatched under its Role's person name, one `worker_done` waited for, `check-writes.sh` run on the delivery, the Worker settled, the delivery landed on that Role's integration branch, and that branch closed the way its Review setting says - for an `auto` Role, `gate.sh` run for real before any reviewer is invoked. The generated cycle is the only part of this design that can really fail, and this is the step that tests it.

## The cycle's rules

They live in `templates/OFFICE.md.tmpl` and reach the target repo through the scaffold, which makes it the one place to change them. Read them there before explaining a cycle, rather than reciting from memory: `check-writes.sh` gates a delivery, `pending-merges.sh` gates a cycle, `prepare-worktrees.sh` keeps one standing desk per Role, `integrate.sh` lands one on its Role's integration branch, `gate.sh` builds and tests that branch, `review-integration.sh` closes it with a human review, `merge-integration.sh` is the git half both paths end in, and each carries a rule the dry runs earned.

## Tests

```bash
skills/the-office/tests/e2e.sh
shellcheck -e SC2016,SC2015 skills/the-office/scripts/*.sh skills/the-office/tests/e2e.sh
```

The suite verifies the determinism contract on a synthetic repo. It sets `OFFICE_SKIP_ORCA=1` to run without an Orca runtime; a real install keeps the Orca probes.
