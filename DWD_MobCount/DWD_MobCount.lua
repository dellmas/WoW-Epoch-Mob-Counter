-- DWD_MobCount.lua (Wrath 3.3.5a / Project Epoch)
-- Tracks YOUR kills per NPC ID. Tooltip shows "Killed: #".
-- Commands: /mobcount [config|clear|debug|lock|restore]

local ADDON = "DWD_MobCount"

-- SavedVariables
DWD_MobCountDB      = DWD_MobCountDB      or {}  -- per-character bucket
DWD_MobCountBackup  = DWD_MobCountBackup  or { _locks = {}, _meta = {} } -- account-wide backup

-- ==== Per-character state ====
local charKey, playerGUID, playerName
local killsById   = {}   -- [npcId] = count
local namesById   = {}   -- [npcId] = last-seen name
local killsByName = {}   -- [name]  = count (fallback if ID missing)

-- caches/guards
local nameByGUID  = {}   -- [guid] = name
local taggedGUID  = {}   -- [guid] = time of last damage from us/pet/vehicle
local taggedName  = {}   -- [name] = time of last damage from us/pet/vehicle
local counted     = {}   -- [guid] = time we credited a kill (dup guard)
local nameToRecentId = {}-- [name] = {id=12345, t=time} for name-only fallbacks

-- debug printing
local DEBUG = false
local function dprint(...)
  if not DEBUG then return end
  local msg = "|cffff7f00MobCount:|r"
  for i=1,select("#", ...) do msg = msg .. " " .. tostring(select(i, ...)) end
  DEFAULT_CHAT_FRAME:AddMessage(msg)
end

-- utils
local function trim(s) return (s and s:gsub("^%s+",""):gsub("%s+$","")) or "" end
local function tempty(t) return not t or next(t) == nil end
local function copyShallow(src) local d = {}; if src then for k,v in pairs(src) do d[k]=v end end; return d end

-- lock helpers (account-wide)
local function isLocked()
  return DWD_MobCountBackup._locks and DWD_MobCountBackup._locks[charKey] or false
end
local function setLocked(v)
  DWD_MobCountBackup._locks = DWD_MobCountBackup._locks or {}
  DWD_MobCountBackup._locks[charKey] = v and true or nil
end

-- snapshot to account-wide backup (independent copy)
local function snapshotToBackup()
  if not charKey then return end
  local b = DWD_MobCountBackup
  b[charKey] = b[charKey] or {}
  b[charKey].killsById   = copyShallow(killsById)
  b[charKey].namesById   = copyShallow(namesById)
  b[charKey].killsByName = copyShallow(killsByName)
  b._meta[charKey] = { t = (time and time() or 0), ver = 1 }
end

-- ensure per-char tables exist (do NOT wipe)
local function ensureCharTables()
  if not charKey then return end
  local b = DWD_MobCountDB[charKey]
  if not b then
    b = { killsById = {}, namesById = {}, killsByName = {} }
    DWD_MobCountDB[charKey] = b
  else
    b.killsById   = b.killsById   or {}
    b.namesById   = b.namesById   or {}
    b.killsByName = b.killsByName or {}
  end
  killsById, namesById, killsByName = b.killsById, b.namesById, b.killsByName
end

-- restore from backup if local is empty (never overwrites non-empty data)
local function maybeRestoreFromBackup()
  local bk = DWD_MobCountBackup and DWD_MobCountBackup[charKey]
  if bk and tempty(killsById) and tempty(killsByName) then
    killsById   = copyShallow(bk.killsById   or {})
    namesById   = copyShallow(bk.namesById   or {})
    killsByName = copyShallow(bk.killsByName or {})
    DWD_MobCountDB[charKey] = { killsById = killsById, namesById = namesById, killsByName = killsByName }
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Restored counts from backup.")
  end
end

-- name<->id map helpers
local function noteNameId(name, id)
  if not name or not id then return end
  nameToRecentId[name] = { id = id, t = GetTime() }
end
local function recentIdForName(name, ttl)
  local e = nameToRecentId[name]
  if e and (GetTime() - e.t) <= (ttl or 30) then return e.id end
end

-- credit helpers (always snapshot)
local function creditKillById(id, nm)
  if not id then return end
  namesById[id] = nm or namesById[id] or ""
  killsById[id] = (killsById[id] or 0) + 1
  snapshotToBackup()
end
local function creditKillByName(nm)
  if not nm or nm == "" then return end
  killsByName[nm] = (killsByName[nm] or 0) + 1
  snapshotToBackup()
