---
name: the-office
description: "Install an office of Orca agents on a repo: a coordinator plus 3-5 role skills working a backlog. Use when the user wants multi-agent orchestration set up, wants to add or remove a role from an existing office, or asks for 'the office'."
---

# The Office

Install an **office** on a target repo: `office.config.json`, one generated role skill per Role, board files, and the bootstrap scripts that reproduce all of it.

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

### 2. Mandate

Ask one open question: **what does this office produce, and what does "done" mean?** Ask about cadence only if the answer leaves it open.

### 3. Roster proposal

Propose 3-5 Roles in compact blocks: persona, one-sentence mandate, `reads`, `writes`, `skills`, `done`. Say what you excluded and why. Field reference: [SPEC.md](../../SPEC.md) §3.

- Draw `skills` from the inventory preflight found, and only from there.
- `writes` is the part that deserves discussion. Exactly one Role writes any given path.
- Shared project files - manifests, lockfiles, migrations, CI config, changelogs - belong to `coordinator.writes`.
- One Role at most holds a tracker-writing skill (`to-tickets`, `to-spec`, `triage`).
- Price a cycle out loud: roles x cycles/day x ~1.5-2 for rework = dispatches/day.
- Name the **merge pressure** the cadence creates. With no `integration_branch` the cycle refuses to dispatch while a delivery is unmerged, so an `hourly` office needs an hourly merger, and `on-demand` is the honest cadence for someone who wants merge authority whole. An `integration_branch` lets the Coordinator merge, so the user picks it explicitly.

Take corrections in prose. The step ends on the user's approval, and the first file is written after it.

### 4. Scaffold

```bash
skills/the-office/scripts/scaffold.sh <repo-root>
```

Write `office.config.json` first. The scaffold re-runs preflight, carries over every keep block, and leaves `OFFICE-LOG.md` and `BACKLOG.md` alone once they exist. A second run must change nothing: a diff there is a bug in the scaffold.

### 5. Automation

```bash
skills/the-office/scripts/automation.sh <repo-root>
```

Registers the Coordinator's schedule, always disabled, and prints the human actions that remain. Enabling it is one of them.

### 6. Dry run

Walk one cycle by hand from the Coordinator terminal, following the target repo's `OFFICE.md`. Done means: one Task dispatched, one `worker_done` waited for, `check-writes.sh` run on the delivery, and the Worker settled. The generated cycle is the only part of this design that can really fail, and this is the step that tests it.

## The cycle's rules

They live in `templates/OFFICE.md.tmpl` and reach the target repo through the scaffold, which makes it the one place to change them. Read them there before explaining a cycle, rather than reciting from memory: `check-writes.sh` gates a delivery, `pending-merges.sh` gates a cycle, `integrate.sh` lands one, and each carries a rule the dry runs earned.

## Tests

```bash
skills/the-office/tests/e2e.sh
shellcheck -e SC2016,SC2015 skills/the-office/scripts/*.sh skills/the-office/tests/e2e.sh
```

The suite verifies the determinism contract on a synthetic repo. It sets `OFFICE_SKIP_ORCA=1` to run without an Orca runtime; a real install keeps the Orca probes.
