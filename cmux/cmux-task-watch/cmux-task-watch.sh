#!/bin/bash
# cmux Dock 4枠目「Task」の描画（cmux-session-todo 設計 §4）。表示専用
# （Vault にも cmux にも書き込まない＝FR-23）。フォーカス中のワークスペース
# の宣言先プロジェクト（cmux-task-declare.sh set で宣言）の Tasks 節を、
# ヘッダー行＋版行＋展開対象の版の子行として表示する（FR-21）。
#
# 表示例（子行の番号はその瞬間の表示順であって恒久IDではない＝設計
# §19.1・FR-49）:
#   ▶ cmux-session-todo  v2 1/3
#   v1 ✅ 3/3
#   v2 ▶ 1/3
#    ├ 1 [x] 要件定義
#    ├ 2 [/] 設計
#    └ 3 [ ] 実装
#   v3 ・ 0/4
#
# 引数: （なし）＝常駐 / --once＝1フレーム色付きで出して終了 / --plain＝1フレーム
# 平文で出して終了（--once と併用可・単独でも1回で終わる＝設計 §4.1）/
# --list＝展開対象の版の子行を4列TSV（番号・版名・状態・本文）で出す
# （--once・--plain とは併用しない＝設計 §20）。
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
if [ ! -r "$LIB_DIR/lib-cmux-workspace.sh" ]; then
  echo "lib-cmux-workspace.sh が見つかりません: $LIB_DIR/lib-cmux-workspace.sh" >&2
  exit 1
fi
# shellcheck source=../lib-dock-view.sh
. "$LIB_DIR/lib-dock-view.sh"
# shellcheck source=../lib-vault-tasks.sh
. "$LIB_DIR/lib-vault-tasks.sh"
# shellcheck source=../lib-cmux-workspace.sh
. "$LIB_DIR/lib-cmux-workspace.sh"

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
LIST_REASON=""
LIST_UUID=""
MODEL_REASON=""
MODEL_SLUG=""
MODEL_SYM=""
MODEL_LEADWORD=""
MODEL_VERNAME=""
MODEL_FRAC=""
V_NAME=(); V_TOTAL=(); V_DONE=(); V_HASSLASH=()
BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
# 表示番号の正本（number_rows() の出力・設計 §19.1）。BL_BLIDX は BL_KIND
# 上の位置（記載順の子行だけを指す）。
NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()

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

# 入力の署名（設計 §19.4・FR-50b）。宣言記録の内容ハッシュ・解決した slug・
# ノートの内容ハッシュの3要素を毎ティック取り直す純関数（cmux を呼ばない）。
# cksum は「CRC 長さ ファイル名」を返すので、ファイル名の列を落として
# CRC と長さだけを署名に入れる（ファイル名が変わっただけでは再読込しない
# ため。slug の変化は署名の第2要素が拾う＝I2-13）。
#   $1 = uuid
# stdout（rc=0のときだけ意味を持つ）: "<state_h><TAB><slug><TAB><note_h>"
#   各要素はファイル不在なら固定文字列 "-"
# rc=0: 3要素とも取得できた（cksum 対象ファイルが存在すれば成功、
#       存在しなければ "-" で確定＝どちらも失敗ではない）
# rc=1: 存在するファイルに対する cksum が失敗した（値は不定・呼び出し側は
#       出力を使わず、無条件で再読込・前回署名未更新とすること＝I2-13）
compute_signature() {
  local uuid="$1" state_h slug note_h h rc

  if [ -f "$STATE_FILE" ]; then
    h="$(cksum "$STATE_FILE" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    state_h="$(printf '%s' "$h" | awk '{print $1, $2}')"
  else
    state_h="-"
  fi

  # 毎ティック lookup＝意図的（署名の取りこぼしを原理的に無くす・I2-15b は不採用）。
  slug="$(lookup_slug "$uuid")"
  [ -n "$slug" ] || slug="-"

  note_h="-"
  if [ "$slug" != "-" ] && slug_valid "$slug" && [ -d "$VAULT" ]; then
    local note="$VAULT/Projects/$slug.md"
    if [ -f "$note" ]; then
      h="$(cksum "$note" 2>/dev/null)"; rc=$?
      [ "$rc" -eq 0 ] || return 1
      note_h="$(printf '%s' "$h" | awk '{print $1, $2}')"
    fi
  fi

  printf '%s\t%s\t%s' "$state_h" "$slug" "$note_h"
}

# --- cmux 側（段A・毎ティック評価） ---------------------------------------

