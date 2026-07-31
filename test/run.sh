#!/usr/bin/env bash
# Pure-bash test harness — no framework. Runs doctor + status against throwaway
# fixture repos in a temp dir, asserts on their output. Exits non-zero on any fail.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AP="$ROOT/bin/autopilot"
pass=0; fail=0
ok()  { printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) no "$3 — got: $1";; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# cd around fixtures in this shell (no subshell) so the pass/fail tally survives.

# --- empty dir → greenfield, and doctor may git-init it under --yes ------------
echo "fixture: empty dir"
mkdir -p "$TMP/empty"; cd "$TMP/empty"
  out="$("$AP" doctor --yes 2>&1)"
  assert_contains "$out" "type: empty"      "detects empty project type"
  assert_contains "$out" "status: greenfield" "reports greenfield status"
  assert_contains "$out" "git initialised"  "git-inits an empty dir under --yes"

# --- node project, clean git → brownfield, default gate present ---------------
echo "fixture: node repo, clean"
mkdir -p "$TMP/node"; cd "$TMP/node"
  echo '{"name":"x","version":"1.0.0"}' > package.json
  git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  out="$("$AP" doctor 2>&1)"
  assert_contains "$out" "type: node"        "detects node project type"
  assert_contains "$out" "npm run build"     "emits node default gate"
  assert_contains "$out" "working tree clean" "sees clean tree"
  assert_contains "$out" "status: brownfield" "reports brownfield status"

# --- dirty tree, no --yes → blocking, exit 3 ---------------------------------
echo "fixture: node repo, dirty, no --yes"
mkdir -p "$TMP/dirty"; cd "$TMP/dirty"
  echo '{"name":"x"}' > package.json
  git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  echo "changed" > package.json
  out="$("$AP" doctor 2>&1)"; code=$?
  assert_contains "$out" "working tree dirty" "flags dirty tree"
  [ "$code" -eq 3 ] && ok "exits 3 (blocked) on dirty tree" || no "expected exit 3, got $code"

# --- status: per-task view from the queue + resolved states ------------------
echo "fixture: status per-task"
mkdir -p "$TMP/st"; cd "$TMP/st"
  git init -q
  mkdir -p .autopilot/state .autopilot/tasks; echo RUNNING > .autopilot/status
  printf '# 001 — Scaffold app\n- **id**: a\n- **gate**: `true`\n' > .autopilot/tasks/001-scaffold.md
  printf '# 002 — Add models\n- **id**: b\n- **gate**: `pytest`\n'   > .autopilot/tasks/002-models.md
  printf '# 003 — Wire routes\n- **id**: c\n'                        > .autopilot/tasks/003-routes.md
  printf '# 004 — Health check\n- **id**: d\n'                       > .autopilot/tasks/004-health.md
  echo done > .autopilot/state/a; echo done > .autopilot/state/b
  echo needs-human > .autopilot/state/c        # d has no state → todo
  out="$("$AP" status 2>&1)"
  assert_contains "$out" "2 done · 0 blocked · 1 needs-human · 0 needs-verification · 1 todo" "counts across queue + states"
  assert_contains "$out" "Scaffold app" "lists a task title"
  assert_contains "$out" "needs-human 003 — Wire routes" "shows the needs-human task with its state"
  assert_contains "$out" "todo        004 — Health check" "shows the untouched task as todo"
  jout="$("$AP" status --json 2>&1)"
  assert_contains "$jout" '"todo":1'                "json carries the todo count"
  assert_contains "$jout" '"id":"a","state":"done"' "json includes per-task entries"
  assert_contains "$jout" '"gate":"pytest"'         "json carries each task's gate"

# --- scope enforcement: diff must stay within ## Allowed Files ----------------
echo "fixture: scope enforcement"
mkdir -p "$TMP/scope/src/auth"; cd "$TMP/scope"
  git init -q
  echo "a" > src/auth/reset.ts; echo "b" > src/auth/login.ts; echo "c" > README.md
  git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  mkdir -p .autopilot/tasks
  cat > .autopilot/tasks/001-x.md <<'EOF'
# 001 — x
- **gate**: `true`
## Allowed Files
- src/auth/reset.ts
- src/auth/          # directory allows anything under it
## Étapes
1. do it
EOF
  # in-scope change (allowed file + under allowed dir)
  echo "a2" > src/auth/reset.ts; echo "n" > src/auth/new.ts
  out="$("$AP" scope .autopilot/tasks/001-x.md 2>&1)"; code=$?
  assert_contains "$out" "scope ok" "passes when changes are within Allowed Files"
  [ "$code" -eq 0 ] && ok "scope exits 0 in scope" || no "expected exit 0, got $code"
  # out-of-scope change (README.md not allowed)
  echo "c2" > README.md
  out="$("$AP" scope .autopilot/tasks/001-x.md 2>&1)"; code=$?
  assert_contains "$out" "SCOPE VIOLATION" "flags a change outside Allowed Files"
  assert_contains "$out" "README.md"       "names the offending file"
  [ "$code" -eq 2 ] && ok "scope exits 2 on violation" || no "expected exit 2, got $code"

