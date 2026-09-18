#!/bin/bash
# cmux-task-watch.sh のユニットテスト（cmux-session-todo 設計 v4・§39・RT層）。
# ai-env が1バイトも無い隔離環境でも通る（呼び出し口はP群スタブ・AC-107）。
#
# 実行方法: bash cmux/cmux-task-watch/tests/test-cmux-task-watch.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CMUX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCH="$SCRIPT_DIR/../cmux-task-watch.sh"
STUBS="$CMUX_DIR/tests/lib-supply-stubs.sh"

[ -r "$WATCH" ] || { echo "FATAL: 見つかりません: $WATCH" >&2; exit 1; }
[ -r "$STUBS" ] || { echo "FATAL: 見つかりません: $STUBS" >&2; exit 1; }
. "$CMUX_DIR/lib-dock-view.sh"
. "$CMUX_DIR/lib-supply-frame.sh"
. "$STUBS"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-cmux-task-watch.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

# AC-123のTMPDIR集合比較が実launchd常駐(cmux-task-watch/cmux-next-watch)の
# 同時ティックと衝突する時限フレーク対策（設計 F-79・DT-15）。WORKDIRを
# 作った後に隔離用のサブディレクトリへTMPDIRを差し替える（WORKDIR自体は
# 旧TMPDIR配下に作るため順序を逆にしない＝自己参照を避ける）。以降の
# tmp_snapshot・run_supplyの一時物はすべてこの配下だけを見る。
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
  CMUX_DOCK_SUPPLY_TASK="$supply" bash "$WATCH" "$@"
}

now_mono() { python3 -c 'import time; print(time.monotonic())'; }

# $1=ログファイル $2=探す部分文字列 $3=上限秒。ポーリング(0.1秒間隔)で
# ログに文字列が現れるのを待つ（v2 test-cmux-task-watch.shから移管。
# AC-80①・DT-2④（v2移管）が使う）。
wait_for() {
  local file="$1" pattern="$2" timeout="$3" i
  local n=$(( timeout * 10 ))
  for ((i = 0; i < n; i++)); do
    if [ -f "$file" ] && grep -qF -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# $1=PID を上限秒(既定10秒)までポーリングで待ち、それでも生きていたら
# -9 で強制終了する（テストが何らかの理由で無応答なプロセスにブロック
# され続けないようにする安全弁。本番の run_supply/cleanup 自体は
# blocking wait のままでよい＝これはテスト側の保険）。
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

# --- v4 期待リテラル（§39.5.2・§39.3のP-6′をそのまま埋め込む。現物の
# 描画関数からは生成しない＝§11.4）。 ------------------------------------
EXPECT_P6=$'▶ 1 v2                               1/3\n   [x] 要件定義\n   [/] 設計\n   [ ] 実装\n 2 v3                                0/4\n── 完了 1 件 ✅'

echo "=== AC-131: P-6′（番号1 2）×幅40が§39.5.2の6行リテラルと完全一致 ==="
mk_stub_P6_task "$WORKDIR/p6"
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --plain --once)"
assert_eq "AC-131: 完全一致" "$EXPECT_P6" "$OUT"
assert_eq "AC-131: 行数は6" "6" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
# 幅の検算は独立オラクル（python3・既存AC-11の流儀＝§11.4）。disp_widthの
# 曖昧幅表（▶✅├└…に加えv4で使う─。「・」は実体のdisp_width範囲表で
# 幅2＝東アジア幅Wなので例外集合から外す＝検証1巡目#5）をそのまま複製する。
WIDTHS="$(python3 -c "
import unicodedata
def w(c):
    if c in '▶✅├└…─':
        return 1
    return 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
text = '''$OUT'''
ok = all(sum(w(c) for c in line) <= 40 for line in text.split(chr(10)))
line1 = text.split(chr(10))[0]
line2 = text.split(chr(10))[4]
print('%d %d %d' % (1 if ok else 0, sum(w(c) for c in line1), sum(w(c) for c in line2)))
")"
assert_true "AC-131: 各行の表示幅が40以下(独立オラクル)" "$(printf '%s' "$WIDTHS" | awk '{print $1}')"
assert_eq "AC-131: 版行1(▶ 1 v2 …1/3)の表示幅はちょうど40" "40" "$(printf '%s' "$WIDTHS" | awk '{print $2}')"
assert_eq "AC-131: 版行2( 2 v3 …0/4)の表示幅はちょうど40" "40" "$(printf '%s' "$WIDTHS" | awk '{print $3}')"

echo "=== AC-86′: 供給側が5・6を返すと版行が5・6で始まる（1 2にならない） ==="
mk_stub_P6_task "$WORKDIR/p6_56" 5 6
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6_56" --plain --once)"
FIRST="$(printf '%s\n' "$OUT" | sed -n '1p')"
FIFTH="$(printf '%s\n' "$OUT" | sed -n '5p')"
assert_true "AC-86′: 先頭行が▶ 5で始まる" "$([[ "$FIRST" == "▶ 5 v2"* ]] && echo 1 || echo 0)"
assert_true "AC-86′: 5行目の版行が 6で始まる" "$([[ "$FIFTH" == " 6 v3"* ]] && echo 1 || echo 0)"
assert_true "AC-86′: 1 2で始まらない" "$([[ "$FIRST" != "▶ 1"* ]] && echo 1 || echo 0)"

echo "=== AC-1′〜AC-4′（P-6′基底・番号1 2）: AC-131の6行と完全一致の部分検査 ==="
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --plain --once)"
assert_eq "AC-1′: P-6′の出力がAC-131のリテラルと一致" "$EXPECT_P6" "$OUT"
assert_eq "AC-2′: 子行3行が記載順（3桁字下げ）" "$(printf '   [x] 要件定義\n   [/] 設計\n   [ ] 実装')" \
  "$(printf '%s\n' "$OUT" | sed -n '2,4p')"
