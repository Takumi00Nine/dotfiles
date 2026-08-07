#!/bin/bash
# cmux Dock（Usage/Next/System の3コントロール）が壊れたまま放置されるのを防ぐ
# 常駐修復ツール。cmux 0.64系の既知仕様（dock.json は初回シード専用で、
# Dock コマンドが死ぬと対話シェルに降格しても再シードされない。上流
# https://github.com/manaflow-ai/cmux/issues/2544 未解決）に対する回避策。
#
# LaunchAgent から cmux 起動のたびに（WatchPaths + StartInterval の2経路で）
# 呼ばれる想定の1回実行スクリプト。常駐ループは持たない。
#
# 流れ: cmux起動確認 -> settle待ち -> 健全性判定(2回・間隔あり、誤検知防御)
#       -> 劣化時のみ修復(reload-config -> だめならnew-window方式) -> ログ記録
# 修復は「cmux起動インスタンスごとに最大1回」（PID+起動時刻マーカー）に制限し、
# WatchPaths の多重発火や暴走を防ぐ。通知は出さない（📣は本人呼び出し専用運用）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

# --- 設定（env で上書き可。本番は既定値のまま、テストは待ち時間を0にして高速化）---
CMUX_BIN="${CMUX_DOCK_GUARD_CMUX_BIN:-cmux}"
DOCK_JSON="${CMUX_DOCK_GUARD_DOCK_JSON:-$HOME/.config/cmux/dock.json}"
STATE_DIR="${CMUX_DOCK_GUARD_STATE_DIR:-$HOME/.local/state/cmux-dock-guard}"
# GUIアプリ本体のプロセスを起動インスタンス識別に使う（CLIの`cmux`バイナリとは別プロセス）。
APP_PATH="${CMUX_DOCK_GUARD_APP_PATH:-/Applications/cmux.app/Contents/MacOS/cmux}"

SETTLE_SECS="${CMUX_DOCK_GUARD_SETTLE_SECS:-30}"
RECHECK_GAP_SECS="${CMUX_DOCK_GUARD_RECHECK_GAP_SECS:-15}"
POST_REPAIR_SECS="${CMUX_DOCK_GUARD_POST_REPAIR_SECS:-5}"
LOCK_STALE_SECS="${CMUX_DOCK_GUARD_LOCK_STALE_SECS:-120}"

# env由来の数値を検証し、不正値は既定へ戻す（cmux-next-watch.sh と同じ流儀）。
case "$SETTLE_SECS" in ''|*[!0-9]*) SETTLE_SECS=30 ;; esac
case "$RECHECK_GAP_SECS" in ''|*[!0-9]*) RECHECK_GAP_SECS=15 ;; esac
case "$POST_REPAIR_SECS" in ''|*[!0-9]*) POST_REPAIR_SECS=5 ;; esac
case "$LOCK_STALE_SECS" in ''|*[!0-9]*) LOCK_STALE_SECS=120 ;; esac

LOCK_DIR="$STATE_DIR/lock"
MARKER_FILE="$STATE_DIR/last-evaluated-instance"
LOG_FILE="$STATE_DIR/guard.log"

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_FILE" 2>/dev/null
  printf '%s\n' "$1"
}

# get_instance_key: cmux.appプロセスのPID+起動時刻を「起動インスタンス」の
# 識別子として返す。1行の文字列。見つからなければ空文字を返す（呼び出し側は
# cmux未起動として扱う）。
#
# pgrep -f ではなく ps の全件出力を自前でフィルタする実装にしている。実機
# （macOS Darwin 25系）で `pgrep -f -x "$APP_PATH"` がcmux.appプロセスに対して
# 常に空振りする（該当プロセスは`ps`には確実に見えているのに）ことを実装中
# に実測した。原因は特定できていない（新しいmacOSの権限モデルの影響の可能性
# はあるが未確認）が、`ps -axo pid=,command=`は同条件で確実にヒットするため、
# こちらを正とする。
get_instance_key() {
  local pid start line
  line="$(ps -axo pid=,command= 2>/dev/null | awk -v want="$APP_PATH" '
    {
      l = $0
      sub(/^[ \t]+/, "", l)
      n = index(l, " ")
      if (n == 0) { next }
      p = substr(l, 1, n - 1)
      cmd = substr(l, n + 1)
      if (cmd == want) { print p; exit }
    }')"
  pid="$line"
  [ -z "$pid" ] && { echo ""; return; }
  start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//;s/ *$//')"
  [ -z "$start" ] && { echo ""; return; }
  printf '%s:%s' "$pid" "$start"
}

