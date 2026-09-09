#!/bin/bash
# cmux Dock 4枠目「Next Task」の描画（cmux-session-todo 設計 §4）。表示専用
# （Vault にも cmux にも書き込まない＝FR-23）。フォーカス中のワークスペース
# の宣言先プロジェクト（cmux-task-declare.sh set で宣言）の Tasks 節を、
# ヘッダー行＋版行＋展開対象の版の子行として表示する（FR-21）。
#
# 表示例:
#   ▶ cmux-session-todo  v2 1/3
#   v1 ✅ 3/3
#   v2 ▶ 1/3
#    ├ [x] 要件定義
#    ├ [/] 設計
#    └ [ ] 実装
#   v3 ・ 0/4
#
# 引数: （なし）＝常駐 / --once＝1フレーム色付きで出して終了 / --plain＝1フレーム
# 平文で出して終了（--once と併用可・単独でも1回で終わる＝設計 §4.1）。
#
# bash 3.2 互換（macOS標準bash）。連想配列・mapfileは使わない。

set -u

LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)/.."
if [ ! -r "$LIB_DIR/lib-dock-view.sh" ]; then
  echo "lib-dock-view.sh が見つかりません: $LIB_DIR/lib-dock-view.sh" >&2
  exit 1
fi
if [ ! -r "$LIB_DIR/lib-vault-tasks.sh" ]; then
  echo "lib-vault-tasks.sh が見つかりません: $LIB_DIR/lib-vault-tasks.sh" >&2
  exit 1
fi
# shellcheck source=../lib-dock-view.sh
. "$LIB_DIR/lib-dock-view.sh"
# shellcheck source=../lib-vault-tasks.sh
. "$LIB_DIR/lib-vault-tasks.sh"

# --- 設定（利用者向け3つ＋テスト・実験用の上書き口＝設計 §4.1・§13 D-1） ---
VAULT="${CMUX_TASK_VAULT:-$HOME/Data/obsidian}"
STATE_FILE="${CMUX_TASK_STATE:-$HOME/.config/cmux-task-watch/workspaces.json}"
INTERVAL="$(sanitize_interval "${CMUX_TASK_INTERVAL:-}" 60)"
FOCUS_INTERVAL="$(sanitize_interval "${CMUX_TASK_FOCUS_INTERVAL:-}" 2)"
# FOCUS_INTERVAL は 1 <= v <= INTERVAL へ丸める（設計 §4.1）。
[ "$FOCUS_INTERVAL" -lt 1 ] && FOCUS_INTERVAL=1
[ "$FOCUS_INTERVAL" -gt "$INTERVAL" ] && FOCUS_INTERVAL="$INTERVAL"
CALL_TIMEOUT="$(sanitize_interval "${CMUX_TASK_CALL_TIMEOUT:-}" 5)"
REDRAW_HEARTBEAT="$(sanitize_interval "${CMUX_TASK_REDRAW_HEARTBEAT:-}" 600)"
CMUX_BIN="${CMUX_TASK_CMUX_BIN:-cmux}"
COLS_OVERRIDE="${CMUX_TASK_COLS:-}"
ROWS_OVERRIDE="${CMUX_TASK_ROWS:-}"

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
ACCENT="${ESC}[38;5;114;1m"
DEFAULT_C="${ESC}[38;5;252m"

# set -u 下で「未評価のまま参照される」経路（例: CMUX_REASON が立って
# load_model を1度も呼ばないティック）でも unbound variable にならないよう、
# モデル系グローバルは起動時に空へ初期化しておく。
CMUX_REASON=""
CMUX_UUID=""
MODEL_REASON=""
MODEL_SLUG=""
MODEL_SYM=""
MODEL_LEADWORD=""
MODEL_VERNAME=""
MODEL_FRAC=""
V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
BL_KIND=(); BL_A=(); BL_B=(); BL_C=()

# --- 記録ファイル（読むだけ・書かない） ---------------------------------

# 記録ファイルの破損判定（設計 §3.1 と同一式）。ファイル不在は破損ではない。
state_is_corrupt() {
  [ -f "$STATE_FILE" ] || return 1
  jq -s -e '
    length == 1
    and (.[0] | type == "object")
    and (.[0].version == 1)
    and (.[0].workspaces | type == "object")
    and (.[0].workspaces | to_entries | all(.value | type == "string"))
  ' "$STATE_FILE" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] && return 1
  return 0
}

