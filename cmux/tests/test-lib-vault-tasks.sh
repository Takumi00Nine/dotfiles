#!/bin/bash
# lib-vault-tasks.sh のユニットテスト。実端末・実Vault・実cmuxに依存しない。
# fixture は要件書 requirements.md の V群（Vault ノート 17件）の記法を、
# lib 関数（fm_extract・fm_field・parse_tasks・read_note）が検査できる
# 粒度で個別に再現する（表示・切り詰め・高さクランプは cmux-task-watch.sh
# 側＝担当Bの受入条件であり、本ファイルの対象外）。
#
# 実行方法: bash tests/test-lib-vault-tasks.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DOCK="$SCRIPT_DIR/../lib-dock-view.sh"
LIB_TASKS="$SCRIPT_DIR/../lib-vault-tasks.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-lib-vault-tasks.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

[ -r "$LIB_DOCK" ]  || { echo "FATAL: lib が見つかりません: $LIB_DOCK" >&2; exit 1; }
[ -r "$LIB_TASKS" ] || { echo "FATAL: lib が見つかりません: $LIB_TASKS" >&2; exit 1; }
# read_note は sanitize_lines（lib-dock-view.sh 側）に依存する（設計 §1.4）。
. "$LIB_DOCK"
. "$LIB_TASKS"

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

TSV=$'\t'

echo "=== fm_extract（stdin版・frontmatter不正の判定） ==="
FM_OK="$(printf -- '---\nkey: val\nother: 1\n---\nbody\n' | fm_extract)"
assert_eq "正常なfrontmatterを抽出する" "$(printf 'key: val\nother: 1')" "$FM_OK"
printf -- '---\nkey: val\n---\n' | fm_extract >/dev/null
assert_eq "正常なfrontmatterは終了コード0" "0" "$?"
printf '本文のみ（1行目が---でない）\n' | fm_extract >/dev/null 2>&1
assert_true "1行目が---でないと終了コード非0" "$([ $? -ne 0 ] && echo 1 || echo 0)"
{ printf -- '---\n'; for i in $(seq 1 65); do printf 'line%d\n' "$i"; done; } | fm_extract >/dev/null 2>&1
assert_true "60行以内に閉じ---が無いと終了コード非0" "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "=== fm_field（既存と同一挙動） ==="
BLOCK="$(printf 'status: active\nnext: "quoted value"\nupdated: 2026-09-01\nsingle: '"'"'q2'"'"'')"
assert_eq "無引用の値を取得" "active" "$(fm_field "$BLOCK" status)"
assert_eq "二重引用符を剥がす" "quoted value" "$(fm_field "$BLOCK" next)"
assert_eq "単一引用符を剥がす" "q2" "$(fm_field "$BLOCK" single)"
assert_eq "存在しないキーは空文字" "" "$(fm_field "$BLOCK" nosuch)"

echo "=== parse_tasks: V-1 相当（3版・完了/進行中混在/未着手） ==="
V1_IN="## Tasks
### v1
- [x] task1
- [x] task2
- [x] task3
### v2
- [x] done
- [/] doing
- [ ] todo
### v3
- [ ] t1
- [ ] t2
- [ ] t3
- [ ] t4"
V1_OUT="$(printf '%s\n' "$V1_IN" | parse_tasks)"
V1_EXPECTED="V${TSV}v1
T${TSV}x${TSV}task1
T${TSV}x${TSV}task2
T${TSV}x${TSV}task3
V${TSV}v2
T${TSV}x${TSV}done
T${TSV}/${TSV}doing
T${TSV} ${TSV}todo
V${TSV}v3
T${TSV} ${TSV}t1
T${TSV} ${TSV}t2
T${TSV} ${TSV}t3
T${TSV} ${TSV}t4"
assert_eq "V-1相当: TSVがリテラルで一致する" "$V1_EXPECTED" "$V1_OUT"

echo "=== parse_tasks: V-2 相当（Tasks節が無い） ==="
V2_OUT="$(printf '%s\n' "# note
## Other
- [ ] not tasks section" | parse_tasks)"
assert_eq "Tasks節が無ければ出力は空" "" "$V2_OUT"

