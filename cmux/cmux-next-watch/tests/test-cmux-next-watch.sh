#!/bin/bash
# cmux-next-watch.sh のユニットテスト（cmux-session-todo 設計 v3・RP層）。
# ai-env が1バイトも無い隔離環境でも通る（呼び出し口はP群スタブ・AC-107）。
#
# 実行方法: bash cmux/cmux-next-watch/tests/test-cmux-next-watch.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CMUX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCH="$SCRIPT_DIR/../cmux-next-watch.sh"
STUBS="$CMUX_DIR/tests/lib-supply-stubs.sh"
TICKLIB="$CMUX_DIR/tests/lib-tick-bytes.sh"

[ -r "$WATCH" ] || { echo "FATAL: 見つかりません: $WATCH" >&2; exit 1; }
[ -r "$STUBS" ] || { echo "FATAL: 見つかりません: $STUBS" >&2; exit 1; }
[ -r "$TICKLIB" ] || { echo "FATAL: 見つかりません: $TICKLIB" >&2; exit 1; }
. "$CMUX_DIR/lib-dock-view.sh"
. "$CMUX_DIR/lib-supply-frame.sh"
. "$STUBS"
. "$TICKLIB"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-cmux-next-watch.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

# AC-123のTMPDIR集合比較が実launchd常駐(cmux-task-watch/cmux-next-watch)の
# 同時ティックと衝突する時限フレーク対策（設計 F-79・DT-15・D-v4-10で
# task側と同じ巡でnext-watch側も隔離）。WORKDIRを作った後に隔離用の
# サブディレクトリへTMPDIRを差し替える（自己参照回避のため順序は変えない）。
mkdir -p "$WORKDIR/tmp"
export TMPDIR="$WORKDIR/tmp"

PASS=0
FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); echo "FAIL: $desc"; fi
}

run_watch() {  # $1=supply-path 残り=引数
  local supply="$1"; shift
  CMUX_DOCK_SUPPLY_PROJECT="$supply" bash "$WATCH" "$@"
}

now_mono() { python3 -c 'import time; print(time.monotonic())'; }

# --- Project v3 フレーム生成（health-self-explain 設計 v1.2 §6・D-3） ------
# 検証1巡目C-1で共有fixture（cmux/tests/lib-supply-stubs.sh の
# mk_stub_P6_project／_p6_proj_lines）を新契約（B行=外部脳1種・
# bkind/bwarn/btextの上書き対応・v5でP行6欄）へ更新したため、このファイル
# 内に同じ組み立てを重複実装せず共有stubをそのまま呼ぶ。P行の既定値は
# _p6_proj_linesの既定と同一（既存の期待値EXPECT_P6等をそのまま流用
# できる）。

# $1=PID を上限秒(既定10秒)までポーリングで待ち、それでも生きていたら-9で
# 強制終了する（テスト側の安全弁・検証1巡目 #14）。
wait_pid_bounded() {
  local pid="$1" limit="${2:-100}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1; waited=$(( waited + 1 ))
  done
  kill -9 "-$pid" 2>/dev/null
  kill -9 "$pid" 2>/dev/null
  return 1
}

# Project期待フレーム（8行・空行2行を含む。外部脳ヘルス行は
# health-self-explain 設計 v1.2 §6・D-3＝見出し行なしの1行）。
# v7 読み替え（FR-117・FR-119）＝エントリ行の先頭 2 セル（▶ 欄・対象なし＝空白 2）・
# 稼働中の見出し記号 ●。
EXPECT_P6="$(printf '● 稼働中 (2)\n  5 svwb-pilot 実データ照合を回す\n  6 takumi009- (next未設定)\n\n⏸ 保留 (1)\n  7 avatar-swi 配布方式のたたき台を書く\n\n外部脳 OK')"

echo "=== AC-91: Project期待フレーム8行との完全一致（色なし比較） ==="
mk_stub_P6_project "$WORKDIR/p6" 5 6 7
OUT="$(CMUX_NEXT_ROWS=40 run_watch "$WORKDIR/p6" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_eq "AC-91: --once の出力(色除去後)が期待フレームと完全一致" "$EXPECT_P6" "$OUT"
assert_eq "AC-91: 行数は8(見出し行が無くなった分だけ旧v3.5の10行より減る)" "8" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

echo "=== 外部脳ヘルス行（health-self-explain 設計 v1.2 §6） ==="
assert_true "extbrain_no_heading_one_line: ⚠/✅の見出し行が0件" \
  "$(printf '%s\n' "$OUT" | grep -qE '⚠ 外部脳|✅ 外部脳' && echo 0 || echo 1)"
assert_true "extbrain_no_heading_one_line: 外部脳ブロックはちょうど1行" \
  "$([ "$(printf '%s\n' "$OUT" | grep -cF '外部脳')" -eq 1 ] && echo 1 || echo 0)"

# extbrain_three_colors_error_red: warn値ごとに正しい色が乗る（本人裁定
# OQ-1のERR_C=38;5;203を含む3色）。色を消さない生出力で見る。
# v5: 高さが取得不能なら h_def=4（FR-101③）になり tty 無しの実行では
# 外部脳行が落ちるため、高さを 40 に固定する（期待値は不変・下の suffix も同じ）。
for spec in "ok:114" "warn:214" "error:203"; do
  bwarn="${spec%%:*}" expect_code="${spec#*:}"
  mk_stub_P6_project "$WORKDIR/color_$bwarn" 5 6 7 外部脳 "$bwarn" "TXT"
  COLOR_RAW="$(CMUX_NEXT_ROWS=40 run_watch "$WORKDIR/color_$bwarn" --once)"
  assert_true "extbrain_three_colors_error_red(${bwarn}): 38;5;${expect_code}が外部脳行に乗る" \
    "$(printf '%s' "$COLOR_RAW" | grep -qF "$(printf '\033')[38;5;${expect_code}m外部脳 TXT" && echo 1 || echo 0)"
done

# extbrain_suffix_candidates_rendered: 末尾の「候補N件」付記（供給側が
# 付ける・0件も表示＝R-2）をそのまま逐語で描く。
mk_stub_P6_project "$WORKDIR/suffix" 5 6 7 外部脳 ok "OK 候補390件"
OUT_SUFFIX="$(CMUX_NEXT_ROWS=40 run_watch "$WORKDIR/suffix" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_true "extbrain_suffix_candidates_rendered: 「外部脳 OK 候補390件」が逐語で出る" \
  "$(printf '%s\n' "$OUT_SUFFIX" | grep -qxF '外部脳 OK 候補390件' && echo 1 || echo 0)"

# compose_frame_n_ext_equals_n_b: 旧実装(n_ext=n_b+1・見出し1行分を過剰
# 計上)ならCMUX_NEXT_ROWS=9でクランプが要ると誤判定し「…他」行が出る。
# 新実装(n_ext=n_b)は8行ちょうどに収まりクランプ不要（設計v1.2 §6）。
OUT_BOUND="$(CMUX_NEXT_ROWS=9 run_watch "$WORKDIR/p6" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_eq "compose_frame_n_ext_equals_n_b: ROWS=9境界でも期待フレームと完全一致(クランプなし)" "$EXPECT_P6" "$OUT_BOUND"
assert_true "compose_frame_n_ext_equals_n_b: 「…他」行が出ない" \
  "$(printf '%s\n' "$OUT_BOUND" | grep -qF '…他' && echo 0 || echo 1)"

# version_mismatch_line_unchanged: 旧Project契約(cmux-dock-frame/1)を
# 名乗るフレームはAC-97③等と同じ縮退文言「AI環境 版ちがい」（値そのもの
# は非互換版上げで変わったが、縮退時の固定文言は不変）。
{
  printf '#V\tcmux-dock-frame/1\tProject\n'
  printf 'P\t5\tsvwb-pilot-log\t実データ照合を回す\t稼働中\t\n'
  printf 'E\t1\n'
} > "$WORKDIR/oldver.data"
cat > "$WORKDIR/oldver" <<'EOF'
#!/bin/bash
cat "$0.data"
EOF
chmod +x "$WORKDIR/oldver"
OUT_OLDVER="$(run_watch "$WORKDIR/oldver" --once)"
assert_eq "version_mismatch_line_unchanged: 旧/1はAI環境 版ちがい" "AI環境 版ちがい" "$OUT_OLDVER"

# ヘルス行0行のフレームを直接組み立てる（B行を含まない）。
{
  printf '#V\tcmux-dock-frame/4\tProject\n'
  printf 'P\t5\tsvwb-pilot-log\t実データ照合を回す\t稼働中\t\n'
  printf 'E\t1\n'
} > "$WORKDIR/p6_nohealth.data"
cat > "$WORKDIR/p6_nohealth" <<'EOF'
#!/bin/bash
cat "$0.data"
EOF
chmod +x "$WORKDIR/p6_nohealth"
OUT2="$(CMUX_NEXT_ROWS=40 run_watch "$WORKDIR/p6_nohealth" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_true "AC-97②: ヘルス行0行では外部脳ブロックごと出ない" \
  "$(printf '%s\n' "$OUT2" | grep -qF '外部脳' && echo 0 || echo 1)"

mk_stub_P1a "$WORKDIR/p1a"
OUT3="$(run_watch "$WORKDIR/p1a" --once)"
assert_eq "AC-97③(単発): 未導入直後は理由行1行だけ" "AI環境 未導入" "$OUT3"

# AC-97③本体: 常駐を1つ立て、まずP-6(ヘルスあり)を描かせてから供給側を
# P-1aへ切り替え、次のフレームに前ティックのヘルス行が1行も残らないこと
# を実際の2ティックで確かめる（単発呼び出しの検査だけでは「前ティックが
# そもそも無い」ケースしか見ないため・検証1巡目 #14）。
STATE_LINK97="$WORKDIR/state97"
ln -sf "$WORKDIR/p6" "$STATE_LINK97"
LOG97="$WORKDIR/carryover97.log"
# v7（R-v7-3）＝常駐のループは対象周期で回るので対象周期 1 も指定する。
CMUX_DOCK_SUPPLY_PROJECT="$STATE_LINK97" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_FOCUS_INTERVAL=1 CMUX_NEXT_ROWS=40 \
  bash "$WATCH" >"$LOG97" 2>/dev/null &
DPID97=$!
sleep 1.5
ln -sf "$WORKDIR/p1a" "$STATE_LINK97"
sleep 1.5
kill -TERM "$DPID97" 2>/dev/null; wait_pid_bounded "$DPID97" 50
LAST97="$(python3 - "$LOG97" <<'PYEOF'
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
blocks = re.findall(r"\x1b\[H(.*?)\x1b\[J", data, re.S)
last = blocks[-1] if blocks else ""
last = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", last).replace("\r", "")
print(last.rstrip("\n"))
PYEOF
)"
assert_eq "AC-97③(2ティック): 縮退後は理由行1行だけで外部脳ブロックが残らない" "AI環境 未導入" "$LAST97"

echo "=== AC-87: ドメインデータに触っていない（Project） ==="
OUT4="$(CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/p6" \
  CMUX_NEXT_VAULT="$WORKDIR/does-not-exist-vault" \
  CMUX_NEXT_ROWS=40 bash "$WATCH" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_eq "AC-87①: ドメインデータ不在でも期待フレームと完全一致" "$EXPECT_P6" "$OUT4"

mkdir -p "$WORKDIR/trap-vault/Projects"
echo "trap" > "$WORKDIR/trap-vault/Projects/svwb-pilot-log.md"
OUT5="$(CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/p6" \
  CMUX_NEXT_VAULT="$WORKDIR/trap-vault" \
  CMUX_NEXT_INVENTORY_DIR="$WORKDIR/trap-vault/inv" \
  CMUX_NEXT_ROWS=40 bash "$WATCH" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_eq "AC-87②: ドメインデータを実在させ矛盾させても期待フレームと完全一致" "$EXPECT_P6" "$OUT5"

# 走査対象は「描画側のソースと同一repo内のlib」の4ファイル全部（設計
# §31.5）。$WATCH単体だけでは、lib-supply-frame.sh/lib-dock-view.shに
# ドメイン環境変数名等が紛れ込んでも検出できない（検証2巡目 #24）。
# v7 AC-163 ④（FR-124 ⑩＝裁定 2）＝v7 で触る描画側 3 ファイルに同じ式をそのまま
# 当てる（宣言先の解決は供給側・描画側は cmux・宣言記録に触れない）。
RENDER_FILES=("$WATCH" "$CMUX_DIR/lib-dock-view.sh" "$CMUX_DIR/lib-supply-frame.sh")
assert_true "AC-87③: ソース(描画側4ファイル)にドメイン環境変数名が0件" \
  "$(grep -qE 'CMUX_NEXT_VAULT|CMUX_TASK_VAULT|CMUX_TASK_STATE' "${RENDER_FILES[@]}" && echo 0 || echo 1)"