# UUID に対応する slug を stdout へ出す（無ければ空）。呼び出し側は
# state_is_corrupt を先に確認していること。
lookup_slug() {
  local uuid="$1"
  [ -f "$STATE_FILE" ] || return 0
  jq -r --arg u "$uuid" '(.workspaces // {})[$u] // empty' "$STATE_FILE" 2>/dev/null
}

# slug が FR-34 を満たすか判定する。
slug_valid() {
  local s="$1"
  case "$s" in
    '') return 1 ;;
    .|..) return 1 ;;
  esac
  case "$s" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# --- cmux 側（段A・毎ティック評価） ---------------------------------------

# cmux identify / workspace list を1回ずつ呼び、フォーカス中ワークスペース
# の UUID を解決する。成功時は CMUX_UUID に UUID を、失敗時は CMUX_REASON に
# §7 順1・順2 の理由行を入れる（両方成功かつ解決できたときは CMUX_REASON=""）。
probe_focus_uuid() {
  local ident_raw ident_rc wslist_raw wslist_rc focus_ref
  CMUX_REASON=""
  CMUX_UUID=""

  ident_raw="$(run_with_timeout "$CALL_TIMEOUT" "$CMUX_BIN" --json identify 2>/dev/null)"
  ident_rc=$?
  wslist_raw="$(run_with_timeout "$CALL_TIMEOUT" "$CMUX_BIN" --json workspace list 2>/dev/null)"
  wslist_rc=$?

  if [ "$ident_rc" -ne 0 ] || [ "$wslist_rc" -ne 0 ]; then
    CMUX_REASON="cmux 応答なし"
    return
  fi

  focus_ref="$(printf '%s' "$ident_raw" | jq -r '.focused.workspace_ref // empty' 2>/dev/null)"
  CMUX_UUID="$(printf '%s' "$wslist_raw" | jq -r --arg r "$focus_ref" '
    (.workspaces // [])[] | select(.ref == $r) | .id
  ' 2>/dev/null | head -n1)"
  if [ -z "$CMUX_UUID" ]; then
    CMUX_REASON="対象不明"
  fi
}

# --- Vault 側（段B・再読込のときだけ評価＝順3〜順10） ---------------------

# UUID から表示モデルを組み立てる。以下のグローバルを設定する。
#   MODEL_REASON      : 非空なら理由行（順3〜10）。空なら通常表示（順11）
#   MODEL_SLUG        : プロジェクト名（宣言された slug）
#   MODEL_SYM/MODEL_LEADWORD/MODEL_VERNAME/MODEL_FRAC : ヘッダーの版欄（FR-35）
#   BL_KIND/BL_A/BL_B/BL_C : 版行＋展開対象の子行（クランプ前・記載順）
#     VE/VC: A=記号 B=版名 C=分数"done/total"
#     CX/CS/CB: A=状態1文字 B=タスク本文 C=（未使用）
load_model() {
  local uuid="$1"
  MODEL_REASON=""
  MODEL_SLUG=""
  MODEL_SYM=""
  MODEL_LEADWORD=""
  MODEL_VERNAME=""
  MODEL_FRAC=""
  V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
  BL_KIND=(); BL_A=(); BL_B=(); BL_C=()

  if state_is_corrupt; then
    MODEL_REASON="宣言記録破損"
    return
  fi

  local slug
  slug="$(lookup_slug "$uuid")"
  if [ -z "$slug" ]; then
    MODEL_REASON="未宣言"
    return
  fi
  MODEL_SLUG="$slug"

  if [ ! -d "$VAULT" ]; then
    MODEL_REASON="Vault 不在"
    return
  fi

  # slug が FR-34 に反する場合はパスを組み立てずに「ノート不在」扱い
  # （§10 F-9・パストラバーサル対策）。
  if ! slug_valid "$slug"; then
    MODEL_REASON="ノート不在"
    return
  fi
  local note="$VAULT/Projects/$slug.md"
  if [ ! -f "$note" ]; then
    MODEL_REASON="ノート不在"
    return
  fi

  local tsv rc
  tsv="$(read_note "$note")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    MODEL_REASON="ノート破損"
    return
  fi

  # TSV → 版・タスクの配列化
  local vcount=0 cur_vi=-1
  local task_vidx=() task_state=() task_body=()
  local kind a b
  while IFS="$(printf '\t')" read -r kind a b; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "V" ]; then
      V_NAME+=("$a")
      V_TOTAL+=(0)
      V_DONE+=(0)
      V_HASSLASH+=(0)
      cur_vi=$vcount
      vcount=$(( vcount + 1 ))
    elif [ "$kind" = "T" ]; then
      [ "$cur_vi" -ge 0 ] || continue
      V_TOTAL[$cur_vi]=$(( V_TOTAL[$cur_vi] + 1 ))
      case "$a" in
        x) V_DONE[$cur_vi]=$(( V_DONE[$cur_vi] + 1 )) ;;
        /) V_HASSLASH[$cur_vi]=1 ;;
      esac
      task_vidx+=("$cur_vi")
      task_state+=("$a")
      task_body+=("$b")
    fi
  done <<TSV_EOF
