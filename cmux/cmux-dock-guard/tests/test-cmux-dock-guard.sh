#!/usr/bin/env bash
# cmux-dock-guard.sh のユニットテスト。実cmux・実launchd・実HOMEには一切依存
# しない。PATH上に偽の cmux/ps/pgrep を置き、待ち時間env(SETTLE等)は0にして
# 高速に実行する。
#
# 実行方法: bash tests/test-cmux-dock-guard.sh

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$TESTS_DIR/../cmux-dock-guard.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}

# --- 偽cmux/ps/pgrepをPATHへ配置する ---
# STUB_DIR配下の状態ファイルで挙動を制御する:
#   cmux_up            存在すればping成功
#   app_pid            psが返すcmux.appプロセスのPID
#   app_start          psが返すlstart文字列（変えると別インスタンス扱い）
#   observed_titles     tree --allが返すdock:globalタイトル一覧（改行区切り）
#   healthy_titles       new-window再シード時に使うタイトル一覧
#   alive_patterns       pgrepで「生きている」ことにするコマンドbasename一覧
#                        （改行区切り。dock_processes_aliveが参照する）
#   windows.tsv          "<id>\t<index>" 1行1ウィンドウ
#   ws_owner.tsv          "<workspace_id>\t<window_id>"
#   calls.log             stubが呼ばれた引数列のログ（検証用）
setup_stub_bin() {
  local stub_bin="$1" stub_dir="$2"
  mkdir -p "$stub_bin"

  cat > "$stub_bin/cmux" <<STUB
#!/usr/bin/env bash
STUB_DIR="$stub_dir"
echo "cmux \$*" >> "\$STUB_DIR/calls.log"

json=0
if [ "\${1:-}" = "--json" ]; then json=1; shift; fi
cmd="\${1:-}"; shift || true

case "\$cmd" in
  ping)
    [ -f "\$STUB_DIR/cmux_up" ] && exit 0 || exit 1
    ;;
  tree)
    titles=""
    if [ -f "\$STUB_DIR/observed_titles" ]; then
      titles="\$(cat "\$STUB_DIR/observed_titles")"
    fi
    printf '{"windows":[{"panes":[{"surfaces":['
    first=1
    while IFS= read -r t; do
      [ -z "\$t" ] && continue
      [ "\$first" = "1" ] || printf ','
      first=0
      printf '{"dock_scope":"global","title":"%s"}' "\$t"
    done <<EOF2
