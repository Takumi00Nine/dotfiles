-- nape_pro/init.lua
--
-- Nape Pro キーマップ v1 Stage 1 (Projects/nape-pro-keymap.md 設計正本の実装)。
-- セッション族(新規/閉じる/切替)は保留箱のまま=このモジュールのスコープ外。
--
-- 呼び出し方: メイン init.lua から
--   local ok, naplePro = pcall(require, "nape_pro")
--   if ok then naplePro.setup() else hs.alert.show("nape_pro load failed: " .. tostring(naplePro)) end
-- のように pcall 越しに使うこと(このモジュールのバグで F17/F18 まで死ぬのを防ぐ)。
--
-- 中立キーコード対応表 (設計判断の詳細はセットアップ手順書 nape_pro/SETUP.md 参照):
--   01 タップ = F13 / 01 ホールド = F14
--   02 タップ = F15 / 02 ホールド = F16
--   M1 タップ = F18 (既存のマイクトグル用コードを流用・ロジックを拡張)
--   M1 ホールド = F19
--   M2 タップ = 実キー Enter/Return (中立コードにしない・Hammerspoon停止時のフォールバック用)
--   M2 ホールド = F20
--   F17 は現状維持(旧・単純Enter送出。使う物理ボタンが無くなれば将来削除候補)。

-- 自分自身(このファイル)のディレクトリを package.path に足しておく。
-- Hammerspoon の require は configdir 直下からの ?.lua / ?/init.lua しか見ないため、
-- サブディレクトリ内の兄弟モジュール(logic/youtube/cmux)を単純な require("logic") で
-- 読めるようにするための自己位置解決(symlink構成に依存しない=堅牢)。
local function scriptDir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return source:match("(.*/)") or "./"
end
package.path = scriptDir() .. "?.lua;" .. package.path

local logic = require("logic")
local youtube = require("youtube")
local cmuxmod = require("cmux")

local M = {}

-- 人間チェックで調整するパラメータ群。値を変えたら Hammerspoon の Reload Config で反映。
M.CONFIG = {
  comboLongMs = 600, -- コンボの短押し/長押し境界
  aiClearRestoreWindowSec = 5, -- AI窓口 短押し「全消し」→ この秒数以内の再押しで復元
  micHandoffDelaySec = 0.15, -- マイクOFF→動画再開までの待ち(既存F18と同じ値)
  seekInvert = false, -- ダイヤルの回転方向とシーク方向が逆に感じたら true
  selectInvert = false, -- 同上、選択肢の上下用
}

local function now()
  return hs.timer.secondsSinceEpoch()
end

local function sendKey(mods, key)
  hs.eventtap.keyStroke(mods, key, 0)
end

-- 右Command (keycode 54) 送出。既存 mic-video-toggle と同じ実装。
local function sendRightCmd()
  hs.eventtap.event.newKeyEvent(54, true):post()
  hs.eventtap.event.newKeyEvent(54, false):post()
end

----------------------------------------------------------------------
-- マイクトグル (M1タップ = 旧F18の後継。ON時にcmux活性化+リーダーペイン focus を追加)
----------------------------------------------------------------------

local micOn = false

local function micRightCmdOn()
  if micOn then return end
  sendRightCmd()
  micOn = true
end

local function micRightCmdOff()
  if not micOn then return end
  sendRightCmd()
  hs.timer.usleep(M.CONFIG.micHandoffDelaySec * 1000000)
  youtube.resumeTaggedVideo()
  micOn = false
end

--- M1 タップ / (旧)F18: マイクトグル。
function M.micToggle()
  if micOn then
    micRightCmdOff()
  else
    youtube.pauseAnyPlayingVideo()
    cmuxmod.activateAndFocusLeaderPane()
    micRightCmdOn()
  end
end

----------------------------------------------------------------------
-- 01/02 タップ: YouTube その場再生停止 / ホームへ
----------------------------------------------------------------------

local youtubeMemory = logic.newYoutubeMemory()

local function tap01PlayPause()
  youtube.toggleActiveTabPlayback()
end

local function tap02GoHome()
  local prevUrl = youtube.goHome()
  if prevUrl then
    youtubeMemory:remember(prevUrl)
  end
end

----------------------------------------------------------------------
-- ダイヤル(ホールド中の修飾): 01/02=シーク, M1=選択肢上下
----------------------------------------------------------------------

local function onDialSeek(delta)
  local forward = delta > 0
  if M.CONFIG.seekInvert then forward = not forward end
  sendKey({}, forward and "right" or "left")
end

local function onDialSelect(delta)
  local down = delta > 0
  if M.CONFIG.selectInvert then down = not down end
  sendKey({}, down and "down" or "up")
end

----------------------------------------------------------------------
-- 橋コンボ: 02+M2 (YouTubeへ) / 01+M1 (入れ子ホームベース)
----------------------------------------------------------------------

local function bridgeGoShort()
  youtube.activateAndFocusYoutube(false)
end

local function bridgeGoLong()
  youtube.activateAndFocusYoutube(true)
end

local function nestedHomeBaseShort()
  if cmuxmod.isFrontmost() then
    cmuxmod.activateAndFocusLeaderPane()
  else
    cmuxmod.activate()
  end
end

-- 「止めて帰って話す」: cmux にいるか/マイク状態に関わらず必ず 停止→cmux→リーダー を行い、
-- マイクは(まだONでなければ)ONにする(micRightCmdOnは冪等)。
local function nestedHomeBaseLong()
  youtube.pauseAnyPlayingVideo()
  cmuxmod.activateAndFocusLeaderPane()
  micRightCmdOn()
