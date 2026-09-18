# P群フィクスチャ（供給側スタブ生成・cmux-session-todo 設計 §34.2）。
# `mk_stub_P<n> <出力先パス> [引数...]` が実行可能なスタブスクリプトを1本
# 書き出す。描画側のテストは CMUX_DOCK_SUPPLY_TASK／CMUX_DOCK_SUPPLY_PROJECT
# でそれを指す。テストから `. lib-supply-stubs.sh` して使う（関数定義のみ・
# 副作用なし）。
#
# 契約はフレーム（TSV・§29.2）だけを知る。ドメインデータは一切知らない。

TAB="$(printf '\t')"

# --- 正準フレーム（P-6′・v4 §39.3の入力） -----------------------------------

# Task枠の正準本体行（#V/Eを除く・記載順・v4行文法）を配列 _P6_TASK_LINES
# へ設定する。$1 $2 = 版番号の上書き（既定 1 2＝AC-86′）。
_p6_task_lines() {
  local n1="${1:-1}" n2="${2:-2}"
  _P6_TASK_LINES=(
    "V${TAB}${n1}${TAB}v2${TAB}1/3${TAB}cur${TAB}open"
    "C${TAB}[x]${TAB}要件定義"
    "C${TAB}[/]${TAB}設計"
    "C${TAB}[ ]${TAB}実装"
    "V${TAB}${n2}${TAB}v3${TAB}0/4${TAB}-${TAB}fold"
    "D${TAB}1"
  )
}

# P-6′の--list応答（5列TSV・v4 §39.4.6。foldのv3の子行4つも出る＝
# ai-env V-1のAC-129リテラルと同一）を stdout へ7行で出す。$1 $2=版番号の
# 上書き（_p6_task_linesと同じ既定1 2）。AC-90′①(RT)専用（検証1巡目#2）。
_p6_task_list() {
  local n1="${1:-1}" n2="${2:-2}"
  printf '%s\n' \
    "${n1}${TAB}v2${TAB}1/3${TAB}[x]${TAB}要件定義" \
    "${n1}${TAB}v2${TAB}1/3${TAB}[/]${TAB}設計" \
    "${n1}${TAB}v2${TAB}1/3${TAB}[ ]${TAB}実装" \
    "${n2}${TAB}v3${TAB}0/4${TAB}[ ]${TAB}t1" \
    "${n2}${TAB}v3${TAB}0/4${TAB}[ ]${TAB}t2" \
    "${n2}${TAB}v3${TAB}0/4${TAB}[ ]${TAB}t3" \
    "${n2}${TAB}v3${TAB}0/4${TAB}[ ]${TAB}t4"
}

