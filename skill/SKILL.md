---
name: autopilot
description: Take any goal — a sentence, a brief, a task list, a requirements document — and drive it to committed, reviewed code autonomously via a local task queue. Each task is one spec file with an executable gate (a shell command that proves it is done). Adapts to the project status (empty, brownfield, mid-migration), uses spec-kit for specification and specialised subagents for execution, and never stops to ask; it decides on its own, records human-only matters in an inbox, and parks what it cannot finish. Use for hands-off execution of a goal on any project — triggers on "en autonome", "sans t'arrêter", "autopilot", "vas-y jusqu'au bout", "fais tout ça tout seul", "/autopilot".
---

# Autopilot — Any Goal → Committed Code, via a Gated Task Queue

Take any goal and carry it to committed, reviewed code **without asking the user
anything** until it is done — driven by a local task queue where **every task proves
its own completion with a shell command**.

**Run this in the main thread.** You spawn the subagents; a subagent cannot.

## The idea that makes this trustworthy

> **A task is done when its gate passes. Not when it looks done.**

Every task carries a **gate**: an executable shell command that returns success only
when the task is genuinely complete — `npm run build && npm test`, `test -s dist/out.js`,
`grep -q EXPORT src/x.ts && npx tsc --noEmit`. The gate is the objective truth. The
reviewer judges quality on top; the gate judges completion at the bottom. No gate, no
"done".

## The `.agent/` workspace (local, not committed)

```
.agent/
├── run/
│   ├── status                 RUNNING | DONE | BLOCKED  (read by the supervisor)
│   ├── lock                   the supervisor's pid, so two runs never collide
│   └── state/<task-id>        done | blocked | needs-human  (one file per task)
├── queue/NNN-slug.md          one task spec per file (see below)
├── PLAN-SUMMARY.md            the triage that produced the queue
├── PROGRESS.md                detailed journal, appended every session — THE reference
└── HUMAN-INBOX.md             everything awaiting a human action or decision
docs/plans/*.md                plans produced by recon tasks (these ARE committed)
```

Add `.agent/` to `.gitignore`. It is local to the worktree. `autopilot status --json`
aggregates `run/state/*` on demand — do not keep a second copy of the state in sync.

`AUTOPILOT_REVIEWER` selects who reviews: `subagent` (default, same model) or `codex`
(an independent model — the builder cannot approve its own work). The doctor reports it.

### A task spec — `.agent/queue/NNN-slug.md`

```markdown
# NNN — <title>
- **id**: p2-240
- **depends**: p2-230
- **gate**: `npm run build && npm test -- x.test.ts`

## Contexte
<why this task exists, what it touches>

## Allowed Files
- src/auth/reset.ts
- src/auth/reset.test.ts
- src/auth/            # a directory allows anything under it

## Out Of Scope
- src/auth/login.ts
- <behaviour the task must not change>

## Docs Impact
- **class**: no-doc | backlog-only | full-durable
- **owns**: <if full-durable, name each durable doc in scope and the exact fact it owns>

## Étapes
1. <concrete step>
2. ...

## NEVER
- ne pas désactiver un test pour faire passer le gate
- ne pas <interdit d'action spécifique>

## Done when
<plain-language observable, must match what the gate checks>
```

Three mandatory guards, each covering a different failure:

- **`gate`** — a shell command; makes *completion* provable (no gate ⇒ not ready).
- **`## Allowed Files`** — the whitelist of paths the task may touch; makes *scope*
  machine-checkable (`autopilot scope <task.md>` fails if the diff strays outside it).
- **`## NEVER`** — banned *actions* (disabling a test, `@ts-ignore`), not paths.

Allowed Files replaces "don't touch file X" prose: instead of listing what's forbidden
(unbounded), list what's permitted (bounded) — and enforce it objectively.

## Phase 0 — Preflight, then open the workspace

Run the doctor first — it tells you the **project status** so you adapt instead of
assuming a clean brownfield repo:

```bash
autopilot doctor        # or: bash lib/doctor.sh   — prints status: greenfield|brownfield|needs-setup
```

