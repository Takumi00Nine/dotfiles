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
# SKIP_LAUNCHCTL と同じ考え方・同じ変数名）。本番運用では常に既定値=0のまま。
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
  # Back up a pre-existing real file (not a symlink) once.
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    cp "$dest" "$dest.pre-dotfiles.bak"
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

# install_usage_refresh_launchagent: usage-refresh LaunchAgent の設置。
# $HOME/work/claude-codex-usage/refresh.sh が無いマシン（サブ機等、このリポジトリの
# 想定外のユーザー名/構成のマシンを含む）では無条件設置せずskipする
# （2026-08-06 障害調査で確定: 実行パス・PATHがユーザー名込みでハードコードされた
# 実ファイルplistを、前提が無いマシンでも設置・launchctl実行していたのが原因）。
install_usage_refresh_launchagent() {
  local refresh_script="$HOME/work/claude-codex-usage/refresh.sh"
  local dest="$HOME/Library/LaunchAgents/com.takumi009.usage-refresh.plist"
  if [ ! -f "$refresh_script" ]; then
    echo "skip: usage-refresh LaunchAgent（$refresh_script が見つかりません）" >&2
    return
  fi
  if ! generate_plist_from_template launchagents/com.takumi009.usage-refresh.plist.template "$dest"; then
    echo "WARN: usage-refresh plistの生成に失敗しました: $dest" >&2
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
# .zshrcが無ければ新規作成する。メイン機の実.zshrcは直書きのcc/cct定義を
# まだ持っており、そちらの除去（source行への一本化）は別途本人が行う
# （このスクリプトは追記のみを担当）。
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
link tmux/tmux.conf              "$HOME/.tmux.conf"
link ghostty/config              "$HOME/.config/ghostty/config"
link ghostty/start-tmux.sh           "$HOME/.config/ghostty/start-tmux.sh"
link ghostty/cmux-session-cleanup.sh "$HOME/.config/ghostty/cmux-session-cleanup.sh"
link cmux/claude-teams-launch.sh     "$HOME/.local/bin/cmux-teams"
# cmux 本体設定・ドック定義・Next ペイン表示ツール（2026-08-06 追加。
# cmux.json=通知フィルタ等 / dock.json=Usage・Next・System の3コントロール /
# cmux-next-watch=dock.json から起動される表示スクリプト。tools/ 側の参照
# パス互換のため ~/work/tools/cmux-next-watch にも symlink を張る）
link cmux/cmux.json                  "$HOME/.config/cmux/cmux.json"
link cmux/dock.json                  "$HOME/.config/cmux/dock.json"
link cmux/cmux-next-watch            "$HOME/work/tools/cmux-next-watch"
chmod +x "$DIR/ghostty/start-tmux.sh" "$DIR/ghostty/cmux-session-cleanup.sh" "$DIR/cmux/claude-teams-launch.sh" "$DIR/cmux/claude-teams-entry.sh" "$DIR/cmux/cmux-next-watch/cmux-next-watch.sh"

install_usage_refresh_launchagent
append_zsh_aliases_source

cat <<'EOF'

Done. Apply each config:
  - tmux:        tmux source-file ~/.tmux.conf   (or restart tmux)
  - Hammerspoon: menubar 🔨 -> Reload Config
  - Ghostty:     Cmd+Shift+,                     (or restart Ghostty)
  - launchd:     usage-refresh agent (re)loaded above, or skipped/WARNed
                 if claude-codex-usage isn't present on this machine
  - zsh:         cc/cct source line added to ~/.zshrc if missing
                 (restart zsh, or: source ~/.zshrc)
EOF