end

-- ==== GUID helpers (Wrath hex & modern dash) ====
local function isCreatureGUID_hex(g)
  if type(g) ~= "string" then return false end
  local up = g:upper()
  return up:find("^0X") and (up:find("^0XF130") or up:find("^0XF150") or up:find("^0XF530")) ~= nil
end
local function isCreatureGUID_dash(g)
  if type(g) ~= "string" then return false end
  return (g:find("^Creature%-") or g:find("^Vehicle%-")) ~= nil
end

-- Canonical WotLK extraction: NPC entry = hex chars 7..10 AFTER "0x"
local function npcIdFromHexGUID(g)
  local up = g:upper()
  if not up:find("^0X") then return nil end
  local s = up:sub(3)
  local hx = s:sub(7, 10)
  if hx and hx:match("^[0-9A-F]+$") then
    local v = tonumber(hx, 16)
    if v and v > 0 and v < 1000000 then return v end
  end
  return nil
end
local function npcIdFromDashGUID(g)
  local id = g:match("-(%d+)-%x+$")
  return id and tonumber(id) or nil
end
local function npcIdFromGUID(g)
  if type(g) ~= "string" then return nil end
  if isCreatureGUID_hex(g)  then return npcIdFromHexGUID(g) end
  if isCreatureGUID_dash(g) then return npcIdFromDashGUID(g) end
  return nil
end
local function isCreatureGUID(g) return isCreatureGUID_hex(g) or isCreatureGUID_dash(g) end

-- Identify "mine" (GUID or name)
local function isMineSource(srcGUID, srcName)
  if srcGUID == playerGUID then return true end
  if srcName and playerName and srcName == playerName then return true end
  local pet = UnitGUID("pet");     if pet and srcGUID == pet then return true end
  local veh = UnitGUID("vehicle"); if veh and srcGUID == veh then return true end
  return false
end

-- ==== Tooltip: only show on ATTACKABLE mobs ====
local function TooltipUnit(tt)
  local _, unit = tt:GetUnit()
  if not unit or not UnitExists(unit) then return end
  if UnitIsPlayer(unit) then return end
  if not UnitCanAttack("player", unit) then return end -- hide for own-faction/friendlies
  local guid = UnitGUID(unit)
  if not (guid and isCreatureGUID(guid)) then return end
  local id = npcIdFromGUID(guid)
  local cnt = 0
  if id then
    cnt = killsById[id] or 0
    noteNameId(UnitName(unit), id)
  else
    local nm = UnitName(unit)
    cnt = killsByName[nm] or 0
  end
  tt:AddLine("Killed: "..cnt, 1,1,1)
  tt:Show()
end

if GameTooltip and GameTooltip.HookScript then
  GameTooltip:HookScript("OnTooltipSetUnit", TooltipUnit)
else
  local prev = GameTooltip:GetScript("OnTooltipSetUnit")
  GameTooltip:SetScript("OnTooltipSetUnit", function(tt, ...)
    if prev then prev(tt, ...) end
    TooltipUnit(tt)
  end)
end

-- ==== Simple config frame (/mobcount) ====
local cfgFrame
local function updateClearButtonState()
  if cfgFrame and cfgFrame.clearBtn then
    if isLocked() then
      cfgFrame.clearBtn:Disable()
      cfgFrame.clearBtn:SetText("Locked")
    else
      cfgFrame.clearBtn:Enable()
      cfgFrame.clearBtn:SetText("Clear (This Character)")
    end
  end
end

