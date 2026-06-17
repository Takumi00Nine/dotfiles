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

link hammerspoon/init.lua "$HOME/.hammerspoon/init.lua"
link tmux/tmux.conf       "$HOME/.tmux.conf"
link ghostty/config       "$HOME/.config/ghostty/config"

cat <<'EOF'

Done. Apply each config:
  - tmux:        tmux source-file ~/.tmux.conf   (or restart tmux)
  - Hammerspoon: menubar 🔨 -> Reload Config
  - Ghostty:     Cmd+Shift+,                     (or restart Ghostty)
EOF
