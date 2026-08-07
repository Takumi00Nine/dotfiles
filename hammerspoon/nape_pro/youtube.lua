-- nape_pro/youtube.lua
--
-- Chrome 上の YouTube 操作。既存資産 (mic-video-toggle の chromePausePlaying /
-- chromeResumeTagged, Knowledge/mic-video-toggle.md) と同じ AppleScript+JS 実行の
-- 作法を踏襲する。「Chromeの表示→デベロッパー→Apple EventsからのJavaScriptを許可」
-- が前提条件(既存機能と共通)。

local M = {}

-- 内部: AppleScript を実行し、失敗しても呼び出し元を落とさない。
-- hs.osascript.applescript(source) の実シグネチャは
--   -> bool(succeeded), object(parsed result), descriptor(raw)
-- なので、pcall の1個目の戻り値(pcall自体の成否)と2個目(AppleScript自体の成否)を
-- 混同しないこと(最初の実装でここを取り違えてスモークテストで発覚した既知の罠)。
local function runAS(src)
  local pcallOk, asOk, result = pcall(hs.osascript.applescript, src)
  if not pcallOk or not asOk then
    return nil
  end
  return result
end

-- 内部: Lua文字列をAppleScriptの文字列リテラルとして安全に埋め込むためのクォート。
-- Luaの string.format("%q", ...) はLuaリテラル用のエスケープ(制御文字を10進数
-- エスケープにする等)であり、AppleScriptの文字列エスケープ規則とは異なるため流用不可
-- (Codexレビュー2026-08-05指摘)。AppleScriptの文字列は "\" と """ だけエスケープすれば
-- 良く、改行・制御文字を含むURLは想定しない(含んでいたら安全側で拒否する)。
local function asQuote(s)
  -- %c は制御文字全般(改行・タブ・NUL等)にマッチする。URLに制御文字が
  -- 含まれることは正規の使い方では無いはずなので、含んでいたら安全側で拒否する
  -- (Codexレビュー2026-08-05指摘、2巡目: 当初はCR/LFしか拒否していなかった)。
  if type(s) ~= "string" or s == "" or s:find("%c") then
    return nil
  end
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- 内部: Chromeが既に起動しているか(読み取りのみ・起動はしない)。
-- `tell application "Google Chrome" to ...` はAppleScriptの仕様上、Chromeが
-- 起動していなければ勝手に起動してしまう副作用がある。停止/再開/トグル/ホームへ、
-- のような「能動的にChromeを開きたいわけではない」操作の前にこれで確認し、未起動なら
-- 何もしない(Codexレビュー2026-08-05指摘、2巡目)。橋コンボ(activateAndFocusYoutube)は
-- 「Chromeを開いてYouTubeへ行く」のが目的そのものなので、意図的にこのガードを掛けない。
local function chromeRunning()
  return hs.application.find("com.google.Chrome") ~= nil
end

--- マイクトグル用: 再生中の動画を(タブ・ウィンドウを問わず)1つ止めて目印タグを付ける。
-- 既存 mic-video-toggle (init.lua の旧 chromePausePlaying) と全く同じロジック。
-- 「1つ」と書いているが実装は全window/tabを走査する(既存実装と同一の挙動を踏襲。
-- 通常は再生中の動画は高々1つなので実用上は1つだけ止まる。Codexレビュー2026-08-05指摘
-- を受けてコメントを実態に合わせて明確化)。
-- M1タップ(マイクON)・01+M1長押し(止めて帰って話す)の両方から呼ばれる共通部品。
function M.pauseAnyPlayingVideo()
  if not chromeRunning() then return end
  runAS([[
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

--- マイクOFF時: 自分が止めた(タグ付きの)動画だけ再生を再開する。既存ロジックと同一。
function M.resumeTaggedVideo()
  if not chromeRunning() then return end
  runAS([[
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

--- 01タップ: フロントのYouTubeタブがあれば、その場で再生/停止をトグルする。
-- (mic-video-toggle の chromePausePlaying は「再生中のものを問答無用で止める」用途
--  なので流用せず、01専用に「今アクティブなYouTubeタブ」だけを狙い撃ちする)
function M.toggleActiveTabPlayback()
  if not chromeRunning() then return end
  runAS([[
    tell application "Google Chrome"
      if (count of windows) = 0 then return
      set t to active tab of front window
      if (URL of t) does not contain "youtube.com" then return
      try
        execute t javascript "(function(){var v=document.querySelector('video'); if(!v) return 'no-video'; if(v.paused){v.play();}else{v.pause();} return 'ok';})()"
      end try
    end tell
  ]])
end

--- 02タップ: アクティブなYouTubeタブをホームへ。遷移前のURLを onBeforeNavigate へ渡す
-- (呼び出し側の YoutubeMemory:remember に渡すのはこちら側の責務にせず、呼び出し側で行う
--  ことでこのモジュールを hs 以外の状態を持たない薄いI/O層に保つ)。
-- @return 遷移前のURL(string) または nil(YouTubeタブが見つからない/失敗)
function M.goHome()
  if not chromeRunning() then return nil end
  local prevUrl = runAS([[
    tell application "Google Chrome"
      if (count of windows) = 0 then return ""
      set t to active tab of front window
      set u to URL of t
      if u does not contain "youtube.com" then return ""
      set URL of t to "https://www.youtube.com/"
      return u
    end tell
  ]])
  if prevUrl == "" then return nil end
  return prevUrl
end

--- 02ホールド(回転なしで離す): 記憶していたURLへ戻す。何も記憶していなければ no-op。
function M.returnToUrl(url)
  if not chromeRunning() then return end
  local quoted = asQuote(url)
  if not quoted then return end
  runAS(string.format([[
    tell application "Google Chrome"
      if (count of windows) = 0 then return
      set t to active tab of front window
      set URL of t to %s
    end tell
  ]], quoted))
end

--- 橋コンボ(02+M2): Chromeをアクティブ化し、既存のYouTubeタブを探して前面化。
-- 見つからなければ新しいタブでYouTubeホームを開く。playAlso=true なら再生も試みる。
-- Chrome起動済みだがウィンドウが0件(全部閉じた直後等)の場合に備え、
-- window不在なら新規windowを開いてから使う(Codexレビュー2026-08-05指摘:
-- 従来は`front window`前提でウィンドウ0件時に静かに失敗していた)。
function M.activateAndFocusYoutube(playAlso)
  runAS(string.format([[
    tell application "Google Chrome"
      activate
      if (count of windows) = 0 then
        make new window
      end if
      set found to false
      repeat with w in windows
        set i to 1
        repeat with t in tabs of w
          if (URL of t) contains "youtube.com" then
            set index of w to 1
            set active tab index of w to i
            set found to true
            exit repeat
          end if
          set i to i + 1
        end repeat
        if found then exit repeat
      end repeat
      if not found then
        tell front window to make new tab at end of tabs with properties {URL:"https://www.youtube.com/"}
      end if
      if %s then
        delay 0.2
        try
          execute (active tab of front window) javascript "(function(){var v=document.querySelector('video'); if(v){v.play();}})()"
        end try
      end if
    end tell
  ]], playAlso and "true" or "false"))
end

return M
