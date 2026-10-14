local addonName, ns = ...

-- Compact, movable now-playing strip for use while the main window is closed.
-- Turned on in Options or with /mf mini.

local UI = ns.UI
local Library = ns.Library
local Player = ns.Player
local MiniPlayer = {}
ns.MiniPlayer = MiniPlayer

local frame

local function Build()
    frame = CreateFrame("Frame", "MusicForeverMiniPlayer", UIParent, "BackdropTemplate")
    frame:SetSize(300, 52)
    frame:SetFrameStrata("MEDIUM")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetBackdropBorderColor(0.4, 0.6, 1, 0.9)
    UI.RestorePosition(frame, ns.charDB.mini, "TOP", 0, -120)
    UI.MakeMovable(frame, function() return ns.charDB.mini end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)

    local prev = UI.Button(frame, "<<", 32, function() Player.Previous() end, 18)
    prev:SetPoint("BOTTOMLEFT", 8, 7)
    local play = UI.Button(frame, ns.L["Play"], 50, function() Player.TogglePlay() end, 18)
    play:SetPoint("LEFT", prev, "RIGHT", 2, 0)
    local nextB = UI.Button(frame, ">>", 32, function() Player.Next() end, 18)
    nextB:SetPoint("LEFT", play, "RIGHT", 2, 0)
    local revert = UI.Button(frame, ns.L["Game music"], 86, function() Player.ReturnToGame() end, 18)
    revert:SetPoint("LEFT", nextB, "RIGHT", 6, 0)
    UI.Tooltip(revert, ns.L["Return to game music"])
    local open = UI.Button(frame, "...", 30, function() ns.Main.Toggle() end, 18)
    open:SetPoint("BOTTOMRIGHT", -8, 7)
    UI.Tooltip(open, ns.L["Open MusicForever"])

    local function Update()
        local id = Player.GetNowPlaying()
        if id and Player.IsPlaying() then
            title:SetText("|cff66ccff" .. Library.TrackName(id) .. "|r  " .. Library.Where(id))
        else
            title:SetText(ns.L["Game music"])
        end
        play:SetText(Player.IsPlaying() and ns.L["Stop"] or ns.L["Play"])
    end
    ns.On("PLAYER_STATE", function() if frame:IsShown() then Update() end end)
    frame:SetScript("OnShow", Update)
    Update()
end

function MiniPlayer.Show()
    if not frame then Build() end
    frame:Show()
end

function MiniPlayer.Hide()
    if frame then frame:Hide() end
end

function MiniPlayer.SetEnabled(on)
    ns.db.settings.miniPlayer = on and true or false
    if on then MiniPlayer.Show() else MiniPlayer.Hide() end
end

function MiniPlayer.Toggle()
    MiniPlayer.SetEnabled(not ns.db.settings.miniPlayer)
end
