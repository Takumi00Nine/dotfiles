#!/bin/bash
# cmux-task-watch.sh のユニットテスト（cmux-session-todo 設計 §11.1 U層）。
# 実 Vault・実ワークスペース・実 cmux には一切触れない。cmux 呼び出しは
# $WORKDIR/stubbin/cmux（スタブ）へ差し替える（§11.2 の契約）。
#
# 実行方法: bash tests/test-cmux-task-watch.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux-task-watch.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-task-watch-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

STUB_STATE="$WORKDIR/stubstate"
STUBBIN="$WORKDIR/stubbin"
VAULT="$WORKDIR/vault"
mkdir -p "$STUB_STATE" "$STUBBIN" "$VAULT/Projects"

# AC-34用: reset_stub_state で消える $STUB_STATE/calls.log とは別に、
# ファイル全体の実行を通して1本の集約ログを残す（verifierレビュー1巡目
# #4対応。§11.3のAC-34は「全fixture実行」を横断して見る契約）。
AGGREGATE_CALLS_LOG="$WORKDIR/aggregate_calls.log"
: > "$AGGREGATE_CALLS_LOG"
export AGGREGATE_CALLS_LOG

PASS=0
FAIL=0

strip_ansi() {
  python3 -c "
import re, sys
esc = chr(27)
pat = re.compile(esc + r'\[[0-9;]*m')
sys.stdout.write(pat.sub('', sys.stdin.read()))
"
}

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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  期待した文字列が見つかりません: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
    echo "  含まれてはいけない文字列が見つかりました: $needle"
  else
    PASS=$(( PASS + 1 ))
  fi
}

# $1 にファイルにパターン($2)が現れるまで$3秒ポーリングする。
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

# ==========================================================================
# cmux スタブ（設計 §11.2 の契約）
# ==========================================================================
cat > "$STUBBIN/cmux" <<'STUB'
#!/bin/bash
STATE="$STUB_STATE"
echo "cmux $*" >> "$STATE/calls.log"
[ -n "${AGGREGATE_CALLS_LOG:-}" ] && echo "cmux $*" >> "$AGGREGATE_CALLS_LOG"

sub2=""
[ "$1" = "--json" ] && sub2="$2"

# ハングの模擬（どのサブコマンドでも hang_<sub> があればハングする）
if [ -n "$sub2" ] && [ -e "$STATE/hang_$sub2" ]; then
  echo "$$" >> "$STATE/hang_pids"
  sleep 60 & child=$!
  echo "$child" >> "$STATE/hang_pids"
  wait "$child"
  exit 1
fi

if [ "$1" = "--json" ] && [ "$2" = "identify" ]; then
  [ -e "$STATE/fail_identify" ] && exit 9
  focused_ref="$(cat "$STATE/focused_ref" 2>/dev/null)"
  caller_ref="$(cat "$STATE/caller_ref" 2>/dev/null)"
  printf '{"focused":{"workspace_ref":"%s"},"caller":{"workspace_ref":"%s"}}\n' "$focused_ref" "$caller_ref"
  exit 0
fi

if [ "$1" = "--json" ] && [ "$2" = "workspace" ] && [ "$3" = "list" ]; then
  win=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in --window) win="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -e "$STATE/fail_workspace_list" ] && exit 9
  if [ -n "$win" ]; then
    [ -e "$STATE/fail_workspace_list.$win" ] && exit 9
    f="$STATE/workspaces.$win.json"
    [ -f "$f" ] || exit 9
    cat "$f"
    exit 0
  fi
  [ -f "$STATE/workspaces.json" ] || exit 9
  cat "$STATE/workspaces.json"
  exit 0
fi

if [ "$1" = "--json" ] && [ "$2" = "list-windows" ]; then
  [ -e "$STATE/fail_list_windows" ] && exit 9
  [ -f "$STATE/windows.json" ] || exit 9
  cat "$STATE/windows.json"
  exit 0
fi

# --json 無しの list-windows は非0で落とす（本番が --json 版だけを使う契約
# をスタブ側でも強制する）
if [ "$1" = "list-windows" ]; then
  exit 9
fi

# 書込系は記録したうえで非0（呼ばれてはいけない＝AC-34）
case "$1 $2" in
  "todo "*|"--json todo"*) exit 9 ;;
esac
case "$*" in
  *set-status*|*clear-status*|*set-progress*|*"workspace status set"*|*new-pane*|*new-surface*)
    exit 9 ;;
esac

echo "unhandled: $*" >&2
exit 9
STUB
chmod +x "$STUBBIN/cmux"

export CMUX_TASK_CMUX_BIN="$STUBBIN/cmux"
export STUB_STATE

reset_stub_state() {
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE"
  echo "workspace:1" > "$STUB_STATE/focused_ref"
  echo "workspace:1" > "$STUB_STATE/caller_ref"
  cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
}

# ==========================================================================
# V群: Vault ノート fixture（17件）
# ==========================================================================
mk_note_V1() {
  cat > "$1/Projects/v1proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] task a
- [x] task b
- [x] task c

### v2
- [x] 要件定義
- [/] 設計
- [ ] 実装

### v3
- [ ] t1
- [ ] t2
- [ ] t3
- [ ] t4
EOF
}

mk_note_V2() {
  cat > "$1/Projects/v2proj.md" <<'EOF'
---
date: 2026-01-01
---
# no tasks section at all
EOF
}

mk_note_V3() {
  cat > "$1/Projects/v3proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks
- [ ] task without a version heading
EOF
}

mk_note_V4() {
  cat > "$1/Projects/v4proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1

### v2
EOF
}

mk_note_V5() {
  cat > "$1/Projects/v5proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] a

### v2

### v3
- [ ] b
EOF
}

