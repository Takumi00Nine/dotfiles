#!/bin/bash
# cmux-next-watch.sh のユニットテスト。tmp配下に fixture Vault を都度生成し、
# --once モードの出力を検証する（実 Vault・実ログには一切依存しない）。
#
# 実行方法: bash tests/test-cmux-next-watch.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../cmux-next-watch.sh"
# mktemp 失敗時は空文字列のまま処理を続けず即座に終了する（Codexレビュー
# 指摘・Major対応: 失敗を無視すると WORKDIR が空になり、以降の
# "$WORKDIR/vault1" 等の生成先がカレントディレクトリ直下の相対パスに化ける
# 恐れがある）。
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-watch-test.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
case "$WORKDIR" in
  "${TMPDIR:-/tmp}"/cmux-next-watch-test.*) : ;;
  *)
    echo "FATAL: WORKDIRが想定外のパスです: $WORKDIR" >&2
    exit 1
    ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

# ANSIエスケープ（色コード）を取り除いたプレーンテキストを標準出力へ返す。
strip_ansi() {
  python3 -c "
import re, sys
esc = chr(27)
pat = re.compile(esc + r'\[[0-9;]*m')
sys.stdout.write(pat.sub('', sys.stdin.read()))
"
}

# $1 に \033 のような実エスケープバイトがそのまま含まれているか判定する
# （注入対策の検証用：無害化されていればこの関数は失敗＝真の ESC が無い）。
contains_raw_esc() {
  python3 -c "
import sys
data = sys.stdin.read()
sys.exit(0 if chr(27) in data else 1)
"
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

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    PASS=$(( PASS + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "FAIL: $desc"
  fi
}

# 行の並び順（配列的に渡した行番号順）を検証する。$1=プレーンテキスト全体、
# 以降は「先に出現すべき順」の文字列。
assert_order() {
  local desc="$1" text="$2"; shift 2
  local prev_line=-1 tok line ok=1
  for tok in "$@"; do
    line="$(printf '%s\n' "$text" | grep -n -F -- "$tok" | head -n1 | cut -d: -f1)"
    if [ -z "$line" ]; then
      ok=0
      break
    fi
    if [ "$line" -le "$prev_line" ]; then
      ok=0
      break
    fi
    prev_line="$line"
  done
  assert_true "$desc" "$ok"
}

# 1つの fixture Vault を組み立てる（複数テストで共用）。
build_fixture_vault() {
  local vault="$1"
  mkdir -p "$vault/Projects"

  cat >"$vault/Projects/proj-active.md" <<'EOF'
---
date: 2026-07-01
updated: 2026-07-30
status: active
next: 実データ照合を回す
---
# active
EOF

  cat >"$vault/Projects/proj-newer-noNext.md" <<'EOF'
---
date: 2026-07-01
updated: 2026-08-01
status: active
---
# next未設定のはず
EOF

  cat >"$vault/Projects/proj-excluded-status.md" <<'EOF'
---
date: 2026-07-01
status: completed
next: これは出ないはず
---
# 許可リスト外のstatusなので除外
EOF

  cat >"$vault/Projects/proj-nodate.md" <<'EOF'
---
status: paused
next: 日付なしプロジェクト
---
# 保留グループ・updated/date どちらも無い（末尾の保留セクションに来るはず）
EOF

  cat >"$vault/Projects/proj-quoted.md" <<'EOF'
---
date: 2026-07-01
updated: 2026-08-02
status: active
next: "配布方式のたたき台を書く"
---
# next値がダブルクォート付き
EOF

  cat >"$vault/Projects/README.md" <<'EOF'
frontmatterが無いファイル（statusも無いので除外されるはず）
EOF
}

echo "=== fixture: 基本Vault ==="
V1="$WORKDIR/vault1"
build_fixture_vault "$V1"
OUT1="$(CMUX_NEXT_VAULT="$V1" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once)"
PLAIN1="$(printf '%s' "$OUT1" | strip_ansi)"

assert_contains "稼働中セクションに active の3件がカウントされる" "$PLAIN1" "▶ 稼働中 (3)"
assert_contains "保留セクションに paused の1件がカウントされる" "$PLAIN1" "⏸ 保留 (1)"
assert_not_contains "statusが対象外（completed）のノートのnextは出ない" "$PLAIN1" "これは出ないはず"
assert_not_contains "README.md（frontmatterなし）は出ない" "$PLAIN1" "README"
assert_contains "next未設定は (next未設定) と表示される" "$PLAIN1" "(next未設定)"
assert_contains "next値のダブルクォートが剥がされる" "$PLAIN1" "配布方式のたたき台を書く"
assert_not_contains "next値のダブルクォートそのものは残らない" "$PLAIN1" '"配布方式のたたき台を書く"'
assert_order "updated（無ければdate）降順で並ぶ・未設定は最後" "$PLAIN1" \
  "配布方式のたたき台を書く" "(next未設定)" "実データ照合を回す" "日付なしプロジェクト"
assert_not_contains "棚卸し・週次どちらもデータ源が無ければ棚卸し行は出ない" "$PLAIN1" "棚卸し"
assert_not_contains "週次メンテ状態ファイルが無い時はこの行を省略する" "$PLAIN1" "週次"
assert_not_contains "外部脳データ源が両方無ければブロック（見出し含む）ごと非表示" "$PLAIN1" "外部脳"

echo "=== fixture: 名前の10文字切り詰め（省略記号なし） ==="
V2="$WORKDIR/vault2"
mkdir -p "$V2/Projects"
cat >"$V2/Projects/very-long-project-name-here.md" <<'EOF'
---
date: 2026-08-01
updated: 2026-08-01
status: active
next: x
---
EOF
OUT2="$(CMUX_NEXT_VAULT="$V2" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "ファイル名は先頭10文字に切り詰められる" "$OUT2" "very-long-"
assert_not_contains "11文字目以降は出ない" "$OUT2" "very-long-p"

echo "=== fixture: エスケープシーケンス注入対策 ==="
V3="$WORKDIR/vault3"
mkdir -p "$V3/Projects"
python3 - "$V3/Projects/proj-injection.md" <<'PYEOF'
import sys
esc = chr(27)
content = "---\ndate: 2026-07-01\nupdated: 2026-08-03\nstatus: active\nnext: evil" + esc + "[31mRED" + esc + "[0m text\n---\n"
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(content)
PYEOF
RAW3="$(CMUX_NEXT_VAULT="$V3" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once)"
# next値の行を抽出（自スクリプトが付与する色ANSIは残る想定なので全体からは
# 判定できない。next値部分だけ見るため、色コードを除去したうえで
# 元のESCバイトが1つも残っていないことを確認する）。
PLAIN3="$(printf '%s' "$RAW3" | strip_ansi)"
if printf '%s' "$PLAIN3" | contains_raw_esc; then
  FAIL=$(( FAIL + 1 ))
  echo "FAIL: next値中のESCバイトが無害化されずに残っている"
else
  PASS=$(( PASS + 1 ))
fi
assert_contains "無害化後もテキスト自体は表示される" "$PLAIN3" "evil [31mRED [0m text"

echo "=== fixture: 端末幅での行全体の切り詰め ==="
V4="$WORKDIR/vault4"
mkdir -p "$V4/Projects"
cat >"$V4/Projects/proj-overflow.md" <<'EOF'
---
date: 2026-08-04
updated: 2026-08-04
status: active
next: これは非常に長いnextテキストで端末幅を確実に超えるように書いています
---
EOF
OUT4="$(CMUX_NEXT_VAULT="$V4" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
LINE4="$(printf '%s\n' "$OUT4" | grep -E '^[0-9]+ proj-overf')"
LEN4="$(python3 -c "import sys; print(len(sys.argv[1]))" "$LINE4")"
if [ -n "$LINE4" ] && [ "$LEN4" -le 40 ]; then
  PASS=$(( PASS + 1 ))
else
  FAIL=$(( FAIL + 1 ))
  echo "FAIL: 端末幅超過時に行が40コードポイント以内に切り詰められていない（実測: ${LEN4:-なし}）"
fi
assert_contains "切り詰め時は省略記号が付く" "$LINE4" "…"

echo "=== fixture: 閉じフェンスが無い壊れたnoteは frontmatter を誤検出しない ==="
V6="$WORKDIR/vault6"
mkdir -p "$V6/Projects"
# 冒頭は正しい "---" だが閉じフェンスが無いまま本文が続くファイル。本文中に
# 偶然 status:/next: と読めてしまう行があっても、これはfrontmatterとして
# 採用してはいけない（受入条件「本文中のnext:等を誤検出しない」の検証）。
cat >"$V6/Projects/proj-no-closing-fence.md" <<'EOF'
---
date: 2026-07-01
本文がここから始まるが閉じフェンスが無い
status: active
next: 本文中の偽next（誤検出してはいけない）
EOF
OUT6B="$(CMUX_NEXT_VAULT="$V6" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "閉じフェンスが無いnoteはNext対象0件になる" "$OUT6B" "▶ 稼働中 (0)"
assert_not_contains "本文中の偽next値は表示されない" "$OUT6B" "本文中の偽next"

echo "=== fixture: frontmatterが無いnoteの本文中のstatus:/next:は誤検出しない ==="
V7="$WORKDIR/vault7"
mkdir -p "$V7/Projects"
cat >"$V7/Projects/proj-no-frontmatter.md" <<'EOF'
# frontmatterが全く無いノート
status: active
next: これも誤検出してはいけない
EOF
OUT7B="$(CMUX_NEXT_VAULT="$V7" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "frontmatterが無いnoteはNext対象0件になる" "$OUT7B" "▶ 稼働中 (0)"
assert_not_contains "本文中のnext値は表示されない" "$OUT7B" "これも誤検出してはいけない"

echo "=== fixture: 正常な閉じフェンス後、本文に別の---があっても誤検出しない ==="
V8="$WORKDIR/vault8"
mkdir -p "$V8/Projects"
cat >"$V8/Projects/proj-extra-fence.md" <<'EOF'
---
date: 2026-07-01
updated: 2026-08-01
status: active
next: 正しいnext値
---
# 本文
---
next: 本文の水平線の後にある偽next（誤検出してはいけない）
EOF
OUT8B="$(CMUX_NEXT_VAULT="$V8" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "1つ目の閉じフェンス内のnext値だけを使う" "$OUT8B" "正しいnext値"
assert_not_contains "本文中の2つ目以降の---より後のnextは使わない" "$OUT8B" "本文の水平線の後にある偽next"

echo "=== fixture: ファイル名に制御文字（ESC）が含まれていても無害化される ==="
V9="$WORKDIR/vault9"
mkdir -p "$V9/Projects"
python3 - "$V9/Projects" <<'PYEOF'
import sys, os
d = sys.argv[1]
esc = chr(27)
name = "proj-esc" + esc + "[31mname.md"
path = os.path.join(d, name)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("---\ndate: 2026-07-01\nupdated: 2026-08-01\nstatus: active\nnext: x\n---\n")
PYEOF
RAW9="$(CMUX_NEXT_VAULT="$V9" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once)"
PLAIN9="$(printf '%s' "$RAW9" | strip_ansi)"
if printf '%s' "$PLAIN9" | contains_raw_esc; then
  FAIL=$(( FAIL + 1 ))
  echo "FAIL: ファイル名中のESCバイトが無害化されずに残っている"
else
  PASS=$(( PASS + 1 ))
fi
assert_contains "ESCを含むファイル名でもNext対象1件として表示される" "$PLAIN9" "▶ 稼働中 (1)"

echo "=== fixture: ファイル名にTAB/LFが含まれていてもTSVレコード境界が壊れない ==="
V10="$WORKDIR/vault10"
mkdir -p "$V10/Projects"
# macOS(APFS)では '/' とNULを除き任意バイトがファイル名に使える。TAB/LFは
# tmpfile（TSV）のフィールド・レコード境界そのものに使う文字なので、書き込み
# 前にサニタイズされていないと余分な行やフィールドずれとして出現しうる
# （Codexレビュー指摘・Major対応の再検証）。
python3 - "$V10/Projects" <<'PYEOF'
import sys, os
d = sys.argv[1]
name = "weird" + chr(9) + "tab" + chr(10) + "newline.md"
path = os.path.join(d, name)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("---\ndate: 2026-07-01\nupdated: 2026-08-01\nstatus: active\nnext: ok\n---\n")
PYEOF
OUT10="$(CMUX_NEXT_VAULT="$V10" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
NLINES10="$(printf '%s\n' "$OUT10" | wc -l | tr -d ' ')"
assert_contains "TAB/LF入りファイル名でもNext対象1件と数える" "$OUT10" "▶ 稼働中 (1)"
assert_contains "next値は正常表示される（フィールドずれが無い）" "$OUT10" " ok"
# 想定行数: ヘッダー1 + 明細1 + 空行1 + 外部脳ヘッダー1 (+棚卸し等の行は
# 対象ディレクトリが無いので棚卸しn/aの1行のみ) = 5行。TAB/LFが無害化されず
# レコードが割れていれば行数が想定より増える。
if [ "$NLINES10" -le 5 ]; then
  PASS=$(( PASS + 1 ))
else
  FAIL=$(( FAIL + 1 ))
  echo "FAIL: TAB/LF入りファイル名でTSVレコードが分裂し、想定より行数が多い（実測: ${NLINES10}行）"
fi

echo "=== fixture: 桁数だけ合った偽日付は並び順・棚卸しどちらにも使われない ==="
V11="$WORKDIR/vault11"
mkdir -p "$V11/Projects"
cat >"$V11/Projects/proj-fakeupdated.md" <<'EOF'
---
date: 2026-07-15
updated: 9999-99-99
status: active
next: 不正なupdated値を持つノート
---
EOF
cat >"$V11/Projects/proj-realupdated.md" <<'EOF'
---
date: 2026-07-01
updated: 2026-07-20
status: active
next: 正しいupdated値を持つノート
---
EOF
INV_FAKE="$WORKDIR/inventory-fake"
mkdir -p "$INV_FAKE"
cat >"$INV_FAKE/2026-08-05.md" <<'EOF'
自動生成。要確認 3 件。
EOF
cat >"$INV_FAKE/9999-99-99.md" <<'EOF'
偽日付ファイル。要確認 777 件と誤読させようとする罠。
EOF
OUT11="$(CMUX_NEXT_VAULT="$V11" CMUX_NEXT_INVENTORY_DIR="$INV_FAKE" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_order "不正なupdated（9999-99-99）は date へフォールバックし、正しいupdated値のノートより後に並ぶ" \
  "$OUT11" "正しいupdated値を持つノート" "不正なupdated値を持つノート"
assert_contains "棚卸しは実在する暦日のファイル名だけを候補にする（9999-99-99は無視）" "$OUT11" "要確認3件"
assert_not_contains "偽日付ファイルの件数は使わない" "$OUT11" "777件"

echo "=== fixture: 存在しない暦日（BSD dateが黙って正規化する値）も偽日付扱いされる ==="
# BSD date -j -f は "2026-02-30" のような存在しない日付を"2026-03-02"へ黙って
# 正規化して成功してしまう。桁数チェック＋成功可否だけでは弾けないため、
# is_valid_date の往復一致チェックで正しく拒否できることを確認する
# （Codex再レビュー指摘・Minor対応の検証）。
V12="$WORKDIR/vault12"
mkdir -p "$V12/Projects"
cat >"$V12/Projects/proj-feb30.md" <<'EOF'
---
date: 2026-01-01
updated: 2026-02-30
status: active
next: 存在しない日付(2026-02-30)を持つノート
---
EOF
cat >"$V12/Projects/proj-real2.md" <<'EOF'
---
date: 2026-01-01
updated: 2026-02-10
status: active
next: 実在する日付を持つノート
---
EOF
INV_FEB30="$WORKDIR/inventory-feb30"
mkdir -p "$INV_FEB30"
# 正常ファイルはあえて偽日付(2026-02-30)より辞書順で「古い」名前
# (2026-02-05)にする。is_valid_date の除外が効いていなければ、辞書順だけで
# 2026-02-30が「最新」として誤って選ばれてしまうため、このテストは除外ロジ
# ックが壊れると確実に失敗する（Codex再々レビュー指摘・Minor対応）。
cat >"$INV_FEB30/2026-02-05.md" <<'EOF'
自動生成。要確認 5 件。
EOF
cat >"$INV_FEB30/2026-02-30.md" <<'EOF'
存在しない日付のファイル。要確認 888 件と誤読させようとする罠。
EOF
OUT12="$(CMUX_NEXT_VAULT="$V12" CMUX_NEXT_INVENTORY_DIR="$INV_FEB30" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_order "存在しない日付updated(2026-02-30)はdateへフォールバックし date(2026-01-01)扱いで最後に並ぶ" \
  "$OUT12" "実在する日付を持つノート" "存在しない日付"
assert_contains "棚卸しは実在する2026-02-05を最新として使う（辞書順で新しい2026-02-30には丸め込まれない）" "$OUT12" "要確認5件"
assert_not_contains "存在しない日付ファイルの件数は使わない" "$OUT12" "888件"

echo "=== fixture: 外部脳ヘルス（棚卸し・週次） ==="
INV_OK="$WORKDIR/inventory-ok"
mkdir -p "$INV_OK"
cat >"$INV_OK/2026-08-01.md" <<'EOF'
古い棚卸し。要確認 99 件。
EOF
cat >"$INV_OK/2026-08-05.md" <<'EOF'
自動生成。ノート312件を検査し、要確認 15 件。
EOF
MAINT_OK="$WORKDIR/maint-ok.json"
cat >"$MAINT_OK" <<'EOF'
{"last_success_at": "2026-08-05T11:13:16Z", "started_at": "2026-08-05T11:06:09Z"}
EOF
V5="$WORKDIR/vault5"
mkdir -p "$V5/Projects"
OUT5="$(CMUX_NEXT_VAULT="$V5" CMUX_NEXT_INVENTORY_DIR="$INV_OK" \
  CMUX_NEXT_MAINT_STATE="$MAINT_OK" "$TARGET" --once | strip_ansi)"
assert_contains "棚卸しは名前順最新ファイル（8/5）の件数を拾う（8/1の99件ではない）" "$OUT5" "要確認15件 (8/5)"
assert_not_contains "古い棚卸しファイルの件数は使わない" "$OUT5" "99件"
assert_contains "週次メンテが新しければ✅表示" "$OUT5" "週次 ✅"

echo "=== fixture: 棚卸し抽出失敗はn/a ==="
INV_BROKEN="$WORKDIR/inventory-broken"
mkdir -p "$INV_BROKEN"
cat >"$INV_BROKEN/2026-08-05.md" <<'EOF'
壊れたレポート（要確認パターンなし）
EOF
OUT6="$(CMUX_NEXT_VAULT="$V5" CMUX_NEXT_INVENTORY_DIR="$INV_BROKEN" \
  CMUX_NEXT_MAINT_STATE="$MAINT_OK" "$TARGET" --once | strip_ansi)"
assert_contains "要確認パターンが見つからない時はn/a" "$OUT6" "棚卸し n/a"

echo "=== fixture: 週次メンテが古い（8日以上）と⚠表示 ==="
MAINT_STALE="$WORKDIR/maint-stale.json"
python3 - "$MAINT_STALE" <<'PYEOF'
import json, sys, time
old = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 10 * 86400))
with open(sys.argv[1], "w") as fh:
    json.dump({"last_success_at": old, "started_at": old}, fh)
