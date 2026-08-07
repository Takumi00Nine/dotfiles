-- nape_pro/logic.lua
--
-- Nape Pro キーマップ v1 (Stage 1) の「純ロジック」部分。
-- hs.* に一切依存しない（unit test を素の lua インタプリタで回すため）。
-- 実際のキー送出・アプリ操作は呼び出し側 (nape_pro/init.lua) が handlers 経由で行う。
--
-- 前提（実機検証済み・2026-08-04, Projects/nape-pro-keymap.md）:
--   ・タップコード = 短押しで単発 DOWN/UP、遅延なしで届く。
--   ・ホールドコード = 押している間 DOWN がオートリピートで連続 → 離すと UP。
--     リピート DOWN は「新しい押下」ではなく生存確認として扱う（このモジュールでは
--     hold(btn, "repeat", now) として通知され、コンボの長押し閾値判定にのみ使う）。
--   ・タップ用コードとホールド用コードは別物（デバイス側で確定させてから送出される）
--     ので、このモジュールは「タップは即時発火・ホールドは状態機械」という前提で良い。
--
-- 裁定ルール（設計正本より）:
--   ・ホールド中にダイヤル回転 → 修飾モード。そのボタンの「離した瞬間のホールド
--     アクション」は発火させない。
--   ・回転なしで離す → 離した瞬間にホールドアクションを発火。
--   ・コンボは「両ボタンのホールドコードが同時に流れている状態」で検出する
--     （タップ側は combo 判定に一切関与しない = 単押しの遅延ゼロを最優先）。
--   ・コンボは短押し/長押しのどちらか一方だけが発火する（閾値を超えた瞬間に長押し
--     が確定発火し、以後そのコンボでは短押しは発火しない）。

local M = {}

local BUTTONS = { "01", "02", "M1", "M2" }

-- 既定コンフィグ。呼び出し側は必要な項目だけ上書きしてよい。
M.DEFAULT_CONFIG = {
  comboLongMs = 600, -- コンボの短押し/長押し境界（人間チェックで調整する変数）
  dialContext = { -- ホールド中のボタン → ダイヤル回転の意味
    ["01"] = "seek",
    ["02"] = "seek",
    ["M1"] = "select",
  },
  comboPairs = { -- 隣接ペアのみ（対角コンボは存在しない = 設計原則）
    { a = "02", b = "M2", name = "bridge_go" }, -- 奥横: YouTubeへ
    { a = "M1", b = "M2", name = "ai_mailbox" }, -- 右縦: AI窓口
    { a = "01", b = "M1", name = "bridge_return" }, -- 手前横: 帰り
    -- 01+02 (中縦) は現状「予約枠・未使用」。意図的に comboPairs へ含めない
    -- (両方 hold されても combo としては何も起きず、各ボタンは通常のソロ hold 挙動を保つ)。
  },
}

local Arbiter = {}
Arbiter.__index = Arbiter

--- 新しい裁定ステートマシンを作る。
-- @param config 部分上書き可能な設定 (省略時 DEFAULT_CONFIG のコピー)
-- @param handlers {
--   onSoloHoldRelease = function(btn, heldMs) end,   -- ソロ hold を回転なしで離した瞬間
--   onComboShort = function(pairName) end,           -- コンボ短押し確定 (release 時)
--   onComboLong = function(pairName) end,             -- コンボ長押し確定 (閾値到達の瞬間、まだ押されたまま)
--   onDialSeek = function(delta) end,                 -- 01/02 hold 中のダイヤル回転
--   onDialSelect = function(delta) end,               -- M1 hold 中のダイヤル回転
-- }
function M.newArbiter(config, handlers)
  local merged = {}
  for k, v in pairs(M.DEFAULT_CONFIG) do merged[k] = v end
  if config then
    for k, v in pairs(config) do merged[k] = v end
  end
  local self = setmetatable({}, Arbiter)
  self.config = merged
  self.handlers = handlers or {}
  self.holds = {} -- btn -> { startedAt = number, rotated = bool }
  self.combo = nil -- { pairName, a, b, startedAt, longFired }
  return self
end

-- 内部: comboが長押し閾値を超えていたら、その場で長押しを確定発火する。
-- down/repeat/up/scroll のどのイベント処理でも先頭で呼ぶ
-- (デバイスのホールド中オートリピートを「時間経過の tick」として利用する)。
function Arbiter:_checkComboThreshold(now)
  local c = self.combo
  if c and not c.longFired and (now - c.startedAt) >= (self.config.comboLongMs / 1000) then
    c.longFired = true
    if self.handlers.onComboLong then
      self.handlers.onComboLong(c.pairName)
    end
  end
end

