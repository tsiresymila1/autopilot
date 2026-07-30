#!/usr/bin/env bash
# Human-facing writers: a uniform per-task report, and a crystal-clear inbox
# action item. Both enforce a fixed structure so every task leaves the same
# readable trail — what was done, how, why — and every human item says exactly
# what to do and why. Sourced, never executed. Depends on paths.sh + gate.sh.

set -uo pipefail

# ap_report <task-file> <state> <did> <why> [how] [notes]
# Writes .autopilot/reports/<id>.md and appends a line to reports/INDEX.md.
# gate/commit/files are filled from the task + git, so the caller only supplies prose.
ap_report() {
  local task="$1" state="$2" did="$3" why="$4" how="${5:-}" notes="${6:-}"
  local id title gate commit files dir f
  id="$(ap_id_of "$task")"
  title="$(sed -n '1s/^#[[:space:]]*//p' "$task")"; [ -n "$title" ] || title="$id"
  gate="$(ap_gate_of "$task")"
  commit="$(git rev-parse --short HEAD 2>/dev/null || echo '—')"
  files="$(ap_allowed_paths "$task" 2>/dev/null | tr '\n' ' ')"
  dir="$(ap_state_dir)/reports"; mkdir -p "$dir"; f="$dir/$id.md"
  {
    printf '# %s — %s\n\n' "$id" "$title"
    printf -- '- **state:** %s\n' "$state"
    printf -- '- **gate:** `%s`\n' "${gate:-—}"
    printf -- '- **commit:** %s\n' "$commit"
    printf -- '- **files:** %s\n\n' "${files:-—}"
    printf '## What was done\n%s\n\n' "$did"
    printf '## How\n%s\n\n' "${how:-—}"
    printf '## Why\n%s\n\n' "$why"
    [ -n "$notes" ] && printf '## Notes\n%s\n\n' "$notes"
    printf '_logged %s_\n' "$(date '+%Y-%m-%d %H:%M')"
  } > "$f"
  printf -- '- [%s] %s — %s → reports/%s.md\n' "$state" "$id" "$title" "$id" >> "$dir/INDEX.md"
  echo "$f"
}

# ap_inbox_action <task-file> <icon> <action> <why> [how] [unblocks]
# Appends a clear, self-contained human item to .autopilot/inbox.md: what to do,
# why, how, and what it unblocks — so a human can act without reading logs.
ap_inbox_action() {
  local task="$1" icon="$2" action="$3" why="$4" how="${5:-}" unblocks="${6:-}"
  local id title inbox
  id="$(ap_id_of "$task")"
  title="$(sed -n '1s/^#[[:space:]]*//p' "$task")"; [ -n "$title" ] || title="$id"
  inbox="$(ap_inbox)"; mkdir -p "$(dirname "$inbox")"
  [ -s "$inbox" ] || printf '# Autopilot inbox — actions waiting on a human\n' > "$inbox"
  {
    printf '\n### %s %s (%s)\n' "$icon" "$title" "$id"
    printf '**What to do:** %s\n\n' "$action"
    printf '**Why:** %s\n\n' "$why"
    [ -n "$how" ]      && printf '**How:**\n%s\n\n' "$how"
    [ -n "$unblocks" ] && printf '**Unblocks:** %s\n\n' "$unblocks"
    printf '_logged %s_\n' "$(date '+%Y-%m-%d %H:%M')"
  } >> "$inbox"
}
