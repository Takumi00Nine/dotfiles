# 供給側（ai-env の cmux-task-model.sh／cmux-next-model.sh）の呼び出しと
# フレーム契約の検証（cmux-session-todo 設計 §28〜§31・C-17）。ドメイン
# データ（Vault・宣言記録・外部脳ログ・cmux）を一切知らない。締切・大きさ
# 上限・後始末（run_supply）と、契約の意味型12項目の検証（validate_frame）
# を持つ。両常駐（cmux-task-watch.sh／cmux-next-watch.sh）から source される
# （設計 §28.3）。単体では実行しない（関数定義のみ）。
#
# 使い方:
#   LIB_DIR="$(cd -P "$(dirname "$0")" && pwd)/.."
#   . "$LIB_DIR/lib-supply-frame.sh"
#   . "$LIB_DIR/lib-dock-view.sh"   # sanitize_interval を使うため先に読む
#
#   SUPPLY_PGID=""; WATCH_PGID=""; RAW=""; RCF=""; DONE=""; TOUT=""; MODEL=""
#   fetch_frame "Task" "$SUPPLY_PATH"
#   if [ -z "$FRAME_REASON" ]; then
#     # $MODEL に本体行（TAB区切り・1行1レコード）がある。読み終えたら
#     # 呼び出し側が rm -f -- "$MODEL" すること（設計 §31.3 の個別変数の
#     # 流儀＝cleanup() は他の一時物と同じ扱いでこれも消せる）。
#   fi

CMUX_FRAME_VERSION="cmux-dock-frame/1"

# is_number の複製（複製元: cmux/lib-dock-view.sh の is_number）。この
# ファイルは「LIB_DIR/lib-dock-view.sh を先に source 済み」という暗黙の
# 前提に依存していた（単独で source して run_supply を呼ぶと
# is_number: command not found になる＝検証2巡目 #28）。FR-87の方針
# （相手libの関数へ暗黙依存しない）どおり自前に持つことで、source順に
# 依存しない。追随: 片方を直したらもう片方（lib-dock-view.sh）も同じ巡で
# 直す（自動同期は無い＝NFR-13）。
_supply_is_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# --- 一時物・プロセスの後始末（冪等・設計 §31.1・§31.3） -------------------

# run_supply が起こしたプロセスグループを落とす。SUPPLY_PGID/WATCH_PGID は
# 大域変数（source 元＝常駐スクリプトの trap からも同じ変数を見る）。
supply_kill_groups() {
  if [ -n "${SUPPLY_PGID:-}" ]; then
    kill -TERM "-$SUPPLY_PGID" 2>/dev/null
    kill -KILL "-$SUPPLY_PGID" 2>/dev/null
    wait "$SUPPLY_PGID" 2>/dev/null
    SUPPLY_PGID=""
  fi
  if [ -n "${WATCH_PGID:-}" ]; then
    kill -TERM "-$WATCH_PGID" 2>/dev/null
    kill -KILL "-$WATCH_PGID" 2>/dev/null
    wait "$WATCH_PGID" 2>/dev/null
    WATCH_PGID=""
  fi
}

# RAW/RCF/DONE/TOUT を個別に（未引用の $TMPS 展開はしない・§31.3の⚠️）消す。
supply_rm_transient() {
  rm -f -- "${RAW:-}" "${RCF:-}" "${DONE:-}" "${TOUT:-}" 2>/dev/null
  RAW=""; RCF=""; DONE=""; TOUT=""
}

# --- 締切の正規化（FR-67 #1・AC-119） --------------------------------------

# CMUX_DOCK_SUPPLY_TIMEOUT を 1〜60 の整数へ正規化する。空・非数字・0・負・
# 小数・61以上は既定5へ戻す。sanitize_interval（lib-dock-view.sh）が
# 空・非数字・0を既定へ戻す分を担い、ここでは上限61以上だけを追加で見る。
supply_deadline() {
  local d
  d="$(sanitize_interval "${CMUX_DOCK_SUPPLY_TIMEOUT:-}" 5)"
  if [ "$d" -gt 60 ] 2>/dev/null; then
    d=5
  fi
  printf '%s' "$d"
}

# --- 取得（FR-67・詳細設計 §31.1） -----------------------------------------

