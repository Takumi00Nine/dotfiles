#!/bin/bash
# 成果物（Markdown / HTML / URL）を cmux ペインでレビュー用に表示する。
# タブ増殖を防ぐため次の優先順位で表示先を決める（実機確認済みの挙動に
# 基づく。cmux 自身の `browser open` 等が持つ「右隣のペインを自動再利用」
# ヒューリスティックはどのペインを掴むか予測できず、無関係な既存ペイン
# （タクミンが元から使っていたペイン等）に誤って追加しかねないため使わず、
# 本スクリプトが自前で状態を追跡してペインを明示的に選ぶ）:
#   (a) 同じ対象が既にタブで表示済み → そのタブを再利用（フォーカス、
#       ブラウザ系なら navigate で最新化）
#   (b) 未表示だが本スクリプトが過去に使ったペイン（生存していれば）が
#       ある → そのペインへ新タブとして追加（新規ペインは作らない）
#   (c) どちらも無い → 新規ペインを作る。この際、単純に「呼び出し元の
#       ペインから右へsplit」すると、既にその右にチームメイト列など別の
#       列がある場合はリーダーとその列の間に割り込んでしまう（実機確認
#       済み）。ワークスペース全体で最も右にあるペインを起点に右split
#       することで、常にワークスペースの一番右の新しい列として追加する
#       （cmux claude-teams はチームメイトを「右の列」に自動で縦積みする
#       ため、想定レイアウトは 左=リーダー / 中央=チームメイト列
#       / 右=本スクリプトの成果物列 になる）。
# Markdown は `cmux markdown open`（ライブリロード付き整形プレビュー）/
# 汎用 `cmux open --pane`（既存ペインへ追加する唯一の手段。同じ markdown
# ビューアーが使われるためライブリロードは引き継がれる想定）、
# HTML/URL は `cmux new-pane --type browser` / `cmux new-surface --type
# browser --pane`（`cmux open` はローカルhtmlを非対話のfilepreview扱いに
# してしまうため使わない）に振り分ける。
# ワークスペースごとに「対象→surface/pane」の対応を状態ファイルへ記録し、
# 次回以降はこれを見て再利用・追加先ペインを判断する。
#
# 使い方:
#   show-review.sh <path-or-url>
# 例:
#   show-review.sh ./review.md
#   show-review.sh ./report.html
#   show-review.sh https://example.com/preview

err() { printf 'show-review: %s\n' "$1" >&2; exit 1; }

# err より後ろで参照される関数（_columns_json 等）を持ち込む source なので、
# err 自体は先に定義しておく。SCRIPT_DIR 算出・source のどちらの失敗も
# 黙って握り潰さず明示的に止める（2026-07-05 Codexレビュー指摘。以前は
# source 失敗時に enforce_layout_widths 等が未定義のまま呼ばれ、素の
# "command not found" にしかならなかった）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || err "スクリプト自身のディレクトリを特定できませんでした"
# 列幅の矯正ロジック（_columns_json / apply_column_targets /
# enforce_layout_widths 等）は layout-enforce.sh と共有するため
# lib-layout.sh に切り出している（二重実装しない、2026-07-05）。
. "$SCRIPT_DIR/lib-layout.sh" || err "lib-layout.sh の読み込みに失敗しました: $SCRIPT_DIR/lib-layout.sh"

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cmux-show-review"
STATE_FILE="$STATE_DIR/state.json"

LOCK_DIR="$STATE_DIR/.lock"
LOCK_HELD=""

# state.json の read-modify-write を排他する簡易ロック（flock非依存、
# mkdir はアトミック）。前回プロセスが異常終了して lock だけ残っている
# 場合は、所有者PIDが生きていなければ即座に破棄して奪い直す。
# それでも取得できない（=本当に他プロセスが実行中）場合は、無排他の
# まま続行して二重ペインを許すより、待った上でエラー終了する方を選ぶ。
acquire_lock() {
  local waited=0 owner_pid
  mkdir -p "$STATE_DIR"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR" 2>/dev/null
      continue
    fi
    waited=$((waited + 1))
    [ "$waited" -ge 50 ] && err "他の show-review 実行と競合しています（ロック取得に失敗しました）"
    sleep 0.1
  done
  printf '%s' "$$" >"$LOCK_DIR/pid" 2>/dev/null || { rmdir "$LOCK_DIR" 2>/dev/null; err "ロックファイルの作成に失敗しました"; }
  LOCK_HELD=1
  trap 'release_lock' EXIT
}

