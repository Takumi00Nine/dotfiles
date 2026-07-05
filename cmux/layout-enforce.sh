#!/bin/bash
# 現在のワークスペースの列構成を判定し、[[Preferences/cmux-layout]] の
# 目標幅へ冪等に矯正する単発スクリプト。主用途はチームメイト spawn 直後
# （リーダー+チームメイト列の2列 → 75%/25%）だが、判定ロジックは
# show-review.sh と同じ lib-layout.sh を使うため、成果物列がある状態で
# 呼んでも正しい目標（50/50 や 37.5/12.5/50）へ矯正される。
#
# 引数なし。今フォーカスされている（または CMUX_WORKSPACE_ID の）
# ワークスペースだけを対象にする。
#
# 使い方:
#   layout-enforce.sh
#
# 幅の矯正ロジック本体（列の実測・resize-pane 呼び出し）は show-review.sh
# と共有するため二重実装せず lib-layout.sh に集約している。

set -u

err() { printf 'layout-enforce: %s\n' "$1" >&2; exit 1; }

# SCRIPT_DIR 算出・lib-layout.sh の source のどちらの失敗も黙って握り
# 潰さず明示的に止める（2026-07-05 Codexレビュー指摘。以前は source 失敗時
# に enforce_layout_widths が未定義のまま呼ばれ、素の "command not found"
# にしかならなかった）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || err "スクリプト自身のディレクトリを特定できませんでした"
. "$SCRIPT_DIR/lib-layout.sh" || err "lib-layout.sh の読み込みに失敗しました: $SCRIPT_DIR/lib-layout.sh"

# show-review.sh の resolve_workspace と同じフォールバック規則
# （CMUX_WORKSPACE_ID 優先、無ければ `cmux identify` のフォーカス中WS）。
resolve_workspace() {
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    printf '%s' "$CMUX_WORKSPACE_ID"
    return 0
  fi
  cmux identify --json 2>/dev/null | jq -r '.focused.workspace_ref // empty'
}

main() {
  [ $# -eq 0 ] || err "使い方: layout-enforce.sh（引数なし）"
  command -v jq >/dev/null 2>&1 || err "jq が見つかりません"

  local ws
  ws="$(resolve_workspace)"
  [ -n "$ws" ] || err "cmux のワークスペースが特定できません（cmux 内の端末で実行してください）"

  # hint_pane を渡さない＝「今の列構成をそのまま見て役割判定する」モード
  # （show-review.sh のような「直前に自分が触ったペイン」の手がかりが無い
  # ため）。
  enforce_layout_widths "$ws"
}

main "$@"