FIRST_LINE="$(printf '%s\n' "$OUT" | head -n1)"
assert_true "AC-3′: 先頭行が▶ 1 v2で始まり1/3で終わり幅40" \
  "$([[ "$FIRST_LINE" == "▶ 1 v2"* ]] && [[ "$FIRST_LINE" == *"1/3" ]] && [ "${#FIRST_LINE}" -le 43 ] && echo 1 || echo 0)"
assert_true "AC-4′: 2 v3…0/4を含む" "$([[ "$OUT" == *" 2 v3"*"0/4"* ]] && echo 1 || echo 0)"
assert_true "AC-4′: ── 完了 1 件 ✅を含む" "$([[ "$OUT" == *"── 完了 1 件 ✅"* ]] && echo 1 || echo 0)"

echo "=== AC-124′: 直和型の陽性境界（縮退しない） ==="
mk_stub_P23 "$WORKDIR/p23"
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p23" --plain --once)"
assert_eq "AC-124′①: 全版完了(P-23′)は理由行にならず「── 完了 3 件 ✅」の1行" "── 完了 3 件 ✅" "$OUT"

mk_stub_P24 "$WORKDIR/p24"
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p24" --plain --once)"
EXPECT_P24=$'▶ 1 v1                               0/3\n 2 v2                                0/1'
assert_eq "AC-124′②: 今の版が未着手でも▶が描かれ・子行0・縮退しない" "$EXPECT_P24" "$OUT"

echo "=== AC-7′: V-5相当（今の版が0/0でも通常フレーム・完了行あり） ==="
{
  lines=("V${TAB}1${TAB}v2${TAB}0/0${TAB}cur${TAB}fold" "V${TAB}2${TAB}v3${TAB}0/1${TAB}-${TAB}fold" "D${TAB}1")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$WORKDIR/ac7"
}
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/ac7" --plain --once)"
EXPECT_AC7=$'▶ 1 v2                               0/0\n 2 v3                                0/1\n── 完了 1 件 ✅'
assert_eq "AC-7′: 0/0の今の版が理由行にならず3行で描かれる" "$EXPECT_AC7" "$OUT"

echo "=== AC-8′: 同名版2つ（1つ完了・1つ0/1 fold）が2行で描かれる ==="
{
  lines=("V${TAB}1${TAB}dup${TAB}0/1${TAB}cur${TAB}fold" "D${TAB}1")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$WORKDIR/ac8"
}
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/ac8" --plain --once)"
EXPECT_AC8=$'▶ 1 dup                              0/1\n── 完了 1 件 ✅'
assert_eq "AC-8′: dup(fold)が「[ ] b」を出さず2行で描かれる" "$EXPECT_AC8" "$OUT"

echo "=== AC-9′: P-32（60子行）× M-3（40x8）省略行のN==54 ==="
mk_stub_P32 "$WORKDIR/p32"
OUT="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=8 run_watch "$WORKDIR/p32" --plain --once)"
nlines="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_true "AC-9′: 総行数が8以下" "$([ "$nlines" -le 8 ] && echo 1 || echo 0)"
omit_line="$(printf '%s\n' "$OUT" | tail -n1)"
assert_true "AC-9′: 最終行が…他N行の形" "$(printf '%s' "$omit_line" | grep -qE '^…他[0-9]+行$' && echo 1 || echo 0)"
assert_eq "AC-9′: N==54（総行数61−採った7）" "…他54行" "$omit_line"
assert_true "AC-9′: 先頭が▶ 1 v1で始まる（K0が必ず残る）" "$([[ "$(printf '%s\n' "$OUT" | head -n1)" == "▶ 1 v1"* ]] && echo 1 || echo 0)"

echo "=== AC-11′／AC-12′／AC-54′／DT-6′: 子行の固定部（DIGITS+2+[s] ）が残り本文だけ切り詰め ==="
bodyAsahi25="$(python3 -c 'print("あ"*25)')"
{
  lines=("V${TAB}1${TAB}v1${TAB}0/1${TAB}cur${TAB}open" "C${TAB}[ ]${TAB}${bodyAsahi25}" "D${TAB}0")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$WORKDIR/ac11_v9"
}
out9="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/ac11_v9" --plain --once)"
last9="$(printf '%s\n' "$out9" | tail -n1)"
expected_child="   [ ] $(python3 -c 'print("あ"*16)')…"
assert_eq "AC-11′/DT-6′: 40列(digits=1)は「   [ ] 」+あ×16+…と完全一致" "$expected_child" "$last9"
allw40="$(python3 -c "
import unicodedata
def w(c):
    if c in '▶✅├└…─': return 1
    return 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
ok = all(sum(w(c) for c in line) <= 40 for line in '''$out9'''.split(chr(10)))
print(1 if ok else 0)
")"
assert_true "AC-11′: すべての行の表示幅が40以下" "$allw40"

echo "=== AC-12′: 同フィクスチャ×80列は40超・80以下 ==="
out9_80="$(CMUX_TASK_COLS=80 run_watch "$WORKDIR/ac11_v9" --plain --once)"
allw80over40="$(python3 -c "
import unicodedata
def w(c):
    if c in '▶✅├└…─': return 1
    return 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
text = '''$out9_80'''
ok_all = all(sum(w(c) for c in line) <= 80 for line in text.split(chr(10)))
has_over40 = any(sum(w(c) for c in line) > 40 for line in text.split(chr(10)))
print(1 if (ok_all and has_over40) else 0)
")"
assert_true "AC-12′: 80以下かつ40超の行が存在" "$allw80over40"
assert_eq "AC-54′: 固定部「   [ ] 」は変わらず本文だけ切り詰め（DT-6′と同じ判定）" "$expected_child" "$last9"

echo "=== AC-51′: P-28（V-15′相当）× M-3（40x8）の高さクランプを厳密固定 ==="
mk_stub_P28 "$WORKDIR/p28"
OUT="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=8 run_watch "$WORKDIR/p28" --plain --once)"
EXPECT_AC51=$'▶ 1 v2                              5/12\n   [ ] t6\n   [ ] t7\n   [ ] t8\n   [ ] t9\n   [ ] t10\n   [/] t11\n…他7行'
assert_eq "AC-51′: 完全一致（番号は振り直さない）" "$EXPECT_AC51" "$OUT"

