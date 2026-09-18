#!/bin/bash
# cmux Dock「Task」枠の描画（cmux-session-todo 設計 v4・§39.5）。供給側
# （ai-env の cmux-task-model.sh）が返す1ティック分のフレーム（契約
# cmux-dock-frame/2）を受け取って描くだけで、Vault・宣言記録・cmux を
# 自分では一切読まない（FR-62・FR-64）。▶（今の版）・展開・番号はすべて
# 供給側が決め、描画側はその値をそのまま描く。供給側が無い・応答しない・
# 契約の版が合わないときは理由行1行へ縮退する（FR-68）。呼び出し口は
# 環境変数 CMUX_DOCK_SUPPLY_TASK で上書きできる（既定はリポジトリ内の
# 絶対パス）。
#
# 表示例（版番号・分数・▶・展開は供給側が決めた値をそのまま描く）:
#   ▶ 1 v2                               1/3
#      [x] 要件定義
#      [/] 設計
#      [ ] 実装
#    2 v3                                0/4
#   ── 完了 1 件 ✅
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
# v4（§39.5.1）: BL_* は「V行（Uの全版）と、その直後に従属するC行（openの
# 版だけ）」をフレームの並びそのまま持つ。加えてDONE_N>=1のとき末尾に
# "D"種別の1要素を足す（完了行・D-v4-5）。DIGITSはV行番号の最大値の桁数
# （V0行なら1）。X・Hは無い（規則4）。
FRAME_REASON=""
BL_KIND=()      # "V"/"C"/"D"
BL_NUM=()       # 版番号（V行のみ）
BL_NAME=()      # 版名（V行のみ）
BL_FRAC=()      # 分数d/t（V行のみ）
BL_ARROW=()     # cur/-（V行のみ）
BL_STATE=()     # x・/・(空白1)（C行のみ）
BL_BODY=()      # 本文（C行のみ）
BL_PARENT=()    # C行が従属するV行のBL_*上の添字（V/D行は-1）
DONE_N=0
DIGITS=1

# lib-supply-frame.sh の run_supply/fetch_frame が見る一時物・PGID
# （常駐の trap から cleanup() が同じ変数を見て後始末する＝設計 §31.3）。
SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""; MODEL=""
DRAWING=0

# --- MODEL（lib-supply-frame.sh が検証済みの本体行）から表示モデルを
# 組み立てる（設計 §39.5.1）。フレームの並びはそのまま画面の並びと同じ
# （展開対象の版の直後にその子行が来る＝契約が保証する）ので、差し込み
# 直しは不要。$MODEL を1行ずつ読み、BL_* をその並びのまま埋める。
load_model_from_frame() {
  BL_KIND=(); BL_NUM=(); BL_NAME=(); BL_FRAC=(); BL_ARROW=()
  BL_STATE=(); BL_BODY=(); BL_PARENT=()
  DONE_N=0
  DIGITS=1

  local line cur_v_idx=-1 max_num=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    split_tsv "$line"
    case "${TSV_F[0]}" in
      V)
        BL_KIND+=("V")
        BL_NUM+=("${TSV_F[1]}")
        BL_NAME+=("${TSV_F[2]}")
        BL_FRAC+=("${TSV_F[3]}")
        BL_ARROW+=("${TSV_F[4]}")
        BL_STATE+=("")
        BL_BODY+=("")
        BL_PARENT+=("-1")
        cur_v_idx=$(( ${#BL_KIND[@]} - 1 ))
        if [ "${TSV_F[1]}" -gt "$max_num" ] 2>/dev/null; then
          max_num="${TSV_F[1]}"
        fi
        ;;
      C)
        BL_KIND+=("C")
        BL_NUM+=("")
        BL_NAME+=("")
        BL_FRAC+=("")
        BL_ARROW+=("")
        case "${TSV_F[1]}" in
          "[x]") BL_STATE+=("x") ;;
          "[/]") BL_STATE+=("/") ;;
          *)     BL_STATE+=(" ") ;;
        esac
        BL_BODY+=("${TSV_F[2]}")
        BL_PARENT+=("$cur_v_idx")
        ;;
      D)
        DONE_N="${TSV_F[1]}"
        ;;
    esac
  done < "$MODEL"

  if is_number "${DONE_N:-}" && [ "$DONE_N" -ge 1 ]; then
    BL_KIND+=("D")
    BL_NUM+=(""); BL_NAME+=(""); BL_FRAC+=(""); BL_ARROW+=("")
    BL_STATE+=(""); BL_BODY+=(""); BL_PARENT+=("-1")
  fi

  DIGITS="${#max_num}"
  [ "$DIGITS" -lt 1 ] && DIGITS=1
}