release_lock() {
  local owner_pid
  [ -n "$LOCK_HELD" ] || return 0
  owner_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  # pid が自分自身のものであることを確認してから消す（他プロセスが
  # 既に奪い直していた場合に誤って消さないため）。
  if [ "$owner_pid" = "$$" ]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
}

# CMUX_WORKSPACE_ID は cmux 内の端末では自動設定されるが、念のため
# 未設定時は `cmux identify` のフォーカス中ワークスペースへフォールバックする。
resolve_workspace() {
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    printf '%s' "$CMUX_WORKSPACE_ID"
    return 0
  fi
  cmux identify --json 2>/dev/null | jq -r '.focused.workspace_ref // empty'
}

# 引数を種別判定する。TARGET（cmux へ渡す実際のパス/URL）と
# KIND（markdown|browser）をグローバル変数へセットする。
classify_target() {
  local arg="$1" resolved
  case "$arg" in
    http://*|https://*)
      TARGET="$arg"
      KIND="browser"
      return 0
      ;;
  esac
  command -v realpath >/dev/null 2>&1 || err "realpath コマンドが見つかりません"
  resolved="$(realpath -- "$arg" 2>/dev/null)"
  [ -n "$resolved" ] || err "ファイルが見つかりません: $arg"
  case "$resolved" in
    *.md|*.markdown)
      TARGET="$resolved"
      KIND="markdown"
      ;;
    *.html|*.htm)
      TARGET="file://$(path_to_uri "$resolved")"
      KIND="browser"
      ;;
    *)
      err "対応していない対象です（.md / .html / URL のみ）: $arg"
      ;;
  esac
}

# 絶対パスを file:// URI 用にパーセントエンコードする（区切りの "/" は保持し、
# 各セグメントだけ jq の @uri でエンコードする）。空白や # ? % などを含む
# パスがそのまま URL の一部として誤解釈されるのを防ぐ。
path_to_uri() {
  jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")'
}

state_init() {
  mkdir -p "$STATE_DIR"
  if [ -f "$STATE_FILE" ] && jq -e '.entries | type == "array"' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi
  # 壊れたJSON（手動編集・書込途中クラッシュ等）は退避してから作り直す。
  # これをしないと毎回パース失敗→常に新規オープンし続けることになる。
  # mktemp でユニークな退避先を確保する（同一秒内の衝突を避けるため）。
  # 退避に失敗した場合は、元の状態を黙って失わないよう明示的に止める。
  if [ -f "$STATE_FILE" ]; then
    local broken
    broken="$(mktemp "$STATE_FILE.broken.XXXXXX")" || err "破損した状態ファイルの退避先を作成できませんでした"
    mv "$STATE_FILE" "$broken" || err "破損した状態ファイルの退避に失敗しました: $STATE_FILE"
  fi
  printf '{"entries":[]}' >"$STATE_FILE" || err "状態ファイルを作成できませんでした: $STATE_FILE"
}

# 既存エントリを1行 TSV（surface<TAB>pane）で返す。無ければ空文字。
state_lookup() {
  local ws="$1" target="$2"
  jq -r --arg ws "$ws" --arg target "$target" \
    '.entries[] | select(.workspace==$ws and .target==$target) | [.surface, .pane] | @tsv' \
    "$STATE_FILE" 2>/dev/null | tail -n1
}

# 同じ workspace+target のエントリを消してから最新の対応関係を追記する
# （tmp へ書いてから mv することで読み取り側と競合しないようにする）。
state_upsert() {
  local ws="$1" target="$2" kind="$3" surface="$4" pane="$5" tmp
  tmp="$(mktemp "$STATE_DIR/state.XXXXXX")"
  jq --arg ws "$ws" --arg target "$target" --arg kind "$kind" \
     --arg surface "$surface" --arg pane "$pane" \
    '.entries |= (map(select(.workspace==$ws and .target==$target | not))
      + [{workspace:$ws, target:$target, kind:$kind, surface:$surface, pane:$pane}])' \
    "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
}

# 記録済み surface が今も存在し、種別も一致していれば 0 を返す。
surface_still_valid() {
  local ws="$1" surface="$2" kind="$3"
  [ -n "$surface" ] || return 1
  cmux list-panels --json --workspace "$ws" 2>/dev/null \
    | jq -e --arg surface "$surface" --arg kind "$kind" \
      '.surfaces[] | select(.ref==$surface and .type==$kind)' >/dev/null
}