# P-28（V-15′相当）の--list応答を stdout へ12行で出す（番号は常に1・
# openの版なのでC行の記載順とそのまま一致＝ai-env V-15のAC-63′リテラルと
# 同一）。AC-90′②(RT)専用（検証1巡目#2）。
_p28_list() {
  local lines=() i
  for ((i = 1; i <= 5; i++)); do lines+=("1${TAB}v2${TAB}5/12${TAB}[x]${TAB}t${i}"); done
  for ((i = 6; i <= 10; i++)); do lines+=("1${TAB}v2${TAB}5/12${TAB}[ ]${TAB}t${i}"); done
  lines+=("1${TAB}v2${TAB}5/12${TAB}[/]${TAB}t11" "1${TAB}v2${TAB}5/12${TAB}[ ]${TAB}t12")
  printf '%s\n' "${lines[@]}"
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

# $1=スタブパス $2=--list応答本文（複数行文字列）。stdinは_write_frame_stub
# と同じくframe本文。生成したスタブは引数$1が"--list"のときだけ$2を返し、
# それ以外（無引数・--frame等）は従来どおりframe本文を返す。dotfiles本番
# コードはCMUX_DOCK_SUPPLY_TASKを--frameでしか呼ばない（run_supply）ので、
# --listはテストがスタブへ直接渡してAC-90′①②(RT)の画面との突合に使う
# （検証1巡目#2＝§39.4.6のリテラルをP-6′/P-28スタブに持たせる）。
_write_frame_stub_with_list() {
  local path="$1" list_text="$2" data_path="${1}.data" list_path="${1}.list.data"
  cat > "$data_path"
  printf '%s\n' "$list_text" > "$list_path"
  cat > "$path" <<STUBEOF
#!/bin/bash
if [ "\$1" = "--list" ]; then
  cat "$list_path"
else
  cat "$data_path"
fi
STUBEOF
  chmod +x "$path"
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
  { printf '#V%scmux-dock-frame/2%sTask\n' "$TAB" "$TAB"
    printf '%s\n' "${_P6_TASK_LINES[@]}"
    printf 'E%s' "$TAB"   # E行が値も改行も無いまま切れる
  } | _write_frame_stub "$1"
}
mk_stub_P5_field() {  # $1=パス（欄の途中で切れる）
  { printf '#V%scmux-dock-frame/2%sTa' "$TAB" "$TAB"   # フィールドの途中で切断
  } | _write_frame_stub "$1"
}

# --- P-6: 正常フレーム -------------------------------------------------------

mk_stub_P6_task() {  # $1=パス [n1] [n2]（版番号の上書き・既定1 2＝AC-86′）
  local n1="${2:-1}" n2="${3:-2}"
  _p6_task_lines "$n1" "$n2"
  _compose_frame "Task" "cmux-dock-frame/2" "${_P6_TASK_LINES[@]}" |
    _write_frame_stub_with_list "$1" "$(_p6_task_list "$n1" "$n2")"
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
    printf 'printf %s\n' "'#V${TAB}cmux-dock-frame/2${TAB}Task\nV${TAB}1${TAB}v2${TAB}1/3${TAB}cur${TAB}open\n'"
    echo 'wait'
  } > "$1"
  chmod +x "$1"
}

# --- P-20: 終わりなく出し続ける（足跡付き） ----------------------------------

