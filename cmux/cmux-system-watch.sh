#!/bin/bash
# macmon の `pipe` JSON ストリームを cmux Dock（狭幅ペイン・幅約40桁）向けに
# コンパクト表示する。TUI（`macmon` そのまま）は幅80桁前提のため狭幅だと
# 潰れて読めない。代わりに `macmon pipe -i <ms>` の JSON を jq でパースし、
# 自前でゲージ／スパークラインを描画する。cmux-usage-watch.sh と同様、
# 見出し行＋インデントしたサブ行のブロック構成（CPU/GPU/RAM/PWRそれぞれを
# 独立したグループとし、間に空行を1行ずつ挟んでグラフが潰れて見えないように
# する）。
# 表示例:
#   CPU 37°
#    E ▁▂▁▁▃▂▅▂▁▁▂▃   6%
#    P ▁▁▁▂▁▁▁▁▂▁▁▁   4%
#
#   GPU ▂▁▁▃▁▁▁▁▁▁▁▁   1% 37°
#
#   RAM ▅▅▅▅▅▆▅▅▅▅▅▅  68% 16.3/24G
#
#   PWR ▂▃▂▅▇▃▂▂▁▂▃▂  7.1W
#
# E-CPU/P-CPU/GPU/RAM/PWRはいずれも瞬間値ではなく直近SPARK_N件の履歴を
# スパークライン（▁▂▃▄▅▆▇█の8段階、左=古い→右=新しい）で表示する。
# 使用率系(E/P/GPU/RAM)は0-100%の固定スケール、PWR(電力)は%表現が無いため
# 履歴ウィンドウ内の最大値（下限1.0W）を上限とした相対スケールでマップする。

MACMON_BIN="${CMUX_MACMON_BIN:-/opt/homebrew/bin/macmon}"
INTERVAL_MS="${CMUX_SYSTEM_INTERVAL_MS:-5000}"
RETRY_SECONDS=3
# スパークラインの表示幅（サンプル数）。40桁ペインに収まる固定幅。
SPARK_N=12
# E-CPU/P-CPU/GPU/RAM の履歴（スパーク用の1文字トークンを半角空白区切りで
# 保持。bash 3.2 なので配列を使わず文字列で管理する）。run_stream 内の
# 常駐ループが生きている間だけ保持し、macmon 再起動時（新しいプロセス）には
# リセットされる。
ECPU_HIST=""
PCPU_HIST=""
GPU_HIST=""
RAM_HIST=""
# PWR の履歴は上記と異なり「生の電力値(W)」を半角空白区切りで保持する
# （%表現が無く、履歴ウィンドウ内の最大値を都度スケール基準にするため、
# レベル文字ではなく生値を保持し、表示のたびに再マップする）。
PWR_HIST=""

# 環境変数由来の数値を検証し、無効値・範囲外は既定値へ戻す（sleep 即時失敗
# による高速ループや算術式エラーを防ぐ。cmux-usage-watch.sh の env 検証と
# 同じ流儀。下限500ms・上限60000msの範囲外は clamp ではなく既定値に戻す）。
case "$INTERVAL_MS" in ''|*[!0-9]*) INTERVAL_MS=5000 ;; esac
if [ "$INTERVAL_MS" -lt 500 ] || [ "$INTERVAL_MS" -gt 60000 ]; then
  INTERVAL_MS=5000
fi

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
LBL="${ESC}[38;5;252m"
# 見出し行（CPU/GPU/RAM/PWR）用の太字版。cmux-usage-watch.sh の
# service_block と同じ "38;5;NUM;1m" 形式（色指定の直後に ;1m で太字化）
LBL_BOLD="${ESC}[38;5;252;1m"
ERR_C="${ESC}[38;5;197m"
# スパークラインの8段階（低→高）
LEVELS='▁▂▃▄▅▆▇█'

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# 0.xx や 7.1 のような小数を許容する数値判定（指数表記・符号も許可する
# 簡易チェック。欠損フィールドは jq 側で空文字列になるのでここで弾く）。
is_float() { case "$1" in ''|*[!0-9.eE+-]*) return 1 ;; *) return 0 ;; esac; }