# タスク本文に U+0000（NUL）・ESC・CSI（ESC[…）を含む（要件書 V-6）。
# bash 変数は NUL を保持できない（"$(...)" に通した時点で欠落する）ため、
# printf からファイルへ直接リダイレクトして書く（変数へは一切経由しない。
# verifierレビュー1巡目 #7・MINOR対応）。
mk_note_V6() {
  printf -- '---\ndate: 2026-01-01\n---\n## Tasks\n\n### v1\n- [ ] a\x00b\x1bc\x1b[31md\n' > "$1/Projects/v6proj.md"
}

mk_note_V7() {
  local body
  body="$(python3 -c 'print("A"*520)')"
  {
    printf -- '---\ndate: 2026-01-01\n---\n## Tasks\n\n### v1\n- [ ] '
    printf '%s\n' "$body"
  } > "$1/Projects/v7proj.md"
}

mk_note_V8() {
  cat > "$1/Projects/v8proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ]
EOF
}

mk_note_V9() {
  local body
  body="$(python3 -c 'print("あ"*25)')"
  {
    printf -- '---\ndate: 2026-01-01\n---\n## Tasks\n\n### v1\n- [ ] '
    printf '%s\n' "$body"
  } > "$1/Projects/v9proj.md"
}

mk_note_V10() {
  cat > "$1/Projects/v10proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [x] a
- [x] b

### v2
- [x] a

### v3
- [x] a
- [x] b
- [x] c
EOF
}

mk_note_V11() {
  cat > "$1/Projects/v11proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] a

### v2
- [ ] b
EOF
}

mk_note_V12() {
  cat > "$1/Projects/v12proj.md" <<'EOF'
---
date: 2026-01-01
## Tasks

### v1
- [ ] a
EOF
}

mk_note_V13() {
  cat > "$1/Projects/v13proj.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### dup
- [x] a

### dup
- [ ] b
EOF
}

mk_note_V14() {
  python3 -c "
lines=['---','date: 2026-01-01','---','## Tasks','','### v1']
for i in range(60): lines.append(f'- [ ] t{i}')
open('$1/Projects/v14proj.md','w').write('\n'.join(lines)+'\n')
"
}

mk_note_V15() {
  python3 -c "
lines=['---','date: 2026-01-01','---','## Tasks','','### v1','- [x] a','- [x] b','','### v2']
for i in range(1,6): lines.append(f'- [x] t{i}')
for i in range(6,11): lines.append(f'- [ ] t{i}')
lines.append('- [/] t11')
lines.append('- [ ] t12')
lines += ['','### v3','- [x] a','','### v4','- [x] a','','### v5','- [x] a']
open('$1/Projects/v15proj.md','w').write('\n'.join(lines)+'\n')
"
}

# V-16 は slug 自体を表示幅40超にする。呼び出し側は V16_SLUG を参照する。
V16_SLUG="$(python3 -c 'print("a"*45)')"
mk_note_V16() {
  cat > "$1/Projects/${V16_SLUG}.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] t1
- [ ] t2
EOF
}

# V-17 は「版名が表示幅40超」の fixture。verifierレビュー1巡目 #5 指摘:
# slug が10セル未満だとAC-55の「プロジェクト名は10セル下限まで残す」が
# 検査できない（第1段で名前がそもそも削られる余地が無いため）。
# slug 自体は10セル以上・40セル未満（第1段の裁量で残る長さ）にする。
V17_SLUG="v17projectname"
mk_note_V17() {
  local longver
  longver="$(python3 -c 'print("v"*45)')"
  cat > "$1/Projects/${V17_SLUG}.md" <<EOF
---
date: 2026-01-01
---
## Tasks

### ${longver}
- [ ] t1
- [ ] t2
EOF
}

# ==========================================================================
# 共通ヘルパー: 宣言記録・cmux フォーカス状態
# ==========================================================================

# 宣言基底（W-1相当）: UUID-AAA -> $1(slug)。フォーカスは workspace:1。
mk_decl_single() {
  local slug="$1" state_file="$2"
  cat > "$state_file" <<JSON
{"version":1,"workspaces":{"UUID-AAA":"$slug"}}
JSON
}

# AC-33用: $VAULT の全ファイルの内容とmtimeのスナップショット。名前・mtime・
# サイズだけでは内容の書換えを検知できない（verifier実装レビュー2巡目
# #10・MAJOR）ため、内容ハッシュ（shasum -a 256）を各行へ追加する。
vault_snapshot() {
  find "$VAULT" -type f -print 2>/dev/null | sort | while IFS= read -r f; do
    printf '%s %s\n' \
      "$(stat -f '%N %m %z' "$f" 2>/dev/null)" \
      "$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
  done
}

# AC-33の違反を集約する（verifierレビュー1巡目 #4対応:「最後に作り直した
# V-1の2実行」だけでなく、$VAULTを使うfixture実行のたびに前後差分を見る）。
# ファイルへ書く（bash3.2の罠: run_once_plain/run_once_colored は呼び出し
# 元で必ず "$(...)" に包まれるため関数全体がサブシェルで走り、グローバル
# 変数への書込みは呼び出し元に伝わらない。$(func) はサブシェル実行という
# 既知の落とし穴＝Knowledge/bash32-strict-mode-pitfalls.md #5。実測で
# 変数集約方式は検知漏れを起こすことを確認したためファイル集約に変更）。
VAULT_MUTATION_LOG_FILE="$WORKDIR/vault_mutations.log"
: > "$VAULT_MUTATION_LOG_FILE"

# 同じ理由で run_once_ex の rc もファイルへ渡す（呼び出し元が
# out="$(run_once_ex ...)" のように$(...)で包む場合、グローバル変数
# RUN_ONCE_RC への代入はサブシェル内で終わり呼び出し元へ伝わらない）。
RUN_ONCE_RC_FILE="$WORKDIR/run_once_rc"
: > "$RUN_ONCE_RC_FILE"

