local addonName, ns = ...

-- Small builders over Blizzard's shared templates (all present on Forever 70374):
-- UIPanelButtonTemplate, UICheckButtonTemplate, MinimalSliderWithSteppersTemplate,
-- InputBoxTemplate, WowScrollBoxList + MinimalScrollBar with the ScrollBox list views.

local UI = {}
ns.UI = UI

UI.ROW_HEIGHT = 20
UI.HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
UI.BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

function UI.Button(parent, text, width, onClick, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, height or 22)
    b:SetText(text)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

function UI.Tooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title, 1, 1, 1)
        if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", GameTooltip_Hide)
end

function UI.Check(parent, label, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c.Text:SetText(label)
    c.Text:SetFontObject("GameFontHighlight")
    if onClick then
        c:SetScript("OnClick", function(self)
            PlaySound(self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            onClick(self:GetChecked() and true or false)
        end)
    end
    return c
end

-- 0..1 slider showing a percentage on the right. onChange(value) only fires for
-- user changes, not for SetValueSilently.
function UI.Slider(parent, width, onChange)
    local s = CreateFrame("Frame", nil, parent, "MinimalSliderWithSteppersTemplate")
    s:SetWidth(width or 220)
    s:SetHeight(24)
    local formatters = {
        [MinimalSliderWithSteppersMixin.Label.Right] = function(value)
            return string.format("%d%%", math.floor(value * 100 + 0.5))
        end,
    }
    s:Init(0, 0, 1, 20, formatters)
    s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if not s.silent and onChange then onChange(value) end
    end, s)
    function s:SetValueSilently(value)
        self.silent = true
        self:SetValue(value)
        self.silent = false
    end
    return s
end

function UI.Input(parent, width, instructions)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width or 160, 20)
    e:SetAutoFocus(false)
    e:SetMaxLetters(48)
    if instructions then
        local hint = e:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("LEFT", 2, 0)
        hint:SetText(instructions)
        local function update() hint:SetShown(e:GetText() == "" and not e:HasFocus()) end
        e:HookScript("OnTextChanged", update)
        e:HookScript("OnEditFocusGained", update)
        e:HookScript("OnEditFocusLost", update)
    end
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

-- A titled box with a dark inset background.
function UI.Panel(parent)
    local f = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
    return f
end

-- Scrolling list. view: CreateScrollBoxListLinearView or CreateScrollBoxListTreeListView.
function UI.ScrollList(parent, view)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    box:SetPoint("TOPLEFT", 4, -4)
    box:SetPoint("BOTTOMRIGHT", -18, 4)
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, -2)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 2)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    return box, bar
end

-- Shared look for list rows: highlight, selection tint, left and right text.
function UI.SetupRow(row)
    if row.isSetUp then return end
    row.isSetUp = true
    row:SetHeight(UI.ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture(UI.HIGHLIGHT)
    hl:SetBlendMode("ADD")
    hl:SetAllPoints()
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetColorTexture(0.25, 0.5, 1, 0.25)
    row.selected:SetAllPoints()
    row.selected:Hide()
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", -6, 0)
    row.right:SetJustifyH("RIGHT")
    row.left:SetPoint("RIGHT", row.right, "LEFT", -8, 0)
end

function UI.SavePosition(frame, store)
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    store.point, store.relativePoint, store.x, store.y = point, relativePoint, x, y
end

function UI.RestorePosition(frame, store, defaultPoint, defaultX, defaultY)
    frame:ClearAllPoints()
    if store and store.point then
        frame:SetPoint(store.point, UIParent, store.relativePoint or store.point, store.x or 0, store.y or 0)
    else
        frame:SetPoint(defaultPoint or "CENTER", UIParent, defaultPoint or "CENTER", defaultX or 0, defaultY or 0)
    end
end

function UI.MakeMovable(frame, store)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI.SavePosition(self, store())
    end)
end
