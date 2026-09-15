#!/bin/bash
# lib-supply-frame.sh のユニットテスト（cmux-session-todo 設計 v3・RF層）。
# 実Vault・実cmux・実ai-envに依存しない（呼び出し口はP群スタブ）。
#
# 実行方法: bash cmux/tests/test-supply-frame.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DOCK_VIEW="$SCRIPT_DIR/../lib-dock-view.sh"
LIB_SUPPLY="$SCRIPT_DIR/../lib-supply-frame.sh"
LIB_STUBS="$SCRIPT_DIR/lib-supply-stubs.sh"

for f in "$LIB_DOCK_VIEW" "$LIB_SUPPLY" "$LIB_STUBS"; do
  [ -r "$f" ] || { echo "FATAL: 見つかりません: $f" >&2; exit 1; }
done
. "$LIB_DOCK_VIEW"
. "$LIB_SUPPLY"
. "$LIB_STUBS"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-supply-frame.XXXXXX")" || {
  echo "FATAL: mktemp -d に失敗しました" >&2
  exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT

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

# 足跡の3種別が揃うのを待つ（AC-123の申し送り＝0.1秒間隔・上限10秒）。
wait_for_footprints() {
  local fp="$1" limit="${2:-10}" waited=0
  while :; do
    if [ -s "$fp" ]; then
      local has_main=0 has_child=0 has_watchdog=0 k
      while IFS="$(printf '\t')" read -r k _ _; do
        case "$k" in
          main) has_main=1 ;;
          child) has_child=1 ;;
          watchdog) has_watchdog=1 ;;
        esac
      done < "$fp"
      [ "$has_main" = 1 ] && [ "$has_child" = 1 ] && [ "$has_watchdog" = 1 ] && return 0
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
    [ "$waited" -ge $(( limit * 10 )) ] && return 1
  done
}

footprints_all_dead() {
  local fp="$1" alive=0
  while IFS="$(printf '\t')" read -r _ pid _; do
    kill -0 "$pid" 2>/dev/null && alive=$(( alive + 1 ))
  done < "$fp"
  [ "$alive" -eq 0 ] && echo 1 || echo 0
}

now_mono() { python3 -c 'import time; print(time.monotonic())'; }

echo "=== validate_frame（正常系・境界・P-23/P-24） ==="

mk_stub_P6_task "$WORKDIR/p6task"
"$WORKDIR/p6task" --frame > "$WORKDIR/p6task.raw"
validate_frame Task "$WORKDIR/p6task.raw" "$WORKDIR/p6task.model"
assert_eq "P-6 Task は通常(rc=0)" "0" "$?"
assert_eq "P-6 Task の本体行数は8" "8" "$(wc -l < "$WORKDIR/p6task.model" | tr -d ' ')"

mk_stub_P6_project "$WORKDIR/p6proj" 5 6 7
"$WORKDIR/p6proj" --frame > "$WORKDIR/p6proj.raw"
validate_frame Project "$WORKDIR/p6proj.raw" "$WORKDIR/p6proj.model"
assert_eq "P-6 Project は通常(rc=0)" "0" "$?"

# 空のProjectフレーム（P*・B*とも0行）はFR-82#5どおり正当（検証1巡目#8の
# 回帰・検証2巡目#25①）。差し戻すと body_n==0 を一律拒否してしまい、
# Vault/外部脳ともに空のときの「稼働中(0)/保留(0)」描画ができなくなる。
{
  printf '#V\tcmux-dock-frame/1\tProject\n'
  printf 'E\t0\n'
} > "$WORKDIR/p6proj_empty.raw"
validate_frame Project "$WORKDIR/p6proj_empty.raw" "$WORKDIR/p6proj_empty.model"
assert_eq "空のProjectフレーム(P*B*とも0行)は通常(rc=0・検証1巡目#8の回帰)" "0" "$?"
assert_eq "空のProjectフレームの本体行数は0" "0" "$(wc -l < "$WORKDIR/p6proj_empty.model" | tr -d ' ')"

mk_stub_P23 "$WORKDIR/p23"
"$WORKDIR/p23" --frame > "$WORKDIR/p23.raw"
validate_frame Task "$WORKDIR/p23.raw" "$WORKDIR/p23.model"
assert_eq "P-23(全版完了)は通常(rc=0)・縮退しない(AC-124①)" "0" "$?"

mk_stub_P24 "$WORKDIR/p24"
"$WORKDIR/p24" --frame > "$WORKDIR/p24.raw"
validate_frame Task "$WORKDIR/p24.raw" "$WORKDIR/p24.model"
assert_eq "P-24([/]無し)は通常(rc=0)・縮退しない(AC-124②)" "0" "$?"