# 供給側を1回呼び、締切と大きさ上限（65537バイト目／1001行目で打ち切り）を
# 課して RAW へ生バイトを保存する。大域変数 RAW/RCF/DONE/TOUT/SUPPLY_PGID/
# WATCH_PGID を設定する（すべて呼び出し前に必ずクリアする＝run_supply自身の
# 先頭で初期化）。
#   $1 = SUPPLY（呼び出し口の絶対パス）
#   $2 = DEADLINE（秒・正規化済み）
# 戻り値:
#   0  = RAW にデータがある（validate_frame へ進む）
#   10 = 未導入（S0＝呼び出し口が [ -x ] を満たさない）
#   1  = 応答なし（mktemp失敗・上限到達・締切・非0終了・rc=0で0バイト等。
#        どの経路でも理由行は同じなので細分しない＝§31.1の結末表）
run_supply() {
  local supply="$1" deadline="$2"
  RAW=""; RCF=""; DONE=""; TOUT=""; SUPPLY_PGID=""; WATCH_PGID=""

  [ -x "$supply" ] || return 10

  RAW="$(mktemp "${TMPDIR:-/tmp}/cmux-supply-raw.XXXXXX" 2>/dev/null)" || { supply_rm_transient; return 1; }
  RCF="$(mktemp "${TMPDIR:-/tmp}/cmux-supply-rc.XXXXXX" 2>/dev/null)" || { supply_rm_transient; return 1; }
  DONE="$(mktemp "${TMPDIR:-/tmp}/cmux-supply-done.XXXXXX" 2>/dev/null)" || { supply_rm_transient; return 1; }
  rm -f -- "$DONE"
  TOUT="$(mktemp "${TMPDIR:-/tmp}/cmux-supply-tout.XXXXXX" 2>/dev/null)" || { supply_rm_transient; return 1; }
  rm -f -- "$TOUT"

  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  # fork直後、子が既にexecを終えているとbash自身のsetpgidがEPERMになり、
  # 「child setpgid (...): Operation not permitted」を*このシェルの現在の
  # stderr*へ直接出す（disownはジョブ表から外すだけで、この行は止められ
  # ない＝検証5巡目 #46）。フォークする2文だけを{ }2>/dev/nullで包み、
  # ジョブ制御由来のこの1行だけを描画側stderrから隔離する（供給側自身の
  # stderrは"$supply" --frame 2>/dev/nullで既に個別に捨てているので、
  # ここでの追加の抑制で失われる診断は無い）。PGIDでの一括終了
  # （DT-13・DT-14・AC-95・AC-123が検査する性質）はこの変更で変わらない
  # （{ }はサブシェルを作らないため$!・SUPPLY_PGID/WATCH_PGIDの捕捉は従来
  # どおり）。
  {
    ( { "$supply" --frame 2>/dev/null; echo $? >"$RCF"; } |
        head -n 1001 |
        { dd bs=1 count=65537 of="$RAW" 2>/dev/null; : >"$DONE"; } ) &
    SUPPLY_PGID=$!
    disown "$SUPPLY_PGID" 2>/dev/null
    ( sleep "$deadline"; kill -TERM "-$SUPPLY_PGID" 2>/dev/null
      sleep 0.3;         kill -KILL "-$SUPPLY_PGID" 2>/dev/null; : >"$TOUT" ) &
    WATCH_PGID=$!
    disown "$WATCH_PGID" 2>/dev/null
  } 2>/dev/null
  [ "$had_monitor" = "1" ] || set +m

  while :; do
    [ -e "$DONE" ] && break
    [ -e "$TOUT" ] && break
    sleep 0.05
  done
  kill -TERM "-$SUPPLY_PGID" 2>/dev/null
  kill -KILL "-$SUPPLY_PGID" 2>/dev/null
  kill -TERM "-$WATCH_PGID"  2>/dev/null
  wait "$WATCH_PGID" 2>/dev/null
  wait "$SUPPLY_PGID" 2>/dev/null
  SUPPLY_PGID=""; WATCH_PGID=""

  # 大きさ上限の判定は wc を使わない（FR-64の許可表に無い＝検証1巡目 #10）。
  # バイト上限: dd bs=1 count=65537 で RAW は最大65537バイトにしか
  # ならないので、「65536バイト目（0始まりのオフセット）が存在するか」を
  # dd 自身の skip で直接調べれば「raw_bytes >= 65537」と同値になる。
  local probe rcv
  probe="$(mktemp "${TMPDIR:-/tmp}/cmux-supply-probe.XXXXXX" 2>/dev/null)" || { supply_rm_transient; return 1; }
  dd if="$RAW" of="$probe" bs=1 skip=65536 count=1 2>/dev/null
  if [ -s "$probe" ]; then rm -f -- "$probe"; supply_rm_transient; return 1; fi
  rm -f -- "$probe"

  # 行上限: awk の NR（既定 RS=改行のレコード数）で数える。
  local lf_count
  lf_count="$(LC_ALL=C awk 'END{print NR}' "$RAW" 2>/dev/null)"
  _supply_is_number "$lf_count" || lf_count=0
  if [ "$lf_count" -ge 1001 ]; then supply_rm_transient; return 1; fi

  if [ ! -s "$RCF" ]; then supply_rm_transient; return 1; fi
  rcv="$(cat "$RCF" 2>/dev/null)"
  _supply_is_number "$rcv" || { supply_rm_transient; return 1; }
  if [ "$rcv" -ne 0 ]; then supply_rm_transient; return 1; fi
  if [ ! -s "$RAW" ]; then supply_rm_transient; return 1; fi

  rm -f -- "$RCF" "$DONE" "$TOUT"
  RCF=""; DONE=""; TOUT=""
  return 0
}

