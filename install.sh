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
  # Back up a pre-existing real file OR directory (not a symlink) once, then move it
  # out of the way. Uses `mv` (not `cp`) so the destination path is actually freed:
  # for a directory, `ln -sfn` cannot replace it in place (unlink() fails on a
  # non-empty directory), so a `cp`-then-leave-original-behind approach silently
  # fails to link (Codexレビュー2026-08-05指摘 — 2巡目でcp -Rだけでは不十分と判明)。
  # If a backup already exists, stop rather than silently overwriting/merging it.
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    # `-e` alone misses a broken symlink at the backup path (Codexレビュー2026-08-05
    # 指摘・3巡目); `-L` also catches that case.
    if [ -e "$dest.pre-dotfiles.bak" ] || [ -L "$dest.pre-dotfiles.bak" ]; then
      echo "error: backup already exists, refusing to overwrite: $dest.pre-dotfiles.bak" >&2
      return 1
    fi
    mv "$dest" "$dest.pre-dotfiles.bak"
    echo "backed up: $dest -> $dest.pre-dotfiles.bak"
  fi
  ln -sfn "$src" "$dest"
  echo "linked: $dest -> $src"
}

# append_zsh_aliases_source: ~/.zshrc の末尾に cc/cct 関数(zsh/aliases.zsh)への
# source行を追記する。冪等（目印コメント`# dotfiles-managed`をgrepし、既に
# あれば何もしない）。既存の.zshrc内容は一切変更・並べ替えせず末尾追記のみ、
# .zshrcが無ければ新規作成する（このスクリプトは追記のみを担当。zshrc内に
# 直書きのcc/cct定義が別途あればそれを除去するのは呼び出し側の責務）。
append_zsh_aliases_source() {
  local zshrc="$HOME/.zshrc" marker="# dotfiles-managed"
  local src_line
  src_line='[ -r "$HOME/work/dotfiles/zsh/aliases.zsh" ] && source "$HOME/work/dotfiles/zsh/aliases.zsh"  '"$marker"
  if [ -f "$zshrc" ] && grep -qF "$marker" "$zshrc" 2>/dev/null; then
    echo "skip: ~/.zshrcには既にdotfiles-managedのalias source行があります"
    return
  fi
  if [ -s "$zshrc" ]; then
    printf '\n%s\n' "$src_line" >> "$zshrc"
  else
    printf '%s\n' "$src_line" >> "$zshrc"
  fi
  echo "appended: $zshrc <- zsh/aliases.zsh source line"
}

link hammerspoon/init.lua        "$HOME/.hammerspoon/init.lua"
link hammerspoon/nape_pro        "$HOME/.hammerspoon/nape_pro"
link tmux/tmux.conf              "$HOME/.tmux.conf"
link ghostty/config              "$HOME/.config/ghostty/config"
link ghostty/start-tmux.sh           "$HOME/.config/ghostty/start-tmux.sh"
link ghostty/cmux-session-cleanup.sh "$HOME/.config/ghostty/cmux-session-cleanup.sh"
link cmux/claude-teams-launch.sh     "$HOME/.local/bin/cmux-teams"
# cmux 本体設定・ドック定義・Next ペイン表示ツール（2026-08-06 追加。
# cmux.json=通知フィルタ等 / dock.json=Usage・Next・System の3コントロール /
# cmux-next-watch=dock.json から起動される表示スクリプト。tools/ 側の参照
# パス互換のため ~/work/tools/cmux-next-watch にも symlink を張る。Usage
# コントロールが読む cmux-usage-watch.sh は claude-codex-usage リポジトリ
# 側へ移設済み（2026-08-07）で、dotfiles側はsymlinkしない）
link cmux/cmux.json                  "$HOME/.config/cmux/cmux.json"
link cmux/dock.json                  "$HOME/.config/cmux/dock.json"
link cmux/cmux-next-watch            "$HOME/work/tools/cmux-next-watch"
chmod +x "$DIR/ghostty/start-tmux.sh" "$DIR/ghostty/cmux-session-cleanup.sh" "$DIR/cmux/claude-teams-launch.sh" "$DIR/cmux/claude-teams-entry.sh" "$DIR/cmux/cmux-next-watch/cmux-next-watch.sh"

append_zsh_aliases_source

cat <<'EOF'

Done. Apply each config:
  - tmux:        tmux source-file ~/.tmux.conf   (or restart tmux)
  - Hammerspoon: menubar 🔨 -> Reload Config
  - Ghostty:     Cmd+Shift+,                     (or restart Ghostty)
  - zsh:         cc/cct source line added to ~/.zshrc if missing
                 (restart zsh, or: source ~/.zshrc)
  - Usage stats: not managed by this repo. See the separate
                 claude-codex-usage repo's own install.sh for the
                 refresh LaunchAgent + tmux/cmux usage rendering.
EOF