mk_stub_P25a "$WORKDIR/p25a"
"$WORKDIR/p25a" --frame > "$WORKDIR/p25a.raw"
assert_eq "P-25aはちょうど65536バイト" "65536" "$(wc -c < "$WORKDIR/p25a.raw" | tr -d ' ')"
validate_frame Task "$WORKDIR/p25a.raw" "$WORKDIR/p25a.model"
assert_eq "P-25a(ちょうど65536バイト)は受理(rc=0・AC-122①)" "0" "$?"

mk_stub_P25b "$WORKDIR/p25b"
"$WORKDIR/p25b" --frame > "$WORKDIR/p25b.raw"
assert_eq "P-25bはちょうど1000行" "1000" "$(wc -l < "$WORKDIR/p25b.raw" | tr -d ' ')"
validate_frame Task "$WORKDIR/p25b.raw" "$WORKDIR/p25b.model"
assert_eq "P-25b(ちょうど1000行)は受理(rc=0・AC-122②)" "0" "$?"

echo "=== validate_frame（DT-12・正当な空欄を含むフレーム） ==="

{
  printf '#V\tcmux-dock-frame/1\tTask\n'
  # ヘッダーの分数は「完了した版数/版数」(ここは1/1)。版自身の分数(3/3)とは別物。
  printf 'H\t✅\tcmux-session-todo\t全版完了\t\t1/1\n'   # 版名が空（全版完了時の既定）
  printf 'V\tv1\t✅\t3/3\n'
  printf 'X\t-\n'
  printf 'E\t3\n'
} > "$WORKDIR/dt12_h.raw"
validate_frame Task "$WORKDIR/dt12_h.raw" "$WORKDIR/dt12_h.model"
assert_eq "DT-12: Hの空の版名を含む正当フレームは受理" "0" "$?"

{
  printf '#V\tcmux-dock-frame/1\tProject\n'
  printf 'P\t1\tproj-a\t\t稼働中\n'   # next値が空
  printf 'E\t1\n'
} > "$WORKDIR/dt12_p.raw"
validate_frame Project "$WORKDIR/dt12_p.raw" "$WORKDIR/dt12_p.model"
assert_eq "DT-12: Pの空のnext値を含む正当フレームは受理" "0" "$?"

# コメント行（先頭が#）を除いた実コード行にだけ現れないことを見る
# （コメント中の「使わない」という説明自体は不使用の証拠として許容する）。
if grep -v '^[[:space:]]*#' "$LIB_SUPPLY" | grep -qF 'IFS=$'"'"'\t'"'"' read'; then
  DT12_STATIC=0
else
  DT12_STATIC=1
fi
assert_true "DT-12: 欄の分解に while IFS=\$'\\t' read が使われていない（静的・実コード行のみ）" "$DT12_STATIC"

echo "=== validate_frame（45サブID・AC-111・P-4は版ちがい） ==="

mk_stub_P4 "$WORKDIR/p4" Task
"$WORKDIR/p4" --frame > "$WORKDIR/p4.raw"
validate_frame Task "$WORKDIR/p4.raw" "$WORKDIR/p4.model"
assert_eq "P-4(版が未知)はAI環境 版ちがい相当(rc=2)" "2" "$?"

VIOLATION_FAIL=0
IMPLEMENTED_IDS=()
for id in "${SUPPLY_VIOLATION_IDS[@]}"; do
  path="$WORKDIR/v_$id"
  case "$id" in
    P-14d|P-14e)
      # 終わりなく出し続ける変種＝直接captureせずrun_supply自身の
      # limiterで打ち切られることを見る（下のP-20a/P-20bの検査と同型）。
      mk_stub_P_violation "$path" "$id" 2>/dev/null || { VIOLATION_FAIL=$(( VIOLATION_FAIL + 1 )); continue; }
      SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
      run_supply "$path" 5
      rc=$?
      if [ "$rc" -eq 1 ]; then IMPLEMENTED_IDS+=("$id"); else VIOLATION_FAIL=$(( VIOLATION_FAIL + 1 )); echo "  違反していないID: $id (rc=$rc)"; fi
      continue
      ;;
  esac
  mk_stub_P_violation "$path" "$id" 2>/dev/null || { VIOLATION_FAIL=$(( VIOLATION_FAIL + 1 )); continue; }
  "$path" --frame > "${path}.raw" 2>/dev/null
  kind="Task"
  case "$id" in P-12b|P-12c|P-19a|P-19b) kind="Project" ;; esac
  validate_frame "$kind" "${path}.raw" "${path}.model"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    IMPLEMENTED_IDS+=("$id")
  else
    VIOLATION_FAIL=$(( VIOLATION_FAIL + 1 ))
    echo "  違反していないID: $id (rc=$rc)"
  fi
done
assert_eq "45サブIDすべてが応答なし(rc=3)になる" "0" "$VIOLATION_FAIL"

