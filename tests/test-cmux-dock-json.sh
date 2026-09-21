#!/usr/bin/env bash
# cmux/dock.json の Dock コントロール定義（特に Usage 枠 = cmux-usage-watch.sh）の
# 回帰テスト。cmux-usage-watch.sh は旧 claude-codex-usage リポジトリ（退役済み）
# から本リポジトリへ取り込んだもの（2026-09-18）。
#
# 実HOME・実launchd・実cmuxソケットには一切依存しない。dock.json の読み取り元は
# 既定でREPO_ROOT（このテスト自身のcheckout）。DOTFILES_DIR 環境変数を渡すと
# そちらへ差し替えられる（実HOME本体 $HOME/work/dotfiles を明示的に見たいとき
# 用）。$HOME 自体は展開するが、そのままだと dock.json 中の
# "$HOME/work/dotfiles/..." が実リポジトリを指してしまうので、その接頭辞だけ
# DOTFILES_DIR に読み替えてから存在確認する。
#
# 実行方法:
#   bash tests/test-cmux-dock-json.sh
#   DOTFILES_DIR=~/work/dotfiles bash tests/test-cmux-dock-json.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$REPO_ROOT}"
# 環境変数前置（"NAME=値 ..."）の剥がしは cmux-dock-guard.sh の strip_env_prefix
# が正本（v6 FR-115・設計 §41.3.4 案A）。ここで自前の規則を持たず、guardを
# sourceして同じ関数を使う（guardは直接実行時だけmainを走らせるsourceガード
# 済み。sourceは DOCK_JSON 等の変数を上書きするので、このテスト自身の変数を
# 定義する前に行う）。
GUARD_SCRIPT="$DOTFILES_DIR/cmux/cmux-dock-guard/cmux-dock-guard.sh"
# shellcheck source=../cmux/cmux-dock-guard/cmux-dock-guard.sh
. "$GUARD_SCRIPT"
if ! command -v strip_env_prefix >/dev/null 2>&1; then
  echo "NG - cmux-dock-guard.sh に strip_env_prefix が無い ($GUARD_SCRIPT)"
  exit 1
fi
# 既定はREPO_ROOT（このテスト自身のcheckout）配下のdock.json/スクリプトを読む。
# 実HOME本体（$HOME/work/dotfiles）を明示的に見たいときだけDOTFILES_DIRを渡す。
DOCK_JSON="$DOTFILES_DIR/cmux/dock.json"
USAGE_SCRIPT="$DOTFILES_DIR/cmux/cmux-usage-watch.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail_case() { FAIL=$((FAIL + 1)); echo "  NG - $1"; }
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then pass "$desc"; else fail_case "$desc"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq が無いためこのテストは実行できません"
  exit 0
fi

echo "=== 前提: DOTFILES_DIR=$DOTFILES_DIR の dock.json が読める ==="
{
  assert_true "dock.jsonが存在する ($DOCK_JSON)" \
    "$([ -f "$DOCK_JSON" ] && echo 1 || echo 0)"
  assert_true "dock.jsonが妥当なJSON" \
    "$(jq -e . "$DOCK_JSON" >/dev/null 2>&1 && echo 1 || echo 0)"
}

echo "=== (a) dock.jsonの全controlのcommand(\$HOME展開後)が実在し実行可能 ==="
{
  assert_true "strip_env_prefix: 複数の環境変数接頭辞(A=1 B_2=x)を剥がして実行ファイルだけ残す" \
    "$([ "$(strip_env_prefix 'A=1 B_2=x $HOME/work/dotfiles/x')" = '$HOME/work/dotfiles/x' ] && echo 1 || echo 0)"
  assert_true "strip_env_prefix: 接頭辞のみ(A=1)で本体が無ければそのまま返す" \
    "$([ "$(strip_env_prefix 'A=1')" = 'A=1' ] && echo 1 || echo 0)"
  assert_true "strip_env_prefix: 先頭が数字(1A=1)は識別子でないため剥がさずそのまま返す" \
    "$([ "$(strip_env_prefix '1A=1 cmd')" = '1A=1 cmd' ] && echo 1 || echo 0)"
  assert_true "strip_env_prefix: 接頭辞の後ろが連続空白(2個)でも先頭空白を落として実行ファイルだけ残す" \
    "$([ "$(strip_env_prefix 'A=1  $HOME/work/dotfiles/x')" = '$HOME/work/dotfiles/x' ] && echo 1 || echo 0)"
  assert_true "strip_env_prefix: 接頭辞と本体の間がTABでも実行ファイルだけ残す" \
    "$([ "$(strip_env_prefix "$(printf 'A=1\t$HOME/work/dotfiles/x')")" = '$HOME/work/dotfiles/x' ] && echo 1 || echo 0)"

  ids="$(jq -r '.controls[].id' "$DOCK_JSON" 2>/dev/null)"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    raw_cmd="$(jq -r --arg id "$id" '.controls[] | select(.id==$id) | .command' "$DOCK_JSON")"
    cmd="$(strip_env_prefix "$raw_cmd")"
    # "$HOME/work/dotfiles" の接頭辞だけ DOTFILES_DIR に読み替える
    # (worktreeで走らせたとき、実HOME配下の本体リポジトリではなくworktree自身を
    # 指すようにするため。それ以外の$HOME展開は通常のシェル展開に任せる)。
    case "$cmd" in
      '$HOME/work/dotfiles/'*)
        rel="${cmd#\$HOME/work/dotfiles/}"
        resolved="$DOTFILES_DIR/$rel"
        ;;
      *)
        resolved="$(eval echo "$cmd")"
        ;;
    esac
    assert_true "control[$id]のcommandが実在するファイル ($resolved)" \
      "$([ -f "$resolved" ] && echo 1 || echo 0)"
    assert_true "control[$id]のcommandが実行可能 ($resolved)" \
      "$([ -x "$resolved" ] && echo 1 || echo 0)"
    if [ "$id" = "task" ]; then
      assert_true "control[task]のcommand先頭の環境変数接頭辞(例:CMUX_DOCK_MAX_COLS=35)を剥がした後の実行ファイルがcmux-task-watch.shの実パスと一致 ($resolved)" \
        "$([ "$resolved" = "$DOTFILES_DIR/cmux/cmux-task-watch/cmux-task-watch.sh" ] && echo 1 || echo 0)"
    fi
    # Project枠（id=next）。v6 S6-2 で幅の上限の前置（Task枠と同じ形）を置く
    # 予定だが、前置は必須にしない（設計 DT-32＝配置前後の両方で通る）。
    if [ "$id" = "next" ]; then
      assert_true "control[next]のcommand先頭の環境変数接頭辞(あれば)を剥がした後の実行ファイルがcmux-next-watch.shの実パスと一致 ($resolved)" \
        "$([ "$resolved" = "$DOTFILES_DIR/cmux/cmux-next-watch/cmux-next-watch.sh" ] && echo 1 || echo 0)"
    fi
  done <<< "$ids"
}