check_vault_unchanged() {
  local label="$1" before="$2" after="$3"
  if [ "$before" != "$after" ]; then
    echo "$label" >> "$VAULT_MUTATION_LOG_FILE"
  fi
}

# $1 が $VAULT のときだけ、実行前後で vault_snapshot を取って比較する
# （DT-1 等、意図的に別 Vault を使うテストは対象外＝$1 != $VAULT なら素通し）。
#
# 汎用版（verifier実装レビュー3巡目 #13対応）: AC-29/AC-30/AC-31が対象
# スクリプトを直接実行しておりsnapshot比較を通っていなかったため、実行
# バイナリ・フラグ・PATH上書きを引数化してここへ統一する。
#   $1=vault $2=state $3=cols $4=rows $5=bin（省略時bash） $6=フラグ
#   （省略時"--once"。空白区切りで複数可） $7=PATH上書き（空なら未指定）
# stdoutをprintfで返し、rcはグローバル RUN_ONCE_RC へ格納する。
run_once_ex() {
  local vault="$1" state_file="$2" cols="$3" rows="$4"
  local bin="${5:-bash}" flags="${6:---once}" path_override="${7:-}"
  local before="" after="" out
  [ "$vault" = "$VAULT" ] && before="$(vault_snapshot)"
  if [ -n "$path_override" ]; then
    out="$(CMUX_TASK_VAULT="$vault" CMUX_TASK_STATE="$state_file" \
      CMUX_TASK_COLS="$cols" CMUX_TASK_ROWS="$rows" \
      PATH="$path_override" "$bin" "$TARGET" $flags)"
  else
    out="$(CMUX_TASK_VAULT="$vault" CMUX_TASK_STATE="$state_file" \
      CMUX_TASK_COLS="$cols" CMUX_TASK_ROWS="$rows" \
      "$bin" "$TARGET" $flags)"
  fi
  RUN_ONCE_RC=$?
  printf '%s' "$RUN_ONCE_RC" > "$RUN_ONCE_RC_FILE"
  if [ "$vault" = "$VAULT" ]; then
    after="$(vault_snapshot)"
    check_vault_unchanged "run_once_ex bin=$bin flags=$flags cols=$cols rows=$rows" "$before" "$after"
  fi
  printf '%s' "$out"
}

run_once_plain() {
  run_once_ex "$1" "$2" "$3" "$4" bash "--plain --once"
}

run_once_colored() {
  run_once_ex "$1" "$2" "$3" "$4" bash "--once"
}

STATE_FILE="$WORKDIR/decl.json"

# ==========================================================================
# 表示基底（V-1・W-1・M-1・S-1・F-1）: AC-1〜18・25〜32・51〜56
# ==========================================================================
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"

echo "=== AC-1〜4: FR-21 の書式例と行単位一致 ==="
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
expected='▶ v1proj  v2 1/3
v1 ✅ 3/3
v2 ▶ 1/3
 ├ [x] 要件定義
 ├ [/] 設計
 └ [ ] 実装
v3 ・ 0/4'
assert_eq "AC-1: 表示基底の出力がFR-21の書式例と一致" "$expected" "$out"
assert_eq "AC-1: 行数が7" "7" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "AC-2: v2の子行3件が記載順" "$(printf ' ├ [x] 要件定義\n ├ [/] 設計\n └ [ ] 実装')" \
  "$(printf '%s\n' "$out" | sed -n '4,6p')"
assert_eq "AC-3: ヘッダー行の形" "▶ v1proj  v2 1/3" "$(printf '%s\n' "$out" | head -n1)"
assert_contains "AC-4: 畳んだ版行 v1" "$out" "v1 ✅ 3/3"
assert_contains "AC-4: 畳んだ版行 v3" "$out" "v3 ・ 0/4"

echo "=== AC-5: [/]無し・未完版2つ（V-11） ==="
mk_note_V11 "$VAULT"
mk_decl_single "v11proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
expected='・ v11proj  次: v1 0/1
v1 ・ 0/1
 └ [ ] a
v2 ・ 0/1'
assert_eq "AC-5: V-11の表示" "$expected" "$out"

echo "=== AC-6: 全版完了（V-10） ==="
mk_note_V10 "$VAULT"
mk_decl_single "v10proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
expected='✅ v10proj  全版完了 3/3
v1 ✅ 2/2
v2 ✅ 1/1
v3 ✅ 3/3'
assert_eq "AC-6: V-10の表示（子行なし・全✅）" "$expected" "$out"

echo "=== AC-7: タスク0件の版（V-5） ==="
mk_note_V5 "$VAULT"
mk_decl_single "v5proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_contains "AC-7: v2が ・ 0/0 として出る（理由行にならない）" "$out" "v2 ・ 0/0"

echo "=== AC-8: 同名版2つ（V-13） ==="
mk_note_V13 "$VAULT"
mk_decl_single "v13proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
expected='・ v13proj  次: dup 0/1
dup ✅ 1/1
dup ・ 0/1
 └ [ ] b'
assert_eq "AC-8: 同名版が記載順に2行" "$expected" "$out"

echo "=== AC-9: V-14 x M-3（40x8）省略行のN ==="
mk_note_V14 "$VAULT"
mk_decl_single "v14proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 8)"
nlines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_true "AC-9: 総行数が8以下" "$([ "$nlines" -le 8 ] && echo 1 || echo 0)"
omit_line="$(printf '%s\n' "$out" | tail -n1)"
assert_true "AC-9: 最終行が …他N行 の形" "$(printf '%s' "$omit_line" | grep -qE '^…他[0-9]+行$' && echo 1 || echo 0)"
omit_n="$(printf '%s' "$omit_line" | grep -oE '[0-9]+')"
kept_children="$(( nlines - 3 ))"  # header + VE行 + omit行を除いた残り件数
total_children=60
assert_eq "AC-9: Nが落とした行数と一致" "$(( total_children - kept_children ))" "$omit_n"

