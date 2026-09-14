# cmux-next-watch

cmux Dock の右側ドック（幅約40桁の狭幅ターミナルペイン）に「プロジェクト
横断の次アクション」と「外部脳（Vault）ヘルス」を常駐表示するスクリプト。
`cmux-usage-watch.sh` / `cmux-feed-watch.sh` / `cmux-system-watch.sh` と同じ
流儀（bash 3.2 互換・jq 使用・256色エスケープ・`\033[?2026` 同期出力による
チラつき防止・`--once` モード）で書かれている。

dock.json への登録はこのツールの範囲外（リーダーが別途行う）。

同じ `cmux/` 配下の共有 lib（`lib-dock-view.sh`・`lib-vault-tasks.sh`）に
依存する。実体のディレクトリ（`~/work/dotfiles/cmux/`）が壊れていたり
symlink 経由で lib が見つからないときは、理由を1行出して終了コード1で
止まる（機能を欠いたまま無言では起動しない）。

## 表示例

```
▶ Next (3)
svwb-pilot-log 実データ照合を回す
takumi009-ai-e (next未設定)
avatar-switch- 配布方式のたたき台を書く

✅ 外部脳
棚卸し 要確認15件 (8/5)
週次 ✅8/5
```

警告があるとき:

```
⚠ 外部脳
棚卸し 要確認15件 (8/5)
週次 ⚠10日前
```

## 表示仕様

### セクション1: 稼働中 / 保留
- `$CMUX_NEXT_VAULT/Projects/*.md` の frontmatter（先頭行が `---` で始まり、
  2つ目の `---` までの間）を読む。
- status 語彙は4値統一（active/paused/completed/closed＝Vault
  Decisions/2026-08-06-project-status-taxonomy）。`CMUX_NEXT_STATUS_ALLOW`
  （既定 `active`）該当は「▶ 稼働中」、`CMUX_NEXT_STATUS_HOLD`（既定
  `paused`）該当は「⏸ 保留」セクションに表示。それ以外（completed/closed・
  status無し・frontmatter無し）は表示しない。番号はセクション通し。
- 各ノートの `next:`（1行文字列）を表示する。中身のある手書きの `next:` が
  あればそれを優先する。`next:` が無い、または空文字列のノートは、同じ
  ノートの `## Tasks` 節（`### <版名>` ごとのチェックリスト）から先頭の
  未完タスク（状態が `x` でない最初のタスク。`[/]` を優先せず記載順のまま）
  の本文を代わりに使う（FR-31）。長さは先頭15コードポイントに切り詰め、
  省略記号は付けない（既存のプロジェクト名10文字切りと同じ流儀）。
  導出値はノートへ書き戻さない。`next:` も Tasks 節も無ければ dim色で
  `(next未設定)` と表示する（次アクションが未整備なギャップをあえて隠さな
  い）。
- 並び順: frontmatter の `updated:`（無ければ `date:`、どちらも無ければ最
  下位）の降順。
- 1行の形式: `<名前> <next文字列>`。名前はファイル名（拡張子なし）を先頭
  10文字に切り詰め（省略記号は付けない）。行全体は端末幅（`stty size` 実測、
  取得できなければ40桁固定）にコードポイント単位で切り詰め、超過時は末尾に
  `…` を付ける。
- ヘッダー行: `▶ Next (N)`（太字）。

### セクション2: 外部脳
- **棚卸し**: `~/.claude/logs/vault-inventory/`（`CMUX_NEXT_INVENTORY_DIR`
  で変更可）配下の**名前順最新**の `.md`（ファイル名が `YYYY-MM-DD.md` のた
  め辞書順＝時系列順になることを利用）から `要確認 (\d+) 件` を抽出し、
  `棚卸し 要確認N件 (M/D)` と表示する。N=0 は緑・1以上はオレンジ。パターン
  抽出に失敗した場合（ファイルが無い・形式が変わった等）は dim色で
  `棚卸し n/a` と表示する（この n/a 単体はヘッダーの警告判定には数えない
  ＝「抽出できない」と「値が異常」を区別する設計）。