echo "=== AC-53′（欠番AC-52・55・56の後継）: P-27（版名45文字）× M-1/M-4 ==="
mk_stub_P27 "$WORKDIR/p27"
out_m1="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p27" --plain --once)"
# 期待値＝「▶ 1 」+v×31+…+空白1+0/2（右端40桁・版行1行）。
EXPECT_AC53_M1="▶ 1 $(python3 -c 'print("v"*31, end="")')… 0/2"
assert_eq "AC-53′(M-1・40列): 分数が右端に残る" "$EXPECT_AC53_M1" "$out_m1"
assert_true "AC-53′(M-1): 表示幅ちょうど40" "$([ "${#out_m1}" -eq 40 ] && echo 1 || echo 0)"

out_m4="$(CMUX_TASK_COLS=16 run_watch "$WORKDIR/p27" --plain --once)"
EXPECT_AC53_M4="▶ 1 $(python3 -c 'print("v"*7, end="")')… 0/2"
assert_eq "AC-53′(M-4・16列): 分数が右端に残る" "$EXPECT_AC53_M4" "$out_m4"
assert_true "AC-53′(M-4): 表示幅ちょうど16" "$([ "${#out_m4}" -eq 16 ] && echo 1 || echo 0)"

echo "=== DT-4′（v2移管の退化・v4版）: rows=1・rows=2 の退化（完全一致・幅・色） ==="
out1="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=1 run_watch "$WORKDIR/p6" --plain --once)"
assert_eq "DT-4′: rows=1はK0(▶版行)だけ" "▶ 1 v2                               1/3" "$out1"
out2="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=2 run_watch "$WORKDIR/p6" --plain --once)"
expected2=$'▶ 1 v2                               1/3\n…他5行'
assert_eq "DT-4′: rows=2はK0+省略行(N=5・総行数6)" "$expected2" "$out2"
w2ok="$(python3 -c "
lines = '''$out2'''.split(chr(10))
print(1 if all(len(l) <= 40 for l in lines) else 0)
")"
assert_true "DT-4′: rows=2の各行が40以下" "$w2ok"
colored2="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=2 run_watch "$WORKDIR/p6" --once)"
python3 -c "
import sys
data = '''$colored2'''
sys.exit(0 if (data.startswith(chr(27)+'[?2026h') and data.rstrip(chr(10)).endswith(chr(27)+'[?2026l')) else 1)
" && dt4_sync=1 || dt4_sync=0
assert_true "DT-4′: rows=2の色付き出力も同期出力で包まれる" "$dt4_sync"
assert_true "DT-4′: ▶版行に強調色(38;5;114)が付く" "$(printf '%s' "$colored2" | grep -qF '38;5;114' && echo 1 || echo 0)"

echo "=== AC-132: P-29（▶が先頭でない）× rows=4 ==="
mk_stub_P29 "$WORKDIR/p29"
OUT="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=4 run_watch "$WORKDIR/p29" --plain --once)"
EXPECT_AC132=$'▶ 2 v2                               0/2\n   [/] d\n   [ ] e\n…他5行'
assert_eq "AC-132: ▶が先頭でなくても生き残る（総行数8・budget3）" "$EXPECT_AC132" "$OUT"

echo "=== AC-133: 完了行の有無（P-30は無し・P-6′/P-23′は有り） ==="
mk_stub_P30 "$WORKDIR/p30"
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p30" --plain --once)"
assert_true "AC-133①: P-30(D0)に──で始まる行が無い" "$([[ "$OUT" != *$'\n──'* ]] && [[ "$OUT" != "──"* ]] && echo 1 || echo 0)"
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --plain --once)"
assert_eq "AC-133②: P-6′の最終行が── 完了 1 件 ✅" "── 完了 1 件 ✅" "$(printf '%s\n' "$OUT" | tail -n1)"
mk_stub_P23 "$WORKDIR/p23_133"
OUT="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p23_133" --plain --once)"
assert_eq "AC-133③: P-23′は── 完了 3 件 ✅の1行だけ" "── 完了 3 件 ✅" "$OUT"

echo "=== DT-16: clampの親子不変条件（P-28・P-29・P-32 × rows 2〜6） ==="
DT16_FAIL=0
for spec in "p28:v2" "p29:v1" "p32:v1"; do
  fx="${spec%%:*}"
  for r in 2 3 4 5 6; do
    o="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=$r run_watch "$WORKDIR/$fx" --plain --once)"
    ok="$(python3 -c "
import re
lines = '''$o'''.split(chr(10))
digits = 1
child_re = re.compile(r'^ {%d}\[.\] ' % (digits + 2))
version_re = re.compile(r'^▶? \d+ ')
has_arrow = any(l.startswith('▶ ') for l in lines)
# 設計の式どおり全行を走査し、各子行について直前(子行を遡った最初の
# 非子行)が版行(num_re)であることをassertする(検証1巡目#3。省略行
# 「…他N行」・完了行「── 完了…」の直後に子行が来る場合もprev_is_versionが
# Falseのまま維持されるため同時に検出できる)。
ok = True
prev_is_version = False
for l in lines:
    if child_re.match(l):
        if not prev_is_version:
            ok = False
    else:
        prev_is_version = bool(version_re.match(l))
print(1 if (has_arrow and ok) else 0)
")"
    [ "$ok" = "1" ] || { DT16_FAIL=$(( DT16_FAIL + 1 )); echo "  NG: $fx rows=$r"; }
  done
done
assert_eq "DT-16: 全組合せで▶行が残り子行が孤立しない" "0" "$DT16_FAIL"

# AC-90′①②(RT): 画面とスタブの--list応答（§39.4.6のリテラルをP-6′/P-28
# スタブに持たせた＝検証1巡目#2）を突合する。dotfilesの本番コードは
# --listを呼ばない（run_supplyは--frame専用）ので、ここではスタブへ
# 直接--listを渡して取得した固定文字列と画面を比べる。MT側（--frameと
# --listが同じモデルから作られること）はai-env test-cmux-task-model.shの
# N-2′が担保する。
echo "=== AC-90′①(RT): クランプなし(P-6′)＝画面の版番号集合==--list第1列集合、openの版(1)の子行(状態,本文)がlist同番号行(第4,5列)と順序含め一致 ==="
OUT_AC90_1="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --plain --once)"
LIST_AC90_1="$("$WORKDIR/p6" --list)"
AC90_1_OK="$(python3 -c "
import re
out = '''$OUT_AC90_1'''
lst = '''$LIST_AC90_1'''
lines = out.split(chr(10))
version_re = re.compile(r'^▶? (\d+) ')
child_re = re.compile(r'^ {3}\[(.)\] (.*)$')
screen_nums = set()
screen_children = []
cur_num = None
for l in lines:
    m = version_re.match(l)
    if m:
        cur_num = m.group(1)
        screen_nums.add(cur_num)
        continue
    cm = child_re.match(l)
    if cm and cur_num is not None:
        screen_children.append((cur_num, '[' + cm.group(1) + ']', cm.group(2)))
