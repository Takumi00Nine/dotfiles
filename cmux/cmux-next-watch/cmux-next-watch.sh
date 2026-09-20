#!/bin/bash
# cmux Dock「Project」枠の描画（cmux-session-todo 設計 v3・C-19）。供給側
# （ai-env の cmux-next-model.sh）が返す1ティック分のフレームを受け取って
# 描くだけで、Vault・外部脳ログ・cmux を自分では一切読まない（FR-62・
# FR-64）。供給側が無い・応答しない・契約の版が合わないときは理由行1行へ
# 縮退する（FR-68）。呼び出し口は環境変数 CMUX_DOCK_SUPPLY_PROJECT で上書き
# できる（既定はリポジトリ内の絶対パス）。
#
# 表示例（外部脳ヘルス行はDock契約 cmux-dock-frame/3＝health-self-explain
# 設計 v1.2 §6・D-3。1行3値＋末尾付記のみ・見出し行は出さない）:
#   ▶ 稼働中 (2)
#   5 svwb-pilot 実データ照合を回す
#   6 takumi009- (next未設定)
#
#   ⏸ 保留 (1)
#   7 avatar-swi 配布方式のたたき台を書く
#
#   外部脳 OK 候補390件
#
# 引数: （なし）＝常駐 / --once＝1フレーム出して終了。--list は供給側
# （cmux-next-model.sh --list）へ移設済みで、この常駐は提供しない
# （既知の引数として usage を出し rc=1・常駐モードへは落ちない＝F-56）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)/.."
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

SUPPLY="${CMUX_DOCK_SUPPLY_PROJECT:-$HOME/work/takumi009-ai-env/cmux/cmux-next-model.sh}"
INTERVAL="$(sanitize_interval "${CMUX_NEXT_INTERVAL:-}" 60)"
REDRAW_HEARTBEAT="$(sanitize_interval "${CMUX_NEXT_REDRAW_HEARTBEAT:-}" 600)"
ROWS_OVERRIDE="${CMUX_NEXT_ROWS:-}"

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
DIM_BOLD="${ESC}[38;5;244;1m"
LBL="${ESC}[38;5;252m"
LBL_BOLD="${ESC}[38;5;252;1m"
GOOD_C="${ESC}[38;5;114m"
WARN_C="${ESC}[38;5;214m"
# 外部脳ヘルスのERROR用に赤1色を追加（本人裁定OQ-1・2026-09-20・
# health-self-explain 設計 v1.2 §6）。WARN_BOLD/GOOD_BOLDは外部脳ブロック
# の見出し行専用だったが、見出し行を出さない契約（cmux-dock-frame/3）に
# なったため不要＝退役。
ERR_C="${ESC}[38;5;203m"

cols_now() { term_cols ""; }

# --- フレーム由来のモデル ---------------------------------------------------
FRAME_REASON=""
P_NUM=(); P_NAME=(); P_NEXT=(); P_CAT=()
B_KIND=(); B_WARN=(); B_TEXT=()

SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""; MODEL=""
DRAWING=0

# $MODEL（lib-supply-frame.sh が検証済みの本体行）から P_*/B_* 配列を
# 組み立てる。番号は供給側が振った値をそのまま使う（FR-63）。
load_model_from_frame() {
  P_NUM=(); P_NAME=(); P_NEXT=(); P_CAT=()
  B_KIND=(); B_WARN=(); B_TEXT=()

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    split_tsv "$line"
    case "${TSV_F[0]}" in
      P)
        P_NUM+=("${TSV_F[1]}")
        P_NAME+=("${TSV_F[2]}")
        P_NEXT+=("${TSV_F[3]}")
        P_CAT+=("${TSV_F[4]}")
        ;;
      B)
        B_KIND+=("${TSV_F[1]}")
        B_WARN+=("${TSV_F[2]}")
        B_TEXT+=("${TSV_F[3]}")
        ;;
    esac
  done < "$MODEL"
}

# --- 描画（設計 §31.4・表示規則は不変） -------------------------------------