# --- gate: lint weak gates, run gates, two-tier verify, scoped revert --------
echo "fixture: gate + verify"
mkdir -p "$TMP/gate/src"; cd "$TMP/gate"
  git init -q
  echo "console.log(1)" > src/app.js; echo "ok" > keep.txt
  git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  # gate-lint rejects weak gates, accepts real ones
  printf '# 1 — x\n- **gate**: `true`\n## Allowed Files\n- src/app.js\n' > weak.md
  "$AP" gate-lint weak.md >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "gate-lint rejects a tautology gate" || no "weak gate not caught"
  printf '# 1 — x\n- **gate**: `test -f src/app.js`\n## Allowed Files\n- src/app.js\n' > weakf.md
  "$AP" gate-lint weakf.md >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "gate-lint rejects 'test -f' without a content check" || no "test -f not caught"
  # inline `# comment` on an Allowed Files line must be stripped, not treated as a path
  printf '# 1 — x\n- **gate**: `test -s src/app.js`\n## Allowed Files\n- src/app.js   # the entrypoint\n' > strong.md
  out="$("$AP" gate-lint strong.md 2>&1)"; [ "$?" -eq 0 ] && ok "gate-lint accepts a real check" || no "strong gate rejected"
  # gate runner: pass and fail, provenance to journal
  "$AP" gate strong.md >/dev/null 2>&1 && ok "gate runs and passes a green gate" || no "green gate failed"
  [ -f .autopilot/journal.md ] && grep -q "gate" .autopilot/journal.md && ok "gate logs provenance to journal" || no "no journal provenance"
  printf '# 2 — y\n- **gate**: `test -s missing.txt`\n## Allowed Files\n- src/app.js\n' > red.md
  "$AP" gate red.md >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "gate reports a red gate as failure" || no "red gate passed"
  # verify: static project (no repo gate) → scope + task gate only
  out="$("$AP" verify strong.md 2>&1)"; [ "$?" -eq 0 ] && ok "verify passes (scope + task gate, repo gate skipped)" || no "verify failed"
  assert_contains "$out" "repo gate skipped" "verify notes no repo gate for a static project"
  # scoped revert: touch two files, revert restores only the Allowed one
  echo "DIRTY" > src/app.js; echo "DIRTY" > keep.txt
  "$AP" revert strong.md >/dev/null 2>&1
  grep -q DIRTY src/app.js && no "revert did not restore the allowed file" || ok "revert restores the Allowed File"
  grep -q DIRTY keep.txt && ok "revert leaves out-of-scope files untouched" || no "revert touched an out-of-scope file"
cd "$ROOT"

# --- needs-verify: documented gate bypass, refused without documentation ------
echo "fixture: needs-verify (documented gate bypass)"
mkdir -p "$TMP/nv"; cd "$TMP/nv"
  git init -q; mkdir -p .autopilot/tasks .autopilot/state
  # no ## Manual Verification section → must refuse, change nothing
  printf '# 9 — conversions\n- **id**: p6-910\n- **gate**: `npx playwright test`\n## Allowed Files\n- src/x.ts\n' > nv.md
  out="$(AUTOPILOT_NTFY_TOPIC="" "$AP" needs-verify nv.md 2>&1)"; code=$?
  [ "$code" -eq 2 ] && ok "needs-verify refuses without ## Manual Verification" || no "expected exit 2, got $code"
  [ -e .autopilot/state/p6-910 ] && no "refused bypass still wrote state" || ok "refused bypass writes no state"
  # with the section → set state, write inbox, count in status
  printf '## Manual Verification\n- open the dashboard\n- numbers match pre-refactor\n' >> nv.md
  out="$(AUTOPILOT_NTFY_TOPIC="" "$AP" needs-verify nv.md 2>&1)"; code=$?
  [ "$code" -eq 0 ] && ok "needs-verify accepts a documented bypass" || no "documented bypass exited $code"
  [ "$(cat .autopilot/state/p6-910 2>/dev/null)" = needs-verification ] && ok "sets state needs-verification" || no "state not set"
  assert_contains "$(cat .autopilot/inbox.md 2>/dev/null)" "Manually verify this task" "records a clear manual item to inbox"
  assert_contains "$(cat .autopilot/inbox.md 2>/dev/null)" "numbers match pre-refactor" "inbox carries the exact steps"
  cp nv.md .autopilot/tasks/009.md
  assert_contains "$("$AP" status 2>&1)" "1 needs-verification" "status tallies needs-verification"
  assert_contains "$("$AP" status --json 2>&1)" '"needs_verification":1' "json carries the needs-verification count"
