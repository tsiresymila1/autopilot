#!/usr/bin/env bash
# Supervisor: relaunch the autopilot session until the work is finished.
#
# Nothing inside a Claude session can restart it after a quota block. This lives
# outside: it relaunches, waits for the reset, resumes. State is on disk
# (.agent/run/status, PROGRESS.md, run/state/*), so each relaunch picks up where
# the last one stopped.
#
#   supervisor.sh "<goal or file>" [extra autopilot args]
#   MAX_RELAUNCH=40 supervisor.sh "goal" --max-tasks 5

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/common.sh"

GOAL="${1:?usage: supervisor.sh \"<goal or file>\" [options]}"; shift || true
EXTRA="$*"

MAX_RELAUNCH="${MAX_RELAUNCH:-24}"
RETRY_WAIT="${RETRY_WAIT:-900}"                 # fallback wait if reset time unknown
PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}"

command -v claude >/dev/null 2>&1 || ap_die "claude CLI not on PATH"
cd "$(ap_root)" || exit 1

# --- single-run lock (stale locks from dead PIDs are reclaimed) ---------------
LOCK="$(ap_lock_file)"; mkdir -p "$(dirname "$LOCK")"
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  ap_die "another autopilot run holds the lock (pid $(cat "$LOCK")). Stop it first."
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"; ap_log "interrupted"; exit 130' INT TERM
trap 'rm -f "$LOCK"' EXIT

STATUS="$(ap_status_file)"; LOGDIR="$(ap_state_dir)/run-logs"; mkdir -p "$LOGDIR"
log() { ap_log "$1" | tee -a "$LOGDIR/supervisor.log"; }

wait_for_reset() {
  local out="$1" secs="$RETRY_WAIT" hhmm now target
  hhmm=$(grep -oiE '(resets?|réinitialis[^ ]*|réessayez?)[^0-9]{0,20}([0-9]{1,2})[:h]([0-9]{2})' "$out" 2>/dev/null \
         | grep -oE '([0-9]{1,2})[:h]([0-9]{2})' | head -1 | tr 'h' ':')
  if [ -n "$hhmm" ]; then
    now=$(date +%s); target=$(date -j -f "%H:%M" "$hhmm" +%s 2>/dev/null || echo "")
    if [ -n "$target" ]; then
      [ "$target" -le "$now" ] && target=$((target + 86400))
      secs=$((target - now + 60))
    fi
  fi
  log "quota hit — resuming in $((secs/60)) min"; sleep "$secs"
}

PROMPT="/autopilot $GOAL $EXTRA

If .agent/ already holds a queue and a journal, this is a RESUME: read
.agent/PROGRESS.md, .agent/run/state/* and .agent/queue/, then restart at the first
task not marked done. Do not start over. Do not re-litigate decisions already made."

log "start — goal: $GOAL ${EXTRA:+· options: $EXTRA}"

for i in $(seq 1 "$MAX_RELAUNCH"); do
  OUT="$LOGDIR/run-$(date +%Y%m%d-%H%M%S).log"
  log "session $i/$MAX_RELAUNCH → $OUT"
  claude -p "$PROMPT" --permission-mode "$PERMISSION_MODE" >"$OUT" 2>&1
  code=$?
  status=$(cat "$STATUS" 2>/dev/null || echo "RUNNING")
  log "session ended (code $code) · status=$status"

  case "$status" in
    DONE)    log "✅ done — nothing left"; tail -40 "$OUT"; exit 0 ;;
    BLOCKED) log "⛔ blocked — human needed (see .agent/HUMAN-INBOX.md)"; tail -40 "$OUT"; exit 2 ;;
  esac

  if grep -qiE 'usage limit|rate limit|quota|too many requests|limite.*atteinte|429' "$OUT"; then
    wait_for_reset "$OUT"
  elif [ "$code" -ne 0 ]; then
    log "⚠️  unexpected failure (code $code) — retry in 60 s"; tail -15 "$OUT"; sleep 60
  else
    log "session closed without finishing — resuming immediately"
  fi
done

log "⚠️  hit the $MAX_RELAUNCH relaunch cap — stopping"
exit 3
