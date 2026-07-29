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
  assert_contains "$out" "2 done · 0 blocked · 1 needs-human · 1 todo" "counts across queue + states"
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
  printf '# 1 — x\n- **gate**: `test -s src/app.js`\n## Allowed Files\n- src/app.js\n' > strong.md
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
  assert_contains "$out" "scaffolded REQUIREMENTS.md" "init scaffolds REQUIREMENTS"
  assert_contains "$out" "scaffolded TEST_STRATEGY.md" "init scaffolds TEST_STRATEGY"
  out="$("$AP" docs status 2>&1)"; code=$?
  assert_contains "$out" "quad complete" "status reports complete after init"
  [ "$code" -eq 0 ] && ok "status exits 0 when quad present" || no "expected exit 0, got $code"
  grep -q "Owns:" docs/ARCHITECTURE.md && ok "scaffold states each doc's ownership" || no "missing Owns header"
  [ -s docs/AI_MEMORY.md ] && ok "init scaffolds optional AI_MEMORY.md" || no "AI_MEMORY not scaffolded"
  rm -f docs/AI_MEMORY.md; "$AP" docs status >/dev/null 2>&1
  [ "$?" -eq 0 ] && ok "status stays green without AI_MEMORY (not gated)" || no "AI_MEMORY wrongly gated"
  # idempotent: re-init keeps filled docs
  echo "real content" >> docs/REQUIREMENTS.md
  "$AP" docs init >/dev/null 2>&1
  grep -q "real content" docs/REQUIREMENTS.md && ok "re-init never clobbers a filled doc" || no "clobbered content"
cd "$ROOT"

# --- install.sh into a throwaway HOME: links skill, cli, agents; no clobber ----
echo "fixture: install.sh"
FAKE="$TMP/home"; mkdir -p "$FAKE/.claude/agents"
echo "MY OWN builder" > "$FAKE/.claude/agents/builder.md"   # pre-existing user file
out="$(HOME="$FAKE" AUTOPILOT_SKIP_EXTRAS=1 bash "$ROOT/install.sh" 2>&1)"
[ -L "$FAKE/.claude/skills/autopilot" ] && ok "install links the skill" || no "skill not linked"
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

# --- notifications -----------------------------------------------------------
echo "fixture: notifications"
mkdir -p "$TMP/notif"; cd "$TMP/notif"
  # custom hook receives title + body
  hook="$TMP/notif/got.txt"
  out="$(AUTOPILOT_NOTIFY="printf '%s|%s' \"\$AUTOPILOT_NOTIFY_TITLE\" \"\$AUTOPILOT_NOTIFY_BODY\" > '$hook'" \
        "$AP" notify "T1" "B1" 2>&1)"
  assert_contains "$out" "notified via AUTOPILOT_NOTIFY" "reports the custom hook fired"
  [ -f "$hook" ] && assert_contains "$(cat "$hook")" "T1|B1" "hook receives title and body" || no "hook not invoked"
  # ntfy takes priority when a topic is set; unreachable server → reported failure, run survives
  out="$(AUTOPILOT_NTFY_TOPIC=mytopic AUTOPILOT_NTFY_SERVER=http://127.0.0.1:1 \
        AUTOPILOT_NOTIFY="true" "$AP" notify "T" "B" 2>&1)"
  assert_contains "$out" "ntfy" "ntfy backend chosen over the custom hook when a topic is set"
  # doctor advertises the ntfy backend
  ( cd "$TMP/notif" && git init -q )
  dout="$(AUTOPILOT_NTFY_TOPIC=mytopic "$AP" doctor 2>&1)"
  assert_contains "$dout" "notifications via ntfy" "doctor reports the ntfy backend"
cd "$ROOT"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
