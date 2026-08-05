local micOn = false  -- マイクの状態を自前で記録

-- 再生中の動画を1つ止めて、目印タグを付ける
local function chromePausePlaying()
  hs.osascript.applescript([[
    tell application "Google Chrome"
      repeat with w in windows
        repeat with t in tabs of w
          try
            execute t javascript "(function(){var v=document.querySelector('video'); if(v&&!v.paused){v.pause(); window.__pausedByMic=true; return '1';} return '0';})()"
          end try
        end repeat
      end repeat
    end tell
  ]])
end

-- 自分が止めた（タグ付きの）動画だけ再生を再開する
local function chromeResumeTagged()
  hs.osascript.applescript([[
    tell application "Google Chrome"
      repeat with w in windows
        repeat with t in tabs of w
          try
            execute t javascript "(function(){var v=document.querySelector('video'); if(v&&window.__pausedByMic){window.__pausedByMic=false; v.play(); return '1';} return '0';})()"
          end try
        end repeat
      end repeat
    end tell
  ]])
end

-- 右Command を送ってマイクをトグル（keycode 54 = 右⌘）
local function sendRightCmd()
  hs.eventtap.event.newKeyEvent(54, true):post()
  hs.eventtap.event.newKeyEvent(54, false):post()
end

-- F18 (2026-08-05 変更): Nape Pro キーマップ v1 Stage 1 導入に伴い、
-- ロジックの実体を nape_pro モジュールへ移設(M1タップの後継として同じF18コードを再利用。
-- 詳細・移行理由は nape_pro/SETUP.md の「設計判断1」参照)。
-- nape_pro の読み込みに失敗した場合は、上の3関数(旧ロジックそのまま)へフォールバックする
-- (「既存動作を壊さない」を最優先=新モジュールが壊れてもF18は必ず何かしら動く)。
hs.hotkey.bind({}, "F18", function()
  -- require の失敗だけでなく、micToggle() 実行中の例外(setup未完了・内部バグ等)も
  -- まとめて pcall で捕捉し、どちらの失敗でも旧ロジックへフォールバックする
  -- (Codexレビュー2026-08-05指摘: requireだけをpcallしても micToggle() 自体の例外は
  --  素通りしてしまい、ホットキーコールバックがエラーになる問題があった)。
  local ok, errOrModule = pcall(function()
    local naplePro = require("nape_pro")
    naplePro.micToggle()
  end)
  if ok then return end

  hs.alert.show("nape_pro F18 handling failed, falling back to legacy logic: " .. tostring(errOrModule))
  if not micOn then
    chromePausePlaying()
    sendRightCmd()
    micOn = true
  else
    sendRightCmd()
    hs.timer.usleep(150000)
    chromeResumeTagged()
    micOn = false
  end
end)

-- F17: Enter を1回送る（最前面のアプリへ）
-- 現状維持。Nape Pro 新配列では M2タップは実Enterキー直送(Hammerspoon非経由)を
-- 採用したためF17は使わない設計だが、旧物理ボタンの移行が終わるまで残す
-- (詳細は nape_pro/SETUP.md の「設計判断2」参照)。
hs.hotkey.bind({}, "F17", function()
  hs.eventtap.keyStroke({}, "return", 0)
end)

----------------------------------------------------------------------
-- Nape Pro キーマップ v1 Stage 1 (2026-08-05)
-- 01/02/M1ホールド/M2/ダイヤル/コンボ 一式は hammerspoon/nape_pro/ に分離実装。
-- pcall で保護し、失敗しても上記の F17/F18 の登録には影響しない。
----------------------------------------------------------------------
package.path = hs.configdir .. "/?/init.lua;" .. hs.configdir .. "/?.lua;" .. package.path
local napeProOk, napeProModuleOrErr = pcall(require, "nape_pro")
if napeProOk then
  local setupOk, setupErr = pcall(napeProModuleOrErr.setup)
  if not setupOk then
    hs.alert.show("nape_pro.setup() failed: " .. tostring(setupErr))
  end
else
  hs.alert.show("nape_pro module failed to load: " .. tostring(napeProModuleOrErr))
end
