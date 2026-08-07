#!/usr/bin/env bash
# Symlink the configs in this repo into their live locations.
# Idempotent: re-running is safe. Existing real files are backed up once
# as "<dest>.pre-dotfiles.bak" before being replaced by a symlink.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# テスト専用: "1" にすると launchctl への実操作（bootout/bootstrap/enable/
# kickstart）だけをskipする（plist生成・plutil -lintはそのまま行う）。実launchd
# はHOMEを差し替えても隔離できないため、テストで誤って実システムのlaunchdへ
# 登録してしまう事故を防ぐ（takumi009-ai-env scripts/install-sub.sh の
# SKIP_LAUNCHCTL と同じ考え方・同じ変数名。2026-08-07にusage-refresh移設で
# 一度削除したが、cmux-dock-guard LaunchAgentの追加で復活）。本番運用では
# 常に既定値=0のまま。
: "${SKIP_LAUNCHCTL:=0}"
# launchctl 1回あたりの待ち上限（秒）。テストでは短縮して使う。
: "${LAUNCHCTL_TIMEOUT_SECS:=5}"

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

# macOSの標準bashには`timeout`コマンドが無い（GNU coreutils由来）。バックグラウンド
# 実行+`kill $pid`だけでは launchctl が起動する子プロセスが残りうるため、`set -m`で
# ジョブ制御を有効にしてバックグラウンドジョブを独立プロセスグループにし、
# タイムアウト時は負PID（`kill -- -$pid`）でグループごとkillする
# （TERM→1秒猶予→KILL。実証済みパターン: macos-bash-timeout-process-group）。
run_with_timeout() {
  local secs="$1"
  shift
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  [ "$had_monitor" = "1" ] || set +m
  ( sleep "$secs"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null
  rc=$?
  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return "$rc"
}

# generate_plist_from_template <repo-relative template> <destination>
# __DOTFILES_HOME__ を実 $HOME へ置換した実ファイルを生成する（plistはXMLで
# シェル変数展開されないため）。sedのメタ文字（& \ #）は$HOME側でエスケープし、
# 生成はmktempへ書いてからmvで原子的に行う（$HOMEに&や\が含まれる環境での
# 置換破損・書き込み中断時の破損を防ぐ）。
# 注意: cleanupに`trap ... RETURN`は使わない — RETURN trapは設定した関数
# 自身の復帰だけでなく、その後に別の関数が復帰するたびにも発火するため、
# ここで`local tmp`のスコープが外れた後の他関数呼び出し時に
# "unbound variable"で落ちる（実装中に実測）。代わりにsed失敗時だけ
# 明示的にrmする。
generate_plist_from_template() {
  local src="$DIR/$1" dest="$2" escaped_home tmp rc=0
  [ -f "$src" ] || { echo "skip: template missing: $src" >&2; return 1; }
  mkdir -p "$(dirname "$dest")"
  escaped_home=$(printf '%s' "$HOME" | sed -e 's/[&\]/\\&/g' -e 's/#/\\#/g')
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").dotfiles-tmp.XXXXXX")"
  if sed "s#__DOTFILES_HOME__#${escaped_home}#g" "$src" > "$tmp"; then
    mv "$tmp" "$dest"
  else
    rc=1
    rm -f "$tmp"
  fi
  return "$rc"
}

# install_launchagent <plist-path-already-in-place>
# 既に配置済みのplistをlaunchdへ(再)登録する。各launchctl呼び出しは
# run_with_timeoutでラップし、ハングしても次へ進む（インストーラ全体を
# 止めない。上限超過時はWARNを出すだけで処理は続行する）。
install_launchagent() {
  local dest="$1" label dom
  label="$(basename "$dest" .plist)"
  dom="gui/$(id -u)"
  run_with_timeout "$LAUNCHCTL_TIMEOUT_SECS" launchctl bootout "$dom/$label" >/dev/null 2>&1 || true
  if run_with_timeout "$LAUNCHCTL_TIMEOUT_SECS" launchctl bootstrap "$dom" "$dest" >/dev/null 2>&1; then
    run_with_timeout "$LAUNCHCTL_TIMEOUT_SECS" launchctl enable "$dom/$label" >/dev/null 2>&1 || true
    run_with_timeout "$LAUNCHCTL_TIMEOUT_SECS" launchctl kickstart -k "$dom/$label" >/dev/null 2>&1 || true
    echo "launchd: (re)loaded $label"
  else
    echo "WARN: launchd bootstrap failed or timed out for $label (load manually if needed): $dest" >&2
  fi
}

# install_cmux_dock_guard_launchagent: cmux-dock-guard LaunchAgentの設置。
# cmux-dock-guard.sh自体はこのリポジトリ内蔵（symlink不要、直接パス参照）
# なのでusage-refreshのような前提ガードは無く常に設置する。
install_cmux_dock_guard_launchagent() {
  local dest="$HOME/Library/LaunchAgents/com.takumi009.cmux-dock-guard.plist"
  if ! generate_plist_from_template launchagents/com.takumi009.cmux-dock-guard.plist.template "$dest"; then
    echo "WARN: cmux-dock-guard plistの生成に失敗しました: $dest" >&2
    return
  fi
  echo "generated: $dest"
  if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$dest" >/dev/null 2>&1; then
    echo "WARN: 生成したplistが不正です（plutil -lint失敗）。launchdへの登録をskipします: $dest" >&2
    return
  fi
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    echo "SKIP_LAUNCHCTL=1のためlaunchdへの(再)登録はskipします（テスト用）"
    return
  fi
  install_launchagent "$dest"
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
chmod +x "$DIR/ghostty/start-tmux.sh" "$DIR/ghostty/cmux-session-cleanup.sh" "$DIR/cmux/claude-teams-launch.sh" "$DIR/cmux/claude-teams-entry.sh" "$DIR/cmux/cmux-next-watch/cmux-next-watch.sh" "$DIR/cmux/cmux-dock-guard/cmux-dock-guard.sh"

append_zsh_aliases_source
install_cmux_dock_guard_launchagent

cat <<'EOF'

Done. Apply each config:
  - tmux:        tmux source-file ~/.tmux.conf   (or restart tmux)
  - Hammerspoon: menubar 🔨 -> Reload Config
  - Ghostty:     Cmd+Shift+,                     (or restart Ghostty)
  - zsh:         cc/cct source line added to ~/.zshrc if missing
                 (restart zsh, or: source ~/.zshrc)
  - cmux Dock guard: LaunchAgent (re)loaded above, or skipped/WARNed;
                 watches for cmux relaunches and repairs a degraded
                 Dock automatically. Log: ~/.local/state/cmux-dock-guard/
  - Usage stats: not managed by this repo. See the separate
                 claude-codex-usage repo's own install.sh for the
                 refresh LaunchAgent + tmux/cmux usage rendering.
EOF