VARIANT_FAIL=0
for id in "${SUPPLY_VIOLATION_VARIANTS[@]}"; do
  path="$WORKDIR/vv_$id"
  mk_stub_P_violation "$path" "$id" 2>/dev/null || { VARIANT_FAIL=$(( VARIANT_FAIL + 1 )); continue; }
  "$path" --frame > "${path}.raw" 2>/dev/null
  validate_frame Task "${path}.raw" "${path}.model"
  [ "$?" -eq 3 ] || { VARIANT_FAIL=$(( VARIANT_FAIL + 1 )); echo "  変種が違反していない: $id"; }
done
assert_eq "P-14b/P-14cの内側の変種(UTF-8状態機械の全分岐)がすべて応答なし" "0" "$VARIANT_FAIL"

EXPECT_SORTED="$(printf '%s\n' "${SUPPLY_VIOLATION_IDS[@]}" | sort -u)"
ACTUAL_SORTED="$(printf '%s\n' "${IMPLEMENTED_IDS[@]}" | sort -u)"
assert_eq "AC-111: 実装したケースのサブID集合が45件の集合と完全一致" "$EXPECT_SORTED" "$ACTUAL_SORTED"
assert_eq "サブID集合はちょうど45件" "45" "$(printf '%s\n' "${SUPPLY_VIOLATION_IDS[@]}" | sort -u | wc -l | tr -d ' ')"

echo "=== DT-8（判定順の分離） ==="

{
  printf '#V\tcmux-dock-frame/1\tTask\n'
  printf '#V\tunknown-v9\tTask\n'
  printf 'E\t1\n'
} > "$WORKDIR/dt8_1.raw"
validate_frame Task "$WORKDIR/dt8_1.raw" "$WORKDIR/dt8_1.model"
assert_eq "DT-8①: #Vが2行＋版が未知でも応答なし(S2優先・rc=3)" "3" "$?"

{
  printf '#V\tunknown-v9\n'
  printf 'E\t0\n'
} > "$WORKDIR/dt8_2.raw"
validate_frame Task "$WORKDIR/dt8_2.raw" "$WORKDIR/dt8_2.model"
assert_eq "DT-8②: #Vの欄数が2は応答なし(S2b優先・rc=3)" "3" "$?"

# DT-8③: 版が未知＋S4違反(種別不一致)の併発→版ちがい
{
  printf '#V\tunknown-v9\tProject\n'
  printf 'E\t0\n'
} > "$WORKDIR/dt8_3a.raw"
validate_frame Task "$WORKDIR/dt8_3a.raw" "$WORKDIR/dt8_3a.model"
assert_eq "DT-8③a: 版未知+種別不一致併発→版ちがい(rc=2)" "2" "$?"

{
  printf '#V\tunknown-v9\tTask\textra\n'
  printf 'E\t0\n'
} > "$WORKDIR/dt8_3b.raw"
validate_frame Task "$WORKDIR/dt8_3b.raw" "$WORKDIR/dt8_3b.model"
assert_eq "DT-8③b: 版未知だが#V自体の欄数不正→S2b優先で応答なし(rc=3)" "3" "$?"

echo "=== run_supply（P-1・P-2・P-15・締切・後始末） ==="

mk_stub_P1a "$WORKDIR/p1a"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
run_supply "$WORKDIR/p1a" 5
assert_eq "P-1a(不在)はrc=10(未導入)" "10" "$?"

mk_stub_P1b "$WORKDIR/p1b"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
run_supply "$WORKDIR/p1b" 5
assert_eq "P-1b(実行不可)はrc=10(未導入・非0実行と誤判定しない＝AC-92)" "10" "$?"

mk_stub_P2 "$WORKDIR/p2"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
run_supply "$WORKDIR/p2" 5
assert_eq "P-2(非0終了)はrc=1(応答なし)" "1" "$?"

mk_stub_P15 "$WORKDIR/p15"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
run_supply "$WORKDIR/p15" 5
assert_eq "P-15(rc=0で0バイト)はrc=1(応答なし)" "1" "$?"

echo "=== run_supply（300回連続・stderr 0バイト・検証5巡目 #46の回帰） ==="
# set -m でジョブ制御を有効にした直後にfork+forkすると、子が既にexecを
# 終えているタイミングでbash自身のsetpgidがEPERMになり「child setpgid
# (...): Operation not permitted」をこのシェルの現在のstderrへ直接出す
# ことがある（disownでは止められない・発生率は数百回に1回程度）。
# lib-supply-frame.shのfork文2つを{ }2>/dev/nullで包んで隔離した
# （PGID一括終了の性質はDT-13/DT-14/AC-95/AC-123の既存テストが別途保証）。
mk_stub_P6_task "$WORKDIR/stress_p6"
STRESS_ERR="$WORKDIR/run_supply_stress.err"
: > "$STRESS_ERR"
(
  for ((_i = 0; _i < 300; _i++)); do
    SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
    run_supply "$WORKDIR/stress_p6" 5
    rm -f -- "$RAW" 2>/dev/null
  done
) 2>"$STRESS_ERR"
STRESS_ERR_BYTES="$(wc -c < "$STRESS_ERR" | tr -d ' ')"
assert_eq "run_supplyを300回連続で呼んでもstderrが0バイト" "0" "$STRESS_ERR_BYTES"