PYEOF
OUT7="$(CMUX_NEXT_VAULT="$V5" CMUX_NEXT_INVENTORY_DIR="$INV_BROKEN" \
  CMUX_NEXT_MAINT_STATE="$MAINT_STALE" "$TARGET" --once | strip_ansi)"
assert_contains "10日前の週次メンテは⚠10日前と表示される" "$OUT7" "週次 ⚠10日前"
assert_contains "警告が1つでもあればヘッダーは⚠ 外部脳" "$OUT7" "⚠ 外部脳"

echo "=== 新仕様: 棚卸しディレクトリ無し・週次のみデータあり→棚卸し行は出ず週次行のみ表示 ==="
OUT_MAINTONLY="$(CMUX_NEXT_VAULT="$V5" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/inventory-no-such-dir" CMUX_NEXT_MAINT_STATE="$MAINT_OK" "$TARGET" --once | strip_ansi)"
assert_not_contains "棚卸しのデータ源（ディレクトリ）が無ければ棚卸し行は出ない" "$OUT_MAINTONLY" "棚卸し"
assert_contains "週次のみデータありなら週次行は表示される" "$OUT_MAINTONLY" "週次 ✅"
assert_contains "片方でもデータ源があればブロック自体（見出し）は出る" "$OUT_MAINTONLY" "✅ 外部脳"