list_rows = [tuple(r.split(chr(9))) for r in lst.split(chr(10)) if r]
list_nums = set(r[0] for r in list_rows)
ok1 = screen_nums == list_nums
list_num1 = [(r[3], r[4]) for r in list_rows if r[0] == '1']
screen_num1 = [(s, b) for (n, s, b) in screen_children if n == '1']
ok2 = list_num1 == screen_num1
print(1 if (ok1 and ok2) else 0)
")"
assert_true "AC-90′①(RT): 版番号集合が一致・openの版(1)の子行がlistと順序含め一致" "$AC90_1_OK"

echo "=== AC-90′②(RT): クランプあり(P-28×rows=8)＝listは番号1の12行、画面に残る子行列がlistの順序保存部分列 ==="
OUT_AC90_2="$(CMUX_TASK_COLS=40 CMUX_TASK_ROWS=8 run_watch "$WORKDIR/p28" --plain --once)"
LIST_AC90_2="$("$WORKDIR/p28" --list)"
AC90_2_OK="$(python3 -c "
import re
out = '''$OUT_AC90_2'''
lst = '''$LIST_AC90_2'''
lines = out.split(chr(10))
child_re = re.compile(r'^ {3}\[(.)\] (.*)$')
screen_children = []
for l in lines:
    cm = child_re.match(l)
    if cm:
        screen_children.append(('[' + cm.group(1) + ']', cm.group(2)))
list_rows = [tuple(r.split(chr(9))) for r in lst.split(chr(10)) if r]
list_len_ok = len(list_rows) == 12 and all(r[0] == '1' for r in list_rows)
list_seq = [(r[3], r[4]) for r in list_rows]
it = iter(list_seq)
ok_sub = all(any(x == y for y in it) for x in screen_children)
print(1 if (list_len_ok and screen_children and ok_sub) else 0)
")"
assert_true "AC-90′②(RT): listが番号1の12行・画面の子行列がlistの順序保存部分列" "$AC90_2_OK"

echo "=== AC-87: ドメインデータに触っていない ==="
mk_stub_P6_task "$WORKDIR/p6_domain"
OUT1="$(CMUX_DOCK_SUPPLY_TASK="$WORKDIR/p6_domain" \
  CMUX_TASK_VAULT="$WORKDIR/does-not-exist-vault" \
  CMUX_TASK_STATE="$WORKDIR/does-not-exist-state.json" \
  CMUX_TASK_COLS=40 bash "$WATCH" --plain --once)"
assert_eq "AC-87①: ドメインデータ不在でも期待フレームと完全一致" "$EXPECT_P6" "$OUT1"

mkdir -p "$WORKDIR/trap-vault/Projects"
echo "trap" > "$WORKDIR/trap-vault/Projects/cmux-session-todo.md"
echo '{"version":1,"workspaces":{"x":"cmux-session-todo"}}' > "$WORKDIR/trap-state.json"
OUT2="$(CMUX_DOCK_SUPPLY_TASK="$WORKDIR/p6_domain" \
  CMUX_TASK_VAULT="$WORKDIR/trap-vault" \
  CMUX_TASK_STATE="$WORKDIR/trap-state.json" \
  CMUX_TASK_COLS=40 bash "$WATCH" --plain --once)"
assert_eq "AC-87②: ドメインデータを実在させ矛盾させても期待フレームと完全一致" "$EXPECT_P6" "$OUT2"

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

echo "=== AC-88: 供給側の呼び出しは5ティックでちょうど5回 ==="
SPY_LOG="$WORKDIR/spy.log"
: > "$SPY_LOG"
cat > "$WORKDIR/spy_supply" <<SPYEOF
#!/bin/bash
echo call >> "$SPY_LOG"
$(cat <<'FRAMEGEN'
TAB="$(printf '\t')"
printf '#V%scmux-dock-frame/2%sTask\n' "$TAB" "$TAB"
printf 'V%s1%sspy%s0/1%scur%sopen\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB"
printf 'C%s[ ]%sa\n' "$TAB" "$TAB"
printf 'D%s0\n' "$TAB"
printf 'E%s3\n' "$TAB"
FRAMEGEN
)
SPYEOF
chmod +x "$WORKDIR/spy_supply"
AC88_INTERVAL=1
AC88_T0="$(now_mono)"
CMUX_DOCK_SUPPLY_TASK="$WORKDIR/spy_supply" CMUX_TASK_FOCUS_INTERVAL="$AC88_INTERVAL" CMUX_TASK_COLS=40 \
  bash "$WATCH" >/dev/null 2>&1 &
DAEMON_PID=$!
# ちょうど5回目が記録された瞬間に即kill（wall-clockのsleepでは4〜6回に
# ぶれ得るため、observed=5を検出でき次第すぐ止めて6回目を防ぐ＝AC-88の
# 「ちょうど5件(±0)」を厳密に検査する・検証1巡目 #14）。
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
sleep 0.2   # killが間に合わなかった場合の直後1回ぶんの猶予を待ってから確定させる
CALLS="$(awk 'END{print NR}' "$SPY_LOG" 2>/dev/null)"
assert_eq "AC-88: 5ティックで供給側の呼出しがちょうど5回(±0)" "5" "$CALLS"
# 呼出回数だけでなく間隔も見る（検証2巡目 #31）。5回に達するまでの経過が
# 4×interval未満なら、ティック間隔が縮む倍呼び系の退行（4→6回等）を見逃す。
AC88_ELAPSED="$(python3 -c "print($AC88_T1 - $AC88_T0)")"
assert_true "AC-88: 5回目までの経過が4×interval(=4秒)以上(検証2巡目#31)" \
  "$(python3 -c "print(1 if $AC88_ELAPSED >= 4 * $AC88_INTERVAL else 0)")"