assert_true "AC-87③: ソース(描画側4ファイル)に固定パスが0件" \
  "$(grep -qE 'Data/obsidian|\.config/cmux-task-watch|\.claude/logs' "${RENDER_FILES[@]}" && echo 0 || echo 1)"
assert_true "AC-87③: ソース(描画側4ファイル)にcmuxの呼び出しが0件" \
  "$(grep -qE '(^|[;&|(]|\$\()[[:space:]]*cmux[[:space:]]+(--json|identify|workspace|list-windows)' "${RENDER_FILES[@]}" && echo 0 || echo 1)"

echo "=== AC-88: 5ティックで供給側の呼出しがちょうど5回前後 ==="
# v7（R-v7-3）＝供給側は --frame（フレーム周期）と --focus（対象周期）の 2 引数で
# 呼ばれるので、スパイは引数を記録し --frame だけを数える（引数別集計）。
# フレーム周期 1・対象周期 1＝毎ティック --frame が 1 回。
SPY_LOG="$WORKDIR/spy.log"
: > "$SPY_LOG"
cat > "$WORKDIR/spy_supply" <<SPYEOF
#!/bin/bash
echo "call \${1:-}" >> "$SPY_LOG"
if [ "\${1:-}" = "--focus" ]; then echo; exit 0; fi
TAB="\$(printf '\t')"
printf '#V%scmux-dock-frame/4%sProject\n' "\$TAB" "\$TAB"
printf 'P%s1%sspy%s%s稼働中%s\n' "\$TAB" "\$TAB" "\$TAB" "\$TAB" "\$TAB"
printf 'E%s1\n' "\$TAB"
SPYEOF
chmod +x "$WORKDIR/spy_supply"
spy_frame_calls() { grep -c 'call --frame$' "$SPY_LOG" 2>/dev/null | tr -d ' '; }
AC88_INTERVAL=1
AC88_T0="$(now_mono)"
CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/spy_supply" CMUX_NEXT_INTERVAL="$AC88_INTERVAL" CMUX_NEXT_FOCUS_INTERVAL="$AC88_INTERVAL" CMUX_NEXT_ROWS=40 \
  bash "$WATCH" >/dev/null 2>&1 &
DAEMON_PID=$!
# 5回目を検出したら即killし、6回目の発生を防いで「ちょうど5件(±0)」を
# wall-clockのsleepより厳密に検査する（検証1巡目 #14）。
waited=0
CALLS=0
while [ "$waited" -lt 150 ]; do
  CALLS="$(spy_frame_calls)"
  is_number "$CALLS" || CALLS=0
  [ "$CALLS" -ge 5 ] && break
  sleep 0.05
  waited=$(( waited + 1 ))
done
AC88_T1="$(now_mono)"
kill -TERM "$DAEMON_PID" 2>/dev/null
wait_pid_bounded "$DAEMON_PID" 50
sleep 0.2
CALLS="$(spy_frame_calls)"
assert_eq "AC-88: 5ティックで供給側の --frame 呼出しがちょうど5回(±0)" "5" "$CALLS"
# 呼出回数だけでなく間隔も見る（検証2巡目 #31）。5回に達するまでの経過が
# 4×interval未満なら、ティック間隔が縮む倍呼び系の退行を見逃す。
AC88_ELAPSED="$(python3 -c "print($AC88_T1 - $AC88_T0)")"
assert_true "AC-88: 5回目までの経過が4×interval(=4秒)以上(検証2巡目#31)" \
  "$(python3 -c "print(1 if $AC88_ELAPSED >= 4 * $AC88_INTERVAL else 0)")"

echo "=== AC-90: FR-72の描画射影（切り詰め・クランプ・件数一致） ==="
# 10コードポイント超の正式名と幅に収まらないnext値・クランプなし(M-4=幅16)。
{
  printf '#V\tcmux-dock-frame/4\tProject\n'
  printf 'P\t1\tavatar-switch-plan-long-name\t配布方式のたたき台を書く長い説明文\t稼働中\t\n'
  printf 'E\t1\n'
} > "$WORKDIR/p90a.data"
cat > "$WORKDIR/p90a" <<'EOF'
#!/bin/bash
cat "$0.data"
EOF
chmod +x "$WORKDIR/p90a"
OUT6="$(CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=16 run_watch "$WORKDIR/p90a" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
NAME_LINE="$(printf '%s\n' "$OUT6" | sed -n '2p')"
assert_true "AC-90③: 正式名は10コードポイントへ切り詰められる" \
  "$(printf '%s' "$NAME_LINE" | awk '{print $2}' | python3 -c 'import sys; s=sys.stdin.readline().rstrip("\n"); print(1 if len(s)<=10 else 0)')"

# クランプあり（高さ8）＝各区分の見出しの件数が全行数と一致(落ちた分だけ減らない)
{
  printf '#V\tcmux-dock-frame/4\tProject\n'
  for i in 1 2 3 4 5; do
    printf 'P\t%d\tproj-%d\tnext-%d\t稼働中\t\n' "$i" "$i" "$i"
  done
  printf 'P\t6\tproj-6\tnext-6\t保留\t\n'
  printf 'E\t6\n'
} > "$WORKDIR/p90b.data"
cat > "$WORKDIR/p90b" <<'EOF'
#!/bin/bash
cat "$0.data"
EOF
chmod +x "$WORKDIR/p90b"
OUT7="$(CMUX_NEXT_ROWS=8 CMUX_NEXT_COLS=40 run_watch "$WORKDIR/p90b" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_true "AC-90④: 稼働中見出しの件数(5)はクランプで行が落ちても不変" \
  "$(printf '%s\n' "$OUT7" | grep -qF '稼働中 (5)' && echo 1 || echo 0)"
assert_true "AC-90④: 保留見出しの件数(1)は不変" \
  "$(printf '%s\n' "$OUT7" | grep -qF '保留 (1)' && echo 1 || echo 0)"

echo "=== 同一フレーム抑止の回帰（検証1巡目#9・検証2巡目#25②） ==="
# 同じP-6をProjectへ2ティック与え、2ティック目は同期出力0バイトになる
# （cmux-next-watch.sh:305のif [ "$frame" != "$last_frame" ]...を
# if trueへ差し戻すと出力が積み上がりFAILになる）。
mk_stub_P6_project "$WORKDIR/same_p6" 5 6 7
SAMELOG="$WORKDIR/same_frame.log"
# v7（R-v7-3）＝対象周期 1 も指定（ループは対象周期で回る）。
CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/same_p6" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_FOCUS_INTERVAL=1 CMUX_NEXT_ROWS=40 \
  bash "$WATCH" >"$SAMELOG" 2>/dev/null &
SAME_PID=$!
sleep 1.5   # 1ティック目の同期描画を確実に待つ
SIZE_1="$(wc -c < "$SAMELOG" | tr -d ' ')"
sleep 1.2   # 2ティック目のsleep区間を跨ぐ（フレーム不変のはず）
SIZE_2="$(wc -c < "$SAMELOG" | tr -d ' ')"
kill -TERM "$SAME_PID" 2>/dev/null; wait_pid_bounded "$SAME_PID" 50
assert_true "同一フレーム抑止: 1ティック目で何か描画された" "$([ "$SIZE_1" -gt 0 ] && echo 1 || echo 0)"
assert_eq "同一フレーム抑止(検証1巡目#9の回帰): 2ティック目の同期出力が0バイト" "0" "$(( SIZE_2 - SIZE_1 ))"

echo "=== 締切経路の常駐stderrが0バイト（検証1巡目#11・検証2巡目#25③） ==="
# limiterがプロセスグループを終了させる締切経路でも、bashのjob-control通知
# (Terminated: 15 ...)がProject常駐のstderrへ漏れないことを固定する
# （Task側は既にAC-95で検査済み・disownを外すとここでFAILになる）。
mk_stub_P3 "$WORKDIR/deadline_p3" "$WORKDIR/deadline_p3.fp"
DEADLINE_OUT="$(CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/deadline_p3" CMUX_DOCK_SUPPLY_TIMEOUT=1 \
  bash "$WATCH" --once 2>"$WORKDIR/deadline_p3.stderr")"
assert_eq "締切経路: --onceはAI環境 応答なし" "AI環境 応答なし" "$DEADLINE_OUT"
assert_eq "締切経路の常駐stderrが0バイト(検証1巡目#11の回帰)" "0" \
  "$(wc -c < "$WORKDIR/deadline_p3.stderr" | tr -d ' ')"

echo "=== AC-123: 終了経路の全5セル（Project・自然終了・非0終了・締切・TERM・HUP） ==="
wait_fp3() {
  local fp="$1" limit="${2:-100}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    if [ -s "$fp" ]; then
      local hm=0 hc=0 hw=0 k
      while IFS="$(printf '\t')" read -r k _ _; do
        case "$k" in main) hm=1 ;; child) hc=1 ;; watchdog) hw=1 ;; esac
      done < "$fp"
      [ "$hm" = 1 ] && [ "$hc" = 1 ] && [ "$hw" = 1 ] && return 0
    fi
    sleep 0.1; waited=$(( waited + 1 ))
  done
  return 1
}
fp_all_dead() {
  local fp="$1" alive=0 pid pgid
  while IFS="$(printf '\t')" read -r _ pid pgid; do
    kill -0 "$pid" 2>/dev/null && alive=$(( alive + 1 ))
    [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null && alive=$(( alive + 1 ))
  done < "$fp"
  echo "$alive"
}
esc_count() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, re
data = open(sys.argv[1], "rb").read()
pat = sys.argv[2].encode()
print(len(re.findall(re.escape(pat), data)))
PYEOF
}
ESC25H="$(printf '\033[?25h')"
ESC2026L="$(printf '\033[?2026l')"
# run_supply/fetch_frameがTMPDIR配下に作る一時物(raw/rc/done/tout/probe/
# model)だけを対象に前後比較する（AC-123④・検証2巡目 #22）。
tmp_snapshot() {
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cmux-supply-*' 2>/dev/null | sort
}

for spec in "natural:mk_stub_P26a" "nonzero:mk_stub_P26b" "timeout:mk_stub_P3"; do
  name="${spec%%:*}" fn="${spec#*:}"
  fp="$WORKDIR/proj_$name.fp"
  supply="$WORKDIR/proj_${name}_supply"
  if [ "$name" = "timeout" ]; then
    "$fn" "$supply" "$fp"
  else
    "$fn" "$supply" "$fp" Project
  fi
  LOG="$WORKDIR/proj_${name}_daemon.log"
  BEFORE_TMP="$(tmp_snapshot)"
  # v7（R-v7-3）＝1 ティックは --frame と --focus の 2 回の供給側呼出し（締切 1 秒
  # ×2＋後始末）なので、対象周期 2（既定と同値）を明示し、足跡の検査は固定の
  # 待ち時間でなく「呼出しが終わって足跡が全部死ぬ」まで（上限 6 秒）待って行う
  # （足跡の子 sleep 9999 は常駐の後始末でしか死なない）。
  CMUX_DOCK_SUPPLY_PROJECT="$supply" CMUX_DOCK_SUPPLY_TIMEOUT=1 CMUX_NEXT_INTERVAL=1 CMUX_NEXT_FOCUS_INTERVAL=2 CMUX_NEXT_ROWS=40 \
    bash "$WATCH" >"$LOG" 2>/dev/null &
  DPID=$!
  if ! wait_fp3 "$fp" 100; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: AC-123($name/Project): 足跡の3種別(main/child/watchdog)が揃わない"
    kill -TERM "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
    continue
  fi
  sleep 1.5
  w=0
  while [ "$(fp_all_dead "$fp")" != "0" ] && [ "$w" -lt 45 ]; do sleep 0.1; w=$(( w + 1 )); done
  DAEMON_ALIVE="$(kill -0 "$DPID" 2>/dev/null && echo 1 || echo 0)"
  assert_eq "AC-123($name/Project): 常駐は生き続ける" "1" "$DAEMON_ALIVE"
  assert_eq "AC-123($name/Project): 足跡の全PID・全PGIDが死んでいる" "0" "$(fp_all_dead "$fp")"
  assert_eq "AC-123($name/Project): ESC[?25hは出ない(常駐は生存)" "0" "$(esc_count "$LOG" "$ESC25H")"
  # v7＝足跡が死ぬのは watchdog の TERM（締切 1 秒）時点で、描画は --frame・--focus
  # の 2 呼出し完了後（設計 §42.6.1）。足跡消滅直後の即時判定は競合するので
  # AC-168 と同じ形で ESC[?2026l ≥ 1 を上限 6 秒で待つ。
  w=0
  while [ "$w" -lt 60 ] && [ "$(esc_count "$LOG" "$ESC2026L")" -lt 1 ]; do sleep 0.1; w=$(( w + 1 )); done
  ESC2026L_N="$(esc_count "$LOG" "$ESC2026L")"
  assert_true "AC-123($name/Project): 描画を開始したフレームにESC[?2026lがある" \
    "$([ "$ESC2026L_N" -ge 1 ] && echo 1 || echo 0)"
  kill -TERM "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
  w=0
  while [ "$(fp_all_dead "$fp")" != "0" ] && [ "$w" -lt 30 ]; do sleep 0.1; w=$(( w + 1 )); done
  AFTER_TMP="$(tmp_snapshot)"
  assert_eq "AC-123($name/Project): TMPDIRの一時物集合が実行前に戻っている" "$BEFORE_TMP" "$AFTER_TMP"
