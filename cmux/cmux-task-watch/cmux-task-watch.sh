#!/bin/bash
# cmux Dock「Task」枠の描画（cmux-session-todo 設計 v3・C-18）。供給側
# （ai-env の cmux-task-model.sh）が返す1ティック分のフレームを受け取って
# 描くだけで、Vault・宣言記録・cmux を自分では一切読まない（FR-62・FR-64）。
# 供給側が無い・応答しない・契約の版が合わないときは理由行1行へ縮退する
# （FR-68）。呼び出し口は環境変数 CMUX_DOCK_SUPPLY_TASK で上書きできる
# （既定はリポジトリ内の絶対パス）。
#
# 表示例（子行の番号は供給側が採番した値をそのまま描く＝FR-63）:
#   ▶ cmux-session-todo  v2 1/3
#   v1 ✅ 3/3
#   v2 ▶ 1/3
#    ├ 1 [x] 要件定義
#    ├ 2 [/] 設計
#    └ 3 [ ] 実装
#   v3 ・ 0/4
#
# 引数: （なし）＝常駐 / --once＝1フレーム色付きで出して終了 / --plain＝1フレーム
# 平文で出して終了（--once と併用可・単独でも1回で終わる）。
# --list は供給側（cmux-task-model.sh --list）へ移設済みで、この常駐は
# 提供しない（既知の引数として usage を出し rc=1・常駐モードへは落ちない
# ＝F-56）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)/.."
if [ ! -r "$LIB_DIR/lib-dock-view.sh" ]; then
  echo "lib-dock-view.sh が見つかりません: $LIB_DIR/lib-dock-view.sh" >&2
  exit 1
fi
if [ ! -r "$LIB_DIR/lib-supply-frame.sh" ]; then
  echo "lib-supply-frame.sh が見つかりません: $LIB_DIR/lib-supply-frame.sh" >&2
  exit 1
fi
# shellcheck source=../lib-dock-view.sh
. "$LIB_DIR/lib-dock-view.sh"
# shellcheck source=../lib-supply-frame.sh
. "$LIB_DIR/lib-supply-frame.sh"

# --- 設定 -------------------------------------------------------------
SUPPLY="${CMUX_DOCK_SUPPLY_TASK:-$HOME/work/takumi009-ai-env/cmux/cmux-task-model.sh}"
FOCUS_INTERVAL="$(sanitize_interval "${CMUX_TASK_FOCUS_INTERVAL:-}" 2)"
REDRAW_HEARTBEAT="$(sanitize_interval "${CMUX_TASK_REDRAW_HEARTBEAT:-}" 600)"
COLS_OVERRIDE="${CMUX_TASK_COLS:-}"
ROWS_OVERRIDE="${CMUX_TASK_ROWS:-}"

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
ACCENT="${ESC}[38;5;114;1m"
DEFAULT_C="${ESC}[38;5;252m"

# --- フレーム由来のモデル（1ティックぶん・set -u 下の未初期化対策で空へ） --
FRAME_REASON=""
MODEL_SLUG=""; MODEL_SYM=""; MODEL_LEADWORD=""; MODEL_VERNAME=""; MODEL_FRAC=""
V_NAME=(); V_TOTAL=(); V_DONE=()
BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()

# lib-supply-frame.sh の run_supply/fetch_frame が見る一時物・PGID
# （常駐の trap から cleanup() が同じ変数を見て後始末する＝設計 §31.3）。
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""; MODEL=""
DRAWING=0

