# Exactly one Role writes any given path, and the Coordinator owns shared files

Every Role runs in its own worktree and lands through a human merge, so two Roles authorised to write the same path produce conflicts that no amount of coordination prevents. `preflight.sh` computes the intersection of all declared write sets and refuses to scaffold when it is non-empty.

Declared write sets only make the invariant real if the most contested files are declared by someone: manifests, lockfiles, migrations, CI config and changelogs belong to no Role in particular. Those are Coordinator write paths - a Role that needs a new dependency reports it as a Finding, and the Coordinator applies it on `current`, the only place it has write authority.

Write paths are directory prefixes plus optional exact file paths, never globs: intersecting globs cannot be decided reliably in a shell script, and two Roles that want to split one directory by file extension are either one Role or a directory that needs splitting.