done
sleep 1

for sig in TERM HUP; do
  name="sig_$sig"
  fp="$WORKDIR/proj_${name}.fp"
  supply="$WORKDIR/proj_${name}_supply"
  mk_stub_P3 "$supply" "$fp"
  LOG="$WORKDIR/proj_${name}_daemon.log"
  BEFORE_TMP="$(tmp_snapshot)"
  CMUX_DOCK_SUPPLY_PROJECT="$supply" CMUX_DOCK_SUPPLY_TIMEOUT=30 CMUX_NEXT_ROWS=40 \
    bash "$WATCH" >"$LOG" 2>/dev/null &
  DPID=$!
  if ! wait_fp3 "$fp" 100; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: AC-123($sig/Project): 足跡の3種別(main/child/watchdog)が揃わない"
    kill "-$sig" "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
    continue
  fi
  kill "-$sig" "$DPID" 2>/dev/null
  wait_pid_bounded "$DPID" 50
  sleep 0.3
  DAEMON_ALIVE="$(kill -0 "$DPID" 2>/dev/null && echo 1 || echo 0)"
  assert_eq "AC-123($sig/Project): 常駐自身が終了する" "0" "$DAEMON_ALIVE"
  assert_eq "AC-123($sig/Project): 足跡の全PID・全PGIDが死んでいる" "0" "$(fp_all_dead "$fp")"
  assert_eq "AC-123($sig/Project): ESC[?25hがちょうど1回出る" "1" "$(esc_count "$LOG" "$ESC25H")"
  w=0
  while [ "$(fp_all_dead "$fp")" != "0" ] && [ "$w" -lt 30 ]; do sleep 0.1; w=$(( w + 1 )); done
  AFTER_TMP="$(tmp_snapshot)"
  assert_eq "AC-123($sig/Project): TMPDIRの一時物集合が実行前に戻っている" "$BEFORE_TMP" "$AFTER_TMP"
done

echo "=== AC-116: TMPDIR異常でも常駐は生存し\$HOME配下に新規ファイルが無い(RP) ==="
BEFORE_HOME="$(find "$HOME" -maxdepth 1 2>/dev/null | sort)"
OLD_TMPDIR="${TMPDIR:-}"
export TMPDIR="$WORKDIR/no-such-tmpdir"
OUT_TD="$(CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/p6" bash "$WATCH" --once)"
export TMPDIR="$OLD_TMPDIR"
assert_eq "AC-116(RP): TMPDIR不在はAI環境 応答なし" "AI環境 応答なし" "$OUT_TD"
AFTER_HOME="$(find "$HOME" -maxdepth 1 2>/dev/null | sort)"
assert_eq "AC-116(RP): \$HOME直下の一覧が不変" "$BEFORE_HOME" "$AFTER_HOME"

echo "=== v5: AC-140 描画リテラル（WU-F・WU-F0・幅40・高さ40） ==="
strip_sgr() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }
run_once() {  # $1=supply $2=rows $3=cols → 色除去後
  CMUX_DOCK_SUPPLY_PROJECT="$1" CMUX_NEXT_ROWS="$2" CMUX_NEXT_COLS="$3" bash "$WATCH" --once | strip_sgr
}
# v7 読み替え（FR-117・FR-119）＝先頭 2 セルの ▶ 欄（空白 2）・見出し ●。
EXPECT_WU_F="$(printf '● 稼働中 (2)\n  1 p-active 次を進める\n  2 p-past 返答を反映\n\n⏸ 待ち (2)\n  3 p-wait 返事待ち 9/25 10:00\n  4 p-waitday 再開 9/25 00:00\n\n⏸ 保留 (1)\n  5 p-paused (next未設定)\n\n外部脳 OK')"
EXPECT_WU_F0="$(printf '● 稼働中 (2)\n  1 p-active 次を進める\n  2 p-past 返答を反映\n\n⏸ 保留 (1)\n  3 p-paused (next未設定)\n\n外部脳 OK')"
mk_stub_WU_F "$WORKDIR/wu_f"
mk_stub_WU_F0 "$WORKDIR/wu_f0"
mk_stub_WU_C "$WORKDIR/wu_c"
mk_stub_WU_Fplus12 "$WORKDIR/wu_fplus12"
mk_stub_WU_Fpast "$WORKDIR/wu_fpast"
OUT_WU_F="$(run_once "$WORKDIR/wu_f" 40 40)"
assert_eq "v5_ac140_literal_WU_F: 12行とリテラル一致" "$EXPECT_WU_F" "$OUT_WU_F"
OUT_WU_F0="$(run_once "$WORKDIR/wu_f0" 40 40)"
assert_eq "v5_ac140_literal_WU_F0: 8行とリテラル一致" "$EXPECT_WU_F0" "$OUT_WU_F0"
assert_eq "v5_ac140_literal_WU_F0: ⏸ 待ち が0件" "0" "$(printf '%s\n' "$OUT_WU_F0" | grep -cF '⏸ 待ち' | tr -d ' ')"

echo "=== v5: AC-141 待ち行の切り詰めと描画射影（幅24／26・WU-F+12） ==="
# 全行の表示幅（lib-dock-view.sh の disp_width＝jq 範囲表）が幅以下であることも見る。
max_disp_width() { local l m=0 w; while IFS= read -r l; do w="$(disp_width "$l")"; is_number "$w" || w=0; [ "$w" -gt "$m" ] && m="$w"; done; printf '%s' "$m"; }
# v7 読み替え（FR-121＝next 予算 −2）＝入力幅は v5 のまま 24／26、期待値だけ更新。
# 幅 24＝p-wait の next 予算 2 → `…`・p-waitday は固定部（番号・名前・短縮形＝
# 25 セル）が幅を超え、FR-98 のとおり固定部を全部残して next 欄は `…`（行は 26）。
# 幅 26＝v5 の幅 24 と同じ切り詰め（p-waitday の next 予算 1 → `…`）。
OUT_W24="$(run_once "$WORKDIR/wu_f" 40 24)"
assert_eq "v5_ac141_wait_row_w24: 待ち行2行(v7＝next 予算 −2)" "$(printf '  3 p-wait … 9/25 10:00\n  4 p-waitday … 9/25 00:00')" "$(printf '%s\n' "$OUT_W24" | sed -n '6,7p')"
assert_true "v5_ac141_wait_row_w24: 固定部が幅を超える p-waitday 行を除き全行の表示幅≤24" "$([ "$(printf '%s\n' "$OUT_W24" | grep -vF 'p-waitday' | max_disp_width)" -le 24 ] && echo 1 || echo 0)"
OUT_W26="$(run_once "$WORKDIR/wu_f" 40 26)"
assert_eq "v5_ac141_wait_row_w26: 待ち行2行(v7＝next 予算 −2)" "$(printf '  3 p-wait 返… 9/25 10:00\n  4 p-waitday … 9/25 00:00')" "$(printf '%s\n' "$OUT_W26" | sed -n '6,7p')"
assert_true "v5_ac141_wait_row_w26: 全行の表示幅≤26" "$([ "$(printf '%s\n' "$OUT_W26" | max_disp_width)" -le 26 ] && echo 1 || echo 0)"
# v7 FR-121（next 予算 −2）＝v5 が幅 24／26 で観測した next 予算の下限（1 → `…`）
# と 1 文字残り（`返事…`・`再…`）は、v7 では幅 26／28 で同じ形になる。
assert_eq "v7_fr121_wait_row_w26: v5 の幅 24 の切り詰めが幅 26 で再現" "$(printf '  3 p-wait 返… 9/25 10:00\n  4 p-waitday … 9/25 00:00')" "$(printf '%s\n' "$OUT_W26" | sed -n '6,7p')"
OUT_W28="$(run_once "$WORKDIR/wu_f" 40 28)"
assert_eq "v7_fr121_wait_row_w28: v5 の幅 26 の切り詰めが幅 28 で再現" "$(printf '  3 p-wait 返事… 9/25 10:00\n  4 p-waitday 再… 9/25 00:00')" "$(printf '%s\n' "$OUT_W28" | sed -n '6,7p')"
assert_true "v7_fr121_wait_row_w28: 全行の表示幅≤28" "$([ "$(printf '%s\n' "$OUT_W28" | max_disp_width)" -le 28 ] && echo 1 || echo 0)"
OUT_F12="$(run_once "$WORKDIR/wu_fplus12" 40 40)"
assert_eq "v5_ac141_nextyear_short: 2027-01-05T09:00 の短縮形は 1/5 09:00" "  5 p-nextyear 年跨ぎ 1/5 09:00" "$(printf '%s\n' "$OUT_F12" | grep -F 'p-nextyear')"
assert_eq "v5_ac141_nextyear_short: 保留は番号6" "  6 p-paused (next未設定)" "$(printf '%s\n' "$OUT_F12" | grep -F 'p-paused')"
# v5_ac141_projection: クランプなしのとき画面のエントリ行と P 行が1対1で、
# 番号・待ち日時（固定変換）は生・名前は10cp・next は truncate_disp の期待値。
# v7（FR-117）＝エントリ行は ▶ 欄（空白 2）で始まる。
ENTRY_LINES="$(printf '%s\n' "$OUT_F12" | grep -E '^  [0-9]+ ')"
assert_eq "v5_ac141_projection: エントリ行数=P行数(6)" "6" "$(printf '%s\n' "$ENTRY_LINES" | wc -l | tr -d ' ')"
PROJ_FAIL=0
# 欄の分解は split_tsv（while IFS=$'\t' read は空欄を畳む＝§29.1 の⚠️）。
while IFS= read -r prow; do
  split_tsv "$prow"
  pnum="${TSV_F[1]}"; pname="${TSV_F[2]}"; pnext="${TSV_F[3]}"; pcat="${TSV_F[4]}"; pwait="${TSV_F[5]}"
  line="$(printf '%s\n' "$ENTRY_LINES" | grep -E "^  ${pnum} " )"
  name10="$(truncate_plain "$pname" 10)"
  case "$pnext" in '') nx="(next未設定)" ;; *) nx="$pnext" ;; esac
  if [ "$pcat" = "待ち" ]; then
    m="${pwait:5:2}"; d="${pwait:8:2}"; m="${m#0}"; d="${d#0}"
    expect="  $pnum $name10 $nx $m/$d ${pwait:11:5}"
  else
    expect="  $pnum $name10 $nx"
  fi
  [ "$line" = "$expect" ] || { PROJ_FAIL=$(( PROJ_FAIL + 1 )); echo "  射影不一致: [$expect] vs [$line]"; }
done < <(grep '^P' "$WORKDIR/wu_fplus12.data")
assert_eq "v5_ac141_projection: 各対の描画射影（番号・名前10cp・next・短縮形）が一致" "0" "$PROJ_FAIL"

echo "=== v5: AC-142 クランプで残るもの（配分・境界を含む総当たり・要件 v5.6 の表） ==="
# 期待表（要件 AC-142 のリテラル・1 行 1 ケース）＝ h:A集合|W集合|H集合|N
# 集合は番号を空白区切り昇順で書く（空集合は空）。N は …他N行 の N（クランプ
# なしは "-"）。現物の配分関数を呼んで期待を作らない（§11.4）。
AC142_WU_C="9:1|||19
10:1|19||18
11:1|19|20|17
12:1 2|19|20|16
13:1 2 3|19|20|15
14:1 2 3 4|19|20|14
15:1 2 3 4 5|19|20|13
16:1 2 3 4 5 6|19|20|12
17:1 2 3 4 5 6 7|19|20|11
18:1 2 3 4 5 6 7 8|19|20|10
19:1 2 3 4 5 6 7 8 9|19|20|9
20:1 2 3 4 5 6 7 8 9 10|19|20|8
21:1 2 3 4 5 6 7 8 9 10 11|19|20|7
22:1 2 3 4 5 6 7 8 9 10 11 12|19|20|6
23:1 2 3 4 5 6 7 8 9 10 11 12 13|19|20|5
24:1 2 3 4 5 6 7 8 9 10 11 12 13 14|19|20|4
25:1 2 3 4 5 6 7 8 9 10 11 12 13 14 15|19|20|3
26:1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16|19|20|2
27:1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18|19|20|-
28:1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18|19|20|-"
AC142_WU_E="9:1|||19
10:1|9||18
11:1|9|15|17
12:1 2|9|15|16
13:1 2|9 10|15|15
14:1 2|9 10|15 16|14
15:1 2 3|9 10|15 16|13
16:1 2 3|9 10 11|15 16|12
17:1 2 3|9 10 11|15 16 17|11
18:1 2 3 4|9 10 11|15 16 17|10
19:1 2 3 4|9 10 11 12|15 16 17|9
20:1 2 3 4|9 10 11 12|15 16 17 18|8
21:1 2 3 4 5|9 10 11 12|15 16 17 18|7
22:1 2 3 4 5|9 10 11 12 13|15 16 17 18|6
23:1 2 3 4 5|9 10 11 12 13|15 16 17 18 19|5
24:1 2 3 4 5 6|9 10 11 12 13|15 16 17 18 19|4
25:1 2 3 4 5 6|9 10 11 12 13 14|15 16 17 18 19|3
26:1 2 3 4 5 6|9 10 11 12 13 14|15 16 17 18 19 20|2
27:1 2 3 4 5 6 7 8|9 10 11 12 13 14|15 16 17 18 19 20|-
28:1 2 3 4 5 6 7 8|9 10 11 12 13 14|15 16 17 18 19 20|-"
AC142_WU_F="9:1|||4
10:1|3||3
11:1|3|5|2
12:1 2|3 4|5|-
13:1 2|3 4|5|-"
AC142_WU_F0="7:1|||2
8:1 2||3|-
9:1 2||3|-"