echo "=== run_supply（P-3締切・足跡・AC-95） ==="
mk_stub_P3 "$WORKDIR/p3" "$WORKDIR/p3.fp"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
t0="$(now_mono)"
run_supply "$WORKDIR/p3" 1
rc=$?
t1="$(now_mono)"
elapsed="$(python3 -c "print($t1 - $t0)")"
assert_eq "P-3(ハング・締切1秒)はrc=1(応答なし)" "1" "$rc"
assert_true "P-3: 4秒以内に応答なしへ落ちる(AC-95)" "$(python3 -c "print(1 if $elapsed <= 4.0 else 0)")"
assert_true "P-3: 足跡の全PIDがkill -0に失敗する(AC-95)" "$(footprints_all_dead "$WORKDIR/p3.fp")"

echo "=== run_supply（P-16・接頭部の後にハング・AC-114） ==="
mk_stub_P16 "$WORKDIR/p16" "$WORKDIR/p16.fp"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
t0="$(now_mono)"
run_supply "$WORKDIR/p16" 1
rc=$?
t1="$(now_mono)"
elapsed="$(python3 -c "print($t1 - $t0)")"
assert_eq "P-16(接頭部の後ハング)はrc=1(応答なし)" "1" "$rc"
assert_true "P-16: 4秒以内(AC-114)" "$(python3 -c "print(1 if $elapsed <= 4.0 else 0)")"
assert_true "P-16: 足跡の全PIDがkill -0に失敗する" "$(footprints_all_dead "$WORKDIR/p16.fp")"

echo "=== run_supply（P-20a/b/c・上限到達・AC-122・DT-14） ==="
# run_supply実行中の一時領域(RAW/RCF/DONE/TOUT)の合計バイト数を0.02秒間隔で
# サンプリングし、観測した最大値をファイルへ書く（AC-122(d)＝72KiB以内）。
#   run_supply が並行して一時ファイルを消す(TOCTOU)と、[ -e "$f" ] を
# 通過した直後に <"$f" のオープンが失敗し得る。2>/dev/null は wc の
# stderr にしか掛からずオープン失敗自体はリダイレクトの実行元(このループ)
# の現在の stderr へ漏れる（検証4巡目 #44）。波括弧でリダイレクト全体を
# 包んでraceによる失敗を吸収する。読み取り自体を数回だけ即時リトライした
# うえで、それでも読めなければ「その時点でファイルが既に消えている
# （run_supplyの正当な後始末＝benign）」場合と「ファイルは在るのに読めない
# （過小評価につながる本当の競合）」場合を区別する（検証5巡目 #45＝前者を
# missに数えると受入スイートが約17%の確率で非決定的に落ちていた）。
# missに数えるのは後者だけにし、0件であることのassertは残す。
sample_tmp_usage() {
  local pattern="$1" outfile="$2" missfile="$3" max=0 cur files f sz
  : > "$missfile"
  while :; do
    cur=0
    for f in "${TMPDIR:-/tmp}"/cmux-supply-*; do
      [ -e "$f" ] || continue
      case "$f" in *"$pattern"*) : ;; *) continue ;; esac
      sz=""
      for _attempt in 1 2 3; do
        sz="$( { wc -c <"$f"; } 2>/dev/null | tr -d ' ')"   # テスト側の計測はFR-64の対象外
        is_number "$sz" && break
      done
      if ! is_number "$sz"; then
        if [ -e "$f" ]; then
          echo "miss" >> "$missfile"   # 在るのに読めない＝本当の競合
        fi
        # ここに来た時点で既に消えているなら、run_supplyの正当な後始末
        # （benign）なので miss には数えず 0 バイト扱いにする。
        sz=0
      fi
      cur=$(( cur + sz ))
    done
    [ "$cur" -gt "$max" ] && max="$cur"
    echo "$max" > "$outfile"
    sleep 0.02
  done
}
for spec in "P20a:mk_stub_P20a" "P20b:mk_stub_P20b" "P20c:mk_stub_P20c"; do
  name="${spec%%:*}" fn="${spec#*:}"
  "$fn" "$WORKDIR/$name" "$WORKDIR/$name.fp"
  SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
  MAXFILE="$WORKDIR/$name.maxsize"
  MISSFILE="$WORKDIR/$name.miss"
  echo 0 > "$MAXFILE"
  sample_tmp_usage "" "$MAXFILE" "$MISSFILE" &
  SAMPLER_PID=$!
  t0="$(now_mono)"
  run_supply "$WORKDIR/$name" 5
  rc=$?
  t1="$(now_mono)"
  kill -9 "$SAMPLER_PID" 2>/dev/null
  wait "$SAMPLER_PID" 2>/dev/null
  elapsed="$(python3 -c "print($t1 - $t0)")"
  MAXBYTES="$(cat "$MAXFILE" 2>/dev/null)"
  is_number "$MAXBYTES" || MAXBYTES=0
  MISS_N="$(wc -l < "$MISSFILE" 2>/dev/null | tr -d ' ')"
  is_number "$MISS_N" || MISS_N=0
  assert_eq "$name: 上限到達でrc=1(応答なし)" "1" "$rc"
  assert_true "$name: 縮退まで1秒以内(AC-122・DT-14)" "$(python3 -c "print(1 if $elapsed <= 1.0 else 0)")"
  assert_true "$name: 足跡の全PIDがkill -0に失敗する" "$(footprints_all_dead "$WORKDIR/$name.fp")"
  assert_true "$name: 一時領域の観測最大が72KiB(73728バイト)以内(AC-122(d))" \
    "$([ "$MAXBYTES" -le 73728 ] && echo 1 || echo 0)"
  assert_eq "$name: サンプリング中に読めなかった回数が0(検証4巡目#44の回帰・過小評価防止)" "0" "$MISS_N"
