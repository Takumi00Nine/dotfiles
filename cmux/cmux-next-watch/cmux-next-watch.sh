#!/bin/bash
# cmux Dock「Project」枠の描画（cmux-session-todo 設計 v3・C-19）。供給側
# （ai-env の cmux-next-model.sh）が返す1ティック分のフレームを受け取って
# 描くだけで、Vault・外部脳ログ・cmux を自分では一切読まない（FR-62・
# FR-64）。供給側が無い・応答しない・契約の版が合わないときは理由行1行へ
# 縮退する（FR-68）。呼び出し口は環境変数 CMUX_DOCK_SUPPLY_PROJECT で上書き
# できる（既定はリポジトリ内の絶対パス）。
#
# 表示例（契約 cmux-dock-frame/4＝v5 §40.4。区分は 稼働中／待ち／保留 の
# 3ブロック（待ち0件のときは待ちブロックごと出さない）。待ちの行は末尾に
# 待ち日時（供給側が Vault の `wait_until:` から正規化した値）の短縮形
# `M/D HH:MM` を付ける。外部脳ヘルス行は health-self-explain 設計 v1.2
# §6・D-3＝1行3値＋末尾付記のみ・見出し行は出さない。v7＝エントリ行の
# 先頭 2 セルは ▶ 欄で、フォーカス中のワークスペースの宣言先（供給側の
# `--focus` が返す 1 語＝Task 枠と同じ宣言記録）と正式名が一致する 1 行に
# `▶` を置き行全体を強調色で描く。未宣言・不明のときはどの行にも付かない）:
#   ● 稼働中 (2)
#   ▶ 5 svwb-pilot 実データ照合を回す
#     6 takumi009- (next未設定)
#
#   ⏸ 待ち (1)
#     7 p-wait 返事待ち 9/25 10:00
#
#   ⏸ 保留 (1)
#     8 avatar-swi 配布方式のたたき台を書く
#
#   外部脳 OK 候補390件
#
# 高さ（設計 §40.6.1・FR-101）＝①CMUX_NEXT_ROWS（正整数）＞②stty size
# ＞③h_def=4。書き出しは末尾LFなし（h行をh−1個のLFで書く＝D-v5-6）。
# 幅＝CMUX_NEXT_COLS（正整数）＞ stty size（上限 CMUX_DOCK_MAX_COLS）。
#
# 周期（設計 §42.6）＝常駐のループは対象周期 CMUX_NEXT_FOCUS_INTERVAL
# （既定 2 秒）で回り、毎ティック `--focus` を呼ぶ。フレーム（`--frame`）は
# 前回取得から CMUX_NEXT_INTERVAL（既定 60 秒）以上経ったティックで取り直す。
# 本体・対象とも前ティックと同じなら組み立てを省く（WINCH・heartbeat は
# 組み立て直す＝D-v7-10）。
#
# 引数: （なし）＝常駐 / --once＝1フレーム出して終了。--list は供給側
# （cmux-next-model.sh --list）へ移設済みで、この常駐は提供しない
# （既知の引数として usage を出し rc=1・常駐モードへは落ちない＝F-56）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

# source されたとき（A-v5-4・DT-22）も自分の場所から lib を引けるよう
# BASH_SOURCE を優先する（直接実行では $0 と同じ）。
LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/.."
if [ ! -r "$LIB_DIR/lib-dock-view.sh" ]; then
  echo "cmux-next-watch: lib-dock-view.sh が見つかりません: $LIB_DIR/lib-dock-view.sh" >&2
  exit 1
fi
if [ ! -r "$LIB_DIR/lib-supply-frame.sh" ]; then
  echo "cmux-next-watch: lib-supply-frame.sh が見つかりません: $LIB_DIR/lib-supply-frame.sh" >&2
  exit 1
fi
# shellcheck source=../lib-dock-view.sh
. "$LIB_DIR/lib-dock-view.sh"
# shellcheck source=../lib-supply-frame.sh
. "$LIB_DIR/lib-supply-frame.sh"