# 優先順位(b): このワークスペースで本スクリプトが過去に使ったペインのうち、
# まだ markdown/browser 系の surface が残っている（=無関係な用途に転用され
# 尽くしていない）ものを直近順で探して返す。無ければ空文字（呼び出し側は
# 優先順位(c)＝新規ペインへ回る）。
find_review_pane() {
  local ws="$1" candidates panels_json p seen=""
  candidates="$(jq -r --arg ws "$ws" \
    '[.entries[] | select(.workspace==$ws) | .pane] | reverse | .[]' \
    "$STATE_FILE" 2>/dev/null)"
  [ -n "$candidates" ] || return 0
  panels_json="$(cmux list-panels --json --workspace "$ws" 2>/dev/null)"
  [ -n "$panels_json" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case " $seen " in *" $p "*) continue ;; esac
    seen="$seen $p"
    if jq -e --arg p "$p" \
      '.surfaces[] | select(.pane_ref==$p and (.type=="markdown" or .type=="browser"))' \
      <<<"$panels_json" >/dev/null 2>&1; then
      printf '%s' "$p"
      return 0
    fi
  done <<<"$candidates"
}

# 優先順位(c)の下準備: ワークスペース全体で今いちばん右にあるペインの
# surface を返す（pane<TAB>surface の1行TSV、無ければ空文字）。
# `cmux new-pane --direction right` / `new-split right` は指定した起点
# ペインの「その場で右半分に割る」だけで、workspace 全体の右端まで押し出す
# わけではない（実機確認済み: リーダーペインを起点に right すると、既に
# その右にチームメイト列がある場合はリーダーとチームメイト列の間に新しい
# 列が割り込んでしまう）。そのため起点は「呼び出し元のペイン」ではなく
# 「現在ワークスペースで最も右にあるペイン」に固定する必要がある。
# pixel_frame の右端座標（x+width）が最大のものを選ぶ。
find_rightmost_pane() {
  local ws="$1" panes_json
  panes_json="$(cmux list-panes --workspace "$ws" --json 2>/dev/null)"
  [ -n "$panes_json" ] || return 0
  jq -r '[.panes[] | select(.selected_surface_ref != null
              and (.pixel_frame.x? | type) == "number"
              and (.pixel_frame.width? | type) == "number")
            | {pane: .ref, surface: .selected_surface_ref, edge: (.pixel_frame.x + .pixel_frame.width)}]
          | sort_by(.edge) | last
          | select(. != null) | [.pane, .surface] | @tsv' \
    <<<"$panes_json" 2>/dev/null
}

# 列幅の矯正（review_pane が属する最右列を目標幅へ寄せる）は
# lib-layout.sh の enforce_layout_widths に切り出し済み（layout-enforce.sh
# と共有・2026-07-05）。呼び出し箇所は main() 内を参照。