done

echo "=== 締切の正規化（AC-119） ==="
for v in "" "abc" "0" "-1" "2.5" "61"; do
  CMUX_DOCK_SUPPLY_TIMEOUT="$v"
  assert_eq "CMUX_DOCK_SUPPLY_TIMEOUT=[$v] は既定5へ" "5" "$(supply_deadline)"
done
CMUX_DOCK_SUPPLY_TIMEOUT="1"; assert_eq "1は1のまま" "1" "$(supply_deadline)"
CMUX_DOCK_SUPPLY_TIMEOUT="60"; assert_eq "60は60のまま(境界受理)" "60" "$(supply_deadline)"
unset CMUX_DOCK_SUPPLY_TIMEOUT

echo "=== TMPDIR異常（AC-116） ==="
BEFORE_HOME_COUNT="$(find "$HOME" -maxdepth 1 -newer "$WORKDIR" 2>/dev/null | wc -l | tr -d ' ')"
OLD_TMPDIR="${TMPDIR:-}"
export TMPDIR="$WORKDIR/does-not-exist-tmpdir"
mk_stub_P6_task "$WORKDIR/p6_for_tmpdir"
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""
run_supply "$WORKDIR/p6_for_tmpdir" 5
rc=$?
export TMPDIR="$OLD_TMPDIR"
assert_eq "TMPDIR不在はrc=1(応答なし)" "1" "$rc"
AFTER_HOME_COUNT="$(find "$HOME" -maxdepth 1 -newer "$WORKDIR" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "TMPDIR不在でも\$HOME配下に新規ファイルが増えない" "$BEFORE_HOME_COUNT" "$AFTER_HOME_COUNT"

echo "=== FR-64 許可コマンド表（検証2巡目 #27） ==="
# 要件v3.4本文(requirements.md:507)の表はjq・sed・awk・printf・sleep・date・
# cat・rm・mktemp・kill・wait・stty のみで、承認済みの読み替え dd・head・tr
# （検証1巡目#10以前）と、今回リーダーが追加承認した dirname（読み替え
# Q-v3-7＝自パス解決のみでドメインデータへ触れない）が未記載だった。
# 要件本文そのものの追随は締めで別担当が行う（リーダー裁定）。ここでは
# 実装が実際に依拠する許可表をこのテストへ固定し、描画側4ファイル
# （両常駐＋lib-supply-frame.sh＋lib-dock-view.sh）が表に無い外部コマンドを
# 呼んでいないことを静的に検査する（肯定＝表の16語が実際に使われている／
# 否定＝表外の語が0件、をそれぞれ独立したassertで）。
#
# 素朴なgrepでは、コメント中の語・${var#pattern}のような非コマンド位置の
# `#`・$((...))算術式の内部・var=(...)配列リテラルの丸括弧まで「外部コマ
# ンド」と誤認する（検証1巡目#10の教訓と同型）。python3でクォート・
# ヒアドキュメント・コマンド位置を踏まえた最小限の字句走査を行う
# （テスト側の計測はFR-64の対象外）。
CENSUS_PY="$WORKDIR/fr64_census.py"
cat > "$CENSUS_PY" <<'PYEOF'
import re, sys

# FR-64許可表（要件v3.4本文＋承認済み読み替えdd/head/tr＋Q-v3-7のdirname）。
ALLOWED = set("jq sed awk printf sleep date cat rm mktemp kill wait stty dd head tr dirname".split())
# シェル組込（外部コマンドの許可表の対象外）。
BUILTINS = set("""
if then else elif fi for while until do done case esac in select
local declare typeset return exit break continue set trap export unset
read shift eval exec source true false test echo let function time
cd pwd disown
""".split())