SUPPLY="${CMUX_DOCK_SUPPLY_PROJECT:-$HOME/Workspace/Tools/takumi009-ai-env/dock/executor/cmux-next-model.sh}"
INTERVAL="$(sanitize_interval "${CMUX_NEXT_INTERVAL:-}" 60)"
# 対象周期（v7 A-v7-2）＝受理規則は CMUX_NEXT_INTERVAL と同じ。
FOCUS_INTERVAL="$(sanitize_interval "${CMUX_NEXT_FOCUS_INTERVAL:-}" 2)"
REDRAW_HEARTBEAT="$(sanitize_interval "${CMUX_NEXT_REDRAW_HEARTBEAT:-}" 600)"
ROWS_OVERRIDE="${CMUX_NEXT_ROWS:-}"

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
DIM_BOLD="${ESC}[38;5;244;1m"
LBL="${ESC}[38;5;252m"
LBL_BOLD="${ESC}[38;5;252;1m"
# 対象行の強調色（v7 FR-118＝Task 枠の ▶ の版行と同じ色・設計 §39 の型）。
ACCENT="${ESC}[38;5;114;1m"
GOOD_C="${ESC}[38;5;114m"
WARN_C="${ESC}[38;5;214m"
# 外部脳ヘルスのERROR用に赤1色を追加（本人裁定OQ-1・2026-09-20・
# health-self-explain 設計 v1.2 §6）。WARN_BOLD/GOOD_BOLDは外部脳ブロック
# の見出し行専用だったが、見出し行を出さない契約（v1.2 §6以降）に
# なったため不要＝退役。
ERR_C="${ESC}[38;5;203m"

# 幅の上書き口（A-v5-1・CMUX_TASK_COLS と同型）。tty の有無に依らず幅を
# 固定できる（AC-141・AC-143⑦）。上限の丸め（CMUX_DOCK_MAX_COLS）は
# term_cols 側で不変。
COLS_OVERRIDE="${CMUX_NEXT_COLS:-}"
cols_now() { term_cols "$COLS_OVERRIDE"; }

# 高さ（FR-101 ①②③）＝term_rows（①CMUX_NEXT_ROWS／②stty size）が
# 取得不能（0）なら h_def=4（設計 §40.6.1）。
resolve_rows() {
  local r
  r=$(term_rows "$ROWS_OVERRIDE")
  is_number "$r" && [ "$r" -ge 1 ] || r=4
  printf '%s' "$r"
}

# --- フレーム由来のモデル ---------------------------------------------------
# 保持する状態（設計 §42.6.1）＝B（FRAME_REASON か本体行 P_*/B_*・BODY は
# 本体行の原文＝同一入力の判定用）と T（TARGET＝照会口が返した 1 語・対象
# なしは空）。フレームは前回取得から INTERVAL 秒以上経ったティックだけ
# 取り直し、TARGET は毎ティック取り直す。
FRAME_REASON=""
BODY=""
TARGET=""
P_NUM=(); P_NAME=(); P_NEXT=(); P_CAT=(); P_WAIT=()
B_KIND=(); B_WARN=(); B_TEXT=()

SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""; MODEL=""
DRAWING=0

# $MODEL（lib-supply-frame.sh が検証済みの本体行）から P_*/B_* 配列を
# 組み立てる。番号は供給側が振った値をそのまま使う（FR-63）。
load_model_from_frame() {
  P_NUM=(); P_NAME=(); P_NEXT=(); P_CAT=(); P_WAIT=()
  B_KIND=(); B_WARN=(); B_TEXT=()
  BODY=""

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    BODY="$BODY$line
"
    split_tsv "$line"
    case "${TSV_F[0]}" in
      P)
        P_NUM+=("${TSV_F[1]}")
        P_NAME+=("${TSV_F[2]}")
        P_NEXT+=("${TSV_F[3]}")
        P_CAT+=("${TSV_F[4]}")
        P_WAIT+=("${TSV_F[5]}")   # split_tsv は空欄を畳まない（空の第6欄も保存される）
        ;;
      B)
        B_KIND+=("${TSV_F[1]}")
        B_WARN+=("${TSV_F[2]}")
        B_TEXT+=("${TSV_F[3]}")
        ;;
    esac
  done < "$MODEL"
}

