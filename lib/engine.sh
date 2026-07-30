#!/usr/bin/env bash
# The engine: which coding agent actually executes the autopilot skill.
# Sourced, never executed. Depends on paths.sh.
#
#   AUTOPILOT_ENGINE=claude   (default) — runs the installed skill via /autopilot
#   AUTOPILOT_ENGINE=codex             — inlines skill/SKILL.md as the prompt
#
# Claude reads the skill from ~/.claude/skills/autopilot. Codex has no skill system,
# so the engine feeds SKILL.md itself on stdin — the skill is plain markdown, which is
# why it ports at all.

set -uo pipefail

ap_engine() { echo "${AUTOPILOT_ENGINE:-claude}"; }

# Absolute path to the skill this install ships.
ap_skill_file() { echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../skill" && pwd)/SKILL.md"; }

# Is the engine's CLI usable? Echoes a reason on failure.
ap_engine_available() {
  case "$(ap_engine)" in
    claude) command -v claude >/dev/null 2>&1 || { echo "claude CLI not on PATH"; return 1; } ;;
    codex)  command -v codex  >/dev/null 2>&1 || { echo "codex CLI not on PATH"; return 1; }
            [ -f "$(ap_skill_file)" ] || { echo "skill not found at $(ap_skill_file)"; return 1; } ;;
    *)      echo "unknown AUTOPILOT_ENGINE '$(ap_engine)' (use claude or codex)"; return 1 ;;
  esac
}

# Write the engine's prompt for <goal> into <file>.
# Claude: a one-line skill invocation. Codex: the whole skill + the goal.
# A directive appended to every prompt when AUTOPILOT_LANG is set: the engine
# writes all human-facing prose in that language. The CLI already localizes the
# fixed labels; this covers the prose the model itself writes.
_ap_lang_directive() {
  local lang="${AUTOPILOT_LANG:-}"; [ -n "$lang" ] || return 0
  printf 'Language: write ALL human-facing text — reports (--did/--why/--how), inbox items, journal entries, and your final summary — in %s.\n' "$lang"
}

ap_engine_prompt() {
  local goal="$1" out="$2"
  if [ "$(ap_engine)" = codex ]; then
    { cat "$(ap_skill_file)"
      printf '%s\n' "" "" "===== YOUR RUN ====="
      printf '%s\n' "Execute the skill above as the main thread, now, on this goal:" "" "$goal" ""
      printf '%s\n' "Notes for this engine:" \
        "- You have no Claude subagents. Do each role yourself, in the same order and" \
        "  with the same rigour: explore, build, verify, review, commit." \
        "- Review your own diff adversarially, or set AUTOPILOT_REVIEWER for an" \
        "  independent verdict. Never approve work you did not verify." \
        "- Use the autopilot CLI for the checkable steps: gate-lint, gate, scope," \
        "  verify, revert, docs, status. They are the objective truth, not prose."
      d="$(_ap_lang_directive)"; [ -n "$d" ] && printf '%s\n' "" "$d"
    } > "$out"
  else
    { printf '/autopilot %s\n' "$goal"
      d="$(_ap_lang_directive)"; [ -n "$d" ] && printf '%s\n' "$d"; } > "$out"
  fi
}

# Turn claude's stream-json into readable play-by-play: assistant text, each
# tool call, each tool result, the final summary — one line each, the noise
# (hook events, system frames) dropped. Reads stdin, writes lines.
ap_stream_format() {
  jq -rj --unbuffered '
    if .type=="assistant" then
      (.message.content[]? |
        if .type=="text" then (.text + "\n")
        elif .type=="tool_use" then "→ \(.name): \((.input|tostring)[0:120])\n"
        else empty end)
    elif .type=="user" then
      (.message.content[]? | select(.type=="tool_result") |
        "  ← " + (((.content // "") | if type=="array" then (map(.text // "")|join(" ")) else tostring end)[0:120]) + "\n")
    elif .type=="result" then
      "═══ \(.subtype) · \(.num_turns // 0) turns · $\(.total_cost_usd // 0)\n"
    else empty end' 2>/dev/null
}

# Run the engine on a prompt file, streaming to stdout. Returns the engine's exit code.
# ap_engine_exec <prompt-file>
ap_engine_exec() {
  local pf="$1" root; root="$(ap_root)"
  case "$(ap_engine)" in
    codex)
      # -a (approval policy) must precede `exec`; the prompt arrives on stdin via `-`.
      local -a args=()
      [ -n "${AUTOPILOT_CODEX_APPROVAL:-never}" ] && args+=("-a" "${AUTOPILOT_CODEX_APPROVAL:-never}")
      args+=("exec" "-C" "$root" "-s" "${AUTOPILOT_CODEX_SANDBOX:-workspace-write}")
      [ -n "${AUTOPILOT_CODEX_MODEL:-}" ] && args+=("-m" "$AUTOPILOT_CODEX_MODEL")
      [ -n "${AUTOPILOT_CODEX_EFFORT:-}" ] && args+=("-c" "model_reasoning_effort=\"$AUTOPILOT_CODEX_EFFORT\"")
      args+=("-")
      codex "${args[@]}" < "$pf" ;;
    *)
      # Pin the model when asked, so a run is reproducible and can dodge a flaky
      # tier; unset = the claude CLI's own default.
      local -a m=(); [ -n "${AUTOPILOT_CLAUDE_MODEL:-}" ] && m=(--model "$AUTOPILOT_CLAUDE_MODEL")
      # AUTOPILOT_STREAM=1 (needs jq): log every action live, not just the final
      # message, so `logs -f` shows what the engine is doing as it does it.
      if [ -n "${AUTOPILOT_STREAM:-}" ] && command -v jq >/dev/null 2>&1; then
        claude -p "$(cat "$pf")" ${m[@]+"${m[@]}"} --permission-mode "${PERMISSION_MODE:-bypassPermissions}" \
          --output-format stream-json --verbose | ap_stream_format
      else
        claude -p "$(cat "$pf")" ${m[@]+"${m[@]}"} --permission-mode "${PERMISSION_MODE:-bypassPermissions}"
      fi ;;
  esac
}