\$titles
EOF2
    printf ']}]}]}'
    # 誤検知シナリオ用: 1回目のtree呼び出し直後に、起動直後の一時的な汎用
    # タイトルからdock.json通りのタイトルへ自然に遷移した状態を模す
    # （self_heals_after_first_checkが置かれているときだけ・1回限り）。
    if [ -f "\$STUB_DIR/self_heals_after_first_check" ] && [ ! -f "\$STUB_DIR/self_heal_done" ]; then
      touch "\$STUB_DIR/self_heal_done"
      cp "\$STUB_DIR/healthy_titles" "\$STUB_DIR/observed_titles"
    fi
    ;;
  list-windows)
    printf '['
    first=1
    while IFS=\$'\t' read -r id idx; do
      [ -z "\$id" ] && continue
      [ "\$first" = "1" ] || printf ','
      first=0
      printf '{"id":"%s","index":%s}' "\$id" "\$idx"
    done < "\$STUB_DIR/windows.tsv"
    printf ']'
    ;;
  new-window)
    n=0
    [ -f "\$STUB_DIR/newwin_seq" ] && n="\$(cat "\$STUB_DIR/newwin_seq")"
    n=\$((n + 1))
    echo "\$n" > "\$STUB_DIR/newwin_seq"
    newid="NEWWIN\$n"
    idx=\$(wc -l < "\$STUB_DIR/windows.tsv" | tr -d ' ')
    printf '%s\t%s\n' "\$newid" "\$idx" >> "\$STUB_DIR/windows.tsv"
    printf '%s\t%s\n' "\${newid}-default" "\$newid" >> "\$STUB_DIR/ws_owner.tsv"
    if [ -f "\$STUB_DIR/newwin_reseeds" ]; then
      cp "\$STUB_DIR/healthy_titles" "\$STUB_DIR/observed_titles"
    fi
    if [ -f "\$STUB_DIR/newwin_revives_processes" ]; then
      cp "\$STUB_DIR/healthy_alive_patterns" "\$STUB_DIR/alive_patterns"
    fi
    exit 0
    ;;
  workspace)
    sub="\${1:-}"; shift || true
    case "\$sub" in
      list)
        # workspace list --window <id>
        wid=""
        while [ \$# -gt 0 ]; do
          if [ "\$1" = "--window" ]; then wid="\$2"; shift 2; else shift; fi
        done
        printf '{"window_ref":"%s","workspaces":[' "\$wid"
        first=1
        while IFS=\$'\t' read -r wsid ownerid; do
          [ -z "\$wsid" ] && continue
          [ "\$ownerid" = "\$wid" ] || continue
          [ "\$first" = "1" ] || printf ','
          first=0
          printf '{"id":"%s"}' "\$wsid"
        done < "\$STUB_DIR/ws_owner.tsv"
        printf ']}'
        ;;
      close)
        target="\${1:-}"
        awk -F'\t' -v t="\$target" '\$1 != t' "\$STUB_DIR/ws_owner.tsv" > "\$STUB_DIR/ws_owner.tsv.tmp" 2>/dev/null || true
        mv "\$STUB_DIR/ws_owner.tsv.tmp" "\$STUB_DIR/ws_owner.tsv" 2>/dev/null || true
        ;;
    esac
    ;;
  move-workspace-to-window)
    ws="" win=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --workspace) ws="\$2"; shift 2 ;;
        --window) win="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # fail_move_forに書かれたworkspace idと一致する場合は失敗させる（BLOCKING
    # 回帰テスト用: move失敗時に旧ウィンドウを閉じないことの検証）。実際の
    # cmuxのAPI失敗を模し、ws_owner.tsvは一切変更しない（移動していないので）。
    if [ -f "\$STUB_DIR/fail_move_for" ] && [ "\$(cat "\$STUB_DIR/fail_move_for")" = "\$ws" ]; then
      exit 1
    fi
    awk -F'\t' -v w="\$ws" '\$1 != w' "\$STUB_DIR/ws_owner.tsv" > "\$STUB_DIR/ws_owner.tsv.tmp" 2>/dev/null || true
    mv "\$STUB_DIR/ws_owner.tsv.tmp" "\$STUB_DIR/ws_owner.tsv"
    printf '%s\t%s\n' "\$ws" "\$win" >> "\$STUB_DIR/ws_owner.tsv"
    ;;
  close-window)
    win=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--window" ]; then win="\$2"; shift 2; else shift; fi
    done
    awk -F'\t' -v w="\$win" '\$1 != w' "\$STUB_DIR/windows.tsv" > "\$STUB_DIR/windows.tsv.tmp" 2>/dev/null || true
    mv "\$STUB_DIR/windows.tsv.tmp" "\$STUB_DIR/windows.tsv" 2>/dev/null || true
    awk -F'\t' -v w="\$win" '\$2 != w' "\$STUB_DIR/ws_owner.tsv" > "\$STUB_DIR/ws_owner.tsv.tmp" 2>/dev/null || true
    mv "\$STUB_DIR/ws_owner.tsv.tmp" "\$STUB_DIR/ws_owner.tsv" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$stub_bin/cmux"

  # 実機検証で `pgrep -f -x` がcmux.appプロセスに対して空振りすることが判明
  # したため、本体スクリプトは`ps -axww -o pid=,command=`の全件フィルタで起動
  # インスタンスを特定する（cmux-dock-guard.sh のコメント参照。-wwはOpus 5
  # レビュー指摘のMINOR対応で追加＝launchd配下tty無しでの列幅切り詰め防止）。
  # この偽psは本体が実際に発行する2種類の呼び出し方を両方エミュレートする:
  #   ps -axww -o pid=,command=   -> "<PID> <APP_PATH>" の1行（app_pidがあれば）
  #   ps -o lstart= -p <PID>      -> app_startの内容（app_pidと一致する時だけ）
  cat > "$stub_bin/ps" <<STUB
#!/usr/bin/env bash
STUB_DIR="$stub_dir"
if [ "\${1:-}" = "-axww" ]; then
  if [ -f "\$STUB_DIR/app_pid" ]; then
    printf '%s %s\n' "\$(cat "\$STUB_DIR/app_pid")" "/Applications/cmux.app/Contents/MacOS/cmux"
  fi
  exit 0
fi
if [ "\${1:-}" = "-o" ] && [ "\${2:-}" = "lstart=" ] && [ "\${3:-}" = "-p" ]; then
  target_pid="\${4:-}"
  if [ -f "\$STUB_DIR/app_pid" ] && [ -f "\$STUB_DIR/app_start" ] && [ "\$(cat "\$STUB_DIR/app_pid")" = "\$target_pid" ]; then
    cat "\$STUB_DIR/app_start"
    exit 0
  fi
  exit 1
fi
exit 1
STUB
  chmod +x "$stub_bin/ps"

  # dock_processes_alive用。本体は `pgrep -f -- "<basename>"` の形で呼ぶ
  # （最後の引数がパターン）。alive_patternsに完全一致する行があれば「生存」
  # として偽PIDを返す。
  cat > "$stub_bin/pgrep" <<STUB