# --- 描画（設計 §31.4・v5 §40.6） ---------------------------------------------

# 待ち日時（検証済みの YYYY-MM-DDTHH:MM）の短縮形 `M/D HH:MM`（FR-98・
# FR-99「固定の変換」）。パラメータ展開だけで date は呼ばない（D-v5-5）。
# 形が違う値（16文字未満）は防御としてそのまま返す（F-94・到達しない）。
short_wait() {
  local v="$1" m d
  if [ "${#v}" -lt 16 ]; then printf '%s' "$v"; return; fi
  m="${v:5:2}"; d="${v:8:2}"; m="${m#0}"; d="${d#0}"
  printf '%s/%s %s' "$m" "$d" "${v:11:5}"
}

# P_NUM[$1] 他1件ぶんのエントリ行を描く（幅は $2、既定は現在の端末幅）。
# 先頭 2 セルは ▶ 欄（v7 FR-117）＝対象行（P_NAME が TARGET と完全一致）は
# `▶ `・他は空白 2。next 欄の予算はその 2 セル分だけ減る（FR-121）。
# 待ちの行は末尾に短縮形（DIM）を付け、next 欄だけを切り詰める（FR-98）。
# 色は稼働中・保留・待ちとも同じ（番号 DIM・名前 LBL・next LBL＝R-v5-14）。
# 対象行だけは ▶ 欄を含む行全体を ACCENT 1 つで包む（FR-118・D-v7-7）。
_render_entry_line() {
  local i="$1" cols="${2:-}"
  [ -n "$cols" ] || cols="$(cols_now)"
  local num="${P_NUM[$i]}" name="${P_NAME[$i]}" nextraw="${P_NEXT[$i]}" wait="${P_WAIT[$i]:-}"
  local numw=${#num} name_disp name_len remw next_disp next_c short sw=0
  name_disp="$(truncate_plain "$name" 10)"
  name_len="$(disp_width "$name_disp")"
  is_number "$name_len" || name_len=10
  if [ "${P_CAT[$i]}" = "待ち" ] && [ -n "$wait" ]; then
    short="$(short_wait "$wait")"
    sw=${#short}   # ASCII のみ＝幅＝長さ
    remw=$(( cols - 2 - numw - 1 - name_len - 1 - sw - 1 ))
  else
    short=""
    remw=$(( cols - 2 - numw - 1 - name_len - 1 ))
  fi
  [ "$remw" -lt 1 ] && remw=1
  if [ -z "$nextraw" ]; then
    next_disp="$(truncate_disp "(next未設定)" "$remw")"
    next_c="$DIM"
  else
    next_disp="$(truncate_disp "$nextraw" "$remw")"
    next_c="$LBL"
  fi
  local tail=""
  [ -n "$short" ] && tail=" $short"
  if [ "$name" = "$TARGET" ]; then
    printf '%s▶ %s %s %s%s%s\n' "$ACCENT" "$num" "$name_disp" "$next_disp" "$tail" "$RESET"
    return
  fi
  if [ -n "$short" ]; then
    printf '  %s%s%s %s%s%s %s%s%s %s%s%s\n' "$DIM" "$num" "$RESET" "$LBL" "$name_disp" "$RESET" "$next_c" "$next_disp" "$RESET" "$DIM" "$short" "$RESET"
  else
    printf '  %s%s%s %s%s%s %s%s%s\n' "$DIM" "$num" "$RESET" "$LBL" "$name_disp" "$RESET" "$next_c" "$next_disp" "$RESET"
  fi
}

# 区分の見出し行。$1=区分 $2=件数（P_CAT の全件数＝クランプ前・FR-97）。
# 稼働中の記号は ●（v7 FR-119＝▶ はエントリ行の ▶ 欄にしか現れない）。
_render_heading() {
  case "$1" in
    稼働中) printf '%s● 稼働中 (%d)%s\n' "$LBL_BOLD" "$2" "$RESET" ;;
    待ち)   printf '%s⏸ 待ち (%d)%s\n' "$DIM_BOLD" "$2" "$RESET" ;;
    *)      printf '%s⏸ 保留 (%d)%s\n' "$DIM_BOLD" "$2" "$RESET" ;;
  esac
}