# $1=出力(色除去後) $2=A見出し $3=W見出し(空なら待ちブロック無しを期待) $4=H見出し
# $5=期待行 "h:A|W|H|N" $6=クランプ無し時の総行数 → 違反を echo・件数を返す
check_dist_out() {
  local out="$1" act_hd="$2" wait_hd="$3" hold_hd="$4" spec="$5" full_n="$6" bad=0
  local h rest expA expW expH expN gotA="" gotW="" gotH="" cur="" l other_cnt other_n nlines last
  h="${spec%%:*}"; rest="${spec#*:}"
  expA="${rest%%|*}"; rest="${rest#*|}"
  expW="${rest%%|*}"; rest="${rest#*|}"
  expH="${rest%%|*}"; expN="${rest#*|}"
  printf '%s\n' "$out" | grep -qxF "$act_hd" || { bad=$(( bad + 1 )); echo "    稼働中見出し無し"; }
  printf '%s\n' "$out" | grep -qxF "$hold_hd" || { bad=$(( bad + 1 )); echo "    保留見出し無し"; }
  if [ -n "$wait_hd" ]; then
    printf '%s\n' "$out" | grep -qxF "$wait_hd" || { bad=$(( bad + 1 )); echo "    待ち見出し無し"; }
  else
    printf '%s\n' "$out" | grep -qF '⏸ 待ち' && { bad=$(( bad + 1 )); echo "    待ち0件なのに待ち見出し"; }
  fi
  last="$(printf '%s\n' "$out" | tail -n 1)"
  [ "$last" = "外部脳 OK" ] || { bad=$(( bad + 1 )); echo "    最終行が外部脳 OKでない: [$last]"; }
  # ブロック別の番号集合（見出しで区切り、出現順＝画面の順）。
  # v7（FR-117・FR-119）＝見出しは ●・エントリ行は ▶ 欄 2 セル（空白 2）の後に番号。
  local e
  while IFS= read -r l; do
    e="${l#  }"
    case "$l" in
      '● 稼働中'*) cur=A ;;
      '⏸ 待ち'*)   cur=W ;;
      '⏸ 保留'*)   cur=H ;;
      '  '[0-9]*' '*)
        case "$cur" in
          A) gotA="${gotA:+$gotA }${e%% *}" ;;
          W) gotW="${gotW:+$gotW }${e%% *}" ;;
          H) gotH="${gotH:+$gotH }${e%% *}" ;;
        esac ;;
    esac
  done <<EOF_LINES
$out
EOF_LINES
  [ "$gotA" = "$expA" ] || { bad=$(( bad + 1 )); echo "    稼働中の番号集合: 期待[$expA] 実際[$gotA]"; }
  [ "$gotW" = "$expW" ] || { bad=$(( bad + 1 )); echo "    待ちの番号集合: 期待[$expW] 実際[$gotW]"; }
  [ "$gotH" = "$expH" ] || { bad=$(( bad + 1 )); echo "    保留の番号集合: 期待[$expH] 実際[$gotH]"; }
  other_cnt="$(printf '%s\n' "$out" | grep -c '^…他' | tr -d ' ')"
  nlines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  if [ "$expN" = "-" ]; then
    [ "$other_cnt" = "0" ] || { bad=$(( bad + 1 )); echo "    クランプ無しなのに …他"; }
    [ "$nlines" = "$full_n" ] || { bad=$(( bad + 1 )); echo "    クランプ無しの行数 $nlines ≠ $full_n"; }
  else
    [ "$other_cnt" = "1" ] || { bad=$(( bad + 1 )); echo "    …他 が1行でない($other_cnt)"; }
    other_n="$(printf '%s\n' "$out" | sed -n 's/^…他\([0-9]*\)行$/\1/p')"
    [ "$other_n" = "$expN" ] || { bad=$(( bad + 1 )); echo "    …他N の N=$other_n ≠ $expN"; }
    # 末尾＝保留ブロックの後（外部脳の空行の直前）に1行
    [ "$(printf '%s\n' "$out" | tail -n 3 | head -n 1)" = "…他${expN}行" ] || { bad=$(( bad + 1 )); echo "    …他 が末尾にない"; }
    [ "$nlines" -le "$h" ] || { bad=$(( bad + 1 )); echo "    行数 $nlines > h"; }
  fi
  return "$bad"
}
# $1=supply $2=A見出し $3=W見出し $4=H見出し $5=期待表 $6=クランプ無し行数 → 違反件数
run_dist_table() {
  local supply="$1" act="$2" wt="$3" hd="$4" table="$5" full_n="$6" spec h out fail=0
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    h="${spec%%:*}"
    out="$(run_once "$supply" "$h" 40)"
    check_dist_out "$out" "$act" "$wt" "$hd" "$spec" "$full_n" || { fail=$(( fail + 1 )); echo "  h=$h で違反"; }
  done <<EOF_TABLE
$table
EOF_TABLE
  printf '%s' "$fail"
}
mk_stub_WU_E "$WORKDIR/wu_e"
# v7 読み替え（FR-119）＝稼働中の見出しは ●。
assert_eq "v5_ac142_dist_WU_C_h9_28: 表のリテラル20件（ブロック別番号集合・N・境界26/27）" "0" \
  "$(run_dist_table "$WORKDIR/wu_c" "● 稼働中 (18)" "⏸ 待ち (1)" "⏸ 保留 (1)" "$AC142_WU_C" 27)"
assert_eq "v5_ac142_dist_WU_C_h9_28: 表は20行" "20" "$(printf '%s\n' "$AC142_WU_C" | wc -l | tr -d ' ')"
assert_eq "v5_ac142_dist_WU_E_h9_28: 表のリテラル20件（8/6/6 の均等配分）" "0" \
  "$(run_dist_table "$WORKDIR/wu_e" "● 稼働中 (8)" "⏸ 待ち (6)" "⏸ 保留 (6)" "$AC142_WU_E" 27)"
assert_eq "v5_ac142_dist_WU_E_h9_28: 表は20行" "20" "$(printf '%s\n' "$AC142_WU_E" | wc -l | tr -d ' ')"
out="$(run_once "$WORKDIR/wu_c" 40 40)"
assert_eq "v5_ac142_dist_WU_C_h9_28: h=40 はクランプなし27行" "27" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "v5_ac142_WU_F0_h7_9: ⑥待ち0件（表のリテラル3件・⏸ 待ち 0件・h=7で…他2行・h=8/9で8行）" "0" \
  "$(run_dist_table "$WORKDIR/wu_f0" "● 稼働中 (2)" "" "⏸ 保留 (1)" "$AC142_WU_F0" 8)"
assert_eq "v5_ac142_WU_F_h9_13: ⑦クランプ中の区分遷移（表のリテラル5件・境界12）" "0" \
  "$(run_dist_table "$WORKDIR/wu_f" "● 稼働中 (2)" "⏸ 待ち (2)" "⏸ 保留 (1)" "$AC142_WU_F" 12)"

echo "=== v5: AC-143 先頭行の隠れ（常駐1ティックの生バイト列・lib-tick-bytes.sh） ==="
# $1=供給側 $2=h範囲(空白区切り) $3=先頭期待 $4=③を期待する最小h $5=名前
run_tick_range() {
  local supply="$1" hs="$2" first="$3" min3="$4" name="$5" h fails expect_last tfail=0
  for h in $hs; do
    if ! capture_first_tick "$supply" "$h" "$WORKDIR/tick_${name}_$h.log" "$WATCH"; then
      tfail=$(( tfail + 1 )); echo "  $name h=$h: 1ティックを捕捉できない"; continue
    fi
    expect_last=""
    [ "$h" -ge "$min3" ] && expect_last="外部脳 OK"
    fails="$(tick_fails "$WORKDIR/tick_${name}_$h.log" "$h" "$first" "$expect_last")"
    if [ -n "$fails" ]; then
      tfail=$(( tfail + 1 )); printf '  %s h=%s:\n%s\n' "$name" "$h" "$fails"
    fi
  done
  printf '%s' "$tfail"
}
# v7 読み替え（FR-119）＝先頭行の見出しは ● 稼働中 (n)。
assert_eq "v5_ac143_tick_WU_C_h4_28: h∈4..28 で①②③⑤⑥⑦" "0" \
  "$(run_tick_range "$WORKDIR/wu_c" "4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28" "● 稼働中 (18)" 9 WU_C)"
assert_eq "v5_ac143_tick_WU_E_h4_28: h∈4..28 で①②③⑤⑥⑦（8/6/6）" "0" \
  "$(run_tick_range "$WORKDIR/wu_e" "4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28" "● 稼働中 (8)" 9 WU_E)"
assert_eq "v5_ac143_tick_WU_F_h4_13: h∈4..13 で①②③⑤⑥⑦" "0" \
  "$(run_tick_range "$WORKDIR/wu_f" "4 5 6 7 8 9 10 11 12 13" "● 稼働中 (2)" 9 WU_F)"
assert_eq "v5_ac143_tick_WU_F0_h4_9: h∈4..9 で①②③⑤⑥⑦" "0" \
  "$(run_tick_range "$WORKDIR/wu_f0" "4 5 6 7 8 9" "● 稼働中 (2)" 7 WU_F0)"
# ④ WU-R＝明示指定なし・新セッション（制御端末なし＝stty size 取得不能）で
# h_def=4 に対して①②⑤⑥⑦（LF≤3）。
(
  unset CMUX_NEXT_ROWS
  capture_first_tick "$WORKDIR/wu_c" "" "$WORKDIR/tick_WU_R.log" "$WATCH" setsid
) || echo "  WU-R: 1ティックを捕捉できない"
WUR_FAILS="$(tick_fails "$WORKDIR/tick_WU_R.log" 4 "● 稼働中 (18)" "")"
[ -n "$WUR_FAILS" ] && printf '%s\n' "$WUR_FAILS"
assert_eq "v5_ac143_WU_R_hdef4: 行数取得不能の起動で h_def=4（LF≤3・先頭 ● 稼働中 (18)）" "" "$WUR_FAILS"

echo "=== v5: AC-146④ 描画側は時刻で区分を変えない（WU-F-past） ==="
OUT_PAST="$(run_once "$WORKDIR/wu_fpast" 40 40)"
assert_true "v5_ac146_render_ignores_time_WU_Fpast: 過去の待ち日時でも ⏸ 待ち (2) ブロックに残る" \
  "$(printf '%s\n' "$OUT_PAST" | grep -qxF '⏸ 待ち (2)' && echo 1 || echo 0)"
# v7 読み替え（FR-117・FR-119）＝▶ 欄 2 セル・見出し ●。
assert_eq "v5_ac146_render_ignores_time_WU_Fpast: 行は 1/1 00:00 付き" "  3 p-wait 返事待ち 1/1 00:00" \
  "$(printf '%s\n' "$OUT_PAST" | grep -E '^  3 ')"
assert_eq "v5_ac146_render_ignores_time_WU_Fpast: 稼働中は(2)のまま" "● 稼働中 (2)" "$(printf '%s\n' "$OUT_PAST" | sed -n '1p')"

echo "=== v5: AC-147 文書の追随（README・ソース冒頭の表示例） ==="
README_NEXT="$SCRIPT_DIR/../README.md"
README_TASK="$CMUX_DIR/cmux-task-watch/README.md"
for w in '待ち' 'cmux-dock-frame/4' 'wait_until'; do
  assert_true "v5_ac147_readme_next_watch: README に $w が1件以上" "$(grep -qF "$w" "$README_NEXT" && echo 1 || echo 0)"
