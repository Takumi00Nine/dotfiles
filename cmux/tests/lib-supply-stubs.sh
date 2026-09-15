# P群フィクスチャ（供給側スタブ生成・cmux-session-todo 設計 §34.2）。
# `mk_stub_P<n> <出力先パス> [引数...]` が実行可能なスタブスクリプトを1本
# 書き出す。描画側のテストは CMUX_DOCK_SUPPLY_TASK／CMUX_DOCK_SUPPLY_PROJECT
# でそれを指す。テストから `. lib-supply-stubs.sh` して使う（関数定義のみ・
# 副作用なし）。
#
# 契約はフレーム（TSV・§29.2）だけを知る。ドメインデータは一切知らない。

TAB="$(printf '\t')"

# --- 正準フレーム（P-6・v3.5の入力をそのまま） -----------------------------

# Task枠の正準本体行（#V/Eを除く・記載順）を配列 _P6_TASK_LINES へ設定する。
_p6_task_lines() {
  _P6_TASK_LINES=(
    "H${TAB}▶${TAB}cmux-session-todo${TAB}${TAB}v2${TAB}1/3"
    "V${TAB}v1${TAB}✅${TAB}3/3"
    "V${TAB}v2${TAB}▶${TAB}1/3"
    "V${TAB}v3${TAB}・${TAB}0/4"
    "C${TAB}5${TAB}[x]${TAB}要件定義"
    "C${TAB}6${TAB}[/]${TAB}設計"
    "C${TAB}7${TAB}[ ]${TAB}実装"
    "X${TAB}2"
  )
}

# Project枠の正準本体行を配列 _P6_PROJ_LINES へ設定する。番号は $1 $2 $3
# （既定 5 6 7）で差し替えられる（AC-92の検査に使う）。
_p6_proj_lines() {
  local n1="${1:-5}" n2="${2:-6}" n3="${3:-7}"
  _P6_PROJ_LINES=(
    "P${TAB}${n1}${TAB}svwb-pilot-log${TAB}実データ照合を回す${TAB}稼働中"
    "P${TAB}${n2}${TAB}takumi009-ai-env${TAB}${TAB}稼働中"
    "P${TAB}${n3}${TAB}avatar-switch-plan${TAB}配布方式のたたき台を書く${TAB}保留"
    "B${TAB}棚卸し${TAB}warn${TAB}要確認15件 (8/5)"
    "B${TAB}週次${TAB}ok${TAB}✅8/5"
  )
}

# 行配列（#V/Eを除く本体行）から完全なフレーム文字列（#V・E込み）を組み立て
# stdout へ出す。$1=種別(Task/Project) $2=版名（既定cmux-dock-frame/1）
# 残りは行配列（配列名を渡さず値渡しにするため "$@" の3つ目以降を使う）。
_compose_frame() {
  local kind="$1" version="$2"
  shift 2
  local n=$#
  printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
  local l
  for l in "$@"; do printf '%s\n' "$l"; done
  printf 'E%s%d\n' "$TAB" "$n"
}

# --- スタブ書き出しの共通部品 ----------------------------------------------

# $1=スタブ本体のパス。data(隣接ファイル $1.data)をそのまま cat するだけの
# 実行可能スクリプトを作る（静的なフレームを返すP群向け）。
_write_cat_stub() {
  local path="$1" data_path="${1}.data"
  cat > "$path" <<STUBEOF
#!/bin/bash
cat "$data_path"
STUBEOF
  chmod +x "$path"
}

# $1=スタブパス $2=渡す本文（stdinから受けてそのままファイルへ書く）
_write_frame_stub() {
  local path="$1"
  cat > "${path}.data"
  _write_cat_stub "$path"
}

# --- 足跡（P-3/P-16/P-20a/b/c/P-26・v2 hang_pids と同型・§34.2） -----------