echo "=== AC-10: 制御文字を含まない（V-6） ==="
mk_note_V6 "$VAULT"
mk_decl_single "v6proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
bad="$(python3 -c "
import sys
text = '''$out'''
bad = [hex(ord(c)) for c in text if (ord(c) <= 0x1f and c != chr(10)) or (0x7f <= ord(c) <= 0x9f)]
print(len(bad))
")"
assert_eq "AC-10: 制御文字が1文字も無い" "0" "$bad"

echo "=== AC-11: V-7・V-9 x M-1（40列）切り詰め末尾… ==="
mk_note_V7 "$VAULT"
mk_note_V9 "$VAULT"
mk_decl_single "v7proj" "$STATE_FILE"
out7="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
mk_decl_single "v9proj" "$STATE_FILE"
out9="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
allw40="$(python3 -c "
import unicodedata
def w(c):
    if c in '▶✅・├└…':  # 本番の範囲表と同じ既知の例外（設計§11.4）
        return 1
    return 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
ok = True
for text in ('''$out7''', '''$out9'''):
    for line in text.split(chr(10)):
        if sum(w(c) for c in line) > 40:
            ok = False
print(1 if ok else 0)
")"
assert_true "AC-11: すべての行の表示幅が40以下" "$allw40"
last7="$(printf '%s\n' "$out7" | tail -n1)"
last9="$(printf '%s\n' "$out9" | tail -n1)"
assert_true "AC-11: V-7の子行末尾が…" "$(printf '%s' "$last7" | grep -q '…$' && echo 1 || echo 0)"
assert_true "AC-11: V-9の子行末尾が…" "$(printf '%s' "$last9" | grep -q '…$' && echo 1 || echo 0)"

echo "=== DT-6: V-9 x M-1 の切り詰め位置をリテラルで固定 ==="
# 行全体（先頭空白・罫線・状態記号を含む）をリテラルで固定する（§11.4の
# 独立オラクル。verifierレビュー1巡目 #5対応: containsではなく行の完全
# 一致で見る）。
expected_child=" └ [ ] $(python3 -c 'print("あ"*16)')…"
out9_lastline="$(printf '%s\n' "$out9" | tail -n1)"
assert_eq "DT-6: 子行が完全一致（16文字のあ+…で切れる）" "$expected_child" "$out9_lastline"

echo "=== AC-12: V-9 x M-2（80列） ==="
out9_80="$(run_once_plain "$VAULT" "$STATE_FILE" 80 24)"
allw80over40="$(python3 -c "
import unicodedata
def w(c):
    if c in '▶✅・├└…':
        return 1
    return 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
text = '''$out9_80'''
ok_all = True
has_over40 = False
for line in text.split(chr(10)):
    width = sum(w(c) for c in line)
    if width > 80: ok_all = False
    if width > 40: has_over40 = True
print(1 if (ok_all and has_over40) else 0)
")"
assert_true "AC-12: 80以下かつ40超の行が存在" "$allw80over40"

echo "=== AC-13: 陰性4件（V-2/V-3/V-4/V-8）が理由行1行・rc=0 ==="
mk_note_V2 "$VAULT"; mk_note_V3 "$VAULT"; mk_note_V4 "$VAULT"; mk_note_V8 "$VAULT"
declare -a v13_slugs=(v2proj v3proj v4proj v8proj)
declare -a v13_reasons=("Tasks 節なし" "Tasks 節なし" "タスクなし" "空タスク")
for idx in 0 1 2 3; do
  mk_decl_single "${v13_slugs[$idx]}" "$STATE_FILE"
  out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
  rc=$?
  assert_eq "AC-13: ${v13_slugs[$idx]} の理由行" "${v13_reasons[$idx]}" "$out"
  assert_eq "AC-13: ${v13_slugs[$idx]} の終了コード0" "0" "$rc"
done

echo "=== AC-14: frontmatter未閉（V-12）→ノート破損 ==="
mk_note_V12 "$VAULT"
mk_decl_single "v12proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-14: ノート破損1行" "ノート破損" "$out"

echo "=== AC-15: ノート不在/未宣言 ==="
mk_decl_single "no-such-note-slug" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-15: ノート不在" "ノート不在" "$out"
cat > "$STATE_FILE" <<'JSON'
{"version":1,"workspaces":{}}
JSON
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-15: 未宣言" "未宣言" "$out"

echo "=== AC-16: S-2/S-3/S-4 ==="
mk_decl_single "v1proj" "$STATE_FILE"
touch "$STUB_STATE/fail_identify"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-16: S-2 identify失敗 → cmux応答なし" "cmux 応答なし" "$out"
rm -f "$STUB_STATE/fail_identify"

touch "$STUB_STATE/fail_workspace_list"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-16: S-3 workspace list失敗 → cmux応答なし" "cmux 応答なし" "$out"
rm -f "$STUB_STATE/fail_workspace_list"

echo "workspace:99" > "$STUB_STATE/focused_ref"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-16: S-4 対象不明" "対象不明" "$out"
echo "workspace:1" > "$STUB_STATE/focused_ref"

echo "=== AC-17: Vault不在（F-2） ==="
out="$(CMUX_TASK_VAULT="$WORKDIR/no-such-vault" CMUX_TASK_STATE="$STATE_FILE" \
  CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 bash "$TARGET" --plain --once)"
assert_eq "AC-17: Vault不在" "Vault 不在" "$out"

echo "=== AC-18: 先勝ちの3組合せ ==="
mk_note_V8 "$VAULT"
cat > "$STATE_FILE" <<'JSON'
{"version":1,"workspaces":{}}
JSON
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-18: W-3×V-8 → 未宣言" "未宣言" "$out"