is_cmux_up() {
  "$CMUX_BIN" ping >/dev/null 2>&1
}

expected_titles() {
  [ -f "$DOCK_JSON" ] || { echo ""; return; }
  jq -r '.controls[]?.title // empty' "$DOCK_JSON" 2>/dev/null
}

observed_global_titles() {
  "$CMUX_BIN" --json tree --all 2>/dev/null \
    | jq -r '.. | objects | select(.dock_scope? == "global" and (.title? != null)) | .title' 2>/dev/null
}

# dock_healthy: dock.json の各controlのtitleが、いずれかの [dock:global]
# サーフェスのtitleとして観測できていれば健全とみなす。dock.jsonが読めない/
# controlsが空の場合は「判定不能」を安全側（健全扱い＝何もしない）に倒す。
dock_healthy() {
  local expected observed t missing
  expected="$(expected_titles)"
  if [ -z "$expected" ]; then
    log "WARN: dock.jsonからtitleを取得できません（${DOCK_JSON}）。健全性判定をスキップします"
    return 0
  fi
  observed="$(observed_global_titles)"
  missing=0
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if ! printf '%s\n' "$observed" | grep -qxF "$t"; then
      missing=1
    fi
  done <<EOF
$expected
EOF
  [ "$missing" = "0" ]
}

# repair_reload_config: `cmux reload-config`（= `cmux config reload`）を試す。
# dock.md: 「Explicitly reloading the Dock config still replaces the current
# Dock with the config contents.」— 明示リロードがDockをconfig内容へ置き換える
# 旨の記述はあるが、reload-configが劣化したDockを再シードできるかは未確認
# （このツールは直後に再判定して自己検証するので、効かなくても安全）。
repair_reload_config() {
  log "repair: cmux reload-config を試行"
  "$CMUX_BIN" reload-config >/dev/null 2>&1
}

