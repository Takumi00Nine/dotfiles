# dotfiles

AI 作業（Claude Code / Codex）まわりの macOS 設定ファイル集。
ターミナル（Ghostty + tmux）と、Keychron マウスから AI 端末を操作する Hammerspoon ホットキーをまとめている。

環境: macOS (Apple Silicon)

---

## 構成

```
dotfiles/
├── hammerspoon/
│   ├── init.lua        # Keychron マウス → AI 端末制御（F18: マイク/動画トグル, F17: Enter送信）
│   └── README.md       # ↑ の詳細ドキュメント
├── tmux/
│   └── tmux.conf       # prefix=Ctrl+a, 方向分割, Shift+矢印移動, 使用率ステータスバー 等
├── ghostty/
│   └── config          # テーマ/フォント, Option=Alt, 起動時に tmux "ai" へ自動 attach 等
└── install.sh          # 各設定を実体→ライブ位置へシンボリックリンク
```

各設定は **このリポジトリが実体**で、ライブの場所（`~/.tmux.conf` など）は**シンボリックリンク**にしている。
→ 編集はこのリポジトリ側だけで完結し、Git で履歴管理できる。

---

## セットアップ

```sh
git clone https://github.com/Takumi00Nine/dotfiles.git ~/work/dotfiles
cd ~/work/dotfiles
./install.sh
```

`install.sh` は次のシンボリックリンクを張る（既存の実ファイルは `*.pre-dotfiles.bak` に退避）:

| リポジトリ内 | ライブの場所 |
|---|---|
| `hammerspoon/init.lua` | `~/.hammerspoon/init.lua` |
| `tmux/tmux.conf` | `~/.tmux.conf` |
| `ghostty/config` | `~/.config/ghostty/config` |

反映:
- tmux: `tmux source-file ~/.tmux.conf`（または再起動）
- Hammerspoon: メニューバー 🔨 → Reload Config
- Ghostty: `Cmd+Shift+,`（または再起動）

---

## 各設定のメモ

### hammerspoon/
Keychron マウスのボタンで AI 端末を制御する Hammerspoon 設定。F18＝動画一時停止/再開＋マイク(右⌘)トグル＋claude端末フォーカス、F17＝claude端末を前面化して Enter 送信。詳細は [`hammerspoon/README.md`](hammerspoon/README.md)。

### tmux/
- prefix を `Ctrl+a` に変更（押下中はセッション名チップが赤く点灯）
- `prefix + 矢印` で方向分割、`Shift + 矢印` でペイン移動
- Claude / Codex の使用率をステータスバーに常時表示

> ⚠️ ステータスバーは別リポジトリ [`usage-statusline`](https://github.com/Takumi00Nine/usage-statusline) の `tmux-usage.sh` を参照する（`status-right` に絶対パスで指定）。そちらを `~/work/usage-statusline` に置いていないとバーが出ない。

### ghostty/
- テーマ Catppuccin Mocha、`macos-option-as-alt`（Claude Code の Option ショートカット）
- 起動時に `tmux new-session -A -s ai` で tmux セッション "ai" へ自動 attach/create
- ※ Ghostty は行末コメント非対応（コメントは独立行に書く）

---

## ライセンス
[MIT](LICENSE)