# 足跡を書く共通の前置きコード（本体PID・子1本・watchdog名義の子1本の
# 3種）。生成するスタブのスクリプト本文へ埋め込む断片を stdout へ出す。
#   $1 = 足跡ファイルの絶対パス
_footprint_prelude() {
  local fp="$1"
  cat <<PRELUDE
FP="$fp"
: > "\$FP"
MYPGID="\$(ps -o pgid= -p \$\$ 2>/dev/null | tr -d ' ')"
printf 'main\t%s\t%s\n' "\$\$" "\$MYPGID" >> "\$FP"
sleep 9999 &
CPID=\$!
CPGID="\$(ps -o pgid= -p \$CPID 2>/dev/null | tr -d ' ')"
printf 'child\t%s\t%s\n' "\$CPID" "\$CPGID" >> "\$FP"
sleep 9999 &
WPID=\$!
WPGID="\$(ps -o pgid= -p \$WPID 2>/dev/null | tr -d ' ')"
printf 'watchdog\t%s\t%s\n' "\$WPID" "\$WPGID" >> "\$FP"
PRELUDE
}

# --- P-1: 呼び出し口が使えない ----------------------------------------------

mk_stub_P1a() {  # $1=パス（あえて作らない）
  rm -f -- "$1" "${1}.data" 2>/dev/null
}
mk_stub_P1b() {  # $1=パス（作るが実行不可）
  printf '#!/bin/bash\nexit 1\n' > "$1"
  chmod 0644 "$1"
}

# --- P-2: rc!=0・stdout空 ---------------------------------------------------

mk_stub_P2() {
  cat > "$1" <<'STUBEOF'
#!/bin/bash
exit 3
STUBEOF
  chmod +x "$1"
}

# --- P-3: ハング（足跡付き） -------------------------------------------------

mk_stub_P3() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    echo 'wait'
  } > "$1"
  chmod +x "$1"
}

# --- P-4: 版が未知 -----------------------------------------------------------

mk_stub_P4() {  # $1=パス $2=種別(Task/Project、既定Task)
  local kind="${2:-Task}"
  { printf '#V%sunknown-version-9%s%s\n' "$TAB" "$TAB" "$kind"
    printf 'R%s未宣言\n' "$TAB"
    printf 'E%s1\n' "$TAB"
  } | _write_frame_stub "$1"
}

# --- P-5: 版は合うが途中で切れている -----------------------------------------

mk_stub_P5_row() {  # $1=パス（行の途中で切れる）
  _p6_task_lines
  { printf '#V%scmux-dock-frame/1%sTask\n' "$TAB" "$TAB"
    printf '%s\n' "${_P6_TASK_LINES[@]}"
    printf 'C%s8' "$TAB"   # E行なし・最終行が閉じていない
  } | _write_frame_stub "$1"
}
mk_stub_P5_field() {  # $1=パス（欄の途中で切れる）
  { printf '#V%scmux-dock-frame/1%sTask\n' "$TAB" "$TAB"
    printf 'H%s▶%scmux-session' "$TAB" "$TAB"   # フィールドの途中で切断
  } | _write_frame_stub "$1"
}

# --- P-6: 正常フレーム -------------------------------------------------------

mk_stub_P6_task() {  # $1=パス
  _p6_task_lines
  _compose_frame "Task" "cmux-dock-frame/1" "${_P6_TASK_LINES[@]}" | _write_frame_stub "$1"
}
mk_stub_P6_project() {  # $1=パス [n1 n2 n3]
  _p6_proj_lines "$2" "$3" "$4"
  _compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$1"
}

# --- P-15: rc=0・0バイト -----------------------------------------------------

mk_stub_P15() {
  cat > "$1" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
  chmod +x "$1"
}

# --- P-16: 接頭部の後にハング（足跡付き） ------------------------------------

mk_stub_P16() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    printf 'printf %s\n' "'#V${TAB}cmux-dock-frame/1${TAB}Task\nH${TAB}▶${TAB}cmux-session-todo${TAB}${TAB}v2${TAB}1/3\n'"
    echo 'wait'
  } > "$1"
  chmod +x "$1"
}

# --- P-20: 終わりなく出し続ける（足跡付き） ----------------------------------

