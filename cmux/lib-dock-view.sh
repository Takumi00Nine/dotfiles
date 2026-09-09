# cmux Dock ペインの端末描画の共通部品（幅・高さ・切り詰め・サニタイズ・
# cmux 呼び出しのタイムアウト）。cmux-task-watch.sh（新規）と
# cmux-next-watch.sh（既存・互換ラッパ経由）の両方から source される
# （表示幅・切り詰めの実装差を構造的に作らないため）。単体では実行しない
# （関数定義のみ、副作用なし）。lib は環境変数を読まない。上書き値は
# 呼び出し側が引数で渡す（cmux-session-todo 設計 §1.4）。
#
# 使い方:
#   LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)/.."
#   . "$LIB_DIR/lib-dock-view.sh"

# $1 が非負整数（'' も含めて弾く）かどうかを判定する（既存
# cmux-next-watch.sh の is_number と同一挙動）。
is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# $1 を非負整数として正規化する。空・非数字（先頭の '-' を含む）は 0 に
# 丸める。truncate_disp／truncate_plain／term_cols／term_rows の内部専用
# ヘルパー（呼び出し側の外部契約には現れない）。
_normalize_uint() {
  local v="$1"
  case "$v" in
    -*) case "${v#-}" in ''|*[!0-9]*) v=0 ;; esac ;;
    ''|*[!0-9]*) v=0 ;;
  esac
  printf '%s' "$v"
}

# 表示幅（端末セル数）を数える。CJK・かな・全角記号・絵文字は2セル、他は
# 1セルとして数える。範囲表は既存 cmux-next-watch.sh の truncate_disp と
# 同一（cmux-session-todo 設計 §6.2＝既存と揃える）。入力は1行の文字列
# を想定する（複数行文字列を渡すと jq -R が行ごとに評価し、複数行出力に
# なるため呼び出し側は単一行の値だけを渡すこと＝既存 truncate_disp と
# 同じ前提）。
disp_width() {
  local s="$1"
  jq -Rr '
    def cw: if . >= 4352 and ((. <= 4447)
      or (. >= 11904 and . <= 42191)
      or (. >= 44032 and . <= 55203)
      or (. >= 63744 and . <= 64255)
      or (. >= 65072 and . <= 65103)
      or (. >= 65280 and . <= 65376)
      or (. >= 65504 and . <= 65510)
      or (. >= 127744 and . <= 129791)
      or (. >= 131072)) then 2 else 1 end;
    ([explode[] | cw] | add) // 0
  ' <<<"$s" 2>/dev/null
}

# 表示幅ベースで $2 セルに切り詰める。$2 <= 0 は空文字を返す（現行の
# 「最低1へ丸める」規則をやめた新契約＝設計 §1.4）。$2 >= 1 で超過時は
# 末尾を … にして全体を $2 セル以内へ収める。範囲表は disp_width と同一。
truncate_disp() {
  local s="$1" w
  w="$(_normalize_uint "$2")"
  if [ "$w" -le 0 ]; then
    printf ''
    return 0
  fi
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
      end
  ' <<<"$s" 2>/dev/null
}

# コードポイント数ベースで $2 に切り詰める（省略記号は付けない）。
# $2 <= 0 は空文字を返す。
truncate_plain() {
  local s="$1" n
  n="$(_normalize_uint "$2")"
  if [ "$n" -le 0 ]; then
    printf ''
    return 0
  fi
  jq -Rr --argjson w "$n" '.[0:$w]' <<<"$s" 2>/dev/null
}

# 端末の桁数。$1（上書き値）が正整数（1以上）ならそれをそのまま使う。
# 空・非数字・0 は上書き無しと同じ扱いで stty size </dev/tty へ問い合わせる。
# 取得できなければ 40。
term_cols() {
  local override="$1" sz c
  case "$override" in
    ''|*[!0-9]*|0) : ;;
    *) printf '%s' "$override"; return 0 ;;
  esac
  sz=$( { stty size </dev/tty; } 2>/dev/null )
  c="${sz#* }"
  is_number "$c" || c=40
  printf '%s' "$c"
}

# 端末の行数。$1（上書き値）が正整数（1以上）ならそれをそのまま使う。
# 空・非数字・0 は上書き無しと同じ扱いで stty size </dev/tty へ問い合わせる。
# 取得できなければ 0（＝クランプ無効）。
term_rows() {
  local override="$1" sz r
  case "$override" in
    ''|*[!0-9]*|0) : ;;
    *) printf '%s' "$override"; return 0 ;;
  esac
  sz=$( { stty size </dev/tty; } 2>/dev/null )
  r="${sz%% *}"
  is_number "$r" || r=0
  printf '%s' "$r"
}

# $1 を無害化する。既存 cmux-next-watch.sh の sanitize_str と同一挙動
# （gsub 版・jq -Rs）。互換のため挙動を変えない（設計 §1.4）。
sanitize_str() {
  printf '%s' "$1" | jq -Rsr 'gsub("[\u0001-\u001f\u007f-\u009f]"; " ")' 2>/dev/null
}

# stdin の各行を無害化して stdout へ出す。U+0000〜U+001F と U+007F〜U+009F
# を U+0020 へ置換する（U+0000 を含む）。-Rr（行単位）の explode/implode
# 版なので行構造を保つ（設計 §5.1）。jq が非0で終わったら非0を返す。
sanitize_lines() {
  jq -Rr '
    [explode[] | if (. <= 31) or (. >= 127 and . <= 159) then 32 else . end] | implode
  ' 2>/dev/null
}

# $1 を数値とみなし、空・非数字・0 なら $2（既定値）を返す。
sanitize_interval() {
  local v="$1" default="$2"
  case "$v" in
    ''|*[!0-9]*|0) printf '%s' "$default" ;;
    *) printf '%s' "$v" ;;
  esac
}

# "$@" をプロセスグループごと起動し、$1 秒でタイムアウトさせる
# （cmux-dock-guard.sh の run_with_timeout と同じ TERM→1秒猶予→KILL 方式。
# 実績のある実装をそのまま移す＝設計 §4.3）。返り値は cmd の終了コード。
# 打ち切られたときは非0。
#
# 満たす3性質（設計 §4.3・DT-2 で検査）:
#   ① 打ち切りが効く: ウォッチャー自身も set -m でプロセスグループ化する。
#      コマンド置換の中で普通に起動すると、孫の sleep が標準出力の fd を
#      握り続け、動作は正しいのにタイムアウト秒数ぶん毎回遅くなる。
#   ② 常駐が死なない: kill は「-$cmd_pid」「-$watcher_pid」という別々の
#      プロセスグループにだけ効かせ、呼び出し元（このシェル）を巻き込まない。
#   ③ 子孫が残らない: ウォッチャーとコマンドの両方をグループごと落とし、
#      ウォッチャーの sleep が孤児として残らないよう最後に wait する。
run_with_timeout() {
  local secs="$1"
  shift
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "-$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  [ "$had_monitor" = "1" ] || set +m
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -TERM "-$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return "$rc"
}