end

----------------------------------------------------------------------
-- AI窓口コンボ: M1+M2 (短=全消し⇄復元 / 長=Ctrl+C)
----------------------------------------------------------------------

local aiToggle = logic.newAiInputToggle({ restoreWindowSec = M.CONFIG.aiClearRestoreWindowSec })

-- 全消し: Ctrl+E(行末へ)→Ctrl+U(行頭までkill)。複数行入力は「最後の行だけ」しか
-- 消えない既知の制約あり(readline由来のkill-ring方式を採用した根拠・制約は
-- SETUP.md の設計判断4 参照)。
local function aiClearOrRestore()
  local action = aiToggle:press(now())
  if action == "clear" then
    sendKey({ "ctrl" }, "e")
    sendKey({ "ctrl" }, "u")
  else
    sendKey({ "ctrl" }, "y")
  end
end

local function aiInterrupt()
  sendKey({ "ctrl" }, "c")
end

----------------------------------------------------------------------
-- 裁定ステートマシンの組み立て
----------------------------------------------------------------------

local arbiter = logic.newArbiter({ comboLongMs = M.CONFIG.comboLongMs }, {
  onSoloHoldRelease = function(btn, _heldMs)
    if btn == "02" then
      youtube.returnToUrl(youtubeMemory:recall())
    end
    -- 01(空き)・M1(修飾専用)は意図的に無処理。
  end,
  onComboShort = function(pairName)
    if pairName == "bridge_go" then
      bridgeGoShort()
    elseif pairName == "bridge_return" then
      nestedHomeBaseShort()
    elseif pairName == "ai_mailbox" then
      aiClearOrRestore()
    end
  end,
  onComboLong = function(pairName)
    if pairName == "bridge_go" then
      bridgeGoLong()
    elseif pairName == "bridge_return" then
      nestedHomeBaseLong()
    elseif pairName == "ai_mailbox" then
      aiInterrupt()
    end
  end,
  onDialSeek = onDialSeek,
  onDialSelect = onDialSelect,
})

M.arbiter = arbiter -- テスト/デバッグ用に公開 (人間チェック時に hs コンソールから覗ける)

----------------------------------------------------------------------
-- Hammerspoon 側の実バインド (setup() 呼び出しで初めて登録される)
----------------------------------------------------------------------

local boundObjects = {}

local function bindTap(key, fn)
  table.insert(boundObjects, hs.hotkey.bind({}, key, fn))
end

local function bindHold(key, btn)
  table.insert(boundObjects, hs.hotkey.bind({}, key,
    function() arbiter:onHoldDown(btn, now()) end,
    function() arbiter:onHoldUp(btn, now()) end,
    function() arbiter:onHoldRepeat(btn, now()) end))
end

local didSetup = false

-- 内部: setup() の中身。例外を投げた場合、呼び出し側(M.setup)が
-- それまでに登録済みのオブジェクトを全て削除してロールバックする。
-- (Codexレビュー2026-08-05指摘: didSetup を先に立てると、途中失敗時に
--  中途半端な状態のまま再試行不能になるため。全登録が成功して初めて
--  didSetup=true にする)
local function doSetup()
  bindTap("f13", tap01PlayPause) -- 01 タップ
  bindHold("f14", "01") -- 01 ホールド
  bindTap("f15", tap02GoHome) -- 02 タップ
  bindHold("f16", "02") -- 02 ホールド
  bindHold("f19", "M1") -- M1 ホールド (M1タップ=F18は既存バインドから M.micToggle を呼ぶ)
  bindHold("f20", "M2") -- M2 ホールド (M2タップ=実Enterなのでバインド不要)

  -- ダイヤル: hold中のみ消費してseek/select変換、それ以外は素通し(nativeスクロール)。
  M.scrollTap = hs.eventtap.new({ hs.eventtap.event.types.scrollWheel }, function(ev)
    local delta = ev:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
    if delta == 0 then return false end
    local result = arbiter:onScroll(delta, now())
    return result == "consumed"
  end)
  M.scrollTap:start()
end

--- 全バインドを登録する。init.lua から一度だけ呼ぶこと(冪等ガード付き)。
-- 途中で例外が起きた場合は登録済み分をロールバックし、再度呼べば最初からやり直せる
-- (didSetup は全登録が成功した時だけ true にする)。
function M.setup()
  if didSetup then return end
  local ok, err = pcall(doSetup)
  if ok then
    didSetup = true
    return
  end
  -- ロールバック: 途中まで登録されたホットキー/eventtapを片付ける。
  for _, obj in ipairs(boundObjects) do
    pcall(function() obj:delete() end)
  end
  boundObjects = {}
  if M.scrollTap then
    pcall(function() M.scrollTap:stop() end)
    M.scrollTap = nil
  end
  error("nape_pro.setup() failed: " .. tostring(err), 0)
end

--- 全バインド解除(Reload Config時にHammerspoonが古いオブジェクトを自動GCするが、
-- 手動で無効化したい場合のための明示API)。
function M.teardown()
  for _, obj in ipairs(boundObjects) do
    obj:delete()
  end
  boundObjects = {}
  if M.scrollTap then
    M.scrollTap:stop()
    M.scrollTap = nil
  end
  didSetup = false
end

return M