echo "=== (b) Usageのcommandがcmux-usage-watch.shを指す ==="
{
  usage_cmd="$(jq -r '.controls[] | select(.id=="usage") | .command' "$DOCK_JSON")"
  points_to_script=0
  case "$usage_cmd" in
    */cmux-usage-watch.sh) points_to_script=1 ;;
  esac
  assert_true "Usageのcommandがcmux-usage-watch.shを指す ($usage_cmd)" "$points_to_script"

  no_old_repo_ref=1
  case "$usage_cmd" in
    *claude-codex-usage*) no_old_repo_ref=0 ;;
  esac
  assert_true "Usageのcommandが claude-codex-usage リポジトリを指していない(退役済み参照が残っていない)" "$no_old_repo_ref"
}

echo "=== (c) cmux-usage-watch.shがbash -nを通る ==="
{
  assert_true "cmux-usage-watch.shが存在する ($USAGE_SCRIPT)" \
    "$([ -f "$USAGE_SCRIPT" ] && echo 1 || echo 0)"
  assert_true "cmux-usage-watch.shがbash -nを通る(構文エラー無し)" \
    "$(bash -n "$USAGE_SCRIPT" 2>/dev/null && echo 1 || echo 0)"
}

echo "=== (d) キャッシュ不在時、cmux-usage-watch.shが即死せず何か表示する ==="
{
  # 実 XDG_CACHE_HOME を汚さないよう使い捨てのFAKE_CACHEへ差し替える。
  # CMUX_USAGE_INTERVAL=1で高速ループさせ、外側をタイムアウトで打ち切る
  # (このスクリプトはmain()がwhileで永久ループするため、--onceを付けない
  # 限りタイムアウトで止めるしかない=タイムアウトによる強制終了そのものが
  # 「即死しない」ことの確認になる)。
  FAKE_CACHE="$(mktemp -d)"

  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  fi

  if [ -n "$TIMEOUT_BIN" ]; then
    out="$(XDG_CACHE_HOME="$FAKE_CACHE" CMUX_USAGE_INTERVAL=1 \
      "$TIMEOUT_BIN" 3 bash "$USAGE_SCRIPT" 2>&1)"
    rc=$?
    assert_true "${TIMEOUT_BIN}経由でexit 124(タイムアウトで打ち切り=即死していない)" \
      "$([ "$rc" -eq 124 ] && echo 1 || echo 0)"
  else
    out="$(XDG_CACHE_HOME="$FAKE_CACHE" CMUX_USAGE_INTERVAL=1 \
      perl -e 'my $s = shift; alarm $s; exec @ARGV' 3 bash "$USAGE_SCRIPT" 2>&1)"
    rc=$?
    # perl経由だとSIGALRM(14)で強制終了するのでexit codeは142(128+14)。
    # timeoutコマンドが無い環境向けの代替経路であることをそのまま記録する。
    assert_true "perl alarm経由でSIGALRMにより強制終了(exit 142。即死していない=タイムアウトまで生存)" \
      "$([ "$rc" -eq 142 ] && echo 1 || echo 0)"
  fi

  assert_true "出力が非空(即死してエラーだけで落ちていない)" \
    "$([ -n "$out" ] && echo 1 || echo 0)"
  assert_true "キャッシュ不在時の 'n/a' 系プレースホルダ表示が出る" \
    "$(printf '%s' "$out" | grep -q 'n/a' && echo 1 || echo 0)"
  assert_true "Claude行のヘッダーが出る" \
    "$(printf '%s' "$out" | grep -q 'Claude' && echo 1 || echo 0)"
  assert_true "Codex行のヘッダーが出る" \
    "$(printf '%s' "$out" | grep -q 'Codex' && echo 1 || echo 0)"

  rm -rf "$FAKE_CACHE"
}

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
