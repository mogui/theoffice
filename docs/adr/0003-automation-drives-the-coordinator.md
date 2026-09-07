# An Orca automation drives the Coordinator

The Coordinator has to wake up on a cadence, and the two candidates were an Orca automation and a `/loop` in a user terminal. The load-bearing worry was `nested_worker_depth`: at the default of 1 a worker cannot dispatch, so if an automation-launched agent counted as a worker, every Coordinator dispatch would fail with `nested_worker_depth_exceeded` and the whole design would need a different driver. Nothing in the orchestration guide or the automations help mentions the two together, so we probed it instead of assuming.

A `--disabled` probe automation running in an existing workspace ran `run-create`, `task-create` and `worker-start`; the dispatch was accepted (`ok:true`, `state: ready`). An automation run creates no Task or Dispatch of its own, and worker-ness is scoped to an active Dispatch, so the Coordinator is a root. Automation is therefore the driver, and a `/loop` Coordinator stays documented in `OFFICE.md` as a fallback for supervised cycles rather than a second code path.

## Consequences

The probe also settled a rule the Coordinator template must carry. A worker that exits without reporting `worker_done` (`fallbackReason: session_not_reported`) can never be cleared with `worker-release`: it returns `retained / identity_unproven` no matter which terminal calls it, because it is the *worker's* identity that cannot be proven. Such a Dispatch is settled only by `worker-abandon`, which fences it without stopping anything and reports `residualResources` for a human to inspect. So: `worker-release` for settled workers, `worker-abandon` for silent ones, and residuals are never the Coordinator's to clean up.

Two smaller corrections came out of the same run: `run-create` requires `--objective`, and a worker started with `--worktree current` died with `exitCause: operator_close` without reporting - evidence for the rule that every Role always gets its own worktree.
