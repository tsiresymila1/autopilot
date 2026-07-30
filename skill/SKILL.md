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

## The `.autopilot/` workspace (local, not committed)

```
.autopilot/
├── status                     RUNNING | DONE | BLOCKED  (read by the supervisor)
├── lock                       the supervisor's pid, so two runs never collide
├── state/<task-id>            done | blocked | needs-human | needs-verification (one per task)
├── tasks/NNN-slug.md          one task spec per file (see below)
├── reports/<task-id>.md       per-task report: what/how/why (autopilot report)
├── reports/INDEX.md           one line per task, newest last
├── plan.md                    the triage that produced the task list
├── journal.md                 detailed journal + gate provenance, appended every session
├── inbox.md                   clear human items: what to do + why (autopilot inbox)
└── logs/                      supervisor.log + session-<ts>.log (supervise runs)
docs/plans/*.md                plans produced by recon tasks (these ARE committed)
```

Add `.autopilot/` to `.gitignore`. It is local to the worktree. `autopilot status --json`
aggregates `state/*` on demand — do not keep a second copy of the state in sync.

**The two locations are fixed. Use these exact files and nothing else.**

`.autopilot/` — the local workspace (gitignored). Exact names, no improvisation:
`status`, `tasks/NNN-slug.md`, `state/<id>`, `reports/<id>.md`, `journal.md`,
`inbox.md`, `plan.md`. Write the inbox with `autopilot inbox` and reports with
`autopilot report` — do **not** hand-create `HUMAN-INBOX.md`, `PLAN-SUMMARY.md`,
`QUEUE.md`, or any other name. Those are not autopilot files.

`docs/autopilot/` — the **committed durable-doc quad, and ONLY the quad**:
`requirements.md`, `architecture.md`, `backlog.md`, `test-strategy.md` (+ optional
`memory.md`). Never put an inbox, a plan, a queue, a summary, or task state here.
If it is not one of those four docs, it does not belong in `docs/autopilot/`.

**`.agent/` (and any other native orchestration dir — `PROGRESS.md`, an old
`QUEUE.md`, a legacy `HUMAN-INBOX.md`) is IGNORED COMPLETELY.** Do not read it, do
not write it, do not migrate from it, do not reference it. Build your task queue
fresh from the goal and the durable docs. Pretend `.agent/` is not there.

The CLI (`autopilot status/report/inbox/verify/…`) only reads `.autopilot/` and
`docs/autopilot/`; anything written elsewhere is invisible to it and to the human.

`AUTOPILOT_REVIEWER` selects who reviews: `subagent` (default, same model) or `codex`
(an independent model — the builder cannot approve its own work). The doctor reports it.