# フォーカス中ワークスペースの UUID を解決する（薄いラッパ。段階評価の
# 本体は共有 lib＝設計 §21 の I2-15）。成功時は CMUX_UUID に UUID を、
# 失敗時は CMUX_REASON に §7 順1・順2 の理由行を入れる（両方成功かつ
# 解決できたときは CMUX_REASON=""）。
probe_focus_uuid() {
  local refs focus_ref json
  CMUX_REASON=""
  CMUX_UUID=""

  refs="$(ws_identify_refs "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    CMUX_REASON="cmux 応答なし"
    return
  fi
  # タブ区切りの分解はパラメータ展開で行う（"IFS=タブ read" だと先頭の
  # 空フィールド＝caller が null のときに読み飛ばされる罠があるため。
  # ws_caller_uuid のコメントと同じ理由＝設計 §21）。
  focus_ref="${refs#*$'\t'}"

  json="$(ws_list_json "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    CMUX_REASON="cmux 応答なし"
    return
  fi

  CMUX_UUID="$(ws_uuid_for_ref "$json" "$focus_ref")"
  if [ $? -ne 0 ]; then
    CMUX_UUID=""
    CMUX_REASON="対象不明"
  fi
}

# --list の対象解決（設計 §20.2・§21）。ws_caller_uuid は使わず、同じ素材
# （identify1回・workspace list1回）から caller と focused の両方を
# ws_uuid_for_ref で解決し、両者（解決後のUUID同士）が一致するときだけ
# caller の UUID を返す（FR-53b）。成功時は LIST_UUID に UUID を、失敗時は
# LIST_REASON に理由をセットする（LIST_UUID は空のまま）。
#
# ⚠️ 呼び出し側はこの関数を裸の文として呼ぶこと（"$(probe_list_target)" の
# ようにコマンド置換で包まない）。包むと関数全体がサブシェルで走り、
# LIST_REASON/LIST_UUID への代入が呼び出し元へ伝わらない（bash3.2の既知の
# 罠＝probe_focus_uuid/CMUX_REASON/CMUX_UUID と同じ形に揃える）。
probe_list_target() {
  local refs caller_ref focus_ref json cu fu
  LIST_REASON=""
  LIST_UUID=""

  refs="$(ws_identify_refs "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    LIST_REASON="cmux 応答なし"
    return
  fi
  # タブ区切りの分解はパラメータ展開で行う（probe_focus_uuid・
  # ws_caller_uuid と同じ理由＝先頭の空フィールドが読み飛ばされる罠を
  # 避けるため）。
  caller_ref="${refs%%$'\t'*}"
  focus_ref="${refs#*$'\t'}"

  json="$(ws_list_json "$CMUX_BIN" "$CALL_TIMEOUT")"
  if [ $? -ne 0 ]; then
    LIST_REASON="cmux 応答なし"
    return
  fi

  cu="$(ws_uuid_for_ref "$json" "$caller_ref")"
  if [ $? -ne 0 ]; then
    LIST_REASON="対象不明"
    return
  fi

  fu="$(ws_uuid_for_ref "$json" "$focus_ref")"
  if [ $? -ne 0 ] || [ "$cu" != "$fu" ]; then
    LIST_REASON="対象不一致"
    return
  fi

  LIST_UUID="$cu"
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
  NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()

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

  number_rows
}

