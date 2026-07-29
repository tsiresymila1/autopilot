#!/usr/bin/env bash
# Install autopilot into ~/.claude: symlink the skill and put the CLI on PATH.
# Idempotent. Re-run after pulling updates.
#
# From a checkout:   ./install.sh
# Over the network:  curl -fsSL <raw-url>/install.sh | bash
#                    (clones the repo to $AUTOPILOT_DIR, then links from there)
#
# Env overrides: AUTOPILOT_REPO (git url) · AUTOPILOT_DIR (clone target) · CLAUDE_HOME
set -euo pipefail

REPO_URL="${AUTOPILOT_REPO:-https://github.com/tsiresymila1/autopilot.git}"
INSTALL_DIR="${AUTOPILOT_DIR:-$HOME/.local/share/autopilot}"
CLAUDE="${CLAUDE_HOME:-$HOME/.claude}"

# Source of truth: the local checkout if we are inside one, else clone/update it.
# When piped through `bash`, BASH_SOURCE is not a real path, so skill/ won't be found.
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd || true)"
if [ -n "$self_dir" ] && [ -f "$self_dir/skill/SKILL.md" ]; then
  HERE="$self_dir"
else
  command -v git >/dev/null 2>&1 || { echo "autopilot: git is required for a network install" >&2; exit 1; }
  if [ -d "$INSTALL_DIR/.git" ]; then
    echo "updating $INSTALL_DIR"; git -C "$INSTALL_DIR" pull --ff-only -q || true
  else
    echo "cloning $REPO_URL → $INSTALL_DIR"; git clone -q "$REPO_URL" "$INSTALL_DIR"
  fi
  HERE="$INSTALL_DIR"
fi

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