# --- 契約の検証（FR-82・§29〜§31.2） ---------------------------------------

# validate_frame_awk の中身は下の関数が heredoc で組み立てる（1ファイル内に
# 収めるため）。awk は LC_ALL=C・1バイト=1文字として動かす（§29.4のUTF-8
# 状態機械をバイト単位で書けるようにするため）。
_supply_frame_awk_program() {
  cat <<'CMUX_AWK_EOF'
BEGIN {
  FS = "\t"
  for (n = 1; n < 256; n++) ord[sprintf("%c", n)] = n
}

{
  raw_nf[NR] = NF
  for (i = 1; i <= NF; i++) fld[NR, i] = $i
}

function utf8_ok(s,    n, i, b, c1, c2, c3) {
  n = length(s)
  i = 1
  while (i <= n) {
    b = ord[substr(s, i, 1)]
    if (b <= 8) return 0
    if (b == 9 || b == 10) { i++; continue }
    if (b <= 31) return 0
    if (b == 127) return 0
    if (b <= 126) { i++; continue }
    if (b <= 191) return 0
    if (b <= 193) return 0
    if (b == 194) {
      if (i + 1 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]
      if (c1 < 128 || c1 > 191) return 0
      if (c1 <= 159) return 0
      i += 2; continue
    }
    if (b <= 223) {
      if (i + 1 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]
      if (c1 < 128 || c1 > 191) return 0
      i += 2; continue
    }
    if (b == 224) {
      if (i + 2 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]; c2 = ord[substr(s, i + 2, 1)]
      if (c1 < 160 || c1 > 191) return 0
      if (c2 < 128 || c2 > 191) return 0
      i += 3; continue
    }
    if (b <= 236 || b == 238 || b == 239) {
      if (i + 2 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]; c2 = ord[substr(s, i + 2, 1)]
      if (c1 < 128 || c1 > 191) return 0
      if (c2 < 128 || c2 > 191) return 0
      i += 3; continue
    }
    if (b == 237) {
      if (i + 2 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]; c2 = ord[substr(s, i + 2, 1)]
      if (c1 < 128 || c1 > 159) return 0
      if (c2 < 128 || c2 > 191) return 0
      i += 3; continue
    }
    if (b == 240) {
      if (i + 3 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]; c2 = ord[substr(s, i + 2, 1)]; c3 = ord[substr(s, i + 3, 1)]
      if (c1 < 144 || c1 > 191) return 0
      if (c2 < 128 || c2 > 191) return 0
      if (c3 < 128 || c3 > 191) return 0
      i += 4; continue
    }
    if (b <= 243) {
      if (i + 3 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]; c2 = ord[substr(s, i + 2, 1)]; c3 = ord[substr(s, i + 3, 1)]
      if (c1 < 128 || c1 > 191) return 0
      if (c2 < 128 || c2 > 191) return 0
      if (c3 < 128 || c3 > 191) return 0
      i += 4; continue
    }
    if (b == 244) {
      if (i + 3 > n) return 0
      c1 = ord[substr(s, i + 1, 1)]; c2 = ord[substr(s, i + 2, 1)]; c3 = ord[substr(s, i + 3, 1)]
      if (c1 < 128 || c1 > 143) return 0
      if (c2 < 128 || c2 > 191) return 0
      if (c3 < 128 || c3 > 191) return 0
      i += 4; continue
    }
    return 0
  }
  return 1
}

function is_uint(s,    n, i, c) {
  n = length(s)
  if (n == 0) return 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c < "0" || c > "9") return 0
  }
  return 1
}