echo "=== parse_tasks: V-3 相当（版の見出しが無く直下にチェックリスト） ==="
V3_OUT="$(printf '%s\n' "## Tasks
- [ ] no version heading
- [x] still no version" | parse_tasks)"
assert_eq "版の見出しより前のチェックリストは数えない" "" "$V3_OUT"

echo "=== parse_tasks: V-4 相当（2版とも0件） ==="
V4_OUT="$(printf '%s\n' "## Tasks
### v1
### v2" | parse_tasks)"
V4_EXPECTED="V${TSV}v1
V${TSV}v2"
assert_eq "0件の版も版行として出る（タスク行は無い）" "$V4_EXPECTED" "$V4_OUT"

echo "=== parse_tasks: V-5 相当（3版中1版だけ0件） ==="
V5_OUT="$(printf '%s\n' "## Tasks
### v1
- [x] a
### v2
### v3
- [ ] b" | parse_tasks)"
V5_EXPECTED="V${TSV}v1
T${TSV}x${TSV}a
V${TSV}v2
V${TSV}v3
T${TSV} ${TSV}b"
assert_eq "0件の版を挟んでも他の版のタスクは正しく数える" "$V5_EXPECTED" "$V5_OUT"

echo "=== parse_tasks: V-8 相当（trim後に空のタスク本文） ==="
V8_OUT="$(printf '%s\n' "## Tasks
### v1
- [ ]
- [x]   " | parse_tasks)"
V8_EXPECTED="V${TSV}v1
T${TSV} ${TSV}
T${TSV}x${TSV}"
assert_eq "本文なし・空白のみの本文はtrimで空文字になる（空タスクの判定は呼び出し側の仕事）" "$V8_EXPECTED" "$V8_OUT"

echo "=== parse_tasks: V-10 相当（全版完了） ==="
V10_OUT="$(printf '%s\n' "## Tasks
### v1
- [x] a
- [x] b
### v2
- [x] c" | parse_tasks)"
V10_EXPECTED="V${TSV}v1
T${TSV}x${TSV}a
T${TSV}x${TSV}b
V${TSV}v2
T${TSV}x${TSV}c"
assert_eq "全版完了でも通常どおりパースされる（判定は呼び出し側）" "$V10_EXPECTED" "$V10_OUT"

echo "=== parse_tasks: V-11 相当（/ が無く未完の版が2つ） ==="
V11_OUT="$(printf '%s\n' "## Tasks
### v1
- [ ] a
- [x] b
### v2
- [ ] c" | parse_tasks)"
assert_true "V-11相当: 状態記号に / が1つも含まれない" "$(printf '%s\n' "$V11_OUT" | grep -qF "${TSV}/${TSV}" && echo 0 || echo 1)"
V11_EXPECTED="V${TSV}v1
T${TSV} ${TSV}a
T${TSV}x${TSV}b
V${TSV}v2
T${TSV} ${TSV}c"
assert_eq "V-11相当: TSVが一致する" "$V11_EXPECTED" "$V11_OUT"

echo "=== parse_tasks: V-13 相当（同じ版名が2つ・記載順に別版） ==="
V13_OUT="$(printf '%s\n' "## Tasks
### dup
- [x] a
### dup
- [ ] b" | parse_tasks)"
V13_EXPECTED="V${TSV}dup
T${TSV}x${TSV}a
V${TSV}dup
T${TSV} ${TSV}b"
assert_eq "同名の版が記載順に2つの別版として出る" "$V13_EXPECTED" "$V13_OUT"

echo "=== parse_tasks: V-14 相当（1版に60件のタスク） ==="
V14_BODY="## Tasks
### v1"
for i in $(seq 1 60); do
  V14_BODY="$V14_BODY
- [ ] task${i}"
done
V14_OUT="$(printf '%s\n' "$V14_BODY" | parse_tasks)"
V14_T_COUNT="$(printf '%s\n' "$V14_OUT" | grep -c "^T${TSV}")"
assert_eq "60件のタスクが60行のTとして出る" "60" "$V14_T_COUNT"
assert_true "記載順が保たれる（1件目がtask1・60件目がtask60）" "$(printf '%s\n' "$V14_OUT" | grep -q "task1\$" && printf '%s\n' "$V14_OUT" | tail -1 | grep -q "task60\$" && echo 1 || echo 0)"