$tsv
TSV_EOF

  if [ "$vcount" -eq 0 ]; then
    MODEL_REASON="Tasks 節なし"
    return
  fi

  local i total_all=0
  for ((i = 0; i < vcount; i++)); do
    total_all=$(( total_all + V_TOTAL[i] ))
  done
  if [ "$total_all" -eq 0 ]; then
    MODEL_REASON="タスクなし"
    return
  fi

  local n_tasks=${#task_body[@]}
  if [ "$n_tasks" -gt 0 ]; then
    for ((i = 0; i < n_tasks; i++)); do
      if [ -z "${task_body[$i]}" ]; then
        MODEL_REASON="空タスク"
        return
      fi
    done
  fi

  # 展開対象の決定（FR-27）
  local expand=-1
  for ((i = 0; i < vcount; i++)); do
    if [ "${V_HASSLASH[$i]}" -eq 1 ]; then
      expand=$i
      break
    fi
  done
  if [ "$expand" -lt 0 ]; then
    for ((i = 0; i < vcount; i++)); do
      if [ "${V_DONE[$i]}" -lt "${V_TOTAL[$i]}" ]; then
        expand=$i
        break
      fi
    done
  fi

  # ヘッダーの状態（FR-35）
  if [ "$expand" -ge 0 ] && [ "${V_HASSLASH[$expand]}" -eq 1 ]; then
    MODEL_SYM="▶"; MODEL_LEADWORD=""; MODEL_VERNAME="${V_NAME[$expand]}"
    MODEL_FRAC="${V_DONE[$expand]}/${V_TOTAL[$expand]}"
  elif [ "$expand" -ge 0 ]; then
    MODEL_SYM="・"; MODEL_LEADWORD="次: "; MODEL_VERNAME="${V_NAME[$expand]}"
    MODEL_FRAC="${V_DONE[$expand]}/${V_TOTAL[$expand]}"
  else
    MODEL_SYM="✅"; MODEL_LEADWORD="全版完了"; MODEL_VERNAME=""
    local done_v=0
    for ((i = 0; i < vcount; i++)); do
      if [ "${V_TOTAL[$i]}" -ge 1 ] && [ "${V_DONE[$i]}" -eq "${V_TOTAL[$i]}" ]; then
        done_v=$(( done_v + 1 ))
      fi
    done
    MODEL_FRAC="${done_v}/${vcount}"
  fi

  # BL_* の組み立て（版行＋展開対象版の子行・記載順）
  local j sym_i
  for ((i = 0; i < vcount; i++)); do
    if [ "${V_TOTAL[$i]}" -ge 1 ] && [ "${V_DONE[$i]}" -eq "${V_TOTAL[$i]}" ]; then
      sym_i="✅"
    elif [ "${V_HASSLASH[$i]}" -eq 1 ]; then
      sym_i="▶"
    else
      sym_i="・"
    fi
    if [ "$i" -eq "$expand" ]; then
      BL_KIND+=("VE")
    else
      BL_KIND+=("VC")
    fi
    BL_A+=("$sym_i")
    BL_B+=("${V_NAME[$i]}")
    BL_C+=("${V_DONE[$i]}/${V_TOTAL[$i]}")

    if [ "$i" -eq "$expand" ] && [ "$n_tasks" -gt 0 ]; then
      for ((j = 0; j < n_tasks; j++)); do
        if [ "${task_vidx[$j]}" -eq "$i" ]; then
          case "${task_state[$j]}" in
            x) BL_KIND+=("CX") ;;
            /) BL_KIND+=("CS") ;;
            *) BL_KIND+=("CB") ;;
          esac
          BL_A+=("${task_state[$j]}")
          BL_B+=("${task_body[$j]}")
          BL_C+=("")
        fi
      done
    fi
  done
}