#!/usr/bin/env bash
STUB_DIR="$stub_dir"
pat="\${*: -1}"
if [ -f "\$STUB_DIR/alive_patterns" ] && grep -qxF -- "\$pat" "\$STUB_DIR/alive_patterns" 2>/dev/null; then
  echo 99999
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_bin/pgrep"
}

# 共通の実行ラッパー: DOCK_JSON/STATE_DIRをテスト専用の使い捨てにし、待ち時間を0にする。
run_guard() {
  local stub_bin="$1" state_dir="$2" dock_json="$3"
  PATH="$stub_bin:$PATH" \
    CMUX_DOCK_GUARD_STATE_DIR="$state_dir" \
    CMUX_DOCK_GUARD_DOCK_JSON="$dock_json" \
    CMUX_DOCK_GUARD_SETTLE_SECS=0 \
    CMUX_DOCK_GUARD_RECHECK_GAP_SECS=0 \
    CMUX_DOCK_GUARD_POST_REPAIR_SECS=0 \
    bash "$TARGET"
}

# commandフィールドを持つ3コントロール構成。実dock.jsonと同じ3ペイン構成を
# 模す。expected_process_patternsは実行ファイルが存在しないcommandを判定
#対象から除外する仕様（Opus 5レビュー指摘・MAJOR対応）なので、テストでも
# $2で渡されたディレクトリに実在する（何もしない）ダミー実行ファイルを
# 作ってそのパスをcommandに書く。
make_dock_json() {
  local dock_json="$1" scripts_dir="$2"
  mkdir -p "$scripts_dir/fakebin"
  for name in usage-watch next-watch system-watch; do
    cat > "$scripts_dir/fakebin/$name.sh" <<'EOF'
#!/bin/bash
sleep 60
EOF
    chmod +x "$scripts_dir/fakebin/$name.sh"
  done
  cat > "$dock_json" <<EOF
{"controls":[
  {"id":"usage","title":"Usage","command":"$scripts_dir/fakebin/usage-watch.sh"},
  {"id":"next","title":"Next","command":"$scripts_dir/fakebin/next-watch.sh"},
  {"id":"system","title":"System","command":"$scripts_dir/fakebin/system-watch.sh"}
]}
EOF
}