touch "$STUB_STATE/fail_identify"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-18: S-2×W-3 → cmux応答なし" "cmux 応答なし" "$out"
rm -f "$STUB_STATE/fail_identify"

printf 'not json' > "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-18: W-7×W-3 → 宣言記録破損" "宣言記録破損" "$out"

echo "=== AC-23: ref振り直し（W-5）→ 表示基底と一致 ==="
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:7"}]}
JSON
echo "workspace:7" > "$STUB_STATE/focused_ref"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
assert_eq "AC-23: refが振り直っても同一UUIDで解決・表示基底と一致" '▶ v1proj  v2 1/3
v1 ✅ 3/3
v2 ▶ 1/3
 ├ [x] 要件定義
 ├ [/] 設計
 └ [ ] 実装
v3 ・ 0/4' "$out"
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"}]}
JSON
echo "workspace:1" > "$STUB_STATE/focused_ref"

echo "=== AC-27〜29: 色付き/--once/--plain の先頭末尾 ==="
colored="$(run_once_colored "$VAULT" "$STATE_FILE" 40 24)"
assert_true "AC-27: 先頭がESC[?2026h" "$(printf '%s' "$colored" | head -c 8 | od -An -tx1 | tr -d ' \n' | grep -q '^1b5b3f323032366800\|^1b5b3f323032366' && echo 1 || echo 0)"
python3 -c "
import sys
data = '''$colored'''
sys.exit(0 if data.startswith(chr(27)+'[?2026h') else 1)
" && ac27_start=1 || ac27_start=0
assert_true "AC-27: pythonでの先頭確認" "$ac27_start"
python3 -c "
import sys
data = '''$colored'''
sys.exit(0 if data.rstrip('\n').endswith(chr(27)+'[?2026l') else 1)
" && ac27_end=1 || ac27_end=0
assert_true "AC-27: 末尾がESC[?2026l" "$ac27_end"

echo "=== AC-28: 色付きで完了/進行中/未着手が異なるSGR、--plainはESC無し ==="
sgr_x="$(printf '%s' "$colored" | grep -F '[x]' | grep -oE $'\x1b''\[[0-9;]*m' | head -n1)"
sgr_slash="$(printf '%s' "$colored" | grep -F '[/]' | grep -oE $'\x1b''\[[0-9;]*m' | head -n1)"
sgr_blank="$(printf '%s' "$colored" | grep -F '[ ]' | grep -oE $'\x1b''\[[0-9;]*m' | head -n1)"
assert_true "AC-28: [x]と[/]のSGRが異なる" "$([ "$sgr_x" != "$sgr_slash" ] && echo 1 || echo 0)"
assert_true "AC-28: [/]と[ ]のSGRが異なる" "$([ "$sgr_slash" != "$sgr_blank" ] && echo 1 || echo 0)"
assert_true "AC-28: [x]と[ ]のSGRが異なる" "$([ "$sgr_x" != "$sgr_blank" ] && echo 1 || echo 0)"
plain_out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
python3 -c "
import sys
sys.exit(0 if chr(27) not in '''$plain_out''' else 1)
" && ac28_plain=1 || ac28_plain=0
assert_true "AC-28: --plainにESCが無い" "$ac28_plain"

echo "=== AC-29: --onceが1フレーム出力・終了コード0 ==="
run_once_ex "$VAULT" "$STATE_FILE" 40 24 bash "--once" >/dev/null
assert_eq "AC-29: 終了コード0" "0" "$(cat "$RUN_ONCE_RC_FILE")"

echo "=== AC-30: bash -n / bash --once ==="
/bin/bash -n "$TARGET"
assert_eq "AC-30: bash -n 成功" "0" "$?"
run_once_ex "$VAULT" "$STATE_FILE" 40 24 /bin/bash "--once" >/dev/null
assert_eq "AC-30: --once成功" "0" "$(cat "$RUN_ONCE_RC_FILE")"

echo "=== AC-31: PATHを標準ユーティリティ+jq+スタブに限定 ==="
JQDIR="$(dirname "$(command -v jq)")"
out="$(run_once_ex "$VAULT" "$STATE_FILE" 40 24 bash "--plain --once" "/usr/bin:/bin:$STUBBIN:$JQDIR")"
rc="$(cat "$RUN_ONCE_RC_FILE")"
assert_eq "AC-31: 限定PATHでも成功" "0" "$rc"
assert_contains "AC-31: 通常表示になる" "$out" "▶ v1proj"

echo "=== AC-32: CMUX_TASK_INTERVAL の既定復帰 ==="
LIB_DIR="$SCRIPT_DIR/../.."
resolved_default="$(bash -c ". '$LIB_DIR/lib-dock-view.sh'; sanitize_interval '' 60")"
resolved_empty="$(bash -c ". '$LIB_DIR/lib-dock-view.sh'; sanitize_interval '' 60")"
resolved_nonnum="$(bash -c ". '$LIB_DIR/lib-dock-view.sh'; sanitize_interval 'abc' 60")"
resolved_zero="$(bash -c ". '$LIB_DIR/lib-dock-view.sh'; sanitize_interval '0' 60")"
assert_eq "AC-32: 未設定→60" "60" "$resolved_default"
assert_eq "AC-32: 空→60" "60" "$resolved_empty"
assert_eq "AC-32: 非数字→60" "60" "$resolved_nonnum"
assert_eq "AC-32: 0→60" "60" "$resolved_zero"

