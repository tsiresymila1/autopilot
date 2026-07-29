#!/usr/bin/env bash
# Install autopilot into ~/.claude: symlink the skill and put the CLI on PATH.
# Idempotent. Re-run after pulling updates.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="${CLAUDE_HOME:-$HOME/.claude}"

mkdir -p "$CLAUDE/skills" "$CLAUDE/agents" "$HOME/.local/bin"

ln -sfn "$HERE/skill"      "$CLAUDE/skills/autopilot"
ln -sfn "$HERE/bin/autopilot" "$HOME/.local/bin/autopilot"

echo "linked:"
echo "  skill → $CLAUDE/skills/autopilot"
echo "  cli   → $HOME/.local/bin/autopilot"

echo "agents:"
for f in "$HERE"/agents/*.md; do
  name="$(basename "$f")"; dst="$CLAUDE/agents/$name"
  if [ ! -e "$dst" ] || [ -L "$dst" ]; then
    ln -sfn "$f" "$dst"; echo "  ✓ $name"
  else
    echo "  • $name exists (not ours) — kept yours; rm it to let autopilot manage it"
  fi
done
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo; echo "note: add ~/.local/bin to PATH:"; echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac
echo "done. try: autopilot doctor"
