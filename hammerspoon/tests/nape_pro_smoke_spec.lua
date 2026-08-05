-- hammerspoon/tests/nape_pro_smoke_spec.lua
--
-- nape_pro/init.lua + youtube.lua + cmux.lua の「配線」スモークテスト。
-- 実際の Hammerspoon (hs.*) には一切触れず、fake な `hs` グローバルをこのプロセス内だけに
-- 用意して、素の Lua インタプリタ上で読み込み・呼び出しが例外なく動くこと、および
-- 期待した hs API 呼び出し(hs.eventtap.keyStroke / hs.osascript.applescript / hs.execute等)
-- が正しい引数で行われることを検証する。
-- 実機 Hammerspoon への Reload Config はユーザーの人間チェック工程に委ねる(安全側の判断。
-- 理由は完了報告に記載)。
--
-- 実行: lua hammerspoon/tests/nape_pro_smoke_spec.lua

local selfDir = arg[0]:match("(.*/)") or "./"
-- require("nape_pro") が hammerspoon/nape_pro/init.lua を見つけられるようにする。
-- (nape_pro/init.lua 自身は debug.getinfo による自己位置解決で兄弟モジュールを読むので、
--  ここでは "nape_pro" というパッケージ名の解決だけ通しておけばよい)
package.path = selfDir .. "../?/init.lua;" .. package.path

----------------------------------------------------------------------
-- fake `hs` グローバル
----------------------------------------------------------------------

local calls = {
  keyStrokes = {}, -- {mods, key}
  keyEvents = {}, -- {code, down}
  applescripts = {}, -- raw script string
  shell = {}, -- executed shell commands
  alerts = {},
  launchOrFocus = {},
}

local shellResponses = {
  ["cmux current-workspace"] = "workspace:2",
  ["cmux list-panes --workspace workspace:2"] = table.concat({
    "* pane:1  [2 surfaces]  [focused]",
    "  pane:5  [1 surface]  [dock:global]",
    "  pane:6  [1 surface]  [dock:global]",
    "* pane:7  [1 surface]  [dock:global]  [focused]",
  }, "\n"),
}

local fakeClock = 1000.0
local hotkeyRegistry = {} -- key -> {pressedfn, releasedfn, repeatfn}

local frontmostBundleId = "com.other.app"
local fakeChromeRunning = true -- youtube.lua の chromeRunning() ガードの模擬用

_G.hs = {
  configdir = "/fake/.hammerspoon",
  alert = {
    show = function(msg) table.insert(calls.alerts, msg) end,
  },
  printf = function() end,
  timer = {
    secondsSinceEpoch = function() return fakeClock end,
    usleep = function() end,
  },
  eventtap = {
    keyStroke = function(mods, key, _delay)
      table.insert(calls.keyStrokes, { mods = mods, key = key })
    end,
    event = {
      newKeyEvent = function(code, down)
        return {
          post = function() table.insert(calls.keyEvents, { code = code, down = down }) end,
        }
      end,
      types = { scrollWheel = "scrollWheel" },
      properties = { scrollWheelEventDeltaAxis1 = "scrollWheelEventDeltaAxis1" },
    },
    new = function(_types, fn)
      local obj = { _fn = fn, started = false }
      function obj:start() self.started = true end
      function obj:stop() self.started = false end
      return obj
    end,
  },
  hotkey = {
    bind = function(_mods, key, pressedfn, releasedfn, repeatfn)
      hotkeyRegistry[key] = { pressedfn = pressedfn, releasedfn = releasedfn, repeatfn = repeatfn }
      return { delete = function() hotkeyRegistry[key] = nil end }
    end,
  },
  osascript = {
    applescript = function(src)
      table.insert(calls.applescripts, src)
      -- goHome系の戻り値をそれっぽく模擬(前のURLを返す)ため、スクリプト内容で分岐
      if src:find("make new tab", 1, true) or src:find("activate", 1, true) then
        return true, true
      end
      if src:find('set URL of t to "https://www.youtube.com/"', 1, true) then
        return true, "https://www.youtube.com/watch?v=PREV123"
      end
      return true, true
    end,
  },
  application = {
    frontmostApplication = function()
      return { bundleID = function() return frontmostBundleId end }
    end,
    launchOrFocusByBundleID = function(id) table.insert(calls.launchOrFocus, id) end,
    -- youtube.lua の chromeRunning() ガード用。既定でChromeは起動中とみなす
    -- (fakeChromeRunning=falseにすればテスト側で未起動シナリオも模擬できる)。
    find = function(_bundleIdOrName)
      if fakeChromeRunning then
        return { name = function() return "Google Chrome" end }
      end
      return nil
    end,
  },
  execute = function(cmd, _withUserEnv)
    table.insert(calls.shell, cmd)
    local out = shellResponses[cmd]
    if out then
      return out, true, "exit", 0
    end
    return "", true, "exit", 0
  end,
}