echo "=== AC-89: 理由行の完全一致（10通り＋未知理由） ==="
REASONS=("cmux 応答なし" "対象不明" "宣言記録破損" "未宣言" "Vault 不在" "ノート不在" "ノート破損" "Tasks 節なし" "タスクなし" "空タスク" "ZZ理由テスト")
i=0
for r in "${REASONS[@]}"; do
  i=$(( i + 1 ))
  {
    printf '#V\tcmux-dock-frame/2\tTask\n'
    printf 'R\t%s\n' "$r"
    printf 'E\t1\n'
  } > "$WORKDIR/reason_$i.data"
  cat > "$WORKDIR/reason_$i" <<STUBEOF
#!/bin/bash
cat "$WORKDIR/reason_$i.data"
STUBEOF
  chmod +x "$WORKDIR/reason_$i"
  OUT="$(run_watch "$WORKDIR/reason_$i" --plain --once)"
  assert_eq "AC-89: 理由文字列[$r]がそのまま描かれる" "$r" "$OUT"
done

echo "=== AC-83①（v2移管）: 未宣言状態で--onceの理由行が未宣言と一致 ==="
{
  printf '#V\tcmux-dock-frame/2\tTask\n'
  printf 'R\t未宣言\n'
  printf 'E\t1\n'
} > "$WORKDIR/ac83_1.data"
cat > "$WORKDIR/ac83_1" <<'STUBEOF'
#!/bin/bash
cat "$0.data"
STUBEOF
chmod +x "$WORKDIR/ac83_1"
OUT="$(run_watch "$WORKDIR/ac83_1" --plain --once)"
assert_eq "AC-83①: --onceの理由行が未宣言" "未宣言" "$OUT"

echo "=== AC-92: P-1a/P-1bはAI環境 未導入 ==="
mk_stub_P1a "$WORKDIR/p1a"
OUT="$(run_watch "$WORKDIR/p1a" --plain --once)"
assert_eq "AC-92: P-1a(不在)はAI環境 未導入" "AI環境 未導入" "$OUT"
mk_stub_P1b "$WORKDIR/p1b"
OUT="$(run_watch "$WORKDIR/p1b" --plain --once)"
assert_eq "AC-92: P-1b(実行不可)はAI環境 未導入" "AI環境 未導入" "$OUT"

echo "=== AC-93: 応答なしの4通り ==="
mk_stub_P2 "$WORKDIR/p2"
assert_eq "AC-93: P-2(非0終了)はAI環境 応答なし" "AI環境 応答なし" "$(run_watch "$WORKDIR/p2" --plain --once)"
mk_stub_P5_row "$WORKDIR/p5r"
assert_eq "AC-93: P-5(行の途中)はAI環境 応答なし" "AI環境 応答なし" "$(run_watch "$WORKDIR/p5r" --plain --once)"
mk_stub_P5_field "$WORKDIR/p5f"
assert_eq "AC-93: P-5(欄の途中)はAI環境 応答なし" "AI環境 応答なし" "$(run_watch "$WORKDIR/p5f" --plain --once)"
mk_stub_P15 "$WORKDIR/p15"
assert_eq "AC-93: P-15(rc=0で0バイト)はAI環境 応答なし" "AI環境 応答なし" "$(run_watch "$WORKDIR/p15" --plain --once)"

echo "=== AC-94: 版ちがい（P-4・P-31） ==="
mk_stub_P4 "$WORKDIR/p4" Task
assert_eq "AC-94: P-4(版が未知)はAI環境 版ちがい" "AI環境 版ちがい" "$(run_watch "$WORKDIR/p4" --plain --once)"
mk_stub_P31 "$WORKDIR/p31"
assert_eq "AC-94: P-31(cmux-dock-frame/1・v3形)はAI環境 版ちがい" "AI環境 版ちがい" "$(run_watch "$WORKDIR/p31" --plain --once)"

echo "=== AC-111: 48サブIDすべてがAI環境 応答なし（RT層） ==="
V_FAIL=0
for id in "${SUPPLY_VIOLATION_IDS[@]}"; do
  case "$id" in P-12b|P-12c|P-19a|P-19b) continue ;; esac  # Project専用は対象外
  path="$WORKDIR/rtviol_$id"
  case "$id" in
    P-14d|P-14e) continue ;;  # run_supply層(test-supply-frame.sh)で既に検査済み
  esac
  mk_stub_P_violation "$path" "$id" >/dev/null 2>&1 || { V_FAIL=$(( V_FAIL + 1 )); continue; }
  OUT="$(run_watch "$path" --plain --once)"
  [ "$OUT" = "AI環境 応答なし" ] || { V_FAIL=$(( V_FAIL + 1 )); echo "  NG: $id -> [$OUT]"; }
done
assert_eq "AC-111(RT): Task向け違反フィクスチャがすべてAI環境 応答なし" "0" "$V_FAIL"

# 常駐の出力ログから「最後に描いたフレーム」を厳密に取り出す（\033[H ...
# \033[J で挟まれた最後のブロック・末尾のESC[K・ESC[0m等のSGRを除去した
# プレーンテキスト）。substring一致ではなく完全一致で見るための共通道具
# （検証1巡目 #14＝AC-113/AC-96の判定を要件の判定式どおりに）。
extract_last_frame() {
  python3 - "$1" <<'PYEOF'
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
blocks = re.findall(r"\x1b\[H(.*?)\x1b\[J", data, re.S)
if not blocks:
    print("")
    sys.exit(0)
last = blocks[-1]
last = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", last)
last = last.replace("\r", "")
print(last.rstrip("\n"))
PYEOF
}

