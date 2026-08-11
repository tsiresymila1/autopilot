#!/usr/bin/env bash
# Install autopilot into ~/.claude: symlink the skill and put the CLI on PATH.
# Idempotent. Re-run after pulling updates.
#
# From a checkout:   ./install.sh
# Over the network:  curl -fsSL <raw-url>/install.sh | bash
#                    (clones the repo to $AUTOPILOT_DIR, then links from there)
#
# Env overrides: AUTOPILOT_REPO (git url) · AUTOPILOT_DIR (clone target) ·
#                CLAUDE_HOME · CODEX_HOME
set -euo pipefail

REPO_URL="${AUTOPILOT_REPO:-https://github.com/tsiresymila1/autopilot.git}"
INSTALL_DIR="${AUTOPILOT_DIR:-$HOME/.local/share/autopilot}"
CLAUDE="${CLAUDE_HOME:-$HOME/.claude}"
CODEX="${CODEX_HOME:-$HOME/.codex}"

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

# Remove any existing target first: `ln -sfn src dir/` nests the link INSIDE an
# existing directory instead of replacing it, which silently leaves a stale
# copied SKILL.md in place and the engine keeps reading the old skill.
[ -L "$CLAUDE/skills/autopilot" ] || rm -rf "$CLAUDE/skills/autopilot"
ln -sfn "$HERE/skill"      "$CLAUDE/skills/autopilot"
ln -sfn "$HERE/bin/autopilot" "$HOME/.local/bin/autopilot"

echo "linked:"
echo "  skill → $CLAUDE/skills/autopilot"
echo "  cli   → $HOME/.local/bin/autopilot"

# Codex skills dir — same skill/, so `AUTOPILOT_ENGINE=codex` finds it there too.
# Skip with AUTOPILOT_SKIP_CODEX=1. Same rm-first to avoid the ln-nesting trap.
if [ -z "${AUTOPILOT_SKIP_CODEX:-}" ]; then
  mkdir -p "$CODEX/skills"
  [ -L "$CODEX/skills/autopilot" ] || rm -rf "$CODEX/skills/autopilot"
  ln -sfn "$HERE/skill" "$CODEX/skills/autopilot"
  echo "  skill → $CODEX/skills/autopilot (codex)"
fi

echo "agents:"
for f in "$HERE"/agents/*.md; do
  name="$(basename "$f")"; dst="$CLAUDE/agents/$name"
  if [ ! -e "$dst" ] || [ -L "$dst" ]; then
    ln -sfn "$f" "$dst"; echo "  ✓ $name"
  else
    echo "  • $name exists (not ours) — kept yours; rm it to let autopilot manage it"
  fi
done
# --- companion tools (best-effort; never fail the core install) --------------
# Skip with AUTOPILOT_SKIP_EXTRAS=1 (used by tests and by users who don't want them).
if [ -z "${AUTOPILOT_SKIP_EXTRAS:-}" ]; then
  echo "extras:"
  # ponytail — "lazy senior dev" plugin, sharpens the builder's restraint (global).
  if command -v claude >/dev/null 2>&1; then
    claude plugin marketplace add "${AUTOPILOT_PONYTAIL_REPO:-DietrichGebert/ponytail}" >/dev/null 2>&1 || true
    if claude plugin install ponytail@ponytail >/dev/null 2>&1; then echo "  ✓ ponytail plugin"
    else echo "  • ponytail: already present or unavailable — skipped"; fi
  else
    echo "  • ponytail: needs the claude CLI — skipped"
  fi
  # spec-kit — the specify CLI (global). Per-project scaffolding happens at run time:
  #   specify init --here --integration claude --force
  if command -v specify >/dev/null 2>&1; then
    echo "  ✓ spec-kit (specify already installed)"
  elif command -v uv >/dev/null 2>&1; then
    if uv tool install specify-cli --from git+https://github.com/github/spec-kit.git >/dev/null 2>&1; then
      echo "  ✓ spec-kit (specify CLI)"
    else echo "  • spec-kit: install failed — try 'uv tool install specify-cli --from git+https://github.com/github/spec-kit.git'"; fi
  else
    echo "  • spec-kit: needs uv (https://docs.astral.sh/uv) — skipped"
  fi
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo; echo "note: add ~/.local/bin to PATH:"; echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac
echo "done. try: autopilot doctor"
