-- DWD_MobCount_ConfigUI.lua — Interface→AddOns config for wording & colors
-- Builds immediately and exposes DWD_MobCount_OpenConfig() for /mobcount config

-- Safe defaults (use live table if already created by core)
DWD_MobCountConfig = DWD_MobCountConfig or {
  textStyle  = "TOTAL_KILLED",
  labelColor = { r=1, g=0.82, b=0 },
  valueColor = { r=1, g=1,    b=1 },
}

-- Fallback BuildKillLine in case core hasn't defined it yet (first load order, etc.)
if not DWD_MobCount_BuildKillLine then
  local function toHex(c)
    local r=math.floor(((c.r or 1)*255)+0.5)
    local g=math.floor(((c.g or 1)*255)+0.5)
    local b=math.floor(((c.b or 1)*255)+0.5)
    return string.format("%02X%02X%02X", r,g,b)
  end
  local MAP = {
    KILLED        = { label="Killed",       order="label_first" },
    TOTAL_KILLED  = { label="Total Killed", order="label_first" },
    COUNT_KILLED  = { label="Killed",       order="count_first" },
    SLAIN         = { label="Slain",        order="label_first" },
    TOTAL_SLAIN   = { label="Total Slain",  order="label_first" },
    COUNT_SLAIN   = { label="Slain",        order="count_first" },
	YEETED        = { label="Yeeted",       order="label_first" },
	TOTAL_YEETED  = { label="Total Yeeted", order="label_first" },
	COUNT_YEETED  = { label="Yeeted",       order="count_first" },
  }
  function DWD_MobCount_BuildKillLine(styleID, count)
    local s = MAP[styleID] or MAP.TOTAL_KILLED
    local L = ("|cFF%s%s|r"):format(toHex(DWD_MobCountConfig.labelColor), s.label)
    local V = ("|cFF%s%s|r"):format(toHex(DWD_MobCountConfig.valueColor), tostring(count))
    return (s.order=="count_first") and (V.." "..L) or (L..": "..V)
  end
end

local PANEL_NAME = "DWD MobCount - Tooltip"
local panel = CreateFrame("Frame", "DWD_MobCount_TooltipOptions", UIParent)
panel.name = PANEL_NAME

-- Title
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("DWD MobCount — Tooltip Options")

-- Wording dropdown
local ddLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
ddLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
ddLabel:SetText("Tooltip Wording")

local dropdown = CreateFrame("Frame", "DWD_MobCount_WordingDD", panel, "UIDropDownMenuTemplate")
dropdown:SetPoint("TOPLEFT", ddLabel, "BOTTOMLEFT", -16, -6)

local STYLE_OPTIONS = {
  { key="KILLED",        label="Killed: {count}"      },
  { key="TOTAL_KILLED",  label="Total Killed: {count}"},
  { key="COUNT_KILLED",  label="{count} Killed"       },
  { key="SLAIN",         label="Slain: {count}"       },
  { key="TOTAL_SLAIN",   label="Total Slain: {count}" },
  { key="COUNT_SLAIN",   label="{count} Slain"        },
  { key="YEETED",         label="Yeeted: {count}"       },
  { key="TOTAL_YEETED",  label="Total Yeeted: {count}"},
  { key="COUNT_YEETED",  label="{count} Yeeted"       },
}

local function SetDDText(text)
  local fs = _G[dropdown:GetName() .. "Text"]; if fs then fs:SetText(text) end
end

local preview = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
preview:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 32, -24)
preview:SetText(DWD_MobCount_BuildKillLine(DWD_MobCountConfig.textStyle, 123))

local function UpdatePreview()
  preview:SetText(DWD_MobCount_BuildKillLine(DWD_MobCountConfig.textStyle, 123))
end

local function OnSelect(self, key)
  DWD_MobCountConfig.textStyle = key
  for _, opt in ipairs(STYLE_OPTIONS) do if opt.key==key then SetDDText(opt.label) break end end
  UpdatePreview()
end

local function InitializeDropdown(self, level)
  for _, opt in ipairs(STYLE_OPTIONS) do
    local info = UIDropDownMenu_CreateInfo()
    info.text, info.value = opt.label, opt.key
    info.func, info.arg1  = OnSelect, opt.key
    info.checked = (DWD_MobCountConfig.textStyle == opt.key)
    UIDropDownMenu_AddButton(info, level)
  end
