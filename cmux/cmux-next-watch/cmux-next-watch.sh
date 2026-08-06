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

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# jq 抽出用の共通サニタイズフィルタ：cmux-feed-watch.sh と同じくコード
# ポイント単位で C0/C1 制御文字・DEL を空白化する（Vault ノートの next 値・
# ファイル名は任意文字列が端末に生で流れるため、エスケープシーケンス注入
# （ESC・CSI・OSC 等）をここで遮断する）。
# -Rr（行単位）ではなく -Rs（全入力を1つの文字列として slurp）を使う：
# ファイル名に万一 LF/TAB 等の制御文字が混入していても、行単位ではなく全体
# を1文字列として gsub することで確実に空白化する（Codexレビュー指摘・Major
# 対応）。入力は herestring ではなく printf|パイプで渡す（herestring は末尾
# に改行を1つ付与するため、slurpモードだとそれも文字列に含まれてしまい出力
# 末尾に余分な空白が付くため）。
sanitize_str() {
  printf '%s' "$1" | jq -Rsr 'gsub("[\u0001-\u001f\u007f-\u009f]"; " ")' 2>/dev/null
}

# 現在の端末幅（取得できなければ 40 桁固定＝Dockペインの想定幅）。
# cmux-feed-watch.sh の cols_now() と同一実装（/dev/tty を明示して制御端末へ
# 直接問い合わせる。パイプ経由の標準出力/標準エラー経由だと誤って80桁に
# フォールバックしてしまうことを実機確認済みのため）。
cols_now() {
  local sz c
  sz=$( { stty size </dev/tty; } 2>/dev/null )
  c="${sz#* }"
  is_number "$c" || c=40
  printf '%s' "$c"
}

# 現在の端末の表示行数。CMUX_NEXT_ROWS（検証・強制上書き用）が有効数値なら
# それを優先。取得できなければ 0（=クランプ無効）を返す。
rows_now() {
  local sz r
  if is_number "${CMUX_NEXT_ROWS:-}" && [ "${CMUX_NEXT_ROWS}" -gt 0 ]; then
    printf '%s' "$CMUX_NEXT_ROWS"
    return
  fi
  sz=$( { stty size </dev/tty; } 2>/dev/null )
  r="${sz%% *}"
  is_number "$r" || r=0
  printf '%s' "$r"
}

# コードポイント数ベースで幅 $2 に切り詰め、超過分は … を付ける
# （cmux-feed-watch.sh の truncate_str と同一実装）。
truncate_str() {
  local s="$1" w="$2"
  is_number "$w" || w=40
  [ "$w" -lt 1 ] && w=1
  jq -Rr --argjson w "$w" 'if (length) > $w then (.[0:($w-1)] + "…") else . end' <<<"$s" 2>/dev/null
}

