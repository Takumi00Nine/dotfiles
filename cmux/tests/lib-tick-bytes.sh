# 常駐モードの1ティック分の生バイト列に対する AC-143 の判定器（cmux-session-todo
# 設計 v5 §40.9.2・D-v5-9）。テスト専用の lib（本番側からは source しない）。
# テストから `. lib-tick-bytes.sh` して使う（関数定義のみ・副作用なし）。
#
#   tick_check <log> <h> <expect_first> [<expect_last>]
#
# <log> は常駐の stdout を pipe で捕捉したファイル（PTY 変換前の生バイト列）。
# 判定対象 S ＝ ログ先頭から最初の `ESC[?2026l` まで（含む）。S が無ければ
# 全判定を fail にする。stdout へ `名前<TAB>pass|fail<TAB>観測値` を 1 判定
# 1 行で出す（要件 AC-143 の①②③⑤⑥⑦。③は <expect_last> を渡したときだけ）。
#
#   ac143_1_lf        S の LF（0x0A）の個数 ≤ h−1
#   ac143_2_first     ESC シーケンス（CSI・OSC）除去後を LF で分割した先頭要素 == <expect_first>
#   ac143_3_last      同分割の最後の非空要素 == <expect_last>
#   ac143_5_home      最初の可視バイトより前に `ESC[H` か `ESC[1;1H` がある
#   ac143_6_no_vmove  LF 以外の縦移動バイト列（VT・FF・ESC D/E/M・CSI A B d E F e
#                     L M r S T・引数が空／1;1 以外の H f）を含まない（単純な否定検査）
#   ac143_7_width     ESC 除去後の各行の表示幅 ≤ 40（east_asian_width の W/F を 2・他 1＝
#                     lib-dock-view.sh の jq 範囲表とは別実装のオラクル）
#
# 幅の上限 40 は要件 AC-143 の固定値（`CMUX_NEXT_COLS=40` で起動する前提）。
# 依存＝python3（既存テストと同じ）。

tick_check() {
  python3 - "$1" "$2" "$3" "${4-}" <<'PYEOF'
import re, sys, unicodedata

log_path, h_s, expect_first, expect_last = sys.argv[1:5]
h = int(h_s)
data = open(log_path, "rb").read()
END = b"\x1b[?2026l"

def out(name, ok, obs):
    obs = obs.replace("\t", "\\t").replace("\n", "\\n")
    sys.stdout.write("%s\t%s\t%s\n" % (name, "pass" if ok else "fail", obs))

pos = data.find(END)
if pos < 0:
    for name in ("ac143_1_lf", "ac143_2_first", "ac143_3_last", "ac143_5_home",
                 "ac143_6_no_vmove", "ac143_7_width"):
        if name == "ac143_3_last" and not expect_last:
            continue
        out(name, False, "ESC[?2026l が無い(1ティック未捕捉)")
    sys.exit(0)
S = data[:pos + len(END)]

# ① LF の個数
n_lf = S.count(b"\n")
out("ac143_1_lf", n_lf <= h - 1, "LF=%d h=%d" % (n_lf, h))

# ②③⑦ ESC シーケンス除去後の行
ESC_RE = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")
plain = ESC_RE.sub(b"", S).replace(b"\r", b"")
lines = plain.split(b"\n")
first = lines[0].decode("utf-8", "replace")
out("ac143_2_first", first == expect_first, first)
if expect_last:
    nonempty = [l for l in lines if l != b""]
    last = nonempty[-1].decode("utf-8", "replace") if nonempty else ""
    out("ac143_3_last", last == expect_last, last)

# ⑤ 最初の可視バイトより前に ESC[H か ESC[1;1H
SKIP_RE = re.compile(rb"(?:\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|[ \t\r\n])*")
p = SKIP_RE.match(S).end()
head = S[:p]
ok5 = (b"\x1b[H" in head) or (b"\x1b[1;1H" in head)
out("ac143_5_home", ok5, "prefix=%r" % head[:80])

# ⑥ LF 以外の縦移動バイト列を含まない（列挙固定・単純なバイト否定検査）
found = []
if b"\x0b" in S: found.append("VT")
if b"\x0c" in S: found.append("FF")
for m in re.finditer(rb"\x1b[DEM]", S): found.append("ESC %s" % m.group(0)[1:].decode())
for m in re.finditer(rb"\x1b\[[0-9;?]*[ABdEFeLMrST]", S): found.append(repr(m.group(0)))
for m in re.finditer(rb"\x1b\[([0-9;?]*)[Hf]", S):
    if m.group(1) not in (b"", b"1;1"): found.append(repr(m.group(0)))
out("ac143_6_no_vmove", not found, "none" if not found else ",".join(found[:5]))

# ⑦ 各行の表示幅 ≤ 40
def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
widths = [width(l.decode("utf-8", "replace")) for l in lines]
mx = max(widths) if widths else 0
out("ac143_7_width", mx <= 40, "max=%d" % mx)
PYEOF
}

# tick_check の出力から fail 行だけを返す（空なら全判定 pass）。
tick_fails() {
  tick_check "$@" | awk -F '\t' '$2 != "pass"'
}

# 常駐を h 行・幅 40 で起動し、最初の `ESC[?2026l` が現れるまで待って
# （0.1 秒間隔・最大 10 秒）TERM で止める。ログは $3 へ。
#   $1=供給側スタブのパス $2=h（空なら CMUX_NEXT_ROWS を渡さない＝WU-R）
#   $3=ログ $4=常駐スクリプト $5="setsid" なら新セッション（制御端末なし＝
#   /dev/tty が開けない＝WU-R）で起動する。macOS に setsid(1) は無いので
#   python3 の os.setsid()+execvp で代替。
# 戻り値: 0=捕捉できた／1=10 秒以内に描画が出なかった
# 呼び出し側の wait_pid_bounded（テスト本体で定義）を使う。
capture_first_tick() {
  local supply="$1" h="$2" log="$3" watch="$4" mode="${5:-}" pid waited=0 rc=1
  : > "$log"
  if [ "$mode" = "setsid" ]; then
    CMUX_DOCK_SUPPLY_PROJECT="$supply" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_ROWS="$h" CMUX_NEXT_COLS=40 \
      python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash "$watch" \
      >"$log" 2>/dev/null </dev/null &
  else
    CMUX_DOCK_SUPPLY_PROJECT="$supply" CMUX_NEXT_INTERVAL=1 CMUX_NEXT_ROWS="$h" CMUX_NEXT_COLS=40 \
      bash "$watch" >"$log" 2>/dev/null &
  fi
  pid=$!
  while [ "$waited" -lt 100 ]; do
    if grep -q "$(printf '\033')\[?2026l" "$log" 2>/dev/null; then rc=0; break; fi
    sleep 0.1; waited=$(( waited + 1 ))
  done
  kill -TERM "$pid" 2>/dev/null
  wait_pid_bounded "$pid" 100
  return "$rc"
}
