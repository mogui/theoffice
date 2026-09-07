---
name: the-office
description: "Install an office of Orca agents on a repo: one coordinator plus 3-5 specialised role skills that work a backlog continuously. Use when the user wants to set up multi-agent orchestration on a repo, add or remove a role from an existing office, or asks for 'the office'."
---

# The Office

Install an **office** on a target repo: `office.config.json`, one generated role skill per Role, board files, and the bootstrap scripts that reproduce all of it.

You are an **installer, not a runtime**. Run once, write files, get out of the way. If a work cycle would need you in order to run, the scaffold is wrong: the office's logic belongs in `OFFICE.md`, not in this skill.

Read [SPEC.md](../../SPEC.md) for the schema and the generated tree, [CONTEXT.md](../../CONTEXT.md) for vocabulary, and `docs/adr/` for why the design is shaped this way. Vocabulary matters here: **Role** is the durable definition, **Worker** the ephemeral instance of one, and they are never used interchangeably.

## What you author, and what you must not

You author **`office.config.json`** and nothing else. `scripts/scaffold.sh` is a pure function from that config to every generated file. Never hand-write a role `SKILL.md`, never hand-write `never_writes`, never put in prose what belongs in a config field. If a Role needs to know something the schema cannot express, say so and stop - do not improvise it into a template.

## Flow

### 1. Preflight

```bash
skills/the-office/scripts/preflight.sh <repo-root>
```

It reports the environment, whether orchestration is reachable, the installed skill inventory, and whether an office already exists. If it exits non-zero, fix what it names and re-run; do not work around it.

If `office.config.json` exists, this run is an **update**: read the config, show the roster, ask only what changes. Adding a Role after six months is one question.

### 2. Mandate

Ask one open question: **what does this office produce, and what does "done" mean?** Ask about cadence only if the answer does not imply it.

### 3. Roster proposal

Propose 3-5 Roles in compact blocks. For each: persona, one-sentence mandate, `reads`, `writes`, `skills`, `done`. Say what you excluded and why.

Rules for the proposal:

- Draw `skills` **only** from the inventory preflight found. Never propose a skill that is not installed.
- `writes` is the part that deserves discussion. Exactly one Role writes any given path.
- Shared project files - manifests, lockfiles, migrations, CI config, changelogs - go in `coordinator.writes`, never to a Role.
- At most one Role may hold a tracker-writing skill (`to-tickets`, `to-spec`, `triage`).
- Show the cost of a cycle: roles x cycles/day x ~1.5-2 (re-dispatch for rework) = dispatches/day.
- Say out loud what the cadence implies for merging. Without an `integration_branch` the cycle refuses to dispatch while any delivery is unmerged, so an `hourly` office needs an hourly merger. If the user does not want to be that, propose an `integration_branch`; if they want to hold merge authority absolutely, `on-demand` is the honest cadence. Do not set `integration_branch` silently: it lets the Coordinator merge, and that is the user's call.

Take corrections in prose until the user approves. Do not write anything yet.

### 4. Scaffold

Only after approval. Write `office.config.json`, then:

```bash
skills/the-office/scripts/scaffold.sh <repo-root>
```

It aborts on any preflight failure, carries over every keep block, and never overwrites `OFFICE-LOG.md` or `BACKLOG.md`. Running it twice must change nothing; if it does, that is a bug in the scaffold, not something to paper over.

### 5. Automation

Register the Coordinator's automation, always `--disabled`. Enabling it is a human action - never enable it yourself.

### 6. Dry run

Walk one cycle by hand from the Coordinator terminal, following `OFFICE.md`. The generated cycle is the only part of this design that can really fail, so do not skip this.

## Rules that survive the install

These belong in `OFFICE.md` and you must not contradict them:

- The Coordinator is the only actor on `current`. Every Role runs in its own worktree; `--worktree current` is never an option for a Worker.
- A Role that reports a Finding does not authorise anyone to edit those files. The fix is re-dispatched to the owning Role.
- `worker-release` settles a Worker that reported. A Worker that exited silently is settled with `worker-abandon`, and its residual resources are a human's problem.
- A delivery is a branch, and a delivery that broke its write set never lands.
- Merge authority over the default branch is human, always. An `integration_branch` moves where the Coordinator may merge, never whether a human merges.

## Tests

```bash
skills/the-office/tests/e2e.sh
shellcheck skills/the-office/scripts/*.sh
```

The test suite verifies the determinism contract on a synthetic repo. It sets `OFFICE_SKIP_ORCA=1`, which exists for that purpose only - never set it when installing a real office.
