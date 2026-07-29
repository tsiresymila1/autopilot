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

# --- status aggregation reads run/state/* ------------------------------------
echo "fixture: status aggregation"
mkdir -p "$TMP/st"; cd "$TMP/st"
  git init -q
  mkdir -p .agent/run/state; echo RUNNING > .agent/run/status
  echo done > .agent/run/state/a; echo done > .agent/run/state/b
  echo needs-human > .agent/run/state/c
  out="$("$AP" status --json 2>&1)"
  assert_contains "$out" '"done":2'        "counts 2 done"
  assert_contains "$out" '"needs_human":1' "counts 1 needs-human"
  assert_contains "$out" '"status":"RUNNING"' "reads run status"

# --- scope enforcement: diff must stay within ## Allowed Files ----------------
echo "fixture: scope enforcement"
mkdir -p "$TMP/scope/src/auth"; cd "$TMP/scope"
  git init -q
  echo "a" > src/auth/reset.ts; echo "b" > src/auth/login.ts; echo "c" > README.md
  git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  mkdir -p .agent/queue
  cat > .agent/queue/001-x.md <<'EOF'
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
  out="$("$AP" scope .agent/queue/001-x.md 2>&1)"; code=$?
  assert_contains "$out" "scope ok" "passes when changes are within Allowed Files"
  [ "$code" -eq 0 ] && ok "scope exits 0 in scope" || no "expected exit 0, got $code"
  # out-of-scope change (README.md not allowed)
  echo "c2" > README.md
  out="$("$AP" scope .agent/queue/001-x.md 2>&1)"; code=$?
  assert_contains "$out" "SCOPE VIOLATION" "flags a change outside Allowed Files"
  assert_contains "$out" "README.md"       "names the offending file"
  [ "$code" -eq 2 ] && ok "scope exits 2 on violation" || no "expected exit 2, got $code"

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
cd "$ROOT"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
