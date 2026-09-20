#!/bin/bash
# cmux-next-watch.sh のユニットテスト（cmux-session-todo 設計 v3・RP層）。
# ai-env が1バイトも無い隔離環境でも通る（呼び出し口はP群スタブ・AC-107）。
#
# 実行方法: bash cmux/cmux-next-watch/tests/test-cmux-next-watch.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CMUX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCH="$SCRIPT_DIR/../cmux-next-watch.sh"
STUBS="$CMUX_DIR/tests/lib-supply-stubs.sh"

[ -r "$WATCH" ] || { echo "FATAL: 見つかりません: $WATCH" >&2; exit 1; }
[ -r "$STUBS" ] || { echo "FATAL: 見つかりません: $STUBS" >&2; exit 1; }
. "$CMUX_DIR/lib-dock-view.sh"
. "$CMUX_DIR/lib-supply-frame.sh"
. "$STUBS"

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
# mk_stub_P6_project／_p6_proj_lines）を新契約（cmux-dock-frame/3・B行=
# 外部脳1種・bkind/bwarn/btextの上書き対応）へ更新したため、このファイル
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

# Project期待フレーム（8行・空行2行を含む。外部脳ヘルス行はDock契約
# cmux-dock-frame/3＝health-self-explain 設計 v1.2 §6・D-3＝見出し行なし
# の1行）。
EXPECT_P6="$(printf '▶ 稼働中 (2)\n5 svwb-pilot 実データ照合を回す\n6 takumi009- (next未設定)\n\n⏸ 保留 (1)\n7 avatar-swi 配布方式のたたき台を書く\n\n外部脳 OK')"

echo "=== AC-91: Project期待フレーム8行との完全一致（色なし比較） ==="
mk_stub_P6_project "$WORKDIR/p6" 5 6 7
OUT="$(CMUX_NEXT_ROWS=40 run_watch "$WORKDIR/p6" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
assert_eq "AC-91: --once の出力(色除去後)が期待フレームと完全一致" "$EXPECT_P6" "$OUT"
assert_eq "AC-91: 行数は8(見出し行が無くなった分だけ旧v3.5の10行より減る)" "8" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

echo "=== 外部脳ヘルス行（cmux-dock-frame/3・health-self-explain 設計 v1.2 §6） ==="
assert_true "extbrain_no_heading_one_line: ⚠/✅の見出し行が0件" \
  "$(printf '%s\n' "$OUT" | grep -qE '⚠ 外部脳|✅ 外部脳' && echo 0 || echo 1)"
assert_true "extbrain_no_heading_one_line: 外部脳ブロックはちょうど1行" \
  "$([ "$(printf '%s\n' "$OUT" | grep -cF '外部脳')" -eq 1 ] && echo 1 || echo 0)"