- **週次メンテ死活**: `~/.claude/logs/maintenance/last-run.json`
  （`CMUX_NEXT_MAINT_STATE` で変更可）を読み、`last_success_at`（無ければ
  `started_at`）からの経過日数で判定する。`CMUX_NEXT_MAINT_STALE_DAYS`
  （既定8日、`~/work/takumi009-ai-env/scripts/check-drift.sh` の週次ドリフ
  ト判定と同じ閾値）以上古ければ `週次 ⚠N日前`、それ未満なら `週次 ✅M/D`
  と表示する。状態ファイルが無い・壊れている場合はこの行自体を省略する
  （棚卸しの n/a とは扱いを分けている＝週次メンテは「未導入マシンでは行自
  体が存在しなくて当然」なので、n/aを出して常時警告的に見せるより省略の方
  が実態に合うと判断）。
- ヘッダー行: 棚卸しN≥1、または週次が⚠のいずれか1つでもあれば
  `⚠ 外部脳`（太字オレンジ）、どちらも問題なければ `✅ 外部脳`（太字緑）。

## 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `CMUX_NEXT_VAULT` | `$HOME/Data/obsidian` | Vault のルート（`Projects/` を配下に持つ） |
| `CMUX_NEXT_INTERVAL` | `60` | 常駐モードの再描画間隔（秒）。不正値は既定に戻す |
| `CMUX_NEXT_STATUS_ALLOW` | `active` | 「稼働中」セクションに出す status のカンマ区切りリスト |
| `CMUX_NEXT_STATUS_HOLD` | `paused` | 「保留」セクションに出す status のカンマ区切りリスト |
| `CMUX_NEXT_INVENTORY_DIR` | `$HOME/.claude/logs/vault-inventory` | 棚卸しレポートのディレクトリ（主にテスト用の差し替え口） |
| `CMUX_NEXT_MAINT_STATE` | `$HOME/.claude/logs/maintenance/last-run.json` | 週次メンテの状態ファイル（主にテスト用の差し替え口） |
| `CMUX_NEXT_MAINT_STALE_DAYS` | `8` | 週次メンテを古いとみなす経過日数の閾値 |

## 使い方

```bash
# 1回だけ描画して終了（テスト・動作確認用）
./cmux-next-watch.sh --once

# 常駐（cmux Dock から呼び出す想定）
./cmux-next-watch.sh

# AI/スクリプト用: 表示と同じ順序で「番号<TAB>正式プロジェクト名<TAB>next値
# <TAB>区分（稼働中/保留）」の4列を色なしで出力。ユーザーの「Project の 2 番」等の
# 参照はこれで解決する（正本）。
./cmux-next-watch.sh --list
```

表示行には先頭に番号が付く（例 `2 svwb-pilot #5配信・…`）。番号は恒久IDでは
なく「その時点の表示順（updated 降順）」なので、参照解決は必ず `--list` を
同じタイミングで実行して行うこと。

## テスト

```bash
bash tests/test-cmux-next-watch.sh
```

tmp配下に fixture Vault・fixture 棚卸しログ・fixture last-run.json を都度
生成して検証する。実 Vault (`~/Data/obsidian`)・実ログには一切触れない。

## 品質上の注意点

- Vault ノートの `next:` 値・ファイル名は任意文字列が端末に生で流れるため、
  `cmux-feed-watch.sh` と同じ jq のコードポイント単位 `gsub` で C0/C1 制御
  文字（ESC・CSI・OSC 等のエスケープシーケンス注入の起点）を空白化してから
  表示する。Tasks 節から導出した値（FR-31）も同じ無害化を通るため、タスク
  本文に TAB・改行・制御文字が含まれていても `--list` の4列 TSV は崩れない
  （FR-43）。
- frontmatter パースは「1行目が `---`」から「次の `---` 行の直前まで」に
  厳密に限定しており、本文中に偶然 `next:` 等の行があっても誤検出しない。
  閉じフェンスが無い壊れたファイルを最後まで読み込まないよう60行で走査を
  打ち切る。

## 週次メンテ死活の調査結果

`~/work/takumi009-ai-env/scripts/check-drift.sh` の
`check_maintenance_freshness()` を読んだ結果、週次ランナー
(`maintenance.sh`、LaunchAgent `com.takumi009.maintenance`) の死活状態は
`~/.claude/logs/maintenance/last-run.json` に `{"started_at": "...Z",
"last_success_at": "...Z"}` の形式で書き出されている（ISO8601 UTC）ことを
確認した。check-drift.sh 自身は `started_at` の経過日数を8日超で drift 扱い
にしているが、本スクリプトでは「実際に成功した最終時刻」の方が実態に近い
指標と判断し `last_success_at` を優先し、無い場合のみ `started_at` に
フォールバックする（同じ8日という閾値は踏襲）。