# 外部脳ヘルス行（B_*が0行ならブロックごと出さない＝FR-68・AC-97②）。
# health-self-explain 設計 v1.2 §6・D-3＝見出し行は出さず、B行を1行だけ
# `<色><kind> <text>` で描く（B行は lib-supply-frame.sh の validate_frame
# が既に高々1行に絞っている）。
render_extbrain() {
  local n=${#B_KIND[@]}
  [ "$n" -eq 0 ] && return

  local kind="${B_KIND[0]}" warn="${B_WARN[0]}" text="${B_TEXT[0]}"
  local color
  case "$warn" in
    error) color="$ERR_C" ;;
    warn)  color="$WARN_C" ;;
    ok)    color="$GOOD_C" ;;
    # 契約外の値は到達しない前提（validate_frameがok/warn/error以外を
    # rc=3で落とす＝lib-supply-frame.sh）。それでも黙ってOKの緑に化けない
    # よう、未知値は無色（dim）で描く（検証1巡目C-3）。
    *)     color="$LBL" ;;
  esac
  printf '%s%s %s%s\n' "$color" "$kind" "$text" "$RESET"
}

# クランプ時の配分（FR-100 ②・設計 §40.6.3 distribute_rows・D-v5-11）。
# 純関数（bash 3.2 の整数演算だけ）。$1=R（残り行数） $2=nA $3=nW $4=nH
# （各ブロックの全件数・待ちブロックの有無は nW>0 で決まる）→ stdout に
# "kA kW kH"（各ブロックの残し数）。
#   (1) R を表示するブロック数（待ち0件なら2）で割って均等（床）
#   (2) 余りは 稼働中→待ち→保留 の順に1行ずつ
#   (3) 件数が配分より少ないブロックの余剰を回収し、同じ順で空きのある
#       ブロックへ1行ずつ回す（回し切るまで繰り返す）
# 性質＝R ≤ n のとき kA+kW+kH = R・k_b ≤ n_b（DT-22）。
distribute_rows() {
  local R="$1" nA="$2" nW="$3" nH="$4"
  local nbk=2 base rem kA kW kH surplus moved
  [ "$nW" -gt 0 ] && nbk=3
  base=$(( R / nbk )); rem=$(( R % nbk ))
  kA=$base; kH=$base
  if [ "$nW" -gt 0 ]; then kW=$base; else kW=0; fi
  # (2) 余り（rem < nbk）を順の先頭から +1
  if [ "$rem" -ge 1 ]; then kA=$(( kA + 1 )); fi
  if [ "$rem" -ge 2 ]; then
    if [ "$nW" -gt 0 ]; then kW=$(( kW + 1 )); else kH=$(( kH + 1 )); fi
  fi
  # (3) 回収
  surplus=0
  if [ "$kA" -gt "$nA" ]; then surplus=$(( surplus + kA - nA )); kA=$nA; fi
  if [ "$kW" -gt "$nW" ]; then surplus=$(( surplus + kW - nW )); kW=$nW; fi
  if [ "$kH" -gt "$nH" ]; then surplus=$(( surplus + kH - nH )); kH=$nH; fi
  # (3) 回し（空きが無くなるか surplus が尽きるまで）
  while [ "$surplus" -gt 0 ]; do
    moved=0
    if [ "$surplus" -gt 0 ] && [ "$kA" -lt "$nA" ]; then kA=$(( kA + 1 )); surplus=$(( surplus - 1 )); moved=1; fi
    if [ "$surplus" -gt 0 ] && [ "$kW" -lt "$nW" ]; then kW=$(( kW + 1 )); surplus=$(( surplus - 1 )); moved=1; fi
    if [ "$surplus" -gt 0 ] && [ "$kH" -lt "$nH" ]; then kH=$(( kH + 1 )); surplus=$(( surplus - 1 )); moved=1; fi
    [ "$moved" -eq 1 ] || break   # 空きが無い＝R > n（クランプ時は到達しない・防御）
  done
  printf '%s %s %s' "$kA" "$kW" "$kH"
}

