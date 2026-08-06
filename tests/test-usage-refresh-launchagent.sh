#!/usr/bin/env bash
# install.sh の usage-refresh LaunchAgent 設置ロジック（テンプレート展開・
# 前提ガード・launchctlタイムアウト）のユニットテスト。
#
# 実HOME・実launchd・実claude-codex-usageには一切依存しない。HOME はテストごとに
# 使い捨てのFAKE_HOMEへ差し替え、launchctlはPATH上のシムに置き換える。
#
# 実行方法: bash tests/test-usage-refresh-launchagent.sh

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
  if [ "$cond" = "1" ]; then
    pass "$desc"
  else
    fail_case "$desc"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail_case "$desc (expected=$expected actual=$actual)"
  fi
}

# make_fake_home <dir>: install.sh の他のlinkターゲット(~/.hammerspoon等)も
# 一緒に作られるが、実システムには一切影響しない使い捨てディレクトリなので
# 特別な準備は不要（mkdirはinstall.sh自身が行う）。
DEST_PLIST_REL="Library/LaunchAgents/com.takumi009.usage-refresh.plist"

echo "=== (a) claude-codex-usage/refresh.sh が無いマシンではskipする ==="
{
  FAKE_HOME="$(mktemp -d)"
  rc=0
  out=$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" 2>&1) || rc=$?
  assert_eq "install.sh自体はexit 0で完走する" "0" "$rc"
  assert_true "plistは生成されない" \
    "$([ ! -e "$FAKE_HOME/$DEST_PLIST_REL" ] && echo 1 || echo 0)"
  assert_true "skipメッセージが出る" \
    "$(echo "$out" | grep -q 'skip: usage-refresh LaunchAgent' && echo 1 || echo 0)"
  assert_true "bootstrapは試みられない" \
    "$(echo "$out" | grep -qi 'bootstrap' && echo 0 || echo 1)"
  rm -rf "$FAKE_HOME"
}

echo "=== (b) refresh.sh が存在する場合はプレースホルダの残らないplistが生成される ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/work/claude-codex-usage"
  cat > "$FAKE_HOME/work/claude-codex-usage/refresh.sh" <<'EOF'
#!/usr/bin/env bash
echo fake-refresh
EOF
  chmod +x "$FAKE_HOME/work/claude-codex-usage/refresh.sh"

  rc=0
  out=$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" 2>&1) || rc=$?
  DEST="$FAKE_HOME/$DEST_PLIST_REL"
  assert_eq "install.sh自体はexit 0で完走する" "0" "$rc"
  assert_true "plistが生成される" "$([ -f "$DEST" ] && echo 1 || echo 0)"
  assert_true "プレースホルダ__DOTFILES_HOME__が残っていない" \
    "$(grep -q '__DOTFILES_HOME__' "$DEST" && echo 0 || echo 1)"
  assert_true "FAKE_HOMEの実パスに置換されている" \
    "$(grep -qF "$FAKE_HOME/work/claude-codex-usage/refresh.sh" "$DEST" && echo 1 || echo 0)"
  assert_true "PATHのnodenv shimsもFAKE_HOME起点で生成される" \
    "$(grep -qF "$FAKE_HOME/.anyenv/envs/nodenv/shims" "$DEST" && echo 1 || echo 0)"
  if command -v plutil >/dev/null 2>&1; then
    assert_true "生成されたplistはplutil -lintを通過する" \
      "$(plutil -lint "$DEST" >/dev/null 2>&1 && echo 1 || echo 0)"
  else
    echo "  SKIP: このホストにplutilが無いためlint検証を省略"
  fi
  assert_true "SKIP_LAUNCHCTL=1のためlaunchctlへの実操作はskipされる" \
    "$(echo "$out" | grep -q 'SKIP_LAUNCHCTL=1のため' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== (c) launchctl bootstrapがハングしてもタイムアウトで抜け、孫プロセスも残らない ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/work/claude-codex-usage"
  cat > "$FAKE_HOME/work/claude-codex-usage/refresh.sh" <<'EOF'