cd "$ROOT"

# --- report + inbox: uniform human-facing writers -----------------------------
echo "fixture: report + inbox writers"
mkdir -p "$TMP/rep"; cd "$TMP/rep"
  git init -q; echo x > f; git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  printf '# 42 — Convert dashboard\n- **id**: p6-042\n- **gate**: `npm run build`\n## Allowed Files\n- src/d.tsx\n' > rt.md
  # report: required fields enforced
  "$AP" report rt.md --state done >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "report requires --did/--why" || no "missing fields not caught"
  out="$("$AP" report rt.md --state done --did "moved queries to a hook" --why "boundary + caching" --how "added api/useX, ran check:types" --notes "aiProxy deferred" 2>&1)"
  [ "$?" -eq 0 ] && ok "report writes with all fields" || no "report failed"
  rf=".autopilot/reports/p6-042.md"
  assert_contains "$(cat $rf 2>/dev/null)" "## What was done" "report has the What section"
  assert_contains "$(cat $rf 2>/dev/null)" "moved queries to a hook" "report carries the did prose"
  assert_contains "$(cat $rf 2>/dev/null)" "## Why" "report has the Why section"
  assert_contains "$(cat $rf 2>/dev/null)" '**gate:**' "report auto-fills the gate"
  assert_contains "$(cat .autopilot/reports/INDEX.md 2>/dev/null)" "p6-042" "report appends to INDEX"
  # inbox: clear human item with required action + why
  "$AP" inbox rt.md --do "" --why "x" >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "inbox requires --do" || no "empty --do not caught"
  AUTOPILOT_NTFY_TOPIC="" "$AP" inbox rt.md --do "Merge agent/phase-3-4" --why "reviewed, ready; autopilot never merges" --how "git merge --no-ff" --unblocks "tsc root cause" >/dev/null 2>&1
  ib="$(cat .autopilot/inbox.md 2>/dev/null)"
  assert_contains "$ib" "What to do:** Merge agent/phase-3-4" "inbox states the action"
  assert_contains "$ib" "Why:** reviewed, ready"              "inbox states why"
  assert_contains "$ib" "Unblocks:** tsc root cause"          "inbox states what it unblocks"
cd "$ROOT"

# --- output language: fr labels, --lang flag, per-repo config, inline override -
echo "fixture: output language"
mkdir -p "$TMP/lang"; cd "$TMP/lang"
  git init -q; echo x > f; git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  printf '# 7 — Conversion\n- **id**: p6-042\n- **gate**: `npm test`\n## Allowed Files\n- src/d.tsx\n' > lt.md
  # fr labels in the report + inbox
  AUTOPILOT_LANG=fr "$AP" report lt.md --state done --did "fait" --why "raison" >/dev/null 2>&1
  assert_contains "$(cat .autopilot/reports/p6-042.md 2>/dev/null)" "## Ce qui a été fait" "report uses fr labels under AUTOPILOT_LANG=fr"
  AUTOPILOT_NTFY_TOPIC="" AUTOPILOT_LANG=fr "$AP" inbox lt.md --do "merger" --why "prête" >/dev/null 2>&1
  assert_contains "$(cat .autopilot/inbox.md 2>/dev/null)" "**À faire:**" "inbox uses fr labels under AUTOPILOT_LANG=fr"
  # --lang injects a language directive into the engine prompt
  out="$("$AP" run "faire X" --lang de --print-prompt 2>&1)"
  assert_contains "$out" "in de." "--lang adds a language directive to the prompt"
  goal_line="$(printf '%s\n' "$out" | grep '/autopilot')"
  case "$goal_line" in *"--lang"*) no "--lang leaked into the goal";; *) ok "--lang is stripped from the goal";; esac
  # per-repo config sets it; an inline env still wins thanks to the := form
  printf ': "${AUTOPILOT_LANG:=fr}"\n' > .autopilot.env
  assert_contains "$("$AP" doctor 2>&1)"                    "output language: fr" "config .autopilot.env sets the language"
  assert_contains "$(AUTOPILOT_LANG=en "$AP" doctor 2>&1)"  "output language: en" "inline env overrides the config file"
  assert_contains "$("$AP" doctor 2>&1)" "per-repo config loaded" "doctor reports the loaded config"
cd "$ROOT"