# P-20a: 長い行(4096バイト)を少数出す（バイト上限が先）
mk_stub_P20a() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    cat <<'BODY'
printf '#V\tcmux-dock-frame/1\tTask\n'
i=0
PAYLOAD="$(printf 'a%.0s' $(seq 1 4090))"
while :; do
  i=$((i+1))
  printf 'C\t%d\t[ ]\t%s\n' "$i" "$PAYLOAD"
  if [ "$i" -eq 17 ]; then
    date +%s.%N > "$FP.limit"
  fi
done
BODY
  } > "$1"
  chmod +x "$1"
}

# P-20b: 短い行(8バイト行 "C\t1\t \tX\n" 相当)を多数出す（行上限が先）
mk_stub_P20b() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    cat <<'BODY'
i=0
while :; do
  i=$((i+1))
  printf 'C\ta\n'
  if [ "$i" -eq 1001 ]; then
    date +%s.%N > "$FP.limit"
  fi
done
BODY
  } > "$1"
  chmod +x "$1"
}

# P-20c: P-20aと同じ出力だがSIGPIPEを無視する
mk_stub_P20c() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    echo "trap '' PIPE"
    _footprint_prelude "$2"
    cat <<'BODY'
i=0
PAYLOAD="$(printf 'a%.0s' $(seq 1 4090))"
while :; do
  i=$((i+1))
  printf 'C\t%d\t[ ]\t%s\n' "$i" "$PAYLOAD" 2>/dev/null
  if [ "$i" -eq 17 ]; then
    date +%s.%N > "$FP.limit"
  fi
done
BODY
  } > "$1"
  chmod +x "$1"
}

# --- P-21/P-22: 遅延して正常終了 --------------------------------------------

mk_stub_P21() {  # $1=パス $2=種別 $3=秒(既定2)
  local kind="${2:-Task}" secs="${3:-2}"
  if [ "$kind" = "Project" ]; then
    _p6_proj_lines
    { echo "sleep $secs"; _compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}"; } > "${1}.gen"
  else
    _p6_task_lines
    { echo "sleep $secs"; _compose_frame "Task" "cmux-dock-frame/1" "${_P6_TASK_LINES[@]}"; } > "${1}.gen"
  fi
  {
    echo '#!/bin/bash'
    printf 'sleep %s\n' "$secs"
    tail -n +2 "${1}.gen" | sed "s/^/printf '%s\\\\n' '/;s/\$/'/"
  } > "$1"
  chmod +x "$1"
  rm -f -- "${1}.gen"
}
mk_stub_P22() {  # $1=パス $2=種別
  mk_stub_P21 "$1" "${2:-Task}" 7
}

# --- P-23/P-24: 直和型の陽性境界 --------------------------------------------

mk_stub_P23() {  # $1=パス（全版完了）
  local lines=(
    "H${TAB}✅${TAB}cmux-session-todo${TAB}全版完了${TAB}${TAB}2/2"
    "V${TAB}v1${TAB}✅${TAB}2/2"
    "V${TAB}v2${TAB}✅${TAB}1/1"
    "X${TAB}-"
  )
  _compose_frame "Task" "cmux-dock-frame/1" "${lines[@]}" | _write_frame_stub "$1"
}
mk_stub_P24() {  # $1=パス（[/]無し・未完版を展開）
  local lines=(
    "H${TAB}・${TAB}cmux-session-todo${TAB}次: ${TAB}v1${TAB}0/2"
    "V${TAB}v1${TAB}・${TAB}0/2"
    "C${TAB}1${TAB}[ ]${TAB}task a"
    "C${TAB}2${TAB}[ ]${TAB}task b"
    "X${TAB}1"
  )
  _compose_frame "Task" "cmux-dock-frame/1" "${lines[@]}" | _write_frame_stub "$1"
}

# --- P-25: 上限ちょうど ------------------------------------------------------