# --- 描画パイプライン（C-1・§6） -----------------------------------------

# 版欄（field）を leadword・vername・frac から組み立てる。
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

# ヘッダー行を組み立てる（FR-46・§6.1 の3段切り詰め）。
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

  # 第2段: 版名を削る（先頭語・分数は残す。0セルまで削ってよい）
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

  # 第3段: 記号と分数だけ
  printf '%s %s' "$sym" "$frac"
}

# 版行を組み立てる（FR-28。固定部=" {sym} {frac}"・版名だけを切り詰める）。
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

# 子行を組み立てる（FR-29。固定部=" {罫線} [{state}] "・本文だけを切り詰める）。
render_child_line() {
  local arrow="$1" state="$2" body="$3" cols="$4"
  local fixed w_fixed avail body_disp
  fixed=" ${arrow} [${state}] "
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

# クランプ（FR-30・§6.3の退化規則）。BL_* を読み、次を設定する。
#   KEEP_IDX  : 残す BL_* のインデックス（記載順）の配列
#   OMIT_N    : 省略行に出す件数。-1 なら省略行を出さない
#   HEADER_ONLY : 1 なら §6.3 の rows=1（ヘッダーのみ）
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

  # must = ヘッダー(別枠) + 展開対象の版行(VE) + すべての CS
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
  local keep_flag_cb=() keep_flag_cx=() keep_flag_vc=()
  # cls 別のインデックス列（記載順）を作る
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

  # must_idx と extra_idx を合わせて元の記載順へソート（単純な数値ソート）
  local all_idx=("${must_idx[@]}" "${extra_idx[@]}")
  KEEP_IDX=($(printf '%s\n' "${all_idx[@]}" | sort -n))
  OMIT_N=$(( n - ${#KEEP_IDX[@]} ))
}

# render(): MODEL_REASON があれば理由行、無ければ通常表示を組み立てる。
# 結果は OUT_LINES[]（テキスト・切り詰め済み・色コード無し）と
# OUT_COLOR[]（対応する色区分: DIM/ACCENT/DEFAULT）に入れる。
render() {
  local cols="$1" rows="$2"
  OUT_LINES=()
  OUT_COLOR=()

  local reason="${CMUX_REASON}${MODEL_REASON}"
  if [ -n "$reason" ]; then
    local line
    if [ "$cols" -gt 0 ]; then
      line="$(truncate_disp "$reason" "$cols")"
    else
      line="$reason"
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
  # 罫線: 残った子行（CX/CS/CB）のうち最後の1件だけ└、他は├
  local last_child_pos=-1 p idx
  for ((p = 0; p < keep_n; p++)); do
    idx="${KEEP_IDX[$p]}"
    case "${BL_KIND[$idx]}" in
      CX|CS|CB) last_child_pos=$p ;;
    esac
  done

  for ((p = 0; p < keep_n; p++)); do
    idx="${KEEP_IDX[$p]}"
    local kind="${BL_KIND[$idx]}" a="${BL_A[$idx]}" b="${BL_B[$idx]}" c="${BL_C[$idx]}"
    case "$kind" in
      VE|VC)
        OUT_LINES+=("$(render_version_line "$a" "$b" "$c" "$cols")")
        OUT_COLOR+=("$(color_for_sym "$a")")
        ;;
      CX|CS|CB)
        local arrow="├"
        [ "$p" -eq "$last_child_pos" ] && arrow="└"
        OUT_LINES+=("$(render_child_line "$arrow" "$a" "$b" "$cols")")
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

# 記号（✅/▶/・）から色区分を返す（FR-24）。
color_for_sym() {
  case "$1" in
    "✅") printf 'DIM' ;;
    "▶") printf 'ACCENT' ;;
    *) printf 'DEFAULT' ;;
  esac
}