echo "=== fixture: 両方正常ならヘッダーは✅ 外部脳 ==="
INV_ZERO="$WORKDIR/inventory-zero2"
mkdir -p "$INV_ZERO"
cat >"$INV_ZERO/2026-08-05.md" <<'EOF'
自動生成。要確認 0 件。
EOF
OUT8="$(CMUX_NEXT_VAULT="$V5" CMUX_NEXT_INVENTORY_DIR="$INV_ZERO" CMUX_NEXT_MAINT_STATE="$MAINT_OK" "$TARGET" --once | strip_ansi)"
assert_contains "棚卸し0件は要確認0件と表示" "$OUT8" "要確認0件"
assert_contains "棚卸し0件・週次新しい→ヘッダーは✅ 外部脳" "$OUT8" "✅ 外部脳"

echo "=== 新仕様: Projectsディレクトリが空でも稼働中(0)/保留(0)見出しが必ず出る ==="
V13="$WORKDIR/vault13-empty-projects"
mkdir -p "$V13/Projects"
OUT13="$(CMUX_NEXT_VAULT="$V13" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "Projects空でも稼働中(0)見出しが出る" "$OUT13" "▶ 稼働中 (0)"
assert_contains "Projects空でも保留(0)見出しが出る" "$OUT13" "⏸ 保留 (0)"

