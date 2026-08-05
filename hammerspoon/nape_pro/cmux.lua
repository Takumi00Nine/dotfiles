-- nape_pro/cmux.lua
--
-- cmux (com.cmuxterm.app) の外部操作ラッパー。読み取り系CLI呼び出しは
-- Knowledge/cmux-cli-reference.md の調査結果 + 2026-08-05 実機実測(read-only)に基づく。
--
-- 安全方針: close系コマンドは一切呼ばない。CLI呼び出しは全て pcall で保護し、
-- 失敗・パース不能時は「cmuxをアクティブ化するだけ」に静かにフォールバックする
-- (絶対にエラーで nape_pro 全体を止めない)。
--
-- 既知の制約(Codexレビュー2026-08-05指摘): hs.execute は同期呼び出しでタイムアウト
-- 機構が無い。cmux CLI 側が万一ハングすると、その間 Hammerspoon 全体のイベント処理
-- (このモジュール以外のホットキー含む)が止まる。list-panes 等の読み取り系は実測で
-- 即座に返ることを確認済みだが、恒久対策(hs.task化・タイムアウト付き非同期実行)は
-- Stage 1 では見送り、既知リスクとして明記するに留める(SETUP.mdにも記載)。

local M = {}

local BUNDLE_ID = "com.cmuxterm.app"

--- 実行中のフロントモストアプリが cmux かどうか。
function M.isFrontmost()
  local app = hs.application.frontmostApplication()
  return app ~= nil and app:bundleID() == BUNDLE_ID
end

--- cmux をアクティブ化する(起動していなければ起動)。
function M.activate()
  hs.application.launchOrFocusByBundleID(BUNDLE_ID)
end

-- 内部: シェルコマンドを実行し、成功時は trim 済み標準出力を返す。失敗時は nil。
local function run(cmd)
  local ok, out, status = pcall(hs.execute, cmd, true)
  if not ok or not status then
    return nil
  end
  return (out or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- 内部: cmux の ref (例 "workspace:2" / "pane:1") として妥当な形式かを検証する。
-- run() へシェル文字列として埋め込む前のガード(Codexレビュー2026-08-05指摘:
-- current-workspace の生出力を無検証でシェル展開していた)。
-- kind を渡すと種類(例 "workspace"/"pane")まで厳密にチェックする(2巡目の指摘対応:
-- 種類を問わない検証だけだと、workspaceRef位置に"pane:1"のような値が紛れ込んでも
-- 通ってしまっていた)。kind省略時は「シェル的に安全な *:数字 形式」であることのみ確認。
local function isValidRef(ref, kind)
  if type(ref) ~= "string" then return false end
  if kind then
    return ref:match("^" .. kind .. ":%d+$") ~= nil
  end
  return ref:match("^[%a_]+:%d+$") ~= nil
end

--- リーダーペインの特定ヒューリスティック(cmux-cli-reference.mdより):
-- dock:global タグの付いたペインを除外し、最小番号の pane を「リーダー」とみなす。
-- 特定できない場合は nil を返す(呼び出し側は activate() のみへフォールバックすること)。
-- @param workspaceRef 例 "workspace:2" (current-workspace の生出力そのまま使える)
function M.findLeaderPaneRef(workspaceRef)
  if not isValidRef(workspaceRef, "workspace") then return nil end
  local listing = run(string.format("cmux list-panes --workspace %s", workspaceRef))
  if not listing then return nil end

  local minNum, minRef = nil, nil
  for line in listing:gmatch("[^\n]+") do
    if not line:find("dock:global", 1, true) then
      local num = line:match("pane:(%d+)")
      if num then
        num = tonumber(num)
        if not minNum or num < minNum then
          minNum = num
          minRef = "pane:" .. num
        end
      end
    end
  end
  return minRef
end

--- 現在のワークスペース参照 ("workspace:N" 形式) を取得。失敗時・不正形式時 nil。
function M.currentWorkspaceRef()
  local ws = run("cmux current-workspace")
  if not isValidRef(ws, "workspace") then return nil end
  return ws
end

--- cmux をアクティブ化した上で、可能ならリーダーペインへフォーカスする。
-- 特定・フォーカスに失敗しても例外を投げない(activate 済みの状態で留まる=安全側)。
function M.activateAndFocusLeaderPane()
  M.activate()
  local ok, err = pcall(function()
    local ws = M.currentWorkspaceRef()
    if not ws then return end
    local pane = M.findLeaderPaneRef(ws)
    if not isValidRef(pane, "pane") then return end
    run(string.format("cmux focus-pane --pane %s --workspace %s", pane, ws))
  end)
  if not ok then
    hs.printf("nape_pro/cmux: focusLeaderPane best-effort failed: %s", tostring(err))
  end
end

return M
