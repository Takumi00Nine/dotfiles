#!/bin/bash
# cmux Dock（dock.json に定義された Dock コントロール。現行 4＝Usage／Next Project／Next Task／System）が壊れたまま放置されるのを防ぐ
# 常駐修復ツール。cmux 0.64系の既知仕様（dock.json は初回シード専用で、
# Dock コマンドが死ぬと対話シェルに降格しても再シードされない。上流
# https://github.com/manaflow-ai/cmux/issues/2544 未解決）に対する回避策。
#
# LaunchAgent から cmux 起動のたびに（WatchPaths + StartInterval の2経路で）
# 呼ばれる想定の1回実行スクリプト。常駐ループは持たない。
#
# 流れ: cmux起動確認 -> settle待ち -> 健全性判定(2回・間隔あり、誤検知防御)
#       -> 劣化時のみnew-window方式で修復 -> ログ記録
# 健全性判定はtitle一致とプロセス生存の両方を見る（リーダー実測2026-08-07:
# Dockコマンドをkillした直後・cmux再起動を挟まない場合はtitleが古い値のまま
# 変化しないため、titleだけでは検知できない）。`cmux reload-config`による
# 再シードは同日の実機実験で「効かない」と確定したため修復手段には含めない。
# 修復は「cmux起動インスタンスごとに最大1回」（PID+起動時刻マーカー）に制限し、
# WatchPaths の多重発火や暴走を防ぐ。通知は出さない（📣は本人呼び出し専用運用）。
# 本ガードはcmux起動時に1回だけ評価する設計のため、起動後にDockペインを本人が
# 手動で閉じてもそのセッション中は再介入しない（次にcmuxを再起動した時に、
# その時点でのDock状態を評価して、dock.jsonに定義されたDockコントロール（現行4＝Usage／Next Project／Next Task／System）を常設インフラとして復元する。判定基準（title・プロセス生存）もdock.json由来）。
# cmux呼び出しは個別にタイムアウトさせ（cmux_run）、スクリプト全体にも
# ウォッチドッグを仕込む。launchdは同一Labelのジョブを多重起動しないため、
# どこか1箇所がハングすると以後永久に発火しなくなるのを防ぐため。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

# --- 設定（env で上書き可。本番は既定値のまま、テストは待ち時間を0にして高速化）---
CMUX_BIN="${CMUX_DOCK_GUARD_CMUX_BIN:-cmux}"
DOCK_JSON="${CMUX_DOCK_GUARD_DOCK_JSON:-$HOME/.config/cmux/dock.json}"
STATE_DIR="${CMUX_DOCK_GUARD_STATE_DIR:-$HOME/.local/state/cmux-dock-guard}"
# GUIアプリ本体のプロセスを起動インスタンス識別に使う（CLIの`cmux`バイナリとは別プロセス）。
APP_PATH="${CMUX_DOCK_GUARD_APP_PATH:-/Applications/cmux.app/Contents/MacOS/cmux}"

