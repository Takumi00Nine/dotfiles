# cmux-dock-guard

cmux を Cmd+Q で終了して手動で再起動したあと、何も操作しなくても Dock
（`~/.config/cmux/dock.json` の Usage / Next / System の3コントロール）が
復元されている状態にするための常駐修復ツール（目安60秒以内）。

## 背景

cmux 0.64系の仕様（[docs/dock.md](https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/dock.md)）:

- `dock.json` は初回シード専用。Dock のスナップショット（前回終了時の状態）
  があればそちらが優先され、config は再適用されない。
- Dock のコマンドプロセスが死ぬと、そのペインは対話ログインシェルへ降格する
  だけで、自動的に dock.json から再シードされることはない。
- 上流issue [#2544](https://github.com/manaflow-ai/cmux/issues/2544)（セッション
  復元時のコマンド自動再開）は未解決。

このため、何らかの理由でDockコマンドが落ちた状態のままcmuxを終了・再起動
すると、再起動後もDockは壊れたまま（降格シェルのまま）になる。
cmux-dock-guard はこれをLaunchAgentとして常駐監視し、劣化を検知したら自動で
直す。

## 起動検知

cmuxのソケット/ロックファイルが入る `~/.local/state/cmux/` ディレクトリを
launchdの`WatchPaths`で監視する。cmux再起動のたびにソケットファイル自体は
unlink+再作成されるが、**launchdはWatchPathsに指定したパスそのものが消える
と監視対象から外し、後で同じパスが再作成されても監視を復活させない仕様**
（[参考](https://managingosx.wordpress.com/2006/05/10/launchd-gotcha/)）のため、
ソケットファイル単体ではなく、それが入っている**ディレクトリ**を監視対象に
している（ディレクトリ自体は消えないので、中身の増減で確実に発火する）。

これに加えて`StartInterval`（60秒間隔）のポーリングを安全網として併用する
（WatchPathsの取りこぼし対策）。両経路とも同じスクリプトを呼び、スクリプト
自身が「cmux起動インスタンスごとに最大1回」しか判定・修復しないため、
安全網が余分に発火しても実害はない（後述）。

## 動作

1. `ps`でcmux.appプロセスのPID・起動時刻を取得し「起動インスタンス」を
   識別する。見つからなければ（cmux未起動の通常状態）何もせず終了する。
2. このインスタンスが判定済み（状態ファイルに記録済み）なら何もしない
   （WatchPathsの多重発火・StartIntervalの空振り対策）。
3. `cmux ping`でソケットが応答するか確認する（appプロセスはあるが起動途中で
   まだソケットが上がっていない場合は、マーカーを書かずに次回の発火に委ねる）。
4. settle待ち（既定30秒）してから健全性を判定する。次の**両方**が揃って
   初めて健全とみなす:
   - title判定: `dock.json`の各controlの`title`が、`cmux --json tree --all`
     が返す`dock_scope=="global"`なサーフェスのいずれかのtitleとして
     観測できる。ペインが存在しない（閉じられている）場合もここで不一致に
     なる。
   - プロセス判定: `dock.json`の各controlの`command`（実行ファイルパスの
     basenameを抽出）に対応するプロセスが`pgrep -f`で実際に見つかる。
     リーダー実測（2026-08-07）: Dockコマンドのプロセスをkillした直後・
     cmux再起動を挟まない場合、サーフェスのtitleは古い値のまま変化しない
     （降格した対話シェルなのに表示は「Usage」のまま）。title判定だけでは
     この状態を健全と誤判定してしまうため、独立した第2の軸として持つ。
5. 劣化を検知したら、誤検知防御のため間隔（既定15秒）を空けてもう一度判定
   する（起動直後は一時的に汎用タイトルになりうる観測があるため）。
6. 2回連続で劣化を確認した場合のみ、新ウィンドウ方式で修復する: `cmux
   new-window`（スナップショットの無い新ウィンドウはdock.jsonから再シード
   される）→ 既存の全ウィンドウの全ワークスペースを新ウィンドウへ
   `move-workspace-to-window`で移動 → 旧ウィンドウを`close-window`で閉鎖
   （旧ウィンドウ側にワークスペース移動の過程で自動生成される空
   ワークスペースは、旧ウィンドウごと閉鎖されるので個別の移動・掃除は
   不要）→ 新ウィンドウ側の初期空ワークスペースだけ`cmux workspace close`
   で掃除（他に本物のワークスペースが無い退化ケースでは空にしないよう残す）。
   （`cmux reload-config`による再シードは検討したが、実機実験（2026-08-07・
   本人kill→リーダー実測）で劣化したDockを再シードしないことが確定した
   ため、修復手段には含めていない。）
7. 修復の成否によらず、このインスタンスへの再試行はしない（暴走防止。次に
   cmuxが再起動されるまで待つ）。**この設計の帰結として、cmux起動後に本人が
   Dockペインを手動で閉じても、そのセッション中はガードが再介入することは
   ない**（Usage/Next/Systemを常設インフラとして必ず復元させるのは、あくまで
   次にcmuxを起動した時点での評価に限る）。通知は出さない（📣は本人呼び出し
   専用運用のため）。

## 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `CMUX_DOCK_GUARD_CMUX_BIN` | `cmux` | 呼び出すcmux CLI（テスト用差し替え口） |
| `CMUX_DOCK_GUARD_DOCK_JSON` | `~/.config/cmux/dock.json` | 期待タイトルの取得元 |
| `CMUX_DOCK_GUARD_STATE_DIR` | `~/.local/state/cmux-dock-guard` | ログ・ロック・マーカーの置き場所 |
| `CMUX_DOCK_GUARD_APP_PATH` | `/Applications/cmux.app/Contents/MacOS/cmux` | 起動インスタンス識別に使うcmux.appプロセスの実行パス |
| `CMUX_DOCK_GUARD_SETTLE_SECS` | `30` | 起動検知後、1回目の判定までの待ち |
| `CMUX_DOCK_GUARD_RECHECK_GAP_SECS` | `15` | 1回目劣化検知後、2回目判定までの待ち（誤検知防御） |
| `CMUX_DOCK_GUARD_POST_REPAIR_SECS` | `5` | 各修復手段の実行後、再判定までの待ち |
| `CMUX_DOCK_GUARD_LOCK_STALE_SECS` | `120` | この秒数を超えて残るロックは前回のクラッシュ跡とみなし奪取する |

## ログ・状態

`~/.local/state/cmux-dock-guard/` 配下:

- `guard.log`: 判定・修復の経過（タイムスタンプ付き、構造化テキスト）。
- `last-evaluated-instance`: 判定済みの起動インスタンス識別子（PID:起動時刻）。
- `lock/`: 多重実行防止用のロックディレクトリ（実行中のみ存在）。

LaunchAgentの`StandardOutPath`/`StandardErrorPath`は別途
`~/.local/state/cmux-dock-guard/launchd.log`（bashのfatalエラー等、
`guard.log`より前に落ちた場合の捕捉用）。

## テスト

```sh
bash tests/test-cmux-dock-guard.sh
```

実cmux・実launchd・実HOMEには一切依存しない。`PATH`上に偽の`cmux`/`ps`を置き、
待ち時間の環境変数を0にして高速に実行する。

LaunchAgentの設置ロジック（テンプレート展開・launchctlタイムアウト）は
リポジトリ直下の `tests/test-cmux-dock-guard-launchagent.sh` にある。

## 既知の制約

- `cmux new-window`の出力形式が非公開のため、修復時は`cmux --json
  list-windows`の前後差分で新規ウィンドウを特定している。ごく短い時間窓で
  ユーザーが手動で別のウィンドウを開閉すると誤認識しうる（その場合は新規
  ウィンドウを一意に特定できず、エラーログを残してそれ以上の自動操作を
  行わずに終了する＝安全側に倒す）。
- 起動インスタンス識別は`pgrep -f -x`ではなく`ps -axo pid=,command=`の全件
  フィルタで行っている。実装中の実機検証で、`pgrep -f`がcmux.appプロセス
  （`ps`には確実に見えている）に対して常に空振りする現象を確認したため
  （原因未特定。単純なシェルスクリプトの子プロセスに対しては`pgrep -f`も
  正常にヒットした＝プロセス判定側では`pgrep -f`をそのまま使っている。
  対象プロセスの種類に依存する何らかの制限と見られる）。
- cmuxソケットが瞬間的に応答しない（`cmux ping`やDock状態取得コマンドが
  一時的に失敗する）タイミングで2回目の劣化判定〜修復が走ると、実際には
  健全なのに`new-window`修復が空振りし、ERRORログだけ残ってこのインスタンス
  への再試行はしない、という誤判定が理論上ありうる（1起動1回ガードが優先の
  ため）。次にcmuxを再起動すれば改めて判定されるので実害は軽微だが、ログに
  ERRORが出た場合は実際のDockの見た目も確認するのが確実。
- `dock.json`の`command`が複雑なシェル一行（パイプ・複数コマンド等）の
  場合、プロセス判定は先頭トークンのbasenameしか見ないため、実際の生存
  確認としては粗い近似になる。このリポジトリのdock.json（Usage/Next/
  System、いずれも単一スクリプトパス）では問題にならない。