# --- 描画パイプライン（設計 §39.5.2）。-------------------------------------

# 版行 = M + " " + num + " " + name_disp + pad + frac（規則5・D-v4-7）。
# M は▶欄がcurなら▶、それ以外は空（幅0）。w_prefixはMの実際の表示幅から
# 導く（disp_width(M) + DIGITS + 2）＝cur行はDIGITS+3・非cur行はDIGITS+2
# （設計 §39.5.2）。
render_version_line() {
  local arrow="$1" num="$2" name="$3" frac="$4" digits="$5" cols="$6"
  local m
  if [ "$arrow" = "cur" ]; then m="▶"; else m=""; fi
  local num_disp
  num_disp="$(printf '%*d' "$digits" "$num")"

  if [ "$cols" -le 0 ]; then
    printf '%s %s %s %s' "$m" "$num_disp" "$name" "$frac"
    return
  fi

  # w_mはM（▶か空）の表示幅・w_fracはfrac（"d/t"＝常にASCII数字と/だけ）の
  # 表示幅。どちらもdisp_width（jq起動）を呼ばずシェル内で決まる（検証1
  # 巡目#4＝版行1本あたりのjq起動を4回→2回（truncate_disp・name_dispの
  # disp_widthだけ）に戻す）。
  local w_m w_frac w_prefix
  if [ "$arrow" = "cur" ]; then w_m=1; else w_m=0; fi
  w_frac="${#frac}"
  w_prefix=$(( w_m + digits + 2 ))

  if [ "$cols" -lt $(( w_prefix + w_frac + 1 )) ]; then
    local whole
    whole="$(printf '%s %s %s' "$m" "$num_disp" "$frac")"
    truncate_disp "$whole" "$cols"
    return
  fi

  local avail=$(( cols - w_prefix - 1 - w_frac ))
  local name_disp=""
  if [ "$avail" -ge 1 ]; then
    name_disp="$(truncate_disp "$name" "$avail")"
  fi
  local w_name
  w_name="$(disp_width "$name_disp")"
  local pad=$(( cols - w_prefix - w_name - w_frac ))
  [ "$pad" -lt 1 ] && pad=1
  local spaces
  spaces="$(printf '%*s' "$pad" '')"
  printf '%s %s %s%s%s' "$m" "$num_disp" "$name_disp" "$spaces" "$frac"
}

# 子行 = spaces(DIGITS+2) + "[" + s + "] " + truncate_disp(body, cols-(DIGITS+6))
render_child_line() {
  local state="$1" body="$2" digits="$3" cols="$4"
  local prefix fixed
  prefix="$(printf '%*s' $(( digits + 2 )) '')"
  fixed="${prefix}[${state}] "
  if [ "$cols" -le 0 ]; then
    printf '%s%s' "$fixed" "$body"
    return
  fi
  local avail=$(( cols - digits - 6 ))
  [ "$avail" -lt 0 ] && avail=0
  local body_disp
  body_disp="$(truncate_disp "$body" "$avail")"
  printf '%s%s' "$fixed" "$body_disp"
}

# 完了行 = truncate_disp("── 完了 " + n + " 件 ✅", cols)（Q-v4-4・D-v4-5）
render_done_line() {
  local n="$1" cols="$2"
  local text="── 完了 ${n} 件 ✅"
  if [ "$cols" -le 0 ]; then
    printf '%s' "$text"
    return
  fi
  truncate_disp "$text" "$cols"
}