- **`needs-setup`** (not a git repo, or dirty tree) → the run is blocked until a human
  acts, *unless* the goal itself is "set up the project". Do not auto-stash a user's
  unrelated changes; that is theirs. `git init` on an empty dir is safe and allowed.
- **`greenfield`** (empty dir) → skip codebase confrontation; the queue is pure
  construction. Scaffold with the project's own non-interactive tooling (`--yes`).
- **`brownfield`** → confront the codebase before queuing (below).

Then open the workspace:

```bash
mkdir -p .agent/run/state .agent/queue docs/plans
echo RUNNING > .agent/run/status
grep -q '^\.agent/' .gitignore 2>/dev/null || echo '.agent/' >> .gitignore
```

Create `PROGRESS.md` and `HUMAN-INBOX.md` with headers. Append, never rewrite.

| `.agent/run/status` | Meaning for the supervisor |
|---|---|
| `RUNNING` | In progress — or the session died. Relaunch to resume. |
| `DONE` | No executable task left (some may sit in HUMAN-INBOX). Do not relaunch. |
| `BLOCKED` | Hard technical stop, human needed. Do not relaunch. |

## Phase 1 — Triage → the queue

Normalise the goal to a backlog, whatever its shape:

| Goal shape | Do this |
|---|---|
| One sentence | Expand to the concrete deliverables it implies, then queue. |
| A brief / paragraph | Extract each deliverable; one task each. |
| A task list / backlog | Each item → one task (split if it has no single gate). |
| A requirements document | Read it **fully**, then one task per feature; recon tasks for unknowns. |

For **brownfield**, confront the codebase (done / partial / to do — cite evidence for
"done") before queuing so you never re-build what exists.

### The durable-doc quad (committed source of truth)

Before queuing, establish four committed docs under `docs/` — the facts the whole run is
consistent with. **Autopilot generates them itself** from the goal (+ the codebase for
brownfield); they are never a human precondition. Scaffold headers with
`autopilot docs init`, then fill them:

| Doc | Owns |
|---|---|
| `docs/REQUIREMENTS.md` | product behaviour, user-visible requirements, API contracts, security/data rules, roles, permissions, external contracts |
| `docs/ARCHITECTURE.md` | stable module layout, runtime ownership, provider wiring, service boundaries, data-flow shape, top-level responsibility |
| `docs/TASK_BACKLOG.md` | sequencing, exact tasks, per-task mechanics, remaining gaps, future intent — **the queue derives from this** |
| `docs/TEST_STRATEGY.md` | coverage classes, risk scenarios, expected checks, verification gaps |

Rules that keep them trustworthy:

- **One owner per fact.** A fact lives in exactly one doc. Put task ids, slice mechanics
  and per-task test filenames in `TASK_BACKLOG.md`, not in the broad docs.
- **Broad docs stay broad.** Replace stale claims with concise current truth — never
  append implementation narration, proof chronology, or defensive status prose.
- `autopilot docs status` must be green (all four non-empty) before Phase 2. If a task
  would make a durable fact stale but cannot safely touch the owning doc, split it.

Also read `docs/AI_MEMORY.md` if present (committed, optional): one-line lessons from past
runs — gate patterns that worked, recurring blockers, conventions this project taught you.
Let them shape the queue. You append to it in Phase 4.

Each task then declares its `## Docs Impact` class: `no-doc` (internal/refactor/style),
`backlog-only` (only sequencing/status → `TASK_BACKLOG.md`), or `full-durable` (behaviour,
API, architecture, security, data model, ownership, or coverage changed → update every
owning doc it names).

**Use spec-kit for the specification layer** when available (the doctor reports it). If
the `specify` CLI is installed but this project has no spec-kit yet, scaffold it once:
`specify init --here --integration claude --force`. Then, for anything non-trivial:

```
/speckit-specify   → what to build
/speckit-plan      → how, technically
/speckit-tasks     → an ordered task list
```

No spec-kit and no `specify` CLI → decompose plainly into the same ordered task list. Either way, **turn each
task into a queue file** `.agent/queue/NNN-slug.md` and **give each one a gate**.

### Designing the gate (the hard, non-optional part)