# P-20a: 長い行(4096バイト相当)を少数出す（バイト上限が先）
mk_stub_P20a() {  # $1=パス $2=足跡ファイル
  {
    echo '#!/bin/bash'
    _footprint_prelude "$2"
    cat <<'BODY'
printf '#V\tcmux-dock-frame/2\tTask\n'
i=0
PAYLOAD="$(printf 'a%.0s' $(seq 1 4090))"
while :; do
  i=$((i+1))
  printf 'C\t[ ]\t%s\n' "$PAYLOAD"
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
  printf 'C\t[ ]\t%s\n' "$PAYLOAD" 2>/dev/null
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
    { echo "sleep $secs"; _compose_frame "Task" "cmux-dock-frame/2" "${_P6_TASK_LINES[@]}"; } > "${1}.gen"
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

# --- P-23′/P-24′: 直和型の陽性境界（v4） ------------------------------------

mk_stub_P23() {  # $1=パス（全版完了＝V0行・D3・E1）
  local lines=("D${TAB}3")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
}
mk_stub_P24() {  # $1=パス（cur・fold 1版0/3 ＋ -・fold 2版0/1・D0＝今の版が未着手）
  local lines=(
    "V${TAB}1${TAB}v1${TAB}0/3${TAB}cur${TAB}fold"
    "V${TAB}2${TAB}v2${TAB}0/1${TAB}-${TAB}fold"
    "D${TAB}0"
  )
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
}

# --- P-25′: 上限ちょうど（v4文法で再構成） -----------------------------------

# P-25a′: 合計ちょうど65536バイト（Taskの最後のC行本文で調整）
mk_stub_P25a() {  # $1=パス
  _p6_task_lines
  # まず本文なしで組み立ててファイルへ書き、実バイト数を測ってから不足分を
  # C行の本文へ足す（コマンド置換 $(...) は末尾改行を削るので、それで測ると
  # 1バイトずれる＝実ファイルのバイト数で測る）。
  local base_file base_bytes pad_n
  base_file="${1}.base"
  _compose_frame "Task" "cmux-dock-frame/2" "${_P6_TASK_LINES[@]}" > "$base_file"
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
  _P6_TASK_LINES[3]="${_P6_TASK_LINES[3]}${pad}"   # 最後のC行(実装)の末尾へ足す
  _compose_frame "Task" "cmux-dock-frame/2" "${_P6_TASK_LINES[@]}" | _write_frame_stub "$1"
}

# P-25b′: ちょうど1000行（#V1+V1(open)+C996+D1+E1=1000）。t=996・[/]を
# 持つC行が1つも無いので全てfoldではなくopenの版1つに全部ぶら下げる。
mk_stub_P25b() {  # $1=パス
  local lines=("V${TAB}1${TAB}v1${TAB}0/996${TAB}cur${TAB}open")
  local i
  for ((i = 1; i <= 996; i++)); do
    lines+=("C${TAB}[ ]${TAB}t${i}")
  done
  lines+=("D${TAB}0")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
}

# --- P-27〜P-32: v4描画側（RT層）専用の追加fixture（§39.7.2） ----------------

# P-27: 版名45文字（V-17相当）のcur・fold 1版0/2。
mk_stub_P27() {  # $1=パス
  local name45
  name45="$(printf 'v%.0s' $(seq 1 45))"
  local lines=(
    "V${TAB}1${TAB}${name45}${TAB}0/2${TAB}cur${TAB}fold"
    "D${TAB}0"
  )
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
}

# P-28: V-15′相当＝cur・open 1版5/12（[x]×5・[ ]×5・[/] t11・[ ] t12）・D4。
mk_stub_P28() {  # $1=パス
  local lines=("V${TAB}1${TAB}v2${TAB}5/12${TAB}cur${TAB}open")
  local i
  for ((i = 1; i <= 5; i++)); do lines+=("C${TAB}[x]${TAB}t${i}"); done
  for ((i = 6; i <= 10; i++)); do lines+=("C${TAB}[ ]${TAB}t${i}"); done
  lines+=("C${TAB}[/]${TAB}t11" "C${TAB}[ ]${TAB}t12" "D${TAB}4")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" |
    _write_frame_stub_with_list "$1" "$(_p28_list)"
}

# P-29: ▶が先頭でない＝-・open 1版1/3（[x]・[ ]・[ ]）・cur・open 2版0/2
# （[/]・[ ]）・-・fold 3版0/1・D0（総行数8）。
mk_stub_P29() {  # $1=パス
  local lines=(
    "V${TAB}1${TAB}v1${TAB}1/3${TAB}-${TAB}open"
    "C${TAB}[x]${TAB}a" "C${TAB}[ ]${TAB}b" "C${TAB}[ ]${TAB}c"
    "V${TAB}2${TAB}v2${TAB}0/2${TAB}cur${TAB}open"
    "C${TAB}[/]${TAB}d" "C${TAB}[ ]${TAB}e"
    "V${TAB}3${TAB}v3${TAB}0/1${TAB}-${TAB}fold"
    "D${TAB}0"
  )
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
}

# P-30: D0（完了行なし）＝cur・fold 1版0/1・-・fold 2版0/1。
mk_stub_P30() {  # $1=パス
  local lines=(
    "V${TAB}1${TAB}v1${TAB}0/1${TAB}cur${TAB}fold"
    "V${TAB}2${TAB}v2${TAB}0/1${TAB}-${TAB}fold"
    "D${TAB}0"
  )
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
}

# P-31: Task種別で#Vが旧v3形cmux-dock-frame/1（正当なv3フレーム）→版ちがい。
mk_stub_P31() {  # $1=パス
  local lines=(
    "H${TAB}▶${TAB}cmux-session-todo${TAB}${TAB}v2${TAB}1/3"
    "V${TAB}v1${TAB}✅${TAB}3/3" "V${TAB}v2${TAB}▶${TAB}1/3" "V${TAB}v3${TAB}・${TAB}0/4"
    "C${TAB}5${TAB}[x]${TAB}要件定義" "C${TAB}6${TAB}[/]${TAB}設計" "C${TAB}7${TAB}[ ]${TAB}実装"
    "X${TAB}2"
  )
  _compose_frame "Task" "cmux-dock-frame/1" "${lines[@]}" | _write_frame_stub "$1"
}

# P-32: 60子行＝cur・open 1版0/60（[/] t0・[ ] t1〜t59）・D0・総行数61
# （AC-9′・DT-16）。
mk_stub_P32() {  # $1=パス
  local lines=("V${TAB}1${TAB}v1${TAB}0/60${TAB}cur${TAB}open" "C${TAB}[/]${TAB}t0")
  local i
  for ((i = 1; i <= 59; i++)); do lines+=("C${TAB}[ ]${TAB}t${i}"); done
  lines+=("D${TAB}0")
  _compose_frame "Task" "cmux-dock-frame/2" "${lines[@]}" | _write_frame_stub "$1"
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
    frame="$(_compose_frame "Task" "cmux-dock-frame/2" "${_P6_TASK_LINES[@]}")"
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

# 48サブIDのうち Task 側で構成できるものを1関数で扱う（表引き・v4行文法）。
# P-6′基底（_p6_task_lines・_P6_TASK_LINES）の添字＝0:V1(v2)・1:C[x]・
# 2:C[/]・3:C[ ]・4:V2(v3)・5:D。$1=パス $2=サブID
mk_stub_P_violation() {
  local path="$1" id="$2"
  local version="cmux-dock-frame/2" kind="Task"
  _p6_task_lines
  local body=("${_P6_TASK_LINES[@]}")

  case "$id" in
    P-7a)  # 版宣言が0個
      { printf '%s\n' "${body[@]}"; printf 'E%s6\n' "$TAB"; } | _write_frame_stub "$path"; return ;;
    P-7b)  # 版宣言が2個
      { printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '%s\n' "${body[@]}"
        printf 'E%s6\n' "$TAB"
      } | _write_frame_stub "$path"; return ;;
    P-7c)  # 版宣言が先頭にない
      { printf '%s\n' "${body[0]}"
        printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '%s\n' "${body[@]:1}"
        printf 'E%s6\n' "$TAB"
      } | _write_frame_stub "$path"; return ;;
    P-8a)  # 種別不一致（Taskを要求されるが/2でProjectを名乗る＝版ちがいに
           # 化けさせない＝/1にしない）
      _compose_frame "Project" "$version" "${body[@]}" | _write_frame_stub "$path"; return ;;
    P-9a)  # 理由とデータ本体が同居
      { printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf 'R%s理由\n' "$TAB"
        printf '%s\n' "${body[@]}"
        printf 'E%s7\n' "$TAB"
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
    P-11a) # 必須欄が欠ける（V行の欄を1つ削る＝展開欄を落とす）。他の変種
           # （版名が空／C本文が空）はSUPPLY_VIOLATION_VARIANTSで
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}1/3${TAB}cur"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-11a-vname) # 版名が空
      _mutate_task 0 "V${TAB}1${TAB}${TAB}1/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-11a-cbody) # C本文が空
      _mutate_task 1 "C${TAB}[x]${TAB}"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-11b) # 未定義の欄がある（V行に欄を1つ足す）
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}1/3${TAB}cur${TAB}open${TAB}extra"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-11c) # 未定義の行種別がある
      _mutate_task 1 "Z${TAB}[x]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-12a) # 状態が[?]
      _mutate_task 1 "C${TAB}[?]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-12b) # 区分が完了（Project）
      _p6_proj_lines
      _P6_PROJ_LINES[0]="P${TAB}5${TAB}svwb-pilot-log${TAB}実データ照合を回す${TAB}完了"
      _compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    P-12c) # ヘルスの種別が未定義値（Project）
      _p6_proj_lines
      _P6_PROJ_LINES[3]="B${TAB}未定義${TAB}warn${TAB}x"
      _compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    P-12d) # 展開欄がopen/fold以外
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}1/3${TAB}cur${TAB}exp"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-12e) # ▶欄がcur/-以外
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}1/3${TAB}yes${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13a) # 番号が重複（V2の番号をV1と同じ1にする）
      _mutate_task 4 "V${TAB}1${TAB}v3${TAB}0/4${TAB}-${TAB}fold"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13b) # 番号が0
      _mutate_task 0 "V${TAB}0${TAB}v2${TAB}1/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13c) # 番号が負数
      _mutate_task 0 "V${TAB}-1${TAB}v2${TAB}1/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13d) # 番号が非数字
      _mutate_task 0 "V${TAB}abc${TAB}v2${TAB}1/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13e) # 9999超
      _mutate_task 0 "V${TAB}10000${TAB}v2${TAB}1/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-13f) # 記載順に減る（V1を3・V2を既定の2のままにする）
      _mutate_task 0 "V${TAB}3${TAB}v2${TAB}1/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14a) # 自己申告の行数と実行数が違う
      { _compose_frame "$kind" "$version" "${body[@]}" | sed '$ s/.*/E\t99/'; } | _write_frame_stub "$path"; return ;;
    P-14b) # サブIDとしての代表変種（孤立継続バイト）。他の変種は
           # SUPPLY_VIOLATION_VARIANTS 経由で個別に生成できる。
      mk_stub_P_violation "$path" "P-14b-lone"; return ;;
    P-14c) # サブIDとしての代表変種（ESC）
      mk_stub_P_violation "$path" "P-14c-esc"; return ;;
    P-14b-lone) # 孤立継続バイト
      _mutate_task 1 "$(printf 'C%s[x]%sa\x80b' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-overlong) # 過長形式
      _mutate_task 1 "$(printf 'C%s[x]%sa\xc0\x80b' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-surrogate) # サロゲート
      _mutate_task 1 "$(printf 'C%s[x]%sa\xed\xa0\x80b' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-over10ffff) # U+10FFFF超
      _mutate_task 1 "$(printf 'C%s[x]%sa\xf4\x90\x80\x80b' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14b-trunc) # 途中切れ（先頭バイトのみ）
      _mutate_task 1 "$(printf 'C%s[x]%sa\xe2' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-esc) # データ欄にESC
      _mutate_task 1 "$(printf 'C%s[x]%sa\x1bb' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-del) # データ欄にDEL
      _mutate_task 1 "$(printf 'C%s[x]%sa\x7fb' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-c1) # データ欄にC1(U+0080)
      _mutate_task 1 "$(printf 'C%s[x]%sa\xc2\x80b' "$TAB" "$TAB")"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-14c-nul) # 欄の末尾にNUL（NULはbash変数/コマンド置換を経由すると失われる
               # ため、この1件だけはファイルへ直接バイトを書く）
      {
        printf '#V%s%s%s%s\n' "$TAB" "$version" "$TAB" "$kind"
        printf '%s\n' "${body[0]}"
        printf 'C%s[x]%sa\x00' "$TAB" "$TAB"
        printf '\n'
        printf '%s\n' "${body[2]}" "${body[3]}" "${body[4]}" "${body[5]}"
        printf 'E%s6\n' "$TAB"
      } > "${path}.data"
      _write_cat_stub "$path"; return ;;
    P-14d) # 65537バイト（バイト上限）＝P-20aと同じ構成をそのまま使う
      mk_stub_P20a "$path" "${path}.footprints"; return ;;
    P-14e) # 1001行（行上限）＝P-20bと同じ構成をそのまま使う
      mk_stub_P20b "$path" "${path}.footprints"; return ;;
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
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}1-3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18b) # d>t
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}4/3${TAB}cur${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18c) # V≥1行でcurが0（両方とも-）
      _mutate_task 0 "V${TAB}1${TAB}v2${TAB}1/3${TAB}-${TAB}open"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18d) # cur2行
      _mutate_task 4 "V${TAB}2${TAB}v3${TAB}0/4${TAB}cur${TAB}fold"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18e) # openのC行数がtと違う（Cを1行削り、tは3のまま）
      _mutate_task 3 "DELETE"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18f) # openの[x]数がdと違う（[x]行を[ ]に変え、dは1のまま）
      _mutate_task 1 "C${TAB}[ ]${TAB}要件定義"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18g) # foldの後にC（V2はfoldのままC行を1つ追加）
      { local l=("${body[0]}" "${body[1]}" "${body[2]}" "${body[3]}" "${body[4]}" "C${TAB}[ ]${TAB}extra" "${body[5]}")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18h) # V行が完了版（t≥1∧d==t）
      { local l=("V${TAB}1${TAB}v1${TAB}1/1${TAB}cur${TAB}fold" "D${TAB}0")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18i) # CがVの最初の前
      { local l=("C${TAB}[x]${TAB}a" "V${TAB}1${TAB}v1${TAB}1/2${TAB}cur${TAB}open" "C${TAB}[x]${TAB}a" "C${TAB}[ ]${TAB}b" "D${TAB}0")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18j) # Dが負（非整数の変種P-18j-nonintはSUPPLY_VIOLATION_VARIANTSで）
      _mutate_task 5 "D${TAB}-1"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18j-nonint) # Dが非整数
      _mutate_task 5 "D${TAB}abc"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18k) # V0行かつD0
      { local l=("D${TAB}0")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18l) # D0行（Dを削り、後続の行を足さない）
      _mutate_task 5 "DELETE"
      _compose_frame "$kind" "$version" "${_MUT[@]}" | _write_frame_stub "$path"; return ;;
    P-18m) # D2行
      { local l=("${body[@]}" "D${TAB}2")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-18n) # Dの後にVかC
      { local l=("${body[@]}" "C${TAB}[ ]${TAB}extra")
        _compose_frame "$kind" "$version" "${l[@]}"
      } | _write_frame_stub "$path"; return ;;
    P-19a) # ヘルス行の種別が重複（Project）
      _p6_proj_lines
      _P6_PROJ_LINES+=("B${TAB}棚卸し${TAB}ok${TAB}dup")
      _compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    P-19b) # 区分の並びが混ざる（Project・保留の後に稼働中が来る）
      _p6_proj_lines
      _P6_PROJ_LINES[0]="P${TAB}5${TAB}svwb-pilot-log${TAB}実データ照合を回す${TAB}保留"
      _compose_frame "Project" "cmux-dock-frame/1" "${_P6_PROJ_LINES[@]}" | _write_frame_stub "$path"; return ;;
    *)
      echo "mk_stub_P_violation: 未知のサブID: $id" >&2
      return 1
      ;;
  esac
}

