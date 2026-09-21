# cmux-dock-guard

cmux を Cmd+Q で終了して手動で再起動したあと、何も操作しなくても Dock
（`~/.config/cmux/dock.json` に定義された Dock コントロール一式。枠の顔ぶれ・
枚数は dock.json が正本で、本ツールは実行時にそれを読む）が
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

`cmux reload-config`（明示的なDock config再読み込み）による再シードも検討
したが、実機実験（2026-08-07・本人がDockコマンドプロセスをkill→リーダーが
実測）で「劣化したDockは再シードされない」ことが確定したため、修復手段には
含めていない（後述）。

## 前提条件: cmux ソケットのアクセス制御

cmux の既定設定 `automation.socketControlMode: "cmuxOnly"` は
「**cmux 内で起動されたプロセスのみ**ソケットに接続可」という制限で、
launchd から起動される本ガードは接続を拒否される
（実測 2026-08-08: 「アクセスが拒否されました。cmux 内で起動された
プロセスのみ接続できます」→ ガードは無ログのまま何もできない）。

このため `~/.config/cmux/cmux.json` で以下の設定が必要（本リポジトリの
`cmux/cmux.json` には設定済み）:

```jsonc
"automation": { "socketControlMode": "automation" }
```

セキュリティ上の補足: ソケットファイル自体が 0600（同一ユーザーのみ）
なので、この開放で接続可能になるのは同一ユーザーのプロセスに限られる。
`password` モードも存在するが、cmux.json が公開リポジトリ管理のため
秘密を置けず不採用。

## 起動検知

