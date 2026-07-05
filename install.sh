#!/usr/bin/env bash
# Symlink the configs in this repo into their live locations.
# Idempotent: re-running is safe. Existing real files are backed up once
# as "<dest>.pre-dotfiles.bak" before being replaced by a symlink.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link() {  # link <repo-relative-source> <destination>
  local src="$DIR/$1" dest="$2"
  if [ ! -e "$src" ]; then
    echo "skip: source missing: $src" >&2
    return
  fi
  mkdir -p "$(dirname "$dest")"
  # Back up a pre-existing real file (not a symlink) once.
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    cp "$dest" "$dest.pre-dotfiles.bak"
    echo "backed up: $dest -> $dest.pre-dotfiles.bak"
  fi
  ln -sfn "$src" "$dest"
  echo "linked: $dest -> $src"
}

# LaunchAgent is COPIED, not symlinked: launchd's login auto-load is unreliable
# with symlinked plists, so we deploy a real file and (re)load it.
install_launchagent() {  # install_launchagent <plist filename under launchagents/>
  local src="$DIR/launchagents/$1"
  local dest="$HOME/Library/LaunchAgents/$1" label="${1%.plist}" dom="gui/$(id -u)"
  [ -f "$src" ] || { echo "skip: source missing: $src" >&2; return; }
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "copied: $dest"
  launchctl bootout "$dom/$label" 2>/dev/null || true
  if launchctl bootstrap "$dom" "$dest" 2>/dev/null; then
    launchctl enable "$dom/$label" 2>/dev/null || true
    launchctl kickstart -k "$dom/$label" 2>/dev/null || true
    echo "launchd: (re)loaded $label"
  else
    echo "launchd: bootstrap failed for $label (load manually if needed)" >&2
  fi
}

link hammerspoon/init.lua        "$HOME/.hammerspoon/init.lua"
link tmux/tmux.conf              "$HOME/.tmux.conf"
link ghostty/config              "$HOME/.config/ghostty/config"
link ghostty/start-tmux.sh           "$HOME/.config/ghostty/start-tmux.sh"
link ghostty/cmux-session-cleanup.sh "$HOME/.config/ghostty/cmux-session-cleanup.sh"
link cmux/claude-teams-launch.sh     "$HOME/.local/bin/cmux-teams"
chmod +x "$DIR/ghostty/start-tmux.sh" "$DIR/ghostty/cmux-session-cleanup.sh" "$DIR/cmux/claude-teams-launch.sh" "$DIR/cmux/claude-teams-entry.sh"

install_launchagent com.takumi009.usage-refresh.plist

cat <<'EOF'

Done. Apply each config:
  - tmux:        tmux source-file ~/.tmux.conf   (or restart tmux)
  - Hammerspoon: menubar 🔨 -> Reload Config
  - Ghostty:     Cmd+Shift+,                     (or restart Ghostty)
  - launchd:     usage-refresh agent already (re)loaded by this script
EOF