echo "=== 新仕様: Projectsディレクトリ自体が無くても稼働中(0)/保留(0)見出しが出る ==="
V14="$WORKDIR/vault14-no-projects-dir"
mkdir -p "$V14"
OUT14="$(CMUX_NEXT_VAULT="$V14" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "Projectsディレクトリ不在でも稼働中(0)見出しが出る" "$OUT14" "▶ 稼働中 (0)"
assert_contains "Projectsディレクトリ不在でも保留(0)見出しが出る" "$OUT14" "⏸ 保留 (0)"

echo "=== 新仕様: 保留のみ・稼働中0件でも両見出しが出る ==="
V15="$WORKDIR/vault15-hold-only"
mkdir -p "$V15/Projects"
cat >"$V15/Projects/proj-hold-only.md" <<'EOF'
---
date: 2026-07-01
status: paused
next: 保留のみのケース
---
EOF
OUT15="$(CMUX_NEXT_VAULT="$V15" CMUX_NEXT_INVENTORY_DIR="$WORKDIR/no-such-inventory" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "保留のみでも稼働中(0)見出しが出る" "$OUT15" "▶ 稼働中 (0)"
assert_contains "保留のみでは保留(1)見出しが出る" "$OUT15" "⏸ 保留 (1)"
assert_contains "保留のみのnext値が表示される" "$OUT15" "保留のみのケース"

