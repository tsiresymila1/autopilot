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
curl -fsSL https://raw.githubusercontent.com/tsiresymila/autopilot/main/install.sh | bash
```

From a checkout:

```bash
./install.sh
```

Both symlink the skill into `~/.claude/skills/autopilot`, the CLI into `~/.local/bin`,
and the subagents into `~/.claude/agents` (existing files kept). Idempotent — re-run to
update. The network install clones to `~/.local/share/autopilot`; re-running it pulls the
latest. Env overrides: `AUTOPILOT_REPO` (git url), `AUTOPILOT_DIR` (clone target),
`CLAUDE_HOME`.

## Use

```bash
autopilot doctor [--yes]            # is this project ready? what status?
autopilot run "<goal or file>"      # one session (needs the claude CLI)
autopilot supervise "<goal>"        # relaunch across quota resets until DONE/BLOCKED
autopilot resume                    # resume the run in this repo
autopilot status [--json]           # aggregate task states
autopilot scope <task.md> [ref]     # changed files outside the task's ## Allowed Files
autopilot review <task.md> [ref]    # independent JSON verdict from another model
autopilot docs [status|init]        # the durable-doc quad (committed source of truth)
```

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
- `lib/supervisor.sh` — relaunch loop across quota resets, with a pid lock.
- `lib/common.sh` — shared paths, project-type and default-gate matrix.
- `skill/SKILL.md` — the autonomous engine Claude runs.
- `agents/*.md` — the subagents the engine spawns: `builder`, `reviewer`, `writer`,
  `explorer`, `planner`, `debugger`. Bundled and linked by `install.sh`, so a fresh
  machine has them. Existing files in `~/.claude/agents` are kept, never clobbered.

spec-kit is optional — if present the skill uses `/speckit-specify|plan|tasks`,
otherwise it decomposes the goal plainly. `doctor` tells you which.

State lives in `.agent/` (git-ignored, local to the worktree):

```
.agent/run/status          RUNNING | DONE | BLOCKED
.agent/run/lock            supervisor pid — two runs never collide
.agent/run/state/<id>      done | blocked | needs-human   (one per task)
.agent/queue/NNN-slug.md   task specs (each with a gate + a NEVER list)
.agent/PROGRESS.md         the journal — decisions logged as they are made
.agent/HUMAN-INBOX.md      everything awaiting a human
```

`autopilot status --json` aggregates `run/state/*` on demand — there is no second copy
of the state to keep in sync.

## Scope control — the whitelist is enforced, not suggested

Each task declares `## Allowed Files`: the only paths it may touch. After the builder
runs, `autopilot scope <task.md>` diffs the working tree and **fails if any change
strays outside the whitelist** — the machine-checkable form of "stay in your lane",
borrowed from the dual-model orchestrator pattern. A file genuinely needed but not
listed triggers the **scope-expansion protocol**: concrete paths are added to the
whitelist on the record (logged in `PROGRESS.md`), broad/ambiguous ones become a new
task or `needs-human`. Never a silent drift.

## Never done autonomously

`git push` · pull request · deploy · `rm -rf` · `git reset --hard` · force push ·
creating accounts · spending money · editing `.env` · rotating or committing a secret.
Hitting one turns the task `needs-human` and the action is left for a person.

## Test

```bash
bash test/run.sh
```

Pure bash, no framework. Runs `doctor`/`status` against throwaway fixture repos
(empty, node-clean, node-dirty) and asserts on their output.