echo "=== AC-113′/AC-96′: 往復6通り（最後に描いたフレームの完全一致で判定） ==="
mk_stub_P6_task "$WORKDIR/round_p6"
mk_stub_P1a "$WORKDIR/round_p1a"
mk_stub_P2 "$WORKDIR/round_p2"
mk_stub_P4 "$WORKDIR/round_p4" Task
EXPECT_REASON_MAP_round_p1a="AI環境 未導入"
EXPECT_REASON_MAP_round_p2="AI環境 応答なし"
EXPECT_REASON_MAP_round_p4="AI環境 版ちがい"
STATE_LINK="$WORKDIR/round_link"
for bad in round_p1a round_p2 round_p4; do
  want_reason_var="EXPECT_REASON_MAP_${bad}"
  want_reason="${!want_reason_var}"

  # 通常 → 縮退（AC-113′）: 最後に描いたフレームが理由行1行だけと完全一致し、
  # 直前の通常フレームのデータ行(例: 要件定義)が1行も残っていない。
  ln -sf "$WORKDIR/round_p6" "$STATE_LINK"
  CMUX_DOCK_SUPPLY_TASK="$STATE_LINK" CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_COLS=40 \
    bash "$WATCH" >"$WORKDIR/round_out.log" 2>/dev/null &
  DPID=$!
  sleep 1.5
  ln -sf "$WORKDIR/$bad" "$STATE_LINK"
  sleep 1.5
  kill -TERM "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
  LAST="$(extract_last_frame "$WORKDIR/round_out.log")"
  assert_eq "AC-113′: 通常→$bad の最後のフレームが理由行1行と完全一致" "$want_reason" "$LAST"

  # 縮退 → 通常（AC-96′）: 最後に描いたフレームがAC-131のリテラルと完全
  # 一致し、理由行が1行も残っていない。
  ln -sf "$WORKDIR/$bad" "$STATE_LINK"
  CMUX_DOCK_SUPPLY_TASK="$STATE_LINK" CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_COLS=40 \
    bash "$WATCH" >"$WORKDIR/round_out2.log" 2>/dev/null &
  DPID2=$!
  sleep 1.5
  ln -sf "$WORKDIR/round_p6" "$STATE_LINK"
  sleep 1.5
  kill -TERM "$DPID2" 2>/dev/null; wait_pid_bounded "$DPID2" 50
  LAST2="$(extract_last_frame "$WORKDIR/round_out2.log")"
  assert_eq "AC-96′: $bad→通常 の最後のフレームがAC-131のリテラルと完全一致" "$EXPECT_P6" "$LAST2"
done
sleep 1   # このブロックで作った6個のdaemonが完全に片付くのを待ってから次へ

echo "=== AC-25（v2移管）: 同一フレーム抑止（Task側） ==="
daemon_out_ac25="$WORKDIR/daemon_ac25.out"
: > "$daemon_out_ac25"
CMUX_DOCK_SUPPLY_TASK="$WORKDIR/p6" CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_COLS=40 \
  bash "$WATCH" > "$daemon_out_ac25" 2>&1 &
ac25_pid=$!
sleep 3.5
ac25_alive="$(kill -0 "$ac25_pid" 2>/dev/null && echo 1 || echo 0)"
kill -TERM "$ac25_pid" 2>/dev/null; wait_pid_bounded "$ac25_pid" 50
ac25_sync_count="$(python3 -c "
data = open('$daemon_out_ac25','rb').read()
print(data.count((chr(27)+'[?2026h').encode()))
")"
assert_eq "AC-25: 入力を変えず3.5秒でsync-beginが1回だけ" "1" "$ac25_sync_count"
assert_true "AC-25: 常駐は生存していた" "$ac25_alive"

echo "=== AC-27/AC-28/AC-29（v2移管）: 色付き/--once/--plain の先頭末尾・SGR・終了コード ==="
colored="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --once)"
python3 -c "
import sys
data = '''$colored'''
sys.exit(0 if data.startswith(chr(27)+'[?2026h') else 1)
" && ac27_start=1 || ac27_start=0
assert_true "AC-27: 先頭がESC[?2026h" "$ac27_start"
python3 -c "
import sys
data = '''$colored'''
sys.exit(0 if data.rstrip('\n').endswith(chr(27)+'[?2026l') else 1)
" && ac27_end=1 || ac27_end=0
assert_true "AC-27: 末尾がESC[?2026l" "$ac27_end"
sgr_x="$(printf '%s' "$colored" | grep -F '[x]' | grep -oE $'\x1b''\[[0-9;]*m' | head -n1)"
sgr_slash="$(printf '%s' "$colored" | grep -F '[/]' | grep -oE $'\x1b''\[[0-9;]*m' | head -n1)"
sgr_blank="$(printf '%s' "$colored" | grep -F '[ ]' | grep -oE $'\x1b''\[[0-9;]*m' | head -n1)"
assert_true "AC-28: [x]と[/]のSGRが異なる" "$([ "$sgr_x" != "$sgr_slash" ] && echo 1 || echo 0)"
assert_true "AC-28: [/]と[ ]のSGRが異なる" "$([ "$sgr_slash" != "$sgr_blank" ] && echo 1 || echo 0)"
assert_true "AC-28: [x]と[ ]のSGRが異なる" "$([ "$sgr_x" != "$sgr_blank" ] && echo 1 || echo 0)"
plain_out="$(CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --plain --once)"
python3 -c "
import sys
sys.exit(0 if chr(27) not in '''$plain_out''' else 1)
" && ac28_plain=1 || ac28_plain=0
assert_true "AC-28: --plainにESCが無い" "$ac28_plain"
CMUX_TASK_COLS=40 run_watch "$WORKDIR/p6" --once >/dev/null
assert_eq "AC-29: 終了コード0" "0" "$?"

echo "=== AC-30/AC-76（v2移管）: bash -n / bash --once ==="
/bin/bash -n "$WATCH"
assert_eq "AC-30: bash -n（cmux-task-watch.sh）成功" "0" "$?"
/bin/bash -n "$CMUX_DIR/lib-dock-view.sh"
assert_eq "AC-76: bash -n（lib-dock-view.sh）成功" "0" "$?"
/bin/bash -n "$CMUX_DIR/lib-supply-frame.sh"
assert_eq "AC-76: bash -n（lib-supply-frame.sh）成功" "0" "$?"
CMUX_DOCK_SUPPLY_TASK="$WORKDIR/p6" CMUX_TASK_COLS=40 /bin/bash "$WATCH" --once >/dev/null
assert_eq "AC-30: --once成功（/bin/bash直接実行）" "0" "$?"