Start from the project's default, then tighten to the task:

| Project type | Default gate |
|---|---|
| node | `npm run build --if-present && npm test` |
| python | `python -m pytest -q` |
| rust | `cargo build && cargo test` |
| go | `go build ./... && go test ./...` |
| php | `composer test` |
| static / unknown | no default — design one per task (below) |

Tighten to what the task actually changes: `npm test -- x.test.ts`,
`npx tsc --noEmit && npm run build`. When there is **no test runner**, the gate must
still be an *executable* proof — never "looks done":

- a file/artefact exists and is non-empty: `test -s dist/out.js`
- a symbol is present: `grep -q 'export function foo' src/x.ts`
- it type-checks / lints: `npx tsc --noEmit`, `ruff check .`
- it runs without error: `node scripts/smoke.js`, `curl -fsS localhost:3000/health`

A task without a runnable gate is not ready; add one or split it.

For unknown areas, emit **recon tasks** first: spawn `explorer`/`planner`, and write
their findings to `docs/plans/*.md` (committed — they are durable design docs).

Write `PLAN-SUMMARY.md`: the decomposition, risks, execution order, and the blocking
decisions up front. If `--dry-run`, stop here and report the queue.

## Phase 2 — The execution loop

For each task in dependency order (skip those whose `depends` is not `done`):

1. **Read the task spec** — steps, Allowed Files, NEVER, gate.
2. **Reconnaissance** — if it touches unfamiliar code, spawn `explorer` on those files.
3. **Build** — spawn `builder` with the steps, the **Allowed Files list** (the only files
   it may edit), the NEVER list, and the instruction to write tests and make **the gate**
   pass. Pass the gate command verbatim. Tell the builder: if it needs a file outside
   Allowed Files, it must **stop and report `SCOPE_EXPANSION_REQUIRED`** with the exact
   paths — never edit outside the whitelist.
4. **Enforce scope** — `autopilot scope .agent/queue/NNN-slug.md`.
   - **ok** → continue
   - **violation** → a file changed outside Allowed Files. Either the builder must restore
     it (out-of-scope edit), or, if the file is genuinely needed, apply the
     **scope-expansion protocol** below. Never let an out-of-scope change through.
5. **Run the gate** — execute the shell command.
   - **passes** → the task is objectively done
   - **fails** → back to `builder` with the output; if the cause is unclear spawn `debugger`
7. **Review** — get an independent verdict on the diff (the gate proved completion; the
   reviewer catches what a green gate cannot: security, design, hidden regressions, scope).
   Prefer a **different model than the builder** — real independence beats self-review:
   - Run `autopilot review .agent/queue/NNN-slug.md`.
     - Prints JSON `{status, required_checks_passed, findings[]}` → use that verdict.
     - Exits 10 (no external reviewer configured) → spawn the `reviewer` subagent instead.
   - The reviewer also checks **doc consistency** against the task's `## Docs Impact`:
     durable docs required by a `full-durable` task must be updated and internally
     consistent; a `no-doc` task must not touch durable docs.
   - Map the verdict:
     - `APPROVED` → proceed to Record
     - `CHANGES_REQUESTED` → back to `builder` with the findings, re-run gate, re-review
     - `SCOPE_EXPANSION_REQUIRED` → apply the scope-expansion protocol
     - `RISKY` → mark `blocked`, revert, log, next task
8. **Record**:
   - `echo done > .agent/run/state/<id>` (or `blocked` / `needs-human`)
   - append to `PROGRESS.md`: task id, what was done, gate result, decisions taken
   - commit via `writer` (one task or a small batch)
9. **Guards**:
   - **Gate still red after 2 build attempts** → `blocked`, log why, move on. Looping on
     a gate that will not go green burns budget without converging.
   - **The task needs a human** (a merge decision, an architecture call, a secret to
     rotate) → `needs-human`, write it to `HUMAN-INBOX.md`, move on. Its code may be
     finished; what remains is the human part.

### Scope-expansion protocol

The builder reported `SCOPE_EXPANSION_REQUIRED`, or `autopilot scope` flagged a file
genuinely needed for the task. Decide, do not guess:

- **Concrete, in-scope-of-the-goal path** (e.g. the real owner of a function the task
  must call) → **expand** `## Allowed Files` with that exact path, log the expansion in
  `PROGRESS.md`, re-run the builder. Small, reversible, obvious ⇒ auto-accept.
- **Ambiguous or broad** ("the provider layer", "some config", a whole new module) →
  do **not** auto-expand. Split into a new task with its own Allowed Files + gate, or
  mark `needs-human` if it is an architecture decision.
- **Out-of-scope edit the builder made anyway** (not a real expansion) → have the builder
  restore the file so the diff is clean, then re-check scope.

An expansion widens the whitelist deliberately and on the record. It is never a silent
drift.

### The three task states

| State | Meaning | The loop… |
|---|---|---|
| `done` | Gate passed, reviewed, committed | continues |
| `blocked` | Technically stuck, no autonomous path | logs, moves on |
| `needs-human` | Code may be done; a human action/decision remains | inbox, moves on |

`needs-human` is not failure — it is honest routing. Like a tracking task whose code is
merged but whose sign-off is human.

### Deciding on your own

Ambiguity → answer yourself and log it: the goal/file first, then the codebase's
conventions, then the safe default (reversible, smaller scope, stricter). A decision
that only a human can make (business, security, irreversible) → `needs-human`, never a
guess.

## Phase 3 — Stop conditions

Write the matching `.agent/run/status`:

| Condition | status |
|---|---|
| No task left with unmet dependencies and state ≠ done (remaining are `needs-human`) | `DONE` |
| `--max-tasks` reached | `DONE` |
| Gate suite red on the base and `debugger` could not fix | `BLOCKED` |
| Three tasks `blocked` in a row | `BLOCKED` |

Never build on a base whose gates are red.

## Never do autonomously

Hitting one → the task becomes `needs-human`, the action is never taken:
`git push` · pull request · deploy · `rm -rf` · `git reset --hard` · force push ·
creating accounts · spending money · editing `.env` · rotating or committing a secret.

## Resume after interruption

State is on disk. Relaunching must not restart: read `PROGRESS.md` (decisions stand),
`.agent/run/state/*` (which tasks are done), the queue (the rest). Resume at the first
task not `done` whose dependencies are met. Say it is a resumption.

## Phase 4 — Final report

Lead with what the user must act on, not what shipped:
1. **HUMAN-INBOX** — the decisions and actions now waiting on them. First.
2. **Décisions prises** — where you chose on their behalf (from `PROGRESS.md`).
3. **Blocked** — with what unblocks each.
4. **Shipped** — tasks `done`, commits, gate results.
5. **Repo state** — branch, commits, are the base gates green.

Counts, like the model to emulate: e.g. `77 done · 0 blocked · 1 needs-human`.

Then **append durable lessons to `docs/AI_MEMORY.md`** (committed): a gate pattern that
proved reliable, a blocker that recurred, a convention the codebase enforced. One line
each, "what happened → what to do next time". This is the only state that survives across
projects — `.agent/` is local and thrown away.

## Running past the usage limit

```bash
autopilot supervise "ton objectif ou un fichier"
```
Relaunches after each quota reset, resumes from `.agent/run/state`, holds a pid lock so
two runs never collide, and **pushes a notification on DONE / BLOCKED / relaunch-cap** so
the user can walk away. Set `AUTOPILOT_NTFY_TOPIC` (ntfy) to be pinged on their phone.

## Rules

- **A task ships only when its gate passes.** No gate ⇒ the task is not ready.
- **Never disable a test, lower a threshold, or `@ts-ignore` to force a gate green.** That
  is cheating the one mechanism that makes this trustworthy. A gate that cannot pass
  honestly → `blocked`.
- **Never skip the reviewer** — the gate proves completion, not quality.
- **Never invent scope.** Not in the goal ⇒ not a task. A gap is a HUMAN-INBOX line.
- **Log the decision when you make it**, in `PROGRESS.md`, not at the end.
- Requires a clean git working tree (the doctor enforces this) — commit or stash before
  launching, or pass `--yes` to run against a dirty tree at your own risk.
