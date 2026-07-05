# cmux ワークスペースの列幅を [[Preferences/cmux-layout]] の目標値へ矯正する
# 共通ロジック。show-review.sh（成果物表示時）と layout-enforce.sh
# （チームメイト起動直後）の両方から source される（幅矯正を二重実装
# しないため、2026-07-05 の幅ルール精緻化を機に show-review.sh から
# 切り出した）。単体では実行しない（関数定義のみ、副作用なし）。
#
# 目標（状態ごと固定・タクミン指定 2026-07-05）:
#   1列（リーダーのみ）        : 100%
#   2列（リーダー+チームメイト）: 75% / 25%
#   2列（リーダー+成果物）      : 50% / 50%
#   3列（フル）                : 37.5% / 12.5% / 50%
#   4列以上                    : 矯正せず stderr 警告のみ（既存仕様の維持）
#
# 列の役割判定: 左端（x最小）=リーダー、固定。最右列に markdown/browser
# 系 surface が乗っていれば「成果物列」、なければ「チームメイト列」と
# みなす（cmux claude-teams はチームメイトを1列に縦積みするだけで、本
# レイアウトでチームメイト列がterminal以外のsurfaceを持つことは無い前提）。
#
# 使い方:
#   source ".../lib-layout.sh"
#   enforce_layout_widths "$ws" [hint_pane]

RESIZE_TOLERANCE_PX=2

