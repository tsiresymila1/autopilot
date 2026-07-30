#!/usr/bin/env bash
# Human-facing writers: a uniform per-task report, and a crystal-clear inbox
# action item. Both enforce a fixed structure so every task leaves the same
# readable trail — what was done, how, why — and every human item says exactly
# what to do and why. Sourced, never executed. Depends on paths.sh + gate.sh.
#
# AUTOPILOT_LANG picks the label language (en | fr; default en). Unknown values
# fall back to English labels — the engine still writes the *prose* in whatever
# language you asked for (it is told to, in the engine prompt).

set -uo pipefail

ap_lang() { echo "${AUTOPILOT_LANG:-en}"; }

# _ap_label <key> — localized section label. One place to add a language.
_ap_label() {
  case "$(ap_lang)" in
    fr) case "$1" in
          state) echo "état";; gate) echo "gate";; commit) echo "commit";; files) echo "fichiers";;
          did) echo "Ce qui a été fait";; how) echo "Comment";; why) echo "Pourquoi";; notes) echo "Notes";;
          logged) echo "consigné le";;
          todo) echo "À faire";; iwhy) echo "Pourquoi";; ihow) echo "Comment";; unblocks) echo "Débloque";;
          inbox_title) echo "Boîte autopilot — actions en attente d'un humain";;
        esac ;;
    *)  case "$1" in
          state) echo "state";; gate) echo "gate";; commit) echo "commit";; files) echo "files";;
          did) echo "What was done";; how) echo "How";; why) echo "Why";; notes) echo "Notes";;
          logged) echo "logged";;
          todo) echo "What to do";; iwhy) echo "Why";; ihow) echo "How";; unblocks) echo "Unblocks";;
          inbox_title) echo "Autopilot inbox — actions waiting on a human";;
        esac ;;
  esac
}

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
    printf -- '- **%s:** %s\n' "$(_ap_label state)" "$state"
    printf -- '- **%s:** `%s`\n' "$(_ap_label gate)" "${gate:-—}"
    printf -- '- **%s:** %s\n' "$(_ap_label commit)" "$commit"
    printf -- '- **%s:** %s\n\n' "$(_ap_label files)" "${files:-—}"
    printf '## %s\n%s\n\n' "$(_ap_label did)" "$did"
    printf '## %s\n%s\n\n' "$(_ap_label how)" "${how:-—}"
    printf '## %s\n%s\n\n' "$(_ap_label why)" "$why"
    [ -n "$notes" ] && printf '## %s\n%s\n\n' "$(_ap_label notes)" "$notes"
    printf '_%s %s_\n' "$(_ap_label logged)" "$(date '+%Y-%m-%d %H:%M')"
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
  [ -s "$inbox" ] || printf '# %s\n' "$(_ap_label inbox_title)" > "$inbox"
  {
    printf '\n### %s %s (%s)\n' "$icon" "$title" "$id"
    printf '**%s:** %s\n\n' "$(_ap_label todo)" "$action"
    printf '**%s:** %s\n\n' "$(_ap_label iwhy)" "$why"
    [ -n "$how" ]      && printf '**%s:**\n%s\n\n' "$(_ap_label ihow)" "$how"
    [ -n "$unblocks" ] && printf '**%s:** %s\n\n' "$(_ap_label unblocks)" "$unblocks"
    printf '_%s %s_\n' "$(_ap_label logged)" "$(date '+%Y-%m-%d %H:%M')"
  } >> "$inbox"
}