# repair_new_window: リーダー実績の手順（2026-08-06/08-07）をスクリプト化。
# スナップショット無しの新ウィンドウはdock.jsonから再シードされる、という
# 前提のもとで: 新ウィンドウ作成 -> 全既存ウィンドウの全ワークスペースを新
# ウィンドウへ移動 -> 旧ウィンドウを閉鎖（旧ウィンドウ側に移動中に自動生成
# される空ワークスペースは、旧ウィンドウごと閉鎖されるため個別の移動・掃除は
# 不要）-> 新ウィンドウ側の初期空ワークスペースだけ`workspace close`で掃除。
repair_new_window() {
  local before after new_id old_ids old_id ws_ids ws_id default_ws remaining

  before="$("$CMUX_BIN" --json list-windows 2>/dev/null | jq -r '.[].id' 2>/dev/null)"
  if [ -z "$before" ]; then
    log "ERROR: repair_new_window: 既存ウィンドウ一覧の取得に失敗しました"
    return 1
  fi

  log "repair: cmux new-window で新ウィンドウを作成"
  if ! "$CMUX_BIN" new-window >/dev/null 2>&1; then
    log "ERROR: repair_new_window: new-window に失敗しました"
    return 1
  fi

  after="$("$CMUX_BIN" --json list-windows 2>/dev/null | jq -r '.[].id' 2>/dev/null)"
  new_id="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort))"
  if [ -z "$new_id" ] || [ "$(printf '%s\n' "$new_id" | wc -l | tr -d ' ')" != "1" ]; then
    log "ERROR: repair_new_window: 新規ウィンドウを一意に特定できませんでした（他操作との競合の可能性）。これ以上の自動操作は行いません"
    return 1
  fi

  default_ws="$("$CMUX_BIN" --json workspace list --window "$new_id" 2>/dev/null | jq -r '.workspaces[0].id // empty')"

  old_ids="$before"
  while IFS= read -r old_id; do
    [ -z "$old_id" ] && continue
    ws_ids="$("$CMUX_BIN" --json workspace list --window "$old_id" 2>/dev/null | jq -r '.workspaces[].id' 2>/dev/null)"
    while IFS= read -r ws_id; do
      [ -z "$ws_id" ] && continue
      log "repair: workspace $ws_id を新ウィンドウ $new_id へ移動"
      "$CMUX_BIN" move-workspace-to-window --workspace "$ws_id" --window "$new_id" >/dev/null 2>&1 \
        || log "WARN: repair_new_window: workspace $ws_id の移動に失敗しました（継続します）"
    done <<EOF
$ws_ids
EOF
  done <<EOF
$old_ids
EOF

  while IFS= read -r old_id; do
    [ -z "$old_id" ] && continue
    log "repair: 旧ウィンドウ $old_id を閉鎖"
    "$CMUX_BIN" close-window --window "$old_id" >/dev/null 2>&1 \
      || log "WARN: repair_new_window: ウィンドウ $old_id の閉鎖に失敗しました"
  done <<EOF
$old_ids
EOF

  # 新ウィンドウ側の初期空ワークスペースを掃除する。他に本物のワークスペースが
  # 移ってきていない（全体で1個しかない）場合は、ウィンドウを空にしないために残す。
  if [ -n "$default_ws" ]; then
    remaining="$("$CMUX_BIN" --json workspace list --window "$new_id" 2>/dev/null | jq -r '.workspaces | length' 2>/dev/null)"
    if [ -n "$remaining" ] && [ "$remaining" -gt 1 ]; then
      log "repair: 新ウィンドウの初期空ワークスペース $default_ws を掃除"
      "$CMUX_BIN" workspace close "$default_ws" >/dev/null 2>&1 \
        || log "WARN: repair_new_window: 初期空ワークスペース $default_ws の掃除に失敗しました（実害なし、残存するだけ）"
    fi
  fi

  return 0
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  # 古いロックが残っている（前回実行がクラッシュした等）場合は掃除して奪取する。
  local age
  age="$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))"
  if [ "$age" -gt "$LOCK_STALE_SECS" ]; then
    log "WARN: 古いロック（${age}秒経過）を除去して続行します: $LOCK_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null && return 0
  fi
  return 1
}
release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null

  # 起動インスタンスの特定はps（get_instance_key）のみで行い、cmux CLI
  # （ソケット通信）にはまだ触れない。既に判定済み・ロック中の再訪
  # （WatchPaths多重発火やポーリングの空振り）をcmuxへの呼び出し無しに
  # 早期リターンできるようにするため。
  local instance
  instance="$(get_instance_key)"
  if [ -z "$instance" ]; then
    # cmux.appプロセスが見つからない（通常の待機状態）。ログを汚さず静かに終了。
    exit 0
  fi

  if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE" 2>/dev/null)" = "$instance" ]; then
    # このcmux起動インスタンスは判定済み（WatchPaths多重発火/ポーリング再訪）。
    exit 0
  fi

  if ! acquire_lock; then
    # 別プロセスが同じインスタンスを判定中。ここで待たず即終了（次の発火に任せる）。
    exit 0
  fi
  trap release_lock EXIT

  # 再度マーカーを確認（ロック取得までの間に別プロセスが完了させた可能性）。
  if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE" 2>/dev/null)" = "$instance" ]; then
    exit 0
  fi

  if ! is_cmux_up; then
    # appプロセスはあるがソケットがまだ応答しない（起動途中）。マーカーは書かず、
    # このインスタンスの評価は次回の発火（WatchPaths再発火 or 次のポーリング）
    # に委ねる。
    exit 0
  fi

  log "start: instance=$instance settle=${SETTLE_SECS}s"
  sleep "$SETTLE_SECS"

  if dock_healthy; then
    log "ok: 1回目判定で健全"
    printf '%s' "$instance" > "$MARKER_FILE"
    exit 0
  fi

  log "warn: 1回目判定で劣化を検知。${RECHECK_GAP_SECS}秒後に再判定します（誤検知防御）"
  sleep "$RECHECK_GAP_SECS"

  if dock_healthy; then
    log "ok: 2回目判定で健全（誤検知として扱い、修復はしません）"
    printf '%s' "$instance" > "$MARKER_FILE"
    exit 0
  fi

  log "degraded: 2回連続で劣化を確認。修復を開始します"

  repair_reload_config
  sleep "$POST_REPAIR_SECS"
  if dock_healthy; then
    log "repaired: reload-configで復旧しました"
    printf '%s' "$instance" > "$MARKER_FILE"
    exit 0
  fi

  log "reload-configでは復旧しませんでした。new-window方式にフォールバックします"
  repair_new_window
  sleep "$POST_REPAIR_SECS"
  if dock_healthy; then
    log "repaired: new-window方式で復旧しました"
  else
    log "ERROR: 修復を試みましたが復旧を確認できませんでした。手動確認が必要です"
  fi
  # 成否によらずこのインスタンスへの再試行はしない（暴走防止。次のcmux起動まで待つ）。
  printf '%s' "$instance" > "$MARKER_FILE"
}

# テストからsourceして個別関数だけ呼べるよう、直接実行されたときだけmainを走らせる。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