echo "=== AC-46(前半): OSC2タイトルが Next Task ==="
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
_before="$(vault_snapshot)"
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=60 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$TARGET" > "$WORKDIR/daemon_osc2.out" 2>&1 &
osc_pid=$!
sleep 1.2
kill -TERM "$osc_pid" 2>/dev/null || true
wait "$osc_pid" 2>/dev/null
check_vault_unchanged "AC-46 daemon" "$_before" "$(vault_snapshot)"
osc_data="$(cat "$WORKDIR/daemon_osc2.out")"
assert_contains "AC-46: Next Task のOSC2列が含まれる" "$osc_data" "$(printf '\033]2;Next Task\007')"
python3 -c "
import sys
data = open('$WORKDIR/daemon_osc2.out','rb').read()
sys.exit(0 if (chr(27)+']2;Next'+chr(7)).encode() not in data else 1)
" && ac46_no_bare=1 || ac46_no_bare=0
assert_true "AC-46: 素の Next 単独のOSC2は無い" "$ac46_no_bare"

echo "=== AC-51: V-15 x M-3（40x8）の高さクランプ・罫線・N を厳密固定 ==="
reset_stub_state
mk_note_V15 "$VAULT"
mk_decl_single "v15proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 8)"
expected='▶ v15proj  v2 5/12
v2 ▶ 5/12
 ├ [ ] t6
 ├ [ ] t7
 ├ [ ] t8
 ├ [ ] t9
 └ [/] t11
…他11行'
assert_eq "AC-51: V-15 x M-3 の完全一致" "$expected" "$out"

echo "=== AC-52: V-16(長いslug) x M-1: 版欄は丸ごと残り名前だけ切り詰め ==="
mk_note_V16 "$VAULT"
mk_decl_single "$V16_SLUG" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
header="$(printf '%s\n' "$out" | head -n1)"
# 完全な期待行をリテラルで固定する（§11.4の独立オラクル。verifierレビュー
# 1巡目 #5 対応: containsではなく行全体の一致で見る）。
assert_eq "AC-52: ヘッダー行が完全一致" "・ $(python3 -c 'print("a"*24)')…  次: v1 0/2" "$header"

echo "=== AC-53/AC-55: V-17(長い版名・プロジェクト名は10セル超) x M-1 ==="
mk_note_V17 "$VAULT"
mk_decl_single "$V17_SLUG" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
header="$(printf '%s\n' "$out" | head -n1)"
verline="$(printf '%s\n' "$out" | sed -n '2p')"
# V17_SLUG="v17projectname"（14セル）は cols=40 では第1段の10セル下限まで
# 切り詰められる（"v17projec…"=10セル）。これがAC-55の「表示幅10セル分の
# プロジェクト名が残る」を実際に検査可能にする（verifierレビュー1巡目 #5
# 指摘: 旧 slug "v17proj" は7セルで一度も切り詰められず検査になっていな
# かった）。版名（45個のv）は第2段で16個+…まで切り詰められる。
assert_eq "AC-55: ヘッダー行が完全一致（プロジェクト名は10セル floor・版名側が切り詰め）" \
  "・ v17projec…  次: $(python3 -c 'print("v"*16)')… 0/2" "$header"
assert_eq "AC-53: 版行が完全一致（記号・分数は残り版名だけ切り詰め）" \
  "$(python3 -c 'print("v"*32)')… ・ 0/2" "$verline"

echo "=== AC-54: V-9 x M-1: 子行の先頭空白・罫線・状態記号は残り本文だけ切り詰め ==="
mk_note_V9 "$VAULT"
mk_decl_single "v9proj" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 40 24)"
childline="$(printf '%s\n' "$out" | tail -n1)"
assert_eq "AC-54: 固定部が ' └ [ ] ' のまま残る" " └ [ ] $(python3 -c 'print("あ"*16)')…" "$childline"

echo "=== AC-56: V-16(長いslug) x M-4（16列）: 第3段（記号+分数のみ） ==="
out="$(run_once_plain "$VAULT" "$STATE_FILE" 16 24)"
mk_decl_single "$V16_SLUG" "$STATE_FILE"
out="$(run_once_plain "$VAULT" "$STATE_FILE" 16 24)"
header="$(printf '%s\n' "$out" | head -n1)"
width16="$(python3 -c "
import unicodedata
def w(c):
    if c in '▶✅・├└…': return 1
    return 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
print(sum(w(c) for c in '''$header'''))
")"
# 完全な期待行をリテラルで固定する（verifierレビュー1巡目 #5対応）。
# 独立オラクル（python3のunicodedata・§11.4）による幅検査も併用。
assert_eq "AC-56: ヘッダー行が完全一致（第3段=記号+分数のみ）" "・ 0/2" "$header"
assert_true "AC-56: 独立オラクルでもヘッダー表示幅が16以下" "$([ "$width16" -le 16 ] && echo 1 || echo 0)"

echo "=== DT-4: rows=1・rows=2 の退化（完全一致・幅・色） ==="
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
out1="$(run_once_plain "$VAULT" "$STATE_FILE" 40 1)"
assert_eq "DT-4: rows=1はヘッダーのみ" "▶ v1proj  v2 1/3" "$out1"
out2="$(run_once_plain "$VAULT" "$STATE_FILE" 40 2)"
expected2='▶ v1proj  v2 1/3
…他6行'
assert_eq "DT-4: rows=2はヘッダー+省略行(N=6)" "$expected2" "$out2"
w1="$(python3 -c "print(len('''$out1'''.split(chr(10))[0]))")"
w2ok="$(python3 -c "
lines = '''$out2'''.split(chr(10))
print(1 if all(len(l) <= 40 for l in lines) else 0)
")"
assert_true "DT-4: rows=2の各行が40以下" "$w2ok"
colored2="$(run_once_colored "$VAULT" "$STATE_FILE" 40 2)"
python3 -c "
import sys
data = '''$colored2'''
sys.exit(0 if (data.startswith(chr(27)+'[?2026h') and data.rstrip(chr(10)).endswith(chr(27)+'[?2026l')) else 1)
" && dt4_sync=1 || dt4_sync=0
assert_true "DT-4: rows=2の色付き出力も同期出力で包まれる" "$dt4_sync"
assert_true "DT-4: rows=2のヘッダー行に記号相応のSGR(強調色114)が付く" "$(printf '%s' "$colored2" | grep -qF '38;5;114' && echo 1 || echo 0)"