# P-25a: 合計ちょうど65536バイト（Taskの最後のC行本文で調整）
mk_stub_P25a() {  # $1=パス
  _p6_task_lines
  # まず本文なしで組み立ててファイルへ書き、実バイト数を測ってから不足分を
  # C行の本文へ足す（コマンド置換 $(...) は末尾改行を削るので、それで測ると
  # 1バイトずれる＝実ファイルのバイト数で測る）。
  local base_file base_bytes pad_n
  base_file="${1}.base"
  _compose_frame "Task" "cmux-dock-frame/1" "${_P6_TASK_LINES[@]}" > "$base_file"
  base_bytes=$(wc -c < "$base_file" | tr -d ' ')
  rm -f -- "$base_file"
  pad_n=$(( 65536 - base_bytes ))
  [ "$pad_n" -lt 0 ] && pad_n=0
  local pad
  if [ "$pad_n" -gt 0 ]; then
    pad="$(printf 'a%.0s' $(seq 1 "$pad_n"))"
  else
    pad=""
  fi
  _P6_TASK_LINES[6]="${_P6_TASK_LINES[6]}${pad}"   # 最後のC行(実装)の末尾へ足す
  _compose_frame "Task" "cmux-dock-frame/1" "${_P6_TASK_LINES[@]}" | _write_frame_stub "$1"
}

# P-25b: ちょうど1000行（#V+H+V+C*995+X+E=1000）。[/]を持つC行が1つも無い
# ので、記号は展開時の規則(FR-82#12-A⑤)どおり「・」＋先導語「次: 」にする。
mk_stub_P25b() {  # $1=パス
  local lines=("H${TAB}・${TAB}cmux-session-todo${TAB}次: ${TAB}v1${TAB}0/995"
               "V${TAB}v1${TAB}・${TAB}0/995")
  local i
  for ((i = 1; i <= 995; i++)); do
    lines+=("C${TAB}${i}${TAB}[ ]${TAB}t${i}")
  done
  lines+=("X${TAB}1")
  _compose_frame "Task" "cmux-dock-frame/1" "${lines[@]}" | _write_frame_stub "$1"
}

# --- P-26: 終了経路の検査用（足跡付き） --------------------------------------

mk_stub_P26a() {  # $1=パス $2=足跡ファイル $3=種別
  local kind="${3:-Task}"
  local frame
  if [ "$kind" = "Project" ]; then
    _p6_proj_lines
    frame="$(_compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}")"
  else
    _p6_task_lines
    frame="$(_compose_frame "Task" "cmux-dock-frame/1" "${_P6_TASK_LINES[@]}")"
  fi
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    printf 'cat <<'"'"'FRAMEEOF'"'"'\n%s\nFRAMEEOF\n' "$frame"
  } > "$1"
  chmod +x "$1"
}
mk_stub_P26b() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    echo 'exit 5'
  } > "$1"
  chmod +x "$1"
}

# --- 45サブID（FR-82の契約違反・設計 §29.4） --------------------------------

# 正準Task本体行（配列コピー）を取り、$1番目（0始まり）を $2 へ差し替えて
# 返す（グローバル配列 _MUT を更新）。$2 が "DELETE" ならその行を削る。
_mutate_task() {
  _p6_task_lines
  _MUT=("${_P6_TASK_LINES[@]}")
  local idx="$1" val="$2"
  if [ "$val" = "DELETE" ]; then
    unset '_MUT[idx]'
    _MUT=("${_MUT[@]}")
  else
    _MUT[$idx]="$val"
  fi
}