FUNC_DEF_RE = re.compile(r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)[ \t]*\{', re.M)
HEREDOC_START_RE = re.compile(
    r"<<(-)?\s*(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"|([A-Za-z_][A-Za-z0-9_]*))"
)


def strip_heredocs(text):
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = HEREDOC_START_RE.search(line)
        out.append(line)
        i += 1
        if m:
            dashed = bool(m.group(1))
            tag = m.group(2) or m.group(3) or m.group(4)
            while i < len(lines):
                body = lines[i]
                check = body.lstrip("\t") if dashed else body
                i += 1
                if check == tag:
                    break
                out.append("")
    return "\n".join(out)


def skip_dollar_brace(text, i):
    # ${...}（パラメータ展開）を丸ごと読み飛ばす。コマンド位置にはならない。
    depth = 1
    n = len(text)
    in_sq = False
    in_dq = False
    while i < n and depth > 0:
        c = text[i]
        if in_sq:
            if c == "'":
                in_sq = False
            i += 1
            continue
        if in_dq:
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_dq = False
            i += 1
            continue
        if c == "'":
            in_sq = True
            i += 1
            continue
        if c == '"':
            in_dq = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '{':
            depth += 1
            i += 1
            continue
        if c == '}':
            depth -= 1
            i += 1
            continue
        i += 1
    return i


def skip_arith(text, i):
    # $((...)) / ((...)) 算術式を丸ごと読み飛ばす。i は開き括弧2個の直後。
    depth = 2
    n = len(text)
    in_sq = False
    in_dq = False
    while i < n and depth > 0:
        c = text[i]
        if in_sq:
            if c == "'":
                in_sq = False
            i += 1
            continue
        if in_dq:
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_dq = False
            i += 1
            continue
        if c == "'":
            in_sq = True
            i += 1
            continue
        if c == '"':
            in_dq = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '(':
            depth += 1
            i += 1
            continue
        if c == ')':
            depth -= 1
            i += 1
            continue
        i += 1
    return i


ARRAY_LITERAL_BACK_RE = re.compile(
    r'(?:^|[\s;&|(){}])[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=$'
)


def skip_balanced_parens(text, i):
    # var=(...) / var+=(...) の配列リテラル括弧を丸ごと読み飛ばす。
    depth = 1
    n = len(text)
    in_sq = False
    in_dq = False
    while i < n and depth > 0:
        c = text[i]
        if in_sq:
            if c == "'":
                in_sq = False
            i += 1
            continue
        if in_dq:
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_dq = False
            i += 1
            continue
        if c == "'":
            in_sq = True
            i += 1
            continue
        if c == '"':
            in_dq = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '(':
            depth += 1
            i += 1
            continue
        if c == ')':
            depth -= 1
            i += 1
            continue
        i += 1
    return i


def segment_starts(text):
    # クォート・${...}・$((...))・var=(...) を踏まえ、実際に「コマンドが
    # 始まり得る位置」の一覧を返す（行頭／;／&／|／(／{／$( の直後）。
    n = len(text)
    i = 0
    stack = [{'kind': 'top', 'dq': False, 'sq': False}]
    starts = [0]
    while i < n:
        ctx = stack[-1]
        c = text[i]
        if ctx['sq']:
            if c == "'":
                ctx['sq'] = False
            i += 1
            continue
        if ctx['dq']:
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                ctx['dq'] = False
                i += 1
                continue
            if c == '$' and i + 1 < n and text[i + 1] == '{':
                i = skip_dollar_brace(text, i + 2)
                continue
            if c == '$' and i + 2 < n and text[i + 1] == '(' and text[i + 2] == '(':
                i = skip_arith(text, i + 3)
                continue
            if c == '$' and i + 1 < n and text[i + 1] == '(':
                stack.append({'kind': 'cmdsub', 'dq': False, 'sq': False})
                i += 2
                starts.append(i)
                continue
            if c == '`':
                # バッククォートは "..." の中でも展開される（検証3巡目 #38）。
                if stack[-1]['kind'] == 'backtick':
                    stack.pop()
                else:
                    stack.append({'kind': 'backtick', 'dq': False, 'sq': False})
                i += 1
                starts.append(i)
                continue
            i += 1
            continue
        if c == "'":
            ctx['sq'] = True
            i += 1
            continue
        if c == '"':
            ctx['dq'] = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '#':
            j = text.find('\n', i)
            i = n if j == -1 else j
            continue
        if c == '$' and i + 1 < n and text[i + 1] == '{':
            i = skip_dollar_brace(text, i + 2)
            continue
        if c == '$' and i + 2 < n and text[i + 1] == '(' and text[i + 2] == '(':
            i = skip_arith(text, i + 3)
            continue
        if c == '$' and i + 1 < n and text[i + 1] == '(':
            stack.append({'kind': 'cmdsub', 'dq': False, 'sq': False})
            i += 2
            starts.append(i)
            continue
        if c == '(' and i + 1 < n and text[i + 1] == '(':
            i = skip_arith(text, i + 2)
            continue
        if c == '`':
            if stack[-1]['kind'] == 'backtick':
                stack.pop()
            else:
                stack.append({'kind': 'backtick', 'dq': False, 'sq': False})
            i += 1
            starts.append(i)
            continue
        if c == '(' and ARRAY_LITERAL_BACK_RE.search(text[max(0, i - 80):i]):
            i = skip_balanced_parens(text, i + 1)
            continue
        if c == '(':
            stack.append({'kind': 'paren', 'dq': False, 'sq': False})
            i += 1
            starts.append(i)
            continue
        if c == '{':
            stack.append({'kind': 'brace', 'dq': False, 'sq': False})
            i += 1
            starts.append(i)
            continue
        if c == ')':
            if len(stack) > 1 and stack[-1]['kind'] in ('cmdsub', 'paren'):
                stack.pop()
            i += 1
            starts.append(i)
            continue
        if c == '}':
            if len(stack) > 1 and stack[-1]['kind'] == 'brace':
                stack.pop()
            i += 1
            starts.append(i)
            continue
        if c in ';\n&|':
            i += 1
            starts.append(i)
            continue
        i += 1
    return starts


