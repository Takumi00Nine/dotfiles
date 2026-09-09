#!/bin/bash
# cmux Dock（狭幅ペイン・幅約40桁）向けに「プロジェクト横断の次アクション＋
# 外部脳ヘルス」を表示する常駐スクリプト。cmux-usage-watch.sh（描画ループ・
# 同期出力）と cmux-feed-watch.sh（jqサニタイズ・コードポイント単位の
# truncate）の流儀を踏襲する。
#
# 表示例:
#   ▶ Next (3)
#   svwb-pilot-log 実データ照合を回す
#   takumi009-ai-e (next未設定)
#   avatar-switch- 配布方式のたたき台を書く
#
#   ✅ 外部脳
#   棚卸し 要確認15件 (8/5)
#   週次 ✅8/5

# 共有 lib（幅・切り詰め・サニタイズ・frontmatter/Tasks節パーサ）を読み込む。
# symlink（~/work/tools/cmux-next-watch/…）経由で起動されても cd -P で物理
# パスへ解決するため、常に ~/work/dotfiles/cmux/ 配下の実体を見つける
# （cmux-session-todo 設計 §1.2）。lib が見つからないときは理由を1行出して
# 終了コード1とし、機能を欠いたまま無言で起動しない（同 §1.2）。
LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)/.."
if [ ! -r "$LIB_DIR/lib-dock-view.sh" ] || [ ! -r "$LIB_DIR/lib-vault-tasks.sh" ]; then
  echo "cmux-next-watch: 共有ライブラリが見つかりません（$LIB_DIR/lib-dock-view.sh ・ $LIB_DIR/lib-vault-tasks.sh）" >&2
  exit 1
fi
. "$LIB_DIR/lib-dock-view.sh"
. "$LIB_DIR/lib-vault-tasks.sh"

VAULT="${CMUX_NEXT_VAULT:-$HOME/Data/obsidian}"
INTERVAL="${CMUX_NEXT_INTERVAL:-60}"
# status 語彙は4値統一（active/paused/completed/closed＝Vault Decisions/
# 2026-08-06-project-status-taxonomy）。稼働=active・保留=paused のみ表示し、
# completed/closed は対象外。env は語彙移行期・実験用の上書き口として残す。
STATUS_ALLOW="${CMUX_NEXT_STATUS_ALLOW:-active}"
# 保留グループ（⏸ 表示）。稼働リストとは別セクションで通し番号の後半に出す。
STATUS_HOLD="${CMUX_NEXT_STATUS_HOLD:-paused}"
# テスト用フィクスチャ差し替え口（実Vault・実ログに依存しないテストのため。
# 通常運用では変更不要）。
INVENTORY_DIR="${CMUX_NEXT_INVENTORY_DIR:-$HOME/.claude/logs/vault-inventory}"
MAINT_STATE_FILE="${CMUX_NEXT_MAINT_STATE:-$HOME/.claude/logs/maintenance/last-run.json}"
MAINT_STALE_DAYS="${CMUX_NEXT_MAINT_STALE_DAYS:-8}"

