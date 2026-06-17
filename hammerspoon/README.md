# mic-video-toggle

Keychron マウスのボタン1つで「**YouTube動画の一時停止／再開 ＋ Codexマイクのトグル ＋ Claudeターミナルのフォーカス**」をまとめて行う仕組み。

作成日: 2026-06-16 / 環境: macOS (Darwin 25.x, Apple Silicon)

---

## やりたかったこと

動画（Chrome の YouTube）を見ながら作業していて、マイク（Codex、右Commandでトグル）を使うたびに毎回手動で動画を止めるのが面倒だった。それを **1ボタンで自動化**する。

ボタン（= `F18`）を押したときの挙動:

| 操作 | 動画が再生中だった | 動画が止まっていた／無い |
|---|---|---|
| **マイクON**（奇数回目の押下） | 動画を一時停止 → マイクON（端末へはフォーカスを移さない） | 動画はそのまま → マイクON（端末へはフォーカスを移さない） |
| **マイクOFF**（偶数回目の押下） | マイクOFF → （自分が止めた動画だけ）再生再開 → Claude端末を前面に | マイクOFF → Claude端末を前面に |

ポイント:
- **再生中の動画だけ止める**（toggleではなく `video.pause()` を直接呼ぶので、止まっている動画を誤って再生開始しない）。
- **自分が止めた動画だけ再生を戻す**（止めた動画に `window.__pausedByMic` フラグを付け、OFF時はそのフラグ付きだけ `play()`）。
- **マイクをOFFにしてから動画の音を戻す**（マイクが生きてるうちに動画音を拾わないよう、OFFは「マイクOFF → 0.15秒 → 再生再開」の順）。
- **端末フォーカスはマイクOFF時にだけ行う**（ON時は今いる画面のまま喋れる／OFFで `claude` 端末がアクティブになる）。
- **`claude` が動いているペイン/タブだけ**を前面＆入力状態にする（Ghostty+tmux 優先、Terminal.app フォールバック）。

---

## 構成（3パーツ）

### 1. Keychron Launcher（マウス側）
- 対象ボタンに **`KC_F18`**（メインのトグル）を割り当てる（KEYMAP → ボタン選択 → `ANY` → `KC_F18` を入力 → 保存）。
- 別のボタンに **`KC_F17`** を割り当てると、「claude 端末を前面化して **Enter 送信**」ができる（プロンプト送信・確認用）。
- `F17`/`F18` は普段使わない安全な空きキーなので採用。マウスは「ただのトリガー」で、条件分岐の処理は全部 Hammerspoon 側が担当する。

### ボタンの役割まとめ
| キー | 動作 |
|---|---|
| **F18** | 動画一時停止/再開 ＋ マイク(右⌘)トグル ＋（OFF時に）claude 端末を前面化 |
| **F17** | claude 端末を前面化してから **Enter を送信** |

### 2. Hammerspoon（Mac側のロジック）
- 設定ファイル: `~/.hammerspoon/init.lua` は本フォルダの `init.lua` への**シンボリックリンク**（実体＝このリポジトリが正）。編集はリポジトリ側のみで、Reload Config すれば反映される（コピー不要）。
- `F18` を待ち受けて、動画制御・マイク送出・端末フォーカスを実行する。
- 反映: Hammerspoon メニュー（🔨）→ **Reload Config**。
- **端末フォーカスは Ghostty + tmux に対応**（Terminal.app へフォールバック）。まず `tmux list-panes -a` で `pane_current_command` に `claude` を含むペインを探し、`select-window`/`select-pane` で選択 → `hs.application.launchOrFocus("Ghostty")` で前面化。tmux 上に claude ペインが無ければ、従来の Terminal.app ロジックにフォールバックする。tmux パスは `/opt/homebrew/bin/tmux` 前提。

### 3. Chrome（再生状態の読み取り許可）
- メニューバー **表示 → デベロッパー → 「Apple Events からの JavaScript を許可」** に ✓ を入れる。
  - ※ Chrome を最前面にしないとこのメニューは出ない。設定画面内の「サイトのJavaScript許可」とは**別物**なので注意。
- これが無いと AppleScript から動画の再生状態を読めず、**動画制御だけが効かない**（マイクのトグルは動く）。

---

## 必要な権限（macOS）

システム設定 → プライバシーとセキュリティ:
- **アクセシビリティ**: Hammerspoon を許可（合成キー `右Command` の送出に必要）
- **オートメーション**: Hammerspoon → **Google Chrome** を許可（初回ボタン押下時にダイアログが出る）。**Terminal** は Terminal.app フォールバックを使う場合のみ必要。
  - ※ Ghostty への前面化は `tmux` CLI ＋ `launchOrFocus`（アクセシビリティ）で行うため、Ghostty 向けのオートメーション許可は不要。

---

## キー仕様メモ
- 右Command の keycode = **54**（`hs.eventtap.event.newKeyEvent(54, ...)`）。
- ディレイ = `hs.timer.usleep(150000)` = **0.15秒**（ON/OFF とも同じ）。数値を変えれば調整可。
- Claude端末の判定（Ghostty+tmux）= tmux の各ペインの `pane_current_command` に **"claude"** が含まれるか（実機では `claude.exe` として見える）。該当ペインを `select-window`/`select-pane` で選び、Ghostty を前面化。
- フォールバック（Terminal.app）= 各タブの `processes` に **"claude"** が含まれるか。自分用ターミナルは zsh なので対象外。

---

## 既知の注意点 / トラブルシュート
- **マイクON/OFFは必ずこのボタンで行う。** Hammerspoon が `micOn` を自前で数えているため、途中で右Commandを直接押したり動画を手動操作すると状態がズレることがある。ズレたらボタンを1回空押しすれば復帰。
- **マイクは切り替わるが動画が止まらない** → Chrome のオートメーション権限、または「Apple Events からの JavaScript を許可」が未設定。
- **動画は止まるがマイクが反応しない** → 合成した右Command を Codex が受け付けていない可能性。送出方法の調整が必要。
- **再生再開だけ効かない** → Chrome の自動再生制限。タブを一瞬アクティブにしてから `play()` する等の対処を追加する。
- **自分用ターミナルが前面に来てしまう** → 判定 "claude" の調整が必要（プロセス名が変わった場合など）。Ghostty の場合は `tmux list-panes -a -F '#{pane_current_command}'` で実際の名前を確認する。
- **Ghostty なのに前面化しない / Terminal が出る** → tmux に claude ペインが見つからずフォールバックした可能性。`tmux list-panes -a` で claude ペインの有無、`/opt/homebrew/bin/tmux` のパス、claude が tmux 内で動いているかを確認。

---

## ファイル
- `init.lua` — Hammerspoon 設定の**実体**。`~/.hammerspoon/init.lua` がこのファイルへのシンボリックリンクになっている（`ln -sf "$PWD/init.lua" ~/.hammerspoon/init.lua`）。編集後は Hammerspoon の Reload Config で反映。
  - リンクを張り直す場合: `ln -sf /Users/takumi009/work/mic-video-toggle/init.lua ~/.hammerspoon/init.lua`
  - 旧コピー運用に戻す場合: `cp /Users/takumi009/work/mic-video-toggle/init.lua ~/.hammerspoon/init.lua`（バックアップ: `~/.hammerspoon/init.lua.pre-symlink.bak`）