done
assert_eq "v5_ac147_readme_next_watch: README に旧版リテラルが0件" "0" "$(grep -cF "$(printf 'cmux-dock-frame/%s' 3)" "$README_NEXT" | tr -d ' ')"
assert_true "v5_ac147_readme_task_watch_L63: 版ちがい行の Project 側の版が /4" \
  "$(grep -F '版ちがい' "$README_TASK" | grep -qF 'cmux-dock-frame/4' && echo 1 || echo 0)"
assert_eq "v5_ac147_readme_task_watch_L63: 版ちがい行に旧版リテラルが0件" "0" \
  "$(grep -F '版ちがい' "$README_TASK" | grep -cF "$(printf 'cmux-dock-frame/%s' 3)" | tr -d ' ')"
# ソース冒頭（最初の非コメント行より前）の表示例に待ちブロックがある。
HEADER="$(awk '/^[^#]/{exit} {print}' "$WATCH")"
assert_true "v5_ac147_source_header_wait_block: ソース冒頭の表示例に ⏸ 待ち がある" \
  "$(printf '%s\n' "$HEADER" | grep -qF '⏸ 待ち' && echo 1 || echo 0)"

echo "=== v5: DT-18 B行0行の固定行（WU-F 派生・h=9） ==="
mk_stub_WU_F_noB "$WORKDIR/wu_f_nob"
OUT_NOB="$(run_once "$WORKDIR/wu_f_nob" 9 40)"
assert_eq "DT-18: 9行" "9" "$(printf '%s\n' "$OUT_NOB" | wc -l | tr -d ' ')"
assert_eq "DT-18: …他2行 が1行" "1" "$(printf '%s\n' "$OUT_NOB" | grep -cxF '…他2行' | tr -d ' ')"
# v5.6: …他N行 は末尾（保留ブロックの後）に置く（FR-100 ③）ので B行0行では
# 最終行が …他2行・その直前が保留のエントリ行（末尾に空行が無い）。
assert_eq "DT-18: 最終行が …他2行（末尾に空行が無い）" "…他2行" "$(printf '%s\n' "$OUT_NOB" | tail -n 1)"
# v7 読み替え（FR-117）＝エントリ行は ▶ 欄（空白 2）の後に番号。
assert_eq "DT-18: エントリ行は3行(R=3→1/1/1)" "3" "$(printf '%s\n' "$OUT_NOB" | grep -cE '^  [0-9]+ ' | tr -d ' ')"
assert_eq "DT-18: 残る番号は 1・3・5（各ブロック先頭）" "1 3 5" "$(printf '%s\n' "$OUT_NOB" | grep -E '^  [0-9]+ ' | cut -c3- | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
OUT_NOB10="$(run_once "$WORKDIR/wu_f_nob" 10 40)"
assert_eq "DT-18: h=10 はクランプなし10行" "10" "$(printf '%s\n' "$OUT_NOB10" | wc -l | tr -d ' ')"
assert_eq "DT-18: h=10 に …他 が無い" "0" "$(printf '%s\n' "$OUT_NOB10" | grep -c '^…他' | tr -d ' ')"

echo "=== v5: DT-19 幅の上書き口 CMUX_NEXT_COLS=16 ==="
OUT_W16="$(run_once "$WORKDIR/p90a" 40 16)"
NAME16="$(printf '%s\n' "$OUT_W16" | sed -n '2p' | awk '{print $2}')"
assert_eq "DT-19: 名前欄は10cp" "10" "$(printf '%s' "$NAME16" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
assert_true "DT-19: 全行の表示幅≤16" "$([ "$(printf '%s\n' "$OUT_W16" | max_disp_width)" -le 16 ] && echo 1 || echo 0)"
assert_true "DT-19: 幅16で next が切り詰められ末尾が …" "$(printf '%s\n' "$OUT_W16" | sed -n '2p' | grep -q '…$' && echo 1 || echo 0)"

echo "=== v5: DT-20 版ちがいからの回復（同一常駐で旧版→/4） ==="
mk_stub_WU_Z "$WORKDIR/wuz_g" g
STATE_LINK20="$WORKDIR/state20"
ln -sf "$WORKDIR/wuz_g" "$STATE_LINK20"
LOG20="$WORKDIR/dt20.log"
# v7（R-v7-3）＝対象周期 1 も指定（ループは対象周期で回る）。
CMUX_DOCK_SUPPLY_PROJECT="$STATE_LINK20" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_FOCUS_INTERVAL=1 CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=40 \
  bash "$WATCH" >"$LOG20" 2>/dev/null &
DPID20=$!
last_block() {  # $1=log → 最終描画ブロック（ESC[H〜ESC[J・色除去）
  python3 - "$1" <<'PYEOF'
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
blocks = re.findall(r"\x1b\[H(.*?)\x1b\[J", data, re.S)
last = blocks[-1] if blocks else ""
last = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", last).replace("\r", "")
print(last.rstrip("\n"))
PYEOF
}
w=0; while [ "$w" -lt 100 ] && [ "$(esc_count "$LOG20" "$ESC2026L")" -lt 1 ]; do sleep 0.1; w=$(( w + 1 )); done
assert_eq "DT-20①: 旧版の供給側では最終ブロックが AI環境 版ちがい" "AI環境 版ちがい" "$(last_block "$LOG20")"
N20_BEFORE="$(esc_count "$LOG20" "$ESC2026L")"
ln -sf "$WORKDIR/wu_f" "$STATE_LINK20"
w=0; while [ "$w" -lt 100 ] && [ "$(esc_count "$LOG20" "$ESC2026L")" -le "$N20_BEFORE" ]; do sleep 0.1; w=$(( w + 1 )); done
sleep 0.2
LAST20="$(last_block "$LOG20")"
assert_eq "DT-20③: /4 へ切り替えた次のティックで通常表示（AC-140 の12行）" "$EXPECT_WU_F" "$LAST20"
assert_true "DT-20③: 版ちがい を含まない" "$(printf '%s\n' "$LAST20" | grep -qF '版ちがい' && echo 0 || echo 1)"
assert_eq "DT-20③: 常駐 PID が生存" "1" "$(kill -0 "$DPID20" 2>/dev/null && echo 1 || echo 0)"
kill -TERM "$DPID20" 2>/dev/null; wait_pid_bounded "$DPID20" 50

echo "=== v5: DT-21 待ち行の配色（SGR 列の比較・色除去前） ==="
mk_stub_WU_F_holdnext "$WORKDIR/wu_f_holdnext"
sgr_seq() {  # stdin=1行（色付き）→ SGR 列を空白区切りで
  python3 -c 'import re,sys; s=sys.stdin.read(); print(" ".join(m[1:] for m in re.findall(r"\x1b\[[0-9;]*m", s)))'
}
RAW21="$(CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/wu_f_holdnext" CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=40 bash "$WATCH" --once)"
WAIT_SGR="$(printf '%s\n' "$RAW21" | grep -F "p-wait$(printf '\033')" | sgr_seq)"
HOLD_SGR="$(printf '%s\n' "$RAW21" | grep -F 'p-paused' | sgr_seq)"
assert_eq "DT-21: 保留行(nextあり)の SGR 列＝DIM RESET LBL RESET LBL RESET" \
  "[38;5;244m [0m [38;5;252m [0m [38;5;252m [0m" "$HOLD_SGR"
assert_eq "DT-21: 待ち行の SGR 列＝保留行の列＋末尾に DIM RESET の1組" \
  "$HOLD_SGR [38;5;244m [0m" "$WAIT_SGR"
assert_eq "DT-21: 待ち行の短縮形は DIM で描かれる" "1" \
  "$(printf '%s\n' "$RAW21" | grep -F "p-wait$(printf '\033')" | grep -cF "$(printf '\033')[38;5;244m9/25 10:00$(printf '\033')[0m" | tr -d ' ')"

echo "=== v5: DT-22 配分関数の性質（distribute_rows・純関数・source ガード A-v5-4） ==="
# cmux-next-watch.sh を source して直接呼ぶ（末尾の source ガードで main は走らない）。
# 固定表＝本人の3例＋WU-C＋稼働中0件＋2巡以上の回し＋R=0（期待値は手計算）。
DT22_TABLE="10 8 6 6:4 3 3
10 5 1 4:5 1 4
12 8 0 6:6 0 6
10 18 1 1:8 1 1
5 0 3 9:0 3 2
9 1 1 20:1 1 7
0 8 6 6:0 0 0"
DT22_OUT="$(
  . "$WATCH"
  fail=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    args="${row%%:*}"; expect="${row#*:}"
    # shellcheck disable=SC2086
    got="$(distribute_rows $args)"
    [ "$got" = "$expect" ] || { fail=$(( fail + 1 )); echo "  distribute_rows $args: 期待[$expect] 実際[$got]"; }
  done <<EOF_DT22
$DT22_TABLE
EOF_DT22
  # 性質＝0≤n_b≤6・0≤R<n の全組合せで Σk=R・k_b≤n_b
  prop=0
  for nA in 0 1 2 3 4 5 6; do for nW in 0 1 2 3 4 5 6; do for nH in 0 1 2 3 4 5 6; do
    n=$(( nA + nW + nH ))
    R=0
    while [ "$R" -lt "$n" ]; do
      set -- $(distribute_rows "$R" "$nA" "$nW" "$nH")
      if [ $(( $1 + $2 + $3 )) -ne "$R" ] || [ "$1" -gt "$nA" ] || [ "$2" -gt "$nW" ] || [ "$3" -gt "$nH" ] \
         || [ "$1" -lt 0 ] || [ "$2" -lt 0 ] || [ "$3" -lt 0 ]; then
        prop=$(( prop + 1 )); echo "  性質違反: R=$R n=$nA/$nW/$nH → $1/$2/$3"
      fi
      R=$(( R + 1 ))
    done
  done; done; done
  echo "FIXED_FAIL=$fail"
  echo "PROP_FAIL=$prop"
)"
assert_eq "DT-22: 固定表7行の出力が一致" "FIXED_FAIL=0" "$(printf '%s\n' "$DT22_OUT" | grep '^FIXED_FAIL=')"
assert_eq "DT-22: 0≤n_b≤6・0≤R<n の全組合せで Σk=R かつ k_b≤n_b" "PROP_FAIL=0" "$(printf '%s\n' "$DT22_OUT" | grep '^PROP_FAIL=')"
printf '%s\n' "$DT22_OUT" | grep -v '^FIXED_FAIL=\|^PROP_FAIL=' | head -20
assert_true "DT-22: source しても main は走らない（ソース末尾の source ガード）" \
  "$(tail -n 5 "$WATCH" | grep -q 'BASH_SOURCE' && echo 1 || echo 0)"

echo "=== v6: AC-152 待ち行の切り詰めと短縮形の全セル（WW-1・WW-2・幅37／36／35・高さ40） ==="
# 要件 requirements-v6.md §8 AC-152（計算根拠＝requirements-v6-notes.md §8）。
# 幅は明示の上書き口 CMUX_NEXT_COLS で与える（上書き値は上限の対象外＝要件 §11）。
mk_stub_WW_1 "$WORKDIR/ww_1"
mk_stub_WW_2 "$WORKDIR/ww_2"
# $1=AC名 $2=supply $3=幅 $4=番号 $5=期待行 $6=期待表示幅 $7=短縮形の末尾
ac152_case() {
  local name="$1" out line
  out="$(run_once "$2" 40 "$3")"
  line="$(printf '%s\n' "$out" | grep -E "^  $4 ")"
  assert_eq "$name: 待ち行がリテラル一致" "$5" "$line"
  assert_eq "$name: 待ち行の表示幅=$6" "$6" "$(disp_width "$line")"
  assert_true "$name: 短縮形の全文字（末尾 $7）を含む" "$(printf '%s\n' "$line" | grep -q " $7\$" && echo 1 || echo 0)"
  assert_true "$name: 全行の表示幅≤$3" "$([ "$(printf '%s\n' "$out" | max_disp_width)" -le "$3" ] && echo 1 || echo 0)"
}
# v7 読み替え（FR-117・FR-121＝next 予算 −2・requirements-v7-notes.md §5）＝▶ 欄
# 2 セルの分だけ next 欄が 2 セル短い（幅 36 は 職種を設定… → 職種を設…）。
ac152_case "v6_ac152_WW1_w37" "$WORKDIR/ww_1" 37 7 "  7 roles-conf 職種を設定… 9/21 06:00" 37 "9/21 06:00"
ac152_case "v6_ac152_WW1_w36" "$WORKDIR/ww_1" 36 7 "  7 roles-conf 職種を設… 9/21 06:00" 35 "9/21 06:00"
ac152_case "v6_ac152_WW2_w37" "$WORKDIR/ww_2" 37 8 "  8 roles-conf 職種を設… 12/31 23:59" 36 "12/31 23:59"
ac152_case "v6_ac152_WW2_w35" "$WORKDIR/ww_2" 35 8 "  8 roles-conf 職種を… 12/31 23:59" 34 "12/31 23:59"
# 幅の上限の規則（FR-110）＝Project 常駐が使う幅は min(端末取得, 上限)。
# 端末取得は lib-dock-view.sh の差し替え口 _stty_cols（既存検査と同じ口）で 37 を
# 与え、常駐を source（source ガード・DT-22 と同じ）して cols_now を直接呼ぶ。
# 明示の上書き（CMUX_NEXT_COLS=37）は上限の対象外。
COLS_MIN="$(
  unset CMUX_NEXT_COLS
  . "$WATCH"
  _stty_cols() { printf '37'; }
  CMUX_DOCK_MAX_COLS=36 cols_now
)"
assert_eq "v6_ac152_min_rule: 端末取得37・上限36 → Project 常駐の描画幅36" "36" "$COLS_MIN"
COLS_OVR="$(
  export CMUX_NEXT_COLS=37
  . "$WATCH"
  _stty_cols() { printf '37'; }
  CMUX_DOCK_MAX_COLS=36 cols_now
)"
assert_eq "v6_ac152_min_rule: 明示の上書き37は上限36の対象外 → 37" "37" "$COLS_OVR"