-- 内部: btn が新たに hold 状態になったとき、既存の hold と組んでコンボを結成できるか確認。
-- 既にコンボが進行中なら新規結成はしない(3ボタン同時押し等は未対応・仕様上想定外)。
function Arbiter:_maybeFormCombo(btn, now)
  if self.combo then return end
  for _, pair in ipairs(self.config.comboPairs) do
    local other
    if pair.a == btn and self.holds[pair.b] then
      other = pair.b
    elseif pair.b == btn and self.holds[pair.a] then
      other = pair.a
    end
    if other then
      self.combo = { pairName = pair.name, a = pair.a, b = pair.b, startedAt = now, longFired = false }
      return
    end
  end
end

--- ホールドコードの DOWN (初回のみ。リピート DOWN は onHoldRepeat を使うこと)。
function Arbiter:onHoldDown(btn, now)
  self:_checkComboThreshold(now)
  if self.holds[btn] then return end -- 冗長な down は無視 (念のためのガード)
  self.holds[btn] = { startedAt = now, rotated = false }
  self:_maybeFormCombo(btn, now)
end

--- ホールドコードのリピート DOWN (押しっぱなし中に連続到着する)。
-- 状態は変えない。コンボの長押し閾値判定の「tick」としてのみ使う。
function Arbiter:onHoldRepeat(_btn, now)
  self:_checkComboThreshold(now)
end

--- ホールドコードの UP。
function Arbiter:onHoldUp(btn, now)
  self:_checkComboThreshold(now)
  local entry = self.holds[btn]
  if not entry then return end
  self.holds[btn] = nil

  local c = self.combo
  if c and (c.a == btn or c.b == btn) then
    -- 先に状態(combo解消・もう片方の抑制)を確定させてから handler を呼ぶ。
    -- handler が例外を投げても combo が残留してもう片方の release で短押しが
    -- 二重発火する、といった状態機械の破損を防ぐ(Codexレビュー2026-08-05で指摘)。
    local pairName, longFired = c.pairName, c.longFired
    local other = (c.a == btn) and c.b or c.a
    if self.holds[other] then
      self.holds[other].rotated = true
    end
    self.combo = nil

    if not longFired and self.handlers.onComboShort then
      self.handlers.onComboShort(pairName)
    end
  else
    if not entry.rotated and self.handlers.onSoloHoldRelease then
      self.handlers.onSoloHoldRelease(btn, (now - entry.startedAt) * 1000)
    end
  end
end

--- ダイヤル回転 (scrollWheel を ±1 に正規化した delta)。
-- @return "consumed" (ネイティブスクロールを止めるべき) | "passthrough" (素通しでよい)
function Arbiter:onScroll(delta, now)
  self:_checkComboThreshold(now)

  if self.combo then
    -- コンボ中のダイヤル回転は未定義(想定外の同時操作) → 何もしない。素通しもしない
    -- (2ボタン+ダイヤルの同時操作は事故率が高いと判断し、安全側で握りつぶす)。
    return "consumed"
  end

  local activeBtn, activeCount = nil, 0
  for _, b in ipairs(BUTTONS) do
    if self.holds[b] then
      activeCount = activeCount + 1
      activeBtn = b
    end
  end
  if activeCount ~= 1 then
    return "passthrough" -- 何も hold されていない(通常スクロール) or 想定外の多重hold
  end

  local ctx = self.config.dialContext[activeBtn]
  self.holds[activeBtn].rotated = true -- 離した時のホールドアクションは発火させない
  if ctx == "seek" and self.handlers.onDialSeek then
    self.handlers.onDialSeek(delta)
  elseif ctx == "select" and self.handlers.onDialSelect then
    self.handlers.onDialSelect(delta)
  end
  return "consumed"
end

-- テスト/デバッグ用: 現在の内部状態を読み取り専用で覗く。
function Arbiter:debugState()
  return { holds = self.holds, combo = self.combo }
end

M.Arbiter = Arbiter

--- AI窓口(M1+M2)短押し用: 「全消し⇄5秒以内なら復元」のトグル状態機械。
-- 破壊的操作ではない(再押しで戻せる)ので単純な toggle+タイムアウトのみ。
function M.newAiInputToggle(config)
  config = config or {}
  local restoreWindowSec = config.restoreWindowSec or 5
  local self = { cleared = false, clearedAt = 0, restoreWindowSec = restoreWindowSec }

  --- @return "clear" | "restore"
  function self:press(now)
    if self.cleared and (now - self.clearedAt) <= self.restoreWindowSec then
      self.cleared = false
      return "restore"
    end
    self.cleared = true
    self.clearedAt = now
    return "clear"
  end

  function self:isCleared()
    return self.cleared
  end

  return self
end

--- 02タップ(ホームへ)/02ホールド(元の動画へ戻る)用: 直前の動画URLを1件だけ覚える。
-- 「/watch を含む URL だけ記憶する」= ホーム画面そのものを誤って記憶しないためのガード。
function M.newYoutubeMemory()
  local self = { lastVideoUrl = nil }

  function self:remember(url)
    if type(url) == "string" and url:find("watch", 1, true) then
      self.lastVideoUrl = url
    end
  end

  function self:recall()
    return self.lastVideoUrl
  end

  return self
end

return M