# 3コントロール全部のプロセスが生きていることにする（title側だけを変化させる
# テストで、プロセス判定の方はデフォルトで通しておくためのヘルパー）。
set_all_processes_alive() {
  printf 'usage-watch.sh\nnext-watch.sh\nsystem-watch.sh\n' > "$1/alive_patterns"
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-dock-guard-test.XXXXXX")" || { echo "FATAL: mktemp -d に失敗しました" >&2; exit 1; }
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== (a) cmuxが起動していない場合は何もせず終了する ==="
{
  STUB_BIN="$WORKDIR/a/bin"; STUB_DIR="$WORKDIR/a/stub"; STATE_DIR="$WORKDIR/a/state"; DOCK_JSON="$WORKDIR/a/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  # cmux_upファイルを置かない = ping失敗

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "マーカーファイルは作られない" "$([ ! -f "$STATE_DIR/last-evaluated-instance" ] && echo 1 || echo 0)"
  # app_pidも置いていないため、psの時点でcmux.appプロセスが見つからず、
  # cmux CLI（ソケット通信）には一切触れずに終了するのが期待動作。
  assert_true "cmuxへは一度も呼び出しが走らない" \
    "$([ ! -f "$STUB_DIR/calls.log" ] && echo 1 || echo 0)"
}

echo "=== (b) 健全なDock（title一致＋プロセス生存）はそのまま ==="
{
  STUB_BIN="$WORKDIR/b/bin"; STUB_DIR="$WORKDIR/b/stub"; STATE_DIR="$WORKDIR/b/state"; DOCK_JSON="$WORKDIR/b/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/observed_titles"
  set_all_processes_alive "$STUB_DIR"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "マーカーファイルが書かれる" "$([ -f "$STATE_DIR/last-evaluated-instance" ] && echo 1 || echo 0)"
  assert_true "new-windowは呼ばれない" "$(! grep -q 'new-window' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "ログに『1回目判定で健全』が記録される" \
    "$(grep -q '1回目判定で健全' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (c) 1回目劣化・2回目健全（誤検知）は修復しない ==="
{
  STUB_BIN="$WORKDIR/c/bin"; STUB_DIR="$WORKDIR/c/stub"; STATE_DIR="$WORKDIR/c/state"; DOCK_JSON="$WORKDIR/c/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  # 起動直後は一時的に汎用タイトル("Terminal")、2回目判定時にはdock.json通りの
  # タイトルへ自然遷移している、というリーダー想定の誤検知シナリオを再現する。
  printf 'Usage\nNext\nTerminal\n' > "$STUB_DIR/observed_titles"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/healthy_titles"
  touch "$STUB_DIR/self_heals_after_first_check"
  set_all_processes_alive "$STUB_DIR"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "new-windowは呼ばれない" "$(! grep -q 'new-window' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "ログに『2回目判定で健全（誤検知として扱い』が記録される" \
    "$(grep -q '2回目判定で健全（誤検知として扱い' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (d) title一致でもプロセスが死んでいれば劣化として修復する ==="
# リーダー実測(2026-08-07): Dockコマンドのプロセスをkillした直後・cmux再起動を
# 挟まない場合、サーフェスのtitleは古い値のまま変化しない。title判定だけでは
# この状態を健全と誤判定してしまうため、プロセス生存判定を独立の軸として持つ。
{
  STUB_BIN="$WORKDIR/d/bin"; STUB_DIR="$WORKDIR/d/stub"; STATE_DIR="$WORKDIR/d/state"; DOCK_JSON="$WORKDIR/d/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  # titleは3つとも正しいまま(!)なのに、usage-watch.shのプロセスだけ死んでいる。
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/observed_titles"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/healthy_titles"
  printf 'next-watch.sh\nsystem-watch.sh\n' > "$STUB_DIR/alive_patterns"
  printf 'usage-watch.sh\nnext-watch.sh\nsystem-watch.sh\n' > "$STUB_DIR/healthy_alive_patterns"
  touch "$STUB_DIR/newwin_revives_processes"
  printf 'WIN1\t0\n' > "$STUB_DIR/windows.tsv"
  printf 'WS1\tWIN1\n' > "$STUB_DIR/ws_owner.tsv"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "titleが全部正しくてもnew-window修復が発動する" \
    "$(grep -q '^cmux new-window$' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "ログに『new-window方式で復旧』が記録される" \
    "$(grep -q 'new-window方式で復旧' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (e) Dockペインが存在しない(タイトルが全く現れない)場合も修復対象 ==="
# 本人決定(2026-08-07): Usage/Project/Task/Systemは常設インフラ扱い。セッション中に
# 手動で閉じられていても、cmux再起動時のチェックでは必ず復活させる。
{
  STUB_BIN="$WORKDIR/e/bin"; STUB_DIR="$WORKDIR/e/stub"; STATE_DIR="$WORKDIR/e/state"; DOCK_JSON="$WORKDIR/e/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  # Systemペイン自体が存在しない(タイトル一覧に無い。"Terminal"にすり替わる
  # のではなく、そもそも観測されない)。
  printf 'Usage\nNext\n' > "$STUB_DIR/observed_titles"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/healthy_titles"
  touch "$STUB_DIR/newwin_reseeds"
  set_all_processes_alive "$STUB_DIR"
  printf 'WIN1\t0\n' > "$STUB_DIR/windows.tsv"
  printf 'WS1\tWIN1\n' > "$STUB_DIR/ws_owner.tsv"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "存在しないSystemペインもnew-window修復の対象になる" \
    "$(grep -q '^cmux new-window$' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "ログに『new-window方式で復旧』が記録される" \
    "$(grep -q 'new-window方式で復旧' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (f) 2回連続で劣化 -> new-window方式で修復（複数ウィンドウ・複数ワークスペース） ==="
{
  STUB_BIN="$WORKDIR/f/bin"; STUB_DIR="$WORKDIR/f/stub"; STATE_DIR="$WORKDIR/f/state"; DOCK_JSON="$WORKDIR/f/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nTerminal\n' > "$STUB_DIR/observed_titles"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/healthy_titles"
  touch "$STUB_DIR/newwin_reseeds"
  set_all_processes_alive "$STUB_DIR"
  # 旧ウィンドウ2枚・ワークスペース計3個の複数窓構成を用意
  printf 'WIN1\t0\nWIN2\t1\n' > "$STUB_DIR/windows.tsv"
  printf 'WS1\tWIN1\nWS2\tWIN1\nWS3\tWIN2\n' > "$STUB_DIR/ws_owner.tsv"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "new-windowが呼ばれる" "$(grep -q '^cmux new-window$' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_eq "全3ワークスペースがmove-workspace-to-windowされる" "3" \
    "$(grep -c 'move-workspace-to-window' "$STUB_DIR/calls.log")"
  assert_eq "旧ウィンドウ2枚がclose-windowされる" "2" \
    "$(grep -c 'close-window' "$STUB_DIR/calls.log")"
  assert_true "新ウィンドウの初期空ワークスペースがworkspace closeで掃除される" \
    "$(grep -q 'workspace close NEWWIN1-default' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "最終的にWS1/WS2/WS3が新ウィンドウの所有になっている" \
    "$(awk -F'\t' '$1=="WS1"||$1=="WS2"||$1=="WS3" {print $2}' "$STUB_DIR/ws_owner.tsv" | sort -u | grep -qx 'NEWWIN1' && echo 1 || echo 0)"
  assert_true "ログに『new-window方式で復旧』が記録される" \
    "$(grep -q 'new-window方式で復旧' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (g) 2回連続で劣化 -> new-windowでも直らない場合はERRORログのみで暴走しない ==="
{
  STUB_BIN="$WORKDIR/g/bin"; STUB_DIR="$WORKDIR/g/stub"; STATE_DIR="$WORKDIR/g/state"; DOCK_JSON="$WORKDIR/g/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nTerminal\n' > "$STUB_DIR/observed_titles"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/healthy_titles"
  set_all_processes_alive "$STUB_DIR"
  printf 'WIN1\t0\n' > "$STUB_DIR/windows.tsv"
  printf 'WS1\tWIN1\n' > "$STUB_DIR/ws_owner.tsv"
  # newwin_reseedsを置かない = new-windowで作られた新ウィンドウもdock.json通り
  # には再シードされない(=修復失敗)ケース

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する(呼び出し元を落とさない)" "0" "$rc"
  assert_true "ERRORログが記録される" \
    "$(grep -q 'ERROR: 修復を試みましたが復旧を確認できませんでした' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
  assert_true "失敗しても以後の再試行はしない(マーカーは書かれる)" \
    "$([ -f "$STATE_DIR/last-evaluated-instance" ] && echo 1 || echo 0)"
}

echo "=== (h) 同一インスタンスへの2回目呼び出しは何もしない(WatchPaths多重発火対策) ==="
{
  STUB_BIN="$WORKDIR/h/bin"; STUB_DIR="$WORKDIR/h/stub"; STATE_DIR="$WORKDIR/h/state"; DOCK_JSON="$WORKDIR/h/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/observed_titles"
  set_all_processes_alive "$STUB_DIR"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  calls_after_first="$(wc -l < "$STUB_DIR/calls.log" | tr -d ' ')"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  calls_after_second="$(wc -l < "$STUB_DIR/calls.log" | tr -d ' ')"

  assert_eq "2回目呼び出しではcmuxへ追加の呼び出しをしない(pingすらしない早期終了)" \
    "$calls_after_first" "$calls_after_second"
}

echo "=== (i) 新しいcmux起動インスタンス(PID+起動時刻が変わる)は改めて判定する ==="
{
  STUB_BIN="$WORKDIR/i/bin"; STUB_DIR="$WORKDIR/i/stub"; STATE_DIR="$WORKDIR/i/state"; DOCK_JSON="$WORKDIR/i/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/observed_titles"
  set_all_processes_alive "$STUB_DIR"
  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  marker_first="$(cat "$STATE_DIR/last-evaluated-instance")"

  # 再起動を模す: PIDと起動時刻を変える
  echo "9999" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 22:30:00 2026" > "$STUB_DIR/app_start"
  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  marker_second="$(cat "$STATE_DIR/last-evaluated-instance")"

  assert_true "インスタンスキーが変わっている" "$([ "$marker_first" != "$marker_second" ] && echo 1 || echo 0)"
  # guard.logの各行は「タイムスタンプ メッセージ」なので、行頭アンカーは
  # タイムスタンプ側にかかる。メッセージ部分の出現回数を数えるので無アンカー。
  assert_true "新インスタンスでも判定ログが記録される(2回分)" \
    "$([ "$(grep -c 'start: instance=' "$STATE_DIR/guard.log")" = "2" ] && echo 1 || echo 0)"
}

echo "=== (j) dock.jsonが読めない場合は判定不能として何もしない ==="
{
  STUB_BIN="$WORKDIR/j/bin"; STUB_DIR="$WORKDIR/j/stub"; STATE_DIR="$WORKDIR/j/state"; DOCK_JSON="$WORKDIR/j/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  # DOCK_JSONをあえて作らない
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Terminal\n' > "$STUB_DIR/observed_titles"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "修復は試みない" "$(! grep -q 'new-window' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "WARNログが記録される" \
    "$(grep -q 'dock.jsonからtitleを取得できません' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (k) ロック中は多重実行しない ==="
{
  STUB_BIN="$WORKDIR/k/bin"; STUB_DIR="$WORKDIR/k/stub"; STATE_DIR="$WORKDIR/k/state"; DOCK_JSON="$WORKDIR/k/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/observed_titles"
  set_all_processes_alive "$STUB_DIR"
  mkdir -p "$STATE_DIR/lock"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "ロック中はcmuxを一切呼ばない" "$([ ! -f "$STUB_DIR/calls.log" ] && echo 1 || echo 0)"
  assert_true "マーカーも書かれない" "$([ ! -f "$STATE_DIR/last-evaluated-instance" ] && echo 1 || echo 0)"
}

echo "=== (l) ワークスペース移動が1件失敗したウィンドウは閉鎖しない(データ消失防止) ==="
# Opus 5レビュー指摘・BLOCKING回帰テスト。
{
  STUB_BIN="$WORKDIR/l/bin"; STUB_DIR="$WORKDIR/l/stub"; STATE_DIR="$WORKDIR/l/state"; DOCK_JSON="$WORKDIR/l/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nTerminal\n' > "$STUB_DIR/observed_titles"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/healthy_titles"
  touch "$STUB_DIR/newwin_reseeds"
  set_all_processes_alive "$STUB_DIR"
  # WIN1にWS1(移動成功)とWS2(移動失敗)、WIN2にWS3(移動成功)。
  printf 'WIN1\t0\nWIN2\t1\n' > "$STUB_DIR/windows.tsv"
  printf 'WS1\tWIN1\nWS2\tWIN1\nWS3\tWIN2\n' > "$STUB_DIR/ws_owner.tsv"
  echo "WS2" > "$STUB_DIR/fail_move_for"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "移動が全部成功したWIN2はclose-windowされる" \
    "$(grep -q 'close-window --window WIN2' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "移動漏れがあるWIN1はclose-windowされない(作業消失防止)" \
    "$(! grep -q 'close-window --window WIN1' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "WS2はWIN1所有のまま残る(移動されていない)" \
    "$(awk -F'\t' '$1=="WS2"{print $2}' "$STUB_DIR/ws_owner.tsv" | grep -qx 'WIN1' && echo 1 || echo 0)"
  assert_true "ERRORログに移動漏れの旨が記録される" \
    "$(grep -q 'ウィンドウ WIN1 で1件以上のワークスペース移動に失敗したため閉鎖せず残置' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (m) 実行ファイルが存在しないcontrolはプロセス判定から除外される ==="
# Opus 5レビュー指摘・MAJOR。claude-codex-usage等の依存リポジトリを導入して
# いないマシンで、対応する実行ファイルが存在しないcontrolを「常に劣化」と
# 誤判定して毎起動new-window修復が走り続けるのを防ぐ。
{
  STUB_BIN="$WORKDIR/m/bin"; STUB_DIR="$WORKDIR/m/stub"; STATE_DIR="$WORKDIR/m/state"; DOCK_JSON="$WORKDIR/m/dock.json"
  mkdir -p "$STUB_DIR"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_dock_json "$DOCK_JSON" "$STUB_DIR"
  # usageコントロールの実行ファイルを未導入マシン相当にする(削除)。
  rm -f "$STUB_DIR/fakebin/usage-watch.sh"
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'Usage\nNext\nSystem\n' > "$STUB_DIR/observed_titles"
  # next-watch.sh/system-watch.shだけ生存させる(usage-watch.shは実行ファイル
  # が無いので判定対象から除外され、生存有無を問われないはず)。
  printf 'next-watch.sh\nsystem-watch.sh\n' > "$STUB_DIR/alive_patterns"

  run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON"
  rc=$?
  assert_eq "exit 0で終了する" "0" "$rc"
  assert_true "実行ファイルが無いcontrolのプロセス不在は劣化とみなされず、修復されない" \
    "$(! grep -q 'new-window' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
  assert_true "ログに『1回目判定で健全』が記録される" \
    "$(grep -q '1回目判定で健全' "$STATE_DIR/guard.log" && echo 1 || echo 0)"
}

echo "=== (n) v6 AC-155: 環境変数前置つきの枠も生存判定の対象（WG-1・FR-115） ==="
# 要件 requirements-v6.md §7 WG-1・§8 AC-155／設計 design.md §41.7・§41.9。
# 実装への契約（source 後に直接呼ぶ関数名・口）:
#   expected_process_patterns … 判定対象の実行ファイルの basename を 1 行 1 件
#   dock_processes_alive       … 健全=戻り値 0／劣化=非 0
#   CMUX_DOCK_GUARD_DOCK_JSON  … dock.json の差し替え口（command 内の $HOME は展開）
# 生存の模擬＝既存の偽 pgrep（alive_patterns の basename 一覧・設計 M-v6-14）に
# 一本化し、実プロセスは起こさない。偽スクリプト a/b/c/e/f は実行可の存在判定の
# ためだけに置く（起動しない・missing は置かない）。
make_wg1() {  # $1=隔離HOME $2=dock.json（command は $HOME リテラルのまま）
  local n
  mkdir -p "$1/bin"
  for n in a b c e f; do printf '#!/bin/bash\nexit 0\n' > "$1/bin/$n.sh"; chmod +x "$1/bin/$n.sh"; done
  cat > "$2" <<'EOF'
{"controls":[
  {"id":"a","title":"A","command":"$HOME/bin/a.sh"},
  {"id":"b","title":"B","command":"K1=v1 $HOME/bin/b.sh"},
  {"id":"c","title":"C","command":"K1=v1 K_2=v2 $HOME/bin/c.sh"},
  {"id":"d","title":"D","command":"K1=v1 $HOME/bin/missing.sh"},
  {"id":"e","title":"E","command":"1A=1 $HOME/bin/e.sh"},
  {"id":"f","title":"F","command":"K1= $HOME/bin/f.sh"}
]}
EOF
}
# guard を source して関数を直接呼ぶ。$1=stub_bin $2=state_dir $3=dock.json $4=隔離HOME
# guard_targets → 判定対象の集合（sort 済・空白区切り）／guard_alive → 0=健全 1=劣化
guard_targets() {
  ( export HOME="$4" PATH="$1:$PATH" CMUX_DOCK_GUARD_STATE_DIR="$2" CMUX_DOCK_GUARD_DOCK_JSON="$3"
    . "$TARGET"
    expected_process_patterns ) | sort | tr '\n' ' ' | sed 's/ $//'
}
guard_alive() {
  ( export HOME="$4" PATH="$1:$PATH" CMUX_DOCK_GUARD_STATE_DIR="$2" CMUX_DOCK_GUARD_DOCK_JSON="$3"
    . "$TARGET"
    dock_processes_alive ) >/dev/null 2>&1 && echo 0 || echo 1
}
{
  STUB_BIN="$WORKDIR/n/bin"; STUB_DIR="$WORKDIR/n/stub"; STATE_DIR="$WORKDIR/n/state"; DOCK_JSON="$WORKDIR/n/dock.json"
  WG_HOME="$WORKDIR/n/home"
  mkdir -p "$STUB_DIR" "$WG_HOME"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  make_wg1 "$WG_HOME" "$DOCK_JSON"

  assert_eq "AC-155: 判定対象の集合が {a.sh, b.sh, c.sh, f.sh} と完全一致（(d) 実体なし・(e) 文法外は含まない）" \
    "a.sh b.sh c.sh f.sh" "$(guard_targets "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$WG_HOME")"
  printf 'a.sh\nb.sh\nc.sh\nf.sh\n' > "$STUB_DIR/alive_patterns"
  assert_eq "AC-155: (a)(b)(c)(f) が全部生きていれば健全" "0" "$(guard_alive "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$WG_HOME")"
  printf 'a.sh\nc.sh\nf.sh\n' > "$STUB_DIR/alive_patterns"
  assert_eq "AC-155: (b) 前置1つの枠だけが死ぬと劣化" "1" "$(guard_alive "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$WG_HOME")"
  printf 'a.sh\nb.sh\nf.sh\n' > "$STUB_DIR/alive_patterns"
  assert_eq "AC-155: (c) 前置2つの枠だけが死ぬと劣化" "1" "$(guard_alive "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$WG_HOME")"

  # main 経由でも同じ＝(b) だけ死んだ状態で new-window 修復が発動する（既存 (d) と同じ口）。
  touch "$STUB_DIR/cmux_up"
  echo "4242" > "$STUB_DIR/app_pid"
  echo "Fri Aug  7 21:00:00 2026" > "$STUB_DIR/app_start"
  printf 'A\nB\nC\nD\nE\nF\n' > "$STUB_DIR/observed_titles"
  printf 'A\nB\nC\nD\nE\nF\n' > "$STUB_DIR/healthy_titles"
  printf 'a.sh\nc.sh\nf.sh\n' > "$STUB_DIR/alive_patterns"
  printf 'a.sh\nb.sh\nc.sh\nf.sh\n' > "$STUB_DIR/healthy_alive_patterns"
  touch "$STUB_DIR/newwin_revives_processes"
  printf 'WIN1\t0\n' > "$STUB_DIR/windows.tsv"
  printf 'WS1\tWIN1\n' > "$STUB_DIR/ws_owner.tsv"
  HOME="$WG_HOME" run_guard "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" >/dev/null
  rc=$?
  assert_eq "AC-155(main): exit 0で終了する" "0" "$rc"
  assert_true "AC-155(main): (b) だけ死んだ状態で new-window 修復が発動する" \
    "$(grep -q '^cmux new-window$' "$STUB_DIR/calls.log" && echo 1 || echo 0)"
}

echo "=== (o) v6 DT-31: 前置の文法の境界（TAB／連続空白・前置3つ・値に =・値に空白） ==="
# 設計 §41.9.4 DT-31・§41.7.2。TAB／連続空白・前置 3 つ・K=a=b は対象に含む。
# K="a b" <実体> は前置 K="a ＋ 実体 b"（不在）と読まれて判定外。
{
  STUB_BIN="$WORKDIR/o/bin"; STUB_DIR="$WORKDIR/o/stub"; STATE_DIR="$WORKDIR/o/state"; DOCK_JSON="$WORKDIR/o/dock.json"
  DT_HOME="$WORKDIR/o/home"
  mkdir -p "$STUB_DIR" "$DT_HOME/bin"
  setup_stub_bin "$STUB_BIN" "$STUB_DIR"
  for n in tab sp three eq q; do printf '#!/bin/bash\nexit 0\n' > "$DT_HOME/bin/$n.sh"; chmod +x "$DT_HOME/bin/$n.sh"; done
  cat > "$DOCK_JSON" <<'EOF'
{"controls":[
  {"id":"tab","title":"Tab","command":"K1=v1\t$HOME/bin/tab.sh"},
  {"id":"sp","title":"Sp","command":"K1=v1   $HOME/bin/sp.sh"},
  {"id":"three","title":"Three","command":"K1=v1 K2=v2 K3=v3 $HOME/bin/three.sh"},
  {"id":"eq","title":"Eq","command":"K=a=b $HOME/bin/eq.sh"},
  {"id":"q","title":"Q","command":"K=\"a b\" $HOME/bin/q.sh"}
]}
EOF
  assert_eq "DT-31: 判定対象の集合が {eq.sh, sp.sh, tab.sh, three.sh}（K=\"a b\" の枠は判定外）" \
    "eq.sh sp.sh tab.sh three.sh" "$(guard_targets "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$DT_HOME")"
  printf 'eq.sh\nsp.sh\ntab.sh\nthree.sh\n' > "$STUB_DIR/alive_patterns"
  assert_eq "DT-31: 4 つが生きていれば健全（q.sh の生存は問われない）" "0" "$(guard_alive "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$DT_HOME")"
  printf 'eq.sh\nsp.sh\nthree.sh\n' > "$STUB_DIR/alive_patterns"
  assert_eq "DT-31: TAB 区切りの枠だけが死ぬと劣化" "1" "$(guard_alive "$STUB_BIN" "$STATE_DIR" "$DOCK_JSON" "$DT_HOME")"
}

echo "=== (p) v6 AC-154(c) 文書の追随（dock-guard の説明に「前置」） ==="
# 要件 §9「文書」＝cmux/cmux-dock-guard/README.md（無ければ cmux-dock-guard.sh の冒頭コメント）。
{
  DOC_GUARD="$TESTS_DIR/../README.md"
  if [ -r "$DOC_GUARD" ]; then
    DOC_TEXT="$(cat "$DOC_GUARD")"
  else
    DOC_TEXT="$(awk '/^[^#]/{exit} {print}' "$TARGET")"
  fi
  assert_true "AC-154(c): dock-guard の説明に 前置 を含む文が1つ以上（生存判定の対象になる旨）" \
    "$(printf '%s\n' "$DOC_TEXT" | grep -F '前置' | grep -qF '生存' && echo 1 || echo 0)"
}

echo "=== (q) 実装の内部不変条件: strip_env_prefix（前置の文法の正本・tests/test-cmux-dock-json.sh が source して使う） ==="
# 値は使わない・eval しない・前置だけの文字列はそのまま返す・剥がした後の先頭空白類は落とす。
strip_via_guard() {
  ( . "$TARGET"; strip_env_prefix "$1" )
}
{
  assert_eq "strip: 前置なしはそのまま" '$HOME/bin/a.sh' "$(strip_via_guard '$HOME/bin/a.sh')"
  assert_eq "strip: 前置1つ" '$HOME/bin/b.sh' "$(strip_via_guard 'K1=v1 $HOME/bin/b.sh')"
  assert_eq "strip: 前置2つ・空値" '$HOME/bin/f.sh' "$(strip_via_guard 'K1= K_2=v2 $HOME/bin/f.sh')"
  assert_eq "strip: 値に = を含む前置" '$HOME/bin/eq.sh' "$(strip_via_guard 'K=a=b $HOME/bin/eq.sh')"
  assert_eq "strip: TAB＋連続空白の区切り" '$HOME/bin/t.sh' "$(strip_via_guard "$(printf 'K1=v1\t  K2=v2\t$HOME/bin/t.sh')")"
  assert_eq "strip: 文法外（1A=1）は剥がさない" '1A=1 $HOME/bin/e.sh' "$(strip_via_guard '1A=1 $HOME/bin/e.sh')"
  assert_eq "strip: 文法外（K-1=1）は剥がさない" 'K-1=1 x' "$(strip_via_guard 'K-1=1 x')"
  assert_eq "strip: 前置だけ（本体なし）はそのまま" 'K1=v1' "$(strip_via_guard 'K1=v1')"
  assert_eq "strip: 値の途中の空白は K=\"a を前置とし b\" 以降を残す" 'b" $HOME/bin/q.sh' "$(strip_via_guard 'K="a b" $HOME/bin/q.sh')"
  assert_eq "strip: 本体の後ろの引数は保持" '$HOME/bin/a.sh --x' "$(strip_via_guard 'K=1 $HOME/bin/a.sh --x')"
  assert_eq "strip: 値に \$(…) や \$HOME があっても展開・実行せず文字列として読み飛ばす（eval しない）" \
    '$HOME/bin/a.sh' "$(strip_via_guard 'K=$(hostname) H=$HOME $HOME/bin/a.sh')"
}

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