# extbrain_three_colors_error_red: warn値ごとに正しい色が乗る（本人裁定
# OQ-1のERR_C=38;5;203を含む3色）。色を消さない生出力で見る。
for spec in "ok:114" "warn:214" "error:203"; do
  bwarn="${spec%%:*}" expect_code="${spec#*:}"
  mk_stub_P6_project "$WORKDIR/color_$bwarn" 5 6 7 外部脳 "$bwarn" "TXT"
  COLOR_RAW="$(run_watch "$WORKDIR/color_$bwarn" --once)"
  assert_true "extbrain_three_colors_error_red(${bwarn}): 38;5;${expect_code}が外部脳行に乗る" \
    "$(printf '%s' "$COLOR_RAW" | grep -qF "$(printf '\033')[38;5;${expect_code}m外部脳 TXT" && echo 1 || echo 0)"
done

# extbrain_suffix_candidates_rendered: 末尾の「候補N件」付記（供給側が
# 付ける・0件も表示＝R-2）をそのまま逐語で描く。
mk_stub_P6_project "$WORKDIR/suffix" 5 6 7 外部脳 ok "OK 候補390件"
OUT_SUFFIX="$(run_watch "$WORKDIR/suffix" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
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
# は/3への非互換版上げで変わったが、縮退時の固定文言は不変）。
{
  printf '#V\tcmux-dock-frame/1\tProject\n'
  printf 'P\t5\tsvwb-pilot-log\t実データ照合を回す\t稼働中\n'
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
  printf '#V\tcmux-dock-frame/3\tProject\n'
  printf 'P\t5\tsvwb-pilot-log\t実データ照合を回す\t稼働中\n'
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
CMUX_DOCK_SUPPLY_PROJECT="$STATE_LINK97" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_ROWS=40 \
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
RENDER_FILES=("$WATCH" "$CMUX_DIR/lib-dock-view.sh" "$CMUX_DIR/lib-supply-frame.sh")
assert_true "AC-87③: ソース(描画側4ファイル)にドメイン環境変数名が0件" \
  "$(grep -qE 'CMUX_NEXT_VAULT|CMUX_TASK_VAULT|CMUX_TASK_STATE' "${RENDER_FILES[@]}" && echo 0 || echo 1)"
assert_true "AC-87③: ソース(描画側4ファイル)に固定パスが0件" \
  "$(grep -qE 'Data/obsidian|\.config/cmux-task-watch|\.claude/logs' "${RENDER_FILES[@]}" && echo 0 || echo 1)"
assert_true "AC-87③: ソース(描画側4ファイル)にcmuxの呼び出しが0件" \
  "$(grep -qE '(^|[;&|(]|\$\()[[:space:]]*cmux[[:space:]]+(--json|identify|workspace|list-windows)' "${RENDER_FILES[@]}" && echo 0 || echo 1)"

echo "=== AC-88: 5ティックで供給側の呼出しがちょうど5回前後 ==="
SPY_LOG="$WORKDIR/spy.log"
: > "$SPY_LOG"
cat > "$WORKDIR/spy_supply" <<SPYEOF
#!/bin/bash
echo call >> "$SPY_LOG"
TAB="\$(printf '\t')"
printf '#V%scmux-dock-frame/3%sProject\n' "\$TAB" "\$TAB"
printf 'P%s1%sspy%s%s稼働中\n' "\$TAB" "\$TAB" "\$TAB" "\$TAB"
printf 'E%s1\n' "\$TAB"
SPYEOF
chmod +x "$WORKDIR/spy_supply"
AC88_INTERVAL=1
AC88_T0="$(now_mono)"
CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/spy_supply" CMUX_NEXT_INTERVAL="$AC88_INTERVAL" CMUX_NEXT_ROWS=40 \
  bash "$WATCH" >/dev/null 2>&1 &
DAEMON_PID=$!
# 5回目を検出したら即killし、6回目の発生を防いで「ちょうど5件(±0)」を
# wall-clockのsleepより厳密に検査する（検証1巡目 #14）。
waited=0
CALLS=0
while [ "$waited" -lt 150 ]; do
  CALLS="$(awk 'END{print NR}' "$SPY_LOG" 2>/dev/null)"
  is_number "$CALLS" || CALLS=0
  [ "$CALLS" -ge 5 ] && break
  sleep 0.05
  waited=$(( waited + 1 ))
done
AC88_T1="$(now_mono)"
kill -TERM "$DAEMON_PID" 2>/dev/null
wait_pid_bounded "$DAEMON_PID" 50
sleep 0.2
CALLS="$(awk 'END{print NR}' "$SPY_LOG" 2>/dev/null)"
assert_eq "AC-88: 5ティックで供給側の呼出しがちょうど5回(±0)" "5" "$CALLS"
# 呼出回数だけでなく間隔も見る（検証2巡目 #31）。5回に達するまでの経過が
# 4×interval未満なら、ティック間隔が縮む倍呼び系の退行を見逃す。
AC88_ELAPSED="$(python3 -c "print($AC88_T1 - $AC88_T0)")"
assert_true "AC-88: 5回目までの経過が4×interval(=4秒)以上(検証2巡目#31)" \
  "$(python3 -c "print(1 if $AC88_ELAPSED >= 4 * $AC88_INTERVAL else 0)")"

echo "=== AC-90: FR-72の描画射影（切り詰め・クランプ・件数一致） ==="
# 10コードポイント超の正式名と幅に収まらないnext値・クランプなし(M-4=幅16)。
{
  printf '#V\tcmux-dock-frame/3\tProject\n'
  printf 'P\t1\tavatar-switch-plan-long-name\t配布方式のたたき台を書く長い説明文\t稼働中\n'
  printf 'E\t1\n'
} > "$WORKDIR/p90a.data"
cat > "$WORKDIR/p90a" <<'EOF'
#!/bin/bash
cat "$0.data"
EOF
chmod +x "$WORKDIR/p90a"
OUT6="$(CMUX_NEXT_ROWS=40 CMUX_TASK_COLS=16 run_watch "$WORKDIR/p90a" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
NAME_LINE="$(printf '%s\n' "$OUT6" | sed -n '2p')"
assert_true "AC-90③: 正式名は10コードポイントへ切り詰められる" \
  "$(printf '%s' "$NAME_LINE" | awk '{print $2}' | python3 -c 'import sys; s=sys.stdin.readline().rstrip("\n"); print(1 if len(s)<=10 else 0)')"

# クランプあり（高さ8）＝各区分の見出しの件数が全行数と一致(落ちた分だけ減らない)
{
  printf '#V\tcmux-dock-frame/3\tProject\n'
  for i in 1 2 3 4 5; do
    printf 'P\t%d\tproj-%d\tnext-%d\t稼働中\n' "$i" "$i" "$i"
  done
  printf 'P\t6\tproj-6\tnext-6\t保留\n'
  printf 'E\t6\n'
} > "$WORKDIR/p90b.data"
cat > "$WORKDIR/p90b" <<'EOF'
#!/bin/bash
cat "$0.data"
EOF
chmod +x "$WORKDIR/p90b"
OUT7="$(CMUX_NEXT_ROWS=8 CMUX_TASK_COLS=40 run_watch "$WORKDIR/p90b" --once | sed -E $'s/\x1b\\[[0-9;]*m//g')"
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
CMUX_DOCK_SUPPLY_PROJECT="$WORKDIR/same_p6" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_ROWS=40 \
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
  CMUX_DOCK_SUPPLY_PROJECT="$supply" CMUX_DOCK_SUPPLY_TIMEOUT=1 CMUX_NEXT_INTERVAL=1 CMUX_NEXT_ROWS=40 \
    bash "$WATCH" >"$LOG" 2>/dev/null &
  DPID=$!
  if ! wait_fp3 "$fp" 100; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: AC-123($name/Project): 足跡の3種別(main/child/watchdog)が揃わない"
    kill -TERM "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
    continue
  fi
  sleep 1.5
  DAEMON_ALIVE="$(kill -0 "$DPID" 2>/dev/null && echo 1 || echo 0)"
  assert_eq "AC-123($name/Project): 常駐は生き続ける" "1" "$DAEMON_ALIVE"
  assert_eq "AC-123($name/Project): 足跡の全PID・全PGIDが死んでいる" "0" "$(fp_all_dead "$fp")"
  assert_eq "AC-123($name/Project): ESC[?25hは出ない(常駐は生存)" "0" "$(esc_count "$LOG" "$ESC25H")"
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

echo "=== --list 拒否（F-56） ==="
OUT8="$(bash "$WATCH" --list 2>&1)"; RC8=$?
assert_eq "--list は既知だが提供しない引数としてrc=1" "1" "$RC8"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