# Opus 5レビュー指摘(MAJOR)反映: 「Cmd+Q→再起動で目安60秒以内に復元」を
# 満たすため待ち時間を短縮。settle 30→12・recheck 15→6（本番既定。悪化を
# 静かに見逃さないためのsettle+2回判定という設計思想は変えず、値だけ縮める）。
SETTLE_SECS="${CMUX_DOCK_GUARD_SETTLE_SECS:-12}"
RECHECK_GAP_SECS="${CMUX_DOCK_GUARD_RECHECK_GAP_SECS:-6}"
POST_REPAIR_SECS="${CMUX_DOCK_GUARD_POST_REPAIR_SECS:-5}"
LOCK_STALE_SECS="${CMUX_DOCK_GUARD_LOCK_STALE_SECS:-120}"
# is_cmux_upが空振り（appプロセスはあるがソケット未応答=起動途中）した時の
# 短いリトライ。ここで粘らずに「次のWatchPaths/StartInterval発火待ち」に
# 倒すと、StartInterval短縮後でも最大20秒程度の空白が生まれる
# （Opus 5レビュー指摘・MAJOR）。
IS_UP_RETRIES="${CMUX_DOCK_GUARD_IS_UP_RETRIES:-10}"
IS_UP_RETRY_GAP_SECS="${CMUX_DOCK_GUARD_IS_UP_RETRY_GAP_SECS:-2}"
# cmux呼び出し1回あたりのタイムアウト。ソケット半死状態で1回のcmux呼び出しが
# 永久にハングすると、launchdは同一Labelのジョブを多重起動しない仕様のため、
# 以後WatchPaths/StartIntervalが一切発火しなくなる（Opus 5レビュー指摘・
# MAJOR）。
CMUX_CALL_TIMEOUT_SECS="${CMUX_DOCK_GUARD_CMUX_CALL_TIMEOUT_SECS:-15}"
# スクリプト全体のウォッチドッグ。個々のcmux呼び出しにタイムアウトを入れて
# いても、未知の理由（jq/ps/bash自体のハング等）でスクリプト全体が止まった
# 場合に備える最後の砦。
WATCHDOG_SECS="${CMUX_DOCK_GUARD_WATCHDOG_SECS:-300}"

# env由来の数値を検証し、不正値は既定へ戻す（cmux-next-watch.sh と同じ流儀）。
case "$SETTLE_SECS" in ''|*[!0-9]*) SETTLE_SECS=12 ;; esac
case "$RECHECK_GAP_SECS" in ''|*[!0-9]*) RECHECK_GAP_SECS=6 ;; esac
case "$POST_REPAIR_SECS" in ''|*[!0-9]*) POST_REPAIR_SECS=5 ;; esac
case "$LOCK_STALE_SECS" in ''|*[!0-9]*) LOCK_STALE_SECS=120 ;; esac
case "$IS_UP_RETRIES" in ''|*[!0-9]*) IS_UP_RETRIES=10 ;; esac
case "$IS_UP_RETRY_GAP_SECS" in ''|*[!0-9]*) IS_UP_RETRY_GAP_SECS=2 ;; esac
case "$CMUX_CALL_TIMEOUT_SECS" in ''|*[!0-9]*) CMUX_CALL_TIMEOUT_SECS=15 ;; esac
case "$WATCHDOG_SECS" in ''|*[!0-9]*) WATCHDOG_SECS=300 ;; esac

LOCK_DIR="$STATE_DIR/lock"
MARKER_FILE="$STATE_DIR/last-evaluated-instance"
LOG_FILE="$STATE_DIR/guard.log"
WATCHDOG_PID=""
LOCK_HELD=0

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_FILE" 2>/dev/null
  printf '%s\n' "$1"
}

# run_with_timeout / cmux_run: install.shのrun_with_timeoutと同じプロセス
# グループkillパターン（TERM→1秒猶予→KILL）。macOS標準bashにGNU timeoutが
# 無いための自前実装。cmux呼び出しをこれで包み、ソケット半死ハングが
# ジョブ自体を永久停止させるのを防ぐ。
# install.shのrun_with_timeoutとの違い: cmux_run経由の呼び出しは常に
# `x=$(cmux_run ... | jq ...)` のようなコマンド置換／パイプの中で使われる。
# コマンド置換・パイプの左辺はサブシェルで実行されるため、その中で作る
# ウォッチャー（`sleep secs; kill ...`という複数文のサブシェル）も、cmd自体
# と同様にプロセスグループ化してグループごとkillしないと、ウォッチャーが
# フォークした孫のsleepだけ生き残って標準出力のfdを握り続け、コマンド置換
# 全体がそのsleepの残り時間ぶんブロックし続ける（実装中に実測: 動作は正しい
# のに毎回まるまるタイムアウト秒数だけ遅くなる不具合を引き起こした）。その
# ためcmd・ウォッチャーの両方をset -mでプロセスグループ化し、両方とも
# `kill -TERM -PID`でグループごと終了させる。
run_with_timeout() {
  local secs="$1"
  shift
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  [ "$had_monitor" = "1" ] || set +m
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -TERM "-$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return "$rc"
}

