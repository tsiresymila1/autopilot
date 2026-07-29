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
if ls "$HOME/.claude"/commands/speckit-* "$HOME/.claude"/skills/speckit* >/dev/null 2>&1; then
  pass "spec-kit available"
else
  note "spec-kit not found — the skill falls back to plain task decomposition"
fi
command -v claude >/dev/null 2>&1 && pass "claude CLI on PATH" \
                                  || note "claude CLI not on PATH — 'autopilot supervise' will not work"
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