# 1 ブロックのエントリ行を描く。$1=先頭添字 $2=そのブロックの件数 $3=残す
# 行数 k $4=幅。残すのは先頭 k 行。ただし対象行（P_NAME が TARGET と一致）が
# このブロックの先頭 k 行の外にあれば「先頭 k−1 行＋対象行」（番号昇順の
# まま＝FR-123・設計 §42.7.2）。k=0 のブロックは対象行も出ない（D-v7-8）。
_render_block() {
  local start="$1" cnt="$2" k="$3" cols="$4"
  local i end=$(( start + cnt )) t=-1
  for ((i = start + k; i < end; i++)); do
    if [ "${P_NAME[$i]}" = "$TARGET" ]; then t=$i; break; fi
  done
  if [ "$t" -ge 0 ] && [ "$k" -ge 1 ]; then k=$(( k - 1 )); else t=-1; fi
  for ((i = start; i < start + k; i++)); do _render_entry_line "$i" "$cols"; done
  [ "$t" -ge 0 ] && _render_entry_line "$t" "$cols"
  return 0
}

# 3ブロック（稼働中→待ち→保留）＋外部脳を組む（設計 §40.6.3 build）。
# $1=クランプ有無(0/1) $2=kA $3=kW $4=kH（各ブロックで残す行数）。
# 見出しの件数は常にクランプ前の全件数（FR-97）。見出しは件数0でも出す
# （落ちたブロックの見出しも残す＝FR-100 ①）。待ち0件のときは待ちブロック
# ごと出さない。`…他N行` はクランプ時に末尾（保留ブロックの後）に1行だけ。
# P_* 配列は --list の順（稼働中→待ち→保留・validate_frame が順位の
# 非減少を保証）なので添字範囲で各ブロックを描く。
build_lines() {
  local clamp="$1" kA="$2" kW="$3" kH="$4"
  local n=${#P_NUM[@]} i cnt_a=0 cnt_w=0 cnt_h=0
  for ((i = 0; i < n; i++)); do
    case "${P_CAT[$i]}" in
      待ち) cnt_w=$(( cnt_w + 1 )) ;;
      保留) cnt_h=$(( cnt_h + 1 )) ;;
      *)    cnt_a=$(( cnt_a + 1 )) ;;
    esac
  done
  local cols
  cols="$(cols_now)"

  _render_heading 稼働中 "$cnt_a"
  _render_block 0 "$cnt_a" "$kA" "$cols"
  if [ "$cnt_w" -gt 0 ]; then
    printf '\n'; _render_heading 待ち "$cnt_w"
    _render_block "$cnt_a" "$cnt_w" "$kW" "$cols"
  fi
  printf '\n'; _render_heading 保留 "$cnt_h"
  _render_block $(( cnt_a + cnt_w )) "$cnt_h" "$kH" "$cols"
  if [ "$clamp" -eq 1 ]; then
    printf '%s…他%d行%s\n' "$DIM" "$(( n - (kA + kW + kH) ))" "$RESET"
  fi
  if [ "${#B_KIND[@]}" -gt 0 ]; then
    printf '\n'; render_extbrain
  fi
}