----------------------------------------------------------------------
-- テストランナー(logic_spec.luaと同じ簡易方式)
----------------------------------------------------------------------

local failures = {}
local passCount = 0

local function assertEq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertEq", tostring(expected), tostring(actual)), 2)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passCount = passCount + 1
    print("  ok  - " .. name)
  else
    table.insert(failures, { name = name, err = err })
    print("FAIL  - " .. name .. "\n        " .. tostring(err))
  end
end

----------------------------------------------------------------------
-- 読み込み
----------------------------------------------------------------------

local naplePro
test("nape_pro モジュールがエラーなく読み込める", function()
  naplePro = require("nape_pro")
  assert(naplePro ~= nil, "module should load")
end)

test("setup() が例外なく完走し、6個のホールド/タップキーがbindされる", function()
  naplePro.setup()
  for _, key in ipairs({ "f13", "f14", "f15", "f16", "f19", "f20" }) do
    assert(hotkeyRegistry[key], key .. " should be bound")
  end
  assert(naplePro.scrollTap ~= nil and naplePro.scrollTap.started, "scroll eventtap should be started")
end)

test("Chrome未起動時は01タップで何も起きない(勝手に起動させない)", function()
  fakeChromeRunning = false
  calls.applescripts = {}
  hotkeyRegistry["f13"].pressedfn()
  assertEq(#calls.applescripts, 0, "chromeRunning()=false のときはAppleScriptを一切呼ばないはず")
  fakeChromeRunning = true
end)

test("F13(01タップ)を押すとChromeへ再生停止トグルのJS実行スクリプトが飛ぶ", function()
  calls.applescripts = {}
  hotkeyRegistry["f13"].pressedfn()
  assert(#calls.applescripts == 1, "one applescript call expected")
  assert(calls.applescripts[1]:find("youtube.com", 1, true), "script should check youtube.com")
end)

test("F15(02タップ=ホームへ)→F16(02ホールド、回転なしで離す)で記憶したURLへ戻る", function()
  calls.applescripts = {}
  hotkeyRegistry["f15"].pressedfn() -- ホームへ(内部でPREV123を記憶する想定)
  assert(#calls.applescripts == 1, "goHome should call applescript once")

  calls.applescripts = {}
  hotkeyRegistry["f16"].pressedfn() -- 02 hold down
  fakeClock = fakeClock + 0.2
  hotkeyRegistry["f16"].releasedfn() -- 回転なしで release -> 元動画へ戻るはず
  assert(#calls.applescripts == 1, "returnToUrl should fire once on solo release without rotation")
  assert(calls.applescripts[1]:find("PREV123", 1, true), "should navigate back to the remembered watch url")
end)

test("M1(F19)+M2(F20) 短押しコンボでAI窓口の全消し(Ctrl+E, Ctrl+U)が送られる", function()
  calls.keyStrokes = {}
  hotkeyRegistry["f19"].pressedfn() -- M1 hold down
  fakeClock = fakeClock + 0.05
  hotkeyRegistry["f20"].pressedfn() -- M2 hold down -> ai_mailbox 結成
  fakeClock = fakeClock + 0.1
  hotkeyRegistry["f20"].releasedfn() -- 閾値(600ms)未満で先に離す -> 短押し
  assert(#calls.keyStrokes == 2, "expected 2 keystrokes (ctrl+e, ctrl+u)")
  assertEq(calls.keyStrokes[1].key, "e", "first keystroke")
  assertEq(calls.keyStrokes[2].key, "u", "second keystroke")

  -- 残っているM1も離しておく(状態クリーンアップ、誤発火しないことも確認)
  calls.keyStrokes = {}
  fakeClock = fakeClock + 0.05
  hotkeyRegistry["f19"].releasedfn()
  assertEq(#calls.keyStrokes, 0, "releasing the other combo member afterwards must not fire anything extra")
end)

test("M1+M2 長押し(600ms超)でCtrl+Cが送られ、短押しは発火しない", function()
  calls.keyStrokes = {}
  hotkeyRegistry["f19"].pressedfn()
  fakeClock = fakeClock + 0.05
  hotkeyRegistry["f20"].pressedfn()
  fakeClock = fakeClock + 0.7 -- 閾値超過のtick
  hotkeyRegistry["f20"].repeatfn()
  assertEq(#calls.keyStrokes, 1, "ctrl+c should fire exactly once at threshold crossing")
  assertEq(calls.keyStrokes[1].key, "c", "should be ctrl+c")
  assertEq(calls.keyStrokes[1].mods[1], "ctrl", "should include ctrl modifier")

  calls.keyStrokes = {}
  fakeClock = fakeClock + 0.1
  hotkeyRegistry["f19"].releasedfn()
  hotkeyRegistry["f20"].releasedfn()
  assertEq(#calls.keyStrokes, 0, "no extra keystrokes should fire on release after long already fired")
end)

test("01+M1(bridge_return)短押し: cmux外にいる場合はactivateのみ呼ばれる(focus-paneは呼ばれない)", function()
  frontmostBundleId = "com.other.app"
  calls.shell = {}
  calls.launchOrFocus = {}
  fakeClock = fakeClock + 1
  hotkeyRegistry["f14"].pressedfn() -- 01 hold down
  fakeClock = fakeClock + 0.05
  hotkeyRegistry["f19"].pressedfn() -- M1 hold down -> bridge_return 結成
  fakeClock = fakeClock + 0.1
  hotkeyRegistry["f14"].releasedfn() -- 短押しで先に離す
  assertEq(#calls.launchOrFocus, 1, "cmux should be activated")
  assertEq(#calls.shell, 0, "list-panes/focus-pane must NOT be called when starting outside cmux")
  hotkeyRegistry["f19"].releasedfn() -- 後始末
end)

test("01+M1(bridge_return)短押し: cmux内にいる場合はリーダーペインへfocusする(実測フォーマットのパース確認込み)", function()
  frontmostBundleId = "com.cmuxterm.app"
  calls.shell = {}
  calls.launchOrFocus = {}
  fakeClock = fakeClock + 1
  hotkeyRegistry["f14"].pressedfn()
  fakeClock = fakeClock + 0.05
  hotkeyRegistry["f19"].pressedfn()
  fakeClock = fakeClock + 0.1
  hotkeyRegistry["f14"].releasedfn()
  assertEq(#calls.launchOrFocus, 1, "cmux activate should still be called (idempotent)")
  local sawCurrentWorkspace, sawFocusPane1 = false, false
  for _, cmd in ipairs(calls.shell) do
    if cmd == "cmux current-workspace" then sawCurrentWorkspace = true end
    if cmd:find("focus%-pane %-%-pane pane:1 %-%-workspace workspace:2") then sawFocusPane1 = true end
  end
  assert(sawCurrentWorkspace, "should query current-workspace")
  -- dock:global(pane:5/6/7)を除いた最小番号=pane:1 が選ばれていること(ヒューリスティック確認)
  assert(sawFocusPane1, "should focus pane:1 (min non-dock:global pane), got: " .. table.concat(calls.shell, " | "))
  hotkeyRegistry["f19"].releasedfn()
end)

test("ダイヤル: 何もholdしていない時はpassthrough(false)が返る", function()
  local ev = { _delta = 1 }
  function ev:getProperty(_prop) return self._delta end
  local consumed = naplePro.scrollTap._fn(ev)
  assertEq(consumed, false, "scroll should pass through when nothing is held")
end)

test("ダイヤル: 01ホールド中の回転でLeft/Right矢印キーが送られ、consumeされる", function()
  calls.keyStrokes = {}
  fakeClock = fakeClock + 1
  hotkeyRegistry["f14"].pressedfn() -- 01 hold down
  local ev = { _delta = 1 }
  function ev:getProperty(_prop) return self._delta end
  local consumed = naplePro.scrollTap._fn(ev)
  assertEq(consumed, true, "scroll should be consumed while 01 is held")
  assertEq(#calls.keyStrokes, 1, "one arrow keystroke expected")
  assertEq(calls.keyStrokes[1].key, "right", "positive delta -> right arrow (seekInvert=false)")
  hotkeyRegistry["f14"].releasedfn() -- 後始末(回転済みなので追加アクションは起きないはず)
end)

print(string.format("\n%d passed, %d failed", passCount, #failures))
if #failures > 0 then
  os.exit(1)
end