# 表示番号の正本（C-1の変更・設計 §19.1）。BL_KIND/BL_A/BL_B（load_model が
# 組み立てた版行＋展開対象版の子行・記載順）を読み、展開対象版の子行
# （CX/CS/CB）だけに記載順で1から番号を振る。並列配列
# NR_BLIDX（BL_KIND上の位置）/NR_NUM/NR_STATE/NR_BODY を設定する。
# render も --list もこの関数が返した配列を読むだけで、自分では数えない
# （N-1）。純関数（副作用は上記グローバルの設定のみ・BL_* は変更しない）。
number_rows() {
  NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()
  local n=${#BL_KIND[@]} i num=0
  for ((i = 0; i < n; i++)); do
    case "${BL_KIND[$i]}" in
      CX|CS|CB)
        num=$(( num + 1 ))
        NR_BLIDX+=("$i")
        NR_NUM+=("$num")
        NR_STATE+=("${BL_A[$i]}")
        NR_BODY+=("${BL_B[$i]}")
        ;;
    esac
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

# 子行を組み立てる（FR-51。固定部=" {罫線} {番号} [{state}] "・本文だけを
# 切り詰める。番号は number_rows() が採番し右詰め済みの文字列を受け取る＝
# ここでは切り捨てない）。
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

  # 番号の桁数（設計 §19.2・I2-2）: number_rows() が返した行数（クランプ
  # 「前」の子行総数）から取る。KEEP_IDX の長さから取らない（クランプの
  # 有無で行頭が動かないようにするため＝AC-63）。
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
        # NR_BLIDX は BL_KIND の子行位置を記載順（＝idx の昇順）に持つ。
        # KEEP_IDX も昇順（clamp_lines が sort -n 済み）なので、ポインタを
        # 前へ進めるだけで対応する番号へ到達できる（設計 §19.1）。
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
  printf '\033]2;Task\007'
  printf '\033[?25l'
  trap 'printf "\033[?2026l\033[?25h"' EXIT
  trap 'exit 0' INT TERM HUP
  local force=0
  trap 'force=1' WINCH

  local last_uuid="" last_frame="" last_reload=0 last_redraw=0
  local last_was_reason=0
  local last_signature=""
  printf '\033[2J'

  while :; do
    local now
    now=$(date +%s)

    probe_focus_uuid

    if [ -n "$CMUX_REASON" ]; then
      MODEL_REASON=""
      MODEL_SLUG=""
      BL_KIND=(); BL_A=(); BL_B=(); BL_C=()
      NR_BLIDX=(); NR_NUM=(); NR_STATE=(); NR_BODY=()
      last_uuid=""
      last_signature=""
      last_was_reason=1
    else
      local need_reload=0 sig="" sig_rc=0
      sig="$(compute_signature "$CMUX_UUID")"
      sig_rc=$?

      # 署名の取得に1つでも失敗したティックは、理由を問わず無条件で
      # 再読込する（設計 §19.4・I2-13）。失敗を "-" という値として前回
      # 署名に書き込むと、失敗が続く間の宣言変更を取りこぼす（検証5巡目
      # #3）ため、last_signature は sig_rc=0 のときだけ更新する。
      if [ "$CMUX_UUID" != "$last_uuid" ]; then
        need_reload=1
      elif [ "$sig_rc" -ne 0 ]; then
        need_reload=1
      elif [ "$sig" != "$last_signature" ]; then
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
        [ "$sig_rc" -eq 0 ] && last_signature="$sig"
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

# `--list`（C-1 の新サブコマンド・設計 §20）。常駐に依存せず単発で完結する
# （--once と同じ。v2.4 の描画スナップショット方式の撤回）。
# 対象は caller。caller と focused が一致するときだけ4列TSVを出す
# （FR-53b）。stdout: 成功時のみ4列TSVを1行以上。失敗時は0バイト。
# stderr: 失敗時のみ理由1行。rc: 成功0／失敗1（§20.3）。
run_list() {
  probe_list_target
  if [ -z "$LIST_UUID" ]; then
    echo "${LIST_REASON:-対象不明}" >&2
    return 1
  fi

  load_model "$LIST_UUID"
  if [ -n "$MODEL_REASON" ]; then
    echo "$MODEL_REASON" >&2
    return 1
  fi

  local n=${#NR_NUM[@]}
  if [ "$n" -eq 0 ]; then
    # 展開対象の版が無い＝全版完了（§20.3 の#11）。MODEL_REASON は立たない
    # （render は通常フレームとして扱う）ので、ここで別に検出する。
    echo "全版完了" >&2
    return 1
  fi

  local i
  for ((i = 0; i < n; i++)); do
    printf '%s\t%s\t[%s]\t%s\n' "${NR_NUM[$i]}" "$MODEL_VERNAME" "${NR_STATE[$i]}" "${NR_BODY[$i]}"
  done
  return 0
}

usage() {
  cat >&2 <<'EOF'
使い方:
  cmux-task-watch.sh [--once] [--plain]
  cmux-task-watch.sh --list
EOF
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "jq が見つかりません。" >&2; exit 1; }

  local once=0 plain=0 list=0 a
  for a in "$@"; do
    case "$a" in
      --once) once=1 ;;
      --plain) plain=1; once=1 ;;
      --list) list=1 ;;
      *) usage; exit 1 ;;
    esac
  done

  # --list は --once / --plain と併用しない（設計 §20.4・FR-55）。未知の
  # 引数と同じく、常駐へ落とさず即座に拒否する。
  if [ "$list" -eq 1 ] && { [ "$once" -eq 1 ] || [ "$plain" -eq 1 ]; }; then
    usage
    exit 1
  fi

  if [ "$list" -eq 1 ]; then
    run_list
    exit $?
  fi

  if [ "$once" -eq 1 ]; then
    run_once "$plain"
    exit 0
  fi
  run_daemon
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