# --- independent reviewer: backend dispatch + JSON validation ----------------
echo "fixture: reviewer backend"
mkdir -p "$TMP/rev"; cd "$TMP/rev"
  git init -q
  echo "v1" > f.ts; git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  echo "v2" > f.ts                                   # uncommitted change to review
  printf '# 1 — x\n- **gate**: `true`\n## Allowed Files\n- f.ts\n' > task.md
  # default = subagent → exit 10 (skill reviews in-session)
  "$AP" review task.md >/dev/null 2>&1; [ "$?" -eq 10 ] && ok "subagent default exits 10" || no "expected 10"
  # stub external backend that returns APPROVED
  out="$(AUTOPILOT_REVIEWER=stub AUTOPILOT_REVIEWER_CMD='cat >/dev/null; echo "{\"status\":\"APPROVED\",\"required_checks_passed\":true,\"findings\":[],\"summary\":\"ok\"}"' "$AP" review task.md 2>&1)"
  assert_contains "$out" '"status":"APPROVED"' "external backend verdict passed through"
  # backend returning garbage (no valid status) → error exit
  AUTOPILOT_REVIEWER=stub AUTOPILOT_REVIEWER_CMD='cat >/dev/null; echo "lol no json"' "$AP" review task.md >/dev/null 2>&1
  [ "$?" -ne 0 ] && ok "rejects a verdict with no valid status" || no "expected non-zero on garbage"

# --- project-type + default-gate matrix across languages ---------------------
# marker file → expected type → substring the default gate must contain
echo "fixture: language detection matrix"
run_type_case() {                        # <dir> <marker-file> <type> <gate-substr>
  local d="$TMP/$1"; mkdir -p "$d"; : > "$d/$2"; ( cd "$d" && git init -q )
  cd "$d"
  local out; out="$("$AP" doctor 2>&1)"
  assert_contains "$out" "type: $3" "$1: detects $3"
  if [ -n "$4" ]; then assert_contains "$out" "$4" "$1: default gate for $3"; fi
  cd "$ROOT"
}
run_type_case py1   pyproject.toml   python "pytest"
run_type_case py2   requirements.txt python "pytest"
run_type_case py3   setup.py         python "pytest"
run_type_case rs    Cargo.toml       rust   "cargo test"
run_type_case go1   go.mod           go     "go test"
run_type_case php1  composer.json    php    "composer test"
# a non-toolchain file → static, no default gate (skill designs one per task)
echo "fixture: static project (no toolchain)"
mkdir -p "$TMP/stat"; cd "$TMP/stat"; echo "hi" > index.html; git init -q
  out="$("$AP" doctor 2>&1)"
  assert_contains "$out" "type: static"        "static: detects static type"
  assert_contains "$out" "no default gate"     "static: no default gate, skill designs one"
cd "$ROOT"

# --- durable-doc quad: status gate + idempotent scaffold ---------------------
echo "fixture: durable-doc quad"
mkdir -p "$TMP/quad"; cd "$TMP/quad"; git init -q
  "$AP" docs status >/dev/null 2>&1; [ "$?" -eq 3 ] && ok "status exits 3 when quad missing" || no "expected exit 3"
  out="$("$AP" docs init 2>&1)"
  assert_contains "$out" "scaffolded requirements.md"   "init scaffolds requirements"
  assert_contains "$out" "scaffolded test-strategy.md"  "init scaffolds test-strategy"
  out="$("$AP" docs status 2>&1)"; code=$?
  assert_contains "$out" "quad complete" "status reports complete after init"
  assert_contains "$out" "docs/autopilot/requirements.md" "status reports the namespaced path"
  [ "$code" -eq 0 ] && ok "status exits 0 when quad present" || no "expected exit 0, got $code"
  grep -q "Owns:" docs/autopilot/architecture.md && ok "scaffold states each doc's ownership" || no "missing Owns header"
  [ -s docs/autopilot/memory.md ] && ok "init scaffolds optional memory.md" || no "memory.md not scaffolded"
  rm -f docs/autopilot/memory.md; "$AP" docs status >/dev/null 2>&1
  [ "$?" -eq 0 ] && ok "status stays green without memory.md (not gated)" || no "memory.md wrongly gated"
  # idempotent: re-init keeps filled docs
  echo "real content" >> docs/autopilot/requirements.md
  "$AP" docs init >/dev/null 2>&1
  grep -q "real content" docs/autopilot/requirements.md && ok "re-init never clobbers a filled doc" || no "clobbered content"
  # a project's own docs/ is never touched by the namespaced quad
  echo "MINE" > docs/architecture.md; "$AP" docs init >/dev/null 2>&1
  grep -q MINE docs/architecture.md && ok "never collides with the project's own docs/" || no "clobbered project docs"
  # overridable location
  ( cd "$TMP/quad" && AUTOPILOT_DOCS_DIR=documentation "$AP" docs init >/dev/null 2>&1 )
  [ -s documentation/requirements.md ] && ok "AUTOPILOT_DOCS_DIR relocates the quad" || no "override ignored"
cd "$ROOT"

# --- init: scaffold editable project instructions, idempotent ----------------
echo "fixture: autopilot init"
mkdir -p "$TMP/init"; cd "$TMP/init"; git init -q
  out="$("$AP" init 2>&1)"
  assert_contains "$out" "scaffolded CLAUDE.md" "init scaffolds CLAUDE.md"
  assert_contains "$out" "scaffolded architecture.md" "init scaffolds the quad"
  grep -q '^## Boundaries' CLAUDE.md && ok "CLAUDE.md has editable rule sections" || no "CLAUDE.md missing sections"
  grep -q '^## Module layout' docs/autopilot/architecture.md && ok "quad carries fillable prompts" || no "no fill prompts"
  grep -q '^## Constraints' docs/autopilot/requirements.md && ok "project never-do lives in requirements.md (## Constraints)" || no "no Constraints section"
  ! grep -q '^## Never' CLAUDE.md && ok "CLAUDE.md defers constraints to the quad (no duplicate Never)" || no "CLAUDE.md still owns Never"
  [ -s .autopilot.env ] && ok "init scaffolds .autopilot.env" || no ".autopilot.env not created"
  grep -q '^\.autopilot/' .gitignore && ok "init gitignores the workspace" || no "gitignore not updated"
  # idempotent: a human's filled instructions survive a re-init
  printf '# CLAUDE\nmes regles a moi\n' > CLAUDE.md; echo "MON ARCHI" > docs/autopilot/architecture.md
  "$AP" init >/dev/null 2>&1
  grep -q "mes regles a moi" CLAUDE.md && ok "re-init keeps a filled CLAUDE.md" || no "clobbered CLAUDE.md"
  grep -q "MON ARCHI" docs/autopilot/architecture.md && ok "re-init keeps a filled quad doc" || no "clobbered quad"
cd "$ROOT"

# --- install.sh into a throwaway HOME: links skill, cli, agents; no clobber ----
echo "fixture: install.sh"
FAKE="$TMP/home"; mkdir -p "$FAKE/.claude/agents"
echo "MY OWN builder" > "$FAKE/.claude/agents/builder.md"   # pre-existing user file
out="$(HOME="$FAKE" AUTOPILOT_SKIP_EXTRAS=1 bash "$ROOT/install.sh" 2>&1)"
[ -L "$FAKE/.claude/skills/autopilot" ] && ok "install links the skill" || no "skill not linked"
# a STALE dir target (old copied SKILL.md) must be replaced by the symlink, not nested into
STALE="$TMP/stale"; mkdir -p "$STALE/.claude/skills/autopilot"; echo "OLD" > "$STALE/.claude/skills/autopilot/SKILL.md"
HOME="$STALE" AUTOPILOT_SKIP_EXTRAS=1 bash "$ROOT/install.sh" >/dev/null 2>&1
{ [ -L "$STALE/.claude/skills/autopilot" ] && [ "$(readlink "$STALE/.claude/skills/autopilot")" = "$ROOT/skill" ]; } \
  && ok "install replaces a stale skill dir with the live symlink" || no "stale skill dir not replaced (ln nested inside)"
[ -L "$FAKE/.local/bin/autopilot" ]     && ok "install links the CLI"   || no "cli not linked"
[ -L "$FAKE/.claude/agents/reviewer.md" ] && ok "install links a fresh agent" || no "agent not linked"
grep -q "MY OWN builder" "$FAKE/.claude/agents/builder.md" && ok "install never clobbers an existing agent" || no "clobbered user agent"
assert_contains "$out" "kept yours" "reports the kept user agent"
# the linked CLI runs a lib-dependent command through the symlink (catches HERE
# resolution bugs that a bare `help` — which never sources lib — would miss)
sout="$("$FAKE/.local/bin/autopilot" status 2>&1)"
assert_contains "$sout" "run status" "linked CLI resolves lib through the symlink"

# --- update: pulls a new version into the install dir and re-links ------------
echo "fixture: update"
G="git -c user.email=t@t -c user.name=t"
SRC="$TMP/src"; $G clone -q "$ROOT" "$SRC"                 # a repo with all files
cp "$ROOT/bin/autopilot" "$SRC/bin/autopilot"             # ensure SRC has THIS CLI (update cmd)
( cd "$SRC"; $G add -A; $G commit -qm "sync cli" >/dev/null 2>&1 || true )
CLONE="$TMP/inst"; $G clone -q "$SRC" "$CLONE"             # the install dir, now with update cmd
( cd "$SRC"; echo "NEWVER" > UPDATE_MARKER; $G add -A; $G commit -qm "new version" )  # SRC ahead
UHOME="$TMP/uhome"; mkdir -p "$UHOME/.local/bin"
ln -sfn "$CLONE/bin/autopilot" "$UHOME/.local/bin/autopilot"
before="$(git -C "$CLONE" rev-parse --short HEAD)"
uout="$(HOME="$UHOME" AUTOPILOT_SKIP_EXTRAS=1 "$UHOME/.local/bin/autopilot" update 2>&1)"
after="$(git -C "$CLONE" rev-parse --short HEAD)"
[ "$before" != "$after" ] && ok "update pulls the new commit into the install dir" || no "did not advance HEAD"
[ -f "$CLONE/UPDATE_MARKER" ] && ok "update brings in new files" || no "new file missing after update"
assert_contains "$uout" "updated" "reports the version change"
# second run = no-op
uout="$(HOME="$UHOME" AUTOPILOT_SKIP_EXTRAS=1 "$UHOME/.local/bin/autopilot" update 2>&1)"
assert_contains "$uout" "already up to date" "second update is a clean no-op"

# --- logs: resolve and tail the right file ------------------------------------
echo "fixture: logs"
mkdir -p "$TMP/lg/.autopilot/logs"; cd "$TMP/lg"; git init -q
  printf 'SUPERVISOR LINE\n' > .autopilot/logs/supervisor.log
  printf 'SESSION OLD\n'     > .autopilot/logs/session-20260101-000000.log
  printf 'SESSION NEW\n'     > .autopilot/logs/session-20260101-000001.log
  printf 'GATE OUTPUT\n'     > .autopilot/logs/gate-042.log
  printf '# journal\nJOURNAL LINE\n' > .autopilot/journal.md
  assert_contains "$("$AP" logs 2>/dev/null)"           "SESSION NEW"     "logs defaults to the newest session log"
  assert_contains "$("$AP" logs supervisor 2>/dev/null)" "SUPERVISOR LINE" "logs supervisor resolves supervisor.log"
  assert_contains "$("$AP" logs gate-042 2>/dev/null)"   "GATE OUTPUT"     "logs gate-042 resolves that gate's log"
  assert_contains "$("$AP" logs journal 2>/dev/null)"    "JOURNAL LINE"    "logs journal reads the decision journal"
  assert_contains "$("$AP" logs ls 2>/dev/null)"         "session-2026"    "logs ls lists the log files"
  "$AP" logs nosuchthing >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "logs errors on an unknown target" || no "expected failure"
cd "$ROOT"

# --- engine: claude by default, codex inlines the skill, bogus is rejected -----
echo "fixture: engine"
mkdir -p "$TMP/eng"; cd "$TMP/eng"; git init -q
  # prompt building, checked directly against the library
  pf="$TMP/eng/p.txt"
  ( . "$ROOT/lib/common.sh"; ap_engine_prompt "do the thing" "$pf" )
  assert_contains "$(cat "$pf")" "/autopilot do the thing" "claude engine prompt invokes the skill"
  ( . "$ROOT/lib/common.sh"; AUTOPILOT_ENGINE=codex ap_engine_prompt "do the thing" "$pf" )
  assert_contains "$(cat "$pf")" "gate"          "codex engine prompt inlines the skill text"
  assert_contains "$(cat "$pf")" "do the thing"  "codex engine prompt carries the goal"
  assert_contains "$(cat "$pf")" "no Claude subagents" "codex prompt tells it to do the roles itself"
  # an unknown engine is refused before anything runs
  out="$(AUTOPILOT_ENGINE=bogus "$AP" run "x" 2>&1)"; code=$?
  assert_contains "$out" "unknown AUTOPILOT_ENGINE" "an unknown engine is rejected"
  [ "$code" -ne 0 ] && ok "run exits non-zero on an unknown engine" || no "expected non-zero"
  # doctor names the active engine
  assert_contains "$("$AP" doctor 2>&1)" "engine:" "doctor reports the active engine"
  # --dry-run shows the prompt and starts nothing (no session log, no state)
  out="$("$AP" run "phase 6" --print-prompt 2>&1)"; code=$?
  [ "$code" -eq 0 ] && ok "--print-prompt exits 0" || no "--print-prompt exited $code"
  assert_contains "$out" "engine NOT started"  "--print-prompt says it started nothing"
  assert_contains "$out" "/autopilot phase 6"  "--print-prompt prints the engine prompt"
  [ -z "$(ls .autopilot/logs 2>/dev/null)" ] && ok "--print-prompt writes no session log" || no "session log written"
  # --print-prompt is CLI-only: it must NOT leak into the engine prompt; real flags do
  out="$("$AP" run "phase 6" --print-prompt --dry-run 2>&1 | grep '/autopilot')"
  case "$out" in *--print-prompt*) no "--print-prompt leaked into the prompt";; *) ok "--print-prompt stripped from the prompt";; esac
  assert_contains "$out" "--dry-run" "real flags stay forwarded to the skill"
  # model pin: AUTOPILOT_CLAUDE_MODEL must reach the claude CLI as --model.
  # A stub `claude` on PATH records its args; unset = no --model at all.
  stub="$TMP/eng/bin"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/claude.args"\n' "$TMP/eng" > "$stub/claude"
  chmod +x "$stub/claude"; echo "hi" > "$pf"
  ( . "$ROOT/lib/common.sh"; PATH="$stub:$PATH" AUTOPILOT_CLAUDE_MODEL=claude-opus-4-8 ap_engine_exec "$pf" )
  assert_contains "$(cat "$TMP/eng/claude.args")" "--model" "pin passes --model to claude"
  assert_contains "$(cat "$TMP/eng/claude.args")" "claude-opus-4-8" "pin passes the model id"
  ( . "$ROOT/lib/common.sh"; PATH="$stub:$PATH" ap_engine_exec "$pf" )
  case "$(cat "$TMP/eng/claude.args")" in *--model*) no "--model sent when no pin set";; *) ok "no --model when pin unset";; esac
  # stream formatter: turn claude stream-json into readable play-by-play lines
  if command -v jq >/dev/null 2>&1; then
    sj="$TMP/eng/stream.jsonl"
    printf '%s\n' \
      '{"type":"system","subtype":"hook_started"}' \
      '{"type":"assistant","message":{"content":[{"type":"text","text":"Investigating"},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}' \
      '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"1548 passing"}]}]}}' \
      '{"type":"result","subtype":"success","num_turns":3,"total_cost_usd":0.42}' > "$sj"
    fmt="$( . "$ROOT/lib/common.sh"; ap_stream_format < "$sj" )"
    assert_contains "$fmt" "Investigating"   "stream formatter shows assistant text"
    assert_contains "$fmt" "→ Bash"          "stream formatter shows the tool call"
    assert_contains "$fmt" "← 1548 passing"  "stream formatter shows the tool result"
    assert_contains "$fmt" "success · 3 turns" "stream formatter shows the final summary"
    case "$fmt" in *hook_started*) no "stream formatter leaked hook noise";; *) ok "stream formatter drops hook noise";; esac
  fi