# タスク状態1文字（x//・空白）から色区分を返す（FR-24）。
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

# --- フレーム組み立て（モード別・§4.6） -----------------------------------

# 色付きの1フレーム文字列（行を \n 区切り）を stdout へ出す。
compose_colored_frame() {
  local cols="$1" rows="$2" i n
  render "$cols" "$rows"
  n=${#OUT_LINES[@]}
  for ((i = 0; i < n; i++)); do
    printf '%s%s%s' "$(color_code "${OUT_COLOR[$i]}")" "${OUT_LINES[$i]}" "$RESET"
    [ $(( i + 1 )) -lt "$n" ] && printf '\n'
  done
}

# 平文の1フレーム文字列（行を \n 区切り・ESC無し）を stdout へ出す。
compose_plain_frame() {
  local cols="$1" rows="$2" i n
  render "$cols" "$rows"
  n=${#OUT_LINES[@]}
  for ((i = 0; i < n; i++)); do
    printf '%s' "${OUT_LINES[$i]}"
    [ $(( i + 1 )) -lt "$n" ] && printf '\n'
  done
}

# --- 起動口 ---------------------------------------------------------------

run_once() {
  local plain="$1"
  local cols rows
  cols="$(term_cols "$COLS_OVERRIDE")"
  rows="$(term_rows "$ROWS_OVERRIDE")"

  probe_focus_uuid
  if [ -z "$CMUX_REASON" ]; then
    load_model "$CMUX_UUID"
  fi

  if [ "$plain" -eq 1 ]; then
    compose_plain_frame "$cols" "$rows"
    printf '\n'
  else
    printf '\033[?2026h'
    compose_colored_frame "$cols" "$rows"
    printf '\n\033[?2026l'
  fi
}

run_daemon() {
  printf '\033]2;Next Task\007'
  printf '\033[?25l'
  trap 'printf "\033[?2026l\033[?25h"' EXIT
  trap 'exit 0' INT TERM HUP
  local force=0
  trap 'force=1' WINCH

  local last_uuid="" last_frame="" last_reload=0 last_redraw=0
  local last_was_reason=0
  printf '\033[2J'

  while :; do
    local now
    now=$(date +%s)

    probe_focus_uuid

    if [ -n "$CMUX_REASON" ]; then
      MODEL_REASON=""
      MODEL_SLUG=""
      BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
      last_uuid=""
      last_was_reason=1
    else
      local need_reload=0
      if [ "$CMUX_UUID" != "$last_uuid" ]; then
        need_reload=1
      elif [ $(( now - last_reload )) -ge "$INTERVAL" ]; then
        need_reload=1
      elif [ "$force" -eq 1 ]; then
        need_reload=1
      elif [ "$last_was_reason" -eq 1 ]; then
        need_reload=1
      fi
      if [ "$need_reload" -eq 1 ]; then
        load_model "$CMUX_UUID"
        last_reload="$now"
        last_uuid="$CMUX_UUID"
        if [ -n "$MODEL_REASON" ]; then
          last_was_reason=1
        else
          last_was_reason=0
        fi
      fi
    fi

    local cols rows frame
    cols="$(term_cols "$COLS_OVERRIDE")"
    rows="$(term_rows "$ROWS_OVERRIDE")"
    frame="$(compose_colored_frame "$cols" "$rows" | sed "s/\$/${ESC}[K/")"

    if [ "$frame" != "$last_frame" ] || [ "$force" -eq 1 ] || [ $(( now - last_redraw )) -ge "$REDRAW_HEARTBEAT" ]; then
      printf '\033[?2026h\033[H%s\033[J\033[?2026l' "$frame"
      last_frame="$frame"
      last_redraw="$now"
      force=0
    fi

    sleep "$FOCUS_INTERVAL"
  done
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "jq が見つかりません。" >&2; exit 1; }

  local once=0 plain=0 a
  for a in "$@"; do
    case "$a" in
      --once) once=1 ;;
      --plain) plain=1; once=1 ;;
      *) : ;;
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