# --- MODEL（lib-supply-frame.sh が検証済みの本体行）から表示モデルを
# 組み立てる（設計 §31.4＝表示規則は1つも変えない。データの出どころだけが
# Vault からフレームへ変わる）。$MODEL を1行ずつ読み、BL_*/NR_* を
# load_model() 相当の形で埋める。
load_model_from_frame() {
  MODEL_SLUG=""; MODEL_SYM=""; MODEL_LEADWORD=""; MODEL_VERNAME=""; MODEL_FRAC=""
  BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
  NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()

  # フレームの並びは契約上 H→V*→C*→X で固定（§29.2）だが、画面は
  # 「展開対象の版の直後にその子行を挟む」形（v2の記載順）を保つ。ここで
  # 一度 V・C を別々の一時配列へ集め、X が指す版の直後へ子行を差し込んで
  # BL_* を組み立て直す。
  local line vn=0 cn=0 x_raw=""
  local vname_a=() vsym_a=() vfrac_a=()
  local cstate_a=() cbody_a=() cnum_a=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    split_tsv "$line"
    case "${TSV_F[0]}" in
      H)
        MODEL_SYM="${TSV_F[1]}"
        MODEL_SLUG="${TSV_F[2]}"
        MODEL_LEADWORD="${TSV_F[3]}"
        MODEL_VERNAME="${TSV_F[4]}"
        MODEL_FRAC="${TSV_F[5]}"
        ;;
      V)
        vn=$(( vn + 1 ))
        vname_a+=("${TSV_F[1]}")
        vsym_a+=("${TSV_F[2]}")
        vfrac_a+=("${TSV_F[3]}")
        ;;
      C)
        cn=$(( cn + 1 ))
        cnum_a+=("${TSV_F[1]}")
        cstate_a+=("${TSV_F[2]}")
        cbody_a+=("${TSV_F[3]}")
        ;;
      X)
        x_raw="${TSV_F[1]}"
        ;;
    esac
  done < "$MODEL"

  local i j
  for ((i = 0; i < vn; i++)); do
    local is_expand=0
    if [ -n "$x_raw" ] && [ "$x_raw" != "-" ] && [ "$x_raw" -eq $(( i + 1 )) ] 2>/dev/null; then
      is_expand=1
    fi
    if [ "$is_expand" -eq 1 ]; then
      BL_KIND+=("VE")
    else
      BL_KIND+=("VC")
    fi
    BL_A+=("${vsym_a[$i]}")
    BL_B+=("${vname_a[$i]}")
    BL_C+=("${vfrac_a[$i]}")

    if [ "$is_expand" -eq 1 ]; then
      for ((j = 0; j < cn; j++)); do
        local st="${cstate_a[$j]}" kind_c stc
        case "$st" in
          "[x]") kind_c="CX"; stc="x" ;;
          "[/]") kind_c="CS"; stc="/" ;;
          *)     kind_c="CB"; stc=" " ;;
        esac
        BL_KIND+=("$kind_c")
        BL_A+=("$stc")
        BL_B+=("${cbody_a[$j]}")
        BL_C+=("")
        NR_BLIDX+=($(( ${#BL_KIND[@]} - 1 )))
        NR_NUM+=("${cnum_a[$j]}")
        NR_STATE+=("$stc")
        NR_BODY+=("${cbody_a[$j]}")
      done
    fi
  done
}

# --- 描画パイプライン（設計 §31.4・表示規則は不変。v2 の実装をそのまま
# 引き継ぐ）。--------------------------------------------------------------

compose_field() {
  local leadword="$1" vername="$2" frac="$3"
  if [ -n "$vername" ]; then
    printf '%s%s %s' "$leadword" "$vername" "$frac"
  elif [ -n "$leadword" ]; then
    printf '%s %s' "$leadword" "$frac"
  else
    printf '%s' "$frac"
  fi
}

render_header_line() {
  local sym="$1" name="$2" leadword="$3" vername="$4" frac="$5" cols="$6"
  local field w_sym w_name w_field need name_disp
  field="$(compose_field "$leadword" "$vername" "$frac")"
  w_sym="$(disp_width "$sym")"
  w_name="$(disp_width "$name")"
  w_field="$(disp_width "$field")"
  need=$(( w_sym + 1 + 2 + w_field ))

  if [ "$cols" -le 0 ] || [ $(( need + w_name )) -le "$cols" ]; then
    printf '%s %s  %s' "$sym" "$name" "$field"
    return
  fi

  local avail_name=$(( cols - need ))
  [ "$avail_name" -lt 10 ] && avail_name=10
  name_disp="$(truncate_disp "$name" "$avail_name")"
  w_name="$(disp_width "$name_disp")"
  if [ $(( need + w_name )) -le "$cols" ]; then
    printf '%s %s  %s' "$sym" "$name_disp" "$field"
    return
  fi

  local w_lead w_frac avail_ver vername_disp full_w
  w_lead="$(disp_width "$leadword")"
  w_frac="$(disp_width "$frac")"
  avail_ver=$(( cols - w_sym - 1 - 2 - w_name - w_lead - w_frac - 1 ))
  [ "$avail_ver" -lt 0 ] && avail_ver=0
  vername_disp="$(truncate_disp "$vername" "$avail_ver")"
  field="$(compose_field "$leadword" "$vername_disp" "$frac")"
  full_w=$(( w_sym + 1 + w_name + 2 + $(disp_width "$field") ))
  if [ "$full_w" -le "$cols" ]; then
    printf '%s %s  %s' "$sym" "$name_disp" "$field"
    return
  fi

  printf '%s %s' "$sym" "$frac"
}

render_version_line() {
  local sym="$1" vername="$2" frac="$3" cols="$4"
  local fixed w_fixed avail vername_disp
  fixed=" $sym $frac"
  if [ "$cols" -le 0 ]; then
    printf '%s%s' "$vername" "$fixed"
    return
  fi
  w_fixed="$(disp_width "$fixed")"
  avail=$(( cols - w_fixed ))
  [ "$avail" -lt 0 ] && avail=0
  vername_disp="$(truncate_disp "$vername" "$avail")"
  printf '%s%s' "$vername_disp" "$fixed"
}

render_child_line() {
  local arrow="$1" num="$2" state="$3" body="$4" cols="$5"
  local fixed w_fixed avail body_disp
  fixed=" ${arrow} ${num} [${state}] "
  if [ "$cols" -le 0 ]; then
    printf '%s%s' "$fixed" "$body"
    return
  fi
  w_fixed="$(disp_width "$fixed")"
  avail=$(( cols - w_fixed ))
  [ "$avail" -lt 0 ] && avail=0
  body_disp="$(truncate_disp "$body" "$avail")"
  printf '%s%s' "$fixed" "$body_disp"
}

clamp_lines() {
  local rows="$1"
  local n=${#BL_KIND[@]}
  KEEP_IDX=()
  OMIT_N=-1
  HEADER_ONLY=0

  if [ "$rows" -le 0 ]; then
    local i
    for ((i = 0; i < n; i++)); do KEEP_IDX+=("$i"); done
    return
  fi
  if [ "$rows" -eq 1 ]; then
    HEADER_ONLY=1
    return
  fi
  if [ "$rows" -eq 2 ]; then
    OMIT_N=$n
    return
  fi

  local total=$(( 1 + n ))
  if [ "$total" -le "$rows" ]; then
    local i
    for ((i = 0; i < n; i++)); do KEEP_IDX+=("$i"); done
    return
  fi

  local must_idx=() i
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      VE|CS) must_idx+=("$i") ;;
    esac
  done
  local must_n=${#must_idx[@]}
  local must_incl_header=$(( 1 + must_n ))

  if [ $(( must_incl_header + 1 )) -gt "$rows" ]; then
    local keep_n=$(( rows - 2 ))
    [ "$keep_n" -lt 0 ] && keep_n=0
    local k
    for ((k = 0; k < keep_n && k < must_n; k++)); do
      KEEP_IDX+=("${must_idx[$k]}")
    done
    OMIT_N=$(( n - ${#KEEP_IDX[@]} ))
    return
  fi

  local room=$(( rows - must_incl_header - 1 ))
  local cb_idx=() cx_idx=() vc_idx=()
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      CB) cb_idx+=("$i") ;;
      CX) cx_idx+=("$i") ;;
      VC) vc_idx+=("$i") ;;
    esac
  done

  local extra_idx=()
  local take cnt

  cnt=${#cb_idx[@]}
  take=$room; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do extra_idx+=("${cb_idx[$i]}"); done
  room=$(( room - take ))

  cnt=${#cx_idx[@]}
  take=$room; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do extra_idx+=("${cx_idx[$i]}"); done
  room=$(( room - take ))

  cnt=${#vc_idx[@]}
  take=$room; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do extra_idx+=("${vc_idx[$i]}"); done
  room=$(( room - take ))

  local all_idx=("${must_idx[@]}" "${extra_idx[@]}")
  _sort_uint_asc "${all_idx[@]}"
  KEEP_IDX=("${SORTED_IDX[@]}")
  OMIT_N=$(( n - ${#KEEP_IDX[@]} ))
}

# 非負整数の配列を昇順に並べ替える（挿入ソート・sort非依存＝FR-64の許可表に
# 無いためbash純正の実装に置き換える＝検証1巡目 #10）。結果は SORTED_IDX へ。
# 要素数は端末の行数に収まる程度（高々数百）なので O(n^2) で十分。
_sort_uint_asc() {
  local arr=("$@") i j key
  local n=${#arr[@]}
  for ((i = 1; i < n; i++)); do
    key="${arr[$i]}"
    j=$(( i - 1 ))
    while [ "$j" -ge 0 ] && [ "${arr[$j]}" -gt "$key" ]; do
      arr[$(( j + 1 ))]="${arr[$j]}"
      j=$(( j - 1 ))
    done
    arr[$(( j + 1 ))]="$key"
  done
  SORTED_IDX=("${arr[@]}")
}

render() {
  local cols="$1" rows="$2"
  OUT_LINES=()
  OUT_COLOR=()

  if [ -n "$FRAME_REASON" ]; then
    local line
    if [ "$cols" -gt 0 ]; then
      line="$(truncate_disp "$FRAME_REASON" "$cols")"
    else
      line="$FRAME_REASON"
    fi
    OUT_LINES+=("$line")
    OUT_COLOR+=("DEFAULT")
    return
  fi

  clamp_lines "$rows"

  if [ "$HEADER_ONLY" -eq 1 ]; then
    local hline
    hline="$(render_header_line "$MODEL_SYM" "$MODEL_SLUG" "$MODEL_LEADWORD" "$MODEL_VERNAME" "$MODEL_FRAC" "$cols")"
    OUT_LINES+=("$hline")
    OUT_COLOR+=("$(color_for_sym "$MODEL_SYM")")
    return
  fi

  local hline
  hline="$(render_header_line "$MODEL_SYM" "$MODEL_SLUG" "$MODEL_LEADWORD" "$MODEL_VERNAME" "$MODEL_FRAC" "$cols")"
  OUT_LINES+=("$hline")
  OUT_COLOR+=("$(color_for_sym "$MODEL_SYM")")

  local keep_n=${#KEEP_IDX[@]}
  local last_child_pos=-1 p idx
  for ((p = 0; p < keep_n; p++)); do
    idx="${KEEP_IDX[$p]}"
    case "${BL_KIND[$idx]}" in
      CX|CS|CB) last_child_pos=$p ;;
    esac
  done

  local child_n="${#NR_NUM[@]}" digits
  digits="${#child_n}"
  [ "$digits" -lt 1 ] && digits=1

  local nr_ptr=0
  for ((p = 0; p < keep_n; p++)); do
    idx="${KEEP_IDX[$p]}"
    local kind="${BL_KIND[$idx]}" a="${BL_A[$idx]}" b="${BL_B[$idx]}" c="${BL_C[$idx]}"
    case "$kind" in
      VE|VC)
        OUT_LINES+=("$(render_version_line "$a" "$b" "$c" "$cols")")
        OUT_COLOR+=("$(color_for_sym "$a")")
        ;;
      CX|CS|CB)
        while [ "$nr_ptr" -lt "${#NR_BLIDX[@]}" ] && [ "${NR_BLIDX[$nr_ptr]}" -ne "$idx" ]; do
          nr_ptr=$(( nr_ptr + 1 ))
        done
        local num_disp
        num_disp="$(printf '%*d' "$digits" "${NR_NUM[$nr_ptr]}")"
        nr_ptr=$(( nr_ptr + 1 ))
        local arrow="├"
        [ "$p" -eq "$last_child_pos" ] && arrow="└"
        OUT_LINES+=("$(render_child_line "$arrow" "$num_disp" "$a" "$b" "$cols")")
        OUT_COLOR+=("$(color_for_state "$a")")
        ;;
    esac
  done

  if [ "$OMIT_N" -ge 0 ]; then
    local omit_line
    omit_line="…他${OMIT_N}行"
    if [ "$cols" -gt 0 ]; then
      omit_line="$(truncate_disp "$omit_line" "$cols")"
    fi
    OUT_LINES+=("$omit_line")
    OUT_COLOR+=("DEFAULT")
  fi
}

color_for_sym() {
  case "$1" in
    "✅") printf 'DIM' ;;
    "▶") printf 'ACCENT' ;;
    *) printf 'DEFAULT' ;;
  esac
}

color_for_state() {
  case "$1" in
    x) printf 'DIM' ;;
    /) printf 'ACCENT' ;;
    *) printf 'DEFAULT' ;;
  esac
}

color_code() {
  case "$1" in
    DIM) printf '%s' "$DIM" ;;
    ACCENT) printf '%s' "$ACCENT" ;;
    *) printf '%s' "$DEFAULT_C" ;;
  esac
}