echo "=== AC-46（v2移管）: OSC2タイトルが Task ==="
daemon_out_ac46="$WORKDIR/daemon_ac46.out"
: > "$daemon_out_ac46"
CMUX_DOCK_SUPPLY_TASK="$WORKDIR/p6" CMUX_TASK_COLS=40 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$WATCH" > "$daemon_out_ac46" 2>&1 &
ac46_pid=$!
sleep 1.2
kill -TERM "$ac46_pid" 2>/dev/null; wait_pid_bounded "$ac46_pid" 50
osc_data="$(cat "$daemon_out_ac46")"
assert_contains_local() { local desc="$1" hay="$2" needle="$3"
  case "$hay" in *"$needle"*) PASS=$(( PASS + 1 )) ;; *) FAIL=$(( FAIL + 1 )); echo "FAIL: $desc" ;; esac
}
assert_contains_local "AC-46: Task のOSC2列が含まれる" "$osc_data" "$(printf '\033]2;Task\007')"
python3 -c "
import sys
data = open('$daemon_out_ac46','rb').read()
sys.exit(0 if (chr(27)+']2;Next'+chr(7)).encode() not in data else 1)
" && ac46_no_bare=1 || ac46_no_bare=0
assert_true "AC-46: 素の Next 単独のOSC2は無い" "$ac46_no_bare"

echo "=== AC-80①（v2移管）: 内容が変わってから画面追随までのSLA・N-3 ==="
mk_stub_P6_task "$WORKDIR/ac80_before"
{
  _p6_task_lines
  _P6_TASK_LINES[3]="C${TAB}[ ]${TAB}新規タスク"
  _compose_frame "Task" "cmux-dock-frame/2" "${_P6_TASK_LINES[@]}" | _write_frame_stub "$WORKDIR/ac80_after"
}
AC80_LINK="$WORKDIR/ac80_link"
ln -sf "$WORKDIR/ac80_before" "$AC80_LINK"
CMUX_DOCK_SUPPLY_TASK="$AC80_LINK" CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_COLS=40 \
  bash "$WATCH" >"$WORKDIR/ac80_out.log" 2>/dev/null &
AC80_PID=$!
wait_for "$WORKDIR/ac80_out.log" "実装" 10
t0="$(now_mono)"
ln -sf "$WORKDIR/ac80_after" "$AC80_LINK"
wait_for "$WORKDIR/ac80_out.log" "新規タスク" 10
ac80_found=$?
t1="$(now_mono)"
kill -TERM "$AC80_PID" 2>/dev/null; wait_pid_bounded "$AC80_PID" 50
ac80_elapsed="$(python3 -c "print($t1 - $t0)")"
assert_true "AC-80①: 新しい内容(新規タスク)が見つかった" "$([ "$ac80_found" -eq 0 ] && echo 1 || echo 0)"
assert_true "AC-80①: SLA内（<2.0秒=FOCUS_INTERVAL(1)+1.0）" "$(python3 -c "print(1 if $ac80_elapsed < 2.0 else 0)")"

echo "=== DT-2④（v2移管）: cmuxハング(締切)解除後に通常表示へ回復・SLA ==="
mk_stub_P3 "$WORKDIR/dt2_hang" "$WORKDIR/dt2_hang.fp"
mk_stub_P6_task "$WORKDIR/dt2_recover"
DT2_LINK="$WORKDIR/dt2_link"
ln -sf "$WORKDIR/dt2_hang" "$DT2_LINK"
CMUX_DOCK_SUPPLY_TASK="$DT2_LINK" CMUX_DOCK_SUPPLY_TIMEOUT=1 CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_COLS=40 \
  bash "$WATCH" >"$WORKDIR/dt2_out.log" 2>/dev/null &
DT2_PID=$!
wait_for "$WORKDIR/dt2_out.log" "応答なし" 10
t0="$(now_mono)"
ln -sf "$WORKDIR/dt2_recover" "$DT2_LINK"
wait_for "$WORKDIR/dt2_out.log" "▶" 10
dt2_found=$?
t1="$(now_mono)"
kill -TERM "$DT2_PID" 2>/dev/null; wait_pid_bounded "$DT2_PID" 50
dt2_elapsed="$(python3 -c "print($t1 - $t0)")"
assert_true "DT-2④: hang解除後に通常表示へ回復" "$([ "$dt2_found" -eq 0 ] && echo 1 || echo 0)"
assert_true "DT-2④: 回復がSLA内（<2.0秒）" "$(python3 -c "print(1 if $dt2_elapsed < 2.0 else 0)")"

echo "=== AC-95: 締切1秒で4秒以内に応答なし・足跡PID全滅 ==="
mk_stub_P3 "$WORKDIR/p3" "$WORKDIR/p3.fp"
t0="$(now_mono)"
OUT="$(CMUX_DOCK_SUPPLY_TIMEOUT=1 run_watch "$WORKDIR/p3" --plain --once 2>"$WORKDIR/p3.stderr")"
t1="$(now_mono)"
elapsed="$(python3 -c "print($t1 - $t0)")"
assert_eq "AC-95: P-3はAI環境 応答なし" "AI環境 応答なし" "$OUT"
assert_true "AC-95: 4秒以内" "$(python3 -c "print(1 if $elapsed <= 4.0 else 0)")"
# limiterがプロセスグループを終了させる締切経路でも、bashのjob-control通知
# (Terminated: 15 ...)が常駐stderrへ漏れないことを固定する（検証1巡目#11の
# 回帰・検証2巡目#25③）。disownを外すとここでFAILになる。
assert_eq "AC-95: 締切経路の常駐stderrが0バイト(検証1巡目#11の回帰)" "0" \
  "$(wc -c < "$WORKDIR/p3.stderr" | tr -d ' ')"

