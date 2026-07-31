#!/usr/bin/env bash
# Multi-channel notification fan-out + the structured per-step event entry point.
# Sourced, never executed. Depends on paths.sh (ap_journal, ap_events_log, ap_id_of
# lives in gate.sh which common.sh sources first).
#
# Two things live here:
#   ap_event         — the structured emitter the CLI verbs and the skill call. It
#                      ALWAYS records to .autopilot/events.log + journal, then pushes
#                      to channels only if the run's notify level allows this event.
#   ap_channels_send — fans a message out to EVERY configured channel (ntfy, Telegram,
#                      webhook, custom hook, local), each best-effort, each echoing the
#                      backend it used so callers/tests can see it.
#
# Verbosity: AUTOPILOT_NOTIFY_LEVEL = milestones < steps < verbose (default steps).
#   milestones = run terminal states + blocked / needs-human / needs-verification
#   steps      = the deterministic per-step feed: gate, verify, review, task-done, phase
#   verbose    = adds best-effort decision + task-cut (emitted by the skill)
# Every event is logged regardless; the level only gates the channel push.
#
# Channel config (set in .autopilot.env, which is gitignored — keep secrets there):
#   AUTOPILOT_NTFY_TOPIC / _SERVER / _TOKEN
#   AUTOPILOT_TELEGRAM_TOKEN + AUTOPILOT_TELEGRAM_CHAT_ID
#   AUTOPILOT_WEBHOOK_URL
#   AUTOPILOT_NOTIFY (custom eval hook)
#   AUTOPILOT_LOCAL_LEVEL (cap for osascript/notify-send; default milestones)

set -uo pipefail

# --- level model -------------------------------------------------------------

_ap_level_num() {
  case "$1" in milestones) echo 1;; steps) echo 2;; verbose) echo 3;; *) echo 2;; esac
}
_ap_level_now() { echo "${AUTOPILOT_NOTIFY_LEVEL:-steps}"; }
# true when the current level is at least the event's level
_ap_level_ge()  { [ "$(_ap_level_num "$1")" -ge "$(_ap_level_num "$2")" ]; }

# default min-level a kind needs before it pushes to channels
_ap_event_level() {
  case "$1" in
    task-cut|decision)                                  echo verbose ;;
    phase|gate|verify|review|task-done)                 echo steps ;;
    blocked|needs-human|needs-verification)             echo milestones ;;
    run-done|run-blocked|run-stuck|run-stopped)         echo milestones ;;
    *)                                                  echo steps ;;
  esac
}

_ap_event_emoji() {
  local kind="$1" state="${2:-}"
  case "$kind" in
    gate)                case "$state" in pass) echo "✅";; *) echo "❌";; esac ;;
    verify)             case "$state" in pass) echo "✅";; *) echo "🔴";; esac ;;
    review)             case "$state" in APPROVED) echo "✅";; RISKY) echo "🛑";; *) echo "📝";; esac ;;
    task-done)          echo "✔️" ;;
    blocked)            echo "⛔" ;;
    needs-human)        echo "⚑" ;;
    needs-verification) echo "⚠️" ;;
    decision)           echo "🧭" ;;
    task-cut)           echo "✂️" ;;
    phase)              echo "🚩" ;;
    run-done)           echo "🎉" ;;
    run-blocked)        echo "⛔" ;;
    run-stuck)          echo "🛑" ;;
    run-stopped)        echo "🚧" ;;
    *)                  echo "🔔" ;;
  esac
}

# --- helpers -----------------------------------------------------------------

# Escape a string for embedding in a JSON double-quoted value. stdin -> stdout.
_ap_json_escape() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"");
    if (NR>1) printf "\\n"; printf "%s", $0
  }'
}

# --- channels ----------------------------------------------------------------
# Each: <headline> <body> <id> <ts>  (kind/state/url read from env). Best-effort.

_ap_ch_ntfy() {
  [ -n "${AUTOPILOT_NTFY_TOPIC:-}" ] && command -v curl >/dev/null 2>&1 || return 0
  local server="${AUTOPILOT_NTFY_SERVER:-https://ntfy.sh}"
  curl -fsS -m 10 -H "Title: $1" \
    ${AUTOPILOT_NTFY_TOKEN:+-H "Authorization: Bearer $AUTOPILOT_NTFY_TOKEN"} \
    -d "$2" "$server/$AUTOPILOT_NTFY_TOPIC" >/dev/null 2>&1 \
    && echo "notified via ntfy ($AUTOPILOT_NTFY_TOPIC)" \
    || echo "ntfy push failed ($server/$AUTOPILOT_NTFY_TOPIC)"
}

_ap_ch_telegram() {
  [ -n "${AUTOPILOT_TELEGRAM_TOKEN:-}" ] && [ -n "${AUTOPILOT_TELEGRAM_CHAT_ID:-}" ] \
    && command -v curl >/dev/null 2>&1 || return 0
  local headline="$1" body="$2" id="$3" text
  text="*${headline}*"
  [ -n "$body" ] && text="$text
${body}"
  # Telegram hard limit is 4096 chars; leave room and point at the full report.
  if [ "${#text}" -gt 4096 ]; then
    text="${text:0:3900}
… truncated — full report: .autopilot/reports/${id:-<id>}.md"
  fi
  # --data-urlencode keeps arbitrary prose injection-safe (no shell/URL parsing).
  curl -fsS -m 10 \
    --data-urlencode "chat_id=${AUTOPILOT_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot${AUTOPILOT_TELEGRAM_TOKEN}/sendMessage" >/dev/null 2>&1 \
    && echo "notified via telegram (chat ${AUTOPILOT_TELEGRAM_CHAT_ID})" \
    || echo "telegram push failed (chat ${AUTOPILOT_TELEGRAM_CHAT_ID})"
}

