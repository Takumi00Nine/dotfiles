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

echo "=== sanitize_str（既存 cmux-next-watch.sh と同一挙動） ==="
ESC=$'\x1b'
TAB=$'\x09'
DEL=$'\x7f'
OUT_ESC="$(sanitize_str "a${ESC}b")"
assert_true "ESC を含む文字列に真の ESC バイトが残らない" "$(printf '%s' "$OUT_ESC" | python3 -c 'import sys; d=sys.stdin.read(); print(1 if chr(27) not in d else 0)')"
assert_eq "ESC は空白に置換される" "a b" "$OUT_ESC"
OUT_TAB="$(sanitize_str "a${TAB}b")"
assert_eq "TAB は空白に置換される" "a b" "$OUT_TAB"
OUT_DEL="$(sanitize_str "a${DEL}b")"
assert_eq "DEL(0x7f) は空白に置換される" "a b" "$OUT_DEL"

echo "=== sanitize_lines（stdin/stdout・NUL/ESC/TAB/CSI を空白化・行構造を保つ） ==="
# NUL は bash 変数に保持できず代入時点で切り詰まる（$'\x00' を変数へ入れて
# 文字列連結する形は NUL が消えたまま「成立していないテスト」になる＝
# verifier 実装レビュー1巡目 #7 指摘）。printf のフォーマット文字列に
# \0（NUL）・\033（ESC・CSIの導入バイト）を直接埋め込み、変数を経由せず
# ファイルへ書いてから sanitize_lines に食わせる。
SANITIZE_LINES_IN="$WORKDIR/sanitize_lines_input.bin"
printf 'line1\0NUL\033ESC\tTAB\033[31mCSI\nline2\n' > "$SANITIZE_LINES_IN"
OUT_LINES="$(sanitize_lines < "$SANITIZE_LINES_IN")"
RC_LINES=$?
assert_eq "sanitize_lines は正常終了で終了コード0" "0" "$RC_LINES"
NUL_GONE="$(printf '%s' "$OUT_LINES" | python3 -c 'import sys; d=sys.stdin.read(); print(1 if chr(0) not in d else 0)')"
assert_true "出力にU+0000が残らない" "$NUL_GONE"
ESC_GONE="$(printf '%s' "$OUT_LINES" | python3 -c 'import sys; d=sys.stdin.read(); print(1 if chr(27) not in d else 0)')"
assert_true "出力にESCが残らない" "$ESC_GONE"
TAB_GONE="$(printf '%s' "$OUT_LINES" | python3 -c 'import sys; d=sys.stdin.read(); print(1 if chr(9) not in d else 0)')"
assert_true "出力にTABが残らない" "$TAB_GONE"
LINE_COUNT="$(printf '%s\n' "$OUT_LINES" | wc -l | tr -d ' ')"
assert_eq "2行入力は2行のまま（行構造を保つ）" "2" "$LINE_COUNT"
assert_true "各行にNUL/ESC/TAB/CSI置換後の目印テキストが残る（脱落ではなく空白化）" "$(printf '%s' "$OUT_LINES" | grep -qF "NUL" && printf '%s' "$OUT_LINES" | grep -qF "line2" && echo 1 || echo 0)"

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

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
