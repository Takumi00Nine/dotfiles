# cmux-task-watch

cmux Dock の4枠目「Task」に、供給側（ai-env の `cmux-task-model.sh`）から
受け取った1ティック分のフレームを描くだけの常駐スクリプト
（`cmux-task-watch.sh`）。v3（cmux-session-todo 設計 §28〜§31）で
Vault・宣言記録・cmux の解析はすべて供給側へ移り、この常駐は**表示専用**
（Vault にも cmux にも一切触れない）になった。

宣言 CLI（`set`／`unset`／`list`／`prune`）は
`~/work/takumi009-ai-env/cmux/cmux-task-declare.sh` へ移設済み。この
リポジトリには置かない（使い方は ai-env 側の README を参照）。

同じ `cmux/` 配下の共有 lib（`lib-dock-view.sh`・`lib-supply-frame.sh`）に
依存する。実体のディレクトリ（`~/work/dotfiles/cmux/`）が壊れていて lib が
見つからないときは、理由を1行出して終了コード1で止まる（機能を欠いたまま
無言では起動しない）。

## 表示例

実作業中の版がある場合:

```
▶ cmux-session-todo  v2 1/3
v1 ✅ 3/3
v2 ▶ 1/3
 ├ 5 [x] 要件定義
 ├ 6 [/] 設計
 └ 7 [ ] 実装
v3 ・ 0/4
```

子行の番号は**供給側が採番した値をそのまま描く**（この常駐は連番を振り
直さない＝FR-63）。表示規則そのものは v1・v2 から一切変えていない。

供給側が使えない・応答しない・契約の版が合わないときは、理由行1行だけを
出す（`AI環境 未導入`／`AI環境 応答なし`／`AI環境 版ちがい`）。供給側が
返した宣言・Vault 由来の理由（`未宣言`・`ノート不在`等）は、受け取った
文字列をそのまま描く。

## 表示番号と対応表

Dock 枠の名前は「Task」。展開中の版の子行にだけ番号が付く（畳んだ版の
子タスクには付かない）。**番号は恒久 ID ではない。** 端末の高さが足りず
子行が省略されても、残った行の番号は振り直さない。

「Task の N 番」の対応表を得る口は、供給側（
`~/work/takumi009-ai-env/cmux/cmux-task-model.sh --list`）へ移設済み。
この常駐は `--list` を提供しない（渡すと使い方を出して終了コード1・
常駐モードへは落ちない）。

## 使い方

```
cmux-task-watch.sh [--once] [--plain]
```

| 引数 | 意味 |
|---|---|
| （なし） | 常駐。OSC 2 でペインタイトルを「Task」と名乗り、ループする |
| `--once` | 1フレームを色付きで出して終了（終了コード0） |
| `--plain` | 1フレームを平文（ESC無し）で出して終了。`--once` と併用可・単独でも1回で終わる |

上記以外の引数（未知の引数・`--list`）は常駐へは落ちず、使い方を標準
エラーへ出して終了コード非0で即座に終わる。

宣言の作成・切り替え・週次の掃除は ai-env 側の CLI で行う（このリポジトリ
の範囲外）。

## 環境変数

| 環境変数 | 既定 | 意味 |
|---|---|---|
| `CMUX_DOCK_SUPPLY_TASK` | `$HOME/work/takumi009-ai-env/cmux/cmux-task-model.sh` | 供給側の呼び出し口（テスト・実験用の上書き口） |
| `CMUX_DOCK_SUPPLY_TIMEOUT` | 5 | 供給側の呼び出しの締切（秒）。1〜60の整数以外は既定へ戻す |
| `CMUX_TASK_FOCUS_INTERVAL` | 2 | 常駐ループの周期（秒） |
| `CMUX_TASK_REDRAW_HEARTBEAT` | 600 | 同一フレームでも強制再描画する間隔（秒） |
| `CMUX_TASK_COLS` / `CMUX_TASK_ROWS` | 未設定（`stty` 実測） | 端末寸法の強制上書き |
| `CMUX_DOCK_MAX_COLS` | 60 | 桁数の実測値（`stty` 実測。`CMUX_TASK_COLS` 上書き時は対象外）がこの値を超えるとき丸める上限。Dock ペインの pty 桁数が可視幅より大きく報告される既知の癖への対処（`lib-dock-view.sh` の `term_cols()` 共通） |

## 供給側との契約

呼び出しは1ティックにつき1回、`$CMUX_DOCK_SUPPLY_TASK --frame` を実行し、
TSV 形式の1フレーム分を受け取る（契約の詳細は cmux-session-todo 設計
§29）。締切・大きさ上限（65536バイト・1000行）に達したときは供給側を
プロセスグループごと終了させ、`AI環境 応答なし` へ縮退する。

## テスト

```
bash tests/test-cmux-task-watch.sh
```

実 Vault・実ワークスペース・実 cmux には一切触れない（供給側はテスト用
スタブへ差し替える＝`cmux/tests/lib-supply-stubs.sh`）。
