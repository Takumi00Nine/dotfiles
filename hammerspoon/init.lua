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

local TMUX = "/opt/homebrew/bin/tmux"

-- Ghostty + tmux 用: claude が動いている tmux ペインを探して選択し、Ghostty を前面化する。
-- claude ペインが見つかれば true を返す（見つからなければ false でフォールバックさせる）。
local function focusClaudeInGhostty()
  -- 全ペインを "session:window.pane current_command" で列挙
  local out, ok = hs.execute(TMUX ..
    " list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null")
  if not ok or not out then return false end

  local target  -- 例: "ai:1.1"
  for line in out:gmatch("[^\n]+") do
    local tgt, cmd = line:match("^(%S+)%s+(%S+)$")
    -- claude バイナリはペイン上で "claude.exe" 等として見える
    if tgt and cmd and cmd:lower():find("claude") then
      target = tgt
      break
    end
  end
  if not target then return false end

  -- "ai:1.1" -> ウィンドウターゲット "ai:1"
  local win = target:match("^(.-)%.%d+$")
  if win then hs.execute(TMUX .. " select-window -t '" .. win .. "' 2>/dev/null") end
  hs.execute(TMUX .. " select-pane -t '" .. target .. "' 2>/dev/null")
  hs.application.launchOrFocus("Ghostty")
  return true
end

-- 旧来の Terminal.app 用: 「claude」が動いているタブだけを前面＆入力状態にする
local function focusClaudeTerminalApp()
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

-- ディスパッチャ: まず Ghostty+tmux、見つからなければ Terminal.app にフォールバック
local function focusClaudeTerminal()
  if not focusClaudeInGhostty() then
    focusClaudeTerminalApp()
  end
end

-- 右Command を送ってマイクをトグル（keycode 54 = 右⌘）
local function sendRightCmd()
  hs.eventtap.event.newKeyEvent(54, true):post()
  hs.eventtap.event.newKeyEvent(54, false):post()
end

hs.hotkey.bind({}, "F18", function()
  if not micOn then
    -- ▶ マイクON：動画停止 → マイクON（端末へはフォーカスを移さない）
    chromePausePlaying()
    sendRightCmd()
    micOn = true
  else
    -- ⏹ マイクOFF：マイクOFF → 0.15秒 → 動画再開 → Claude端末を前面に
    sendRightCmd()
    hs.timer.usleep(150000)
    chromeResumeTagged()
    focusClaudeTerminal()
    micOn = false
  end
end)

-- F17: claude が動いているターミナルを前面化してから Enter を送る
hs.hotkey.bind({}, "F17", function()
  focusClaudeTerminal()
  hs.timer.usleep(150000)        -- フォーカスが移るのを待ってから送信
  hs.eventtap.keyStroke({}, "return", 0)
end)