# 45サブIDのうち Task 側で構成できるものを1関数で扱う（表引き）。
# $1=パス $2=サブID
mk_stub_P_violation() {
  local path="$1" id="$2"
  local version="cmux-dock-frame/1" kind="Task"
  _p6_task_lines
  local body=("${_P6_TASK_LINES[@]}")

  case "$id" in
    P-7a)  # 版宣言が0個
      { printf '%s\n' "${body[@]}"; printf 'E%s8\n' "$TAB"; } | _write_frame_stub "$path"; return ;;
    P-7b)  # 版宣言が2個
      { printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '%s\n' "${body[@]}"
        printf 'E%s8\n' "$TAB"
      } | _write_frame_stub "$path"; return ;;
    P-7c)  # 版宣言が先頭にない
      { printf '%s\n' "${body[0]}"
        printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '%s\n' "${body[@]:1}"
        printf 'E%s8\n' "$TAB"
      } | _write_frame_stub "$path"; return ;;
    P-8a)  # 種別不一致（Taskを要求されるがProjectを名乗る）
      _compose_frame "Project" "$version" "${body[@]}" | _write_frame_stub "$path"; return ;;
    P-9a)  # 理由とデータ本体が同居
      { printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf 'R%s理由\n' "$TAB"
        printf '%s\n' "${body[@]}"
        printf 'E%s9\n' "$TAB"
      } | _write_frame_stub "$path"; return ;;
    P-9b)  # どちらも無い
      { printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf 'E%s0\n' "$TAB"
      } | _write_frame_stub "$path"; return ;;
    P-10a) # フレームが2つ連なる
      { _compose_frame "$kind" "$version" "${body[@]}"
        _compose_frame "$kind" "$version" "${body[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-10b) # 終端の後に余分なバイト
      { _compose_frame "$kind" "$version" "${body[@]}"
        printf 'GARBAGE\n'
      } | _write_frame_stub "$path"; return ;;
    P-11a) # 必須欄が欠ける（H行の欄を1つ削る）
      _mutate_task 0 "H${TAB}▶${TAB}cmux-session-todo${TAB}${TAB}v2"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-11b) # 未定義の欄がある（H行に欄を1つ足す）
      _mutate_task 0 "H${TAB}▶${TAB}cmux-session-todo${TAB}${TAB}v2${TAB}1/3${TAB}extra"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-11c) # 未定義の行種別がある
      _mutate_task 4 "Z${TAB}5${TAB}[x]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-12a) # 状態が[?]
      _mutate_task 4 "C${TAB}5${TAB}[?]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-12b) # 区分が完了（Project）
      _p6_proj_lines
      _P6_PROJ_LINES[0]="P${TAB}5${TAB}svwb-pilot-log${TAB}実データ照合を回す${TAB}完了"
      _compose_frame "Project" "$version" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    P-12c) # ヘルスの種別が未定義値（Project）
      _p6_proj_lines
      _P6_PROJ_LINES[3]="B${TAB}未定義${TAB}warn${TAB}x"
      _compose_frame "Project" "$version" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    P-13a) # 番号が重複
      _mutate_task 5 "C${TAB}5${TAB}[/]${TAB}設計"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13b) # 番号が0
      _mutate_task 4 "C${TAB}0${TAB}[x]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13c) # 番号が負数
      _mutate_task 4 "C${TAB}-1${TAB}[x]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13d) # 番号が非数字
      _mutate_task 4 "C${TAB}abc${TAB}[x]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13e) # 9999超
      _mutate_task 4 "C${TAB}10000${TAB}[x]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13f) # 記載順に減る
      _mutate_task 5 "C${TAB}4${TAB}[/]${TAB}設計"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14a) # 自己申告の行数と実行数が違う
      { _compose_frame "$kind" "$version" "${body[@]}" | sed '$ s/.*/E\t99/'; } | _write_frame_stub "$path"; return ;;
    P-14b) # サブIDとしての代表変種（孤立継続バイト）。他の変種は
           # SUPPLY_VIOLATION_VARIANTS 経由で個別に生成できる。
      mk_stub_P_violation "$path" "P-14b-lone"; return ;;
    P-14c) # サブIDとしての代表変種（ESC）
      mk_stub_P_violation "$path" "P-14c-esc"; return ;;
    P-14b-lone) # 孤立継続バイト
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\x80b' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-overlong) # 過長形式
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\xc0\x80b' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-surrogate) # サロゲート
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\xed\xa0\x80b' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-over10ffff) # U+10FFFF超
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\xf4\x90\x80\x80b' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-trunc) # 途中切れ（先頭バイトのみ）
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\xe2' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-esc) # データ欄にESC
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\x1bb' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-del) # データ欄にDEL
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\x7fb' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-c1) # データ欄にC1(U+0080)
      _mutate_task 4 "$(printf 'C%s5%s[x]%sa\xc2\x80b' "$TAB" "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-nul) # 欄の末尾にNUL（NULはbash変数/コマンド置換を経由すると失われる
               # ため、この1件だけはファイルへ直接バイトを書く）
      {
        printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '%s\n' "${body[0]}" "${body[1]}" "${body[2]}" "${body[3]}"
        printf 'C%s5%s[x]%sa\x00' "$TAB" "$TAB" "$TAB"
        printf '\n'
        printf '%s\n' "${body[5]}" "${body[6]}" "${body[7]}"
        printf 'E%s8\n' "$TAB"
      } > "${path}.data"
      _write_cat_stub "$path"; return ;;
    P-17a) # 理由にESC
      { printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf 'R%s\n' "$TAB"
        printf 'E%s1\n' "$TAB"
      } > "${path}.tmp"
      # 理由本文へESCを直接埋め込む（printf経由だと解釈されるためsedで挿入）
      awk -v tab="$TAB" 'NR==2{printf "R%s理由\x1bテスト\n", tab; next} {print}' "${path}.tmp" > "${path}.data"
      rm -f -- "${path}.tmp"
      _write_cat_stub "$path"; return ;;
    P-17b) # 理由にLF相当（欄内には現れ得ないため、TAB混入で模擬しない。
           # ここでは理由文字列にLFを直接含めたレコード破壊として構成する）
      printf '#V%s%s%s%s\nR%s理由\nテスト\nE%s2\n' "$TAB" "$version" "$TAB" "$kind" "$TAB" "$TAB" > "${path}.data"
      _write_cat_stub "$path"; return ;;
    P-17c) # 理由にTAB
      printf '#V%s%s%s%s\nR%s理由%sテスト\nE%s1\n' "$TAB" "$version" "$TAB" "$kind" "$TAB" "$TAB" "$TAB" > "${path}.data"
      _write_cat_stub "$path"; return ;;
    P-17d) # 理由にU+0080
      printf '#V%s%s%s%s\nR%s理由\xc2\x80テスト\nE%s1\n' "$TAB" "$version" "$TAB" "$kind" "$TAB" "$TAB" > "${path}.data"
      _write_cat_stub "$path"; return ;;
    P-17e) # 理由にU+009F
      printf '#V%s%s%s%s\nR%s理由\xc2\x9fテスト\nE%s1\n' "$TAB" "$version" "$TAB" "$kind" "$TAB" "$TAB" > "${path}.data"
      _write_cat_stub "$path"; return ;;
    P-18a) # 分数の形式不正
      _mutate_task 1 "V${TAB}v1${TAB}✅${TAB}1-3"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18b) # d>t
      _mutate_task 1 "V${TAB}v1${TAB}✅${TAB}4/3"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18c) # ヘッダーの版名・分数が展開対象と違う
      _mutate_task 0 "H${TAB}▶${TAB}cmux-session-todo${TAB}${TAB}vX${TAB}9/9"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18d) # 子行の行数が展開対象のtと違う（Cを1行削り、tはv2の1のまま）
      _p6_task_lines
      _MUT=("${_P6_TASK_LINES[@]}")
      unset '_MUT[6]'; _MUT=("${_MUT[@]}")
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14d) # 65537バイト（バイト上限）＝P-20aと同じ構成をそのまま使う
      mk_stub_P20a "$path" "${path}.footprints"; return ;;
    P-14e) # 1001行（行上限）＝P-20bと同じ構成をそのまま使う
      mk_stub_P20b "$path" "${path}.footprints"; return ;;
    P-18e) # 子行の[x]数がdと違う
      _mutate_task 4 "C${TAB}5${TAB}[ ]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18f) # 展開対象の記号が[/]有無と矛盾（[/]があるのに・）
      _p6_task_lines
      _MUT=("${_P6_TASK_LINES[@]}")
      _MUT[2]="V${TAB}v2${TAB}・${TAB}1/3"
      _MUT[0]="H${TAB}・${TAB}cmux-session-todo${TAB}次: ${TAB}v2${TAB}1/3"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18g) # 全版完了なのに子行がある
      { local l=("H${TAB}✅${TAB}p${TAB}全版完了${TAB}${TAB}1/1" "V${TAB}v1${TAB}✅${TAB}1/1" "C${TAB}1${TAB}[x]${TAB}a" "X${TAB}-")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18h) # 展開ありでヘッダー記号・先導語が矛盾
      _p6_task_lines
      _MUT=("${_P6_TASK_LINES[@]}")
      _MUT[0]="H${TAB}・${TAB}cmux-session-todo${TAB}次: ${TAB}v2${TAB}1/3"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18i) # 版行の記号が分数と矛盾（t==0なのに✅）
      { local l=("H${TAB}✅${TAB}p${TAB}全版完了${TAB}${TAB}1/1" "V${TAB}v1${TAB}✅${TAB}0/0" "X${TAB}-")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18j) # 展開対象の版行がt==0
      { local l=("H${TAB}・${TAB}p${TAB}次: ${TAB}v1${TAB}0/0" "V${TAB}v1${TAB}・${TAB}0/0" "X${TAB}1")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18k) # 展開対象の版行がd==t
      { local l=("H${TAB}▶${TAB}p${TAB}${TAB}v1${TAB}2/2" "V${TAB}v1${TAB}✅${TAB}2/2" "C${TAB}1${TAB}[x]${TAB}a" "C${TAB}2${TAB}[x]${TAB}b" "X${TAB}1")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18l) # [/]が無いのに展開対象の記号が▶
      _p6_task_lines
      _MUT=("${_P6_TASK_LINES[@]}")
      _MUT[5]="C${TAB}6${TAB}[ ]${TAB}設計"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18m) # 全版完了なのに版行が0件
      { local l=("H${TAB}✅${TAB}p${TAB}全版完了${TAB}${TAB}0/0" "X${TAB}-")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-19a) # ヘルス行の種別が重複（Project）
      _p6_proj_lines
      _P6_PROJ_LINES+=("B${TAB}棚卸し${TAB}ok${TAB}dup")
      _compose_frame "Project" "$version" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    P-19b) # 区分の並びが混ざる（Project・保留の後に稼働中が来る）
      _p6_proj_lines
      _P6_PROJ_LINES[0]="P${TAB}5${TAB}svwb-pilot-log${TAB}実データ照合を回す${TAB}保留"
      _compose_frame "Project" "$version" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    *)
      echo "mk_stub_P_violation: 未知のサブID: $id" >&2
      return 1
      ;;
  esac
}