### A task spec — `.autopilot/tasks/NNN-slug.md`

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
mkdir -p .autopilot/state .autopilot/tasks docs/plans
echo RUNNING > .autopilot/status
grep -q '^\.autopilot/' .gitignore 2>/dev/null || printf '.autopilot/\n.autopilot.env\n' >> .gitignore
```

The durable-doc quad under `docs/autopilot/` **is** committed; only the local
`.autopilot/` workspace and the `.autopilot.env` config are ignored.

Create `journal.md` and `inbox.md` with headers. Append, never rewrite.

`.autopilot/status` is the **one required machine contract** — the supervisor and
`autopilot status` read only it. Even if this repo has its own orchestration
layout (`.agent/`, `PROGRESS.md`, a roadmap doc) and you keep human-readable
notes there, you MUST still write `.autopilot/status` and `.autopilot/inbox.md`.
Following the repo's convention does not replace the contract; a run that skips
it is invisible and gets relaunched as a no-op until the supervisor gives up.

| `.autopilot/status` | Meaning for the supervisor |
|---|---|
| `RUNNING` | In progress — or the session died. Relaunch to resume. |
| `DONE` | No executable task left (some may sit in inbox). Do not relaunch. |
| `BLOCKED` | Hard technical stop, human needed. Do not relaunch. |

## Phase 1 — Triage → the task list

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

Before queuing, establish four **committed** docs under `docs/autopilot/` — the facts the
whole run is consistent with. **Autopilot generates them itself** from the goal (+ the
codebase for brownfield); they are never a human precondition. They are namespaced so
they never collide with the project's own `docs/`. Scaffold headers with
`autopilot docs init`, then fill them:

| Doc | Owns |
|---|---|
| `docs/autopilot/requirements.md` | product behaviour, user-visible requirements, API contracts, security/data rules, roles, permissions, external contracts |
| `docs/autopilot/architecture.md` | stable module layout, runtime ownership, provider wiring, service boundaries, data-flow shape, top-level responsibility |
| `docs/autopilot/backlog.md` | sequencing, exact tasks, per-task mechanics, remaining gaps, future intent — **the task list derives from this** |
| `docs/autopilot/test-strategy.md` | coverage classes, risk scenarios, expected checks, verification gaps |

Rules that keep them trustworthy:

- **One owner per fact.** A fact lives in exactly one doc. Put task ids, slice mechanics
  and per-task test filenames in `backlog.md`, not in the broad docs.
- **Broad docs stay broad.** Replace stale claims with concise current truth — never
  append implementation narration, proof chronology, or defensive status prose.
- **Never clobber the project's own docs.** If `docs/architecture.md` already exists and
  is the real owner of a fact, read it and *reference* it; the quad records what autopilot
  maintains. `AUTOPILOT_DOCS_DIR` relocates the quad if the team wants them merged.
- `autopilot docs status` must be green (all four non-empty) before Phase 2. If a task
  would make a durable fact stale but cannot safely touch the owning doc, split it.

Also read `docs/autopilot/memory.md` if present (committed, optional): one-line lessons
from past runs — gate patterns that worked, recurring blockers, conventions this project
taught you. Let them shape the task list. You append to it in Phase 4.

Each task then declares its `## Docs Impact` class: `no-doc` (internal/refactor/style),
`backlog-only` (only sequencing/status → `backlog.md`), or `full-durable` (behaviour,
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
task into a queue file** `.autopilot/tasks/NNN-slug.md` and **give each one a gate**.

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
their findings to `docs/autopilot/plans/*.md` (committed — they are durable design docs).

Write `.autopilot/plan.md`: the decomposition, risks, execution order, and the blocking
decisions up front. If `--dry-run`, stop here and report the task list.

## Phase 2 — The execution loop

For each task in dependency order (skip those whose `depends` is not `done`):

**Base must be green.** Before the first task, and after every commit, the repo gate
(`autopilot gate <task> --repo`) must pass. Never build on a red base — you would not know
which failure is yours.

1. **Read the task spec** — steps, Allowed Files, NEVER, gate.
2. **Lint the gate** — `autopilot gate-lint .autopilot/tasks/NNN-slug.md`. If it rejects the
   gate as weak (a tautology, a bare `test -f`), strengthen the gate *before* building — a
   gate that cannot fail proves nothing.
3. **Reconnaissance** — if it touches unfamiliar code, spawn `explorer` on those files.
4. **Build** — spawn `builder` with the steps, the **Allowed Files list** (the only files
   it may edit), the NEVER list, and the instruction to write tests and make **the gate**
   pass. Pass the gate command verbatim. Tell the builder: if it needs a file outside
   Allowed Files, it must **stop and report `SCOPE_EXPANSION_REQUIRED`** with the exact
   paths — never edit outside the whitelist.
5. **Verify — the two-tier proof.** `autopilot verify .autopilot/tasks/NNN-slug.md`.
   It checks, in order: **scope** (diff ⊆ Allowed Files), the **task gate** (narrow, this
   task's proof), and the **repo gate** (build + full suite + lint — the change must not
   break anything wider). All three must pass.
   - **scope ✗** → out-of-scope edit → builder restores it, or apply the
     **scope-expansion protocol** below. Never let an out-of-scope change through.
   - **task gate ✗** → back to `builder` with the log (`.autopilot/logs/`); if the cause is
     unclear spawn `debugger`.
   - **repo gate ✗** → the change broke the wider build/tests → back to `builder`; this is
     the regression a narrow gate would have hidden.
6. **Review** — an independent verdict on the diff (verify proved completion; the reviewer
   catches what a green gate cannot: security, design, hidden regressions, scope). Prefer a
   **different model than the builder** — real independence beats self-review:
   - Run `autopilot review .autopilot/tasks/NNN-slug.md`.
     - Prints JSON `{status, required_checks_passed, findings[]}` → use that verdict.
     - Exits 10 (no external reviewer configured) → spawn the `reviewer` subagent instead.
   - The reviewer also checks **doc consistency** against the task's `## Docs Impact`:
     durable docs required by a `full-durable` task must be updated and internally
     consistent; a `no-doc` task must not touch durable docs.
   - Map the verdict:
     - `APPROVED` → proceed to Record
     - `CHANGES_REQUESTED` → back to `builder` with the findings, re-verify, re-review
     - `SCOPE_EXPANSION_REQUIRED` → apply the scope-expansion protocol
     - `RISKY` → **`autopilot revert .autopilot/tasks/NNN-slug.md`** (scoped revert —
       restores only the Allowed Files, never a global reset), mark `blocked`, log, next task
7. **Record** — every task leaves a report, no exception:
   - `echo done > .autopilot/state/<id>` (or `blocked` / `needs-human`)
   - **Write the per-task report** so a human can see what happened without reading logs:
     ```
     autopilot report .autopilot/tasks/NNN-slug.md --state done \
       --did "what was actually changed, concretely" \
       --why "why this change, why this way" \
       --how "the approach: files touched, subagents used, how the gate proved it" \
       --notes "anything deferred, risky, or worth knowing next"
     ```
     Write real prose, not placeholders — `--did/--why` are what a teammate reads first.
     It lands in `.autopilot/reports/<id>.md` with the gate, commit, and files auto-filled.
   - append to `journal.md`: task id, gate result, decisions taken (the chronological trail)
   - commit via `writer` (one task or a small batch)
8. **Guards**:
   - **Verify still red after 2 build attempts** → `autopilot revert`, mark `blocked`, then
     write a **clear human item** — never a bare note:
     ```
     autopilot inbox .autopilot/tasks/NNN-slug.md \
       --do "the exact action a human must take" \
       --why "why it is blocked / why it needs a human" \
       --how "concrete steps, commands, or the decision to make" \
       --unblocks "what finishing this frees up"
     ```
   - **The task needs a human** (a merge decision, an architecture call, a secret to
     rotate) → `needs-human`, then the same `autopilot inbox ...` with `--do/--why`. Its
     code may be finished; what remains is the human part — say exactly what and why.

### Scope-expansion protocol

The builder reported `SCOPE_EXPANSION_REQUIRED`, or `autopilot scope` flagged a file
genuinely needed for the task. Decide, do not guess:

- **Concrete, in-scope-of-the-goal path** (e.g. the real owner of a function the task
  must call) → **expand** `## Allowed Files` with that exact path, log the expansion in
  `journal.md`, re-run the builder. Small, reversible, obvious ⇒ auto-accept.
- **Ambiguous or broad** ("the provider layer", "some config", a whole new module) →
  do **not** auto-expand. Split into a new task with its own Allowed Files + gate, or
  mark `needs-human` if it is an architecture decision.
- **Out-of-scope edit the builder made anyway** (not a real expansion) → have the builder
  restore the file so the diff is clean, then re-check scope.

An expansion widens the whitelist deliberately and on the record. It is never a silent
drift.

### The task states

| State | Meaning | The loop… |
|---|---|---|
| `done` | Gate passed, reviewed, committed | continues |
| `blocked` | Technically stuck, no autonomous path | logs, moves on |
| `needs-human` | Code may be done; a human action/decision remains | inbox, moves on |
| `needs-verification` | Code done + committed, but the gate cannot **prove** it here | inbox + notify, moves on |

`needs-human` is not failure — it is honest routing. Like a tracking task whose code is
merged but whose sign-off is human.

### When the gate cannot prove completion — the documented bypass

Some tasks are done in code but their true "it works" gate cannot run in this
headless environment: it needs a live app, an e2e/browser run, a test account, or
a human's eyes (does the data still render identically?). Do **not** fake a green
gate, and do **not** silently drop the work. Instead:

1. Finish and **commit** the code (scope-checked, self-reviewed) as usual.
2. Add a `## Manual Verification` section to the task listing exactly what a human
   must check to confirm completion (the steps, the expected result).
3. Run `autopilot needs-verify <task.md>`. It refuses unless that section exists,
   sets the task `needs-verification`, records the steps to `.autopilot/inbox.md`,
   and fires a notification. The work is surfaced, never silently accepted.

This bypass is only for a gate that *genuinely cannot* run here — never to dodge a
gate that would run but might fail. A runnable-but-red gate is `blocked`, not
`needs-verification`.

### Deciding on your own

Ambiguity → answer yourself and log it: the goal/file first, then the codebase's
conventions, then the safe default (reversible, smaller scope, stricter). A decision
that only a human can make (business, security, irreversible) → `needs-human`, never a
guess.

## Phase 3 — Stop conditions

Write the matching `.autopilot/status`:

| Condition | status |
|---|---|
| No task left with unmet dependencies and state ≠ done (remaining are `needs-human`) | `DONE` |
| The goal is **already complete** on inspection (found done on a branch, nothing executable left) — record the situation and any pending human actions in `inbox.md` | `DONE` |
| `--max-tasks` reached | `DONE` |
| Gate suite red on the base and `debugger` could not fix | `BLOCKED` |
| Three tasks `blocked` in a row | `BLOCKED` |

**Always end a session by writing a terminal status.** Never exit while
`.autopilot/status` still says `RUNNING` because you concluded there was nothing
to do — the supervisor cannot tell that from a crash and will relaunch an
identical, wasted session. If the work is already done or only human decisions
remain, that is `DONE` (with `inbox.md` filled), not `RUNNING`.

Never build on a base whose gates are red.

## Never do autonomously

Hitting one → the task becomes `needs-human`, the action is never taken:
`git push` · pull request · deploy · `rm -rf` · `git reset --hard` · force push ·
creating accounts · spending money · editing `.env` · rotating or committing a secret.

## Resume after interruption

State is on disk. Relaunching must not restart: read `.autopilot/journal.md` (decisions
stand), `.autopilot/state/*` (which tasks are done), `.autopilot/tasks/` (the rest). Resume
at the first task not `done` whose dependencies are met. Say it is a resumption.

## Phase 4 — Final report

Lead with what the user must act on, not what shipped:
1. **`inbox.md`** — the decisions and actions now waiting on them. First.
2. **Décisions prises** — where you chose on their behalf (from `journal.md`).
3. **Blocked** — with what unblocks each.
4. **Shipped** — tasks `done`, commits, gate results.
5. **Repo state** — branch, commits, are the base gates green.

Counts, like the model to emulate: e.g. `77 done · 0 blocked · 1 needs-human`.

Then **append durable lessons to `docs/autopilot/memory.md`** (committed): a gate pattern
that proved reliable, a blocker that recurred, a convention the codebase enforced. One line
each, "what happened → what to do next time". This is the only state that survives across
projects — `.autopilot/` is local and thrown away.

## Running past the usage limit

```bash
autopilot supervise "ton objectif ou un fichier"
```
Relaunches after each quota reset, resumes from `.autopilot/state`, holds a pid lock so
two runs never collide, and **pushes a notification on DONE / BLOCKED / relaunch-cap** so
the user can walk away. Set `AUTOPILOT_NTFY_TOPIC` (ntfy) to be pinged on their phone.

## Rules

- **A task ships only when `autopilot verify` passes** — scope, task gate, and repo gate.
  No gate ⇒ the task is not ready. A green narrow gate on a broken repo is not done.
- **Never disable a test, lower a threshold, or `@ts-ignore` to force a gate green.** That
  is cheating the one mechanism that makes this trustworthy. A gate that cannot pass
  honestly → `blocked`.
- **Never weaken a gate to make it pass** — `gate-lint` rejects tautologies for a reason.
- **Never skip the reviewer** — verify proves completion, not quality.
- **Never invent scope.** Not in the goal ⇒ not a task. A gap is an `inbox.md` line.
- **Log the decision when you make it**, in `.autopilot/journal.md`, not at the end.
- Requires a clean git working tree (the doctor enforces this) — commit or stash before
  launching, or pass `--yes` to run against a dirty tree at your own risk.