# 現在のワークスペースの列（同一x座標を共有するペイン群）をx昇順で返す。
# 出力: {"total": <全幅>, "surfaces_ok": true|false,
#         "columns": [{"x":.., "width":.., "panes":[ref,...],
#         "has_review_surface": true|false}, ...]}
# has_review_surface は「この列のいずれかのペインに markdown/browser の
# surface が乗っているか」（list-panes の座標情報と list-panels の
# surface種別情報を pane参照で突き合わせる。それぞれ別コマンドの結果
# なので、list-panels 側だけ独立して失敗しうる）。surfaces_ok は
# list-panels の取得・パースに成功したかどうか（失敗時は has_review_surface
# が全列falseに固定されてしまい、成果物列をチームメイト列と誤判定しかねない
# ため、呼び出し側（enforce_layout_widths）が「役割判定不能」を区別できる
# よう明示的に返す＝2026-07-05 Codexレビュー指摘）。
_columns_json() {
  local ws="$1" panes_json panels_json panels_ok
  panes_json="$(cmux list-panes --workspace "$ws" --json 2>/dev/null)"
  [ -n "$panes_json" ] || return 1
  panels_json="$(cmux list-panels --json --workspace "$ws" 2>/dev/null)"
  if [ -n "$panels_json" ] && jq -e '.surfaces | type == "array"' <<<"$panels_json" >/dev/null 2>&1; then
    panels_ok=true
  else
    panels_ok=false
    panels_json='{"surfaces":[]}'
  fi
  jq -c --argjson panels "$panels_json" --argjson panels_ok "$panels_ok" '
    ($panels.surfaces // []) as $surfaces
    | { total: .container_frame.width,
        surfaces_ok: $panels_ok,
        columns: ( .panes
          | map(select((.pixel_frame.x? | type) == "number"
                       and (.pixel_frame.width? | type) == "number"))
          | group_by((.pixel_frame.x * 4) | round)
          | map({ x: .[0].pixel_frame.x, width: .[0].pixel_frame.width,
                  panes: map(.ref),
                  has_review_surface: (
                    any(.[]; .ref as $p
                      | any($surfaces[]; .pane_ref == $p
                          and (.type == "markdown" or .type == "browser"))) )
                })
          | sort_by(.x)) }' <<<"$panes_json" 2>/dev/null
}

# amount を四捨五入した整数へ丸めて resize-pane を呼ぶ（許容誤差
# RESIZE_TOLERANCE_PX 未満・0以下なら何もしない）。失敗しても致命的では
# ないため（レイアウト微調整に過ぎない）、戻り値は無視してよい呼び出し
# 専用にする。
_resize_pane() {
  local ws="$1" pane="$2" dir="$3" amount="$4" rounded
  rounded="$(awk -v a="$amount" 'BEGIN{printf "%.0f", a}' 2>/dev/null)"
  [ -n "$rounded" ] || return 0
  [ "$rounded" -gt 0 ] 2>/dev/null || return 0
  cmux resize-pane --pane "$pane" "$dir" --amount "$rounded" --workspace "$ws" >/dev/null 2>&1
}

# delta（目標幅 - 現在幅、呼び出し側が符号を用意する）が許容誤差を超えて
# いれば、正なら growth_pane を -L で伸ばし、負なら shrink_side_pane を -R
# で伸ばす（＝相対的に反対側を縮める）ことで境界を目標へ寄せる。
# 実測（cmux 0.64.17、隔離workspaceで検証）に基づく前提:
#   - resize-pane の方向は「指定ペインから見て最も近い分割境界」を動かす。
#   - amount は pixel_frame の座標系と同一単位（10指定で厳密に10px動く）。
#     負数は拒否される（"--amount must be greater than 0"）ため、縮めたい
#     側ではなく「反対側を伸ばす」操作を選ぶ。
#   - 境界が下限に達すると、それ以上はエラーにならず静かに変化しない。
_apply_delta() {
  local ws="$1" delta="$2" growth_pane="$3" shrink_side_pane="$4" abs_delta
  abs_delta="$(awk -v d="$delta" 'BEGIN{print (d<0?-d:d)}')"
  awk -v d="$abs_delta" -v tol="$RESIZE_TOLERANCE_PX" 'BEGIN{exit !(d>tol)}' || return 0
  if awk -v d="$delta" 'BEGIN{exit !(d>0)}'; then
    _resize_pane "$ws" "$growth_pane" -L "$delta"
  else
    _resize_pane "$ws" "$shrink_side_pane" -R "$abs_delta"
  fi
}

# apply_column_targets ws targets_csv
# targets_csv: 現在の列数と同じ要素数の目標比率（カンマ区切り、合計1）。
# 外側→内側の順で境界を動かす（外側を先に確定させないと、後段の内側
# 境界計算が比率再分配の影響を受けて狂うため）。列0..n-2 側の境界は
#「その列自身の目標幅」に直接合わせにいく（隣（右）列を伸縮させることで
# 間接的に実現＝下記ループ）。最後の境界だけは逆に「最右列自身の目標幅」
# に直接合わせにいく（隣（左）列を伸縮させることで実現）。中間に残る列は
# 差分として自動的に目標値へ収束する（目標比率の合計が1である前提）。
# 各ステップの前に必ず列構成を実測し直す（前段のリサイズによる比率
# 再分配の影響を受けないようにするため）。
apply_column_targets() {
  local ws="$1" targets_csv="$2"
  local -a targets
  IFS=',' read -r -a targets <<<"$targets_csv"
  # 同一 local 文で右辺に先行代入変数を参照すると（`set -u` 環境の
  # layout-enforce.sh から呼ばれた際に）unbound variable になる
  # （bashは同一コマンドの全引数を先に展開してから local を実行するため）。
  # そのため n と last の代入は文を分ける（2026-07-05 実機テストで発覚）。
  local n="${#targets[@]}"
  local last=$((n - 1))
  [ "$n" -ge 2 ] || return 0

  local data total ncols
  data="$(_columns_json "$ws")"
  [ -n "$data" ] || return 0
  total="$(jq -r '.total // empty' <<<"$data")"
  ncols="$(jq -r '.columns | length' <<<"$data")"
  [[ "$total" =~ ^[0-9.]+$ ]] || return 0
  [ "$ncols" = "$n" ] || return 0
  awk -v t="$total" 'BEGIN{exit !(t>0)}' || return 0

  local i
  for ((i = 0; i < last - 1; i++)); do
    data="$(_columns_json "$ws")"
    [ -n "$data" ] || return 0
    ncols="$(jq -r '.columns | length' <<<"$data")"
    [ "$ncols" = "$n" ] || return 0
    local col_w col_pane next_pane target_w delta
    col_w="$(jq -r --argjson i "$i" '.columns[$i].width' <<<"$data")"
    col_pane="$(jq -r --argjson i "$i" '.columns[$i].panes[0]' <<<"$data")"
    next_pane="$(jq -r --argjson i "$((i + 1))" '.columns[$i].panes[0]' <<<"$data")"
    [[ "$col_w" =~ ^[0-9.]+$ ]] || return 0
    [ -n "$col_pane" ] && [ -n "$next_pane" ] || return 0
    target_w="$(awk -v t="$total" -v f="${targets[$i]}" 'BEGIN{print t*f}')"
    # delta = 現在 - 目標（正=この列が広すぎる→隣列を-Lで伸ばして縮める）
    delta="$(awk -v w="$col_w" -v tw="$target_w" 'BEGIN{print w-tw}')"
    _apply_delta "$ws" "$delta" "$next_pane" "$col_pane"
  done

  data="$(_columns_json "$ws")"
  [ -n "$data" ] || return 0
  ncols="$(jq -r '.columns | length' <<<"$data")"
  [ "$ncols" = "$n" ] || return 0
  local left_pane last_pane last_w target_last delta
  left_pane="$(jq -r --argjson i "$((last - 1))" '.columns[$i].panes[0]' <<<"$data")"
  last_pane="$(jq -r --argjson i "$last" '.columns[$i].panes[0]' <<<"$data")"
  last_w="$(jq -r --argjson i "$last" '.columns[$i].width' <<<"$data")"
  [ -n "$left_pane" ] && [ -n "$last_pane" ] || return 0
  [[ "$last_w" =~ ^[0-9.]+$ ]] || return 0
  target_last="$(awk -v t="$total" -v f="${targets[$last]}" 'BEGIN{print t*f}')"
  # delta = 目標 - 現在（正=最右列が狭すぎる→自身を-Lで伸ばして広げる）
  delta="$(awk -v w="$last_w" -v tw="$target_last" 'BEGIN{print tw-w}')"
  _apply_delta "$ws" "$delta" "$last_pane" "$left_pane"
}

# enforce_layout_widths ws [hint_pane]
# 現在の列数と最右列の役割（成果物 or チームメイト）を判定し、対応する
# 目標比率で apply_column_targets を呼ぶ。hint_pane を渡した場合は、それが
# 実際に最右列に属していることを確認したうえで（show-review.sh が直前に
# 触ったペインが想定した列にあるかの追加ガード）、その最右列を無条件で
# 「成果物列」と確定する（surfaceの種別再判定はしない）。hint_pane が無い
# 場合（layout-enforce.sh のような「今の構成をそのまま見て判断する」単発
# 実行）は、list-panels から取得した has_review_surface で役割判定する。
# list-panels 自体の取得に失敗した場合、hint 無しでは役割を確定できない
# （has_review_surface が全列falseに落ちて成果物列をチームメイト列と誤判定
# し 75/25 を誤適用しかねない）ため、矯正せず警告のみで終える
# （2026-07-05 Codexレビュー指摘を受けたハイブリッド対策）。
# 想定外の構成（3列で最右列が成果物でない・4列以上）も同様に矯正せず
# stderr 警告のみで終える（既存仕様の維持）。
enforce_layout_widths() {
  local ws="$1" hint_pane="${2:-}"
  local data ncols
  data="$(_columns_json "$ws")"
  [ -n "$data" ] || return 0
  ncols="$(jq -r '.columns | length' <<<"$data")"
  [[ "$ncols" =~ ^[0-9]+$ ]] || return 0

  local last_is_review
  if [ -n "$hint_pane" ]; then
    local hint_idx
    hint_idx="$(jq -r --arg p "$hint_pane" \
      '[.columns[] | any(.panes[]; . == $p)] | index(true) // -1' <<<"$data")"
    [ "$hint_idx" = "$((ncols - 1))" ] || return 0
    last_is_review=true
  else
    local surfaces_ok
    surfaces_ok="$(jq -r '.surfaces_ok' <<<"$data")"
    if [ "$surfaces_ok" != "true" ]; then
      printf 'cmux-layout: list-panels の取得に失敗し列の役割判定ができないため、幅調整をスキップしました\n' >&2
      return 0
    fi
    last_is_review="$(jq -r --argjson i "$((ncols - 1))" '.columns[$i].has_review_surface' <<<"$data")"
  fi

  case "$ncols" in
    1) return 0 ;; # リーダーのみ: 常に100%なので矯正不要
    2)
      if [ "$last_is_review" = "true" ]; then
        apply_column_targets "$ws" "0.5,0.5"
      else
        apply_column_targets "$ws" "0.75,0.25"
      fi
      ;;
    3)
      if [ "$last_is_review" = "true" ]; then
        apply_column_targets "$ws" "0.375,0.125,0.5"
      else
        printf 'cmux-layout: 想定外の3列構成のため幅調整をスキップしました（最右列が成果物surfaceではありません）\n' >&2
      fi
      ;;
    *)
      printf 'cmux-layout: 想定外の列数(%s)のため幅調整をスキップしました（本レイアウトは最大3列が前提です）\n' "$ncols" >&2
      ;;
  esac
}