# 新規オープンを実行し、結果を NEW_SURFACE / NEW_PANE へセットする。
# pane_hint があれば既存ペインへタブ追加を試み、失敗（取得直後に閉じられた
# 等）すれば新規ペイン作成にフォールバックする。fresh_surface が非空のとき
# の pane_hint は、本関数の呼び出し側が「今回のためだけに」空で作った
# 使い捨てペインなので、流し込みに失敗したら放置せず閉じてからフォール
# バックする（reuse目的の pane_hint はここで閉じない＝他のタブが残って
# いる可能性がある）。close-surface は --surface にサーフェス参照を要求し
# ペイン参照では解決できない（実機確認済み: pane:N を渡すと
# `not_found: Surface not found` になる）ため、pane_hint ではなく
# fresh_surface（そのペインの surface 参照）を渡す。
open_new() {
  local ws="$1" kind="$2" target="$3" pane_hint="$4" fresh_surface="$5" out

  NEW_SURFACE=""; NEW_PANE=""

  if [ -n "$pane_hint" ]; then
    if [ "$kind" = "markdown" ]; then
      # markdown を既存ペインへ追加できるのは汎用 `cmux open --pane` だけ
      # （`cmux markdown open` は毎回新規split専用で --pane を持たない）。
      out="$(cmux open "$target" --workspace "$ws" --pane "$pane_hint" --focus true --json 2>/dev/null)"
      [ -n "$out" ] && NEW_SURFACE="$(jq -r '.opened[0].payload.surface_ref // empty' <<<"$out")"
      [ -n "$out" ] && NEW_PANE="$(jq -r '.opened[0].payload.pane_ref // empty' <<<"$out")"
    else
      out="$(cmux new-surface --type browser --pane "$pane_hint" --workspace "$ws" --url "$target" --focus true --json 2>/dev/null)"
      [ -n "$out" ] && NEW_SURFACE="$(jq -r '.surface_ref // empty' <<<"$out")"
      [ -n "$out" ] && NEW_PANE="$(jq -r '.pane_ref // empty' <<<"$out")"
    fi
    if [ -n "$NEW_SURFACE" ]; then
      # pane_ref がJSONに含まれない形状変化があっても、次回の
      # find_review_pane が使えるよう pane_hint 自体を記録しておく。
      [ -n "$NEW_PANE" ] || NEW_PANE="$pane_hint"
      # new-split のプレースホルダは流し込み成功後に不要。閉じ忘れると
      # 空ターミナルタブが残る（2026-07-05 実運用で発覚）。fresh_surface は
      # ケース(c)（新設split）のみ非空で、ケース(b)（既存ペインへのタブ
      # 追加）では空のため、その場合はここは何もしない。
      if [ -n "$fresh_surface" ]; then
        cmux close-surface --workspace "$ws" --surface "$fresh_surface" >/dev/null 2>&1 \
          || printf 'show-review: 空ペインのクリーンアップに失敗しました（放置されます）: %s\n' "$fresh_surface" >&2
      fi
      return 0
    fi
    if [ -n "$fresh_surface" ]; then
      cmux close-surface --workspace "$ws" --surface "$fresh_surface" >/dev/null 2>&1 \
        || printf 'show-review: 空ペインのクリーンアップに失敗しました（放置されます）: %s\n' "$fresh_surface" >&2
    fi
  fi

  if [ "$kind" = "markdown" ]; then
    out="$(cmux markdown open "$target" --workspace "$ws" --focus true --json)" || err "markdown open に失敗しました"
  else
    # `cmux browser open` は「右隣ペインの自動再利用」ヒューリスティックを
    # 持ち無関係な既存ペインを掴みうるため使わない。`new-pane` は常に
    # 新規ペインを作る（実機確認済み）ので優先順位(c)に合致する。ただし
    # これも起点はワークスペースの right-most ではなく呼び出し元ペインなので、
    # ここに来るのは find_rightmost_pane が使えなかった場合の最終手段。
    out="$(cmux new-pane --type browser --url "$target" --workspace "$ws" --direction right --focus true --json)" || err "new-pane(browser) に失敗しました"
  fi
  NEW_SURFACE="$(jq -r '.surface_ref // empty' <<<"$out")"
  NEW_PANE="$(jq -r '.pane_ref // empty' <<<"$out")"
  [ -n "$NEW_SURFACE" ] || err "surface_ref を取得できませんでした: $out"
}