_ap_ch_webhook() {
  [ -n "${AUTOPILOT_WEBHOOK_URL:-}" ] && command -v curl >/dev/null 2>&1 || return 0
  local headline="$1" body="$2" id="$3" ts="$4" json
  json="$(printf '{"kind":"%s","title":"%s","body":"%s","task":"%s","state":"%s","ts":"%s"}' \
    "$(printf '%s' "${AP_EVENT_KIND:-notify}" | _ap_json_escape)" \
    "$(printf '%s' "$headline" | _ap_json_escape)" \
    "$(printf '%s' "$body" | _ap_json_escape)" \
    "$(printf '%s' "$id" | _ap_json_escape)" \
    "$(printf '%s' "${AP_EVENT_STATE:-}" | _ap_json_escape)" \
    "$(printf '%s' "$ts" | _ap_json_escape)")"
  printf '%s' "$json" | curl -fsS -m 10 -H 'Content-Type: application/json' \
    --data-binary @- "$AUTOPILOT_WEBHOOK_URL" >/dev/null 2>&1 \
    && echo "notified via webhook" || echo "webhook push failed"
}

_ap_ch_custom() {
  [ -n "${AUTOPILOT_NOTIFY:-}" ] || return 0
  AUTOPILOT_NOTIFY_TITLE="$1" AUTOPILOT_NOTIFY_BODY="$2" \
    eval "$AUTOPILOT_NOTIFY" >/dev/null 2>&1 \
    && echo "notified via AUTOPILOT_NOTIFY" || echo "notify hook failed (AUTOPILOT_NOTIFY)"
}

# Local desktop popup — capped at AUTOPILOT_LOCAL_LEVEL (default milestones) so a
# verbose run does not buzz the laptop on every step.
_ap_ch_local() {
  _ap_level_ge "${AUTOPILOT_LOCAL_LEVEL:-milestones}" "${AP_EVENT_LEVEL:-steps}" || return 0
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run {t,b}' -e 'display notification b with title t' -e 'end run' \
      "$1" "$2" >/dev/null 2>&1 && echo "notified via osascript"
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" >/dev/null 2>&1 && echo "notified via notify-send"
  fi
}

# Fan out to every configured channel. Never fails the run.
# ap_channels_send <kind> <headline> <body> <id> <state> <ts>
ap_channels_send() {
  AP_EVENT_KIND="$1" AP_EVENT_STATE="$5"
  local headline="$2" body="$3" id="$4" ts="$6" sent=""
  sent="$sent$(_ap_ch_ntfy     "$headline" "$body" "$id" "$ts")
"
  sent="$sent$(_ap_ch_telegram "$headline" "$body" "$id" "$ts")
"
  sent="$sent$(_ap_ch_webhook  "$headline" "$body" "$id" "$ts")
"
  sent="$sent$(_ap_ch_custom   "$headline" "$body" "$id" "$ts")
"
  sent="$sent$(_ap_ch_local    "$headline" "$body" "$id" "$ts")
"
  if [ -n "$(printf '%s' "$sent" | grep -v '^$')" ]; then
    printf '%s\n' "$sent" | grep -v '^$'
  else
    echo "no notifier configured (set AUTOPILOT_TELEGRAM_TOKEN, AUTOPILOT_WEBHOOK_URL, or AUTOPILOT_NTFY_TOPIC)"
  fi
}

# --- the structured event emitter --------------------------------------------
# ap_event <kind> <title> <body> [task-file] [state] [level]
# Always logs; pushes to channels only when the run level allows the event level.
ap_event() {
  local kind="$1" title="$2" body="${3:-}" task="${4:-}" state="${5:-}" level="${6:-}"
  [ -n "$level" ] || level="$(_ap_event_level "$kind")"
  local ts id emoji
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  id=""; [ -n "$task" ] && [ -f "$task" ] && id="$(ap_id_of "$task")"
  emoji="$(_ap_event_emoji "$kind" "$state")"

  # Durable audit trail — always, regardless of level.
  local elog; elog="$(ap_events_log)"; mkdir -p "$(dirname "$elog")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$kind" "$level" "${state:-}" "${id:-}" "$title" >> "$elog" 2>/dev/null || true
  printf '[%s] event %s%s: %s\n' "$ts" "$kind" "${id:+ ($id)}" "$title" >> "$(ap_journal)" 2>/dev/null || true

  # AP_EVENT_SUPPRESS lets a caller (e.g. verify's inner gate calls) log without pushing.
  [ -n "${AP_EVENT_SUPPRESS:-}" ] && return 0
  _ap_level_ge "$(_ap_level_now)" "$level" || return 0

  AP_EVENT_LEVEL="$level"
  ap_channels_send "$kind" "$emoji $title" "$body" "$id" "$state" "$ts"
}