cd "$ROOT"

# --- supervisor: a no-op session loop is caught, not relaunched to the cap -----
echo "fixture: supervisor stall detection"
mkdir -p "$TMP/stall"; cd "$TMP/stall"
  git init -q; echo x > f; git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  # a stub engine that exits 0 and changes NOTHING — the pathological no-op run
  stub="$TMP/stall/bin"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"; chmod +x "$stub/claude"
  out="$(PATH="$stub:$PATH" STALL_LIMIT=2 MAX_RELAUNCH=10 AUTOPILOT_NTFY_TOPIC="" \
         bash "$ROOT/lib/supervisor.sh" "do nothing" 2>&1)"; code=$?
  assert_contains "$out" "stuck" "supervisor detects a stalled no-op loop"
  [ "$code" -eq 4 ] && ok "supervisor exits 4 (stuck), not the relaunch cap" || no "expected exit 4, got $code"
  case "$out" in *"session 10/10"*) no "reached the relaunch cap instead of stopping early";; *) ok "stops early, well before the cap";; esac
  # the workspace contract must exist even though the stub engine wrote nothing
  [ "$(cat .autopilot/status 2>/dev/null)" = RUNNING ] && ok "supervisor scaffolds status=RUNNING up front" || no "status not scaffolded"
  { [ -d .autopilot/tasks ] && [ -d .autopilot/state ]; } && ok "supervisor scaffolds the tasks/state dirs" || no "workspace dirs missing"