def consume_word(text, i):
    # 代入値の末尾を、クォート・${...}・$((...))・$(...) を踏まえて探す
    # （値の中の外部コマンドはsegment_startsが別途独立に見つける）。
    n = len(text)
    while i < n:
        c = text[i]
        if c in ' \t\n;&|(){}':
            break
        if c == "'":
            i += 1
            while i < n and text[i] != "'":
                i += 1
            i = min(i + 1, n)
            continue
        if c == '"':
            i += 1
            while i < n:
                if text[i] == '\\' and i + 1 < n:
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '$' and i + 1 < n and text[i + 1] == '{':
            i = skip_dollar_brace(text, i + 2)
            continue
        if c == '$' and i + 2 < n and text[i + 1] == '(' and text[i + 2] == '(':
            i = skip_arith(text, i + 3)
            continue
        if c == '$' and i + 1 < n and text[i + 1] == '(':
            depth = 1
            i += 2
            while i < n and depth > 0:
                cc = text[i]
                if cc == '(':
                    depth += 1
                elif cc == ')':
                    depth -= 1
                elif cc == "'":
                    i += 1
                    while i < n and text[i] != "'":
                        i += 1
                elif cc == '"':
                    i += 1
                    while i < n and text[i] != '"':
                        if text[i] == '\\' and i + 1 < n:
                            i += 1
                        i += 1
                i += 1
            continue
        if c == '`':
            # バッククォート置換の値としての終端探索（中の外部コマンドは
            # segment_startsが別途独立に見つける・検証3巡目#38）。
            i += 1
            while i < n and text[i] != '`':
                if text[i] == '\\' and i + 1 < n:
                    i += 2
                    continue
                i += 1
            i = min(i + 1, n)
            continue
        i += 1
    return i


# if/elif/while/until/then/do/else の直後、および ! の直後はコマンド開始
# 位置になる（検証3巡目 #38）。BUILTINSに当たって読み飛ばされるだけだと、
# その後ろの実コマンド（例: if ditto a b; then）が一度も検査されない。
KEYWORD_CONTINUE = set("if elif while until then do else".split())


def first_command_word(text, offset):
    # segment_starts()が返した1つの位置から、先頭の VAR=/VAR+=（連鎖可）・
    # 予約語(if/while/...)・! を読み飛ばし、実際のコマンド語を1つ取り出す。
    # 無ければNone。
    n = len(text)
    pos = offset
    while True:
        while pos < n and text[pos] in ' \t':
            pos += 1
        m_assign = re.match(r'[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=', text[pos:pos + 200])
        if m_assign:
            pos += m_assign.end()
            pos = consume_word(text, pos)
            continue
        if pos < n and text[pos] == '!' and (pos + 1 >= n or text[pos + 1] in ' \t\n'):
            pos += 1
            continue
        m_kw = re.match(r'[A-Za-z_][A-Za-z0-9_]*', text[pos:pos + 200])
        if m_kw and m_kw.group(0) in KEYWORD_CONTINUE:
            pos += m_kw.end()
            continue
        break
    m2 = re.match(r'[A-Za-z_][A-Za-z0-9_.-]*', text[pos:pos + 200])
    if not m2:
        return None
    word = m2.group(0)
    # 空白を挟まず ')' か '|' が続く語は case のパターン/選言であって
    # コマンドではない（例: "H)" / "VE|CS)"）。
    nxt = text[pos + len(word):pos + len(word) + 1]
    if nxt in (')', '|'):
        return None
    return word


