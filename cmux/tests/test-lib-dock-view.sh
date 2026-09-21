#!/bin/bash
# lib-dock-view.sh のユニットテスト。実端末・実Vault・実cmuxに依存しない。
#
# 実行方法: bash tests/test-lib-dock-view.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib-dock-view.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-lib-dock-view.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

[ -r "$LIB" ] || { echo "FATAL: lib が見つかりません: $LIB" >&2; exit 1; }
. "$LIB"

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
  if [ "$cond" = "1" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

assert_false() {
  local desc="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

echo "=== disp_width（§6.2 の範囲表・既存 cmux-next-watch.sh と同一） ==="
assert_eq "ASCII 3文字は3セル" "3" "$(disp_width "abc")"
assert_eq "空文字は0セル" "0" "$(disp_width "")"
assert_eq "CJK 3文字（あいう）は6セル" "6" "$(disp_width "あいう")"
assert_eq "ASCII+CJK混在（ab漢字）は6セル" "6" "$(disp_width "ab漢字")"
assert_eq "・（U+30FB）は2セル（範囲表どおり）" "2" "$(disp_width "・")"
assert_eq "▶ は1セル（範囲表どおり・実端末との既知の乖離あり＝§6.2）" "1" "$(disp_width "▶")"
assert_eq "✅ は1セル（範囲表どおり）" "1" "$(disp_width "✅")"
assert_eq "├ は1セル" "1" "$(disp_width "├")"
assert_eq "└ は1セル" "1" "$(disp_width "└")"
assert_eq "… は1セル" "1" "$(disp_width "…")"

echo "=== truncate_disp（w<=0 は空文字・w>=1 は末尾…で w セル以内） ==="
assert_eq "w=0 は空文字を返す（現行の最低1丸めをやめた新契約）" "" "$(truncate_disp "hello" 0)"
assert_eq "w が負でも空文字を返す" "" "$(truncate_disp "hello" -5)"
assert_eq "w が空文字でも空文字を返す" "" "$(truncate_disp "hello" "")"
assert_eq "w が非数字でも空文字扱い（w<=0 相当）" "" "$(truncate_disp "hello" "abc")"
assert_eq "収まる場合はそのまま" "hello" "$(truncate_disp "hello" 10)"
assert_eq "ちょうど収まる境界（幅=文字数）はそのまま" "hello" "$(truncate_disp "hello" 5)"
assert_eq "超過時は末尾…でw以内（5→4）" "hell…" "$(truncate_disp "hello world" 5)"
assert_eq "truncate_dispの結果の表示幅がwを超えない" "1" "$([ "$(disp_width "$(truncate_disp "hello world" 5)")" -le 5 ] && echo 1 || echo 0)"
assert_eq "CJKを含む文字列の切り詰め（あいうえお→5セル）" "あい…" "$(truncate_disp "あいうえお" 5)"
assert_eq "w=1でCJK超過は…のみ（1セル）" "…" "$(truncate_disp "あいうえお" 1)"

echo "=== truncate_plain（n<=0は空文字・省略記号なし） ==="
assert_eq "n=0は空文字" "" "$(truncate_plain "hello" 0)"
assert_eq "nが負でも空文字" "" "$(truncate_plain "hello" -3)"
assert_eq "nが空文字でも空文字" "" "$(truncate_plain "hello" "")"
assert_eq "収まる場合はそのまま" "hello" "$(truncate_plain "hello" 10)"
assert_eq "コードポイント数で切り詰め・省略記号なし" "hel" "$(truncate_plain "hello" 3)"
assert_eq "CJKはコードポイント単位（文字数）で切り詰め" "あいう" "$(truncate_plain "あいうえお" 3)"

echo "=== term_cols / term_rows（正整数の上書きのみ有効・0/空/非数字は上書き無し扱い） ==="
assert_eq "正整数の上書きはそのまま使う" "80" "$(term_cols "80")"
assert_eq "0は上書き無し扱い（stty/既定40へフォールバック）" "1" "$([ -n "$(term_cols "0")" ] && echo 1 || echo 0)"
assert_eq "空は上書き無し扱い（stty/既定40へフォールバック）" "1" "$([ -n "$(term_cols "")" ] && echo 1 || echo 0)"
assert_eq "非数字は上書き無し扱い（stty/既定40へフォールバック）" "1" "$([ -n "$(term_cols "abc")" ] && echo 1 || echo 0)"
assert_eq "term_rowsの正整数上書きはそのまま使う" "24" "$(term_rows "24")"
assert_eq "term_rowsの0は上書き無し扱い" "1" "$([ -n "$(term_rows "0")" ] && echo 1 || echo 0)"

echo "=== term_cols の CMUX_DOCK_MAX_COLS 上限（上書き値は対象外・stty実測値だけ丸める） ==="
# _stty_cols を関数上書きで差し替え、実 tty の有無に関わらず任意の桁数を
# 模擬する（stty コマンド自体の上書きは </dev/tty のリダイレクトが先に
# 評価されて失敗するため使えない＝lib-dock-view.sh 側のコメントに実測済み
# と明記）。このブロックの外側では元に戻す（以降のテストへ影響させない）。
_stty_cols() { printf '148'; }
assert_eq "上書きありは上限を無視する（stty148桁でも80のまま）" "80" "$(term_cols "80")"
assert_eq "stty桁数(148)が既定60を超えるとき既定60へ丸める" "60" "$(CMUX_DOCK_MAX_COLS= term_cols "")"
assert_eq "CMUX_DOCK_MAX_COLS=80指定時、stty桁数(148)は80へ丸める" "80" "$(CMUX_DOCK_MAX_COLS=80 term_cols "")"
assert_eq "CMUX_DOCK_MAX_COLSが0なら既定60へ丸める" "60" "$(CMUX_DOCK_MAX_COLS=0 term_cols "")"
assert_eq "CMUX_DOCK_MAX_COLSが非数字なら既定60へ丸める" "60" "$(CMUX_DOCK_MAX_COLS=abc term_cols "")"

_stty_cols() { printf '50'; }
assert_eq "stty桁数(50)が既定60以下ならそのまま（丸めない）" "50" "$(CMUX_DOCK_MAX_COLS= term_cols "")"

_stty_cols() { printf '70'; }
assert_eq "CMUX_DOCK_MAX_COLS=80指定時、stty桁数(70)が上限未満ならそのまま" "70" "$(CMUX_DOCK_MAX_COLS=80 term_cols "")"

# v6 AC-152「幅の上限の規則」（requirements-v6.md FR-110・§11）＝端末取得 37・
# 上限 36 → 描画幅 36。明示の上書き 37 は上限の対象外（Project 枠の pty 37 桁・
# 可視幅 36 の実機事象 E-v6-5 と同じ値）。
_stty_cols() { printf '37'; }
assert_eq "v6_ac152_min_rule: 端末取得37・上限36 → 36" "36" "$(CMUX_DOCK_MAX_COLS=36 term_cols "")"
assert_eq "v6_ac152_min_rule: 明示の上書き37は上限36の対象外 → 37" "37" "$(CMUX_DOCK_MAX_COLS=36 term_cols "37")"

# unset -f だと元の定義が失われたままになる（このシェルでの再定義に上書き
# の巻き戻し履歴が無いため）。lib を再 source して原本の _stty_cols へ戻す。
. "$LIB"

# stty が取れない環境（テスト実行はパイプ経由が通常なので /dev/tty が無い）
# では、term_cols は既定40・term_rows は既定0（クランプ無効）へ落ちることを
# 確認する（実端末依存の分岐なので確定的に検査できるのはこの既定値だけ）。
COLS_NO_OVERRIDE="$(term_cols "" </dev/null 2>/dev/null)"
ROWS_NO_OVERRIDE="$(term_rows "" </dev/null 2>/dev/null)"
if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
  assert_eq "tty が無い環境では term_cols は既定40" "40" "$COLS_NO_OVERRIDE"
  assert_eq "tty が無い環境では term_rows は既定0" "0" "$ROWS_NO_OVERRIDE"
else
  echo "SKIP: このホストでは /dev/tty が使えるため、stty失敗時のフォールバック既定値は確定検査できません（上書き経路のみ検査済み）"
fi

echo "=== is_number（既存と同一） ==="
assert_true "数字だけはtrue" "$(is_number "123" && echo 1 || echo 0)"
assert_false "空文字はfalse" "$(is_number "" && echo 1 || echo 0)"
assert_false "非数字を含むとfalse" "$(is_number "12a" && echo 1 || echo 0)"
assert_false "負号を含むとfalse（非負整数のみ）" "$(is_number "-1" && echo 1 || echo 0)"

echo "=== sanitize_interval（空・非数字・0は既定へ・それ以外はそのまま） ==="
assert_eq "空は既定値" "60" "$(sanitize_interval "" 60)"
assert_eq "0は既定値" "60" "$(sanitize_interval 0 60)"
assert_eq "非数字は既定値" "60" "$(sanitize_interval abc 60)"
assert_eq "正整数はそのまま" "30" "$(sanitize_interval 30 60)"

echo "=== run_with_timeout（§4.3 の3性質・DT-2 相当） ==="
assert_eq "正常終了するコマンドの終了コードをそのまま返す" "0" "$(run_with_timeout 5 true; echo $?)"
assert_eq "失敗するコマンドの終了コードをそのまま返す" "3" "$(run_with_timeout 5 bash -c 'exit 3'; echo $?)"

t0=$(date +%s)
run_with_timeout 1 sleep 30
rc=$?
t1=$(date +%s)
elapsed=$(( t1 - t0 ))
assert_true "打ち切りが効く: タイムアウト秒(1)+猶予(1)に近い時間で戻る（30秒待たない）" "$([ "$elapsed" -le 4 ] && echo 1 || echo 0)"
assert_true "打ち切り時は非0終了" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# コマンド置換の中で呼んでも遅延しないこと（ウォッチャーが標準出力のfdを
# 握り続けない＝設計 §4.3「打ち切りが効く」の性質）。
t0=$(date +%s)
out="$(run_with_timeout 1 sleep 30)"
rc=$?
t1=$(date +%s)
elapsed=$(( t1 - t0 ))
assert_true "コマンド置換の中でも遅延しない" "$([ "$elapsed" -le 4 ] && echo 1 || echo 0)"
assert_eq "コマンド置換内の出力は空（打ち切りなので）" "" "$out"

# 常駐が死なない: run_with_timeout 実行後もテストプロセス自身が生存する
# （呼び出し元を巻き込まずにプロセスグループだけを落とす）。
run_with_timeout 1 sleep 30 >/dev/null 2>&1
assert_true "常駐（呼び出し元プロセス）が死なない" "$(kill -0 $$ 2>/dev/null && echo 1 || echo 0)"

# 子孫が残らない: ハングするコマンドが生成した孫プロセスがグループごと
# 落ちて孤児として残らないこと（足跡方式・DT-2 と同じ検査手法）。
HANG_PIDS="$WORKDIR/hang_pids"
: > "$HANG_PIDS"
run_hang() {
  echo "$$" >> "$HANG_PIDS"
  sleep 60 &
  local child=$!
  echo "$child" >> "$HANG_PIDS"
  wait "$child"
}
run_with_timeout 1 bash -c '
  echo "$$" >> "'"$HANG_PIDS"'"
  sleep 60 &
  child=$!
  echo "$child" >> "'"$HANG_PIDS"'"
  wait "$child"
' >/dev/null 2>&1
sleep 1
orphan_count=0
if [ -s "$HANG_PIDS" ]; then
  while read -r pid; do
    kill -0 "$pid" 2>/dev/null && orphan_count=$(( orphan_count + 1 ))
  done < "$HANG_PIDS"
fi
assert_eq "子孫が残らない（記録した全PIDがkill -0に失敗する＝孤児ゼロ）" "0" "$orphan_count"

echo "=== run_with_timeout補強: TERMを無視する子孫がいてもコマンド置換がブロックされず子孫も残らない（cmux/lib-model-view.sh側の同型回帰の写し・MAJOR-2追随） ==="
# TERM無視の子孫（trap '' TERM）が標準出力のパイプ書き込み端を握ったまま
# 残ると、wait後にKILLで掃除しない実装ではcmd_pid自体がTERMで終了しても
# 呼び出し元の command substitution（$(...)）がEOF待ちで子孫のsleep終了
# （60秒後）までブロックする＝上の「子孫が残らない」検査（TERM無視なし）
# では検出できない実害。elapsed（上の「打ち切りが効く」と同じ検査）が
# その実害を直接捉える。
TERM_IGNORE_PID_FILE="$WORKDIR/term_ignore_grandchild_pid"
rm -f "$TERM_IGNORE_PID_FILE"
t0=$(date +%s)
out_term="$(run_with_timeout 1 bash -c '
  ( trap "" TERM; sleep 60 ) &
  echo "$!" >> "'"$TERM_IGNORE_PID_FILE"'"
  sleep 60
')"
t1=$(date +%s)
elapsed_term=$(( t1 - t0 ))
assert_true "TERM無視の子孫がいてもコマンド置換が4秒未満で戻る（fd待ちでブロックされない）" \
  "$([ "$elapsed_term" -le 4 ] && echo 1 || echo 0)"
assert_eq "コマンド置換内の出力は空（打ち切りなので）" "" "$out_term"
sleep 1.5
grandchild_pid="$(cat "$TERM_IGNORE_PID_FILE" 2>/dev/null)"
assert_true "子孫PIDが記録されている（検査自体が空振りでない）" \
  "$([ -n "$grandchild_pid" ] && echo 1 || echo 0)"
if [ -n "$grandchild_pid" ] && kill -0 "$grandchild_pid" 2>/dev/null; then
  kill -9 "$grandchild_pid" 2>/dev/null
  assert_eq "TERM無視の子孫がタイムアウト後に生存しない（elapsedが主検査・本assertは補助）" "生存しない" "生存した"
else
  assert_eq "TERM無視の子孫がタイムアウト後に生存しない（elapsedが主検査・本assertは補助）" "生存しない" "生存しない"
fi

echo "=== 縮小の確認（§31.5＝sanitize_str・sanitize_linesは描画側から削除済み） ==="
assert_false "sanitize_str は削除済み（未定義）" "$(type sanitize_str >/dev/null 2>&1 && echo 1 || echo 0)"
assert_false "sanitize_lines は削除済み（未定義）" "$(type sanitize_lines >/dev/null 2>&1 && echo 1 || echo 0)"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