echo "=== 新仕様: 外部脳データ源が両方無ければブロック（見出し含む）ごと非表示 ==="
assert_not_contains "棚卸し行が出ない（データ源なし・Projects空fixture流用）" "$OUT13" "棚卸し"
assert_not_contains "週次行が出ない（データ源なし）" "$OUT13" "週次"
assert_not_contains "外部脳ヘッダー(✅)も出ない" "$OUT13" "✅ 外部脳"
assert_not_contains "外部脳ヘッダー(⚠)も出ない" "$OUT13" "⚠ 外部脳"

echo "=== 新仕様: 棚卸しのみデータあり（週次は状態ファイル無し）→棚卸し行のみ表示 ==="
INV_ONLY="$WORKDIR/inventory-only"
mkdir -p "$INV_ONLY"
cat >"$INV_ONLY/2026-08-05.md" <<'EOF'
自動生成。要確認 2 件。
EOF
OUT16="$(CMUX_NEXT_VAULT="$V5" CMUX_NEXT_INVENTORY_DIR="$INV_ONLY" \
  CMUX_NEXT_MAINT_STATE="$WORKDIR/no-such-maint.json" "$TARGET" --once | strip_ansi)"
assert_contains "棚卸しのみデータありなら棚卸し行が出る" "$OUT16" "要確認2件"
assert_not_contains "週次のデータ源（状態ファイル）が無ければ週次行は出ない" "$OUT16" "週次"
assert_contains "片方でもデータ源があればブロック自体（見出し）は出る" "$OUT16" "外部脳"

echo "=== fixture: jqが無い環境ではERRを出す ==="
STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
# jqを含まない最小限のPATHで実行し、依存不足時に例外終了せずERR表示する
# ことを確認する（cmux-usage-watch.sh等と同じ防御パターン）。
OUT9="$(PATH="/usr/bin:/bin" CMUX_NEXT_VAULT="$V5" "$TARGET" --once 2>&1)"
if command -v jq >/dev/null 2>&1 && [ ! -x "/usr/bin/jq" ] && [ ! -x "/bin/jq" ]; then
  assert_contains "jq未検出時はERRメッセージを出す" "$OUT9" "ERR"
else
  echo "SKIP: このホストの /usr/bin または /bin に jq があるため、jq不在ケースは検証できません"
fi

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
