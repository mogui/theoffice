# `office.config.json` is the only input to the scaffold

The skill's guiding principle is that everything essential must be recreatable from the bootstrap scripts copied into the target repo, yet the model is the thing that knows the repo's real build commands, paths and file contracts. Those two pull apart the moment the model writes prose directly into a generated `SKILL.md`: the scaffold is then only reproducible by re-running an LLM.

We resolve it by making the model author *only* `office.config.json`, and `scaffold.sh` a pure deterministic function from that config to the generated files. Anything a Role needs to know must therefore have a field in the config rather than being improvised in prose. Keep blocks are the single exception to determinism, and `BACKLOG.md` / `DECISIONS.md` are never overwritten once present.

## Consequences

Regeneration is byte-stable and machine-independent, and "installer, not runtime" becomes literally true rather than aspirational. The cost is schema pressure: every new thing a Role must know forces a config field and a `schema_version` decision, and the config will be more verbose than a hand-written skill would be.