local function CreateConfigFrame()
  local f = CreateFrame("Frame", "DWD_MobCountFrame", UIParent)
  f:SetSize(520, 430)
  f:SetPoint("CENTER")
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true, tileSize=16, edgeSize=16,
    insets={left=4,right=4,top=4,bottom=4}
  })
  f:SetBackdropColor(0,0,0,0.85)
  local title = f:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
  title:SetPoint("TOP",0,-12); title:SetText("DWD MobCount")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",-4,-4)

  local function Header(text, x)
    local b = CreateFrame("Frame", nil, f)
    b:SetSize(160, 18); b:SetPoint("TOPLEFT", x, -36)
    local fs = b:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    fs:SetPoint("LEFT",0,0); fs:SetText(text)
    local ul = b:CreateTexture(nil,"BACKGROUND")
    ul:SetTexture("Interface\\Buttons\\WHITE8x8")
    ul:SetVertexColor(1,1,1,0.4); ul:SetHeight(1)
    ul:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, -1)
    ul:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, -1)
    return b
  end
  Header("NPC ID / Name", 12); Header("Kills", 360)

  local scroll = CreateFrame("ScrollFrame", "DWD_MobCountScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -56); scroll:SetPoint("BOTTOMRIGHT", -28, 52)
  local content = CreateFrame("Frame", "DWD_MobCountScrollChild", scroll)
  content:SetSize(480, 360); scroll:SetScrollChild(content)
  f.content = content; content.rows = {}

  local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  clear:SetSize(180,22); clear:SetPoint("BOTTOM",0,12)
  clear:SetText("Clear (This Character)")
  clear:SetScript("OnClick", function()
    if isLocked() then
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Data is locked. Use /mobcount lock to unlock.")
      return
    end
    StaticPopup_Show("DWDMOBCOUNT_CLEAR")
  end)
  f.clearBtn = clear

  f:Hide(); return f
end

StaticPopupDialogs["DWDMOBCOUNT_CLEAR"] = {
  text="Clear ALL saved counts for this character?",
  button1=YES, button2=NO,
  OnAccept=function()
    if isLocked() then
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Clear blocked (locked). Use /mobcount lock to unlock.")
      return
    end
    killsById, namesById, killsByName = {}, {}, {}
    DWD_MobCountDB[charKey] = { killsById = killsById, namesById = namesById, killsByName = killsByName }
    snapshotToBackup() -- also wipe backup for this char
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Cleared.")
  end,
  timeout=0, whileDead=true, hideOnEscape=true, preferredIndex=3,
}

local function ShowConfig()
  if not cfgFrame then cfgFrame = CreateConfigFrame() end
  ensureCharTables()

  local arr = {}
  for id,c in pairs(killsById) do table.insert(arr, {name=(namesById[id] or ("NPC "..id)), cnt=c}) end
  for nm,c in pairs(killsByName) do table.insert(arr, {name=nm, cnt=c}) end
  table.sort(arr, function(a,b) if a.cnt==b.cnt then return a.name < b.name end return a.cnt > b.cnt end)

  local parent = cfgFrame.content; local rows = parent.rows
  local y = -2
  for i,row in ipairs(arr) do
    local line = rows[i]
    if not line then
      line = CreateFrame("Frame", nil, parent); line:SetSize(480,18)
      local left = line:CreateFontString(nil,"OVERLAY","GameFontNormal")
      left:SetPoint("LEFT",0,0); left:SetWidth(340); left:SetJustifyH("LEFT"); line.left = left
      local right = line:CreateFontString(nil,"OVERLAY","GameFontNormal")
      right:SetPoint("LEFT",360,0); right:SetWidth(100); right:SetJustifyH("RIGHT"); line.right = right
      rows[i]=line
    end
    line:SetPoint("TOPLEFT",0,y-(i-1)*18)
    line.left:SetText(row.name)
    line.right:SetText(row.cnt)
    line:Show()
  end
  for j=#arr+1, #rows do rows[j]:Hide() end
  parent:SetSize(480, math.max(360, (#arr)*18 + 6))
  updateClearButtonState()
  cfgFrame:Show()
end

-- ==== Core: attribute YOUR kills ====
local TAG_TTL = 20 -- seconds window for fallbacks

local TAG_EVENTS = {
  SWING_DAMAGE=true, SWING_MISSED=true,
  RANGE_DAMAGE=true, RANGE_MISSED=true,
  SPELL_DAMAGE=true, SPELL_MISSED=true,
  SPELL_PERIODIC_DAMAGE=true, SPELL_PERIODIC_MISSED=true,
  DAMAGE_SHIELD=true, DAMAGE_SPLIT=true,
}

local function isCreatureGUID(g) return isCreatureGUID_hex(g) or isCreatureGUID_dash(g) end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")                -- just to snapshot
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("COMBAT_TEXT_UPDATE")           -- KILLING_BLOW
frame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")-- "X dies."

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    -- noop

  elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    local realm = GetRealmName() or "UnknownRealm"
    playerName   = UnitName("player") or "Unknown"
    charKey      = realm.."-"..playerName
    playerGUID   = UnitGUID("player")
    ensureCharTables()
    maybeRestoreFromBackup()
    if event == "PLAYER_LOGIN" then
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Loaded. /mobcount (config|clear|debug|lock|restore).")
    end

  elseif event == "PLAYER_LOGOUT" then
    snapshotToBackup()

  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    -- *** WRATH ORDER ***
    local timestamp, subevent,
          srcGUID, srcName, srcFlags,
          dstGUID, dstName, dstFlags = ...

    -- cache + name->id map
    if dstGUID and dstName and dstName ~= "" then
      nameByGUID[dstGUID] = dstName
      local nid = npcIdFromGUID(dstGUID)
      if nid then noteNameId(dstName, nid) end
    end

    -- tag when we (or pet/vehicle) damage a creature
    if dstGUID and TAG_EVENTS[subevent] and isCreatureGUID(dstGUID) and isMineSource(srcGUID, srcName) then
      local now = GetTime()
      taggedGUID[dstGUID] = now
      if dstName and dstName ~= "" then taggedName[dstName] = now end
      dprint("tag", subevent, dstName or dstGUID)
    end

    -- credit on PARTY_KILL
    if subevent == "PARTY_KILL" and dstGUID and isCreatureGUID(dstGUID) and isMineSource(srcGUID, srcName) then
      local now = GetTime()
      if not counted[dstGUID] or (now - counted[dstGUID]) > 2 then
        ensureCharTables()
        local id = npcIdFromGUID(dstGUID)
        local nm = dstName or nameByGUID[dstGUID] or ""
        if id then creditKillById(id, nm) else creditKillByName(nm) end
        dprint("kill(PARTY_KILL)", id or "name", nm)
        counted[dstGUID] = now
      end
      return
    end

    -- fallback: UNIT_DIED for recently tagged
    if subevent == "UNIT_DIED" and dstGUID and isCreatureGUID(dstGUID) then
      local t = taggedGUID[dstGUID]
      if t and (GetTime() - t) <= TAG_TTL then
        local now = GetTime()
        if not counted[dstGUID] or (now - counted[dstGUID]) > 2 then
          ensureCharTables()
          local id = npcIdFromGUID(dstGUID)
          local nm = dstName or nameByGUID[dstGUID] or ""
          if id then creditKillById(id, nm) else creditKillByName(nm) end
          dprint("kill(UNIT_DIED)", id or "name", nm)
          counted[dstGUID] = now
        end
      end
      taggedGUID[dstGUID] = nil
    end

  elseif event == "COMBAT_TEXT_UPDATE" then
    local action, victim = ...
    if action == "KILLING_BLOW" and victim then
      ensureCharTables()
      local id = recentIdForName(victim, 30)
      if id then creditKillById(id, victim) else creditKillByName(victim) end
      dprint("kb", id or "name", victim)
    end

  elseif event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
    local msg = ...
    local victim = msg and msg:match("^(.+) dies%.$") or msg:match("^(.+) is slain ")
    if victim then
      local now = GetTime()
      local taggedAt = taggedName[victim]
      if taggedAt and (now - taggedAt) <= TAG_TTL then
        ensureCharTables()
        local id = recentIdForName(victim, 30)
        if id then creditKillById(id, victim) else creditKillByName(victim) end
        dprint("hostile_death", id or "name", victim)
      end
    end
  end
end)

-- ==== Slash commands ====
SLASH_DWDMOBCOUNT1 = "/mobcount"
SLASH_DWDMOBCOUNT2 = "/MobCount"
SlashCmdList["DWDMOBCOUNT"] = function(msg)
  local m = trim(msg)
  if m == "" or m == "config" or m == "show" or m == "list" then
    if not cfgFrame then cfgFrame = CreateConfigFrame() end
    ShowConfig()
  elseif m == "clear" or m == "reset" then
    if isLocked() then
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Clear blocked (locked). Use /mobcount lock to unlock.")
    else
      StaticPopup_Show("DWDMOBCOUNT_CLEAR")
    end
  elseif m == "debug" then
    DEBUG = not DEBUG
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r debug "..(DEBUG and "ON" or "OFF"))
  elseif m == "lock" then
    setLocked(not isLocked())
    updateClearButtonState()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Lock "..(isLocked() and "ENABLED" or "DISABLED"))
  elseif m == "restore" then
    local before = (not tempty(killsById)) or (not tempty(killsByName))
    maybeRestoreFromBackup()
    local after = (not tempty(killsById)) or (not tempty(killsByName))
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r Restore "..((not before and after) and "applied." or "no backup found / not needed."))
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00MobCount:|r /mobcount [config|clear|debug|lock|restore]")
  end
end