# P_NUM[$1] 他1件ぶんのエントリ行を描く（幅は $2、既定は現在の端末幅）。
_render_entry_line() {
  local i="$1" cols="${2:-}"
  [ -n "$cols" ] || cols="$(cols_now)"
  local num="${P_NUM[$i]}" name="${P_NAME[$i]}" nextraw="${P_NEXT[$i]}"
  local numw=${#num} name_disp name_len remw next_disp
  name_disp="$(truncate_plain "$name" 10)"
  name_len="$(disp_width "$name_disp")"
  is_number "$name_len" || name_len=10
  remw=$(( cols - numw - 1 - name_len - 1 ))
  [ "$remw" -lt 1 ] && remw=1
  if [ -z "$nextraw" ]; then
    next_disp="$(truncate_disp "(next未設定)" "$remw")"
    printf '%s%s%s %s%s%s %s%s%s\n' "$DIM" "$num" "$RESET" "$LBL" "$name_disp" "$RESET" "$DIM" "$next_disp" "$RESET"
  else
    next_disp="$(truncate_disp "$nextraw" "$remw")"
    printf '%s%s%s %s%s%s %s%s%s\n' "$DIM" "$num" "$RESET" "$LBL" "$name_disp" "$RESET" "$LBL" "$next_disp" "$RESET"
  fi
}

# 稼働中・保留の見出しの件数は P_CAT の全件数（クランプ前）から数える
# （FR-72 #2「各区分の見出しの件数はlistのその区分の全行数と一致」）。
# $1（省略可）＝表示するエントリ件数の上限。省略時は全件表示（クランプ無し）。
render_next() {
  local limit="${1:--1}"
  local n=${#P_NUM[@]} i count_a=0 count_h=0
  for ((i = 0; i < n; i++)); do
    if [ "${P_CAT[$i]}" = "保留" ]; then count_h=$(( count_h + 1 )); else count_a=$(( count_a + 1 )); fi
  done

  printf '%s▶ 稼働中 (%d)%s\n' "$LBL_BOLD" "$count_a" "$RESET"
  local cols
  cols="$(cols_now)"

  local shown_n="$n"
  [ "$limit" -ge 0 ] && [ "$limit" -lt "$n" ] && shown_n="$limit"

  local cur_grp="A" printed_hold_header=0
  for ((i = 0; i < shown_n; i++)); do
    local cat="${P_CAT[$i]}" grp
    if [ "$cat" = "保留" ]; then grp="H"; else grp="A"; fi
    if [ "$grp" = "H" ] && [ "$cur_grp" != "H" ]; then
      printf '\n%s⏸ 保留 (%d)%s\n' "$DIM_BOLD" "$count_h" "$RESET"
      cur_grp="H"
      printed_hold_header=1
    fi
    _render_entry_line "$i" "$cols"
  done
  if [ "$shown_n" -lt "$n" ]; then
    printf '%s…他%d行%s\n' "$DIM" "$(( n - shown_n ))" "$RESET"
  fi
  if [ "$printed_hold_header" -eq 0 ]; then
    printf '\n%s⏸ 保留 (%d)%s\n' "$DIM_BOLD" "$count_h" "$RESET"
  fi
}

# 外部脳ヘルス行（B_*が0行ならブロックごと出さない＝FR-68・AC-97②）。
# Dock契約 cmux-dock-frame/3（health-self-explain 設計 v1.2 §6・D-3）＝
# 見出し行は出さず、B行を1行だけ `<色><kind> <text>` で描く（B行は
# lib-supply-frame.sh の validate_frame が既に高々1行に絞っている）。
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

render() {
  render_next
  printf '\n'
  render_extbrain
}

# フレームをペインの表示行数に収める（高さ超過時はエントリ行を後ろから
# 畳んで「…他N行」に置き換え、外部脳は常に残す）。稼働中・保留の見出しは
# クランプの有無に関わらず必ず出し、件数は常に未クランプの全件数
# （FR-72 #2・AC-90④＝「落ちた行の分だけ減らない」）。
compose_frame() {
  if [ -n "$FRAME_REASON" ]; then
    printf '%s\n' "$FRAME_REASON"
    return
  fi
  local n=${#P_NUM[@]}
  local ext_out n_ext n_b=${#B_KIND[@]}
  ext_out="$(render_extbrain)"
  n_ext=$n_b   # 見出し行が無い契約（/3）なのでB行数がそのまま外部脳ブロックの行数

  local rows avail
  rows=$(term_rows "$ROWS_OVERRIDE")
  avail=$(( rows - 1 ))

  if [ "$rows" -lt 4 ]; then
    render_next
    printf '\n'
    render_extbrain
    return
  fi

  # 未クランプで組んだときの行数＝3(稼働中見出し・保留見出し・その前の空行)＋n
  local full_next_lines=$(( 3 + n ))
  local total=$(( full_next_lines + 1 + n_ext ))
  if [ "$total" -le "$avail" ]; then
    render_next
    printf '\n'
    render_extbrain
    return
  fi

  # クランプが要る: 省略行1行ぶんを見込んで entry の表示件数を決める。
  local limit=$(( avail - 4 - n_ext ))
  [ "$limit" -lt 0 ] && limit=0
  [ "$limit" -gt "$n" ] && limit="$n"
  render_next "$limit"
  if [ "$n_ext" -gt 0 ]; then
    printf '\n%s\n' "$ext_out"
  fi
}

# --- 取得（供給側1回・fetch_frame） ----------------------------------------

fetch_tick() {
  fetch_frame "Project" "$SUPPLY"
  if [ -z "$FRAME_REASON" ]; then
    load_model_from_frame
  fi
  [ -n "${MODEL:-}" ] && { rm -f -- "$MODEL"; MODEL=""; }
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

供給側から1フレーム分を受け取って描くだけの常駐です（Vault・外部脳ログ・
cmux は読みません＝FR-62・FR-64）。呼び出し口は環境変数
CMUX_DOCK_SUPPLY_PROJECT で上書きできます（既定は
$HOME/work/takumi009-ai-env/cmux/cmux-next-model.sh）。供給側が無い・
応答しない・契約の版が合わないときは "AI環境 未導入" のように理由行
1行へ縮退します。

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
  local frame last_frame="" last_redraw=0 now
  while :; do
    now=$(date +%s)
    fetch_tick
    frame="$(compose_frame | sed "s/\$/${ESC}[K/")"
    if [ "$frame" != "$last_frame" ] || [ "$force_redraw" -eq 1 ] || [ $(( now - last_redraw )) -ge "$REDRAW_HEARTBEAT" ]; then
      DRAWING=1
      printf '\033[?2026h\033[H%s\n\033[J\033[?2026l' "$frame"
      DRAWING=0
      last_frame="$frame"
      last_redraw="$now"
      force_redraw=0
    fi
    sleep "$INTERVAL"
  done
}

main "$@"