function parse_frac(s,    slash, dpart, tpart, d, t) {
  FRAC_OK = 0; FRAC_D = -1; FRAC_T = -1
  slash = index(s, "/")
  if (slash <= 1 || slash == length(s)) return
  dpart = substr(s, 1, slash - 1)
  tpart = substr(s, slash + 1)
  if (!is_uint(dpart) || !is_uint(tpart)) return
  d = dpart + 0; t = tpart + 0
  if (d > t) return
  FRAC_OK = 1; FRAC_D = d; FRAC_T = t
}

END {
  N = NR
  if (N < 1) exit 3

  vcount = 0; vpos = 0
  for (i = 1; i <= N; i++) if (fld[i, 1] == "#V") { vcount++; if (vcount == 1) vpos = i }
  if (vcount != 1 || vpos != 1) exit 3

  if (raw_nf[1] != 3) exit 3
  if (fld[1,1] == "" || fld[1,2] == "" || fld[1,3] == "") exit 3

  version = fld[1,2]; vkind = fld[1,3]
  if (version != "cmux-dock-frame/1") exit 2

  if (vkind != expect_kind) exit 3
  if (vkind != "Task" && vkind != "Project") exit 3

  for (i = 2; i <= N; i++) {
    for (j = 1; j <= raw_nf[i]; j++) {
      if (!utf8_ok(fld[i, j])) exit 3
    }
  }

  ecount = 0; eidx = 0
  for (i = 2; i <= N; i++) if (fld[i, 1] == "E") { ecount++; if (ecount == 1) eidx = i }
  if (ecount != 1) exit 3
  if (eidx != N) exit 3
  if (raw_nf[eidx] != 2) exit 3
  if (!is_uint(fld[eidx, 2])) exit 3
  body_n = eidx - 2
  if (fld[eidx, 2] + 0 != body_n) exit 3

  if (body_n == 1 && fld[2, 1] == "R") {
    if (raw_nf[2] != 2) exit 3
    reason = fld[2, 2]
    if (reason == "") exit 3
    print reason
    exit 1
  }
  for (i = 2; i < eidx; i++) if (fld[i, 1] == "R") exit 3
  # body_n==0 は Task では #5 の必須 H 行が無いことになり fld[2,1]!="H" で
  # 落ちる。Project は「P*・B*ともに0行以上」が正当（FR-82 #5）なので、
  # ここでは種別を問わず一律には落とさない（検証1巡目 #8）。

  last_num = 0

  if (vkind == "Task") {
    if (fld[2, 1] != "H") exit 3
    if (raw_nf[2] != 6) exit 3
    h_sym = fld[2,2]; h_name = fld[2,3]; h_lead = fld[2,4]; h_ver = fld[2,5]; h_frac = fld[2,6]
    if (h_sym == "" || h_name == "" || h_frac == "") exit 3
    if (h_sym != "▶" && h_sym != "✅" && h_sym != "・") exit 3

    vn = 0; cn = 0
    pos = 3
    while (pos < eidx && fld[pos, 1] == "V") {
      vn++
      if (raw_nf[pos] != 4) exit 3
      vname[vn] = fld[pos, 2]; vsym[vn] = fld[pos, 3]; vfrac[vn] = fld[pos, 4]
      if (vname[vn] == "" || vsym[vn] == "" || vfrac[vn] == "") exit 3
      if (vsym[vn] != "▶" && vsym[vn] != "✅" && vsym[vn] != "・") exit 3
      parse_frac(vfrac[vn])
      if (!FRAC_OK) exit 3
      vd[vn] = FRAC_D; vt[vn] = FRAC_T
      if (vt[vn] == 0) { if (vsym[vn] != "・") exit 3 }
      else if (vd[vn] == vt[vn]) { if (vsym[vn] != "✅") exit 3 }
      else { if (vsym[vn] != "▶" && vsym[vn] != "・") exit 3 }
      pos++
    }
    slash_seen = 0
    while (pos < eidx && fld[pos, 1] == "C") {
      cn++
      if (raw_nf[pos] != 4) exit 3
      cnum = fld[pos, 2]; cstate = fld[pos, 3]; cbody = fld[pos, 4]
      if (cnum == "" || cbody == "") exit 3
      if (cstate != "[x]" && cstate != "[/]" && cstate != "[ ]") exit 3
      if (!is_uint(cnum)) exit 3
      nval = cnum + 0
      if (nval < 1 || nval > 9999) exit 3
      if (nval <= last_num) exit 3
      last_num = nval
      if (cstate == "[/]") slash_seen = 1
      cst[cn] = cstate
      pos++
    }
    if (pos != eidx - 1) exit 3
    if (fld[pos, 1] != "X") exit 3
    if (raw_nf[pos] != 2) exit 3
    xval = fld[pos, 2]
    if (xval == "") exit 3

    if (xval == "-") {
      if (cn != 0) exit 3
      if (h_sym != "✅") exit 3
      if (h_lead != "全版完了") exit 3
      if (h_ver != "") exit 3
      if (vn < 1) exit 3
      done_v = 0
      for (k = 1; k <= vn; k++) {
        if (vsym[k] != "✅") exit 3
        if (vt[k] >= 1 && vd[k] == vt[k]) done_v++
      }
      parse_frac(h_frac)
      if (!FRAC_OK) exit 3
      if (FRAC_D != done_v || FRAC_T != vn) exit 3
      if (FRAC_D != FRAC_T) exit 3
    } else {
      if (!is_uint(xval)) exit 3
      xn = xval + 0
      if (xn < 1 || xn > vn) exit 3
      if (vt[xn] == 0) exit 3
      if (vd[xn] >= vt[xn]) exit 3
      if (cn != vt[xn]) exit 3
      xdone = 0
      for (k = 1; k <= cn; k++) if (cst[k] == "[x]") xdone++
      if (xdone != vd[xn]) exit 3
      if (h_ver != vname[xn]) exit 3
      if (h_frac != vfrac[xn]) exit 3
      if (slash_seen) {
        if (vsym[xn] != "▶" || h_sym != "▶" || h_lead != "") exit 3
      } else {
        if (vsym[xn] != "・" || h_sym != "・" || h_lead != "次: ") exit 3
      }
    }
  } else {
    pn = 0; bn = 0
    pos = 2
    while (pos < eidx && fld[pos, 1] == "P") {
      pn++
      if (raw_nf[pos] != 5) exit 3
      pnum[pn] = fld[pos,2]; pname[pn] = fld[pos,3]; pnext[pn] = fld[pos,4]; pcat[pn] = fld[pos,5]
      if (pnum[pn] == "" || pname[pn] == "" || pcat[pn] == "") exit 3
      if (pcat[pn] != "稼働中" && pcat[pn] != "保留") exit 3
      if (!is_uint(pnum[pn])) exit 3
      nval = pnum[pn] + 0
      if (nval < 1 || nval > 9999) exit 3
      if (nval <= last_num) exit 3
      last_num = nval
      pos++
    }
    while (pos < eidx && fld[pos, 1] == "B") {
      bn++
      if (raw_nf[pos] != 4) exit 3
      bkind[bn] = fld[pos,2]; bwarn[bn] = fld[pos,3]; btext[bn] = fld[pos,4]
      if (bkind[bn] == "" || bwarn[bn] == "" || btext[bn] == "") exit 3
      if (bkind[bn] != "棚卸し" && bkind[bn] != "週次") exit 3
      if (bwarn[bn] != "warn" && bwarn[bn] != "ok") exit 3
      pos++
    }
    if (pos != eidx) exit 3

    seen_hold = 0
    for (k = 1; k <= pn; k++) {
      if (pcat[k] == "保留") seen_hold = 1
      else if (seen_hold) exit 3
    }
    cnt_tana = 0; cnt_week = 0
    for (k = 1; k <= bn; k++) {
      if (bkind[k] == "棚卸し") cnt_tana++
      else cnt_week++
    }
    if (cnt_tana > 1 || cnt_week > 1) exit 3
  }

  for (i = 2; i < eidx; i++) {
    line = fld[i, 1]
    for (j = 2; j <= raw_nf[i]; j++) line = line "\t" fld[i, j]
    print line
  }
  exit 0
}
CMUX_AWK_EOF
}