# 環境変数由来の数値を検証し、無効値は既定値へ戻す（cmux-usage-watch.sh の
# env 検証と同じ流儀。sleep 即時失敗による高速ループを防ぐ）。
case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=60 ;; esac
case "$MAINT_STALE_DAYS" in ''|*[!0-9]*|0) MAINT_STALE_DAYS=8 ;; esac
STATUS_ALLOW="$(printf '%s' "$STATUS_ALLOW" | tr -d '[:space:]')"
[ -z "$STATUS_ALLOW" ] && STATUS_ALLOW="active"
STATUS_HOLD="$(printf '%s' "$STATUS_HOLD" | tr -d '[:space:]')"

ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[38;5;244m"
DIM_BOLD="${ESC}[38;5;244;1m"
LBL="${ESC}[38;5;252m"
LBL_BOLD="${ESC}[38;5;252;1m"
GOOD_C="${ESC}[38;5;114m"
GOOD_BOLD="${ESC}[38;5;114;1m"
WARN_C="${ESC}[38;5;214m"
WARN_BOLD="${ESC}[38;5;214;1m"
ERR_C="${ESC}[38;5;197m"

# is_number / sanitize_str は lib-dock-view.sh から供する（挙動不変・設計
# §1.4）。cols_now / rows_now は lib の term_cols / term_rows への互換ラッパ
# として残す（既存の呼び出し箇所を書き換えないため・設計 §1.4）。
cols_now() { term_cols ""; }
rows_now() { term_rows "${CMUX_NEXT_ROWS:-}"; }

# コードポイント数ベースで幅 $2 に切り詰め、超過分は … を付ける
# （cmux-feed-watch.sh の truncate_str と同一実装）。
truncate_str() {
  local s="$1" w="$2"
  is_number "$w" || w=40
  [ "$w" -lt 1 ] && w=1
  jq -Rr --argjson w "$w" 'if (length) > $w then (.[0:($w-1)] + "…") else . end' <<<"$s" 2>/dev/null
}

# truncate_disp / truncate_plain / fm_extract / fm_field は lib から供する
# （名前・引数とも不変。fm_extract のみ stdin 版になったため、呼び出し
# 箇所を fm_extract <"$f" の形に直した＝設計 §1.4・§5.3）。

# status が許可リスト（カンマ区切り）に含まれるか判定する。
status_allowed() {
  local status="$1" allow="$2"
  [ -z "$status" ] && return 1
  case ",${allow}," in
    *",${status},"*) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 が実在する暦日の "YYYY-MM-DD" かどうかを判定する（Codexレビュー指摘・
# Minor対応: 桁数だけの形式チェックでは "9999-99-99" のような値がそのまま
# 通ってしまうため、BSD date で実際に解釈できることまで確認する）。
# BSD date -j -f は "2026-02-30" のような存在しない日付を黙って正規化して
# 成功してしまう（例: 2026-03-02 に丸められる）ため、単に成功/失敗を見る
# だけでは不十分。パース結果を同じ書式で出力し直し、入力と完全一致するか
# まで確認することで正規化を検出する（Codex再レビュー指摘・Minor対応）。
is_valid_date() {
  local normalized
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  normalized="$(TZ=UTC date -j -f '%Y-%m-%d' "$1" '+%Y-%m-%d' 2>/dev/null)" || return 1
  [ "$normalized" = "$1" ]
}

# frontmatter の next: が無い／空文字列のノートについて、同じノートの
# Tasks 節（lib-vault-tasks.sh の read_note 経由）から先頭未完タスク（状態が
# x でない最初のタスク。[/] を優先しない・記載順のまま）の本文を取り出す
# （FR-31・設計 §7）。Tasks 節が無い・未完タスクが無い・ノートが破損して
# いるときは何も出さず非0で返る（呼び出し側は従来どおり空のまま扱い、
# 表示側で (next未設定) になる）。ファイルの存在確認は呼び出し側
# （collect_entries）が既に済ませている（lib の契約＝設計 §1.4）。
derive_next_from_tasks() {
  local f="$1" ts
  ts="$(read_note "$f" 2>/dev/null)" || return 1
  printf '%s\n' "$ts" | awk -F '\t' '
    $1 == "T" && $2 != "x" { print $3; found = 1; exit }
    END { if (!found) exit 1 }
  '
}

# セクション1: Projects/*.md の frontmatter を走査し、status をグループ判定
# （A=稼働中＝進行系 / H=保留＝on-hold 系。completed/closed/status無しは対象外）。
# "グループ<TAB>sortkey<TAB>名前<TAB>next値" を A→H・各グループ内は更新日降順で
# 標準出力へ並べる（表示と --list の共通データ源）。mktemp 失敗時は非0。
collect_entries() {
  local projects_dir="$VAULT/Projects" f base fm status nextval
  local tmpfile sortkey grp derived

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/cmux-next-watch.XXXXXX" 2>/dev/null)"
  [ -n "$tmpfile" ] || return 1
  for f in "$projects_dir"/*.md; do
    [ -e "$f" ] || continue
    fm="$(fm_extract <"$f")" || continue
    [ -z "$fm" ] && continue
    status="$(fm_field "$fm" status)"
    if status_allowed "$status" "$STATUS_ALLOW"; then
      grp="A"
    elif status_allowed "$status" "$STATUS_HOLD"; then
      grp="H"
    else
      continue
    fi
    # base・nextval はここで（TSVへ書く前に）サニタイズする。ファイル名は
    # OS上は '/' とNUL以外なら任意バイトを含み得る（TAB・LFも許される）ため、
    # 表示直前ではなくレコード生成前に無害化しないと、TSVの行・フィールド
    # 境界そのものが壊れてしまう（Codexレビュー指摘・Major対応）。
    base="$(sanitize_str "$(basename "$f" .md)")"
    nextval="$(sanitize_str "$(fm_field "$fm" next)")"
    # FR-31: 手書きの next: が無い／空文字列のときだけ Tasks 節から導出する。
    # 導出値は15コードポイントに切り詰め（省略記号は付けない＝
    # truncate_plain）てからサニタイズする。read_note 内部の sanitize_lines
    # で既に制御文字は空白化済みだが、sanitize_str を通す位置は既存の
    # next: 値と揃え、二重に通しても無害（設計 §7）。
    if [ -z "$nextval" ]; then
      derived="$(derive_next_from_tasks "$f")"
      if [ -n "$derived" ]; then
        nextval="$(sanitize_str "$(truncate_plain "$derived" 15)")"
      fi
    fi
    sortkey="$(fm_field "$fm" updated)"
    is_valid_date "$sortkey" || sortkey="$(fm_field "$fm" date)"
    is_valid_date "$sortkey" || sortkey="0000-00-00"
    printf '%s\t%s\t%s\t%s\n' "$grp" "$sortkey" "$base" "$nextval" >>"$tmpfile"
  done
  sort -t "$(printf '\t')" -k1,1 -k2,2r "$tmpfile"
  rm -f "$tmpfile"
}

render_next() {
  local entries count_a count_h idx numw cur_grp
  local grp sortkey name nextraw name_disp name_len remw next_disp cols

  entries="$(collect_entries)"
  if [ $? -ne 0 ]; then
    printf '%s▶ 稼働中 ERR (mktemp failed)%s\n' "$ERR_C" "$RESET"
    return
  fi
  count_a="$(printf '%s\n' "$entries" | grep -c '^A' | tr -d ' ')"
  count_h="$(printf '%s\n' "$entries" | grep -c '^H' | tr -d ' ')"

  # 稼働中セクションの見出しは、対象0件（データ源が無いサブ機・単に該当ゼロの
  # 両方）でも常に出す（本人確定仕様: 意味のない非表示より「0件」の方が
  # データ源の有無に依らず状態を正しく伝える）。以降の一覧行は対象があれば
  # 続けて出す。
  printf '%s▶ 稼働中 (%d)%s\n' "$LBL_BOLD" "$count_a" "$RESET"
  cols="$(cols_now)"
  # グループが変わるタイミングで保留見出しを出す（A=稼働中は既に上で出力済み）。
  # 番号はセクションをまたいで通し（「Nextの11番」で保留組も参照可能）。
  # 番号は恒久ID ではなくその時点の表示順。AI 側の解決は --list を使う。
  # name・nextraw は tmpfile へ書く前に既にサニタイズ済み（collect_entries の
  # コメント参照）。ここでは切り詰めのみ行う。
  if [ -n "$entries" ]; then
    idx=0
    cur_grp="A"
    printf '%s\n' "$entries" | while IFS="$(printf '\t')" read -r grp sortkey name nextraw; do
      if [ "$grp" = "H" ] && [ "$cur_grp" != "H" ]; then
        printf '\n%s⏸ 保留 (%d)%s\n' "$DIM_BOLD" "$count_h" "$RESET"
        cur_grp="H"
      fi
      idx=$(( idx + 1 ))
      numw=${#idx}
      name_disp="$(truncate_plain "$name" 10)"
      name_len="$(jq -Rr 'length' <<<"$name_disp" 2>/dev/null)"
      is_number "$name_len" || name_len=10
      remw=$(( cols - numw - 1 - name_len - 1 ))
      [ "$remw" -lt 1 ] && remw=1
      if [ -z "$nextraw" ]; then
        next_disp="$(truncate_disp "(next未設定)" "$remw")"
        printf '%s%d%s %s%s%s %s%s%s\n' "$DIM" "$idx" "$RESET" "$LBL" "$name_disp" "$RESET" "$DIM" "$next_disp" "$RESET"
      else
        next_disp="$(truncate_disp "$nextraw" "$remw")"
        printf '%s%d%s %s%s%s %s%s%s\n' "$DIM" "$idx" "$RESET" "$LBL" "$name_disp" "$RESET" "$LBL" "$next_disp" "$RESET"
      fi
    done
  fi
  # 稼働中側だけでループが終わった（保留が0件）場合は、上のwhile内では保留
  # 見出しを出す機会が無いため、ここで0件見出しを補う。
  if [ "$count_h" -eq 0 ]; then
    printf '\n%s⏸ 保留 (0)%s\n' "$DIM_BOLD" "$RESET"
  fi
}

# 棚卸しレポート（vault-inventory）の最新ファイル（名前順＝日付ファイル名
# なので辞書順＝時系列順）から「要確認 N 件」を抽出する。見つかれば
# "count<TAB>M/D" を標準出力へ、抽出失敗時は何も出さず非0を返す。
# ファイル名が実在する暦日の YYYY-MM-DD.md 形式のものだけを候補にする
# （Codexレビュー指摘・Minor対応: `ls *.md | sort | tail -1` は日付形式でない
# .md ファイル（例 zzz.md）や "9999-99-99.md" のような桁数だけ合った偽日付
# が紛れ込むと誤って「最新」扱いしてしまうため、is_valid_date で実在の暦日
# であることまで確認してから辞書順比較する）。
inventory_status() {
  local f base latest="" latest_base="" count mmdd mm dd
  for f in "$INVENTORY_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"
    is_valid_date "$base" || continue
    # 固定長 YYYY-MM-DD なので文字列比較（辞書順）がそのまま時系列順になる
    if [ -z "$latest" ] || [ "$base" \> "$latest_base" ]; then
      latest="$f"
      latest_base="$base"
    fi
  done
  [ -n "$latest" ] || return 1
  count="$(grep -oE '要確認 [0-9]+ 件' "$latest" 2>/dev/null | head -n1 | grep -oE '[0-9]+')"
  is_number "$count" || return 1
  base="$(basename "$latest" .md)"
  mmdd="${base#*-}"
  mm="${mmdd%-*}"; dd="${mmdd#*-}"
  mm=$(( 10#$mm )); dd=$(( 10#$dd ))
  printf '%s\t%d/%d\n' "$count" "$mm" "$dd"
}

# 棚卸しの「データ源」の有無だけを判定する（実在する暦日ファイル名の最新
# レポートが1件でも見つかるか）。件数抽出（inventory_status）の成否とは
# 独立させる: ディレクトリごと無い／該当ファイルが無いサブ機ではデータ源
# 無しとして render_extbrain 側で行自体を出さないが、レポートファイルは
# あるのに「要確認 N件」パターン抽出だけ失敗した場合はデータ源有りとして
# 従来通り n/a を表示する（本人確定仕様: 判定はmachine-role等ではなくデータ
# 駆動）。
inventory_has_source() {
  local f base
  for f in "$INVENTORY_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"
    is_valid_date "$base" && return 0
  done
  return 1
}

# 週次メンテ（maintenance.sh）の死活状態を last-run.json の last_success_at
# （無ければ started_at）から判定する。見つかれば
# "ok_or_warn<TAB>表示テキスト" を標準出力へ、状態ファイルが無い／壊れて
# いる場合は何も出さず非0を返す（呼び出し側はこの行自体を省略する）。
maintenance_status() {
  local raw ts epoch now age_days mm dd disp
  [ -f "$MAINT_STATE_FILE" ] || return 1
  raw="$(jq -r '.last_success_at // empty' "$MAINT_STATE_FILE" 2>/dev/null)"
  [ -n "$raw" ] || raw="$(jq -r '.started_at // empty' "$MAINT_STATE_FILE" 2>/dev/null)"
  [ -n "$raw" ] || return 1
  ts="$raw"
  case "$ts" in *.*Z) ts="${ts%%.*}Z" ;; esac
  epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null)"
  is_number "$epoch" || return 1
  now="$(date '+%s')"
  age_days=$(( (now - epoch) / 86400 ))
  [ "$age_days" -lt 0 ] && age_days=0
  if [ "$age_days" -ge "$MAINT_STALE_DAYS" ]; then
    printf 'warn\t⚠%d日前\n' "$age_days"
  else
    disp="$(date -r "$epoch" '+%-m/%-d' 2>/dev/null)"
    [ -n "$disp" ] || disp="?"
    printf 'ok\t✅%s\n' "$disp"
  fi
}

# セクション2「外部脳」: 棚卸し件数・週次メンテ死活の2行（片方または両方が
# 取得できないときはその行を省略する）と、警告有無に応じたヘッダーを表示する。
# ブロック全体（ヘッダー含む）は、棚卸し・週次いずれのデータ源も実在しない
# 場合にのみ非表示にする（本人確定仕様: 判定は machine-role 等の役割判定では
# なくデータ駆動。データ源を一切持たないサブ機で「棚卸し n/a」等の意味の無い
# 表示が出ていた問題への対処）。片方でもデータ源があればブロックは出し、
# データ源が無い側の行だけを省略する。
render_extbrain() {
  local inv_out inv_count inv_date maint_out maint_kind maint_disp has_warn=0
  local inv_src=0 maint_src=0

  inventory_has_source && inv_src=1
  [ -f "$MAINT_STATE_FILE" ] && maint_src=1
  if [ "$inv_src" -eq 0 ] && [ "$maint_src" -eq 0 ]; then
    return
  fi

  inv_out="$(inventory_status)"
  maint_out="$(maintenance_status)"
  if [ -n "$maint_out" ]; then
    maint_kind="${maint_out%%$(printf '\t')*}"
    maint_disp="${maint_out#*$(printf '\t')}"
    [ "$maint_kind" = "warn" ] && has_warn=1
  fi
  if [ -n "$inv_out" ]; then
    inv_count="${inv_out%%$(printf '\t')*}"
    [ "$inv_count" -ge 1 ] 2>/dev/null && has_warn=1
  fi

  if [ "$has_warn" -eq 1 ]; then
    printf '%s⚠ 外部脳%s\n' "$WARN_BOLD" "$RESET"
  else
    printf '%s✅ 外部脳%s\n' "$GOOD_BOLD" "$RESET"
  fi

  if [ "$inv_src" -eq 1 ]; then
    if [ -n "$inv_out" ]; then
      inv_count="${inv_out%%$(printf '\t')*}"
      inv_date="${inv_out#*$(printf '\t')}"
      if [ "$inv_count" -ge 1 ] 2>/dev/null; then
        printf '%s棚卸し 要確認%s件 (%s)%s\n' "$WARN_C" "$inv_count" "$inv_date" "$RESET"
      else
        printf '%s棚卸し 要確認%s件 (%s)%s\n' "$GOOD_C" "$inv_count" "$inv_date" "$RESET"
      fi
    else
      printf '%s棚卸し n/a%s\n' "$DIM" "$RESET"
    fi
  fi

  if [ -n "$maint_out" ]; then
    if [ "$maint_kind" = "warn" ]; then
      printf '%s週次 %s%s\n' "$WARN_C" "$maint_disp" "$RESET"
    else
      printf '%s週次 %s%s\n' "$GOOD_C" "$maint_disp" "$RESET"
    fi
  fi
}

render() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '%snext ERR (jq not found)%s\n' "$ERR_C" "$RESET"
    return
  fi
  render_next
  printf '\n'
  render_extbrain
}

# フレームをペインの表示行数に収める（Dock の狭いペインでフレームが視界より
# 長いと、毎フレームのスクロールで過去フレームがスクロールバックに積み重なり
# 「同じ表示の繰り返し」に見える実害の対策＝2026-08-05 本人報告）。
# 高さ超過時はプロジェクト行を後ろから畳んで「…他N行」のdim行に置き換え、
# 外部脳セクションは常に残す。高さが取得できない（rows=0・非tty）/十分な
# ときは全文をそのまま出す＝ --once・既存テストの挙動は不変。
compose_frame() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '%snext ERR (jq not found)%s\n' "$ERR_C" "$RESET"
    return
  fi
  local rows avail next_out ext_out n_next n_ext total budget shown omitted
  next_out="$(render_next)"
  ext_out="$(render_extbrain)"
  n_next=$(printf '%s\n' "$next_out" | wc -l | tr -d ' ')
  n_ext=$(printf '%s\n' "$ext_out" | wc -l | tr -d ' ')
  total=$(( n_next + 1 + n_ext ))
  rows=$(rows_now)
  # 末尾の printf が frame 直後に改行を1つ足すため、収容判定は rows-1 行
  avail=$(( rows - 1 ))
  if [ "$rows" -lt 4 ] || [ "$total" -le "$avail" ]; then
    printf '%s\n\n%s\n' "$next_out" "$ext_out"
    return
  fi
  budget=$(( avail - n_ext - 1 ))
  if [ "$budget" -lt 2 ]; then
    # 極端に低いペイン: 先頭から入るだけ出す（外部脳ごと切れるのは許容）
    printf '%s\n\n%s\n' "$next_out" "$ext_out" | head -n "$avail"
    return
  fi
  shown=$(( budget - 1 ))
  omitted=$(( n_next - shown ))
  printf '%s\n' "$next_out" | head -n "$shown"
  printf '%s…他%d行%s\n' "$DIM" "$omitted" "$RESET"
  printf '\n%s\n' "$ext_out"
}

main() {
  if [ "${1:-}" = "--list" ]; then
    # AI/スクリプト用: 表示と同じ順序で「番号<TAB>正式プロジェクト名<TAB>next値
    # <TAB>区分（稼働中/保留）」を色なしで出力する。「Nextの2番」等の参照を
    # AI が解決するための正本。
    if ! command -v jq >/dev/null 2>&1; then
      printf 'ERR: jq not found\n' >&2
      exit 1
    fi
    collect_entries | awk -F '\t' 'NF {
      label = ($1 == "H") ? "保留" : "稼働中"
      printf "%d\t%s\t%s\t%s\n", NR, $3, $4, label
    }'
    return
  fi
  if [ "${1:-}" = "--once" ]; then
    compose_frame
    return
  fi
  # ペインのタイトルを名乗る（OSC 2）。手動起動したペインが「Terminal」の
  # ままで他ドック（Usage/System）と区別できない問題への対処（2026-08-05
  # 本人要望）。dock.json 起動時は title 指定と重複するが実害はない。
  printf '\033]2;Next\007'
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
    frame="$(compose_frame | sed "s/\$/${ESC}[K/")"
    printf '\033[?2026h\033[H%s\n\033[J\033[?2026l' "$frame"
    sleep "$INTERVAL"
  done
}

main "$@"