end
UIDropDownMenu_Initialize(dropdown, InitializeDropdown)
dropdown:SetScript("OnShow", function() UIDropDownMenu_Initialize(dropdown, InitializeDropdown) end)

do
  local shown = "Total Killed: {count}"
  for _, o in ipairs(STYLE_OPTIONS) do if o.key == DWD_MobCountConfig.textStyle then shown = o.label break end end
  SetDDText(shown)
end

-- Label color
local labelTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
labelTitle:SetPoint("TOPLEFT", preview, "BOTTOMLEFT", 10, -18)
labelTitle:SetText("Label Color (e.g., 'Total Killed')")

local labelSwatch = CreateFrame("Button", "DWD_MobCount_LabelSwatch", panel)
labelSwatch:SetPoint("TOPLEFT", labelTitle, "BOTTOMLEFT", 0, -6)
labelSwatch:SetSize(16, 16)
labelSwatch:SetNormalTexture("Interface\\ChatFrame\\ChatFrameColorSwatch")
labelSwatch:GetNormalTexture():SetVertexColor(DWD_MobCountConfig.labelColor.r, DWD_MobCountConfig.labelColor.g, DWD_MobCountConfig.labelColor.b)
labelSwatch:SetScript("OnClick", function()
  local c = DWD_MobCountConfig.labelColor
  ColorPickerFrame.hasOpacity = false
  ColorPickerFrame.previousValues = { r=c.r, g=c.g, b=c.b }
  ColorPickerFrame.func = function()
    local r,g,b = ColorPickerFrame:GetColorRGB()
    DWD_MobCountConfig.labelColor = { r=r, g=g, b=b }
    labelSwatch:GetNormalTexture():SetVertexColor(r,g,b)
    UpdatePreview()
  end
  ColorPickerFrame.cancelFunc = function(prev)
    DWD_MobCountConfig.labelColor = { r=prev.r, g=prev.g, b=prev.b }
    labelSwatch:GetNormalTexture():SetVertexColor(prev.r,prev.g,prev.b)
    UpdatePreview()
  end
  ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
  ColorPickerFrame:Show()
end)

-- Value color
local valueTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
valueTitle:SetPoint("TOPLEFT", labelSwatch, "BOTTOMLEFT", 0, -16)
valueTitle:SetText("Number Color (e.g., '0')")

local valueSwatch = CreateFrame("Button", "DWD_MobCount_ValueSwatch", panel)
valueSwatch:SetPoint("TOPLEFT", valueTitle, "BOTTOMLEFT", 0, -6)
valueSwatch:SetSize(16, 16)
valueSwatch:SetNormalTexture("Interface\\ChatFrame\\ChatFrameColorSwatch")
valueSwatch:GetNormalTexture():SetVertexColor(DWD_MobCountConfig.valueColor.r, DWD_MobCountConfig.valueColor.g, DWD_MobCountConfig.valueColor.b)
valueSwatch:SetScript("OnClick", function()
  local c = DWD_MobCountConfig.valueColor
  ColorPickerFrame.hasOpacity = false
  ColorPickerFrame.previousValues = { r=c.r, g=c.g, b=c.b }
  ColorPickerFrame.func = function()
    local r,g,b = ColorPickerFrame:GetColorRGB()
    DWD_MobCountConfig.valueColor = { r=r, g=g, b=b }
    valueSwatch:GetNormalTexture():SetVertexColor(r,g,b)
    UpdatePreview()
  end
  ColorPickerFrame.cancelFunc = function(prev)
    DWD_MobCountConfig.valueColor = { r=prev.r, g=prev.g, b=prev.b }
    valueSwatch:GetNormalTexture():SetVertexColor(prev.r,prev.g,prev.b)
    UpdatePreview()
  end
  ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
  ColorPickerFrame:Show()
end)

-- Register panel and opener
if InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel) end
function DWD_MobCount_OpenConfig()
  if InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel) -- 3.x quirk
  end
end

-- Positive confirmation that THIS file executed
(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffffff00MobCount:|r Config UI loaded.")
