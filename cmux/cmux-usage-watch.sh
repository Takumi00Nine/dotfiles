#!/bin/bash
# Claude/Codex 使用率を cmux Dock（縦長ペイン）向けに複数行で描画する。
# claude-codex-usage のキャッシュ JSON を読むだけ（通信なし）。
# 表示例:
#   Claude
#    5h ██████░░  54% ↻3:04
#    7d ░░░░░░░░   6% ↻27:24
#
#   Codex
#    5h ░░░░░░░░   5% ↻2:57
#    7d ███░░░░░  27% ↻70:01

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-codex-usage"
INTERVAL="${CMUX_USAGE_INTERVAL:-5}"
CELLS="${CMUX_USAGE_CELLS:-8}"
STALE_MINUTES="${STALE_MINUTES:-10}"

# 環境変数由来の数値を検証し、無効値は既定値へ戻す（sleep 即時失敗による
# 高速ループや算術式エラーを防ぐ）。CELLS は狭幅ペイン用途なので上限つき。
case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=5 ;; esac
case "$CELLS" in ''|*[!0-9]*|0) CELLS=8 ;; esac
[ "$CELLS" -gt 40 ] && CELLS=40
case "$STALE_MINUTES" in ''|*[!0-9]*|0) STALE_MINUTES=10 ;; esac

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
LBL="${ESC}[38;5;252m"
EMPTY_C="${ESC}[38;5;238m"
ERR_C="${ESC}[38;5;197m"

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 使用率に応じた 256 色番号（tmux-usage.sh の pcolor と同じしきい値）
pcolor() {
  local p="${1%.*}"
  is_number "$p" || { printf '244'; return; }
  if [ "$p" -ge 80 ]; then printf '197'
  elif [ "$p" -ge 50 ]; then printf '214'
  else printf '114'; fi
}

read_field() { jq -r "$2 // empty" "$1" 2>/dev/null; }

# 1ウィンドウ分の行: " 5h ██████░░  54% ↻3:04"
window_line() {
  local label="$1" value="$2" epoch="$3"
  local p="${value%.*}" color filled empty i rem
  printf ' %s%s ' "$LBL" "$label"
  if ! is_number "$p"; then
    printf '%s' "$EMPTY_C"
    i=0; while [ "$i" -lt "$CELLS" ]; do printf '░'; i=$(( i + 1 )); done
    printf ' %s  --' "$DIM"
  else
    [ "$p" -gt 100 ] && p=100
    color="${ESC}[38;5;$(pcolor "$p")m"
    filled=$(( (p * CELLS + 50) / 100 ))
    [ "$filled" -gt "$CELLS" ] && filled="$CELLS"
    empty=$(( CELLS - filled ))
    printf '%s' "$color"
    i=0; while [ "$i" -lt "$filled" ]; do printf '█'; i=$(( i + 1 )); done
    printf '%s' "$EMPTY_C"
    i=0; while [ "$i" -lt "$empty" ]; do printf '░'; i=$(( i + 1 )); done
    printf ' %s%3d%%' "$color" "$p"
  fi
  if is_number "$epoch"; then
    rem=$(( epoch - NOW ))
    if [ "$rem" -gt 0 ]; then
      printf ' %s↻%d:%02d' "$DIM" $(( rem / 3600 )) $(( (rem % 3600) / 60 ))
    fi
  fi
  printf '%s\n' "$RESET"
}

# サービス1つ分のブロック（ヘッダー行＋5h/7d 行）
service_block() {
  local file="$1" name="$2" color_num="$3"
  local h d r rd fetched err age
  printf '%s[38;5;%s;1m%s%s' "$ESC" "$color_num" "$name" "$RESET"
  if [ ! -f "$file" ]; then
    printf ' %sn/a%s\n' "$DIM" "$RESET"
    return
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf ' %sERR%s\n' "$ERR_C" "$RESET"
    return
  fi
  err="$(read_field "$file" '.last_error.type')"
  [ -n "$err" ] && printf ' %sERR%s' "$ERR_C" "$RESET"
  fetched="$(read_field "$file" '.fetched_at')"
  if is_number "$fetched"; then
    age=$(( NOW - fetched ))
    if [ "$age" -gt $(( STALE_MINUTES * 60 )) ]; then
      printf ' %s(%d分前)%s' "$DIM" $(( age / 60 )) "$RESET"
    fi
  fi
  printf '\n'
  h="$(read_field "$file" '.five_hour.used_percent')"
  d="$(read_field "$file" '.seven_day.used_percent')"
  r="$(read_field "$file" '.five_hour.resets_at_epoch')"
  rd="$(read_field "$file" '.seven_day.resets_at_epoch')"
  window_line "5h" "$h" "$r"
  window_line "7d" "$d" "$rd"
}

render() {
  NOW="$(date '+%s')"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%susage ERR (jq not found)%s\n' "$ERR_C" "$RESET"
    return
  fi
  service_block "$CACHE_DIR/claude-cache.json" "Claude" 39
  printf '\n'
  service_block "$CACHE_DIR/codex-cache.json" "Codex" 213
}

main() {
  if [ "${1:-}" = "--once" ]; then
    render
    return
  fi
  printf '\033[?25l'
  # どの経路で終了しても同期出力モード解除とカーソル表示を復帰させる
  # （?2026h の直後に割り込まれてもモードが端末に残らないように）
  trap 'printf "\033[?2026l\033[?25h"' EXIT
  trap 'exit 0' INT TERM HUP
  # 初回のみ全消去。以降は全消去せず、ホーム位置から行単位で上書きして
  # 残りを消す（\033[K/\033[J）。全体を同期出力モード（?2026）で囲み、
  # 途中状態が描画されるチラつきを防ぐ。
  printf '\033[2J'
  local frame
  while :; do
    frame="$(render | sed "s/\$/${ESC}[K/")"
    printf '\033[?2026h\033[H%s\n\033[J\033[?2026l' "$frame"
    sleep "$INTERVAL"
  done
}

main "$@"
