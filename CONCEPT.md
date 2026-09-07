---
title: "The Office"
type: idea
tags: [limbo, idea, orca, multi-agent, orchestration, agent-skills, claude-code]
created: 2026-09-03
updated: 2026-09-03
sources: ["The Office.md"]
---

# The Office

Spec (2026-09-01) di una skill generatrice che allestisce un "ufficio" di agenti [[Orca]] su un repo: un coordinatore piu' una piccola rosa di ruoli specializzati che lavorano un backlog in continuo. Stato: spec, nessun codice scritto. Nome skill deciso: `the-office`. Repo dedicato da creare.

Progetto personale di [[Niko Usai]]. Correlato a [[AI Agents]] (pattern orchestrator-workers), [[Claude Code]] (skill come identita' dei ruoli), [[Spec-Driven Development]] e [[Dark Factory]].

## Principio guida

La skill e' un **installer, non un runtime**. Gira una volta (o di nuovo per aggiornare la rosa), scrive file nel repo target e si toglie di mezzo. Da li' in poi lavorano coordinatore e role skill generate. Se un ciclo di lavoro ha bisogno della skill per girare, lo scaffold e' sbagliato: la logica dell'ufficio e' finita nella skill invece che in `OFFICE.md`.

Corollario: l'ufficio e' un repo, non un'installazione. Tutto l'essenziale deve essere ricreabile dagli script di bootstrap, che vengono copiati nel repo (`.office/scripts/`) e non lasciati nella cartella della skill.

## Mapping su Orca

| Concetto ufficio | Primitiva Orca |
|---|---|
| Regional manager (coordinatore) | terminale dell'utente, legato a un Run (`run-create`) |
| Dipendente | role skill committata nel repo + worker lanciato con `worker-start` |
| Assegnazione lavoro | `task-create` + `worker-start` (Task + Dispatch) |
| Consegna | messaggio `worker_done` con `--outcome succeeded|failed` |
| Board / memoria | file versionati: `OFFICE.md`, `BACKLOG.md`, `specs/`, `DECISIONS.md` |
| Heartbeat | `orca automations create`, cron sul prompt del coordinatore |

I worker non hanno memoria tra un dispatch e l'altro: chiudono con `worker_done` e vengono rilasciati. La memoria aziendale e' il repo, non gli agenti.

## Nessun catalogo di ruoli

Esiste un solo skeleton di role skill; i suoi campi definiscono cosa e' un ruolo. La skill legge il mandato dell'ufficio e propone 3-5 ruoli, poi corretti in conversazione. Niente ruoli predefiniti, niente wizard a domande.

Campi dello skeleton:

| Campo | Origine |
|---|---|
| `persona` / `id` | proposto dal mandato |
| `mandate` (una frase) | proposto dal mandato |
| `reads` / `writes` | proposto; la parte che merita discussione |
| `never_writes` | **derivato**: unione dei `writes` di tutti gli altri ruoli. Mai scritto a mano |
| `done` (definition of done) | proposto |
| `agent` / `model` | derivato, editabile in un passaggio finale |

Regole strutturali:
- Ogni ruolo gira sempre nel proprio worktree, senza eccezioni. Il coordinatore e' l'unico attore su `current`.
- **Invariante non negoziabile: esattamente un ruolo scrive un dato path.** Write set sovrapposti sono l'unica vera failure mode del design. `preflight.sh` calcola l'intersezione e rifiuta lo scaffold se non e' vuota.
- Il coordinatore e' dichiarato in `office.config.json` con il proprio `writes` (board file) e partecipa all'invariante. E' l'unico che trasforma i finding riportati dai ruoli in nuovi item di backlog.
- I `SKILL.md` dei ruoli li scrive solo l'installer. Nessun ruolo ha `.claude/skills/**` nei propri `writes`.

## Struttura della skill

- `SKILL.md` - flusso conversazionale
- `templates/` - `role.SKILL.md.tmpl` (unica definizione di ruolo), `OFFICE.md.tmpl`, `BACKLOG.md.tmpl`, `DECISIONS.md.tmpl`
- `scripts/` - `preflight.sh` (orca status, repo target, ufficio gia' presente, overlap write set), `scaffold.sh` (tree, copia template, `git add`, idempotente), `automation.sh` (crea l'automation, sempre `--disabled`)

Divisione del lavoro: gli **script** sono deterministici e identici su ogni macchina; il **modello** riempie solo i template con contesto reale del repo (path, comandi di build/test, contratto file di ogni ruolo). Ogni `SKILL.md` generato ha `name` e `description` scritti perche' un worker risolva la skill da una task spec che la nomina soltanto: e' il meccanismo con cui un worker impara chi e'.

## Flusso

1. **Preflight** - `orca status --json`, repo target, presenza di `office.config.json`. Se l'orchestrazione non e' abilitata ci si ferma: va attivata a mano in Settings > Experimental.
2. **Mandato** - una domanda aperta: cosa produce l'ufficio e cosa significa "done". Cadenza solo se non implicita.
3. **Proposta rosa** - 3-5 ruoli in blocchi compatti, con cosa e' stato escluso e perche'. Mostra il costo di un ciclo: ruoli x cicli/giorno x ~1.5-2 (re-dispatch per rework) = dispatch/giorno. Correzioni in prosa fino ad approvazione.
4. **Scaffold** - solo dopo conferma. Scrive `office.config.json`, `.claude/skills/role-*/SKILL.md`, `.office/scripts/`, `OFFICE.md`, e `BACKLOG.md` / `DECISIONS.md` se assenti. Abortisce su overlap.
5. **Automation** - registrata in Orca sempre `--disabled`. Abilitarla e' un'azione umana.
6. **Dry run** - un ciclo supervisionato guidato a mano dal coordinatore.

Se `office.config.json` esiste gia' il run e' un **update**: legge la config, mostra la rosa, chiede solo cosa cambia. Aggiungere un dipendente dopo sei mesi deve essere una sola domanda.

## office.config.json

Alla radice del repo: `schema_version`, `office`, `mandate`, `cadence` (`on-demand|hourly|daily`), `merge_authority: "human"`, `coordinator.writes`, `roles[]` con `id`, `persona`, `mandate`, `reads`, `writes`, `done`, `agent`, `model`. `never_writes` e' volutamente assente: viene calcolato allo scaffold. E' il file che rende il setup rieditabile invece che rifatto da zero.

## Rigenerazione senza perdita

Ogni role `SKILL.md` e `OFFICE.md` terminano con una sezione `## Notes` delimitata da `<!-- office:keep -->` / `<!-- /office:keep -->`, riportata verbatim a ogni rigenerazione. Tutto il resto e' sovrascrivibile. `BACKLOG.md` e `DECISIONS.md` non vengono mai sovrascritti una volta presenti.

## Ciclo di lavoro generato (in OFFICE.md)

Sequenza: `run-create` -> per ogni ruolo `task-create` (con `--deps` sui task precedenti) + `worker-start --worktree new-child --setup run` -> `check --wait --types worker_done,escalation,question --timeout-ms 900000` -> `worker-release --dispatch`.

Regole del coordinatore da incorporare nel template:
- Ogni task spec nomina la role skill: cosi' il worker sa chi e'. La skill non si passa come flag.
- Un timeout di `check --wait` e' un checkpoint, non un fallimento. I task di coding durano 15-60 minuti: si ripete la check.
- Heartbeat e attivita' del terminale significano vivo, non finito. Non chiudere un worker perche' silenzioso.
- Un ruolo che riporta finding non autorizza il coordinatore a editare quei file: il fix viene ri-dispatchato al ruolo owner dei path.
- Un ruolo che deve leggere il lavoro in corso di un altro lo legge dal suo worktree o dal branch pushato. Nulla e' visibile su `current` finche' non atterra.
- Dopo ogni `worker_done` accettato: `worker-release`, salvo follow-up immediato sullo stesso terminale.
- Merge authority umana.

## Vincoli reali (verificati sulla guida del binario Orca)

- Orchestrazione = feature sperimentale, toggle solo da UI.
- **Nested worker depth = 1** di default: un worker non puo' dispatchare sub-worker (`nested_worker_depth_exceeded`). Tutto il routing sta sul coordinatore. Alzabile a 2 ma il design non deve dipenderne.
- Un `worker_done` per dispatch, poi `worker-release`. I dipendenti non restano su tra un task e l'altro: le persone sono le skill, non i processi.
- Ogni ruolo nel proprio worktree con `--setup run`, altrimenti il checkout e' senza dipendenze. N ruoli = N setup, N branch, N merge: costo accettato per avere una regola sola.
- `new-child` vs `new-top-level` e' solo lineage Orca; la base git e' una scelta separata (senza `--base-branch` si parte dal default del repo).
- Le role skill viaggiano col checkout solo se committate in `.claude/skills/` del repo; quelle in `~/.claude/skills/` restano legate alla macchina.

## Portabilita'

| Layer | Dove vive | Export |
|---|---|---|
| Board file, specs, role skill, `office.config.json`, `.office/scripts/` | repo | git |
| Automations | config Orca locale, per macchina | ricreate da `.office/scripts/automation.sh` |
| Settings sperimentali, nested depth | preferenze desktop | a mano, per macchina |
| Run / Task / Dispatch | DB orchestrazione locale | non esportabile, ne' utile |

`orca skills share` pubblica un bundle dietro link unlisted ma richiede il permesso Settings > Share Skills (off di default) e pubblica l'intera cartella: niente credenziali dentro.

## Aperto

- Repo dedicato da creare, piu' un piccolo progetto per il primo dry run.
- Coordinatore guidato da un'automation Orca o dal `/loop` di [[Claude Code]]? Load-bearing: se il coordinatore gira come agente lanciato da automation, i suoi dispatch potrebbero gia' stare a nested depth 2 e fallire. Da verificare prima di scrivere il template.
- Ambiguita' che un ruolo non riesce a risolvere: non esiste un campo `on_ambiguity`, quindi serve una regola unica in `OFFICE.md`. In un ciclo cron non presidiato non c'e' un umano a cui escalare: la regola ha bisogno di un sink che non sia una persona.