cd "$ROOT"

# --- supervisor: transient 5xx retries fast, not on the 60s generic path ------
echo "fixture: supervisor transient-error classification"
  re='5[0-9]{2} .*(internal server|server error)|overloaded|Execution error|API Error: 5[0-9]{2}'
  echo 'API Error: 500 Internal server error.' | grep -qiE "$re" && ok "500 classed transient" || no "500 missed"
  echo 'Retryable overloaded_error' | grep -qiE "$re" && ok "overloaded classed transient" || no "overloaded missed"
  echo 'Execution error' | grep -qiE "$re" && ok "execution error classed transient" || no "exec error missed"
  echo 'TypeError: undefined is not a function' | grep -qiE "$re" && no "real bug misclassed transient" || ok "a genuine failure is not transient"

# --- notifications -----------------------------------------------------------
echo "fixture: notifications"
mkdir -p "$TMP/notif"; cd "$TMP/notif"; git init -q
  # custom hook receives title + body
  hook="$TMP/notif/got.txt"
  out="$(AUTOPILOT_NOTIFY="printf '%s|%s' \"\$AUTOPILOT_NOTIFY_TITLE\" \"\$AUTOPILOT_NOTIFY_BODY\" > '$hook'" \
        "$AP" notify "T1" "B1" 2>&1)"
  assert_contains "$out" "notified via AUTOPILOT_NOTIFY" "reports the custom hook fired"
  [ -f "$hook" ] && assert_contains "$(cat "$hook")" "T1|B1" "hook receives title and body" || no "hook not invoked"
  # fan-out: ntfy AND the custom hook both fire now (not first-match)
  out="$(AUTOPILOT_NTFY_TOPIC=mytopic AUTOPILOT_NTFY_SERVER=http://127.0.0.1:1 \
        AUTOPILOT_NOTIFY="true" "$AP" notify "T" "B" 2>&1)"
  assert_contains "$out" "ntfy"               "ntfy channel fires when a topic is set"
  assert_contains "$out" "AUTOPILOT_NOTIFY"   "fan-out: the custom hook also fires alongside ntfy"
  # doctor advertises the ntfy backend
  dout="$(AUTOPILOT_NTFY_TOPIC=mytopic "$AP" doctor 2>&1)"
  assert_contains "$dout" "notifications via ntfy" "doctor reports the ntfy backend"
