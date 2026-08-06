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

echo
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
