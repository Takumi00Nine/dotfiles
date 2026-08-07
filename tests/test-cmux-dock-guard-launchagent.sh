#!/usr/bin/env bash
# install.sh の cmux-dock-guard LaunchAgent 設置ロジック（テンプレート展開・
# launchctlタイムアウト）のユニットテスト。
#
# 実HOME・実launchd・実cmuxには一切依存しない。HOME はテストごとに使い捨ての
# FAKE_HOMEへ差し替え、launchctlはPATH上のシムに置き換える。
#
# 実行方法: bash tests/test-cmux-dock-guard-launchagent.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail_case "$desc (expected=$expected actual=$actual)"; fi
}

DEST_PLIST_REL="Library/LaunchAgents/com.takumi009.cmux-dock-guard.plist"

echo "=== (a) SKIP_LAUNCHCTL=1なら実launchdへ一切触れずplistだけ生成される ==="
{
  FAKE_HOME="$(mktemp -d)"
  rc=0
  out=$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" 2>&1) || rc=$?
  DEST="$FAKE_HOME/$DEST_PLIST_REL"
  assert_eq "install.sh自体はexit 0で完走する" "0" "$rc"
  assert_true "plistが生成される" "$([ -f "$DEST" ] && echo 1 || echo 0)"
  assert_true "プレースホルダ__DOTFILES_HOME__が残っていない" \
    "$(grep -q '__DOTFILES_HOME__' "$DEST" && echo 0 || echo 1)"
  assert_true "FAKE_HOMEの実パスに置換されている(cmux-dock-guard.sh本体を直接指す)" \
    "$(grep -qF "$FAKE_HOME/work/dotfiles/cmux/cmux-dock-guard/cmux-dock-guard.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "WatchPathsはcmuxソケットのディレクトリ(ファイル単体ではない)を指す" \
    "$(grep -qF "$FAKE_HOME/.local/state/cmux</string>" "$DEST" && echo 1 || echo 0)"
  assert_true "StartIntervalの安全網(60秒)が入っている" \
    "$(grep -qF '<integer>60</integer>' "$DEST" && echo 1 || echo 0)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "生成されたplistはplutil -lintを通過する" \
      "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  else
    echo "  SKIP: このホストにplutilが無いためlint検証を省略"
  fi
  assert_true "SKIP_LAUNCHCTL=1のためlaunchctlへの実操作はskipされる" \
    "$(echo "$out" | grep -q 'SKIP_LAUNCHCTL=1のため' && echo 1 || echo 0)"
  assert_true "launchctlという単語がどこにも出力されない(実操作ゼロの確認)" \
    "$(echo "$out" | grep -qi 'launchctl bootstrap\|launchctl bootout\|launchctl enable\|launchctl kickstart' && echo 0 || echo 1)"

  rm -rf "$FAKE_HOME"
}

echo "=== (b) launchctl bootstrapがハングしてもタイムアウトで抜け、孫プロセスも残らない ==="
{
  FAKE_HOME="$(mktemp -d)"

  # bootstrapサブコマンドだけSIGTERMを無視して孫プロセス(sleep)を起動し待ち続ける
  # 偽launchctl。他のサブコマンド(bootout/enable/kickstart)は即座に成功する。
  STUB_BIN="$(mktemp -d)"
  CHILD_PID_FILE="$(mktemp)"
  cat > "$STUB_BIN/launchctl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "bootstrap" ]; then
    trap '' TERM
    sleep 100 &
    echo "\$!" > "$CHILD_PID_FILE"
    wait "\$!"
    exit 0
  fi
done
exit 0
EOF
  chmod +x "$STUB_BIN/launchctl"

  START=$(date +%s)
  rc=0
  out=$(HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" LAUNCHCTL_TIMEOUT_SECS=2 \
    bash "$INSTALL_SH" 2>&1) || rc=$?
  END=$(date +%s)
  ELAPSED=$((END - START))

  assert_eq "bootstrapがハングしてもinstall.sh自体はexit 0で完走する(fail-open)" "0" "$rc"
  assert_true "タイムアウト秒数+余裕(15秒)以内に終了する(ハングしない)" \
    "$([ "$ELAPSED" -le 15 ] && echo 1 || echo 0)"
  assert_true "タイムアウトのWARNメッセージが出る" \
    "$(echo "$out" | grep -q 'WARN: launchd bootstrap failed or timed out' && echo 1 || echo 0)"

  sleep 1
  GRANDCHILD_PID="$(cat "$CHILD_PID_FILE" 2>/dev/null || true)"
  assert_true "孫プロセス(sleep)のPIDが記録されている(テスト自体が意図通り動いた確認)" \
    "$([ -n "$GRANDCHILD_PID" ] && echo 1 || echo 0)"
  assert_true "TERMを無視する孫プロセスもプロセスグループごとKILLされ残骸が無い" \
    "$(! kill -0 "$GRANDCHILD_PID" 2>/dev/null && echo 1 || echo 0)"
  if [ -n "$GRANDCHILD_PID" ] && kill -0 "$GRANDCHILD_PID" 2>/dev/null; then
    kill -KILL "$GRANDCHILD_PID" 2>/dev/null || true
  fi

  rm -rf "$FAKE_HOME" "$STUB_BIN"
  rm -f "$CHILD_PID_FILE"
}

echo "=== (c) 冪等性: 2回実行しても同じplistになり残骸(一時ファイル)が残らない ==="
{
  FAKE_HOME="$(mktemp -d)"
  HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1
  DEST="$FAKE_HOME/$DEST_PLIST_REL"
  first_sum="$(shasum "$DEST" | awk '{print $1}')"
  HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1
  second_sum="$(shasum "$DEST" | awk '{print $1}')"
  assert_eq "2回目実行後もplist内容は同一" "$first_sum" "$second_sum"
  assert_true "生成時の一時ファイル(.dotfiles-tmp)が残らない" \
    "$(find "$(dirname "$DEST")" -name '*.dotfiles-tmp.*' | grep -q . && echo 0 || echo 1)"
  rm -rf "$FAKE_HOME"
}

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
