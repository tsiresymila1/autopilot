# autopilot

Drive any goal — a sentence, a brief, a task list, a requirements document — to
committed, reviewed code **autonomously**, on any project in any state.

Every task carries a **gate**: a shell command that returns success only when the task
is genuinely done. No gate, no "done". The gate proves completion; a reviewer subagent
judges quality on top. The engine never stops to ask — it decides, logs the decision,
parks human-only matters in an inbox, and keeps going.

## Quick start

```bash
cd your-repo
autopilot doctor                       # is it ready? what status?
autopilot supervise "add CSV export to the reports page"
```

That's the whole loop: `supervise` keeps a session running (relaunching across quota
resets and transient errors) until it reaches `DONE`, `BLOCKED`, or `STUCK`, and pings you.
Watch it live from a second terminal with `autopilot logs -f`. Prefer to set your options
once? Drop an `.autopilot.env` at the repo root (see [Ease of use](#ease-of-use)).

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
autopilot needs-verify <task.md>    # documented gate bypass → needs-verification + notify
autopilot report <task.md> --state S --did .. --why ..   # per-task report (what/how/why)
autopilot inbox  <task.md> --do .. --why ..              # clear human item (+ notify)
autopilot gate <task.md> [--repo]   # run the task gate (or the repo-wide gate)
autopilot gate-lint <task.md>       # reject a weak / cheatable gate
autopilot scope <task.md> [ref]     # changed files outside the task's ## Allowed Files
autopilot revert <task.md>          # restore only the task's Allowed Files (scoped)
autopilot review <task.md> [ref]    # independent JSON verdict from another model
autopilot event <kind> <title> ..   # push a per-step notification (Telegram/webhook/ntfy)
autopilot docs [status|init]        # the durable-doc quad (committed source of truth)
autopilot logs [what] [-f] [-n N]   # session (default) | supervisor | gate-<id> | journal | ls
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
| **See what would be sent** | add `--print-prompt` — prints the engine prompt and exits; nothing runs. |
| **Limit the run** | add `--max-tasks 3` — stops after N tasks (status `DONE`). |
| **Dirty tree, on purpose** | add `--yes` — runs against uncommitted changes (it won't commit your unrelated work). |

## Project instructions — dictate before it builds

Give autopilot your architecture and rules *before* it starts, and it builds to them
instead of guessing — especially useful for a project from zero.

```bash
autopilot init          # scaffold editable templates (never clobbers filled files)
# → edit CLAUDE.md and docs/autopilot/*.md
autopilot supervise "build the app"
```

`autopilot init` creates:

| File | You put | Who reads it |
|---|---|---|
| `CLAUDE.md` | stack, conventions, boundaries — **how to build** | every subagent, automatically |
| `docs/autopilot/architecture.md` | module layout, boundaries, wiring, data flow | autopilot, Phase 1 |
| `docs/autopilot/requirements.md` | product behaviour, API contracts, security/data rules, roles, **`## Constraints` (project never-do)** | autopilot, Phase 1 |
| `docs/autopilot/backlog.md` | *(optional)* the exact task sequence you want | autopilot, Phase 1 |
| `.autopilot.env` | lang, model, notifier | the CLI |

A **filled** doc is authoritative: autopilot obeys it and only *extends* it — it never
overwrites your decisions. An **empty** one it drafts itself in Phase 1. `autopilot doctor`
reports whether `CLAUDE.md` and the quad are present and suggests `init` when they aren't.
Priority: `CLAUDE.md` (how) → the quad (what) → the goal.

**Project "never do" rules** live in `requirements.md`'s `## Constraints` section — the
committed source of truth. autopilot reads them in Phase 1 and passes them to every builder
alongside its built-in never-do list (no `git push`/`rebase`/`rm -rf`/secrets…), refusing
or parking any task that would violate one.

## Durable docs — the committed source of truth

Every run maintains four **committed** docs under `docs/autopilot/`, each owning a distinct
class of fact. **Autopilot generates and fills them itself in Phase 1** — they are never a
human precondition, so the hands-off "any goal" entry survives. They are namespaced (and
lowercase) so they never collide with the project's own `docs/`; set `AUTOPILOT_DOCS_DIR`
to relocate them.

| Doc | Owns |
|---|---|
| `requirements.md` | product behaviour, API contracts, security/data rules, roles, permissions |
| `architecture.md` | module layout, ownership, provider wiring, service boundaries, data flow |
| `backlog.md` | sequencing, exact tasks, per-task mechanics, gaps — the task list derives from this |
| `test-strategy.md` | coverage classes, risk scenarios, expected checks, verification gaps |
| `memory.md` | *(optional, not gated)* one-line lessons carried between runs |

One fact, one owner: broad docs stay broad, task mechanics live in `backlog.md`. Each task
declares a `## Docs Impact` class (`no-doc` / `backlog-only` / `full-durable`) and the
reviewer enforces it. `autopilot docs status` must be green before execution;
`autopilot docs init` scaffolds the ownership headers (never overwriting a filled doc, and
never touching the project's own `docs/`).

## Reports every human can read

Every task leaves a uniform report, and every human item spells out the action — so you
never have to read a log to know what happened or what you must do.

```bash
# per-task report → .autopilot/reports/<id>.md (gate, commit, files auto-filled)
autopilot report <task.md> --state done \
  --did "what was actually changed" \
  --why "why this change, why this way" \
  --how "the approach: files, subagents, how the gate proved it" \
  --notes "anything deferred or worth knowing"

# clear human item → .autopilot/inbox.md (+ notification)
autopilot inbox <task.md> \
  --do  "the exact action a human must take" \
  --why "why it is blocked / needs a human" \
  --how "concrete steps or the decision to make" \
  --unblocks "what finishing it frees up"
```

Both refuse empty required fields (`--did/--why`, `--do/--why`), so a report is never a
placeholder. The skill calls `report` after every task and `inbox` for every blocked /
needs-human item. `.autopilot/reports/INDEX.md` lists them all; `autopilot status` points
at the reports dir and the inbox.

### Output language

Reports, inbox items, and the run summary come out in the language you pick:

```bash
autopilot supervise "<goal>" --lang fr     # or: export AUTOPILOT_LANG=fr
```

The fixed labels are localized (`## Ce qui a été fait`, `**À faire:**` for `fr`; English is
the default and the fallback for other codes), and the engine is told to write all of its
prose — reports, inbox, journal, summary — in that language too.

## Ease of use

Set your options once per repo in `.autopilot.env` at the repo root, instead of prefixing
every command. The CLI sources it automatically; an inline env var still wins for a one-off.

```bash
# .autopilot.env  (copy from .autopilot.env.example)
: "${AUTOPILOT_LANG:=fr}"
: "${AUTOPILOT_CLAUDE_MODEL:=claude-opus-4-8}"
: "${AUTOPILOT_STREAM:=1}"
# : "${AUTOPILOT_NTFY_TOPIC:=my-topic-abc123}"
```

Then the everyday command is just `autopilot supervise "<goal>"` — model pinned, French
output, live play-by-play, all without a long env prefix. `autopilot doctor` shows the
active language and whether a config file was loaded.

## When the gate can't prove it — documented bypass

Some work is done in code but its real gate can't run here: it needs a live app, an
e2e/browser run, a test account, or a human's eyes. Autopilot never fakes a green gate
and never silently drops the work. The task adds a `## Manual Verification` section (what
a human must check, and the expected result), and:

```bash
autopilot needs-verify <task.md>
```

refuses unless that section exists, marks the task `needs-verification`, appends the steps
to `.autopilot/inbox.md`, and fires a notification. `autopilot status` counts it (`⚠`)
separately from `done`. This is only for a gate that *genuinely cannot* run — a
runnable-but-red gate is `blocked`, not bypassed.

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
`--print-prompt` is handled by the CLI itself: it shows the prompt the engine would
receive and starts nothing (doctor still reports, but cannot block).

**The engine is headless.** `claude -p` prints nothing until the session ends, so a long
`run` shows an empty terminal for minutes — it is working, not hung. `run` now says so and
tees the session to `.autopilot/logs/session-<ts>.log`. Watch it from a second terminal:

```bash
autopilot status            # task states as they land
autopilot logs journal -f   # decisions and gate results
autopilot logs -f           # the session log
```

By default the session log holds only the engine's final message. `AUTOPILOT_STREAM=1`
(needs `jq`) logs a live **play-by-play** instead — every assistant reply, tool call
(`→ Bash: …`), tool result (`← …`), and a final `═══ success · N turns` line — so
`autopilot logs -f` shows what the engine is doing as it does it.

**Stuck detection.** `supervise` relaunches after a crash, but if a session exits clean
without moving anything — no new commit, no status change, no task-state change — it counts
that as a no-op. After `STALL_LIMIT` such sessions (default `2`) it stops with status
`STUCK` (exit 4) instead of relaunching an identical session to the cap. That happens when
the engine keeps concluding the same thing (work already done, or a human decision pending)
without writing a terminal status; the last session output and `.autopilot/inbox.md` say why.

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
- `lib/paths.sh` — the workspace layout, logging, git, and scope checking.
- `lib/project.sh` — project-type detection + the default-gate matrix.
- `lib/gate.sh` — gate extraction, weak-gate detection, reproducible gate runs.
- `lib/doctor.sh` — preflight + project-status detection.
- `lib/supervisor.sh` — relaunch loop across quota resets, with a pid lock + notifications.
- `lib/docs.sh` — the durable-doc quad (status gate + scaffold).
- `lib/review.sh` — the pluggable independent reviewer.
- `lib/engine.sh` — the engine abstraction (Claude skill call vs inlined-skill Codex run).
- `lib/notify.sh` — the notification backends (ntfy first).
- `lib/common.sh` — thin aggregator that sources the modules above.
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
.autopilot/events.log        append-only per-step event feed (what got notified)
.autopilot/logs/             supervisor.log · session-<ts>.log · gate-<id>.log
```

`autopilot status --json` aggregates `state/*` on demand — there is no second copy
of the state to keep in sync. The **committed** durable docs live separately, under
`docs/autopilot/`.

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

## Notifications — walk away, watch every step from your phone

A `supervise` run can span hours and quota resets. You can follow it **step by step** on
Telegram (or a webhook) instead of the terminal — every gate result, verify, review verdict,
each task done **with its full report**, each decision, and the run's terminal state.

### Verbosity

`AUTOPILOT_NOTIFY_LEVEL` controls how much is pushed (every event is always recorded to
`.autopilot/events.log` regardless):

| Level | You get |
|---|---|
| `milestones` | run `DONE`/`BLOCKED`/`STUCK` + anything needing a human |
| `steps` (default) | + every gate, verify, review, and task done — the deterministic per-step feed |
| `verbose` | + each decision and task cut (best-effort, emitted by the engine) |

The per-step feed (`steps`) is emitted **deterministically by the CLI verbs and the
supervisor** — it does not depend on the engine remembering to notify. `verbose` adds the
engine's own decision commentary on top.

### Channels (all configured ones fire — fan-out)

Set these once in `.autopilot.env` (gitignored, so tokens stay out of git):

```bash
AUTOPILOT_NOTIFY_LEVEL=verbose
# Telegram — @BotFather → /newbot for the token; message the bot once, then read the
# chat id from https://api.telegram.org/bot<TOKEN>/getUpdates
AUTOPILOT_TELEGRAM_TOKEN=123456:ABC...
AUTOPILOT_TELEGRAM_CHAT_ID=123456789
# Generic webhook — POST JSON {kind,title,body,task,state,ts}; point at n8n / Make /
# Twilio (WhatsApp) / your own bot
AUTOPILOT_WEBHOOK_URL=https://example.com/hooks/autopilot
# ntfy still works too
AUTOPILOT_NTFY_TOPIC=my-autopilot-a1b2c3
```

Test one: `autopilot event decision "hello" "from autopilot"`. Every channel is best-effort
(a failure never stops the run) and each reports itself; `doctor` lists the active channels
and the level. The Telegram token is never printed by the tool — but keep secrets out of
event bodies, since they reach the webhook. A verbose run of a large queue is a lot of
messages; the desktop popup channel is capped at milestones so your laptop stays quiet.

## Logs, progress, and agent output

Everything a run produces lives under `.autopilot/` (git-ignored):

```
.autopilot/journal.md            every decision, gate result, and action, logged at the
                                 moment it happens. Read this first.
.autopilot/inbox.md              what is waiting on you (decisions, secrets, merges).
.autopilot/plan.md               the Phase-1 decomposition, risks, and execution order.
.autopilot/tasks/NNN-slug.md     the task specs (gate + Allowed Files + steps + NEVER).
.autopilot/state/<id>            per-task state: done | blocked | needs-human.
.autopilot/status                RUNNING | DONE | BLOCKED.
.autopilot/logs/supervisor.log   the supervisor's own log: each session, quota waits.
.autopilot/logs/session-<ts>.log full session output per relaunch — this is where the
                                 subagents' work (builder, reviewer, …) is captured.
.autopilot/logs/gate-<id>.log    the captured output of each gate run.
```

Practical commands:

```bash
autopilot status               # counts + a per-task table (icon, state, title)
autopilot status --json        # same, machine-readable, with a per-task array
autopilot logs                 # the newest session log — what the engine actually did
autopilot logs -f              # follow it live
autopilot logs supervisor -f   # watch relaunches and quota waits
autopilot logs gate-042        # why that gate failed
autopilot logs journal         # the decision journal
autopilot logs ls              # every log, with size and time
sed -n '/^# NNN/,/Done when/p' .autopilot/tasks/042-*.md   # inspect one task's spec + gate
```

`autopilot run` (foreground) streams to your terminal. `autopilot supervise` (background,
survives quota resets) is the one that files the session logs; gate logs are written by
both.

## Engines — Claude or Codex

The skill is plain markdown, so it is not tied to one agent:

```bash
autopilot run "<goal>"                        # Claude (default)
AUTOPILOT_ENGINE=codex autopilot run "<goal>"  # Codex
```

| Engine | How the skill reaches it | Notes |
|---|---|---|
| `claude` (default) | the installed skill, invoked as `/autopilot <goal>` | spawns the bundled subagents (builder, reviewer, …) |
| `codex` | `skill/SKILL.md` is inlined on stdin — Codex has no skill system | no subagents: it performs each role itself, in the same order |

Claude knob: `AUTOPILOT_CLAUDE_MODEL` pins the model (e.g. `claude-opus-4-8`) so a run
is reproducible and can dodge a flaky tier; unset uses the claude CLI's own default.

Codex knobs: `AUTOPILOT_CODEX_MODEL`, `AUTOPILOT_CODEX_EFFORT` (e.g. `xhigh`),
`AUTOPILOT_CODEX_SANDBOX` (default `workspace-write`), `AUTOPILOT_CODEX_APPROVAL`
(default `never`, so an autonomous run never waits on approval). `doctor` reports the
active engine and whether it is usable.

`supervise` classifies why a session ended: a quota block waits for the reset, a
transient server error (5xx / overloaded / execution error) retries in
`TRANSIENT_WAIT` seconds (default `10`), any other non-zero exit retries in 60s.

The checkable steps (`gate-lint`, `gate`, `scope`, `verify`, `revert`, `docs`, `status`)
are CLI verbs, not model behaviour — so they hold identically on either engine. That
combines well with the independent reviewer: run the engine on one model and
`AUTOPILOT_REVIEWER` on the other, and no model reviews its own work.

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
