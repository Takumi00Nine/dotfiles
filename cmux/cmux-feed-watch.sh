#!/bin/bash
# cmux Feed（~/.cmuxterm/workstream.jsonl）を Dock の狭幅ペイン（約40桁）向けに
# 追記型でコンパクト表示する。画面クリア・再描画はしない（チラつき防止、
# スクロールバックがそのまま履歴として残る）。
# 旧来の `cmux feed tui` は幅80桁前提のヘッダーが折り返されて読めないため代替。
#
# 表示例:
#   02:12 CL Bash
#     echo hello
#   03:40 CX toolResult ERR
#     compile failed: unexpected token…

LOG="${CMUX_FEED_LOG:-$HOME/.cmuxterm/workstream.jsonl}"
BACKFILL="${CMUX_FEED_BACKFILL:-20}"

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
LBL="${ESC}[38;5;252m"
ERR_C="${ESC}[38;5;197m"

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# jq 抽出用の共通サニタイズフィルタ：改行・CR を含む C0（NUL は jq 文字列で
# 扱えないため対象外）・C1 制御文字と DEL を空白化する。ログ内容（ツールコマンド等の任意文字列）が端末に生で
# 流れるため、エスケープシーケンス注入（ESC・CSI・OSC 等）をここで遮断する。
# バイト単位の tr だと UTF-8 継続バイト（0x9B 等）を壊すので、jq のコード
# ポイント単位 gsub で行う（改行も潰れるので1イベント2行の上限も守られる）。
SANITIZE='gsub("[\u0001-\u001f\u007f-\u009f]"; " ")'

# 現在の端末幅（取得できなければ 40 桁固定＝Dockペインの想定幅）
# 注意: パイプ内（tail | while read）かつコマンド置換の中で `tput cols` を
# 呼ぶと、標準出力/標準エラーがどちらも端末でなくなるため既定の80桁に
# フォールバックしてしまうことを実機確認した。/dev/tty を明示して制御端末
# へ直接問い合わせることで、パイプの深さに関わらず正しい実幅を取得する。
cols_now() {
  local sz c
  # /dev/tty が無い環境（制御端末なしで起動された場合など）でも
  # bash自身のリダイレクトエラーを漏らさないよう { } でまとめて2>/dev/nullする
  sz=$( { stty size </dev/tty; } 2>/dev/null )
  c="${sz#* }"
  is_number "$c" || c=40
  printf '%s' "$c"
}

# ISO8601 UTC ("...Z") をローカル時刻の HH:MM に変換。解釈できなければ "--:--"
# ミリ秒付き（"...T12:34:56.789Z"）は小数部を落としてからパースする。
to_local_hm() {
  local ts="$1" epoch=""
  case "$ts" in
    *.*Z) ts="${ts%%.*}Z" ;;
  esac
  case "$ts" in
    *Z) epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null) ;;
  esac
  if [ -z "$epoch" ]; then
    printf -- '--:--'
  else
    date -r "$epoch" '+%H:%M'
  fi
}

# 文字数（バイト数ではない）ベースで幅 $2 に切り詰め、超過分は … を付ける。
# jqの文字列スライスはコードポイント単位なので日本語などマルチバイト文字
# でも文字化けしない。
truncate_str() {
  local s="$1" w="$2"
  is_number "$w" || w=40
  [ "$w" -lt 1 ] && w=1
  jq -Rr --argjson w "$w" 'if (length) > $w then (.[0:($w-1)] + "…") else . end' <<<"$s" 2>/dev/null
}