# フレームをペインの高さ h に収める（設計 §40.6.3・FR-100・FR-101）。
#   fixed = 見出し数 + ブロック間の空行 + 外部脳(空行+行)
#   fixed + n ≤ h → クランプなし（全ブロック全件）
#   それ以外 → R = h − (fixed + 1)（`…他N行` を固定行に数える＝§40.2 M-5
#   の修正）を distribute_rows で3ブロックへ配分（FR-100 ②）。
#   組んだ行数が h を超える（h ≤ fixed）ときは先頭 h 行に退化（D-v5-4・
#   R=0 → 0/0/0 で規則と矛盾しない）。
# 各行を LF 終端で出す（--once はこれがそのまま出力。常駐は $( ) で末尾
# LF を落として書く＝h 行を h−1 個の LF で）。
compose_frame() {
  if [ -n "$FRAME_REASON" ]; then
    printf '%s\n' "$FRAME_REASON"
    return
  fi
  local n=${#P_NUM[@]} i nA=0 nW=0 nH=0 nb=${#B_KIND[@]}
  for ((i = 0; i < n; i++)); do
    case "${P_CAT[$i]}" in
      待ち) nW=$(( nW + 1 )) ;;
      保留) nH=$(( nH + 1 )) ;;
      *)    nA=$(( nA + 1 )) ;;
    esac
  done
  local blocks=2 ext=0 fixed h R clamp kA kW kH
  [ "$nW" -gt 0 ] && blocks=3
  [ "$nb" -gt 0 ] && ext=2
  fixed=$(( blocks + (blocks - 1) + ext ))
  h="$(resolve_rows)"
  if [ $(( fixed + n )) -le "$h" ]; then
    clamp=0; kA=$nA; kW=$nW; kH=$nH
  else
    clamp=1
    R=$(( h - (fixed + 1) ))
    [ "$R" -lt 0 ] && R=0
    read -r kA kW kH <<EOF_DIST
$(distribute_rows "$R" "$nA" "$nW" "$nH")
EOF_DIST
  fi
  build_lines "$clamp" "$kA" "$kW" "$kH" | head -n "$h"
}

# --- 取得（供給側の 2 つの口＝--frame と --focus・設計 §42.6.1） ---------------

# フレーム（`--frame`・契約検証つき）。失敗は理由行＝前の本体は残さない
# （D-v7-2）。
fetch_tick() {
  BODY=""
  fetch_frame "Project" "$SUPPLY"
  if [ -z "$FRAME_REASON" ]; then
    load_model_from_frame
  fi
  [ -n "${MODEL:-}" ] && { rm -f -- "$MODEL"; MODEL=""; }
}

# 対象（`--focus`・設計 §42.5.3 の読み方）＝rc 0 かつ stdout がちょうど 1 行
# ならその行を TARGET、それ以外（rc 非 0・0 バイト・2 行以上・締切）は対象
# なし（空）。値は P 行の正式名との等値比較にしか使わない（文法検査・切り
# 詰め・stderr の読み取りはしない＝§42.4 境界 ②④）。
fetch_target() {
  local rc
  TARGET=""
  run_supply "$SUPPLY" "$(supply_deadline)" --focus
  rc=$?
  if [ "$rc" -eq 0 ]; then
    TARGET="$(LC_ALL=C awk 'NR == 1 { l = $0 } END { if (NR == 1) printf "%s", l }' "$RAW" 2>/dev/null)"
  fi
  supply_rm_transient
}

# --- 起動口 ---------------------------------------------------------------

cleanup() {
  if [ -n "$SUPPLY_PGID" ]; then
    kill -TERM "-$SUPPLY_PGID" 2>/dev/null; kill -KILL "-$SUPPLY_PGID" 2>/dev/null
    wait "$SUPPLY_PGID" 2>/dev/null; SUPPLY_PGID=""
  fi
  if [ -n "$WATCH_PGID" ]; then
    kill -TERM "-$WATCH_PGID" 2>/dev/null; kill -KILL "-$WATCH_PGID" 2>/dev/null
    wait "$WATCH_PGID" 2>/dev/null; WATCH_PGID=""
  fi
  rm -f -- "$RAW" "$RCF" "$DONE" "$TOUT" "$MODEL" 2>/dev/null
  RAW=""; RCF=""; DONE=""; TOUT=""; MODEL=""
  if [ "$DRAWING" = "1" ]; then printf '\033[?2026l'; DRAWING=0; fi
}
on_exit() { trap - EXIT; cleanup; printf '\033[?25h'; }

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-next-watch.sh [--once]