# 45サブIDの完全な集合（AC-111の突合対象）。P-14b・P-14cはそれぞれ内部に
# 5変種・4変種を持つが、サブIDとしては1つのまま数える（設計 §29.4・
# AC-111の「45サブIDの集合」を増やさない）。変種ごとの実装は下の
# SUPPLY_VIOLATION_VARIANTS で別途網羅する。
SUPPLY_VIOLATION_IDS=(
  P-7a P-7b P-7c
  P-8a
  P-9a P-9b
  P-10a P-10b
  P-11a P-11b P-11c
  P-12a P-12b P-12c
  P-13a P-13b P-13c P-13d P-13e P-13f
  P-14a P-14b P-14c P-14d P-14e
  P-17a P-17b P-17c P-17d P-17e
  P-18a P-18b P-18c P-18d P-18e P-18f P-18g P-18h P-18i P-18j P-18k P-18l P-18m
  P-19a P-19b
)

# P-14b・P-14cの内側の変種（サブIDの集合には数えないが、状態機械の全分岐を
# 網羅するために個別に生成できるようにする＝§29.4のUTF-8状態機械表）。
SUPPLY_VIOLATION_VARIANTS=(
  P-14b-lone P-14b-overlong P-14b-surrogate P-14b-over10ffff P-14b-trunc
  P-14c-esc P-14c-del P-14c-c1 P-14c-nul
)
