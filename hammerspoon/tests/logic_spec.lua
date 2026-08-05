-- hammerspoon/tests/logic_spec.lua
--
-- nape_pro/logic.lua の単体テスト。busted 等の依存を増やしたくないので、
-- 素の Lua (5.4 を想定・Hammerspoon 組込みと同系統) で動く簡易ランナーを自前で持つ。
-- 実行: lua hammerspoon/tests/logic_spec.lua  (dotfiles リポジトリ直下から)
--
-- anyenv 経由で luaenv 5.4.8 を導入してテストしている
-- (absolute-rules を踏まえ brew directインストールは避け、anyenv-runtime ルールに従った)。

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "../nape_pro/?.lua"

local logic = require("logic")

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

-- 呼び出し記録用のスパイを作るヘルパー
local function spy()
  local calls = {}
  local fn = function(...)
    table.insert(calls, { ... })
  end
  return fn, calls
end

print("== logic.Arbiter: ソロ hold (回転なし) ==")
test("回転なしで離すとソロ hold アクションが release 時に1回だけ発火する", function()
  local onSolo, soloCalls = spy()
  local a = logic.newArbiter(nil, { onSoloHoldRelease = onSolo })
  a:onHoldDown("02", 0.0)
  a:onHoldRepeat("02", 0.2)
  a:onHoldUp("02", 0.4)
  assertEq(#soloCalls, 1, "solo release call count")
  assertEq(soloCalls[1][1], "02", "solo release button")
  -- 400ms 保持 -> ms 換算で概ね400 (浮動小数点誤差を許容)
  local heldMs = soloCalls[1][2]
  assert(heldMs >= 390 and heldMs <= 410, "held ms should be ~400, got " .. tostring(heldMs))
end)

test("01(空き)は release してもソロ hold ハンドラが未定義なら何も起きない(エラーにならない)", function()
  local a = logic.newArbiter(nil, {})
  a:onHoldDown("01", 0.0)
  a:onHoldUp("01", 0.3)
  -- エラーが飛ばずここまで到達すればOK
end)

print("== logic.Arbiter: ソロ hold + ダイヤル回転 ==")
test("hold中にダイヤル回転→修飾モード。releaseでソロhold発火を抑制する", function()
  local onSolo, soloCalls = spy()
  local onSeek, seekCalls = spy()
  local a = logic.newArbiter(nil, { onSoloHoldRelease = onSolo, onDialSeek = onSeek })
  a:onHoldDown("02", 0.0)
  local result = a:onScroll(1, 0.1)
  assertEq(result, "consumed", "scroll should be consumed while holding")
  a:onHoldUp("02", 0.3)
  assertEq(#seekCalls, 1, "seek should fire once")
  assertEq(seekCalls[1][1], 1, "seek delta")
  assertEq(#soloCalls, 0, "solo release must be suppressed after rotation")
end)

test("M1 hold中の回転は select ハンドラに来る(seekではない)", function()
  local onSeek, seekCalls = spy()
  local onSelect, selectCalls = spy()
  local a = logic.newArbiter(nil, { onDialSeek = onSeek, onDialSelect = onSelect })
  a:onHoldDown("M1", 0.0)
  a:onScroll(-1, 0.1)
  assertEq(#seekCalls, 0, "seek should not fire for M1")
  assertEq(#selectCalls, 1, "select should fire for M1")
  assertEq(selectCalls[1][1], -1, "select delta")
end)

test("何も hold されていない時のダイヤル回転は passthrough(素通し)", function()
  local a = logic.newArbiter(nil, {})
  local result = a:onScroll(1, 0.0)
  assertEq(result, "passthrough", "no hold -> passthrough")
end)

print("== logic.Arbiter: コンボ 短押し/長押し ==")
test("2ボタンとも閾値未満で離す→短押しが release 時に発火し、長押しは発火しない", function()
  local onShort, shortCalls = spy()
  local onLong, longCalls = spy()
  local a = logic.newArbiter({ comboLongMs = 600 }, { onComboShort = onShort, onComboLong = onLong })
  a:onHoldDown("02", 0.0)
  a:onHoldDown("M2", 0.05) -- コンボ結成 (02+M2 = bridge_go)
  a:onHoldRepeat("02", 0.2)
  a:onHoldRepeat("M2", 0.2)
  a:onHoldUp("M2", 0.3) -- 閾値(0.6s)未満で先に離す
  assertEq(#shortCalls, 1, "short should fire once")
  assertEq(shortCalls[1][1], "bridge_go", "short pair name")
  assertEq(#longCalls, 0, "long should not fire")

  -- もう片方(02)を後で離しても、ソロhold release(=元動画へ戻る)が誤発火しないこと
  local onSolo, soloCalls = spy()
  a.handlers.onSoloHoldRelease = onSolo
  a:onHoldUp("02", 0.4)
  assertEq(#soloCalls, 0, "solo release must be suppressed for the combo's other member")
end)

test("閾値を超えて保持し続けると、離す前に長押しが確定発火する(以後短押しは発火しない)", function()
  local onShort, shortCalls = spy()
  local onLong, longCalls = spy()
  local a = logic.newArbiter({ comboLongMs = 600 }, { onComboShort = onShort, onComboLong = onLong })
  a:onHoldDown("M1", 0.0)
  a:onHoldDown("M2", 0.05) -- ai_mailbox 結成
  a:onHoldRepeat("M1", 0.2)
  a:onHoldRepeat("M2", 0.2)
  a:onHoldRepeat("M1", 0.65) -- 閾値0.6s超過のtick → ここで長押し確定発火
  assertEq(#longCalls, 1, "long should fire exactly once, at threshold crossing")
  assertEq(longCalls[1][1], "ai_mailbox", "long pair name")
  assertEq(#shortCalls, 0, "short should never fire once long has fired")

  a:onHoldUp("M1", 0.9)
  a:onHoldUp("M2", 0.95)
  assertEq(#longCalls, 1, "long must not double-fire on release")
  assertEq(#shortCalls, 0, "short must not fire after long already fired")
end)

test("押した順序と離す順序が逆でも(先に押した方を後で離しても)結成・解消は同じに働く", function()
  local onShort, shortCalls = spy()
  local a = logic.newArbiter({ comboLongMs = 600 }, { onComboShort = onShort })
  a:onHoldDown("01", 0.0) -- 01を先に押す
  a:onHoldDown("M1", 0.02) -- M1を後に押す -> bridge_return 結成
  a:onHoldUp("M1", 0.1) -- 後から押したM1を先に離す(押下順と解放順が逆転するケース)
  assertEq(#shortCalls, 1, "short should fire on first release regardless of which member releases first")

  local onSolo, soloCalls = spy()
  a.handlers.onSoloHoldRelease = onSolo
  a:onHoldUp("01", 0.2) -- 先に押していた01を後から離しても誤発火しない(抑制フラグが効く)
  assertEq(#soloCalls, 0, "the later-released member must not fire its own solo action")
end)

test("01+02(予約枠)は comboPairs に含まれないため、コンボ扱いされずソロ動作を維持する", function()
  local onSolo, soloCalls = spy()
  local onShort, shortCalls = spy()
  local a = logic.newArbiter(nil, { onSoloHoldRelease = onSolo, onComboShort = onShort })
  a:onHoldDown("01", 0.0)
  a:onHoldDown("02", 0.02)
  a:onHoldUp("01", 0.1) -- 01自体はソロhold release アクション未定義(空き)だが、ハンドラ自体は呼ばれる
  a:onHoldUp("02", 0.2)
  assertEq(#shortCalls, 0, "no combo action defined for 01+02")
  -- 01(空き)・02(元動画へ戻る)ともソロ扱いのまま release 時に1回ずつハンドラへ通知される
  assertEq(#soloCalls, 2, "both buttons fire their own solo release notification independently")
  assertEq(soloCalls[1][1], "01", "01 solo release notified first")
  assertEq(soloCalls[2][1], "02", "02 solo release notified second")
end)

test("onComboShortハンドラが例外を投げても、状態(combo解消・もう片方の抑制)は先に確定している", function()
  -- Codexレビュー2026-08-05指摘への回帰テスト: handler内で例外が起きても
  -- comboが残留して二重発火しないことを確認する。
  local a = logic.newArbiter({ comboLongMs = 600 }, {
    onComboShort = function() error("boom (handler内の意図的な例外)") end,
  })
  a:onHoldDown("M1", 0.0)
  a:onHoldDown("M2", 0.02) -- ai_mailbox 結成
  local ok = pcall(function() a:onHoldUp("M1", 0.1) end) -- handlerが例外を投げる
  assertEq(ok, false, "handler の例外はそのまま呼び出し元に伝播する(意図した挙動)")
  assertEq(a.combo, nil, "例外が起きてもcomboは既に解消されているはず")
  assert(a.holds["M2"] and a.holds["M2"].rotated == true,
    "例外が起きてもM2(まだ押されっぱなし)の抑制フラグは既に立っているはず")

  -- 後始末: M2を離してもソロ release アクションが誤発火しないことも確認
  local onSolo, soloCalls = spy()
  a.handlers.onSoloHoldRelease = onSolo
  a:onHoldUp("M2", 0.2)
  assertEq(#soloCalls, 0, "抑制済みのM2は release してもソロアクションを発火しない")
end)

test("リピートDOWNは新規holdとして扱われない(冗長downガード)", function()
  local onSolo, soloCalls = spy()
  local a = logic.newArbiter(nil, { onSoloHoldRelease = onSolo })
  a:onHoldDown("02", 0.0)
  a:onHoldDown("02", 0.1) -- 実装バグ等でdownが再送されても無視される
  a:onHoldUp("02", 0.2)
  assertEq(#soloCalls, 1, "duplicate down must not reset state or double count")
end)

print("== logic.newAiInputToggle ==")
test("初回は clear、5秒以内の再押しは restore、5秒超は再び clear", function()
  local t = logic.newAiInputToggle({ restoreWindowSec = 5 })
  assertEq(t:press(0), "clear", "first press")
  assertEq(t:press(3), "restore", "within window")
  assertEq(t:press(3.1), "clear", "after restore, next press starts a fresh clear cycle")
  assertEq(t:press(20), "clear", "far outside window counts as fresh clear")
end)

print("== logic.newYoutubeMemory ==")
test("/watch を含むURLだけ記憶し、ホームURL等は無視する", function()
  local m = logic.newYoutubeMemory()
  assertEq(m:recall(), nil, "initially nil")
  m:remember("https://www.youtube.com/")
  assertEq(m:recall(), nil, "home url must not be remembered")
  m:remember("https://www.youtube.com/watch?v=abc123")
  assertEq(m:recall(), "https://www.youtube.com/watch?v=abc123", "watch url remembered")
  m:remember("https://www.youtube.com/")
  assertEq(m:recall(), "https://www.youtube.com/watch?v=abc123", "subsequent home nav must not clobber memory")
end)

print(string.format("\n%d passed, %d failed", passCount, #failures))
if #failures > 0 then
  os.exit(1)
end
