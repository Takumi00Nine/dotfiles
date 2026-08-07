#!/usr/bin/env bash
# install.sh の append_zsh_aliases_source()（~/.zshrc への cc/cct source行の
# 冪等追記）のユニットテスト。
#
# 実 ~/.zshrc には一切依存しない。HOME はテストごとに使い捨てのFAKE_HOMEへ
# 差し替える。
#
# 実行方法: bash tests/test-zsh-aliases-source.sh

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

MARKER="# dotfiles-managed"

echo "=== (a) 初回実行でsource行が1行入る ==="
{
  FAKE_HOME="$(mktemp -d)"
  printf '# 既存の.zshrc\nexport FOO=bar\n' > "$FAKE_HOME/.zshrc"

  rc=0
  out=$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" 2>&1) || rc=$?
  ZSHRC="$FAKE_HOME/.zshrc"
  COUNT="$(grep -cF "$MARKER" "$ZSHRC" || true)"

  assert_eq "install.sh自体はexit 0で完走する" "0" "$rc"
  assert_eq "目印付きsource行が1行だけ入る" "1" "$COUNT"
  assert_true "source行がaliases.zshを指している" \
    "$(grep -qF 'work/dotfiles/zsh/aliases.zsh' "$ZSHRC" && echo 1 || echo 0)"
  assert_true "追記メッセージが出る" \
    "$(echo "$out" | grep -q 'appended:.*aliases.zsh source line' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== (b) 3回連続実行しても1行のまま（冪等） ==="
{
  FAKE_HOME="$(mktemp -d)"
  printf '# 既存の.zshrc\n' > "$FAKE_HOME/.zshrc"

  for i in 1 2 3; do
    HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1
  done
  COUNT="$(grep -cF "$MARKER" "$FAKE_HOME/.zshrc" || true)"
  assert_eq "3回実行しても目印付きsource行は1行のまま" "1" "$COUNT"

  out3=$(HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" 2>&1)
  assert_true "4回目はskipメッセージが出る" \
    "$(echo "$out3" | grep -q 'skip: ~/.zshrcには既に' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== (c) .zshrcが存在しない場合は新規作成される ==="
{
  FAKE_HOME="$(mktemp -d)"
  # .zshrcを意図的に作らない

  rc=0
  HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1 || rc=$?
  ZSHRC="$FAKE_HOME/.zshrc"

  assert_eq "install.sh自体はexit 0で完走する" "0" "$rc"
  assert_true ".zshrcが新規作成される" "$([ -f "$ZSHRC" ] && echo 1 || echo 0)"
  assert_true "作成された.zshrcにsource行が入っている" \
    "$(grep -qF "$MARKER" "$ZSHRC" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

echo "=== (d) 既存の.zshrc内容が変更・並べ替えされずに保全される ==="
{
  FAKE_HOME="$(mktemp -d)"
  cat > "$FAKE_HOME/.zshrc" <<'EOF'
# anyenv
export PATH="$HOME/.anyenv/bin:$PATH"
eval "$(anyenv init -)"

alias ll='ls -la'
EOF
  ORIG_HEAD="$(head -n 5 "$FAKE_HOME/.zshrc")"

  HOME="$FAKE_HOME" SKIP_LAUNCHCTL=1 bash "$INSTALL_SH" >/dev/null 2>&1
  NEW_HEAD="$(head -n 5 "$FAKE_HOME/.zshrc")"

  assert_eq "先頭5行(既存内容)が一切変更されない" "$ORIG_HEAD" "$NEW_HEAD"
  assert_true "source行は末尾に追記される（既存行より後ろに出現）" \
    "$(tail -n 3 "$FAKE_HOME/.zshrc" | grep -qF "$MARKER" && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME"
}

# cct の argv 実測テスト((e)(f)(g))共通のセットアップ。
# - cmuxはPATH上のstubへ差し替える。ただし実cmuxパネル内で実行すると
#   CMUX_BUNDLED_CLI_PATH が既に実バイナリを指しており、cct内の
#   `${CMUX_BUNDLED_CLI_PATH:-cmux}` がPATH解決を経ずそちらを直接使って
#   しまう（=このstubを迂回して実cmuxを起動しかねない・実測して判明した
#   罠）。空に上書きしてPATH経由でstubを解決させる。
# - HOMEもFAKE_HOMEへ隔離する（cctは`cd ~/Claude`するため、実`~/Claude`の
#   有無や実`~/work/dotfiles/cmux/claude-cmux-hooks.json`の有無に結果が
#   依存しないようにする。Codexレビュー2026-08-07指摘）。
# - stdinも/dev/nullへ明示的に切る（何らかの理由で実バイナリが起動した
#   場合に標準入力待ちでハングするのを避ける保険）。
run_cct_argv() {
  local fake_home="$1" stubdir="$2" argv_log="$3"
  shift 3
  PATH="$stubdir:$PATH" CMUX_ARGV_LOG="$argv_log" CMUX_BUNDLED_CLI_PATH= HOME="$fake_home" zsh -c '
    source "'"$REPO_ROOT"'/zsh/aliases.zsh"
    cct "$@" >/dev/null 2>&1
    cat "$CMUX_ARGV_LOG"
  ' _ "$@" < /dev/null
}

echo "=== (e) cct: --teammate-mode省略時は既定で --teammate-mode in-process が注入される ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Claude"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/cmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CMUX_ARGV_LOG"
EOF
  chmod +x "$STUBDIR/cmux"
  ARGV_LOG="$(mktemp)"

  ARGV_OUT="$(run_cct_argv "$FAKE_HOME" "$STUBDIR" "$ARGV_LOG" foo bar)"

  assert_true "既定でmode_argsに--teammate-modeが注入される" \
    "$(echo "$ARGV_OUT" | grep -qF -- '--teammate-mode' && echo 1 || echo 0)"
  assert_true "既定注入の値はin-process" \
    "$(echo "$ARGV_OUT" | grep -A1 -- '--teammate-mode' | tail -n1 | grep -qF 'in-process' && echo 1 || echo 0)"
  assert_true "呼び出し側の引数(foo bar)もそのまま渡される" \
    "$(echo "$ARGV_OUT" | grep -qF 'foo' && echo "$ARGV_OUT" | grep -qF 'bar' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUBDIR"
  rm -f "$ARGV_LOG"
}

echo "=== (f) cct: 呼び出し側が --teammate-mode を明示したら既定注入を譲る ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Claude"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/cmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CMUX_ARGV_LOG"
EOF
  chmod +x "$STUBDIR/cmux"
  ARGV_LOG="$(mktemp)"

  ARGV_OUT="$(run_cct_argv "$FAKE_HOME" "$STUBDIR" "$ARGV_LOG" --teammate-mode auto)"

  assert_true "--teammate-mode auto を明示したら既定のin-process注入は入らない" \
    "$(echo "$ARGV_OUT" | grep -qF 'in-process' && echo 0 || echo 1)"
  assert_true "呼び出し側の--teammate-mode autoはそのまま渡される" \
    "$(echo "$ARGV_OUT" | grep -qF -- '--teammate-mode' && echo "$ARGV_OUT" | grep -qF 'auto' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUBDIR"
  rm -f "$ARGV_LOG"
}

echo "=== (g) cct: -- 以降の引数は --teammate-mode に見えても明示指定と誤判定しない ==="
{
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/Claude"
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/cmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CMUX_ARGV_LOG"
EOF
  chmod +x "$STUBDIR/cmux"
  ARGV_LOG="$(mktemp)"

  ARGV_OUT="$(run_cct_argv "$FAKE_HOME" "$STUBDIR" "$ARGV_LOG" -- --teammate-mode is-a-prompt-not-a-flag)"

  assert_true "-- 以降の文字列に惑わされず既定のin-process注入が入る" \
    "$(echo "$ARGV_OUT" | grep -qF 'in-process' && echo 1 || echo 0)"
  assert_true "-- とその後の引数(プロンプト)はそのまま渡される" \
    "$(echo "$ARGV_OUT" | grep -qxF -- '--' && echo "$ARGV_OUT" | grep -qF 'is-a-prompt-not-a-flag' && echo 1 || echo 0)"

  rm -rf "$FAKE_HOME" "$STUBDIR"
  rm -f "$ARGV_LOG"
}

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
