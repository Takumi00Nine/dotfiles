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

1. `pgrep`でcmux.appプロセスのPID・起動時刻を取得し「起動インスタンス」を
   識別する。見つからなければ（cmux未起動の通常状態）何もせず終了する。
2. このインスタンスが判定済み（状態ファイルに記録済み）なら何もしない
   （WatchPathsの多重発火・StartIntervalの空振り対策）。
3. `cmux ping`でソケットが応答するか確認する（appプロセスはあるが起動途中で
   まだソケットが上がっていない場合は、マーカーを書かずに次回の発火に委ねる）。
4. settle待ち（既定30秒）してから健全性を判定する: `dock.json`の各control
   の`title`が、`cmux --json tree --all`が返す`dock_scope=="global"`な
   サーフェスのいずれかのtitleとして観測できていれば健全。
5. 劣化を検知したら、誤検知防御のため間隔（既定15秒）を空けてもう一度判定
   する（起動直後は一時的に汎用タイトルになりうる観測があるため）。
6. 2回連続で劣化を確認した場合のみ修復する:
   1. まず `cmux reload-config`（`cmux config reload`の別名）を試す。
      dock.mdに「Explicitly reloading the Dock config still replaces the
      current Dock with the config contents.」という記述があり、明示リロード
      がDockをconfig内容へ置き換える旨が書かれている。ただし劣化した
      Dockに対して実際に再シードされるかは未確認（上流issueが開いたままな
      のもそれを裏付ける）。効いたかどうかは直後に再判定して自己検証する
      ので、効かなくても後段へ安全にフォールバックする。
   2. 直っていなければ、新ウィンドウ方式で修復する: `cmux new-window`
      （スナップショットの無い新ウィンドウはdock.jsonから再シードされる）
      → 既存の全ウィンドウの全ワークスペースを新ウィンドウへ
      `move-workspace-to-window`で移動 → 旧ウィンドウを`close-window`で閉鎖
      （旧ウィンドウ側にワークスペース移動の過程で自動生成される空
      ワークスペースは、旧ウィンドウごと閉鎖されるので個別の掃除は不要）
      → 新ウィンドウ側の初期空ワークスペースだけ`cmux workspace close`で
      掃除（他に本物のワークスペースが無い退化ケースでは空にしないよう残す）。
7. 修復の成否によらず、このインスタンスへの再試行はしない（暴走防止。次に
   cmuxが再起動されるまで待つ）。通知は出さない（📣は本人呼び出し専用運用の
   ため）。

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
- `reload-config`が劣化したDockを実際に再シードできるかは未確認（本人環境
  での破壊的な再現実験がAI側の権限で実行できず未実施。次のcmux再起動時の
  実運用で確認できる）。
- 起動インスタンス識別は`pgrep -f -x`ではなく`ps -axo pid=,command=`の全件
  フィルタで行っている。実装中の実機検証で、`pgrep -f`がcmux.appプロセス
  （`ps`には確実に見えている）に対して常に空振りする現象を確認したため
  （原因未特定。単純なシェルスクリプトの子プロセスに対しては`pgrep -f`も
  正常にヒットしたので、対象プロセスの種類に依存する何らかの制限と見られる）。
- cmuxソケットが瞬間的に応答しない（`cmux ping`やDock状態取得コマンドが
  一時的に失敗する）タイミングで2回目の劣化判定〜修復が走ると、実際には
  健全なのに`cmux reload-config`/`new-window`修復が両方とも空振りし、
  ERRORログだけ残ってこのインスタンスへの再試行はしない、という誤判定が
  理論上ありうる（1起動1回ガードが優先のため）。次にcmuxを再起動すれば
  改めて判定されるので実害は軽微だが、ログにERRORが出た場合は実際のDockの
  見た目も確認するのが確実。