echo "=== v6: AC-154(b) 文書の追随（README の待ちの項に「▶ の版」） ==="
# 要件 §9「文書」＝cmux/cmux-next-watch/README.md の wait_until の説明の直後に「▶ の版」。
assert_true "v6_ac154b_readme_next_watch: README に ▶ の版 が1件以上" \
  "$(grep -qF '▶ の版' "$README_NEXT" && echo 1 || echo 0)"
WAIT_LN="$(grep -nF 'wait_until' "$README_NEXT" | head -n 1 | cut -d: -f1)"
VER_LN="$(grep -nF '▶ の版' "$README_NEXT" | head -n 1 | cut -d: -f1)"
assert_true "v6_ac154b_readme_next_watch: ▶ の版 が wait_until の説明より後にある" \
  "$([ -n "$WAIT_LN" ] && [ -n "$VER_LN" ] && [ "$VER_LN" -gt "$WAIT_LN" ] && echo 1 || echo 0)"

# ===========================================================================
# v7（要件 requirements-v7.md v7.3 §7〜§8・設計 design.md §42.9 RP 層）
# 供給側は FV スタブ（lib-supply-stubs.sh mk_stub_FV）＝`--frame` は記録フレーム
# （fixtures/fv-a.frame・fv-b.frame＝FV-A／FV-B・T0 で v6 供給側が出したもの）・
# `--focus` は隣接ファイルの 1 行。FD-n は RP 層では「照会口が返す 1 行」に写す
# （設計 §42.9.1）＝FD-1→p-act2・FD-2→roles-conf・FD-3→p-hold・FD-3′→p-hold7・
# FD-4〜7・FD-5′→空行・FD-8→p-done・FD-8′→p-none・FD-9／9′→10 秒 sleep・
# FD-10→p-act2。平文＝`--once` の出力から SGR を除去（D-v7-9）。
# ===========================================================================
echo "=== v7: 共通（fixture・期待リテラル・補助関数） ==="
FIXTURES="$SCRIPT_DIR/fixtures"
FV_A_FRAME="$FIXTURES/fv-a.frame"
FV_B_FRAME="$FIXTURES/fv-b.frame"
FX6_WATCH="$FIXTURES/fx6-cmux-next-watch.sh"   # FX-6＝v6 の描画側の写し（AC-167 (i)）
for f in "$FV_A_FRAME" "$FV_B_FRAME" "$FX6_WATCH"; do
  [ -r "$f" ] || { echo "FATAL: 見つかりません: $f" >&2; exit 1; }