# 48サブIDの完全な集合（AC-111の突合対象）。P-14b・P-14cはそれぞれ内部に
# 5変種・4変種を持つが、サブIDとしては1つのまま数える（設計 §29.4・
# AC-111の「48サブIDの集合」を増やさない）。変種ごとの実装は下の
# SUPPLY_VIOLATION_VARIANTS で別途網羅する。
SUPPLY_VIOLATION_IDS=(
  P-7a P-7b P-7c
  P-8a
  P-9a P-9b
  P-10a P-10b
  P-11a P-11b P-11c
  P-12a P-12b P-12c P-12d P-12e
  P-13a P-13b P-13c P-13d P-13e P-13f
  P-14a P-14b P-14c P-14d P-14e
  P-17a P-17b P-17c P-17d P-17e
  P-18a P-18b P-18c P-18d P-18e P-18f P-18g P-18h P-18i P-18j P-18k P-18l P-18m P-18n
  P-19a P-19b
)

# P-14b・P-14c・P-11aの内側の変種（サブIDの集合には数えないが、状態機械の
# 全分岐（§29.4のUTF-8状態機械表）・欠落欄の別形（版名が空／C本文が空）を
# 網羅するために個別に生成できるようにする）。
SUPPLY_VIOLATION_VARIANTS=(
  P-14b-lone P-14b-overlong P-14b-surrogate P-14b-over10ffff P-14b-trunc
  P-14c-esc P-14c-del P-14c-c1 P-14c-nul
  P-11a-vname P-11a-cbody
  P-18j-nonint
)