# 表示幅（端末セル数）ベースで幅 $2 に切り詰め、超過分は … を付ける。
# 日本語・CJK・かな・全角記号・絵文字は2セル幅として数える（コードポイント
# 数ベースの truncate_str だと日本語27文字＝54セルが40桁ペインを素通りして
# 行が折り返す実害があった＝2026-08-05 本人報告）。幅判定は East Asian Width
# の主要レンジの近似（Hangul Jamo・CJK統合漢字周辺・ハングル・互換漢字・
# 全角形・絵文字ブロック・拡張漢字面）。
truncate_disp() {
  local s="$1" w="$2"
  is_number "$w" || w=40
  [ "$w" -lt 1 ] && w=1
  # jq は16進数リテラル非対応のため10進で書く（4352=U+1100, 4447=U+115F,
  # 11904=U+2E80, 42191=U+A4CF, 44032=U+AC00, 55203=U+D7A3, 63744=U+F900,
  # 64255=U+FAFF, 65072=U+FE30, 65103=U+FE4F, 65280=U+FF00, 65376=U+FF60,
  # 65504=U+FFE0, 65510=U+FFE6, 127744=U+1F300, 129791=U+1FAFF, 131072=U+20000）
  jq -Rr --argjson w "$w" '
    def cw: if . >= 4352 and ((. <= 4447)
      or (. >= 11904 and . <= 42191)
      or (. >= 44032 and . <= 55203)
      or (. >= 63744 and . <= 64255)
      or (. >= 65072 and . <= 65103)
      or (. >= 65280 and . <= 65376)
      or (. >= 65504 and . <= 65510)
      or (. >= 127744 and . <= 129791)
      or (. >= 131072)) then 2 else 1 end;
    (explode) as $cs
    | ($cs | map(cw)) as $ws
    | (reduce $ws[] as $x (0; . + $x)) as $total
    | if $total <= $w then .
      else
        (reduce range(0; $cs | length) as $i ({acc: 0, n: 0, stop: false};
          if .stop then .
          elif .acc + $ws[$i] <= ($w - 1) then {acc: (.acc + $ws[$i]), n: ($i + 1), stop: false}
          else {acc: .acc, n: .n, stop: true} end)) as $st
        | ($cs[0:$st.n] | implode) + "…"
      end' <<<"$s" 2>/dev/null
}

# コードポイント数ベースで幅 $2 に切り詰め（…は付けない・プロジェクト名の
# 固定幅ラベル用）。
truncate_plain() {
  local s="$1" w="$2"
  is_number "$w" || w=10
  [ "$w" -lt 0 ] && w=0
  jq -Rr --argjson w "$w" '.[0:$w]' <<<"$s" 2>/dev/null
}

# frontmatter ブロック（先頭行が "---" である場合の、1つ目と2つ目の "---"
# 行に挟まれた行）だけを抽出する。1行目が "---" でなければ何も出さない
# （本文中の next: 等を誤検出しないため、フェンス内のみに厳密に限定する）。
# 閉じフェンスが60行以内に見つからない場合は、それまでに読んだ行を「本文の
# 誤検出」として一切使わず、非0で終了する（found フラグ・Codexレビュー指摘・
# Major対応: 元実装は60行打ち切り時も exit ステータス0で終了し、本文の一部を
# frontmatter として誤って採用してしまっていた）。呼び出し側は終了ステータス
# を必ず確認すること（$(...) は失敗時も直前まで出力した行を返してしまう
# ため、空文字列チェックだけでは不十分）。
fm_extract() {
  local f="$1"
  awk '
    NR==1 { if ($0 != "---") { exit 1 } ; next }
    /^---$/ { found=1; exit 0 }
    NR>60 { exit 1 }
    { print }
    END { if (!found) exit 1 }
  ' "$f" 2>/dev/null
}

# frontmatter ブロック文字列 $1 から key "$2" の値を1つ取り出す（複数行
# キーの2件目以降は無視・grep -m1）。前後空白・前後が揃った引用符（"…" /
# '…'）を剥がす。
fm_field() {
  local block="$1" key="$2" raw val
  raw="$(printf '%s\n' "$block" | grep -m1 "^${key}:" | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]+\$//")"
  val="$raw"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

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

# セクション1: Projects/*.md の frontmatter を走査し、status をグループ判定
# （A=稼働中＝進行系 / H=保留＝on-hold 系。completed/closed/status無しは対象外）。
# "グループ<TAB>sortkey<TAB>名前<TAB>next値" を A→H・各グループ内は更新日降順で
# 標準出力へ並べる（表示と --list の共通データ源）。mktemp 失敗時は非0。
collect_entries() {
  local projects_dir="$VAULT/Projects" f base fm status nextval
  local tmpfile sortkey grp

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/cmux-next-watch.XXXXXX" 2>/dev/null)"
  [ -n "$tmpfile" ] || return 1
  for f in "$projects_dir"/*.md; do
    [ -e "$f" ] || continue
    fm="$(fm_extract "$f")" || continue
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
