**English** | [日本語](#日本語)

# dotfiles

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Shell](https://img.shields.io/badge/shell-zsh-blue)
![License](https://img.shields.io/badge/license-MIT-green)

A collection of macOS configuration files for AI work (Claude Code / Codex).
It brings together terminal settings (Ghostty + tmux), Hammerspoon hotkeys (Keychron mouse + Nape Pro trackball) for controlling AI terminals, and a [`cmux`](https://cmux.io) integration suite (Dock status panes, Agent Teams launcher, notification filtering).

Environment: macOS (Apple Silicon)

---

## Directory map

```
dotfiles/
├── cmux/                          cmux (AI-terminal multiplexer) integration
│   ├── cmux.json                  cmux app config: notification filtering
│   ├── dock.json                  Dock pane definitions: Usage / Next / System (Usage's script lives in the sibling claude-codex-usage repo)
│   ├── claude-cmux-hooks.json     Claude Code hooks (turn-completion notify, feed log, etc.), injected via --settings
│   ├── claude-teams-launch.sh     Launches cmux + starts/attaches the Agent Teams "Supervisor" workspace
│   ├── claude-teams-entry.sh      Session picker (new vs. resume) invoked by claude-teams-launch.sh
│   ├── cmux-system-watch.sh       Dock pane: CPU/GPU/RAM/power (via macmon)
│   ├── cmux-feed-watch.sh         Dock pane: compact cmux workstream feed
│   ├── cmux-next-watch/           Dock pane: cross-project "next action" + external-brain health
│   │   ├── cmux-next-watch.sh
│   │   ├── README.md              Details for this pane
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
├── tests/                         Repo-level tests for install.sh behavior
│   └── test-zsh-aliases-source.sh
├── tmux/
│   └── tmux.conf                  prefix=Ctrl+a, directional splits, Shift+arrow movement, usage status bar, etc.
├── zsh/
│   └── aliases.zsh                cc/cct functions, source'd from ~/.zshrc (not symlinked; see below)
└── install.sh                     Installer: symlink each config, or append (zsh)
```

Usage-tracking (`claude-cache.json`/`codex-cache.json`, the refresh LaunchAgent, the tmux status-bar segment, and the `cmux-usage-watch.sh` script that `dock.json`'s Usage pane runs) lives entirely in the separate [`claude-codex-usage`](https://github.com/Takumi00Nine/claude-codex-usage) repository, not here.

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
| `cmux/cmux-next-watch/` | `~/work/tools/cmux-next-watch` | symlink (directory; `dock.json`'s "Next" pane points here) |
| `zsh/aliases.zsh` | end of `~/.zshrc` | **idempotent append** of a source line, not a symlink (see below) |

A few `cmux/` scripts are *not* symlinked individually: `claude-cmux-hooks.json`, `claude-teams-entry.sh`, `cmux-system-watch.sh`, `cmux-feed-watch.sh`, `layout-enforce.sh`, `lib-layout.sh`, `show-review.sh`. They're invoked directly from this repo's path (by `dock.json` commands, the `cct` alias's `--settings` flag, or `claude-teams-launch.sh`'s sibling-script resolution), which assumes the repo lives at `~/work/dotfiles`. `dock.json`'s Usage pane command points at `cmux-usage-watch.sh` in the separate `claude-codex-usage` repo instead (`~/work/claude-codex-usage/cmux-usage-watch.sh`) — that script and its LaunchAgent are not part of this repo.

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
- Usage stats (Claude/Codex usage bars, refresh LaunchAgent): install separately from the [`claude-codex-usage`](https://github.com/Takumi00Nine/claude-codex-usage) repo's own `install.sh`

---

## Configuration notes

### hammerspoon/
Hammerspoon configuration for controlling AI terminals with Keychron mouse buttons. F18 toggles video pause/resume + microphone (right command) + focuses the claude terminal; F17 brings the claude terminal to the front and sends Enter. See [`hammerspoon/README.md`](hammerspoon/README.md) for details. The `nape_pro/` module adds a full Nape Pro trackball keymap (01/02/M1/M2 + dial + combos); see [`hammerspoon/nape_pro/SETUP.md`](hammerspoon/nape_pro/SETUP.md).

### tmux/
- Changes prefix to `Ctrl+a` (while pressed, the session-name chip lights up red)
- `prefix + arrow` creates directional splits, and `Shift + arrow` moves between panes
- Always displays Claude / Codex usage in the status bar

> Warning: The status bar references `tmux-usage.sh` from a separate `claude-codex-usage` repository via a hardcoded absolute path in `status-right`. The bar will not appear unless that repository exists at the exact path baked into `tmux/tmux.conf`; adjust the path there for your own machine.

### ghostty/
- Catppuccin Mocha theme and `macos-option-as-alt` (Option shortcuts for Claude Code)
- Includes `start-tmux.sh`, which attaches to (or creates) a tmux session that follows the current cmux workspace name, falling back to session "ai" outside cmux — but auto-run on launch is **disabled by default** in `ghostty/config` (it conflicts with `cmux claude-teams`'s own tmux/pane management); uncomment the `command` line there to re-enable it for plain-Ghostty use
- Ghostty does not support end-of-line comments (write comments on their own lines)

### cmux/
Integration with the [`cmux`](https://cmux.io) terminal: notification filtering (`cmux.json`), three Dock status panes (Usage/Next/System, wired via `dock.json`), an Agent Teams launcher (`cmux-teams` -> `claude-teams-launch.sh`), and pane-layout helpers. See [`cmux/cmux-next-watch/README.md`](cmux/cmux-next-watch/README.md) for the Next pane's project/external-brain display. The Usage pane's rendering script and its refresh LaunchAgent live in the separate [`claude-codex-usage`](https://github.com/Takumi00Nine/claude-codex-usage) repo.

### zsh/
`cc` (`cd ~/Claude && claude`) and `cct` (`cd ~/Claude && cmux claude-teams ...`, with cmux notification-hook and `--teammate-mode in-process` injection unless the caller already passed one of those flags). See [zsh: append, not symlink](#zsh-append-not-symlink) above for how it gets wired into `~/.zshrc`.

---

## Tests

```sh
bash tests/test-zsh-aliases-source.sh
bash cmux/cmux-next-watch/tests/test-cmux-next-watch.sh

# Hammerspoon logic tests run under a plain Lua interpreter (no hs.* dependency);
# any Lua 5.x works, e.g. via anyenv: anyenv install luaenv && luaenv install 5.4.8
lua hammerspoon/tests/logic_spec.lua
lua hammerspoon/tests/nape_pro_smoke_spec.lua
```

(Usage-tracking tests live in the separate `claude-codex-usage` repo's own `test/test.sh`.)

---

## License
[MIT](LICENSE)

---

## 日本語

# dotfiles

AI 作業（Claude Code / Codex）まわりの macOS 設定ファイル集。
ターミナル（Ghostty + tmux）、Keychron マウス／Nape Pro トラックボールから AI 端末を操作する Hammerspoon ホットキー、[`cmux`](https://cmux.io) 統合（Dockステータスペイン・Agent Teams ランチャー・通知フィルタ）をまとめている。

環境: macOS (Apple Silicon)

---

## ディレクトリマップ

```
dotfiles/
├── cmux/                          cmux（AI端末マルチプレクサ）統合
│   ├── cmux.json                  cmuxアプリ設定: 通知フィルタ
│   ├── dock.json                  Dockペイン定義: Usage / Next / System（Usageのスクリプトは別リポジトリclaude-codex-usage側）
│   ├── claude-cmux-hooks.json     Claude Code フック（ターン完了通知・feedログ等）。--settingsで注入
│   ├── claude-teams-launch.sh     cmuxを起動しAgent Teamsの「Supervisor」ワークスペースを開始/復帰
│   ├── claude-teams-entry.sh      claude-teams-launch.shから呼ばれるセッション選択（新規/再開）
│   ├── cmux-system-watch.sh       Dockペイン: CPU/GPU/RAM/電力（macmon経由）
│   ├── cmux-feed-watch.sh         Dockペイン: cmuxワークストリームの簡易フィード表示
│   ├── cmux-next-watch/           Dockペイン: プロジェクト横断「次アクション」＋外部脳ヘルス
│   │   ├── cmux-next-watch.sh
│   │   ├── README.md              このペインの詳細
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
├── tests/                         install.shの挙動に対するリポジトリレベルのテスト
│   └── test-zsh-aliases-source.sh
├── tmux/
│   └── tmux.conf                  prefix=Ctrl+a, 方向分割, Shift+矢印移動, 使用率ステータスバー 等
├── zsh/
│   └── aliases.zsh                cc/cct関数。~/.zshrcからsourceされる（symlinkではない。後述）
└── install.sh                     インストーラ: 設定ごとにsymlink、またはappend（zsh）
```

使用率トラッキング（`claude-cache.json`/`codex-cache.json`・refresh用LaunchAgent・tmuxステータスバー表示・`dock.json`のUsageペインが起動する`cmux-usage-watch.sh`）は本リポジトリではなく、別リポジトリ [`claude-codex-usage`](https://github.com/Takumi00Nine/claude-codex-usage) 側に一本化されている。

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
| `cmux/cmux-next-watch/` | `~/work/tools/cmux-next-watch` | symlink（ディレクトリ。`dock.json`の「Next」ペインがこのパスを参照）|
| `zsh/aliases.zsh` | `~/.zshrc` 末尾 | **冪等追記**（symlinkではない。後述）|

`cmux/` の一部スクリプト（`claude-cmux-hooks.json`・`claude-teams-entry.sh`・`cmux-system-watch.sh`・`cmux-feed-watch.sh`・`layout-enforce.sh`・`lib-layout.sh`・`show-review.sh`）は個別にsymlinkされない。`dock.json`のコマンド・`cct`エイリアスの`--settings`・`claude-teams-launch.sh`の隣接スクリプト解決から、リポジトリのパス（`~/work/dotfiles`に置かれている前提）を直接参照して使われる。`dock.json`のUsageペインのcommandは別リポジトリ`claude-codex-usage`側の`cmux-usage-watch.sh`（`~/work/claude-codex-usage/cmux-usage-watch.sh`）を指しており、そのスクリプトと対応するLaunchAgentは本リポジトリには含まれない。

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
- 使用率まわり（Claude/Codex使用率バー・refresh用LaunchAgent）: 別リポジトリ [`claude-codex-usage`](https://github.com/Takumi00Nine/claude-codex-usage) 自身の `install.sh` で別途導入

---

## 各設定のメモ

### hammerspoon/
Keychron マウスのボタンで AI 端末を制御する Hammerspoon 設定。F18＝動画一時停止/再開＋マイク(右⌘)トグル＋claude端末フォーカス、F17＝claude端末を前面化して Enter 送信。詳細は [`hammerspoon/README.md`](hammerspoon/README.md)。`nape_pro/` モジュールに Nape Pro トラックボール向けの本格キーマップ(01/02/M1/M2 + ダイヤル + コンボ)を追加済み。セットアップ手順は [`hammerspoon/nape_pro/SETUP.md`](hammerspoon/nape_pro/SETUP.md)。

### tmux/
- prefix を `Ctrl+a` に変更（押下中はセッション名チップが赤く点灯）
- `prefix + 矢印` で方向分割、`Shift + 矢印` でペイン移動
- Claude / Codex の使用率をステータスバーに常時表示

> ⚠️ ステータスバーは別リポジトリ `claude-codex-usage` の `tmux-usage.sh` を、`tmux/tmux.conf` にハードコードされた絶対パスで参照する（`status-right`）。そのリポジトリがそのパスに無いとバーが出ない。自分の環境では `tmux/tmux.conf` 側のパスを書き換えること。

### ghostty/
- テーマ Catppuccin Mocha、`macos-option-as-alt`（Claude Code の Option ショートカット）
- `start-tmux.sh` を同梱（現在のcmuxワークスペース名に追従するtmuxセッションへ自動attach/作成。cmux外では"ai"にフォールバック）。ただし起動時の自動実行は `ghostty/config` で**既定では無効化**されている（`cmux claude-teams` 自身のtmux/ペイン管理と競合するため）。素のGhosttyで使う場合は同ファイルの `command` 行をコメント解除する
- ※ Ghostty は行末コメント非対応（コメントは独立行に書く）

### cmux/
[`cmux`](https://cmux.io) ターミナルとの統合。通知フィルタ（`cmux.json`）、3つのDockステータスペイン（Usage/Next/System、`dock.json`で配線）、Agent Teamsランチャー（`cmux-teams` → `claude-teams-launch.sh`）、ペインレイアウト補助スクリプト群。Nextペインの詳細は [`cmux/cmux-next-watch/README.md`](cmux/cmux-next-watch/README.md) 参照。Usageペインの描画スクリプトと対応するrefresh用LaunchAgentは別リポジトリ [`claude-codex-usage`](https://github.com/Takumi00Nine/claude-codex-usage) 側にある。

### zsh/
`cc`（`cd ~/Claude && claude`）と `cct`（`cd ~/Claude && cmux claude-teams ...`。呼び出し側が該当フラグを渡していなければcmux通知フックと`--teammate-mode in-process`を注入）を定義。`~/.zshrc` への配線方式は上の[「zsh: symlinkではなく追記」](#zsh-symlinkではなく追記)参照。

---

## テスト

```sh
bash tests/test-zsh-aliases-source.sh
bash cmux/cmux-next-watch/tests/test-cmux-next-watch.sh

# Hammerspoonのロジックテストは素のLuaインタプリタで動く（hs.*非依存）。
# Lua 5.x であればよい（例: anyenv経由 anyenv install luaenv && luaenv install 5.4.8）
lua hammerspoon/tests/logic_spec.lua
lua hammerspoon/tests/nape_pro_smoke_spec.lua
```

（使用率まわりのテストは別リポジトリ`claude-codex-usage`自身の`test/test.sh`にある。）

---

## ライセンス
[MIT](LICENSE)