echo "=== AC-24: W-6 x T-3 フォーカス切替から5秒以内 ==="
reset_stub_state
mk_note_V1 "$VAULT"
cat > "$VAULT/Projects/proj2.md" <<'EOF'
---
date: 2026-01-01
---
## Tasks

### v1
- [ ] only task
EOF
cat > "$STATE_FILE" <<'JSON'
{"version":1,"workspaces":{"UUID-AAA":"v1proj","UUID-BBB":"proj2"}}
JSON
cat > "$STUB_STATE/workspaces.json" <<'JSON'
{"workspaces":[{"id":"UUID-AAA","ref":"workspace:1"},{"id":"UUID-BBB","ref":"workspace:2"}]}
JSON
echo "workspace:1" > "$STUB_STATE/focused_ref"
daemon_out="$WORKDIR/daemon_ac24.out"
: > "$daemon_out"
_before="$(vault_snapshot)"
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=60 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$TARGET" > "$daemon_out" 2>&1 &
ac24_pid=$!
wait_for "$daemon_out" "v1proj" 10
t0=$(python3 -c 'import time;print(time.monotonic())')
echo "workspace:2" > "$STUB_STATE/focused_ref"
wait_for "$daemon_out" "proj2" 10
found_rc=$?
t1=$(python3 -c 'import time;print(time.monotonic())')
elapsed="$(python3 -c "print($t1 - $t0)")"
kill -TERM "$ac24_pid" 2>/dev/null || true
wait "$ac24_pid" 2>/dev/null
check_vault_unchanged "AC-24 daemon" "$_before" "$(vault_snapshot)"
assert_true "AC-24: proj2が見つかった" "$([ "$found_rc" -eq 0 ] && echo 1 || echo 0)"
assert_true "AC-24: 5秒未満で切り替わる" "$(python3 -c "print(1 if $elapsed < 5.0 else 0)")"

echo "=== AC-25: 同一フレーム抑止 ==="
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
daemon_out="$WORKDIR/daemon_ac25.out"
: > "$daemon_out"
_before="$(vault_snapshot)"
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=1 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$TARGET" > "$daemon_out" 2>&1 &
ac25_pid=$!
sleep 3.5
alive="$(kill -0 "$ac25_pid" 2>/dev/null && echo 1 || echo 0)"
kill -TERM "$ac25_pid" 2>/dev/null || true
wait "$ac25_pid" 2>/dev/null
check_vault_unchanged "AC-25 daemon" "$_before" "$(vault_snapshot)"
sync_count="$(python3 -c "
data = open('$daemon_out','rb').read()
print(data.count((chr(27)+'[?2026h').encode()))
")"
assert_eq "AC-25: 入力を変えず3.5秒でsync-beginが1回だけ" "1" "$sync_count"
assert_true "AC-25: 常駐は生存していた" "$alive"

echo "=== AC-26: T-2（cmux応答なし→回復）・プロセス生存 ==="
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
touch "$STUB_STATE/fail_identify"
daemon_out="$WORKDIR/daemon_ac26.out"
: > "$daemon_out"
_before="$(vault_snapshot)"
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=1 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$TARGET" > "$daemon_out" 2>&1 &
ac26_pid=$!
wait_for "$daemon_out" "応答なし" 10
rm -f "$STUB_STATE/fail_identify"
wait_for "$daemon_out" "▶" 10
found_normal=$?
sleep 0.3
alive="$(kill -0 "$ac26_pid" 2>/dev/null && echo 1 || echo 0)"
data="$(cat "$daemon_out")"
sync_count="$(python3 -c "
data = open('$daemon_out','rb').read()
print(data.count((chr(27)+'[?2026h').encode()))
")"
kill -TERM "$ac26_pid" 2>/dev/null || true
wait "$ac26_pid" 2>/dev/null
check_vault_unchanged "AC-26 daemon" "$_before" "$(vault_snapshot)"
assert_true "AC-26: 通常表示に回復した" "$([ "$found_normal" -eq 0 ] && echo 1 || echo 0)"
assert_true "AC-26: プロセスが生存していた" "$alive"
assert_eq "AC-26: sync-beginが2回（理由行1・通常表示1）" "2" "$sync_count"

echo "=== DT-1: NFR-6のVault側回復（同一パスをmvで出現させる） ==="
reset_stub_state
mk_decl_single "v1proj" "$STATE_FILE"
DT1_V="$WORKDIR/vault-dt1"
DT1_READY="$WORKDIR/vault-dt1-ready"
rm -rf "$DT1_V" "$DT1_READY"
mkdir -p "$DT1_READY/Projects"
mk_note_V1 "$DT1_READY"
daemon_out="$WORKDIR/daemon_dt1.out"
: > "$daemon_out"
CMUX_TASK_VAULT="$DT1_V" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=60 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$TARGET" > "$daemon_out" 2>&1 &
dt1_pid=$!
wait_for "$daemon_out" "Vault 不在" 10
t0=$(python3 -c 'import time;print(time.monotonic())')
mv "$DT1_READY" "$DT1_V"
wait_for "$daemon_out" "▶" 10
found_dt1=$?
t1=$(python3 -c 'import time;print(time.monotonic())')
elapsed_dt1="$(python3 -c "print($t1 - $t0)")"
sync_count_dt1="$(python3 -c "
data = open('$daemon_out','rb').read()
print(data.count((chr(27)+'[?2026h').encode()))
")"
kill -TERM "$dt1_pid" 2>/dev/null || true
wait "$dt1_pid" 2>/dev/null
assert_true "DT-1: 復旧後に通常表示が出る" "$([ "$found_dt1" -eq 0 ] && echo 1 || echo 0)"
assert_true "DT-1: 5秒未満で回復" "$(python3 -c "print(1 if $elapsed_dt1 < 5.0 else 0)")"
assert_eq "DT-1: sync-beginが厳密に2回" "2" "$sync_count_dt1"

