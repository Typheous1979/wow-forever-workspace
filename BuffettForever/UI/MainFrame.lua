local addonName, ns = ...

-- Main window. Three panes: the reagent tray and the top pick (left), the craftable items
-- with their cost, sale values and ROI (middle), the selected item's details (right), and a
-- status line for the auction data with the Scan button (enabled only at an auctioneer).
-- The status line works since M1; the panes fill in from M3 (see CLAUDE.md). Built on first open.

local UI = ns.UI
local L = ns.L
local Main = {}
ns.Main = Main

local WIDTH, HEIGHT = 900, 560
local FRAME_NAME = "BuffettForeverFrame"
local TRAY_SLOTS, TRAY_COLUMNS = 10, 5
local SLOT_SIZE, SLOT_GAP = 36, 8
local LEFT_WIDTH, RIGHT_WIDTH, PICK_HEIGHT = 232, 260, 150
local COLUMNS = { "Cost", "Vendor", "AH", "Best", "Profit", "ROI" }   -- right-aligned, after Item
local COLUMN_WIDTH = 56
local EMPTY_SLOT = "Interface\\Buttons\\UI-EmptySlot-Disabled"     -- Blizzard's empty-slot art

local frame

local function Store()
    return ns.charDB.window
end

local function Note(parent, text, width, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontDisableSmall")
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

local function BuildTray(content)
    local panel = UI.TitledPanel(content, L["Reagents"])
    panel:SetPoint("TOPLEFT")
    panel:SetPoint("BOTTOMLEFT", 0, PICK_HEIGHT + 6)
    panel:SetWidth(LEFT_WIDTH)
    panel.slots = {}
    for i = 1, TRAY_SLOTS do
        local slot = CreateFrame("Button", nil, panel)
        slot:SetSize(SLOT_SIZE, SLOT_SIZE)
        local col, row = (i - 1) % TRAY_COLUMNS, math.floor((i - 1) / TRAY_COLUMNS)
        slot:SetPoint("TOPLEFT", 10 + col * (SLOT_SIZE + SLOT_GAP), -30 - row * (SLOT_SIZE + SLOT_GAP))
        local bg = slot:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture(EMPTY_SLOT)
        bg:SetSize(45, 45)
        bg:SetPoint("CENTER", 0, -1)
        bg:SetTexCoord(0.140625, 0.84375, 0.140625, 0.84375)
        UI.Tooltip(slot, L["Empty reagent slot"], L["Drag a reagent here, or Alt+Right-click it in your bags."])
        panel.slots[i] = slot
    end
    local rows = math.ceil(TRAY_SLOTS / TRAY_COLUMNS)
    local hint = Note(panel, L["Drop up to 10 reagents to see every recipe that uses them."], LEFT_WIDTH - 20)
    hint:SetPoint("TOPLEFT", 10, -30 - rows * (SLOT_SIZE + SLOT_GAP) - 2)
    return panel
end

local function BuildPick(content)
    local panel = UI.TitledPanel(content, L["Top pick"])
    panel:SetPoint("BOTTOMLEFT")
    panel:SetSize(LEFT_WIDTH, PICK_HEIGHT)
    panel.Text = Note(panel, L["The best return on investment, and where to sell it, shows here."], LEFT_WIDTH - 20,
        "GameFontHighlightSmall")
    panel.Text:SetPoint("TOPLEFT", 10, -28)
    return panel
end

local function BuildDetails(content)
    local panel = UI.TitledPanel(content, L["Details"])
    panel:SetPoint("TOPRIGHT")
    panel:SetPoint("BOTTOMRIGHT")
    panel:SetWidth(RIGHT_WIDTH)
    panel.Text = Note(panel, L["Select an item to see the reagents it needs, what each costs at a vendor or the Auction House, and where to sell the result."],
        RIGHT_WIDTH - 20)
    panel.Text:SetPoint("TOPLEFT", 10, -28)
    return panel
end

local function BuildResults(content, tray, details)
    local panel = UI.TitledPanel(content, L["Craftable items"])
    panel:SetPoint("TOPLEFT", tray, "TOPRIGHT", 6, 0)
    panel:SetPoint("BOTTOMRIGHT", details, "BOTTOMLEFT", -6, 0)

    local item = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    item:SetPoint("TOPLEFT", 10, -28)
    item:SetText(L["Item"])
    local x = -22   -- room for the scroll bar
    for i = #COLUMNS, 1, -1 do
        local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPRIGHT", x, -28)
        header:SetWidth(COLUMN_WIDTH)
        header:SetJustifyH("RIGHT")
        header:SetText(L[COLUMNS[i]])
        x = x - COLUMN_WIDTH
    end
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.12)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 6, -42)
    divider:SetPoint("TOPRIGHT", -6, -42)

    local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER", 0, -10)
    empty:SetWidth(280)
    empty:SetText(L["Drop a reagent into the tray to see what it can make, what that costs and what it sells for."])
    panel.Empty = empty
    return panel