#!/usr/bin/env bash
echo fake-refresh
EOF
  chmod +x "$FAKE_HOME/work/claude-codex-usage/refresh.sh"

  # bootstrapサブコマンドだけSIGTERMを無視して孫プロセス(sleep)を起動し待ち続ける
  # 偽launchctl。他のサブコマンド(bootout/enable/kickstart)は即座に成功する
  # （テストの主眼はbootstrapのハングからの回復と孫プロセスの後始末の両方の検証）。
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

echo "=== (d) 冪等性: 2回実行しても同じ結果になり残骸(一時ファイル)が残らない ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/work/claude-codex-usage"
  cat > "$FAKE_HOME/work/claude-codex-usage/refresh.sh" <<'EOF'
#!/usr/bin/env bash
echo fake-refresh
EOF
  chmod +x "$FAKE_HOME/work/claude-codex-usage/refresh.sh"
  DEST="$FAKE_HOME/$DEST_PLIST_REL"

  rc1=0
  HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1 || rc1=$?
  CONTENT1="$(cat "$DEST")"
  rc2=0
  HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1 || rc2=$?
  CONTENT2="$(cat "$DEST")"

  assert_eq "1回目もexit 0" "0" "$rc1"
  assert_eq "2回目もexit 0" "0" "$rc2"
  assert_eq "2回実行しても生成内容が同一" "$CONTENT1" "$CONTENT2"
  assert_true "一時ファイル(.dotfiles-tmp)が残っていない" \
    "$([ -z "$(find "$FAKE_HOME/Library/LaunchAgents" -name '*.dotfiles-tmp.*' 2>/dev/null)" ] && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== (e) 生成後のplistがXMLとして壊れている場合はplutil -lintで検出しWARNしてlaunchdへ登録しない ==="
{
  if ! command -v plutil >/dev/null 2>&1; then
    echo "  SKIP: このホストにplutilが無いため省略"
  else
    # install.shはDIR相対で自分のlaunchagents/を参照するため、リポジトリ全体を
    # 使い捨てディレクトリへコピーし、コピー側のテンプレートだけを壊す
    # （リポジトリ本体（gitで追跡されているファイル）には一切触れない。
    # install.sh本体だけをコピーする案だと、末尾のchmod +xが他ファイルの実在を
    # 前提にしていて無関係な理由で失敗するため、リポジトリ全体をコピーする）。
    MINI_REPO="$(mktemp -d)"
    cp -R "$REPO_ROOT/." "$MINI_REPO/"
    rm -rf "$MINI_REPO/.git"
    # DTD宣言の途中でファイルを打ち切り、意図的に不正なXMLにする
    # （plutil -lintが「XMLとして壊れている」ことを検出できるかを検証する。
    # 単なる末尾ゴミの付与ではplutilは寛容に通してしまうことを実測済みのため、
    # 文書途中で打ち切る形で壊す）。
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"' \
      > "$MINI_REPO/launchagents/com.takumi009.usage-refresh.plist.template"

    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/work/claude-codex-usage"
    cat > "$FAKE_HOME/work/claude-codex-usage/refresh.sh" <<'EOF'
#!/usr/bin/env bash
echo fake-refresh
EOF
    chmod +x "$FAKE_HOME/work/claude-codex-usage/refresh.sh"

    rc=0
    out=$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$MINI_REPO/install.sh" 2>&1) || rc=$?
    DEST="$FAKE_HOME/$DEST_PLIST_REL"

    assert_eq "壊れたplistでもinstall.sh自体はexit 0で完走する" "0" "$rc"
    assert_true "plutil -lint失敗のWARNメッセージが出る" \
      "$(echo "$out" | grep -q 'WARN:.*plutil -lint' && echo 1 || echo 0)"
    assert_true "不正なplistはlaunchdへの登録を試みない（bootstrapのWARNは出ない）" \
      "$(echo "$out" | grep -q 'bootstrap failed or timed out' && echo 0 || echo 1)"

    rm -rf "$MINI_REPO" "$FAKE_HOME"
  fi
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