供給側から1フレーム分（--frame）とフォーカス中のワークスペースの宣言先
（--focus・1 語）を受け取って描くだけの常駐です（Vault・外部脳ログ・
cmux は読みません＝FR-62・FR-64）。呼び出し口は環境変数
CMUX_DOCK_SUPPLY_PROJECT で上書きできます（既定は
$HOME/Workspace/Tools/takumi009-ai-env/dock/executor/cmux-next-model.sh）。供給側が無い・
応答しない・契約の版が合わないときは "AI環境 未導入" のように理由行
1行へ縮退します。宣言先が取れないときは ▶ の無い表を描きます。

--list は供給側（cmux-next-model.sh --list）へ移設済みで、この常駐は
提供しません。
EOF
}

main() {
  local a
  for a in "$@"; do
    case "$a" in
      --once) : ;;
      *) usage; exit 1 ;;
    esac
  done

  if [ "${1:-}" = "--once" ]; then
    fetch_tick
    fetch_target
    compose_frame
    return
  fi

  printf '\033]2;Project\007'
  printf '\033[?25l'
  local force_redraw=0
  trap 'force_redraw=1' WINCH
  trap 'on_exit; exit 0' INT TERM HUP
  trap 'on_exit' EXIT
  printf '\033[2J'
  # ループは対象周期で回る（設計 §42.6.1）。段 1＝フレームは期限（初回・前回
  # 取得から INTERVAL 秒以上）のティックだけ取り直す。段 2＝対象は毎ティック。
  # 段 3＝入力（理由行・本体・対象）が前ティックと同じで、WINCH も heartbeat
  # 期限も無ければ組み立てを省く（D-v7-10）。段 4＝組み立てて、描画文字列が
  # 変わったか強制・heartbeat なら描く（既存の同一フレーム抑止）。
  local frame last_frame="" last_redraw=0 now last_fetch="" input last_input="" must
  while :; do
    now=$(date +%s)
    if [ -z "$last_fetch" ] || [ $(( now - last_fetch )) -ge "$INTERVAL" ]; then
      fetch_tick
      last_fetch="$now"
    fi
    fetch_target
    input="$FRAME_REASON
$BODY
$TARGET"
    must=0   # WINCH か heartbeat 期限＝組み立ても描画も省かない
    if [ "$force_redraw" -eq 1 ] || [ $(( now - last_redraw )) -ge "$REDRAW_HEARTBEAT" ]; then must=1; fi
    if [ "$input" != "$last_input" ] || [ "$must" -eq 1 ]; then
      frame="$(compose_frame | sed "s/\$/${ESC}[K/")"
      last_input="$input"
      if [ "$frame" != "$last_frame" ] || [ "$must" -eq 1 ]; then
        DRAWING=1
        # 末尾 LF なし（D-v5-6）＝最下行の LF で 1 行スクロールして先頭行が
        # 隠れる（§40.2 M-5）のを防ぐ。ESC[J が末尾行の末尾から画面末までを消す。
        printf '\033[?2026h\033[H%s\033[J\033[?2026l' "$frame"
        DRAWING=0
        last_frame="$frame"
        last_redraw="$now"
        force_redraw=0
      fi
    fi
    sleep "$FOCUS_INTERVAL"
  done
}

# source ガード（A-v5-4・cmux-next-model.sh と同じ型）＝テストが
# distribute_rows を純関数として直接呼べるようにする。直接実行時は従来
# どおり main が走る。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