compose_colored_frame() {
  local cols="$1" rows="$2" i n
  render "$cols" "$rows"
  n=${#OUT_LINES[@]}
  for ((i = 0; i < n; i++)); do
    printf '%s%s%s' "$(color_code "${OUT_COLOR[$i]}")" "${OUT_LINES[$i]}" "$RESET"
    [ $(( i + 1 )) -lt "$n" ] && printf '\n'
  done
}

compose_plain_frame() {
  local cols="$1" rows="$2" i n
  render "$cols" "$rows"
  n=${#OUT_LINES[@]}
  for ((i = 0; i < n; i++)); do
    printf '%s' "${OUT_LINES[$i]}"
    [ $(( i + 1 )) -lt "$n" ] && printf '\n'
  done
}

# --- 取得（供給側1回・fetch_frame）----------------------------------------

fetch_tick() {
  fetch_frame "Task" "$SUPPLY"
  if [ -z "$FRAME_REASON" ]; then
    load_model_from_frame
  fi
  [ -n "${MODEL:-}" ] && { rm -f -- "$MODEL"; MODEL=""; }
}

# --- 起動口 ---------------------------------------------------------------

run_once() {
  local plain="$1"
  local cols rows
  cols="$(term_cols "$COLS_OVERRIDE")"
  rows="$(term_rows "$ROWS_OVERRIDE")"

  fetch_tick

  if [ "$plain" -eq 1 ]; then
    compose_plain_frame "$cols" "$rows"
    printf '\n'
  else
    printf '\033[?2026h'
    compose_colored_frame "$cols" "$rows"
    printf '\n\033[?2026l'
  fi
}

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
force_redraw=0

run_daemon() {
  printf '\033]2;Task\007'
  printf '\033[?25l'
  trap 'force_redraw=1' WINCH
  trap 'on_exit; exit 0' INT TERM HUP
  trap 'on_exit' EXIT

  local last_frame="" last_redraw=0
  printf '\033[2J'

  while :; do
    local now
    now=$(date +%s)

    fetch_tick

    local cols rows frame
    cols="$(term_cols "$COLS_OVERRIDE")"
    rows="$(term_rows "$ROWS_OVERRIDE")"
    frame="$(compose_colored_frame "$cols" "$rows" | sed "s/\$/${ESC}[K/")"

    if [ "$frame" != "$last_frame" ] || [ "$force_redraw" -eq 1 ] || [ $(( now - last_redraw )) -ge "$REDRAW_HEARTBEAT" ]; then
      DRAWING=1
      printf '\033[?2026h\033[H%s\033[J\033[?2026l' "$frame"
      DRAWING=0
      last_frame="$frame"
      last_redraw="$now"
      force_redraw=0
    fi

    sleep "$FOCUS_INTERVAL"
  done
}

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-task-watch.sh [--once] [--plain]

供給側から1フレーム分を受け取って描くだけの常駐です（Vault・宣言記録・
cmux は読みません＝FR-62・FR-64）。呼び出し口は環境変数
CMUX_DOCK_SUPPLY_TASK で上書きできます（既定は
$HOME/work/takumi009-ai-env/cmux/cmux-task-model.sh）。供給側が無い・
応答しない・契約の版が合わないときは "AI環境 未導入" のように理由行
1行へ縮退します。

--list は供給側（cmux-task-model.sh --list）へ移設済みで、この常駐は
提供しません。
EOF
}

main() {
  local once=0 plain=0 a
  for a in "$@"; do
    case "$a" in
      --once) once=1 ;;
      --plain) plain=1; once=1 ;;
      *) usage; exit 1 ;;
    esac
  done

  if [ "$once" -eq 1 ]; then
    run_once "$plain"
    exit 0
  fi
  run_daemon
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