echo "=== DT-2: cmuxハングの打ち切り・孤児ゼロ・回復 ==="
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
rm -f "$STUB_STATE/hang_pids"
touch "$STUB_STATE/hang_identify"
daemon_out="$WORKDIR/daemon_dt2.out"
: > "$daemon_out"
_before="$(vault_snapshot)"
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=60 CMUX_TASK_FOCUS_INTERVAL=1 CMUX_TASK_CALL_TIMEOUT=2 \
  bash "$TARGET" > "$daemon_out" 2>&1 &
dt2_pid=$!
t0=$(python3 -c 'import time;print(time.monotonic())')
wait_for "$daemon_out" "応答なし" 10
found_dt2_reason=$?
t1=$(python3 -c 'import time;print(time.monotonic())')
elapsed_dt2="$(python3 -c "print($t1 - $t0)")"
alive_dt2="$(kill -0 "$dt2_pid" 2>/dev/null && echo 1 || echo 0)"
sleep 0.3
orphan_free=1
if [ -f "$STUB_STATE/hang_pids" ]; then
  while IFS= read -r hp; do
    [ -n "$hp" ] || continue
    kill -0 "$hp" 2>/dev/null && orphan_free=0
  done < "$STUB_STATE/hang_pids"
fi
rm -f "$STUB_STATE/hang_identify"
wait_for "$daemon_out" "▶" 10
found_dt2_recover=$?
kill -TERM "$dt2_pid" 2>/dev/null || true
wait "$dt2_pid" 2>/dev/null
check_vault_unchanged "DT-2 daemon" "$_before" "$(vault_snapshot)"
assert_true "DT-2①: 打ち切り後5秒以内に理由行" "$([ "$found_dt2_reason" -eq 0 ] && [ "$(python3 -c "print(1 if $elapsed_dt2 < 5.0 else 0)")" = "1" ] && echo 1 || echo 0)"
assert_true "DT-2②: 常駐が生存" "$alive_dt2"
assert_true "DT-2③: 孤児ゼロ" "$orphan_free"
assert_true "DT-2④: hang解除後に通常表示へ回復" "$([ "$found_dt2_recover" -eq 0 ] && echo 1 || echo 0)"

echo "=== AC-44: W-1×T-1: 常駐2ティック後も記録ファイル・mtimeが不変 ==="
reset_stub_state
mk_note_V1 "$VAULT"
mk_decl_single "v1proj" "$STATE_FILE"
before_state="$(cat "$STATE_FILE")"
before_mtime="$(stat -f '%m' "$STATE_FILE")"
_before="$(vault_snapshot)"
sleep 1.1
CMUX_TASK_VAULT="$VAULT" CMUX_TASK_STATE="$STATE_FILE" CMUX_TASK_COLS=40 CMUX_TASK_ROWS=24 \
  CMUX_TASK_INTERVAL=1 CMUX_TASK_FOCUS_INTERVAL=1 \
  bash "$TARGET" > "$WORKDIR/daemon_ac44.out" 2>&1 &
ac44_pid=$!
sleep 2.5
kill -TERM "$ac44_pid" 2>/dev/null || true
wait "$ac44_pid" 2>/dev/null
check_vault_unchanged "AC-44 daemon" "$_before" "$(vault_snapshot)"
after_state="$(cat "$STATE_FILE")"
after_mtime="$(stat -f '%m' "$STATE_FILE")"
assert_eq "AC-44: 記録ファイルの内容が不変" "$before_state" "$after_state"
assert_eq "AC-44: 記録ファイルのmtimeが不変" "$before_mtime" "$after_mtime"

echo "=== AC-33: 全fixture実行を横断してfixture Vaultが不変 ==="
# verifierレビュー1巡目 #4対応: 「最後に作り直したV-1の2実行」だけでなく、
# run_once_plain/run_once_colored・各daemonブロック（AC-24/25/26/44/46・
# DT-2）が $VAULT を使うたびに前後差分を取っていた結果（$VAULT_MUTATION_LOG_FILE）
# を、このファイルが実行した全fixture横断でまとめて判定する。DT-1は意図的
# に別Vault（$DT1_V）を使うため対象外（設計どおり）。
mutation_count="$(wc -l < "$VAULT_MUTATION_LOG_FILE" | tr -d ' ')"
assert_eq "AC-33: 全fixture実行を通してfixture Vaultへの書込が1件も無い" "0" "$mutation_count"

echo "=== AC-34: 全fixture実行を横断して書込系コマンドが1度も呼ばれない ==="
# verifierレビュー1巡目 #4対応: ファイル冒頭から蓄積した集約ログ
# （AGGREGATE_CALLS_LOG。reset_stub_stateで消える$STUB_STATE/calls.logとは
# 別）を使い、このファイルが実行した全fixtureを横断して検査する。
write_cmds="$(grep -cE 'todo|set-status|clear-status|set-progress|workspace status set|new-pane|new-surface' "$AGGREGATE_CALLS_LOG" 2>/dev/null)"
[ -n "$write_cmds" ] || write_cmds=0
assert_eq "AC-34: 全fixture実行を通して書込系コマンドが0件" "0" "$write_cmds"
total_calls="$(wc -l < "$AGGREGATE_CALLS_LOG" | tr -d ' ')"
assert_true "AC-34: 集約ログにcmux呼出が記録されている（検査自体が空振りでない）" "$([ "$total_calls" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
exit $?
