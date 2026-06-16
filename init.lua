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

-- 「claude」が動いているターミナルのタブだけを前面＆入力状態にする
local function focusClaudeTerminal()
  hs.osascript.applescript([[
    tell application "Terminal"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          try
            if (processes of t) contains "claude" then
              set selected of t to true
              set index of w to 1
            end if
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

hs.hotkey.bind({}, "F18", function()
  if not micOn then
    -- ▶ マイクON：動画停止 → Claude端末を前面に → 0.15秒 → マイクON
    chromePausePlaying()
    focusClaudeTerminal()
    hs.timer.usleep(150000)
    sendRightCmd()
    micOn = true
  else
    -- ⏹ マイクOFF：マイクOFF → 0.15秒 → 動画再開
    sendRightCmd()
    hs.timer.usleep(150000)
    chromeResumeTagged()
    micOn = false
  end
end)