echo "=== parse_tasks: V-15 相当（1版12件・記載順1-5=x, 6-10=空, 11=/, 12=空） ==="
V15_BODY="## Tasks
### v2"
for i in 1 2 3 4 5; do V15_BODY="$V15_BODY
- [x] c${i}"; done
for i in 6 7 8 9 10; do V15_BODY="$V15_BODY
- [ ] c${i}"; done
V15_BODY="$V15_BODY
- [/] c11
- [ ] c12"
V15_OUT="$(printf '%s\n' "$V15_BODY" | parse_tasks)"
V15_STATES="$(printf '%s\n' "$V15_OUT" | awk -F"$TSV" '$1=="T"{print $2}' | tr -d '\n')"
assert_eq "12件の状態が記載順どおり（xxxxx     / ）" "xxxxx     / " "$V15_STATES"
V15_BODIES="$(printf '%s\n' "$V15_OUT" | awk -F"$TSV" '$1=="T"{print $3}' | paste -sd, -)"
assert_eq "本文の記載順も保たれる" "c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12" "$V15_BODIES"

echo "=== parse_tasks: Tasks節の終了判定（別のh1/h2見出しでTasks節を打ち切る） ==="
END_H1_OUT="$(printf '%s\n' "## Tasks
### v1
- [x] a
# 別セクション(h1)
### v2
- [ ] b" | parse_tasks)"
assert_true "h1見出しでTasks節が終わり、それ以降の版・タスクは出ない" "$([ "$(printf '%s\n' "$END_H1_OUT" | grep -c '^V')" = "1" ] && echo 1 || echo 0)"
END_H2_OUT="$(printf '%s\n' "## Tasks
### v1
- [x] a
## 別セクション(h2)
### v2
- [ ] b" | parse_tasks)"
assert_true "別のh2見出しでTasks節が終わり、それ以降の版・タスクは出ない" "$([ "$(printf '%s\n' "$END_H2_OUT" | grep -c '^V')" = "1" ] && echo 1 || echo 0)"

echo "=== parse_tasks: 記法として数えない行（FR-2・インデント・大文字） ==="
NOTCOUNT_OUT="$(printf '%s\n' "## Tasks
### v1
  - [ ] indented (数えない)
- [X] uppercase (数えない)
- [-] invalid state (数えない)
-[ ] no space after dash (数えない)
- [x] valid" | parse_tasks)"
NOTCOUNT_T_COUNT="$(printf '%s\n' "$NOTCOUNT_OUT" | grep -c "^T${TSV}")"
assert_eq "規定外の記法は1件も数えず、正しい1件だけが残る" "1" "$NOTCOUNT_T_COUNT"
assert_true "残った1件の本文がvalidである" "$(printf '%s\n' "$NOTCOUNT_OUT" | grep -qF "valid" && echo 1 || echo 0)"

echo "=== parse_tasks: V-7 相当（500文字超のASCII本文をそのまま保持・切り詰めない） ==="
LONG_BODY="$(python3 -c 'print("a"*520)')"
V7_OUT="$(printf '%s\n' "## Tasks
### v1
- [ ] ${LONG_BODY}" | parse_tasks)"
V7_BODY_OUT="$(printf '%s\n' "$V7_OUT" | awk -F"$TSV" '$1=="T"{print $3}')"
assert_eq "本文は切り詰めずそのまま出す（切り詰めは表示層の仕事）" "$LONG_BODY" "$V7_BODY_OUT"

echo "=== parse_tasks: 常に終了コード0 ==="
printf '%s\n' "## Tasks
### v1
- [x] a" | parse_tasks >/dev/null
assert_eq "正常系で終了コード0" "0" "$?"
printf '%s\n' "no tasks section at all" | parse_tasks >/dev/null
assert_eq "Tasks節が無くても終了コード0" "0" "$?"

echo "=== read_note: 公開入口の正常系（frontmatter+Tasks節） ==="
mkdir -p "$WORKDIR/vault/Projects"
cat > "$WORKDIR/vault/Projects/ok.md" <<'NOTE'
---
date: 2026-01-01
status: active
---
# ok
## Tasks
### v1
- [x] done task
- [ ] todo task
NOTE
READ_OUT="$(read_note "$WORKDIR/vault/Projects/ok.md")"
READ_RC=$?
assert_eq "正常系は終了コード0" "0" "$READ_RC"
READ_EXPECTED="V${TSV}v1
T${TSV}x${TSV}done task
T${TSV} ${TSV}todo task"
assert_eq "正常系のTSVが一致する" "$READ_EXPECTED" "$READ_OUT"