echo "=== AC-123: 終了経路の全5セル（自然終了・非0終了・締切・TERM・HUP） ==="
# 足跡ファイルの3種別(main/child/watchdog)が揃うまで待つ（0.1秒間隔・上限10秒
# ＝AC-123の申し送り）。空集合や本体だけで合格させない。
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
fp_all_dead() {  # $1=footprints file。個々のPIDだけでなくPGIDも見る。
  local fp="$1" alive=0 pid pgid
  while IFS="$(printf '\t')" read -r _ pid pgid; do
    kill -0 "$pid" 2>/dev/null && alive=$(( alive + 1 ))
    [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null && alive=$(( alive + 1 ))
  done < "$fp"
  echo "$alive"
}
esc_count() {  # $1=ログファイル $2=探すESCシーケンス(python正規表現の断片)
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
# model)だけを対象に前後比較する（AC-123④・検証2巡目 #22・DT-15で隔離
# 済みのTMPDIR配下を見る）。
tmp_snapshot() {
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cmux-supply-*' 2>/dev/null | sort
}

# --- 3セル: 常駐が生き続ける経路（自然終了・非0終了・締切） ---
for spec in "natural:mk_stub_P26a" "nonzero:mk_stub_P26b" "timeout:mk_stub_P3"; do
  name="${spec%%:*}" fn="${spec#*:}"
  fp="$WORKDIR/$name.fp"
  supply="$WORKDIR/${name}_supply"
  if [ "$name" = "timeout" ]; then
    "$fn" "$supply" "$fp"
  else
    "$fn" "$supply" "$fp" Task
  fi
  LOG="$WORKDIR/${name}_daemon.log"
  BEFORE_TMP="$(tmp_snapshot)"
  CMUX_DOCK_SUPPLY_TASK="$supply" CMUX_DOCK_SUPPLY_TIMEOUT=1 CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_COLS=40 \
    bash "$WATCH" >"$LOG" 2>/dev/null &
  DPID=$!
  if ! wait_fp3 "$fp" 100; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: AC-123($name): 足跡の3種別(main/child/watchdog)が揃わない"
    kill -TERM "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
    continue
  fi
  # 常駐が次のtickへ進む前にPGID終了が確定するのを少し待つ。
  sleep 1.5
  DAEMON_ALIVE="$(kill -0 "$DPID" 2>/dev/null && echo 1 || echo 0)"
  assert_eq "AC-123($name): 常駐は生き続ける" "1" "$DAEMON_ALIVE"
  assert_eq "AC-123($name): 足跡の全PID・全PGIDが死んでいる" "0" "$(fp_all_dead "$fp")"
  ESC25H_N="$(esc_count "$LOG" "$ESC25H")"
  assert_eq "AC-123($name): ESC[?25hは出ない(常駐は生存)" "0" "$ESC25H_N"
  ESC2026L_N="$(esc_count "$LOG" "$ESC2026L")"
  assert_true "AC-123($name): 描画を開始したフレームにESC[?2026lがある" \
    "$([ "$ESC2026L_N" -ge 1 ] && echo 1 || echo 0)"
  kill -TERM "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
  # 次のセルへ進む前に、この足跡のPID/PGIDが確実に無くなるまで少し待つ
  # （プロセス数が積み上がった状態で次のdaemonを起動しない＝安定性のため）。
  w=0
  while [ "$(fp_all_dead "$fp")" != "0" ] && [ "$w" -lt 30 ]; do sleep 0.1; w=$(( w + 1 )); done
  AFTER_TMP="$(tmp_snapshot)"
  assert_eq "AC-123($name): TMPDIRの一時物集合が実行前に戻っている" "$BEFORE_TMP" "$AFTER_TMP"
done

# --- 2セル: 常駐自身が終わる経路（TERM・HUP） ---
for sig in TERM HUP; do
  name="sig_$sig"
  fp="$WORKDIR/${name}.fp"
  supply="$WORKDIR/${name}_supply"
  mk_stub_P3 "$supply" "$fp"   # ハングし続ける供給側。締切は長く取り、
                                # シグナル自体で常駐が終わることを見る。
  LOG="$WORKDIR/${name}_daemon.log"
  BEFORE_TMP="$(tmp_snapshot)"
  CMUX_DOCK_SUPPLY_TASK="$supply" CMUX_DOCK_SUPPLY_TIMEOUT=30 CMUX_TASK_COLS=40 \
    bash "$WATCH" >"$LOG" 2>/dev/null &
  DPID=$!
  if ! wait_fp3 "$fp" 100; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: AC-123($sig): 足跡の3種別(main/child/watchdog)が揃わない"
    kill "-$sig" "$DPID" 2>/dev/null; wait_pid_bounded "$DPID" 50
    continue
  fi
  kill "-$sig" "$DPID" 2>/dev/null
  wait_pid_bounded "$DPID" 50
  sleep 0.3
  DAEMON_ALIVE="$(kill -0 "$DPID" 2>/dev/null && echo 1 || echo 0)"
  assert_eq "AC-123($sig): 常駐自身が終了する" "0" "$DAEMON_ALIVE"
  assert_eq "AC-123($sig): 足跡の全PID・全PGIDが死んでいる" "0" "$(fp_all_dead "$fp")"
  ESC25H_N="$(esc_count "$LOG" "$ESC25H")"
  assert_eq "AC-123($sig): ESC[?25hがちょうど1回出る" "1" "$ESC25H_N"
  w=0
  while [ "$(fp_all_dead "$fp")" != "0" ] && [ "$w" -lt 30 ]; do sleep 0.1; w=$(( w + 1 )); done
  AFTER_TMP="$(tmp_snapshot)"
  assert_eq "AC-123($sig): TMPDIRの一時物集合が実行前に戻っている" "$BEFORE_TMP" "$AFTER_TMP"
done

echo "=== AC-116: TMPDIR異常でも常駐は生存し\$HOME配下に新規ファイルが無い(RT) ==="
mk_stub_P6_task "$WORKDIR/p6_tmpdir"
BEFORE_HOME="$(find "$HOME" -maxdepth 1 2>/dev/null | sort)"
OLD_TMPDIR="${TMPDIR:-}"
export TMPDIR="$WORKDIR/no-such-tmpdir"
OUT_TD="$(CMUX_DOCK_SUPPLY_TASK="$WORKDIR/p6_tmpdir" bash "$WATCH" --plain --once)"
export TMPDIR="$OLD_TMPDIR"
assert_eq "AC-116(RT): TMPDIR不在はAI環境 応答なし" "AI環境 応答なし" "$OUT_TD"
AFTER_HOME="$(find "$HOME" -maxdepth 1 2>/dev/null | sort)"
assert_eq "AC-116(RT): \$HOME直下の一覧が不変" "$BEFORE_HOME" "$AFTER_HOME"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
