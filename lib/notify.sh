#!/usr/bin/env bash
# Milestone notifications. Sourced, never executed. Depends on ap_warn (paths.sh).

set -uo pipefail

# Notify the user that an autonomous run reached a milestone. Best-effort — never
# fails the run. Backends, in priority order:
#   ntfy    → $AUTOPILOT_NTFY_TOPIC set → push to $AUTOPILOT_NTFY_SERVER (default
#             https://ntfy.sh), optional $AUTOPILOT_NTFY_TOKEN for auth. The main path.
#   custom  → $AUTOPILOT_NOTIFY run as a command; title/body in
#             $AUTOPILOT_NOTIFY_TITLE / $AUTOPILOT_NOTIFY_BODY
#   macOS   → osascript · linux → notify-send · else → no-op (still logged)
# Report the backend used on stdout so callers/tests can see it.
ap_notify() {
  local title="${1:-autopilot}" body="${2:-}"
  if [ -n "${AUTOPILOT_NTFY_TOPIC:-}" ] && command -v curl >/dev/null 2>&1; then
    local server="${AUTOPILOT_NTFY_SERVER:-https://ntfy.sh}"
    curl -fsS -m 10 -H "Title: $title" \
      ${AUTOPILOT_NTFY_TOKEN:+-H "Authorization: Bearer $AUTOPILOT_NTFY_TOKEN"} \
      -d "$body" "$server/$AUTOPILOT_NTFY_TOPIC" >/dev/null 2>&1 \
      && { echo "notified via ntfy ($AUTOPILOT_NTFY_TOPIC)"; return; }
    echo "ntfy push failed ($server/$AUTOPILOT_NTFY_TOPIC)"; return
  fi
  if [ -n "${AUTOPILOT_NOTIFY:-}" ]; then
    AUTOPILOT_NOTIFY_TITLE="$title" AUTOPILOT_NOTIFY_BODY="$body" \
      eval "$AUTOPILOT_NOTIFY" >/dev/null 2>&1 && { echo "notified via AUTOPILOT_NOTIFY"; return; }
    echo "notify hook failed (AUTOPILOT_NOTIFY)"; return
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run {t,b}' -e 'display notification b with title t' -e 'end run' \
      "$title" "$body" >/dev/null 2>&1 && { echo "notified via osascript"; return; }
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1 && { echo "notified via notify-send"; return; }
  fi
  echo "no notifier available (set AUTOPILOT_NTFY_TOPIC or AUTOPILOT_NOTIFY)"
}