echo "=== read_note: V-12 相当（frontmatterの閉じ---が無い・終了コード2） ==="
cat > "$WORKDIR/vault/Projects/nofm.md" <<'NOTE'
---
date: 2026-01-01
status: active
# 閉じの--- が無い
## Tasks
### v1
- [x] a
NOTE
read_note "$WORKDIR/vault/Projects/nofm.md" >/tmp/read_note_v12.$$ 2>&1
RC_V12=$?
assert_eq "frontmatter不正は終了コード2（ノート破損）" "2" "$RC_V12"
rm -f /tmp/read_note_v12.$$

echo "=== read_note: 1行目が---でない場合も終了コード2 ==="
cat > "$WORKDIR/vault/Projects/no_open_fence.md" <<'NOTE'
# frontmatterが無いノート
## Tasks
### v1
- [x] a
NOTE
read_note "$WORKDIR/vault/Projects/no_open_fence.md" >/dev/null 2>&1
assert_eq "1行目が---でない場合も終了コード2" "2" "$?"

echo "=== read_note: V-6 相当（本文にNUL/ESC/CSIを含む・サニタイズ後に出力） ==="
# NUL は bash 変数に保持できず代入時点で切り詰まる（$'\x00' を変数へ入れて
# %s 展開する形は NUL が消えたまま "成立していないテスト" になる＝
# verifier 実装レビュー1巡目 #7 指摘）。printf のフォーマット文字列に
# \0（NUL）・\033（ESC）を直接埋め込み、変数を経由せずファイルへ書く。
{
  printf -- '---\n'
  printf 'date: 2026-01-01\n'
  printf -- '---\n'
  printf '## Tasks\n'
  printf '### v1\n'
  printf -- '- [ ] a\0b\033[31mc\n'
} > "$WORKDIR/vault/Projects/v6.md"
V6_OUT="$(read_note "$WORKDIR/vault/Projects/v6.md")"
V6_RC=$?
assert_eq "V-6相当: 正常終了（サニタイズはノート破損にしない）" "0" "$V6_RC"
V6_HAS_NUL="$(printf '%s' "$V6_OUT" | python3 -c 'import sys; d=sys.stdin.read(); print(1 if chr(0) in d else 0)')"
assert_eq "V-6相当: 出力にU+0000が残らない" "0" "$V6_HAS_NUL"
V6_HAS_ESC="$(printf '%s' "$V6_OUT" | python3 -c 'import sys; d=sys.stdin.read(); print(1 if chr(27) in d else 0)')"
assert_eq "V-6相当: 出力にESCが残らない（CSIの導入バイトも含む）" "0" "$V6_HAS_ESC"
assert_true "V-6相当: 制御文字が空白に置換されただけで本文は残る（a・b・cが読める）" "$(printf '%s' "$V6_OUT" | grep -qF "a" && printf '%s' "$V6_OUT" | grep -qF "c" && echo 1 || echo 0)"

echo "=== read_note: サニタイズ失敗（jq不在）は終了コード2 ==="
NO_JQ_DIR="$WORKDIR/no-jq-path"
mkdir -p "$NO_JQ_DIR"
(
  PATH="$NO_JQ_DIR"
  export PATH
  read_note "$WORKDIR/vault/Projects/ok.md" >/dev/null 2>&1
  exit $?
)
assert_eq "jqが無くsanitize_linesが失敗すると終了コード2" "2" "$?"

echo "=== read_note: Tasks節が無いノートは正常終了かつ出力が空 ==="
cat > "$WORKDIR/vault/Projects/no_tasks.md" <<'NOTE'
---
date: 2026-01-01
---
# タスク節なし
本文だけ。
NOTE
NO_TASKS_OUT="$(read_note "$WORKDIR/vault/Projects/no_tasks.md")"
assert_eq "Tasks節が無ければ終了コード0" "0" "$?"
assert_eq "Tasks節が無ければ出力は空（Tasks節なしの判定は呼び出し側の仕事）" "" "$NO_TASKS_OUT"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