# 使用率に応じた 256 色番号（cmux-usage-watch.sh の pcolor と同じしきい値）
pcolor() {
  local p="${1%.*}"
  is_number "$p" || { printf '244'; return; }
  if [ "$p" -ge 80 ]; then printf '197'
  elif [ "$p" -ge 50 ]; then printf '214'
  else printf '114'; fi
}

# 0..1 の小数を 0-100 の整数（四捨五入）へ変換して標準出力へ。
# 非数値・欠損なら何も出さず非0を返す。
frac_to_pct() {
  is_float "$1" || return 1
  awk -v v="$1" 'BEGIN{printf "%d", (v*100)+0.5}'
}

# 0-100 の整数を LEVELS（▁..█の8段階）の1文字へ変換する。非数値・欠損時は
# 最低レベル ▁ を返す（実測0%との区別はしない簡易仕様）。
# マルチバイト文字の切り出しは bash のネイティブ添字ではなく jq のコード
# ポイント単位スライスで行う（cmux-feed-watch.sh の truncate_str と同じ理由：
# bash 添字は環境依存で文字化けし得るため）。
level_char() {
  local p="$1" idx ch
  if ! is_number "$p"; then
    printf '▁'
    return
  fi
  [ "$p" -gt 100 ] && p=100
  idx=$(( (p * 8 + 50) / 100 ))
  [ "$idx" -gt 7 ] && idx=7
  ch=$(printf '%s' "$LEVELS" | jq -Rr --argjson i "$idx" '.[$i:($i+1)]' 2>/dev/null)
  [ -n "$ch" ] && printf '%s' "$ch" || printf '▁'
}

# 履歴文字列（半角空白区切り、各トークンはスパーク用の1文字）に新しい
# トークンを追加し、末尾 SPARK_N 件だけを残して返す（溢れた古い分は捨てる）。
append_hist() {
  local hist="$1" tok="$2" n="$3" newhist count
  if [ -z "$hist" ]; then
    newhist="$tok"
  else
    newhist="$hist $tok"
  fi
  set -- $newhist
  count=$#
  if [ "$count" -gt "$n" ]; then
    shift $(( count - n ))
    newhist="$*"
  fi
  printf '%s' "$newhist"
}

# 履歴文字列から表示用スパークライン（固定長 N 文字）を組み立てる。件数が
# N に満たない間（起動直後）は先頭を ▁ で埋める。
build_spark() {
  local hist="$1" n="$2" out="" pad i tok count
  set -- $hist
  count=$#
  if [ "$count" -gt "$n" ]; then
    shift $(( count - n ))
    count=$n
  fi
  if [ "$count" -lt "$n" ]; then
    pad=$(( n - count ))
    i=0; while [ "$i" -lt "$pad" ]; do out="${out}▁"; i=$(( i + 1 )); done
  fi
  for tok in "$@"; do
    out="${out}${tok}"
  done
  printf '%s' "$out"
}