main() {
  local arg="$1" ws surface pane existing
  [ $# -eq 1 ] || err "使い方: show-review.sh <path-or-url>"
  command -v jq >/dev/null 2>&1 || err "jq が見つかりません"

  classify_target "$arg"
  ws="$(resolve_workspace)"
  [ -n "$ws" ] || err "cmux のワークスペースが特定できません（cmux 内の端末で実行してください）"

  # lookup → open → upsert の一連を排他し、同時実行で二重にペインが
  # 開かれるのを防ぐ（state_init もロック内。ロック取得自体は待機上限あり）。
  acquire_lock
  state_init

  local reused=""
  existing="$(state_lookup "$ws" "$TARGET")"
  if [ -n "$existing" ]; then
    surface="${existing%%$'\t'*}"
    pane="${existing#*$'\t'}"
    if surface_still_valid "$ws" "$surface" "$KIND"; then
      # Markdown はファイル変更を自動反映（ライブリロード）するため
      # 再オープンは不要。ブラウザは navigate で明示的に最新内容へ更新する。
      # navigate が失敗した場合は再利用を諦め、新規オープンにフォールバックする。
      if [ "$KIND" != "browser" ] || cmux browser "$surface" navigate "$TARGET" >/dev/null 2>&1; then
        # 幅の矯正は行わない（2026-07-05 夜・本人指定＝cmux デフォルトの
        # 分割比率のままで良い。カスタム矯正 enforce_layout_widths は廃止。
        # 経緯は Preferences/cmux-layout）。
        cmux focus-panel --panel "$surface" --workspace "$ws" >/dev/null || err "focus-panel に失敗しました: $surface"
        reused=1
      fi
    fi
    # surface が既に閉じられていた/再利用に失敗した場合は新規オープンへ。
  fi
  [ -n "$reused" ] && return 0

  # 優先順位(b): 過去に使った生存中ペインがあればそこへ追加、
  # 無ければ(c)新規ペイン。open_new 内でフォールバックまで処理する。
  local pane_hint fresh_surface=""
  pane_hint="$(find_review_pane "$ws")"
  if [ -z "$pane_hint" ]; then
    # (c) 新規ペイン: ワークスペースの最も右のペインを起点に、まず中身の
    # 無い空ペインだけを右方向へ割っておき（--focus false でユーザーの
    # フォーカスは動かさない）、その空ペインへ open_new の pane_hint 経路で
    # 中身を流し込む。こうすることで、途中にチームメイト列などが挟まって
    # いても常にワークスペースの一番右の新しい列として追加される
    # （find_rightmost_pane 直前のコメント参照）。起点が見つからない・
    # split自体に失敗した場合は pane_hint を空のままにし、open_new 側の
    # 旧来のフォールバック（呼び出し元ペイン起点の new-pane/markdown open）
    # に委ねる。
    local rm_tsv rm_surface split_out split_status=1
    rm_tsv="$(find_rightmost_pane "$ws")"
    if [ -n "$rm_tsv" ]; then
      rm_surface="${rm_tsv#*$'\t'}"
      split_out="$(cmux new-split right --surface "$rm_surface" --workspace "$ws" --focus false --json 2>/dev/null)"
      split_status=$?
      if [ "$split_status" -eq 0 ] && [ -n "$split_out" ]; then
        pane_hint="$(jq -r '.pane_ref // empty' <<<"$split_out")"
        fresh_surface="$(jq -r '.surface_ref // empty' <<<"$split_out")"
        if [ -z "$pane_hint" ] || [ -z "$fresh_surface" ]; then
          # new-split の応答から pane_ref/surface_ref を取り切れなかった
          # 場合の保険。split 自体は終了ステータス0で成功しているはずなので、
          # 直後にもう一度 find_rightmost_pane すれば「今作ったばかりの
          # 空ペイン」を取り戻せる……はずだが、split前の rm_tsv と同じ結果
          # が返る可能性もある（レイアウト反映の遅延・実際にはsplitされて
          # いない等）。その場合は既存の（無関係な）ペインを誤って fresh
          # 扱いし、後述のクリーンアップで他人のペインを閉じてしまう事故に
          # なるため、rm_tsv と異なる結果が得られたときだけ採用する。
          local recover_tsv
          recover_tsv="$(find_rightmost_pane "$ws")"
          if [ -n "$recover_tsv" ] && [ "$recover_tsv" != "$rm_tsv" ]; then
            pane_hint="${recover_tsv%%$'\t'*}"
            fresh_surface="${recover_tsv#*$'\t'}"
          else
            pane_hint=""
            fresh_surface=""
          fi
        fi
        # pane_hint と fresh_surface は対で揃わない限り使わない。
        # fresh_surface が無いまま pane_hint だけ使うと、流し込み失敗時に
        # クリーンアップ手段（正しい surface 参照）が無く空ペインが残る
        # ため、旧来のフォールバックに委ねた方が安全。
        if [ -z "$pane_hint" ] || [ -z "$fresh_surface" ]; then
          pane_hint=""
          fresh_surface=""
        fi
      fi
    fi
  fi
  open_new "$ws" "$KIND" "$TARGET" "$pane_hint" "$fresh_surface"
  surface="$NEW_SURFACE"
  pane="$NEW_PANE"

  state_upsert "$ws" "$TARGET" "$KIND" "$surface" "$pane" || err "状態ファイルの更新に失敗しました"
  # 幅の矯正は行わない（2026-07-05 夜・本人指定＝cmux デフォルトの分割比率で
  # 良い。リーダーのみ→成果物で 50/50、ワーカー列あり→ 50/25/25 に自然になる）。
  # --focus true 直後は稀にフォーカス反映がまだ効いていないことがある
  # （実機確認）ため、念のため明示的にも focus-panel しておく。
  cmux focus-panel --panel "$surface" --workspace "$ws" >/dev/null || err "focus-panel に失敗しました: $surface"
}

main "$@"