end

local function Build()
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    ButtonFrameTemplate_HidePortrait(frame)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    if frame.SetTitle then frame:SetTitle("BuffettForever") end
    frame.Inset:Hide()
    UI.RestorePosition(frame, Store())
    UI.MakeMovable(frame, Store)
    tinsert(UISpecialFrames, FRAME_NAME)   -- Escape closes it

    local signature = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    signature:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -12, -6)
    signature:SetText(L["by Typheous"])
    frame:Hide()

    local scan = UI.Button(frame, L["Scan"], 90, function() ns.Scanner.Start() end)
    scan:SetPoint("TOPRIGHT", -14, -31)
    scan:SetMotionScriptsWhileDisabled(true)   -- the tooltip explains why it is disabled
    scan:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["Full scan"], 1, 1, 1)
        GameTooltip:AddLine(L["Reads every listing on the Auction House and updates the stored prices."], nil, nil, nil, true)
        local ok, why = ns.Scanner.CanScan()
        if not ok then GameTooltip:AddLine(why, 1, 0.3, 0.3, true) end
        local hint = ns.Scanner.CooldownHint()
        if hint then GameTooltip:AddLine(hint, 1, 0.82, 0, true) end
        GameTooltip:Show()
    end)
    scan:SetScript("OnLeave", GameTooltip_Hide)
    frame.ScanButton = scan

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", 18, -36)
    status:SetPoint("TOPRIGHT", scan, "TOPLEFT", -8, -5)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    frame.Status = status

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 10, -58)
    content:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.Content = content
    Main.Content = content

    frame.Tray = BuildTray(content)
    frame.Pick = BuildPick(content)
    frame.Details = BuildDetails(content)
    frame.Results = BuildResults(content, frame.Tray, frame.Details)

    frame:SetScript("OnShow", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
        Main.RefreshStatus()
    end)
    frame:SetScript("OnHide", function() PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE) end)
    Main.RefreshStatus()
    ns.Fire("MAIN_BUILT", frame, content)
end

function Main.Toggle()
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
end

function Main.Show()
    if not frame then Build() end
    frame:Show()
end

function Main.Hide()
    if frame then frame:Hide() end
end

function Main.IsShown()
    return frame ~= nil and frame:IsShown()
end

function Main.GetFrame()
    if not frame then Build() end
    return frame
end

-- Status line and Scan button, from the scanner's state.
function Main.RefreshStatus()
    if not frame then return end
    frame.Status:SetText(ns.Scanner.StatusText())
    frame.ScanButton:SetEnabled((ns.Scanner.CanScan()))
end

for _, message in ipairs({ "SCAN_PROGRESS", "SCAN_DONE", "AH_OPEN", "AH_CLOSED", "READ_ONLY" }) do
    ns.On(message, Main.RefreshStatus)
end