def main():
    files = sys.argv[1:]
    funcnames = set()
    texts = {}
    for fp in files:
        raw = open(fp, encoding='utf-8').read()
        stripped = strip_heredocs(raw)
        texts[fp] = stripped
        for m in FUNC_DEF_RE.finditer(stripped):
            funcnames.add(m.group(1))

    found = set()
    violations = []
    for fp, text in texts.items():
        for off in segment_starts(text):
            word = first_command_word(text, off)
            if word is None:
                continue
            if word in ALLOWED:
                found.add(word)
                continue
            if word in BUILTINS or word in funcnames:
                continue
            lineno = text.count('\n', 0, off) + 1
            line_text = text.split('\n')[lineno - 1].strip()
            violations.append((fp, lineno, word, line_text))

    for w in sorted(ALLOWED):
        print(("FOUND\t" if w in found else "MISSING\t") + w)
    print("VIOLATION_COUNT\t%d" % len(violations))
    for fp, lineno, word, line in violations:
        print("VIOLATION\t%s\t%d\t%s\t%s" % (fp, lineno, word, line))


main()
PYEOF

CENSUS_OUT="$WORKDIR/fr64_census.out"
python3 "$CENSUS_PY" "$LIB_SUPPLY" "$LIB_DOCK_VIEW" \
  "$SCRIPT_DIR/../cmux-task-watch/cmux-task-watch.sh" \
  "$SCRIPT_DIR/../cmux-next-watch/cmux-next-watch.sh" \
  > "$CENSUS_OUT"

MISSING_N="$(grep -c '^MISSING' "$CENSUS_OUT")"
VIOLATION_N="$(awk -F '\t' '$1=="VIOLATION_COUNT"{print $2}' "$CENSUS_OUT")"
assert_eq "FR-64許可表: 表の16語すべてが描画側4ファイルのどこかで実際に使われている(肯定・検証2巡目#27)" "0" "$MISSING_N"
assert_eq "FR-64許可表: 表に無い外部コマンドの呼び出しが0件(否定・検証2巡目#27)" "0" "$VIOLATION_N"
if [ "$MISSING_N" != "0" ] || [ "$VIOLATION_N" != "0" ]; then
  echo "  詳細:"
  sed 's/^/    /' "$CENSUS_OUT" | grep -E 'MISSING|VIOLATION'
fi

echo "=== FR-64許可表の字句走査・偽陰性の回帰（検証3巡目 #38） ==="
# impl-r3.out の再現表の4行（if <cmd>・while <cmd>・if ! <cmd>・バック
# クォート）をそのまま回帰ケースにする。各パターンを表に無いコマンド
# 1語だけを使う独立fixtureへ置き、censusがそれぞれ検出することを見る
# （検出できなければ segment_starts()/first_command_word() の予約語・
# バッククォート対応が壊れている）。
mk_s38() {  # $1=出力fixtureパス $2=fixture本文
  printf '%s\n' "$2" > "$1"
}
mk_s38 "$WORKDIR/s38_if.sh"      'f() { if ditto a b; then :; fi; }'
mk_s38 "$WORKDIR/s38_while.sh"   'f() { while nslookup x; do break; done; }'
mk_s38 "$WORKDIR/s38_ifnot.sh"   'f() { if ! lsof -i; then :; fi; }'
mk_s38 "$WORKDIR/s38_backtick.sh" 'f() { _p=`hostname`; }'
for spec in "if:ditto" "while:nslookup" "ifnot:lsof" "backtick:hostname"; do
  case_name="${spec%%:*}" expect_word="${spec#*:}"
  fixture="$WORKDIR/s38_${case_name}.sh"
  out="$WORKDIR/s38_${case_name}.out"
  python3 "$CENSUS_PY" "$fixture" > "$out"
  vn="$(awk -F '\t' '$1=="VIOLATION_COUNT"{print $2}' "$out")"
  assert_eq "検証3巡目#38回帰($case_name): 表に無い${expect_word}が検出される" "1" "$vn"
  assert_true "検証3巡目#38回帰($case_name): 検出語が${expect_word}" \
    "$(grep -qF "$(printf '\t')${expect_word}$(printf '\t')" "$out" && echo 1 || echo 0)"
done
# コメント内・ヒアドキュメント本文は誤検知しないことも対で確認する。
mk_s38 "$WORKDIR/s38_comment.sh" 'f() { : ; # perl -e 1
  cat <<HEREDOC_TAG
perl -e 1
HEREDOC_TAG
}'
python3 "$CENSUS_PY" "$WORKDIR/s38_comment.sh" > "$WORKDIR/s38_comment.out"
assert_eq "検証3巡目#38回帰(comment/heredoc): コメント内・ヒアドキュメント本文は誤検知しない" \
  "0" "$(awk -F '\t' '$1=="VIOLATION_COUNT"{print $2}' "$WORKDIR/s38_comment.out")"

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
