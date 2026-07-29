# autopilot

Drive any goal — a sentence, a brief, a task list, a requirements document — to
committed, reviewed code **autonomously**, on any project in any state.

Every task carries a **gate**: a shell command that returns success only when the task
is genuinely done. No gate, no "done". The gate proves completion; a reviewer subagent
judges quality on top. The engine never stops to ask — it decides, logs the decision,
parks human-only matters in an inbox, and keeps going.

## Install

Over the network (clones the repo, then links):

```bash
curl -fsSL https://raw.githubusercontent.com/tsiresymila1/autopilot/main/install.sh | bash
```

From a checkout:

```bash
./install.sh
```

Both symlink the skill into `~/.claude/skills/autopilot`, the CLI into `~/.local/bin`,
and the subagents into `~/.claude/agents` (existing files kept). Idempotent — re-run to
update. The network install clones to `~/.local/share/autopilot`; re-running it pulls the
latest.

It also sets up two companion tools, best-effort (a failure never blocks the core install):

- **ponytail** — the "lazy senior dev" plugin, installed via `claude plugin` — sharpens
  the builder's restraint.
- **spec-kit** — the `specify` CLI, installed via `uv tool install` — the specification
  layer. Per project, the skill scaffolds it on first use with
  `specify init --here --integration claude --force`. Needs [uv](https://docs.astral.sh/uv).

Skip both with `AUTOPILOT_SKIP_EXTRAS=1`. Env overrides: `AUTOPILOT_REPO` (git url),
`AUTOPILOT_DIR` (clone target), `AUTOPILOT_PONYTAIL_REPO`, `CLAUDE_HOME`.

## Use

```bash
autopilot doctor [--yes]            # is this project ready? what status?
autopilot run "<goal or file>"      # one session (needs the claude CLI)
autopilot supervise "<goal>"        # relaunch across quota resets until DONE/BLOCKED
autopilot resume                    # resume the run in this repo
autopilot status [--json]           # per-task table + counts
autopilot verify <task.md> [ref]    # two-tier proof: scope + task gate + repo gate
autopilot gate <task.md> [--repo]   # run the task gate (or the repo-wide gate)
autopilot gate-lint <task.md>       # reject a weak / cheatable gate
autopilot scope <task.md> [ref]     # changed files outside the task's ## Allowed Files
autopilot revert <task.md>          # restore only the task's Allowed Files (scoped)
autopilot review <task.md> [ref]    # independent JSON verdict from another model
autopilot docs [status|init]        # the durable-doc quad (committed source of truth)
autopilot notify "<title>" "<msg>"  # fire a milestone notification (test the hook)
autopilot update                    # pull the latest version and re-link (alias: upgrade)
```

Update to a newly-pushed version with `autopilot update` — it pulls the install dir and
re-links (new agents, lib, and refreshed extras). Or re-run the curl one-liner.

## Worked example — a project from zero

```bash
mkdir my-app && cd my-app                      # empty dir
export AUTOPILOT_NTFY_TOPIC=my-app-run         # get pinged when it finishes
autopilot doctor                               # → status: greenfield (git init is automatic)
autopilot supervise "a REST API in FastAPI for a todo list: CRUD tasks, \
  SQLite storage, pytest coverage, a /health endpoint"
```

What happens, hands-off:

1. **doctor** sees an empty dir → `greenfield`, runs `git init`.
2. **Phase 1** — writes the durable quad (`docs/REQUIREMENTS.md`, `ARCHITECTURE.md`,
   `TASK_BACKLOG.md`, `TEST_STRATEGY.md`), then a queue of gated tasks under
   `.autopilot/tasks/` (scaffold app → models → CRUD routes → health → tests). Each task gets
   a gate like `python -m pytest -q` and an `## Allowed Files` whitelist.
3. **Phase 2** — for each task: `builder` writes code + tests → `autopilot verify` proves
   it (scope ⊆ Allowed Files + task gate + repo gate all green) → `reviewer` checks quality
   → `writer` commits. Anything only a human can decide → `.autopilot/inbox.md`.
4. **Phase 4** — an ntfy push: `autopilot: DONE`.

Then:

```bash
autopilot status              # per-task table:
#   run status: RUNNING
#   6 done · 0 blocked · 1 needs-human · 1 todo
#
#     ✓  done         001 — Scaffold FastAPI app
#     ⚑  needs-human  006 — Deploy config (needs a secret)
#     ·  todo         007 — Rate limiting
git log --oneline             # one commit per task
cat .autopilot/inbox.md      # what's left for you
```

## Contexts — same engine, different entry

The goal shape decides everything; the commands are the same. Run `autopilot doctor`
first in every case.

| Context | How you start it |
|---|---|
| **Project from zero** | empty dir → `autopilot supervise "describe the whole app"`. doctor = `greenfield`, git init automatic, pure construction. |
| **From a cahier des charges** (spec doc) | `autopilot supervise cahier.md` — it reads the file **fully**, one task per feature, recon tasks for unknowns. |
| **From a one-line goal** | `autopilot run "add CSV export to the reports page"` — expanded into the concrete deliverables it implies. |
| **Existing project** | `cd repo && autopilot run "<goal>"`. doctor = `brownfield`: it confronts the codebase (done / partial / to do) before queuing, so nothing gets rebuilt. |
| **A new feature** | `autopilot run "implement F-101: password reset"` — scoped to that feature's files via `## Allowed Files`. |
| **A bug / debug** | `autopilot run "fix: uploads over 5MB return 500"` — the gate is a failing test that must go green; the `debugger` subagent is spawned when the cause is unclear. |
| **Just plan, don't build** | add `--dry-run` — stops after Phase 1 and shows the queue. |
| **Limit the run** | add `--max-tasks 3` — stops after N tasks (status `DONE`). |
| **Dirty tree, on purpose** | add `--yes` — runs against uncommitted changes (it won't commit your unrelated work). |

## Durable docs — the committed source of truth

Every run maintains four committed docs under `docs/`, each owning a distinct class of
fact. **Autopilot generates and fills them itself in Phase 1** — they are never a human
precondition, so the hands-off "any goal" entry survives.

| Doc | Owns |
|---|---|
| `REQUIREMENTS.md` | product behaviour, API contracts, security/data rules, roles, permissions |
| `ARCHITECTURE.md` | module layout, ownership, provider wiring, service boundaries, data flow |
| `TASK_BACKLOG.md` | sequencing, exact tasks, per-task mechanics, gaps — the queue derives from this |
| `TEST_STRATEGY.md` | coverage classes, risk scenarios, expected checks, verification gaps |

One fact, one owner: broad docs stay broad, task mechanics live in the backlog. Each task
declares a `## Docs Impact` class (`no-doc` / `backlog-only` / `full-durable`) and the
reviewer enforces it. `autopilot docs status` must be green before execution;
`autopilot docs init` scaffolds the ownership headers.

## Independent review — the builder can't approve itself

`AUTOPILOT_REVIEWER` picks who reviews the diff:

| Value | Reviewer | Independence |
|---|---|---|
| `subagent` (default) | a Claude subagent | same model as the builder |
| `codex` | the `codex` CLI | **different model** — real separation |
| *(custom)* | `$AUTOPILOT_REVIEWER_CMD` (reads prompt on stdin, writes JSON) | any model you wire |

`autopilot review <task.md>` returns a strict JSON verdict
(`APPROVED` / `CHANGES_REQUESTED` / `RISKY` / `SCOPE_EXPANSION_REQUIRED`) the loop
branches on deterministically. With no external reviewer configured it exits 10 and the
skill reviews in-session. Borrowed from the dual-model orchestrator; optional, so
autopilot still runs single-model out of the box.

Forwarded to the skill: `--dry-run`, `--max-tasks N`, `--yes`.

Inside a Claude session, `/autopilot <goal>` runs the skill directly.

**Permissions.** Autonomy needs no prompts: `run`, `resume`, and `supervise` launch Claude
with `--permission-mode bypassPermissions`, so the gate commands, git, and edits never
stall waiting for approval. The safety net is autopilot's own rules — the `## NEVER` list,
the `## Allowed Files` scope check, and the "never done autonomously" list below (no push,
deploy, `rm -rf`, secrets…). Downgrade with `PERMISSION_MODE=acceptEdits autopilot run …`
if you'd rather approve each shell command yourself (it will stop and wait).

## Project status — adapts, does not assume

`doctor` classifies the project and the run adapts:

| Status | When | Behaviour |
|---|---|---|
| `greenfield` | empty dir | pure construction, scaffolds with the project's own tooling; `git init` is automatic |
| `brownfield` | git repo, clean tree | confronts the codebase before queuing so nothing is rebuilt |
| `needs-setup` | not a repo, or dirty tree | blocks until a human acts — pass `--yes` to override, never auto-stashes your changes |

## How it works

- `bin/autopilot` — CLI dispatcher (the invocation contract).
- `lib/doctor.sh` — preflight + project-status detection.
- `lib/supervisor.sh` — relaunch loop across quota resets, with a pid lock + notifications.
- `lib/docs.sh` — the durable-doc quad (status gate + scaffold).
- `lib/review.sh` — the pluggable independent reviewer.
- `lib/common.sh` — shared paths, project-type/default-gate matrix, notifications.
- `skill/SKILL.md` — the autonomous engine Claude runs.
- `agents/*.md` — the subagents the engine spawns: `builder`, `reviewer`, `writer`,
  `explorer`, `planner`, `debugger`. Bundled and linked by `install.sh`, so a fresh
  machine has them. Existing files in `~/.claude/agents` are kept, never clobbered.

spec-kit is optional and set up by `install.sh` (the `specify` CLI). When available the
skill uses `/speckit-specify|plan|tasks` (scaffolding a project with
`specify init --here --integration claude --force` on first use); otherwise it decomposes
the goal plainly. `doctor` tells you which.

State lives in `.autopilot/` (git-ignored, local to the worktree):

```
.autopilot/status            RUNNING | DONE | BLOCKED
.autopilot/lock              supervisor pid — two runs never collide
.autopilot/state/<id>        done | blocked | needs-human   (one per task)
.autopilot/tasks/NNN-slug.md task specs (each: gate + ## Allowed Files + ## NEVER)
.autopilot/plan.md           the Phase-1 decomposition
.autopilot/journal.md        decisions + gate provenance, logged as they happen
.autopilot/inbox.md          everything awaiting a human
.autopilot/logs/             supervisor.log + session-<ts>.log (supervise runs)
```

`autopilot status --json` aggregates `state/*` on demand — there is no second copy
of the state to keep in sync.

## Scope control — the whitelist is enforced, not suggested

Each task declares `## Allowed Files`: the only paths it may touch. After the builder
runs, `autopilot scope <task.md>` diffs the working tree and **fails if any change
strays outside the whitelist** — the machine-checkable form of "stay in your lane",
borrowed from the dual-model orchestrator pattern. A file genuinely needed but not
listed triggers the **scope-expansion protocol**: concrete paths are added to the
whitelist on the record (logged in `journal.md`), broad/ambiguous ones become a new
task or `needs-human`. Never a silent drift.

## Robust execution — completion is proven, not claimed

The loop is built from small deterministic CLI verbs, so robustness is tested, not just
described in the skill:

- **Two-tier verification.** A task is done only when `autopilot verify` passes all three:
  scope ⊆ Allowed Files, the **task gate** (this task's narrow proof), and the **repo gate**
  (the project's build + full test suite + lint). A task can't go green by passing its own
  mini-test while breaking the wider repo — the classic narrow-gate blind spot.
- **Weak gates are rejected.** `autopilot gate-lint` refuses a gate that proves nothing —
  `true`, `echo …`, or a bare `test -f` (which passes on an empty file). The gate must be a
  real check: `test -s`, a passing test, `tsc --noEmit`, a smoke run.
- **The base stays green.** The repo gate must pass before a task starts and after each
  commit; autopilot never builds on a red base.
- **Reproducible gate runs.** `autopilot gate` runs from the repo root, captures output to
  `.autopilot/logs/`, and appends provenance (command + exit code) to `journal.md`.
- **Scoped revert.** A rejected task is undone with `autopilot revert` — `git checkout` of
  only its Allowed Files, never a global `reset --hard` — so the tree never carries
  half-done work and unrelated changes are untouched.

## Notifications — you walk away, it pings you

A `supervise` run can span hours and quota resets. When it reaches a terminal state it
fires a notification so you don't have to watch the terminal:

| State | Notified |
|---|---|
| `DONE` | nothing left to do |
| `BLOCKED` | a human is needed (see `.autopilot/inbox.md`) |
| relaunch cap hit | still not done after N relaunches |

The main backend is **ntfy** — push to your phone from anywhere. Pick a topic and
subscribe to it in the ntfy app (or ntfy.sh in a browser):

```bash
export AUTOPILOT_NTFY_TOPIC=my-autopilot-a1b2c3      # required to enable ntfy
# optional:
export AUTOPILOT_NTFY_SERVER=https://ntfy.sh         # self-hosted server if you run one
export AUTOPILOT_NTFY_TOKEN=tk_xxx                   # Bearer auth for private topics
autopilot notify "test" "hello from autopilot"       # fire a test push
```

Backend priority, best-effort (never fails the run): **ntfy** (`AUTOPILOT_NTFY_TOPIC`) →
custom `AUTOPILOT_NOTIFY` command (title/body in `$AUTOPILOT_NOTIFY_TITLE` /
`$AUTOPILOT_NOTIFY_BODY`) → macOS `osascript` → Linux `notify-send` → none. `doctor`
reports which is active.

## Logs, progress, and agent output

Everything a run produces lives under `.autopilot/` (git-ignored):

```
.autopilot/journal.md              the journal — every decision, gate result, and action,
                                logged at the moment it happens. Read this first.
.autopilot/inbox.md           what is waiting on you (decisions, secrets, merges).
.autopilot/plan.md          the Phase-1 decomposition, risks, and execution order.
.autopilot/tasks/NNN-slug.md        the task specs (gate + Allowed Files + steps + NEVER).
.autopilot/state/<id>           per-task state: done | blocked | needs-human.
.autopilot/status               RUNNING | DONE | BLOCKED.
.autopilot/logs/supervisor.log  the supervisor's own log: each session, quota waits.
.autopilot/logs/run-<ts>.log    full session output per relaunch — this is where the
                                subagents' work (builder, reviewer, …) is captured.
```

Practical commands:

```bash
autopilot status               # counts + a per-task table (icon, state, title)
autopilot status --json        # same, machine-readable, with a per-task array
tail -f .autopilot/logs/supervisor.log        # watch a supervise run live
tail -n 200 .autopilot/logs/run-*.log | less  # what an agent actually did last session
cat .autopilot/journal.md          # the decision journal
sed -n '/^# NNN/,/Done when/p' .autopilot/tasks/042-*.md   # inspect one task's spec + gate
```

`autopilot run` (foreground) streams to your terminal. `autopilot supervise` (background,
survives quota resets) is the one that files the `logs/`.

## When a task fails, blocks, or needs you

A task ends in exactly one of three states — visible in `.autopilot/state/<id>` and
counted by `autopilot status`:

| State | Meaning | What to do |
|---|---|---|
| `done` | gate passed, reviewed, committed | nothing |
| `blocked` | gate stayed red after 2 build attempts, or the reviewer flagged it `Risky` (reverted) | read `journal.md` for the reason; fix the blocker, then `autopilot resume` |
| `needs-human` | code may be finished; a human action/decision remains (a merge, an architecture call, a secret to rotate) | do the item in `inbox.md`, then `autopilot resume` |

**Resume is safe and never restarts from scratch.** State is on disk, so relaunching
reads `journal.md` (decisions stand), `state/*` (which tasks are done) and the queue,
then continues at the first task not `done` whose dependencies are met:

```bash
autopilot resume                    # picks up where it stopped, in this repo
autopilot supervise "<same goal>"   # same thing across quota resets (it detects the resume)
```

The interrupted session (crash, quota, Ctrl-C) leaves `.autopilot/status` = `RUNNING`;
the supervisor treats that as "resume me". A pid `lock` prevents two runs colliding.

If the whole run stopped at `BLOCKED` (base gates red, or three tasks blocked in a row),
that is a hard stop: fix the underlying issue, then relaunch.

## Never done autonomously

`git push` · pull request · deploy · `rm -rf` · `git reset --hard` · force push ·
creating accounts · spending money · editing `.env` · rotating or committing a secret.
Hitting one turns the task `needs-human` and the action is left for a person.

## Test

```bash
bash test/run.sh
```

Pure bash, no framework. Spins up throwaway fixture repos and asserts on real output:
project-status detection, the language/default-gate matrix (node/python/rust/go/php/
static/empty), scope enforcement, the durable-doc quad, the independent reviewer, ntfy
notifications, `install.sh` into a fake HOME, and `autopilot update` end-to-end. Every
script also passes `bash -n`.