done
ESC_CH="$(printf '\033')"
ACCENT_SGR="${ESC_CH}[38;5;114;1m"
RESET_SGR="${ESC_CH}[0m"
# 要件 AC-158 の 3 リテラル（先頭 9 行）と AC-160 の無印表。
EXPECT_FD1="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n▶ 2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (1)\n  4 p-hold 止')"
EXPECT_FD2="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n▶ 3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (1)\n  4 p-hold 止')"
EXPECT_FD3="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (1)\n▶ 4 p-hold 止')"
EXPECT_PLAIN="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (1)\n  4 p-hold 止')"
head9() { printf '%s\n' "$1" | head -n 9; }
count_arrow_rows() { printf '%s\n' "$1" | grep -c '^▶' | tr -d ' '; }                 # ▶ で始まる行
count_target_entries() { printf '%s\n' "$1" | grep -cE '^▶ [0-9]+ ' | tr -d ' '; }    # 対象エントリ行
count_entries() { printf '%s\n' "$1" | grep -cE '^(▶ |  )[0-9]+ ' | tr -d ' '; }      # ▶ 欄 2 セル＋番号
count_reason_rows() { printf '%s\n' "$1" | grep -c '^AI環境' | tr -d ' '; }
count_accent() { printf '%s\n' "$1" | grep -cF '38;5;114;1' | tr -d ' '; }
run_raw() {  # $1=supply $2=rows $3=cols → 色付きの生出力
  CMUX_DOCK_SUPPLY_PROJECT="$1" CMUX_NEXT_ROWS="$2" CMUX_NEXT_COLS="$3" bash "$WATCH" --once
}
# $1=FV スタブ $2=引数 $3=回数 $4=上限(0.1秒単位) → 呼出しが $3 回に達するまで待つ
wait_stub_calls() {
  local w=0
  while [ "$w" -lt "$4" ]; do
    [ "$(stub_FV_calls "$1" "$2")" -ge "$3" ] && return 0
    sleep 0.1; w=$(( w + 1 ))
  done
  return 1
}
block_count() {  # $1=log → 描画ブロック（ESC[H〜ESC[J）の数
  python3 -c 'import re,sys; d=open(sys.argv[1],"rb").read().decode("utf-8","replace"); print(len(re.findall(r"\x1b\[H(.*?)\x1b\[J", d, re.S)))' "$1"
}
distinct_block_count() {  # $1=log → 色・制御列を除いた描画ブロックの異なり数
  python3 - "$1" <<'PYEOF'
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
blocks = re.findall(r"\x1b\[H(.*?)\x1b\[J", data, re.S)
plain = set(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", b).replace("\r", "").rstrip("\n") for b in blocks)
print(len(plain))
PYEOF
}
mk_stub_FV "$WORKDIR/fv_a" "$FV_A_FRAME"
mk_stub_FV "$WORKDIR/fv_b" "$FV_B_FRAME"

echo "=== v7: AC-158 対象行と区分不問（FV-A × FD-1〜3・幅 36・高さ 40・FR-116/117/119） ==="
ac158_case() {  # $1=FD名 $2=--focus の 1 行 $3=期待の先頭 9 行
  set_stub_FV_focus "$WORKDIR/fv_a" "$2"
  local out; out="$(run_once "$WORKDIR/fv_a" 40 36)"
  assert_eq "AC-158($1): 色除去後の先頭 9 行がリテラル一致" "$3" "$(head9 "$out")"
  assert_eq "AC-158($1): ▶ で始まる行はちょうど 1" "1" "$(count_arrow_rows "$out")"
  assert_eq "AC-158($1): エントリ行 4 行とも ▶ 欄 2 セルの後（3 セル目）が番号" "4" "$(count_entries "$out")"
  assert_eq "AC-158($1): 外部脳行は既存 fixture のまま（10 行目以降）" "$(printf '\n外部脳 OK')" "$(printf '%s\n' "$out" | sed -n '10,11p')"
}
ac158_case FD-1 p-act2 "$EXPECT_FD1"
ac158_case FD-2 roles-conf "$EXPECT_FD2"
ac158_case FD-3 p-hold "$EXPECT_FD3"

echo "=== v7: AC-159 強調色（色付きの生バイト・FR-118・設計 §42.9.2 の SGR 位置） ==="
ac159_case() {  # $1=FD名 $2=--focus の 1 行 $3=対象行だけに含まれる語（生出力は RAW159 へ）
  set_stub_FV_focus "$WORKDIR/fv_a" "$2"
  local raw tline; raw="$(run_raw "$WORKDIR/fv_a" 40 36)"; RAW159="$raw"
  tline="$(printf '%s\n' "$raw" | grep -F "$3")"
  assert_eq "AC-159($1): 対象行の SGR 列は強調色とリセットだけ" "[38;5;114;1m [0m" "$(printf '%s\n' "$tline" | sgr_seq)"
  assert_true "AC-159($1): 行の最初の SGR が強調色で、直後が ▶（▶ 欄を含む行全体）" \
    "$(case "$tline" in ("${ACCENT_SGR}▶ "*) echo 1 ;; (*) echo 0 ;; esac)"
  assert_true "AC-159($1): 最後の SGR がリセットで行末" "$(case "$tline" in (*"$RESET_SGR") echo 1 ;; (*) echo 0 ;; esac)"
  assert_eq "AC-159($1): 38;5;114;1 を含む行は出力全体でちょうど 1" "1" "$(count_accent "$raw")"
  assert_eq "AC-159($1): 見出し（稼働中）の SGR は v5 のまま 38;5;252;1" "[38;5;252;1m [0m" "$(printf '%s\n' "$raw" | sed -n '1p' | sgr_seq)"
  assert_eq "AC-159($1): 見出し（待ち）の SGR は v5 のまま 38;5;244;1" "[38;5;244;1m [0m" "$(printf '%s\n' "$raw" | sed -n '5p' | sgr_seq)"
}
RAW159=""
ac159_case FD-1 p-act2 p-act2
assert_eq "AC-159(FD-1): 対象行の生バイト列＝ACCENT ▶ 2 p-act2 実装 RESET（間に SGR 無し）" \
  "${ACCENT_SGR}▶ 2 p-act2 実装${RESET_SGR}" "$(printf '%s\n' "$RAW159" | sed -n '3p')"
assert_true "AC-159(FD-1): 非対象行の ▶ 欄（空白 2）は色の外（v5 の欄ごとの色のまま）" \
  "$(case "$(printf '%s\n' "$RAW159" | sed -n '2p')" in ("  ${ESC_CH}["*) echo 1 ;; (*) echo 0 ;; esac)"
ac159_case FD-2 roles-conf roles-conf
ac159_case FD-3 p-hold p-hold

echo "=== v7: AC-160 未宣言・不明・一致行なし・同 slug・ハング（無印表・FR-120/116・NFR-22） ==="
ac160_plain() {  # $1=FD名 $2=--focus の 1 行 → 無印表・▶ 0・強調色 0・理由行 0
  local out raw
  set_stub_FV_focus "$WORKDIR/fv_a" "$2"
  raw="$(run_raw "$WORKDIR/fv_a" 40 36)"
  out="$(printf '%s\n' "$raw" | strip_sgr)"
  assert_eq "AC-160($1): 色除去後の先頭 9 行が無印表とリテラル一致" "$EXPECT_PLAIN" "$(head9 "$out")"
  assert_eq "AC-160($1): ▶ で始まる行は 0・全エントリ行が空白 2 で始まる" "0/4" "$(count_arrow_rows "$out")/$(count_entries "$out")"
  assert_eq "AC-160($1): 38;5;114;1 は 0 回" "0" "$(count_accent "$raw")"
  assert_eq "AC-160($1): 理由行（AI環境 …）は 0 行" "0" "$(count_reason_rows "$out")"
}
ac160_plain "FD-4" ""          # 未宣言
ac160_plain "FD-5" ""          # cmux 応答なし（identify 非 0）
ac160_plain "FD-5′" ""         # cmux 応答なし（workspace list 非 0）
ac160_plain "FD-6" ""          # 宣言記録破損
ac160_plain "FD-7" ""          # 対象不明
ac160_plain "FD-8" "p-done"    # 宣言先が非表示（一致行なし）
ac160_plain "FD-8′" "p-none"   # 宣言先のノート不在（一致行なし）
# 同 slug 2 ワークスペース＝FD-10 の出力は FD-1 と完全一致（▶ は 1 行）。
set_stub_FV_focus "$WORKDIR/fv_a" "p-act2"
OUT160_FD1="$(run_raw "$WORKDIR/fv_a" 40 36)"
OUT160_FD10="$(run_raw "$WORKDIR/fv_a" 40 36)"
assert_eq "AC-160(FD-10): 出力（色付き）が FD-1 と完全一致" "$OUT160_FD1" "$OUT160_FD10"
assert_eq "AC-160(FD-10): ▶ は 1 行" "1" "$(count_arrow_rows "$(printf '%s\n' "$OUT160_FD10" | strip_sgr)")"
# ハング＝FD-9・FD-9′（RP 層ではどちらも照会が 10 秒応答しない）＝無印表・1 ティック ≤ 6 秒。
for name in "FD-9" "FD-9′"; do
  set_stub_FV_focus "$WORKDIR/fv_a" "sleep 10"
  T0_160="$(now_mono)"
  RAW160="$(run_raw "$WORKDIR/fv_a" 40 36)"
  T1_160="$(now_mono)"
  OUT160="$(printf '%s\n' "$RAW160" | strip_sgr)"
  assert_eq "AC-160($name): ハング中の出力は無印表と完全一致" "$EXPECT_PLAIN" "$(head9 "$OUT160")"
  assert_eq "AC-160($name): 理由行 0・強調色 0" "0/0" "$(count_reason_rows "$OUT160")/$(count_accent "$RAW160")"
  assert_true "AC-160($name): 1 ティック（--once）の所要が 6 秒以内（NFR-22）" \
    "$(python3 -c "print(1 if $T1_160 - $T0_160 <= 6.0 else 0)")"
done

echo "=== v7: AC-161 幅（FW-1＝FV-A × roles-conf・幅 36／35・FR-121） ==="
set_stub_FV_focus "$WORKDIR/fv_a" "roles-conf"
OUT161_36="$(run_once "$WORKDIR/fv_a" 40 36)"
L161_36="$(printf '%s\n' "$OUT161_36" | sed -n '6p')"
assert_eq "AC-161(FW-1 幅36): 待ち行（対象行）がリテラル一致" "▶ 3 roles-conf 職種を設… 12/31 23:59" "$L161_36"
assert_eq "AC-161(FW-1 幅36): 待ち行の表示幅=36" "36" "$(disp_width "$L161_36")"
assert_true "AC-161(FW-1 幅36): 全行の表示幅≤36" "$([ "$(printf '%s\n' "$OUT161_36" | max_disp_width)" -le 36 ] && echo 1 || echo 0)"
OUT161_35="$(run_once "$WORKDIR/fv_a" 40 35)"
L161_35="$(printf '%s\n' "$OUT161_35" | sed -n '6p')"
assert_eq "AC-161(FW-1 幅35): next 欄が 職種を…（対象行・表示幅 34・短縮形は全文字）" "▶ 3 roles-conf 職種を… 12/31 23:59" "$L161_35"
assert_eq "AC-161(FW-1 幅35): 待ち行の表示幅=34" "34" "$(disp_width "$L161_35")"
assert_true "AC-161(FW-1 幅35): 全行の表示幅≤35" "$([ "$(printf '%s\n' "$OUT161_35" | max_disp_width)" -le 35 ] && echo 1 || echo 0)"
set_stub_FV_focus "$WORKDIR/fv_a" "p-act2"
L161_FD1_36="$(run_once "$WORKDIR/fv_a" 40 36 | sed -n '6p')"
assert_eq "AC-161(FD-1 幅36): 同じ行（非対象行）がリテラル一致・表示幅 36" "  3 roles-conf 職種を設… 12/31 23:59/36" "$L161_FD1_36/$(disp_width "$L161_FD1_36")"
L161_FD1_35="$(run_once "$WORKDIR/fv_a" 40 35 | sed -n '6p')"
assert_eq "AC-161(FD-1 幅35): 同じ行（非対象行）は 職種を…・表示幅 34" "  3 roles-conf 職種を… 12/31 23:59/34" "$L161_FD1_35/$(disp_width "$L161_FD1_35")"
for l in "$L161_36" "$L161_35" "$L161_FD1_36" "$L161_FD1_35"; do
  assert_true "AC-161: 11 セルの短縮形 12/31 23:59 を全文字含む（23:59 で終わる）" "$(printf '%s\n' "$l" | grep -q ' 12/31 23:59$' && echo 1 || echo 0)"
done

echo "=== v7: AC-162 クランプで対象行を落とさない（FV-B × p-hold7／空行・高さ 12／13・FR-123） ==="
EXPECT_162_H12="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (7)\n▶ 10 p-hold7 h7\n…他6行\n\n外部脳 OK')"
EXPECT_162_H13="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (7)\n  4 p-hold 止\n▶ 10 p-hold7 h7\n…他5行\n\n外部脳 OK')"
EXPECT_162_FD4_H12="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (7)\n  4 p-hold 止\n…他6行\n\n外部脳 OK')"
EXPECT_162_FD4_H13="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n  2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (7)\n  4 p-hold 止\n  5 p-hold2 h2\n…他5行\n\n外部脳 OK')"
set_stub_FV_focus "$WORKDIR/fv_b" "p-hold7"
OUT162_12="$(run_once "$WORKDIR/fv_b" 12 36)"
assert_eq "AC-162(1) 高さ12: 12 行のリテラル（保留は ▶ 10 p-hold7 h7 の 1 行・…他6行）" "$EXPECT_162_H12" "$OUT162_12"
assert_eq "AC-162(1) 高さ12: 行数 12" "12" "$(printf '%s\n' "$OUT162_12" | wc -l | tr -d ' ')"
OUT162_13="$(run_once "$WORKDIR/fv_b" 13 36)"
assert_eq "AC-162(2) 高さ13: 13 行のリテラル（保留は 4 p-hold・▶ 10 p-hold7 の順・…他5行）" "$EXPECT_162_H13" "$OUT162_13"
assert_eq "AC-162(2) 高さ13: 行数 13" "13" "$(printf '%s\n' "$OUT162_13" | wc -l | tr -d ' ')"
set_stub_FV_focus "$WORKDIR/fv_b" ""
assert_eq "AC-162(FD-4) 高さ12: 対象行なしは v5 のまま（保留は 4 p-hold 止）" "$EXPECT_162_FD4_H12" "$(run_once "$WORKDIR/fv_b" 12 36)"
assert_eq "AC-162(FD-4) 高さ13: 対象行なしは v5 のまま（4 p-hold・5 p-hold2）" "$EXPECT_162_FD4_H13" "$(run_once "$WORKDIR/fv_b" 13 36)"

echo "=== v7: DT-41 退化（FV-B × p-hold7・高さ 7＝配分 0/0/0・D-v7-8） ==="
# h=7 は固定行（見出し 3・空行 2・外部脳 2）と同じ＝R=0 → 先頭 h 行に退化（v5）。
# 7 行目は空行（$( ) が末尾の LF を落とすので 6 行で比べる）。▶ は 0 個。
EXPECT_DT41="$(printf '● 稼働中 (2)\n\n⏸ 待ち (1)\n\n⏸ 保留 (7)\n…他10行')"
set_stub_FV_focus "$WORKDIR/fv_b" "p-hold7"
OUT_DT41="$(run_once "$WORKDIR/fv_b" 7 36)"
assert_eq "DT-41: 高さ 7 は v5 の退化（先頭 h 行）" "$EXPECT_DT41" "$OUT_DT41"
assert_eq "DT-41: ▶ 0 個（配分 0 のブロックに対象行を押し込まない）" "0" "$(count_arrow_rows "$OUT_DT41")"

echo "=== v7: DT-38 照会口の 0 バイト・2 行（描画側は対象なし＝無印表） ==="
: > "$WORKDIR/fv_a.focus"
OUT38A="$(run_once "$WORKDIR/fv_a" 40 36)"
assert_eq "DT-38(a) 0 バイト: 無印表" "$EXPECT_PLAIN" "$(head9 "$OUT38A")"
assert_eq "DT-38(a) 0 バイト: 理由行 0" "0" "$(count_reason_rows "$OUT38A")"
printf 'p-act2\np-act1\n' > "$WORKDIR/fv_a.focus"
OUT38B="$(run_once "$WORKDIR/fv_a" 40 36)"
assert_eq "DT-38(b) 2 行: 無印表（先頭行だけを読まない）" "$EXPECT_PLAIN" "$(head9 "$OUT38B")"
assert_eq "DT-38(b) 2 行: 理由行 0" "0" "$(count_reason_rows "$OUT38B")"

echo "=== v7: AC-167 片側配置（FV-A × FD-1・FX-6・NFR-24＝▶ の無い表） ==="
# (i) 新供給側（--frame は /4 不変・--focus あり）× 旧描画側（FX-6 の写し）。
# 旧描画側は自分の場所の 1 つ上から lib を引くので、写しを同じ形に置き lib は
# 現行のもの（共有部品は引数省略時 --frame 互換＝M-v7-10）を指す。
EXPECT_V6_FVA="$(printf '▶ 稼働中 (2)\n1 p-act1 設計\n2 p-act2 実装\n\n⏸ 待ち (1)\n3 roles-conf 職種を設定… 12/31 23:59\n\n⏸ 保留 (1)\n4 p-hold 止\n\n外部脳 OK')"
mkdir -p "$WORKDIR/fx6/cmux-next-watch"
cp "$FX6_WATCH" "$WORKDIR/fx6/cmux-next-watch/cmux-next-watch.sh"
ln -sf "$CMUX_DIR/lib-dock-view.sh" "$WORKDIR/fx6/lib-dock-view.sh"
ln -sf "$CMUX_DIR/lib-supply-frame.sh" "$WORKDIR/fx6/lib-supply-frame.sh"
set_stub_FV_focus "$WORKDIR/fv_a" "p-act2"
RAW167_I="$(CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/fv_a" CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=36 bash "$WORKDIR/fx6/cmux-next-watch/cmux-next-watch.sh" --once)"
OUT167_I="$(printf '%s\n' "$RAW167_I" | strip_sgr)"
assert_eq "AC-167(i) 新供給側×旧描画側: v6 AC-152 の画面（▶ 稼働中 (2)・エントリ行の先頭が番号）" "$EXPECT_V6_FVA" "$OUT167_I"
assert_eq "AC-167(i): 対象エントリ行 0・38;5;114;1 0 回・理由行 0" "0/0/0" \
  "$(count_target_entries "$OUT167_I")/$(count_accent "$RAW167_I")/$(count_reason_rows "$OUT167_I")"
# (ii) 旧供給側（--frame＝FX-6 の記録フレーム・--focus＝使い方エラー rc 1）× 新描画側。
cat > "$WORKDIR/old_supply" <<EOF
#!/bin/bash
[ "\${1:-}" = "--frame" ] || { echo "使い方: --list|--frame" >&2; exit 1; }
cat "$FV_A_FRAME"
EOF
chmod +x "$WORKDIR/old_supply"
RAW167_II="$(run_raw "$WORKDIR/old_supply" 40 36)"
OUT167_II="$(printf '%s\n' "$RAW167_II" | strip_sgr)"
assert_eq "AC-167(ii) 旧供給側×新描画側: AC-160 の無印表" "$EXPECT_PLAIN" "$(head9 "$OUT167_II")"
assert_eq "AC-167(ii): 対象エントリ行 0・38;5;114;1 0 回・理由行 0" "0/0/0" \
  "$(count_target_entries "$OUT167_II")/$(count_accent "$RAW167_II")/$(count_reason_rows "$OUT167_II")"

echo "=== v7: DT-40 2 周期（対象周期 1・フレーム周期 3・6 秒＝--focus 5〜7 回・--frame 2〜3 回） ==="
mk_stub_FV "$WORKDIR/fv40" "$FV_A_FRAME"
set_stub_FV_focus "$WORKDIR/fv40" "p-act2"
CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/fv40" CMUX_NEXT_INTERVAL=3 CMUX_NEXT_FOCUS_INTERVAL=1 CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=36 \
  bash "$WATCH" >/dev/null 2>&1 &
DPID40=$!
sleep 6
kill -TERM "$DPID40" 2>/dev/null; wait_pid_bounded "$DPID40" 50
N40_FOCUS="$(stub_FV_calls "$WORKDIR/fv40" --focus)"
N40_FRAME="$(stub_FV_calls "$WORKDIR/fv40" --frame)"
assert_true "DT-40: --focus が 5〜7 回（実際 ${N40_FOCUS} 回）" "$([ "$N40_FOCUS" -ge 5 ] && [ "$N40_FOCUS" -le 7 ] && echo 1 || echo 0)"
assert_true "DT-40: --frame が 2〜3 回（実際 ${N40_FRAME} 回）" "$([ "$N40_FRAME" -ge 2 ] && [ "$N40_FRAME" -le 3 ] && echo 1 || echo 0)"

echo "=== v7: DT-37 同一入力では組み立てを省く（jq スパイ・heartbeat・WINCH・D-v7-10） ==="
# PATH 先頭の jq スパイで組み立て（lib-dock-view.sh の幅計算＝jq）の起動回数を数える。
REAL_JQ="$(command -v jq)"
mkdir -p "$WORKDIR/spybin"
JQ_LOG="$WORKDIR/jq_spy.log"
cat > "$WORKDIR/spybin/jq" <<EOF
#!/bin/bash
echo jq >> "$JQ_LOG"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$WORKDIR/spybin/jq"
jq_calls() { awk 'END{print NR}' "$JQ_LOG" 2>/dev/null; }
mk_stub_FV "$WORKDIR/fv37" "$FV_A_FRAME"
set_stub_FV_focus "$WORKDIR/fv37" "p-act2"
: > "$JQ_LOG"
PATH="$WORKDIR/spybin:$PATH" run_raw "$WORKDIR/fv37" 40 36 >/dev/null
J_ONCE="$(jq_calls)"
assert_true "DT-37: 1 ティック分（--once）の組み立てで jq が 1 回以上起動する（前提）" "$([ "$J_ONCE" -ge 1 ] && echo 1 || echo 0)"
# (a) 既定の heartbeat＝3 ティック走らせても jq の起動は 1 ティック分と同じ（2・3 ティック目は 0）。
: > "$JQ_LOG"
PATH="$WORKDIR/spybin:$PATH" CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/fv37" CMUX_NEXT_INTERVAL=60 CMUX_NEXT_FOCUS_INTERVAL=1 CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=36 \
  bash "$WATCH" >/dev/null 2>&1 &
DPID37=$!
assert_eq "DT-37(a): 対象周期 1 で 3 ティック（--focus 3 回）が 10 秒以内に来る" "1" \
  "$(wait_stub_calls "$WORKDIR/fv37" --focus 3 100 && echo 1 || echo 0)"
sleep 0.8
J3="$(jq_calls)"
assert_eq "DT-37(a): 同一入力 3 ティックの jq 起動回数＝1 ティック分（--once と同じ）" "$J_ONCE" "$J3"
# (c) WINCH の直後のティックは組み立て直す（≥1）。
kill -WINCH "$DPID37" 2>/dev/null
wait_stub_calls "$WORKDIR/fv37" --focus 4 100 || echo "  DT-37(c): WINCH 後のティックが 10 秒以内に来ない"
sleep 0.8
J4="$(jq_calls)"
assert_true "DT-37(c): WINCH 直後のティックで jq が 1 回以上起動する（${J3} → ${J4}）" "$([ "$J4" -gt "$J3" ] && echo 1 || echo 0)"
kill -TERM "$DPID37" 2>/dev/null; wait_pid_bounded "$DPID37" 50
# (b) heartbeat 1 秒＝2・3 ティック目も組み立て直す（各 ≥1）。
mk_stub_FV "$WORKDIR/fv37b" "$FV_A_FRAME"
set_stub_FV_focus "$WORKDIR/fv37b" "p-act2"
: > "$JQ_LOG"
PATH="$WORKDIR/spybin:$PATH" CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/fv37b" CMUX_NEXT_INTERVAL=60 CMUX_NEXT_FOCUS_INTERVAL=1 CMUX_NEXT_REDRAW_HEARTBEAT=1 CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=36 \
  bash "$WATCH" >/dev/null 2>&1 &
DPID37B=$!
wait_stub_calls "$WORKDIR/fv37b" --focus 3 100 || echo "  DT-37(b): 3 ティック目が 10 秒以内に来ない"
sleep 0.8
J3B="$(jq_calls)"
kill -TERM "$DPID37B" 2>/dev/null; wait_pid_bounded "$DPID37B" 50
assert_true "DT-37(b): heartbeat 1 秒では 2・3 ティック目も jq が起動する（${J_ONCE}+2 ≤ ${J3B}）" "$([ "$J3B" -ge $(( J_ONCE + 2 )) ] && echo 1 || echo 0)"

echo "=== v7: AC-168 ハングからの復帰（FV-A × FD-9″・同一常駐・幅 36・高さ 40・NFR-22） ==="
# --focus スタブがファイルの内容で「10 秒 sleep」→「p-act2」に切り替わる。対象周期は
# 既定と同値の 2 秒を明示（ティックの所要＝連続する --focus の間隔 − 2）。
mk_stub_FV "$WORKDIR/fv168" "$FV_A_FRAME"
set_stub_FV_focus "$WORKDIR/fv168" "sleep 10"
LOG168="$WORKDIR/ac168.log"
CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/fv168" CMUX_NEXT_FOCUS_INTERVAL=2 CMUX_NEXT_ROWS=40 CMUX_NEXT_COLS=36 \
  bash "$WATCH" >"$LOG168" 2>/dev/null &
DPID168=$!
# (1) ハング中＝最初の描画（照会の締切 5 秒の後）が無印表・2 ティック目の照会が始まるまで待つ。
w=0; while [ "$w" -lt 150 ] && [ "$(esc_count "$LOG168" "$ESC2026L")" -lt 1 ]; do sleep 0.1; w=$(( w + 1 )); done
wait_stub_calls "$WORKDIR/fv168" --focus 2 120 || echo "  AC-168: 2 ティック目の照会が 12 秒以内に始まらない"
sleep 0.5   # 2 ティック目のスタブが「sleep 10」を読み終えてから切り替える
assert_eq "AC-168(1): ハング中の描画ブロックはすべて無印表（異なり数 1）" "1" "$(distinct_block_count "$LOG168")"
assert_eq "AC-168(1): ハング中の画面の先頭 9 行が無印表と完全一致" "$EXPECT_PLAIN" "$(head9 "$(last_block "$LOG168")")"
assert_eq "AC-168(1): 理由行 0 行" "0" "$(count_reason_rows "$(last_block "$LOG168")")"
# (2) 正常（FD-1＝p-act2）へ切り替えた時刻 t_r から 11 秒以内に ▶ 2 p-act2 実装 の画面。
set_stub_FV_focus "$WORKDIR/fv168" "p-act2"
T_R="$(now_mono)"
w=0; FOUND168=0
while [ "$w" -lt 120 ]; do
  if [ "$(esc_count "$LOG168" "$ESC2026L")" -ge 2 ] && printf '%s\n' "$(last_block "$LOG168")" | grep -qF '▶ 2 p-act2 実装'; then FOUND168=1; break; fi
  sleep 0.1; w=$(( w + 1 ))
done
T_F="$(now_mono)"
assert_eq "AC-168(2): 復帰フレーム（▶ 2 p-act2 実装）が描かれる" "1" "$FOUND168"
assert_true "AC-168(2): 切替時刻から復帰まで 11 秒以内" "$(python3 -c "print(1 if $T_F - $T_R <= 11.0 else 0)")"
assert_eq "AC-168(2): 復帰フレームの先頭 9 行が AC-158 FD-1 の期待と一致" "$EXPECT_FD1" "$(head9 "$(last_block "$LOG168")")"
N168="$(stub_FV_calls "$WORKDIR/fv168" --focus)"
wait_stub_calls "$WORKDIR/fv168" --focus $(( N168 + 1 )) 100 || echo "  AC-168: 復帰後の次のティックが来ない"
sleep 1
assert_eq "AC-168(2): その次の 1 ティックの画面も FD-1 の期待と一致" "$EXPECT_FD1" "$(head9 "$(last_block "$LOG168")")"
# (1) 各ティックの所要 ≤ 6 秒＝ハング中の連続する --focus の間隔（所要＋対象周期 2）≤ 8。
GAP168_BAD="$(awk -F '\t' '$1 == "--focus" { if (prev != "" && $2 - prev > 8.0) bad++; prev = $2 } END { print bad + 0 }' "$WORKDIR/fv168.calls")"
assert_eq "AC-168(1): 各ティックの所要が 6 秒以内（--focus の間隔 ≤ 対象周期 2＋6）" "0" "$GAP168_BAD"
# (3) 常駐の PID は不変で生きている。
assert_eq "AC-168(3): 常駐の PID が生きている（再起動されていない）" "1" "$(kill -0 "$DPID168" 2>/dev/null && echo 1 || echo 0)"
kill -TERM "$DPID168" 2>/dev/null; wait_pid_bounded "$DPID168" 50

echo "=== v7: AC-166 (a1)(a2)(a3) 文書の追随（README の意味・設計 §42.13 DOC 層）＋対象周期の設定口（A-v7-2） ==="
# README は途中で折り返すので、改行を除いて「。」で文に分け、1 文に全部の語を
# 含むものが 1 つ以上あるかを見る（(b) は供給側＝ai-env の担当）。
readme_has_sentence() {  # $@=語 → 1 文に全部含む文があれば 1
  python3 - "$README_NEXT" "$@" <<'PYEOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read().replace("\n", "")
words = sys.argv[2:]
print(1 if any(all(w in s for w in words) for s in text.split("。")) else 0)
PYEOF
}
assert_eq "v7_ac166_a1_readme: 1 文に ▶・フォーカス・宣言（宣言先の行に ▶）" "1" "$(readme_has_sentence '▶' 'フォーカス' '宣言')"
assert_eq "v7_ac166_a2_readme: 1 文に 未宣言・付かない（どの行にも ▶ が付かない）" "1" "$(readme_has_sentence '未宣言' '付かない')"
assert_eq "v7_ac166_a3_readme: 1 文に ●・稼働中（見出しが ●）" "1" "$(readme_has_sentence '●' '稼働中')"
assert_eq "v7_a_v7_2_readme: 環境変数表に CMUX_NEXT_FOCUS_INTERVAL の行があり既定が 2" "1" \
  "$(grep -E '^\| `CMUX_NEXT_FOCUS_INTERVAL` \| 2 \|' "$README_NEXT" | wc -l | tr -d ' ')"

# ===========================================================================
# v7 実装側の内部不変条件（implementer 追加・設計 §42.4 境界 ②③・§42.7.2・A-v7-2）
# ===========================================================================
echo "=== v7(impl): 対象行が配分の中にあるブロックは先頭 k 行のまま（§42.7.2 の 1 行目） ==="
# FV-B × p-act2（稼働中 2 件の 2 件目）・高さ 12（配分 2/1/1）＝稼働中は先頭 2 行の
# まま（▶ 2 p-act2）・保留は v5 のまま先頭 4 p-hold（対象行の無いブロックは不変）。
EXPECT_IMPL_IN_K="$(printf '● 稼働中 (2)\n  1 p-act1 設計\n▶ 2 p-act2 実装\n\n⏸ 待ち (1)\n  3 roles-conf 職種を設… 12/31 23:59\n\n⏸ 保留 (7)\n  4 p-hold 止\n…他6行\n\n外部脳 OK')"
set_stub_FV_focus "$WORKDIR/fv_b" "p-act2"
assert_eq "v7_impl_target_in_k: 高さ 12 で対象行が配分内なら残す行は v5 と同じ（▶ だけ付く）" "$EXPECT_IMPL_IN_K" "$(run_once "$WORKDIR/fv_b" 12 36)"

echo "=== v7(impl): 照会結果は等値比較だけ（前方一致・末尾空白・TAB 付きは対象なし＝境界 ②） ==="
for focus_val in "p-act" "p-act2 " "p-act2$(printf '\t')x" " p-act2"; do
  set_stub_FV_focus "$WORKDIR/fv_a" "$focus_val"
  OUT_IMPL_EQ="$(run_once "$WORKDIR/fv_a" 40 36)"
  assert_eq "v7_impl_equality_only([$focus_val]): 無印表・理由行 0" "$EXPECT_PLAIN/0" "$(head9 "$OUT_IMPL_EQ")/$(count_reason_rows "$OUT_IMPL_EQ")"
done

echo "=== v7(impl): フレームと照会は独立に失敗する（境界 ③＝フレーム失敗は理由行 1 行・照会は関与しない） ==="
mk_stub_FV "$WORKDIR/fv_noframe" "$WORKDIR/no-such-frame-file"
set_stub_FV_focus "$WORKDIR/fv_noframe" "p-act2"
OUT_IMPL_NF="$(run_once "$WORKDIR/fv_noframe" 40 36)"
assert_eq "v7_impl_frame_fail: --frame 失敗（rc 非 0）は理由行 1 行だけ（照会が 1 語返しても ▶ は出ない）" "AI環境 応答なし" "$OUT_IMPL_NF"
assert_eq "v7_impl_frame_fail: --focus も呼ばれている（フレーム失敗で照会を省かない＝毎ティック）" "1/1" \
  "$(stub_FV_calls "$WORKDIR/fv_noframe" --frame)/$(stub_FV_calls "$WORKDIR/fv_noframe" --focus)"

echo "=== v7(impl): 対象周期の設定口の受理規則は CMUX_NEXT_INTERVAL と同じ（A-v7-2） ==="
for spec in "abc:2" "0:2" "-3:2" ":2" "7:7"; do
  val="${spec%%:*}"; want="${spec#*:}"
  got="$(
    export CMUX_NEXT_FOCUS_INTERVAL="$val"
    . "$WATCH"
    printf '%s' "$FOCUS_INTERVAL"
  )"
  assert_eq "v7_impl_focus_interval([$val]): 正整数以外は既定 2" "$want" "$got"
done

echo "=== --list 拒否（F-56） ==="
OUT8="$(bash "$WATCH" --list 2>&1)"; RC8=$?
assert_eq "--list は既知だが提供しない引数としてrc=1" "1" "$RC8"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