# 1行のJSONイベントを最大2行で表示する。toolResult以外のkindは実形式が
# 未確認のため、kind名（＋titleがあれば併記）を素朴に表示するだけに留める
# 防御的な実装（未知kindでも落ちない・行を飛ばさない）。
render_event() {
  local line="$1"
  # スキップ時は明示的に 0 を返す（jq の非0終了コードがループ経由で
  # スクリプト全体の終了コードに化けるのを防ぐ）
  [ -z "$line" ] && return 0
  jq -e . >/dev/null 2>&1 <<<"$line" || return 0

  local ts src kind title summary toolname err
  ts=$(jq -r '.createdAt // .updatedAt // empty' <<<"$line" 2>/dev/null)
  src=$(jq -r ".source // empty | $SANITIZE" <<<"$line" 2>/dev/null)
  kind=$(jq -r ".kind // empty | $SANITIZE" <<<"$line" 2>/dev/null)
  title=$(jq -r ".title // empty | $SANITIZE" <<<"$line" 2>/dev/null)
  summary=$(jq -r ".context.toolSummary // empty | $SANITIZE" <<<"$line" 2>/dev/null)
  toolname=$(jq -r ".payload.toolResult.toolName // empty | $SANITIZE" <<<"$line" 2>/dev/null)
  # payload配下のどこかに isError:true があれば拾う（キー名が不明なkindにも対応）
  err=$(jq -r '(.payload // {} | [.. | objects | .isError] | any)' <<<"$line" 2>/dev/null)

  local hm; hm=$(to_local_hm "$ts")

  local tag_txt tag_color
  case "$src" in
    claude) tag_txt="CL"; tag_color=39 ;;
    codex)  tag_txt="CX"; tag_color=213 ;;
    *)      tag_txt="${src:-?}"; tag_color=252 ;;
  esac
  # 未知ソースの長い名前で1行目が折り返さないよう4文字に制限
  if [ "${#tag_txt}" -gt 4 ]; then
    tag_txt=$(truncate_str "$tag_txt" 4)
  fi

  # kind の短縮ラベル
  local label
  if [ "$kind" = "toolResult" ]; then
    label="$title"
    [ -z "$label" ] && label="$toolname"
    [ -z "$label" ] && label="Tool"
  elif [ -n "$title" ] && [ "$title" != "${kind:-?}" ]; then
    label="${kind:-?}(${title})"
  else
    label="${kind:-?}"
  fi

  local cols head_w overhead
  cols=$(cols_now)
  # 1行目の固定分: "HH:MM "(6) + タグ + 区切り空白(1) + エラー時の " ERR"(4)
  overhead=$(( 7 + ${#tag_txt} ))
  [ "$err" = "true" ] && overhead=$(( overhead + 4 ))
  head_w=$(( cols - overhead ))
  [ "$head_w" -lt 5 ] && head_w=5
  label=$(truncate_str "$label" "$head_w")

  printf '%s %s[1;38;5;%sm%s%s %s%s' "$hm" "$ESC" "$tag_color" "$tag_txt" "$RESET" "$LBL" "$label"
  [ "$err" = "true" ] && printf ' %sERR%s' "$ERR_C" "$RESET"
  printf '%s\n' "$RESET"

  # 2行目: context.toolSummary優先。無ければ title を代替表示（1行目に
  # 既出なら重複するので省略）。端末幅に収まるよう切り詰める（折り返さない）。
  local body=""
  if [ -n "$summary" ]; then
    body="$summary"
  elif [ -n "$title" ]; then
    case "$label" in
      *"$title"*) : ;;
      *) body="$title" ;;
    esac
  fi
  if [ -n "$body" ]; then
    local body_w; body_w=$(( cols - 2 ))
    [ "$body_w" -lt 5 ] && body_w=5
    printf '  %s%s%s\n' "$DIM" "$(truncate_str "$body" "$body_w")" "$RESET"
  fi
  return 0
}

# --once専用: 既存ログ末尾N件を表示して終了する。ファイルが無ければ何も
# 待たずに即戻る（テスト時にログ未生成でハングしないため）。
backfill_once() {
  [ -f "$LOG" ] || return 0
  tail -n "$BACKFILL" "$LOG" 2>/dev/null | while IFS= read -r line; do
    render_event "$line"
  done
}

# 常駐モード: 末尾N件の表示と以降の追記追従を1本のtailにまとめる。
# 「backfillしてから改めてtail -F -n0で追従」に分けると、ログファイルが
# まだ存在しない状態で待機中に初回書き込みが起きた場合、attach前に書かれた
# 分を取りこぼすレースがあるため、待機後は必ず -n "$BACKFILL" 付きの
# tail -F 1本で開始する（ファイル未作成でも存在するまで待つ）。
run_follow() {
  while [ ! -e "$LOG" ]; do
    sleep 1
  done
  tail -n "$BACKFILL" -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    render_event "$line"
  done
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '%sfeed ERR (jq not found)%s\n' "$ERR_C" "$RESET"
    exit 1
  fi
  if [ "${1:-}" = "--once" ]; then
    backfill_once
    return
  fi
  run_follow
}

main "$@"