# 高さのclamp（設計 §39.5.3・v3の骨格＝must-keep＋優先度で埋める＋表示順に
# 並べ直す＋末尾に「…他N行」を保ち、優先度表をv4の行種別へ差し替える）。
# K0=▶欄curの版行／K1=curの子行のうち[/]／K2=curの子行のうち[ ]／
# K3=残り全部（curの[x]子行・他の版行とその子行・完了行）を表示順に。
# rows==1はK0だけ（省略行なし）。cur_idxが必ず見つかることは、
# 「n<=rowsなら既に全行を返している」ことから保証される（DT-16）。
clamp_lines() {
  local rows="$1"
  local n=${#BL_KIND[@]}
  KEEP_IDX=()
  OMIT_N=-1

  if [ "$rows" -le 0 ] || [ "$n" -le "$rows" ]; then
    local i
    for ((i = 0; i < n; i++)); do KEEP_IDX+=("$i"); done
    return
  fi

  local cur_idx=-1 i
  for ((i = 0; i < n; i++)); do
    if [ "${BL_KIND[$i]}" = "V" ] && [ "${BL_ARROW[$i]}" = "cur" ]; then
      cur_idx=$i
      break
    fi
  done

  if [ "$rows" -eq 1 ]; then
    [ "$cur_idx" -ge 0 ] && KEEP_IDX+=("$cur_idx")
    return
  fi

  local k0=() k1=() k2=() k3=()
  [ "$cur_idx" -ge 0 ] && k0+=("$cur_idx")
  for ((i = 0; i < n; i++)); do
    [ "$i" -eq "$cur_idx" ] && continue
    if [ "${BL_KIND[$i]}" = "C" ] && [ "${BL_PARENT[$i]}" = "$cur_idx" ] && [ "${BL_STATE[$i]}" = "/" ]; then
      k1+=("$i")
    elif [ "${BL_KIND[$i]}" = "C" ] && [ "${BL_PARENT[$i]}" = "$cur_idx" ] && [ "${BL_STATE[$i]}" = " " ]; then
      k2+=("$i")
    else
      k3+=("$i")
    fi
  done

  local budget=$(( rows - 1 ))
  local take cnt selected=()

  cnt=${#k0[@]}; take=$budget; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do selected+=("${k0[$i]}"); done
  budget=$(( budget - take ))

  cnt=${#k1[@]}; take=$budget; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do selected+=("${k1[$i]}"); done
  budget=$(( budget - take ))

  cnt=${#k2[@]}; take=$budget; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do selected+=("${k2[$i]}"); done
  budget=$(( budget - take ))

  cnt=${#k3[@]}; take=$budget; [ "$take" -gt "$cnt" ] && take=$cnt
  for ((i = 0; i < take; i++)); do selected+=("${k3[$i]}"); done
  budget=$(( budget - take ))

  _sort_uint_asc "${selected[@]}"
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

  local keep_n=${#KEEP_IDX[@]} p idx
  for ((p = 0; p < keep_n; p++)); do
    idx="${KEEP_IDX[$p]}"
    case "${BL_KIND[$idx]}" in
      V)
        OUT_LINES+=("$(render_version_line "${BL_ARROW[$idx]}" "${BL_NUM[$idx]}" "${BL_NAME[$idx]}" "${BL_FRAC[$idx]}" "$DIGITS" "$cols")")
        if [ "${BL_ARROW[$idx]}" = "cur" ]; then
          OUT_COLOR+=("ACCENT")
        else
          OUT_COLOR+=("DEFAULT")
        fi
        ;;
      C)
        OUT_LINES+=("$(render_child_line "${BL_STATE[$idx]}" "${BL_BODY[$idx]}" "$DIGITS" "$cols")")
        OUT_COLOR+=("$(color_for_state "${BL_STATE[$idx]}")")
        ;;
      D)
        OUT_LINES+=("$(render_done_line "$DONE_N" "$cols")")
        OUT_COLOR+=("DIM")
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
cmux は読みません＝FR-62・FR-64）。▶（今の版）・展開・番号はすべて
供給側が決めます。呼び出し口は環境変数
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