cd "$ROOT"

# --- rich per-step: telegram + webhook fan-out, level filter, event verb ------
echo "fixture: per-step events (telegram + webhook + level)"
mkdir -p "$TMP/evt"; cd "$TMP/evt"; git init -q
  # stub curl on PATH: capture argv only (no stdin read → never blocks), always succeed
  stub="$TMP/evt/bin"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/curl.cap"\nexit 0\n' "$TMP/evt" > "$stub/curl"
  chmod +x "$stub/curl"
  TOK=SECRETTOK123
  # 1. fan-out: telegram + webhook both fire on a verbose decision; token never echoed
  : > curl.cap
  out="$(PATH="$stub:$PATH" AUTOPILOT_TELEGRAM_TOKEN=$TOK AUTOPILOT_TELEGRAM_CHAT_ID=999 \
        AUTOPILOT_WEBHOOK_URL=http://wh AUTOPILOT_NOTIFY_LEVEL=verbose \
        "$AP" event decision "d1 decision" "because reasons" 2>&1)"
  assert_contains "$out" "notified via telegram" "verbose decision pushes to telegram"
  assert_contains "$out" "notified via webhook"  "verbose decision pushes to webhook (fan-out)"
  case "$out" in *"$TOK"*) no "SECURITY: telegram token leaked to stdout";; *) ok "telegram token never echoed";; esac
  assert_contains "$(cat curl.cap)" "api.telegram.org/bot$TOK/sendMessage" "telegram endpoint called"
  assert_contains "$(cat curl.cap)" "chat_id=999" "telegram carries the chat id"
  assert_contains "$(cat curl.cap)" "http://wh"   "webhook URL called"
  # 2. level filter: milestones drops a decision from channels, but events.log still records it
  : > curl.cap
  out="$(PATH="$stub:$PATH" AUTOPILOT_TELEGRAM_TOKEN=$TOK AUTOPILOT_TELEGRAM_CHAT_ID=999 \
        AUTOPILOT_NOTIFY_LEVEL=milestones "$AP" event decision "d2" "x" 2>&1)"
  case "$out" in *"notified via"*) no "milestones level wrongly pushed a decision";; *) ok "milestones level suppresses a decision push";; esac
  assert_contains "$(cat .autopilot/events.log)" "decision" "events.log records the event even when not pushed"
  # 3. a milestone-level kind DOES push at milestones level
  : > curl.cap
  out="$(PATH="$stub:$PATH" AUTOPILOT_TELEGRAM_TOKEN=$TOK AUTOPILOT_TELEGRAM_CHAT_ID=999 \
        AUTOPILOT_NOTIFY_LEVEL=milestones "$AP" event run-done "done!" "finished" 2>&1)"
  assert_contains "$out" "notified via telegram" "milestone kind pushes at milestones level"
  # 4. event verb formats: gate event carries title + emoji in the telegram payload
  : > curl.cap
  PATH="$stub:$PATH" AUTOPILOT_TELEGRAM_TOKEN=$TOK AUTOPILOT_TELEGRAM_CHAT_ID=999 \
    AUTOPILOT_NOTIFY_LEVEL=steps "$AP" event gate "gate pass 001" --state pass >/dev/null 2>&1
  assert_contains "$(cat curl.cap)" "gate pass 001" "gate event payload carries the title"
  # 5. doctor lists telegram + webhook + level, never the token
  dout="$(AUTOPILOT_TELEGRAM_TOKEN=$TOK AUTOPILOT_TELEGRAM_CHAT_ID=999 AUTOPILOT_WEBHOOK_URL=http://wh \
        AUTOPILOT_NOTIFY_LEVEL=verbose "$AP" doctor 2>&1)"
  assert_contains "$dout" "notifications via telegram" "doctor advertises telegram"
  assert_contains "$dout" "notifications via webhook"  "doctor advertises webhook"
  assert_contains "$dout" "notify level: verbose"      "doctor reports the notify level"
  case "$dout" in *"$TOK"*) no "SECURITY: doctor leaked the telegram token";; *) ok "doctor never prints the token";; esac
cd "$ROOT"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