# フレーム契約を検証する（S2〜S6＝設計 §29.3・§31.2）。RAW は1バイトも
# 書き換えない。欄の分解は awk -F '\t' に固定する（§29.1の⚠️＝
# while IFS=$'\t' read は空欄を畳むので使わない）。
#   $1 = KIND（"Task"／"Project"＝呼び出し側が要求した種別）
#   $2 = RAW のパス
#   $3 = MODEL のパス（書き込み先）
# 戻り値: 0=通常（MODELに本体行）／1=理由フレーム（MODELに理由文字列1行）
#         ／2=版ちがい／3=契約違反（応答なしへ落とす）
validate_frame() {
  local kind="$1" raw="$2" model="$3"
  LC_ALL=C tr '\000' '\001' < "$raw" \
    | LC_ALL=C awk -v expect_kind="$kind" "$(_supply_frame_awk_program)" > "$model" 2>/dev/null
  local rc="${PIPESTATUS[1]:-$?}"
  return "$rc"
}

# --- 合成（run_supply + validate_frame・呼び出し側の主入口） ---------------

# 1ティック分のフレームを取得・検証する。呼び出し側は大域変数
# SUPPLY_PGID/WATCH_PGID/RAW/RCF/DONE/TOUT/MODEL を（空文字で）先に宣言して
# おくこと（常駐の trap がこれらを見て後始末する＝設計 §31.3）。
#   $1 = KIND（"Task"／"Project"）
#   $2 = SUPPLY（呼び出し口の絶対パス）
# 結果: FRAME_REASON（空文字なら通常描画）。通常描画のときは $MODEL に
#   本体行がある（呼び出し側が読み終えたら rm -f -- "$MODEL" すること）。
#   理由行・版ちがい・応答なしのときは MODEL は既に消してある。
fetch_frame() {
  local kind="$1" supply="$2" deadline rc vrc
  FRAME_REASON=""
  deadline="$(supply_deadline)"

  MODEL="$(mktemp "${TMPDIR:-/tmp}/cmux-supply-model.XXXXXX" 2>/dev/null)" || {
    MODEL=""
    FRAME_REASON="AI環境 応答なし"
    return 0
  }

  run_supply "$supply" "$deadline"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    FRAME_REASON="AI環境 未導入"
    rm -f -- "$MODEL"; MODEL=""
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    FRAME_REASON="AI環境 応答なし"
    rm -f -- "$MODEL"; MODEL=""
    return 0
  fi

  validate_frame "$kind" "$RAW" "$MODEL"
  vrc=$?
  rm -f -- "$RAW"; RAW=""
  case "$vrc" in
    0) FRAME_REASON="" ;;
    1) FRAME_REASON="$(cat "$MODEL" 2>/dev/null)"; rm -f -- "$MODEL"; MODEL="" ;;
    2) FRAME_REASON="AI環境 版ちがい"; rm -f -- "$MODEL"; MODEL="" ;;
    *) FRAME_REASON="AI環境 応答なし"; rm -f -- "$MODEL"; MODEL="" ;;
  esac
  return 0
}

# --- MODEL 行の分解（描画側専用・設計 §29.1 の⚠️を踏襲） -------------------

# TAB区切りの1行を配列 TSV_F[] へ分解する（パラメータ展開のみ・空欄を
# 畳まない）。while IFS=$'\t' read の罠（連続TABが1個に畳まれ空欄が消える）
# を避けるため、$MODEL の読み取り側もこの関数を使うこと。
split_tsv() {
  local line="$1" tab rest field
  tab="$(printf '\t')"
  TSV_F=()
  rest="$line"
  while :; do
    case "$rest" in
      *"$tab"*)
        field="${rest%%"$tab"*}"
        TSV_F+=("$field")
        rest="${rest#*"$tab"}"
        ;;
      *)
        TSV_F+=("$rest")
        break
        ;;
    esac
  done
}
