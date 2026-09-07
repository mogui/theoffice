# The Office

`the-office` is a generator skill: it runs once against a target repo and installs an "office" of Orca agents - one coordinator plus a small roster of specialised roles that work a backlog continuously. The skill is an installer, not a runtime.

## Language

**Office**:
A target repo that has been scaffolded with `office.config.json`, role skills and board files. An office is a repo, not an installation.
_Avoid_: installation, workspace, setup

**Mandate**:
One sentence stating what an office - or a single Role - produces, and what "done" means for it. The single open question the skill asks before proposing a roster.
_Avoid_: charter, mission, goal

**Role**:
A durable job definition: one entry in `office.config.json` plus the `SKILL.md` generated from it. Roles are versioned in the repo and outlive any process.
_Avoid_: employee, dipendente, persona, job

**Worker**:
The ephemeral instance of a Role, launched for exactly one Dispatch and released after `worker_done`. A Worker has no memory of previous Dispatches; the repo is the office's memory.
_Avoid_: employee, dipendente, agent, process

**Coordinator**:
The single actor operating on `current`: it creates Runs and Tasks, dispatches Workers, and turns reported Findings into new backlog items. Declared in `office.config.json` with its own write set, but it is not a Role and is never dispatched.
_Avoid_: regional manager, orchestrator, manager

**Board**:
The versioned files that serve as the office's memory: `OFFICE.md`, `BACKLOG.md`, `DECISIONS.md` and `specs/`.
_Avoid_: state, database, memory

**Write path**:
A directory prefix, or an exact file path, owned by exactly one Role or by the Coordinator. Shared project files (manifests, lockfiles, CI config) are Coordinator write paths.
_Avoid_: glob, pattern, scope

**Write set**:
The complete set of Write paths belonging to one Role. Overlapping write sets across Roles are the design's only true failure mode, and preflight refuses to scaffold when the intersection is non-empty.
_Avoid_: permissions, ownership list

**Never-writes**:
The union of every other Role's Write set. Always derived at scaffold time, never authored, and deliberately absent from `office.config.json`.
_Avoid_: denylist, forbidden paths

**Finding**:
Something a Role discovers outside its own Write set. A Role reports it and stops; only the Coordinator may turn it into a backlog item, and the fix is re-dispatched to the Role that owns those paths.
_Avoid_: issue, bug report, TODO

**Cycle**:
One pass of the Coordinator over the backlog: `run-create`, one Task and Worker per Role, wait, release. The unit in which an office's cost is measured.
_Avoid_: iteration, sprint, tick

**Keep block**:
The region between `<!-- office:keep -->` and `<!-- /office:keep -->` in a generated file, carried over verbatim on every regeneration. Everything outside it is overwritable.
_Avoid_: user section, custom block