# PWR用: 履歴（生の電力値(W)、半角空白区切り）から、ウィンドウ内最大値
# （下限1.0W。ゼロ除算防止）を上限とした相対スケールでスパークライン文字列
# （固定長 N 文字）を組み立てる。CPU/GPUのスパークは0-100%の固定スケール
# だが、電力は%表現が無いため「直近の増減の形」が見えれば十分という設計で
# ウィンドウ内相対値を採用している。件数がNに満たない間は先頭を▁で埋める。
build_pwr_spark() {
  local hist="$1" n="$2" out="" pad i count mx idx idxs tok
  set -- $hist
  count=$#
  if [ "$count" -eq 0 ]; then
    i=0; while [ "$i" -lt "$n" ]; do out="${out}▁"; i=$(( i + 1 )); done
    printf '%s' "$out"
    return
  fi
  if [ "$count" -gt "$n" ]; then
    shift $(( count - n ))
    count=$n
  fi
  if [ "$count" -lt "$n" ]; then
    pad=$(( n - count ))
    i=0; while [ "$i" -lt "$pad" ]; do out="${out}▁"; i=$(( i + 1 )); done
  fi
  # 最大値算出とレベル(0-7)算出を1回のawkにまとめて呼び出し回数を抑える
  idxs=$(awk 'BEGIN{m=1.0}
    {for(i=1;i<=NF;i++) if ($i+0>m) m=$i+0}
    {for(i=1;i<=NF;i++){p=($i+0)/m*100; idx=int((p*8+50)/100); if(idx>7)idx=7; if(idx<0)idx=0; printf "%d ", idx}}
  ' <<<"$*")
  for idx in $idxs; do
    tok=$(printf '%s' "$LEVELS" | jq -Rr --argjson i "$idx" '.[$i:($i+1)]' 2>/dev/null)
    [ -n "$tok" ] || tok='▁'
    out="${out}${tok}"
  done
  printf '%s' "$out"
}

# スパークライン1本分「<色付きラベル><スパークN文字> NN%」を組み立てて出力
# する（末尾リセット無し。呼び出し側で改行とリセットを付ける）。色は現在値
# のしきい値色をスパーク全体・数値部に一律適用する（1文字ごとの色分けはしない）。
#   $1: 4桁固定の行ラベル  $2: ラベルの色エスケープ
#   $3: 組み立て済みスパーク文字列（build_spark の戻り値）
#   $4: 現在値の 0-100 整数。欠損時は空文字列（"--" 表示にする）
spark_row() {
  local label="$1" label_color="$2" spark="$3" p="$4" color
  printf '%s%s' "$label_color" "$label"
  if [ -z "$p" ] || ! is_number "$p"; then
    printf '%s%s' "$DIM" "$spark"
    printf ' %s  --' "$DIM"
    return
  fi
  [ "$p" -gt 100 ] && p=100
  color="${ESC}[38;5;$(pcolor "$p")m"
  printf '%s%s' "$color" "$spark"
  printf ' %s%3d%%' "$color" "$p"
}

# PWR用スパーク行「<太字ラベル><スパークN文字>  N.NW」を組み立てて出力
# する（末尾リセット無し）。電力には%基準のしきい値が無いため、色は常に
# 緑固定（114）とする。
#   $1: 4桁固定の行ラベル  $2: ラベルの色エスケープ
#   $3: 組み立て済みスパーク文字列（build_pwr_spark の戻り値）
#   $4: 現在値の表示テキスト（例 "7.1W"／欠損時 "--W"）
pwr_spark_row() {
  local label="$1" label_color="$2" spark="$3" value_txt="$4" color
  color="${ESC}[38;5;114m"
  printf '%s%s%s%s  %s' "$label_color" "$label" "$color" "$spark" "$value_txt"
}

# 1フレーム分（CPU見出し+E行+P行+空行 / GPU行+空行 / RAM行+空行 / PWR行
# = 計9行）を組み立てて標準出力へ書く。JSON として解釈できない行（非JSON行・
# 空行）は何も出力せず非0を返す。呼び出し側はこれを検知して直前のフレームを
# そのまま維持する（表示を崩さない・空白で潰さない）。個々のフィールドの
# 欠損は行単位で "--" 表示にするだけで全体は継続する。
#
# 注意: この関数は ECPU_HIST/PCPU_HIST/GPU_HIST/RAM_HIST/PWR_HIST
# （グローバル）を更新する副作用を持つ。呼び出し側で `$(render_frame ...)`
# のようにコマンド置換やパイプで包むとサブシェル化し、この副作用（履歴更新）
# が失われるため、標準出力は必ず `>` によるファイルリダイレクトか直接出力で
# 受け取ること（run_stream 参照）。
render_frame() {
  local json="$1"
  jq -e . >/dev/null 2>&1 <<<"$json" || return 1

  local ecpu pcpu gpu ram_used ram_total power ctemp gtemp
  ecpu=$(jq -r '.ecpu_usage[1] // empty' <<<"$json" 2>/dev/null)
  pcpu=$(jq -r '.pcpu_usage[1] // empty' <<<"$json" 2>/dev/null)
  gpu=$(jq -r '.gpu_usage[1] // empty' <<<"$json" 2>/dev/null)
  ram_used=$(jq -r '.memory.ram_usage // empty' <<<"$json" 2>/dev/null)
  ram_total=$(jq -r '.memory.ram_total // empty' <<<"$json" 2>/dev/null)
  # 監視用途には "sys_power"（システム全体消費W）が適切（"all_power" は
  # cpu_power+gpu_power+ane_power の合計値でシステム全体消費ではない。
  # サンプルJSONでも all_power=0.60W に対し期待表示値7.1Wはsys_power=7.06Wと
  # 一致することを確認済み）。macmonのバージョン差などでsys_powerが無い
  # 場合に備え、all_power へのフォールバックも用意する（Codexレビュー指摘）。
  power=$(jq -r '.sys_power // .all_power // empty' <<<"$json" 2>/dev/null)
  ctemp=$(jq -r '.temp.cpu_temp_avg // empty' <<<"$json" 2>/dev/null)
  gtemp=$(jq -r '.temp.gpu_temp_avg // empty' <<<"$json" 2>/dev/null)

  local ecpu_p pcpu_p gpu_p
  ecpu_p=$(frac_to_pct "$ecpu") || ecpu_p=""
  pcpu_p=$(frac_to_pct "$pcpu") || pcpu_p=""
  gpu_p=$(frac_to_pct "$gpu") || gpu_p=""

  local ram_pct="" ram_used_gib="--" ram_total_gib="--"
  if is_number "$ram_used" && is_number "$ram_total" && [ "$ram_total" -gt 0 ]; then
    read -r ram_pct ram_used_gib ram_total_gib <<<"$(awk -v u="$ram_used" -v t="$ram_total" \
      'BEGIN{printf "%d %.1f %.0f", ((u/t*100)+0.5), u/1073741824, t/1073741824}')"
  fi

  # 履歴（グローバル）を更新してからスパークライン文字列を組み立てる。
  ECPU_HIST="$(append_hist "$ECPU_HIST" "$(level_char "$ecpu_p")" "$SPARK_N")"
  PCPU_HIST="$(append_hist "$PCPU_HIST" "$(level_char "$pcpu_p")" "$SPARK_N")"
  GPU_HIST="$(append_hist "$GPU_HIST" "$(level_char "$gpu_p")" "$SPARK_N")"
  RAM_HIST="$(append_hist "$RAM_HIST" "$(level_char "$ram_pct")" "$SPARK_N")"
  local ecpu_spark pcpu_spark gpu_spark ram_spark
  ecpu_spark="$(build_spark "$ECPU_HIST" "$SPARK_N")"
  pcpu_spark="$(build_spark "$PCPU_HIST" "$SPARK_N")"
  gpu_spark="$(build_spark "$GPU_HIST" "$SPARK_N")"
  ram_spark="$(build_spark "$RAM_HIST" "$SPARK_N")"

  local power_txt="--W" ctemp_txt="--°" gtemp_txt="--°"
  is_float "$power" && power_txt=$(awk -v v="$power" 'BEGIN{printf "%.1fW", v}')
  is_float "$ctemp" && ctemp_txt=$(awk -v v="$ctemp" 'BEGIN{printf "%d°", v+0.5}')
  is_float "$gtemp" && gtemp_txt=$(awk -v v="$gtemp" 'BEGIN{printf "%d°", v+0.5}')

  # PWRの履歴は生の電力値を保持する（欠損時は履歴を汚さないよう追加しない）。
  is_float "$power" && PWR_HIST="$(append_hist "$PWR_HIST" "$power" "$SPARK_N")"
  local pwr_spark; pwr_spark="$(build_pwr_spark "$PWR_HIST" "$SPARK_N")"

  # CPUブロック: 太字見出し「CPU <温度>」+ E/P サブ行（インデント、
  # スパークライン表示）。
  printf '%sCPU%s %s%s%s\n' "$LBL_BOLD" "$RESET" "$DIM" "$ctemp_txt" "$RESET"
  spark_row '  E ' "$LBL" "$ecpu_spark" "$ecpu_p"; printf '%s\n' "$RESET"
  spark_row '  P ' "$LBL" "$pcpu_spark" "$pcpu_p"; printf '%s\n' "$RESET"
  printf '\n'

  # GPU行: 単独グループ（スパークライン＋現在値＋温度）
  spark_row 'GPU ' "$LBL_BOLD" "$gpu_spark" "$gpu_p"
  printf ' %s%s%s\n' "$DIM" "$gtemp_txt" "$RESET"
  printf '\n'

  # RAM行: 単独グループ。E/P/GPUと同じスパークライン表示（0-100%固定
  # スケール・同じ色しきい値）。右端に使用GiB/総GiB を併記する。
  spark_row 'RAM ' "$LBL_BOLD" "$ram_spark" "$ram_pct"
  printf ' %s%s/%sG%s\n' "$DIM" "$ram_used_gib" "$ram_total_gib" "$RESET"
  printf '\n'

  # PWR行: 単独グループ（スパークライン化。%基準の色しきい値が無いため
  # pwr_spark_row内で常に緑固定色を使う）
  pwr_spark_row 'PWR ' "$LBL_BOLD" "$pwr_spark" "$power_txt"; printf '%s\n' "$RESET"
}

# macmon 実行ファイルの絶対パスを解決する。CMUX_MACMON_BIN 優先、無ければ
# PATH から探す。見つからなければ何も出さず非0を返す。
resolve_macmon() {
  if [ -x "$MACMON_BIN" ]; then
    printf '%s' "$MACMON_BIN"
    return 0
  fi
  local found; found="$(command -v macmon 2>/dev/null)"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# macmon が異常終了（pipe が EOF）した際、再起動までの待機とエラー表示を
# 同期出力モードで行単位上書きする（run_stream 本体と同じ描画領域を使う）。
show_retry_error() {
  printf '\033[?2026h\033[H%smacmon 終了、%d秒後に再起動します%s\033[K\n\033[J\033[?2026l' \
    "$ERR_C" "$RETRY_SECONDS" "$RESET"
}

run_stream() {
  local tmpframe
  # render_frame の出力は必ずファイルリダイレクトで受ける（コマンド置換や
  # パイプで包むとサブシェル化し、履歴更新の副作用が失われるため）。
  tmpframe="$(mktemp "${TMPDIR:-/tmp}/cmux-system-watch.XXXXXX")" || {
    printf '%ssystem ERR (mktemp failed)%s\n' "$ERR_C" "$RESET"
    exit 1
  }
  printf '\033[?25l'
  # どの経路で終了しても同期出力モード解除・カーソル表示復帰・一時ファイル
  # 削除を行う（?2026h の直後に割り込まれてもモードが端末に残らないように）
  trap 'printf "\033[?2026l\033[?25h"; rm -f "$tmpframe"' EXIT
  trap 'exit 0' INT TERM HUP
  # 初回のみ全消去。以降は全消去せず、ホーム位置から行単位で上書きして
  # 残りを消す（\033[K/\033[J）。全体を同期出力モード（?2026）で囲み、
  # 途中状態が描画されるチラつきを防ぐ。
  printf '\033[2J'
  local line frame
  while :; do
    "$MACMON_BIN" pipe -i "$INTERVAL_MS" 2>/dev/null | while IFS= read -r line; do
      render_frame "$line" > "$tmpframe" || continue
      frame="$(sed "s/\$/${ESC}[K/" "$tmpframe")"
      printf '\033[?2026h\033[H%s\n\033[J\033[?2026l' "$frame"
    done
    # macmon プロセスが終了した（pipe が EOF になった）場合はここに来る。
    # 高速な再起動ループにならないよう数秒待ってから再起動する（履歴は
    # 新しいプロセスの while ループでリセットされる＝起動直後の▁埋め状態）。
    show_retry_error
    sleep "$RETRY_SECONDS"
  done
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '%ssystem ERR (jq not found)%s\n' "$ERR_C" "$RESET"
    exit 1
  fi
  if [ "${1:-}" = "--once" ]; then
    local line
    IFS= read -r line
    render_frame "$line"
    return
  fi
  MACMON_BIN="$(resolve_macmon)" || {
    printf '%ssystem ERR (macmon not found)%s\n' "$ERR_C" "$RESET"
    exit 1
  }
  run_stream
}

main "$@"