cmuxのソケット/ロックファイルが入る `~/.local/state/cmux/` ディレクトリを
launchdの`WatchPaths`で監視する。cmux再起動のたびにソケットファイル自体は
unlink+再作成されるが、**launchdはWatchPathsに指定したパスそのものが消える
と監視対象から外し、後で同じパスが再作成されても監視を復活させない仕様**
（[参考](https://managingosx.wordpress.com/2006/05/10/launchd-gotcha/)）のため、
ソケットファイル単体ではなく、それが入っている**ディレクトリ**を監視対象に
している（ディレクトリ自体は消えないので、中身の増減で確実に発火する）。

これに加えて`StartInterval`（20秒間隔）のポーリングを安全網として併用する
（WatchPathsの取りこぼし対策）。両経路とも同じスクリプトを呼び、スクリプト
自身が「cmux起動インスタンスごとに最大1回」しか判定・修復しないため、
安全網が余分に発火しても実害はない（後述）。

## 動作

1. `ps`でcmux.appプロセスのPID・起動時刻を取得し「起動インスタンス」を
   識別する。見つからなければ（cmux未起動の通常状態）何もせず終了する。
2. このインスタンスが判定済み（状態ファイルに記録済み）なら何もしない
   （WatchPathsの多重発火・StartIntervalの空振り対策）。
3. `cmux ping`でソケットが応答するか確認する。appプロセスはあるが起動途中で
   まだソケットが上がっていない場合は、短く（既定2秒×10回）リトライしてから
   諦める（次のStartInterval発火まで丸ごと待つと目安60秒の枠を圧迫するため）。
4. settle待ち（既定12秒）してから健全性を判定する。次の**両方**が揃って
   初めて健全とみなす:
   - title判定: `dock.json`の各controlの`title`が、`cmux --json tree --all`
     が返す`dock_scope=="global"`なサーフェスのいずれかのtitleとして
     観測できる。ペインが存在しない（閉じられている）場合もここで不一致に
     なる。
   - プロセス判定: `dock.json`の各terminal controlの`command`（実行ファイル
     パスのbasenameを抽出）に対応するプロセスが`pgrep -f`で実際に見つかる。
     実機実験（2026-08-07・本人kill→リーダー実測）: Dockコマンドの
     プロセスをkillした直後・cmux再起動を挟まない場合、サーフェスのtitleは
     古い値のまま変化しない（降格した対話シェルなのに表示は「Usage」の
     まま）。title判定だけではこの状態を健全と誤判定してしまうため、独立
     した第2の軸として持つ。`command`の実行ファイルが存在しない（`[ -x ]`
     で見えない）controlはこの判定から除外する（後述）。
     `command`の先頭に環境変数前置（`KEY=VALUE …`。例: Task枠の
     `CMUX_DOCK_MAX_COLS=35`）が付いたcontrolも、前置を読み飛ばした本体で同じ生存判定の対象になる
     （v6 FR-115。前置の値は使わず`eval`もしない。文法に合わない先頭
     トークン、例: `1A=1`、は前置でないので従来どおり判定外）。
5. 劣化を検知したら、誤検知防御のため間隔（既定6秒）を空けてもう一度判定
   する（起動直後は一時的に汎用タイトルになりうる観測があるため）。
6. 2回連続で劣化を確認した場合のみ、新ウィンドウ方式で修復する: `cmux
   new-window`（スナップショットの無い新ウィンドウはdock.jsonから再シード
   される）→ 各既存ウィンドウのワークスペースを新ウィンドウへ
   `move-workspace-to-window`で移動 → そのウィンドウの移動が**全部成功
   した場合だけ**`close-window`で閉鎖（1件でも失敗したウィンドウは閉鎖せず
   残置し、ERRORログを残す。移動失敗を見逃して閉鎖すると、本人の作業中
   ワークスペースがウィンドウごと消えるため）→ 新ウィンドウ側の初期空
   ワークスペースだけ`cmux workspace close`で掃除（他に本物のワークスペース
   が無い退化ケースでは空にしないよう残す）。
7. 修復の成否によらず、このインスタンスへの再試行はしない（暴走防止。次に
   cmuxが再起動されるまで待つ）。**この設計の帰結として、cmux起動後に本人が
   Dockペインを手動で閉じても、そのセッション中はガードが再介入することは
   ない**（dock.jsonに定義されたDockコントロールを常設インフラとして必ず
   復元させるのは、あくまで次にcmuxを起動した時点での評価に限る）。通知は
   出さない（📣は本人呼び出し
   専用運用のため）。

## 安全対策（ハング・タイムアウト）

- 個々の`cmux`呼び出しは`cmux_run`（`run_with_timeout`）でラップされ、既定
  15秒でタイムアウトする。ソケット半死状態でcmuxがブロックしても、この
  タイムアウトが発火してプロセスグループごと終了させる。
- スクリプト全体にも既定300秒のウォッチドッグを仕込んでいる。launchdは
  同一Labelのジョブを多重起動しない仕様のため、個々のcmux呼び出し以外の
  場所で万一ハングすると、そのままでは以後WatchPaths/StartIntervalが永久に
  発火しなくなる。ウォッチドッグはその最後の砦として自分自身にSIGTERMを
  送る。
- 実装中に、この種のタイムアウト/ウォッチドッグの複数統文サブシェル
  （`sleep N; kill ...`）を`set -m`でプロセスグループ化せずに`kill`すると、
  既にforkされた`sleep`孫プロセスだけ生き残ってPID1へ再親化し、コマンド
  置換／パイプの出力先fdを握り続けたまま数十〜数百秒ブロックし続ける
  不具合を実測した（親を殺しても孫は死なない、という典型的な罠）。cmd・
  ウォッチャー双方をプロセスグループ化し、`kill -TERM "-$pid"`でグループ
  ごと終了させることで解消している。

## 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `CMUX_DOCK_GUARD_CMUX_BIN` | `cmux` | 呼び出すcmux CLI（テスト用差し替え口） |
| `CMUX_DOCK_GUARD_DOCK_JSON` | `~/.config/cmux/dock.json` | 期待タイトル・commandの取得元 |
| `CMUX_DOCK_GUARD_STATE_DIR` | `~/.local/state/cmux-dock-guard` | ログ・ロック・マーカーの置き場所 |
| `CMUX_DOCK_GUARD_APP_PATH` | `/Applications/cmux.app/Contents/MacOS/cmux` | 起動インスタンス識別に使うcmux.appプロセスの実行パス |
| `CMUX_DOCK_GUARD_SETTLE_SECS` | `12` | 起動検知後、1回目の判定までの待ち |
| `CMUX_DOCK_GUARD_RECHECK_GAP_SECS` | `6` | 1回目劣化検知後、2回目判定までの待ち（誤検知防御） |
| `CMUX_DOCK_GUARD_POST_REPAIR_SECS` | `5` | 修復実行後、再判定までの待ち |
| `CMUX_DOCK_GUARD_LOCK_STALE_SECS` | `120` | この秒数を超えて残るロックは前回のクラッシュ跡とみなし奪取する |
| `CMUX_DOCK_GUARD_IS_UP_RETRIES` | `10` | `cmux ping`が空振りした時のリトライ回数 |
| `CMUX_DOCK_GUARD_IS_UP_RETRY_GAP_SECS` | `2` | 上記リトライの間隔（秒） |
| `CMUX_DOCK_GUARD_CMUX_CALL_TIMEOUT_SECS` | `15` | cmux呼び出し1回あたりのタイムアウト |
| `CMUX_DOCK_GUARD_WATCHDOG_SECS` | `300` | スクリプト全体のウォッチドッグ発火までの秒数 |

## ログ・状態

`~/.local/state/cmux-dock-guard/` 配下:

- `guard.log`: 判定・修復の経過（タイムスタンプ付き、構造化テキスト）。
- `last-evaluated-instance`: 判定済みの起動インスタンス識別子（PID:起動時刻）。
- `lock/`: 多重実行防止用のロックディレクトリ（実行中のみ存在）。

LaunchAgentの`StandardOutPath`/`StandardErrorPath`は別途
`~/.local/state/cmux-dock-guard/launchd.log`（bashのfatalエラー等、
`guard.log`より前に落ちた場合の捕捉用）。`install.sh`がこのディレクトリと
`~/.local/state/cmux`（WatchPaths対象）の両方を事前に`mkdir -p`する
（launchdは親ディレクトリが無いと監視自体を付けられない・ログ出力先が
無いとジョブがspawnに失敗しうるため）。

## テスト

```sh
bash tests/test-cmux-dock-guard.sh
```

実cmux・実launchd・実HOMEには一切依存しない。`PATH`上に偽の`cmux`/`ps`/
`pgrep`を置き、待ち時間の環境変数を0にして高速に実行する。

LaunchAgentの設置ロジック（テンプレート展開・`mkdir -p`・launchctlタイム
アウト）はリポジトリ直下の `tests/test-cmux-dock-guard-launchagent.sh` に
ある。

## 既知の制約

- `cmux new-window`の出力形式が非公開のため、修復時は`cmux --json
  list-windows`の前後差分で新規ウィンドウを特定している。ごく短い時間窓で
  ユーザーが手動で別のウィンドウを開閉すると誤認識しうる（その場合は新規
  ウィンドウを一意に特定できず、エラーログを残してそれ以上の自動操作を
  行わずに終了する＝安全側に倒す）。
- 起動インスタンス識別は`pgrep -f -x`ではなく`ps -axww -o pid=,command=`の
  全件フィルタで行っている。実装中の実機検証で、`pgrep -f`がcmux.app
  プロセス（`ps`には確実に見えている）に対して常に空振りする現象を確認
  したため（原因未特定。単純なシェルスクリプトの子プロセスに対しては
  `pgrep -f`も正常にヒットした＝プロセス判定側では`pgrep -f`をそのまま
  使っている。対象プロセスの種類に依存する何らかの制限と見られる）。
  `-ww`は端末幅での切り詰め防止（launchd配下はtty無しで既定80桁になり
  うり、`/Applications/cmux.app/Contents/MacOS/cmux`より長い実行パスだと
  切れて完全一致判定が常に不成立になりかねないため）。
- cmuxソケットが瞬間的に応答しない（`cmux ping`やDock状態取得コマンドが
  一時的に失敗する）タイミングで2回目の劣化判定〜修復が走ると、実際には
  健全なのに`new-window`修復が空振りし、ERRORログだけ残ってこのインスタンス
  への再試行はしない、という誤判定が理論上ありうる（1起動1回ガードが優先の
  ため）。次にcmuxを再起動すれば改めて判定されるので実害は軽微だが、ログに
  ERRORが出た場合は実際のDockの見た目も確認するのが確実。
- `dock.json`の`command`が複雑なシェル一行（パイプ・複数コマンド等）の
  場合、プロセス判定は先頭トークンのbasenameしか見ないため、実際の生存
  確認としては粗い近似になる。このリポジトリのdock.json（Usage/Project/Task/System、
  いずれも単一スクリプトパス）では問題にならない。
- `command`の実行ファイルが存在しない（`[ -x ]`で見えない）controlは
  プロセス判定から除外する。そうしないと、そのcontrolのスクリプトを
  導入していないマシン（例: `claude-codex-usage`リポジトリ未導入で
  Usageコントロールの実体が無いサブ機）で永久に「劣化」判定になり、
  起動のたびにnew-window修復が走り続けてしまう。裏を返すと、実行ファイルが
  存在しないcontrolについては生存確認自体が行われない（title判定だけが
  効く）。
- 修復（new-window方式）の後、選択中のワークスペースやフォーカスが元と
  同じになる保証は無い（移動順は`list-windows`/`workspace list`の返す順に
  依存する）。ターミナル内のセッション自体（エージェントの会話など）は
  cmuxのワークスペース移動で保持されるが、「どのワークスペースが最前面に
  出るか」は変わりうる。
