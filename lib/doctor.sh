#!/usr/bin/env bash
# Preflight: report whether the current project is ready for an autonomous run,
# and describe its status so the skill can adapt instead of assuming.
#
# Exit codes:
#   0  ready (possibly greenfield — see PROJECT_STATUS)
#   3  blocked: a human must act first (dirty tree with no --yes, etc.)
#
# Reads --yes from $1 to allow auto-fixing safe, reversible setup (git init).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/common.sh"

AUTO_YES="${1:-}"
ok=0; warn=0; block=0
say() { printf '  %s %s\n' "$1" "$2"; }
pass(){ say '✓' "$1"; ok=$((ok+1)); }
note(){ say '•' "$1"; warn=$((warn+1)); }
stop(){ say '✗' "$1"; block=$((block+1)); }

root="$(ap_root)"
ptype="$(ap_project_type)"
echo "autopilot doctor — $root"
echo
echo "Project"
say '·' "type: $ptype"
gate="$(ap_default_gate "$ptype")"
[ -n "$gate" ] && say '·' "default gate: $gate" \
               || note "no default gate for '$ptype' — the skill must design one per task"

echo
echo "Git"
if ap_in_git; then
  pass "inside a git repository"
  if ap_tree_clean; then
    pass "working tree clean"
  elif [ "$AUTO_YES" = "--yes" ]; then
    note "working tree dirty — proceeding (--yes); autopilot will not commit your unrelated changes"
  else
    stop "working tree dirty — commit or stash first, or pass --yes"
  fi
else
  if [ "$AUTO_YES" = "--yes" ] || [ "$ptype" = "empty" ]; then
    ( cd "$root" && git init -q ) && pass "git initialised (was not a repo)" \
      || stop "git init failed"
  else
    stop "not a git repository — run 'git init' or pass --yes to let autopilot do it"
  fi
fi

echo
echo "Tooling"
missing=""
for a in builder reviewer writer explorer planner debugger; do
  [ -e "$HOME/.claude/agents/$a.md" ] || missing="$missing $a"
done
if [ -z "$missing" ]; then
  pass "subagents present (builder reviewer writer explorer planner debugger)"
else
  note "missing subagents:$missing — run ./install.sh to link them"
fi
if command -v specify >/dev/null 2>&1 || ls "$root/.specify" "$HOME/.claude"/commands/speckit-* >/dev/null 2>&1; then
  pass "spec-kit available (specify CLI or scaffolded)"
else
  note "spec-kit not found — 'uv tool install specify-cli --from git+https://github.com/github/spec-kit.git', or the skill falls back to plain decomposition"
fi
if claude plugin list 2>/dev/null | grep -qi ponytail; then pass "ponytail plugin installed"
else note "ponytail not installed — install.sh sets it up (best-effort)"; fi
if why="$(ap_engine_available)"; then pass "engine: $(ap_engine) (ready)"
else note "engine $(ap_engine) unusable — $why"; fi
[ "$(ap_engine)" = claude ] && command -v codex >/dev/null 2>&1 \
  && say '·' "codex also available — AUTOPILOT_ENGINE=codex runs the skill on it"
say '·' "output language: ${AUTOPILOT_LANG:-en} (reports/inbox/summary) — set AUTOPILOT_LANG or --lang"
[ -f "$root/.autopilot.env" ] && pass "per-repo config loaded (.autopilot.env)" \
  || say '·' "no .autopilot.env — copy .autopilot.env.example to set options once"
# All configured channels fire (fan-out), not just one. Never print the telegram token.
nch=0
[ -n "${AUTOPILOT_NTFY_TOPIC:-}" ]     && { pass "notifications via ntfy (${AUTOPILOT_NTFY_SERVER:-https://ntfy.sh}/$AUTOPILOT_NTFY_TOPIC)"; nch=$((nch+1)); }
if [ -n "${AUTOPILOT_TELEGRAM_TOKEN:-}" ] && [ -n "${AUTOPILOT_TELEGRAM_CHAT_ID:-}" ]; then pass "notifications via telegram (chat $AUTOPILOT_TELEGRAM_CHAT_ID)"; nch=$((nch+1))
elif [ -n "${AUTOPILOT_TELEGRAM_TOKEN:-}" ]; then note "telegram token set but AUTOPILOT_TELEGRAM_CHAT_ID missing"; fi
[ -n "${AUTOPILOT_WEBHOOK_URL:-}" ]     && { pass "notifications via webhook (JSON POST)"; nch=$((nch+1)); }
[ -n "${AUTOPILOT_NOTIFY:-}" ]          && { pass "notifications via AUTOPILOT_NOTIFY hook"; nch=$((nch+1)); }
if [ "$nch" -eq 0 ]; then
  if command -v osascript >/dev/null 2>&1; then pass "notifications via osascript (macOS, local only)"
  elif command -v notify-send >/dev/null 2>&1; then pass "notifications via notify-send (Linux/WSL, local only)"
  elif command -v powershell.exe >/dev/null 2>&1; then pass "notifications via Windows toast (local only)"
  else note "no notifier — set AUTOPILOT_TELEGRAM_TOKEN + _CHAT_ID, AUTOPILOT_WEBHOOK_URL, or AUTOPILOT_NTFY_TOPIC"; fi
fi
say '·' "notify level: ${AUTOPILOT_NOTIFY_LEVEL:-steps} (milestones · steps · verbose)"
rev="${AUTOPILOT_REVIEWER:-subagent}"
if [ "$rev" = subagent ]; then
  note "reviewer: subagent (same model). Set AUTOPILOT_REVIEWER=codex for independent review"
elif [ "$rev" = codex ] && command -v codex >/dev/null 2>&1; then
  pass "reviewer: codex (independent of the builder model)"
elif [ "$rev" = codex ]; then
  note "reviewer=codex but codex not on PATH — will fall back to the subagent"
else
  pass "reviewer: $rev (custom via AUTOPILOT_REVIEWER_CMD)"
fi

echo
echo "Project instructions"
[ -s "$root/CLAUDE.md" ] && pass "CLAUDE.md present (coding rules, read by every subagent)" \
  || note "no CLAUDE.md — 'autopilot init' scaffolds one to state your stack, conventions, boundaries"
ddir="$(ap_docs_dir)"; drel="${ddir#$root/}"
qmiss=0
for d in requirements architecture backlog test-strategy; do
  [ -s "$ddir/$d.md" ] || qmiss=$((qmiss+1))
done
if [ "$qmiss" -eq 0 ]; then pass "durable-doc quad present ($drel)"
else note "$qmiss/4 quad docs missing ($drel) — 'autopilot init' scaffolds editable templates you fill to dictate the project; else autopilot drafts them in Phase 1"; fi

echo
if [ "$ptype" = empty ]; then
  status=greenfield
elif ! ap_in_git && [ "$AUTO_YES" != "--yes" ]; then
  status=needs-setup
else
  status=brownfield
fi
echo "Summary: $ok ok · $warn note · $block blocking   →   status: $status"
export PROJECT_STATUS="$status"

[ "$block" -eq 0 ] || exit 3
exit 0