cmux_run() {
  run_with_timeout "$CMUX_CALL_TIMEOUT_SECS" "$CMUX_BIN" "$@"
}

cleanup() {
  # プロセスグループごとkill（理由はWATCHDOG_PID起動側のコメント参照）。
  [ -n "$WATCHDOG_PID" ] && kill -TERM "-$WATCHDOG_PID" 2>/dev/null
  [ "$LOCK_HELD" = "1" ] && release_lock
}
trap cleanup EXIT
trap 'log "ERROR: SIGTERMを受信したため終了します（ウォッチドッグ発火の可能性）"; cleanup; trap - TERM; kill -TERM $$' TERM

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
  # -ww: 端末幅に合わせて出力を切り詰めない（launchd配下はtty無しで既定80桁に
  # なりうる。切れるとcmd==wantの完全一致が常に不成立になり、静かに「cmux
  # 未起動」扱いのまま何もしなくなる＝Opus 5レビュー指摘・MINOR）。
  line="$(ps -axww -o pid=,command= 2>/dev/null | awk -v want="$APP_PATH" '
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
  cmux_run ping >/dev/null 2>&1
}

expected_titles() {
  [ -f "$DOCK_JSON" ] || { echo ""; return; }
  jq -r '.controls[]?.title // empty' "$DOCK_JSON" 2>/dev/null
}

observed_global_titles() {
  cmux_run --json tree --all 2>/dev/null \
    | jq -r '.. | objects | select(.dock_scope? == "global" and (.title? != null)) | .title' 2>/dev/null
}

# expected_process_patterns: dock.json の各terminal controlのcommandから、
# 先頭トークン（実行ファイルパス）のbasenameを1行ずつ返す。$HOMEだけ安全に
# 展開する（evalはしない＝任意コマンド実行を避ける。展開はbasename抽出だけ
# なら不要そうに見えるが、直後の実行ファイル存在チェックにはフルパスが要る
# ので実際には必須）。実行ファイルが存在しない（`[ -x ]`で見えない）
# controlは判定対象から除外する。そうしないと、そのcontrolのスクリプトを
# 導入していないマシン（例: claude-codex-usageリポジトリ未導入でUsage
# controlの実体が無い）で永久に「劣化」判定になり、起動のたびにnew-window
# 修復が走り続けてしまう（Opus 5レビュー指摘・MAJOR）。browser control
# （typeが"browser"）はプロセスを持たないので対象外。
expected_process_patterns() {
  [ -f "$DOCK_JSON" ] || return
  jq -r '.controls[]? | select((.type // "terminal") == "terminal") | .command // empty' "$DOCK_JSON" 2>/dev/null \
    | while IFS= read -r cmdline; do
        [ -z "$cmdline" ] && continue
        expanded="${cmdline//\$HOME/$HOME}"
        expanded="${expanded//\${HOME\}/$HOME}"
        first="${expanded%% *}"
        [ -z "$first" ] && continue
        [ -x "$first" ] || continue
        basename "$first"
      done
}

# dock_processes_alive: dock.jsonの各terminal controlのcommandに対応する
# プロセスが実際に生きているかを確認する。titleとは独立した第2の判定軸
# （リーダー実測2026-08-07: Dockコマンドプロセスをkillした直後・cmux再起動を
# 挟まない場合、サーフェスのtitleは古い値「Usage」等のまま変化しない＝
# titleだけでは降格を検知できない）。expected_process_patternsが空（=判定
# 不能）の場合は安全側で健全扱いにする。
dock_processes_alive() {
  local patterns pat missing
  patterns="$(expected_process_patterns)"
  [ -z "$patterns" ] && return 0
  missing=0
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    pgrep -f -- "$pat" >/dev/null 2>&1 || missing=1
  done <<EOF
$patterns
EOF
  [ "$missing" = "0" ]
}

