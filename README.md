**English** | [日本語](#日本語)

# dotfiles

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Shell](https://img.shields.io/badge/shell-zsh-blue)
![License](https://img.shields.io/badge/license-MIT-green)

A collection of macOS configuration files for AI work (Claude Code / Codex).
It brings together terminal settings (Ghostty + tmux), Hammerspoon hotkeys (Keychron mouse + Nape Pro trackball) for controlling AI terminals, and a [`cmux`](https://cmux.com) integration suite (Dock status panes, Agent Teams launcher, notification filtering).

Environment: macOS (Apple Silicon)

---

## Directory map

```
dotfiles/
├── cmux/                          cmux (AI-terminal multiplexer) integration
│   ├── cmux.json                  cmux app config: notification filtering
│   ├── dock.json                  Dock pane definitions: Usage / Project / Task / System
│   ├── claude-cmux-hooks.json     Claude Code hooks (turn-completion notify, feed log, etc.), injected via --settings
│   ├── claude-teams-launch.sh     Launches cmux + starts/attaches the Agent Teams "Supervisor" workspace
│   ├── claude-teams-entry.sh      Session picker (new vs. resume) invoked by claude-teams-launch.sh
│   ├── cmux-usage-watch.sh        Dock pane: Claude/Codex usage bars (reads the cache JSON written by takumi009-ai-env's usage-fetch.sh)
│   ├── cmux-system-watch.sh       Dock pane: CPU/GPU/RAM/power (via macmon)
│   ├── cmux-feed-watch.sh         Dock pane: compact cmux workstream feed
│   ├── cmux-next-watch/           Dock pane: cross-project "next action" + external-brain health
│   │   ├── cmux-next-watch.sh
│   │   ├── README.md              Details for this pane
│   │   └── tests/
│   ├── cmux-dock-guard/           LaunchAgent: repairs a degraded Dock automatically after cmux relaunches
│   │   ├── cmux-dock-guard.sh
│   │   ├── README.md              Detection design, repair logic, env vars, known limitations
│   │   └── tests/
│   ├── layout-enforce.sh          One-shot pane-width enforcement (e.g. right after spawning a teammate)
│   ├── lib-layout.sh              Shared pane-width logic (sourced by layout-enforce.sh / show-review.sh)
│   └── show-review.sh             Shows a deliverable (Markdown/HTML/URL) in a review pane
├── ghostty/                       Ghostty terminal config + tmux/cmux session glue
│   ├── config
│   ├── start-tmux.sh              Attach to (or create) the tmux session matching the current cmux workspace
│   └── cmux-session-cleanup.sh    Kill orphaned tmux sessions whose cmux workspace no longer exists
├── hammerspoon/                   Keychron mouse / Nape Pro trackball -> AI terminal control
│   ├── init.lua                   F17/F18 hotkeys; wires nape_pro/ in
│   ├── README.md                  Details for init.lua (mic/video toggle, Enter send)
│   ├── nape_pro/                  Nape Pro trackball keymap (Stage 1: mic/Enter/YouTube/dial/combos)
│   │   ├── init.lua / logic.lua / cmux.lua / youtube.lua
│   │   └── SETUP.md               Launcher hardware setup + design notes + human-check script
│   └── tests/                     Plain-Lua unit + smoke tests (no hs.* dependency)
├── launchagents/                  LaunchAgent plist templates (install.sh fills in __DOTFILES_HOME__)
│   └── com.takumi009.cmux-dock-guard.plist.template
├── tests/                         Repo-level tests for install.sh behavior
│   ├── test-zsh-aliases-source.sh
│   └── test-cmux-dock-guard-launchagent.sh
├── tmux/
│   └── tmux.conf                  prefix=Ctrl+a, directional splits, Shift+arrow movement, etc.
├── zsh/
│   └── aliases.zsh                cc/cct functions, source'd from ~/.zshrc (not symlinked; see below)
└── install.sh                     Installer: symlink each config, or append (zsh)
```

Usage-tracking is split across two repos: this repo bundles the Dock-rendering script (`cmux/cmux-usage-watch.sh`, run by `dock.json`'s Usage pane) and reads the cache JSON (`claude-cache.json`/`codex-cache.json`) it's given; the cache-refresh LaunchAgent that actually fetches Claude/Codex usage and writes that cache lives in the separate `takumi009-ai-env` repo's `scripts/usage-fetch.sh` (LaunchAgent `com.takumi009.usage-fetch`). The old dedicated `claude-codex-usage` repo is retired.

---

## What each config controls, and where it lands

`install.sh` is idempotent (safe to re-run) and drives every mapping below. For symlinked entries, an existing real file or directory at the destination is backed up once as `<dest>.pre-dotfiles.bak` (it refuses to run again if a backup already exists there, rather than silently overwriting it) before being replaced.

| Repository path | Live location | Method |
|---|---|---|
| `hammerspoon/init.lua` | `~/.hammerspoon/init.lua` | symlink |
| `hammerspoon/nape_pro/` | `~/.hammerspoon/nape_pro` | symlink (directory) |
| `tmux/tmux.conf` | `~/.tmux.conf` | symlink |
| `ghostty/config` | `~/.config/ghostty/config` | symlink |
| `ghostty/start-tmux.sh` | `~/.config/ghostty/start-tmux.sh` | symlink |
| `ghostty/cmux-session-cleanup.sh` | `~/.config/ghostty/cmux-session-cleanup.sh` | symlink |
| `cmux/claude-teams-launch.sh` | `~/.local/bin/cmux-teams` | symlink |
| `cmux/cmux.json` | `~/.config/cmux/cmux.json` | symlink |
| `cmux/dock.json` | `~/.config/cmux/dock.json` | symlink |
| `launchagents/com.takumi009.cmux-dock-guard.plist.template` | `~/Library/LaunchAgents/com.takumi009.cmux-dock-guard.plist` | generated (template with `__DOTFILES_HOME__` filled in) + `launchctl` (re)load, unless `SKIP_LAUNCHCTL=1` |
| `zsh/aliases.zsh` | end of `~/.zshrc` | **idempotent append** of a source line, not a symlink (see below) |

A few `cmux/` scripts are *not* symlinked individually: `claude-cmux-hooks.json`, `claude-teams-entry.sh`, `cmux-usage-watch.sh`, `cmux-system-watch.sh`, `cmux-feed-watch.sh`, `layout-enforce.sh`, `lib-layout.sh`, `show-review.sh`, `cmux-dock-guard/cmux-dock-guard.sh`, `cmux-next-watch/cmux-next-watch.sh`, `cmux-task-watch/cmux-task-watch.sh`. They're invoked directly from this repo's path (by `dock.json` commands, the `cct` alias's `--settings` flag, `claude-teams-launch.sh`'s sibling-script resolution, or the `cmux-dock-guard` LaunchAgent's `ProgramArguments`), which assumes the repo lives at `~/work/dotfiles`. `dock.json`'s Project, Task, and Usage panes point directly at `$HOME/work/dotfiles/cmux/cmux-next-watch/cmux-next-watch.sh`, `$HOME/work/dotfiles/cmux/cmux-task-watch/cmux-task-watch.sh`, and `$HOME/work/dotfiles/cmux/cmux-usage-watch.sh`; Project and Task each receive a supply-side frame from the separate `takumi009-ai-env` repo (see `cmux/cmux-task-watch/README.md` / `cmux/cmux-next-watch/README.md`), and Usage reads the cache JSON that `takumi009-ai-env`'s `scripts/usage-fetch.sh` writes — no `~/work/tools/` symlink is created or required for any of the three panes. The old dedicated `claude-codex-usage` repo that used to hold `cmux-usage-watch.sh` and its LaunchAgent is retired.

### zsh: append, not symlink
`zsh/aliases.zsh` defines `cc`/`cct`. Instead of symlinking a whole `.zshrc` (which would clobber machine-specific setup like `anyenv`/`compinit`), `install.sh` idempotently appends a single marked source line (`# dotfiles-managed`) to the end of `~/.zshrc`. Existing `~/.zshrc` content is never modified or reordered, and re-running `install.sh` does not duplicate the line.

---

## Setup

```sh
git clone https://github.com/Takumi00Nine/dotfiles.git ~/work/dotfiles
cd ~/work/dotfiles
./install.sh
```

Apply changes:
- tmux: `tmux source-file ~/.tmux.conf` (or restart)
- Hammerspoon: menu bar hammer icon -> Reload Config
- Ghostty: `Cmd+Shift+,` (or restart)
- zsh: `cc`/`cct` source line added to `~/.zshrc` if missing (restart the shell, or `source ~/.zshrc`)
- cmux Dock guard: LaunchAgent (re)loaded automatically by `install.sh` (set `SKIP_LAUNCHCTL=1` to only generate the plist without touching `launchctl`, e.g. for testing)
- Usage stats: the Dock bars (`cmux-usage-watch.sh`) are installed by this repo's `install.sh` above; the cache-refresh LaunchAgent that feeds them is installed separately via the `takumi009-ai-env` repo's `scripts/install-usage-fetch.sh`

---

## Configuration notes

### hammerspoon/
Hammerspoon configuration for controlling AI terminals with Keychron mouse buttons. F18 toggles video pause/resume + microphone (right command) + focuses the claude terminal; F17 brings the claude terminal to the front and sends Enter. See [`hammerspoon/README.md`](hammerspoon/README.md) for details. The `nape_pro/` module adds a full Nape Pro trackball keymap (01/02/M1/M2 + dial + combos); see [`hammerspoon/nape_pro/SETUP.md`](hammerspoon/nape_pro/SETUP.md).

### tmux/
- Changes prefix to `Ctrl+a` (while pressed, the session-name chip lights up red)
- `prefix + arrow` creates directional splits, and `Shift + arrow` moves between panes

### ghostty/
- Catppuccin Mocha theme and `macos-option-as-alt` (Option shortcuts for Claude Code)
- Includes `start-tmux.sh`, which attaches to (or creates) a tmux session that follows the current cmux workspace name, falling back to session "ai" outside cmux — but auto-run on launch is **disabled by default** in `ghostty/config` (it conflicts with `cmux claude-teams`'s own tmux/pane management); uncomment the `command` line there to re-enable it for plain-Ghostty use
- Ghostty does not support end-of-line comments (write comments on their own lines)

### cmux/
Integration with the [`cmux`](https://cmux.com) terminal: notification filtering (`cmux.json`), four Dock status panes (Usage/Project/Task/System, wired via `dock.json`), an Agent Teams launcher (`cmux-teams` -> `claude-teams-launch.sh`), and pane-layout helpers. See [`cmux/cmux-next-watch/README.md`](cmux/cmux-next-watch/README.md) for the Project pane's project/external-brain display. The Usage pane's rendering script (`cmux-usage-watch.sh`) is bundled in this repo; its cache-refresh LaunchAgent lives in the separate `takumi009-ai-env` repo (`scripts/usage-fetch.sh`, LaunchAgent `com.takumi009.usage-fetch`) — the old dedicated `claude-codex-usage` repo is retired. See [`cmux/cmux-dock-guard/README.md`](cmux/cmux-dock-guard/README.md) for the LaunchAgent that automatically repairs a degraded Dock after cmux relaunches.

### zsh/
`cc` (`cd ~/Claude && claude`) and `cct` (`cd ~/Claude && cmux claude-teams ...`, with cmux notification-hook and `--teammate-mode in-process` injection unless the caller already passed one of those flags). See [zsh: append, not symlink](#zsh-append-not-symlink) above for how it gets wired into `~/.zshrc`.

---

## Tests

```sh
bash tests/test-zsh-aliases-source.sh
bash tests/test-cmux-dock-guard-launchagent.sh
bash cmux/cmux-next-watch/tests/test-cmux-next-watch.sh
bash cmux/cmux-dock-guard/tests/test-cmux-dock-guard.sh

# Hammerspoon logic tests run under a plain Lua interpreter (no hs.* dependency);
# any Lua 5.x works, e.g. via anyenv: anyenv install luaenv && luaenv install 5.4.8
lua hammerspoon/tests/logic_spec.lua
lua hammerspoon/tests/nape_pro_smoke_spec.lua
```

(`cmux-usage-watch.sh`'s Dock-rendering tests live in this repo's `tests/test-cmux-dock-json.sh`; the cache-refresh side's tests live in the separate `takumi009-ai-env` repo. The old dedicated `claude-codex-usage` repo and its `test/test.sh` are retired.)

---

## License
[MIT](LICENSE)

---

## 日本語

# dotfiles

AI 作業（Claude Code / Codex）まわりの macOS 設定ファイル集。
ターミナル（Ghostty + tmux）、Keychron マウス／Nape Pro トラックボールから AI 端末を操作する Hammerspoon ホットキー、[`cmux`](https://cmux.com) 統合（Dockステータスペイン・Agent Teams ランチャー・通知フィルタ）をまとめている。

環境: macOS (Apple Silicon)

---

## ディレクトリマップ

```
dotfiles/
├── cmux/                          cmux（AI端末マルチプレクサ）統合
│   ├── cmux.json                  cmuxアプリ設定: 通知フィルタ
│   ├── dock.json                  Dockペイン定義: Usage / Project / Task / System
│   ├── claude-cmux-hooks.json     Claude Code フック（ターン完了通知・feedログ等）。--settingsで注入
│   ├── claude-teams-launch.sh     cmuxを起動しAgent Teamsの「Supervisor」ワークスペースを開始/復帰
│   ├── claude-teams-entry.sh      claude-teams-launch.shから呼ばれるセッション選択（新規/再開）
│   ├── cmux-usage-watch.sh        Dockペイン: Claude/Codex使用率バー（takumi009-ai-envのusage-fetch.shが書くキャッシュJSONを読む）
│   ├── cmux-system-watch.sh       Dockペイン: CPU/GPU/RAM/電力（macmon経由）
│   ├── cmux-feed-watch.sh         Dockペイン: cmuxワークストリームの簡易フィード表示
│   ├── cmux-next-watch/           Dockペイン: プロジェクト横断「次アクション」＋外部脳ヘルス
│   │   ├── cmux-next-watch.sh
│   │   ├── README.md              このペインの詳細
│   │   └── tests/
│   ├── cmux-dock-guard/           LaunchAgent: cmux再起動後に劣化したDockを自動修復
│   │   ├── cmux-dock-guard.sh
│   │   ├── README.md              検知方式・修復ロジック・環境変数・既知の制約
│   │   └── tests/
│   ├── layout-enforce.sh          ペイン幅の単発矯正（チームメイト起動直後等）
│   ├── lib-layout.sh              ペイン幅ロジック共通部（layout-enforce.sh / show-review.shからsource）
│   └── show-review.sh             成果物（Markdown/HTML/URL）をレビュー用ペインに表示
├── ghostty/                       Ghosttyターミナル設定＋tmux/cmuxセッション連携
│   ├── config
│   ├── start-tmux.sh              現在のcmuxワークスペース名に追従するtmuxセッションへattach/作成
│   └── cmux-session-cleanup.sh    対応するcmuxワークスペースが無くなったtmuxセッションを掃除
├── hammerspoon/                   Keychronマウス／Nape Proトラックボール → AI端末制御
│   ├── init.lua                   F17/F18ホットキー。nape_pro/を配線
│   ├── README.md                  init.luaの詳細（マイク/動画トグル・Enter送信）
│   ├── nape_pro/                  Nape Proトラックボール向けキーマップ（Stage 1: マイク/Enter/YouTube/ダイヤル/コンボ）
│   │   ├── init.lua / logic.lua / cmux.lua / youtube.lua
│   │   └── SETUP.md               Launcherハード設定手順＋設計判断＋人間チェック台本
│   └── tests/                     素のLuaで動く単体・スモークテスト（hs.*非依存）
├── launchagents/                  LaunchAgent plistテンプレート（install.shが__DOTFILES_HOME__を実HOMEへ展開）
│   └── com.takumi009.cmux-dock-guard.plist.template
├── tests/                         install.shの挙動に対するリポジトリレベルのテスト
│   ├── test-zsh-aliases-source.sh
│   └── test-cmux-dock-guard-launchagent.sh
├── tmux/
│   └── tmux.conf                  prefix=Ctrl+a, 方向分割, Shift+矢印移動 等
├── zsh/
│   └── aliases.zsh                cc/cct関数。~/.zshrcからsourceされる（symlinkではない。後述）
└── install.sh                     インストーラ: 設定ごとにsymlink、またはappend（zsh）
```

使用率トラッキングは2リポジトリに分かれている：本リポジトリにはDock描画スクリプト（`cmux/cmux-usage-watch.sh`・`dock.json`のUsageペインが起動）が同梱され、渡されたキャッシュJSON（`claude-cache.json`/`codex-cache.json`）を読むだけ。実際にClaude/Codexの使用率を取得しそのキャッシュを書くrefresh用LaunchAgentは、別リポジトリ`takumi009-ai-env`側の`scripts/usage-fetch.sh`（LaunchAgent `com.takumi009.usage-fetch`）にある。旧・専用リポジトリ`claude-codex-usage`は退役済み。

---

## 各設定が何を制御し、どこへ入るか

`install.sh` は冪等（再実行安全）で、以下の対応表を全て担当する。symlinkする対象については、既存の実ファイル・実ディレクトリが置換先にある場合、置換前に一度だけ `<dest>.pre-dotfiles.bak` へ退避する（退避先が既に存在する場合は黙って上書きせず、エラーで停止する）。

| リポジトリ内 | ライブの場所 | 方式 |
|---|---|---|
| `hammerspoon/init.lua` | `~/.hammerspoon/init.lua` | symlink |
| `hammerspoon/nape_pro/` | `~/.hammerspoon/nape_pro` | symlink（ディレクトリ）|
| `tmux/tmux.conf` | `~/.tmux.conf` | symlink |
| `ghostty/config` | `~/.config/ghostty/config` | symlink |
| `ghostty/start-tmux.sh` | `~/.config/ghostty/start-tmux.sh` | symlink |
| `ghostty/cmux-session-cleanup.sh` | `~/.config/ghostty/cmux-session-cleanup.sh` | symlink |
| `cmux/claude-teams-launch.sh` | `~/.local/bin/cmux-teams` | symlink |
| `cmux/cmux.json` | `~/.config/cmux/cmux.json` | symlink |
| `cmux/dock.json` | `~/.config/cmux/dock.json` | symlink |
| `launchagents/com.takumi009.cmux-dock-guard.plist.template` | `~/Library/LaunchAgents/com.takumi009.cmux-dock-guard.plist` | 生成（`__DOTFILES_HOME__`をテンプレート展開）＋`launchctl`で(再)登録。`SKIP_LAUNCHCTL=1`で登録のみskip |
| `zsh/aliases.zsh` | `~/.zshrc` 末尾 | **冪等追記**（symlinkではない。後述）|

`cmux/` の一部スクリプト（`claude-cmux-hooks.json`・`claude-teams-entry.sh`・`cmux-usage-watch.sh`・`cmux-system-watch.sh`・`cmux-feed-watch.sh`・`layout-enforce.sh`・`lib-layout.sh`・`show-review.sh`・`cmux-dock-guard/cmux-dock-guard.sh`・`cmux-next-watch/cmux-next-watch.sh`・`cmux-task-watch/cmux-task-watch.sh`）は個別にsymlinkされない。`dock.json`のコマンド・`cct`エイリアスの`--settings`・`claude-teams-launch.sh`の隣接スクリプト解決・`cmux-dock-guard` LaunchAgentの`ProgramArguments`から、リポジトリのパス（`~/work/dotfiles`に置かれている前提）を直接参照して使われる。`dock.json`のProject・Task・Usageの3枠は `$HOME/work/dotfiles/cmux/cmux-next-watch/cmux-next-watch.sh`・`$HOME/work/dotfiles/cmux/cmux-task-watch/cmux-task-watch.sh`・`$HOME/work/dotfiles/cmux/cmux-usage-watch.sh` を直接指す。Project・Taskは別リポジトリ`takumi009-ai-env`から供給側のフレームを受け取って描くだけ（詳細は`cmux/cmux-task-watch/README.md`・`cmux/cmux-next-watch/README.md`）、Usageは同じく`takumi009-ai-env`の`scripts/usage-fetch.sh`が書くキャッシュJSONを読むだけで、3枠ともに`~/work/tools/`のsymlinkは作らない・要らない。`cmux-usage-watch.sh`と対応するLaunchAgentを持っていた旧・専用リポジトリ`claude-codex-usage`は退役済み。

### zsh: symlinkではなく追記
`zsh/aliases.zsh` は `cc`/`cct` を定義する。`.zshrc` 全体をsymlinkすると `anyenv`/`compinit` 等マシン固有の設定を壊すため、`install.sh` は目印コメント（`# dotfiles-managed`）付きのsource行1行だけを `~/.zshrc` 末尾へ冪等に追記する。既存の `~/.zshrc` 内容は一切変更・並べ替えせず、再実行しても二重追記しない。

---

## セットアップ

```sh
git clone https://github.com/Takumi00Nine/dotfiles.git ~/work/dotfiles
cd ~/work/dotfiles
./install.sh
```

反映:
- tmux: `tmux source-file ~/.tmux.conf`（または再起動）
- Hammerspoon: メニューバー 🔨 → Reload Config
- Ghostty: `Cmd+Shift+,`（または再起動）
- zsh: `cc`/`cct` のsource行が無ければ `~/.zshrc` に追記済み（シェル再起動、または `source ~/.zshrc`）
- cmux Dock guard: LaunchAgentは`install.sh`が自動で(再)登録（`SKIP_LAUNCHCTL=1`でplist生成のみ・登録skip。テスト用）
- 使用率まわり: Dockバー（`cmux-usage-watch.sh`）は上記の本リポジトリの`install.sh`で導入済み。バーへキャッシュを供給するrefresh用LaunchAgentは別リポジトリ`takumi009-ai-env`の`scripts/install-usage-fetch.sh`で別途導入

---

## 各設定のメモ

### hammerspoon/
Keychron マウスのボタンで AI 端末を制御する Hammerspoon 設定。F18＝動画一時停止/再開＋マイク(右⌘)トグル＋claude端末フォーカス、F17＝claude端末を前面化して Enter 送信。詳細は [`hammerspoon/README.md`](hammerspoon/README.md)。`nape_pro/` モジュールに Nape Pro トラックボール向けの本格キーマップ(01/02/M1/M2 + ダイヤル + コンボ)を追加済み。セットアップ手順は [`hammerspoon/nape_pro/SETUP.md`](hammerspoon/nape_pro/SETUP.md)。

### tmux/
- prefix を `Ctrl+a` に変更（押下中はセッション名チップが赤く点灯）
- `prefix + 矢印` で方向分割、`Shift + 矢印` でペイン移動

### ghostty/
- テーマ Catppuccin Mocha、`macos-option-as-alt`（Claude Code の Option ショートカット）
- `start-tmux.sh` を同梱（現在のcmuxワークスペース名に追従するtmuxセッションへ自動attach/作成。cmux外では"ai"にフォールバック）。ただし起動時の自動実行は `ghostty/config` で**既定では無効化**されている（`cmux claude-teams` 自身のtmux/ペイン管理と競合するため）。素のGhosttyで使う場合は同ファイルの `command` 行をコメント解除する
- ※ Ghostty は行末コメント非対応（コメントは独立行に書く）

### cmux/
[`cmux`](https://cmux.com) ターミナルとの統合。通知フィルタ（`cmux.json`）、4つのDockステータスペイン（Usage/Project/Task/System、`dock.json`で配線）、Agent Teamsランチャー（`cmux-teams` → `claude-teams-launch.sh`）、ペインレイアウト補助スクリプト群。Projectペインの詳細は [`cmux/cmux-next-watch/README.md`](cmux/cmux-next-watch/README.md) 参照。Usageペインの描画スクリプト（`cmux-usage-watch.sh`）は本リポジトリに同梱。対応するrefresh用LaunchAgentは別リポジトリ`takumi009-ai-env`側（`scripts/usage-fetch.sh`・LaunchAgent `com.takumi009.usage-fetch`）にある。旧・専用リポジトリ`claude-codex-usage`は退役済み。cmux再起動後にDockが壊れたままにならないよう自動修復するLaunchAgentの詳細は [`cmux/cmux-dock-guard/README.md`](cmux/cmux-dock-guard/README.md) 参照。

### zsh/
`cc`（`cd ~/Claude && claude`）と `cct`（`cd ~/Claude && cmux claude-teams ...`。呼び出し側が該当フラグを渡していなければcmux通知フックと`--teammate-mode in-process`を注入）を定義。`~/.zshrc` への配線方式は上の[「zsh: symlinkではなく追記」](#zsh-symlinkではなく追記)参照。

---

## テスト

```sh
bash tests/test-zsh-aliases-source.sh
bash tests/test-cmux-dock-guard-launchagent.sh
bash cmux/cmux-next-watch/tests/test-cmux-next-watch.sh
bash cmux/cmux-dock-guard/tests/test-cmux-dock-guard.sh

# Hammerspoonのロジックテストは素のLuaインタプリタで動く（hs.*非依存）。
# Lua 5.x であればよい（例: anyenv経由 anyenv install luaenv && luaenv install 5.4.8）
lua hammerspoon/tests/logic_spec.lua
lua hammerspoon/tests/nape_pro_smoke_spec.lua
```

（`cmux-usage-watch.sh`のDock描画テストは本リポジトリの`tests/test-cmux-dock-json.sh`にある。キャッシュ取得側のテストは別リポジトリ`takumi009-ai-env`にある。旧・専用リポジトリ`claude-codex-usage`と`test/test.sh`は退役済み。）

---

## ライセンス
[MIT](LICENSE)
