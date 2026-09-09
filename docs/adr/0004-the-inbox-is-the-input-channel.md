# Human input reaches the office through a file, not a channel

`OFFICE-INBOX.md` at the repo root is the office's only input channel. Anyone appends an entry in prose; the Coordinator consumes it at step 0 of each cycle - before the merge gate - turns it into backlog items, and answers by moving the entry's `Status`. The scaffold also appends a marked pointer to the target repo's `CLAUDE.md`.

## Why

- **An office with no input channel gets talked over.** Before this, the only way to feed a scaffolded office was to hand-write backlog items in the Coordinator's own write set. The first install hit it immediately: no tickets existed yet, and the honest answer to "how do I ask for something?" was "there is no way".
- **A file is the channel the design already had.** The automation opens a fresh session per cycle: the Coordinator has no memory, and the repo is the office's memory. A chat channel would need a runtime; a file needs the git history that is already there. It also makes the intake auditable - who asked for what, and what it became.
- **Intake before the merge gate**, because the two failure modes are not symmetric: a cycle that dispatches nothing costs nothing, while an input dropped because deliveries were unmerged is lost work the human has to notice and retype.
- **The `CLAUDE.md` pointer is the discovery mechanism**, and a skill is not. A skill has to be invoked by name; `CLAUDE.md` is read unprompted by every session opened in the repo. Without it a session helpfully implements the product work itself, on paths that belong to Roles, and the next delivery is born in conflict.
- **No Role may own the inbox.** A Role able to rewrite the inbox could rewrite what a human asked for, so preflight refuses the config and the scaffold puts the file in every Role's never-writes.

## Consequences

- The Coordinator answers by moving `Status`, never by editing an entry's text: the inbox is a log, and an argument in it would destroy the audit.
- An entry implying a non-reversible decision does not become a backlog item. It comes back as a request for an ADR, because the Coordinator inventing architecture is the failure this whole design exists to prevent.
- The ordering rule became generated content too. A Coordinator that starts from nothing every cycle needs the order stated - urgent inbox entries, then one effort at a time, at most `max_tasks_per_cycle` Tasks, never two on the same Role - or old items sit forever and two Workers of one Role collide on the same write set.
- Round-tripping a question through the inbox costs a cycle. That is the price of having no runtime, and it is why urgent entries jump the queue rather than getting their own mechanism.