# dock_healthy: 次の両方が揃って初めて健全とみなす。
#   1. title判定: dock.jsonの各controlのtitleが、いずれかの[dock:global]
#      サーフェスのtitleとして観測できる（ペインが無い＝閉じられている場合も
#      当然不一致になり劣化として扱われる。本人決定2026-08-07: Usage/Next/
#      Systemは常設インフラ扱いで、セッション中に手動で閉じられていても
#      cmux再起動時には必ず復活させる）。
#   2. プロセス判定（dock_processes_alive）: 対応するプロセスが実際に生きて
#      いる。titleだけでは拾えない「セッション継続中の降格」を拾うため。
# dock.jsonが読めない/controlsが空の場合は「判定不能」を安全側（健全扱い＝
# 何もしない）に倒す。
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
  [ "$missing" != "0" ] && return 1
  dock_processes_alive
}

# repair_new_window: リーダー実績の手順（2026-08-06/08-07）をスクリプト化。
# スナップショット無しの新ウィンドウはdock.jsonから再シードされる、という
# 前提のもとで: 新ウィンドウ作成 -> 各既存ウィンドウのワークスペースを新
# ウィンドウへ移動 -> そのウィンドウの移動が全部成功した場合だけ`close-window`
# で閉鎖 -> 新ウィンドウ側の初期空ワークスペースだけ`workspace close`で掃除。
#
# 移動と閉鎖を「ウィンドウ単位」でまとめて行い、閉鎖はそのウィンドウの
# move-workspace-to-windowが1件でも失敗した場合はスキップする（Opus 5
# レビュー指摘・BLOCKING: 移動失敗を見逃して閉鎖すると、本人の作業中
# ワークスペースがウィンドウごと消える）。移動後にcmuxが自動生成する空
# ワークスペース（リーダー実測: 旧側にも新側と同様に生じうる）は、move
# コマンド自体の成否とは無関係にできる副産物なのでこの判定を妨げない
# （workspace listを閉鎖直前に再取得して「空かどうか」で見るのではなく、
# move呼び出し自身が報告した成否をそのまま信じる設計にしている）。
repair_new_window() {
  local before after new_id old_ids old_id ws_ids ws_id default_ws remaining move_failed

  before="$(cmux_run --json list-windows 2>/dev/null | jq -r '.[].id' 2>/dev/null)"
  if [ -z "$before" ]; then
    log "ERROR: repair_new_window: 既存ウィンドウ一覧の取得に失敗しました"
    return 1
  fi

  log "repair: cmux new-window で新ウィンドウを作成"
  if ! cmux_run new-window >/dev/null 2>&1; then
    log "ERROR: repair_new_window: new-window に失敗しました"
    return 1
  fi

  after="$(cmux_run --json list-windows 2>/dev/null | jq -r '.[].id' 2>/dev/null)"
  new_id="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort))"
  if [ -z "$new_id" ] || [ "$(printf '%s\n' "$new_id" | wc -l | tr -d ' ')" != "1" ]; then
    log "ERROR: repair_new_window: 新規ウィンドウを一意に特定できませんでした（他操作との競合の可能性）。これ以上の自動操作は行いません"
    return 1
  fi

  default_ws="$(cmux_run --json workspace list --window "$new_id" 2>/dev/null | jq -r '.workspaces[0].id // empty')"

  old_ids="$before"
  while IFS= read -r old_id; do
    [ -z "$old_id" ] && continue
    ws_ids="$(cmux_run --json workspace list --window "$old_id" 2>/dev/null | jq -r '.workspaces[].id' 2>/dev/null)"
    move_failed=0
    while IFS= read -r ws_id; do
      [ -z "$ws_id" ] && continue
      log "repair: workspace $ws_id を新ウィンドウ $new_id へ移動"
      if ! cmux_run move-workspace-to-window --workspace "$ws_id" --window "$new_id" >/dev/null 2>&1; then
        log "WARN: repair_new_window: workspace $ws_id の移動に失敗しました"
        move_failed=1
      fi
    done <<EOF
$ws_ids
EOF
    if [ "$move_failed" = "0" ]; then
      log "repair: 旧ウィンドウ $old_id を閉鎖"
      cmux_run close-window --window "$old_id" >/dev/null 2>&1 \
        || log "WARN: repair_new_window: ウィンドウ $old_id の閉鎖に失敗しました"
    else
      log "ERROR: repair_new_window: ウィンドウ $old_id で1件以上のワークスペース移動に失敗したため閉鎖せず残置します（手動確認が必要です）"
    fi
  done <<EOF
$old_ids
EOF

  # 新ウィンドウ側の初期空ワークスペースを掃除する。他に本物のワークスペースが
  # 移ってきていない（全体で1個しかない）場合は、ウィンドウを空にしないために残す。
  if [ -n "$default_ws" ]; then
    remaining="$(cmux_run --json workspace list --window "$new_id" 2>/dev/null | jq -r '.workspaces | length' 2>/dev/null)"
    if [ -n "$remaining" ] && [ "$remaining" -gt 1 ]; then
      log "repair: 新ウィンドウの初期空ワークスペース $default_ws を掃除"
      cmux_run workspace close "$default_ws" >/dev/null 2>&1 \
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

  # スクリプト全体のウォッチドッグ（Opus 5レビュー指摘・MAJOR）。個々のcmux
  # 呼び出しはcmux_runがタイムアウトさせるが、それ以外の場所で万一ハングした
  # 場合、launchdは同一Labelのジョブを多重起動しない仕様のため、以後
  # WatchPaths/StartIntervalが永久に発火しなくなる。それを防ぐ最後の砦として
  # WATCHDOG_SECS後に自分自身へSIGTERMを送る。
  # set -mでこのバックグラウンドジョブを独立プロセスグループにしてから
  # 起動する（run_with_timeoutと同じ理由）。`( sleep N; kill ... )`は2つの
  # コマンドを順に実行する複合サブシェルなので、sleepがまず子として
  # forkexecされる。cleanup側でこのサブシェル自体のPIDだけをkillすると、
  # 既にforkされたsleep孫プロセスは殺されずPID1へ再親化して生き残ってしまう
  # （実装中に実測: テストを繰り返すと`sleep 300`が何十個も残留した）。
  # プロセスグループごとkillすることでこれを防ぐ。
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  ( sleep "$WATCHDOG_SECS"; kill -TERM $$ 2>/dev/null ) &
  WATCHDOG_PID=$!
  [ "$had_monitor" = "1" ] || set +m

  if ! command -v "$CMUX_BIN" >/dev/null 2>&1; then
    log "ERROR: cmux CLIが見つかりません（CMUX_BIN=$CMUX_BIN PATH=$PATH）"
    exit 0
  fi

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
  LOCK_HELD=1

  # 再度マーカーを確認（ロック取得までの間に別プロセスが完了させた可能性）。
  if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE" 2>/dev/null)" = "$instance" ]; then
    exit 0
  fi

  # appプロセスはあるがソケットがまだ応答しない（起動途中）ことがあるため、
  # 短く粘ってから諦める。ここで即座に「次の発火待ち」にすると、
  # StartIntervalの間隔ぶん（既定20秒）の空白が生まれ、目安60秒以内の復元に
  # 食い込む（Opus 5レビュー指摘・MAJOR）。既定10回×2秒=最大20秒粘る。
  if ! is_cmux_up; then
    local up_tries=0 up=0
    while [ "$up_tries" -lt "$IS_UP_RETRIES" ]; do
      sleep "$IS_UP_RETRY_GAP_SECS"
      if is_cmux_up; then
        up=1
        break
      fi
      up_tries=$((up_tries + 1))
    done
    if [ "$up" != "1" ]; then
      # それでも応答しない。マーカーは書かず、このインスタンスの評価は
      # 次回の発火（WatchPaths再発火 or 次のポーリング）に委ねる。
      exit 0
    fi
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

  log "degraded: 2回連続で劣化を確認。new-window方式で修復を開始します"

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
