local addonName, ns = ...

-- Main window: one Blizzard-style frame with three tabs (Library, Playlists,
-- Mixer) and the player bar along the bottom. Built on first open.

local UI = ns.UI
local Main = {}
ns.Main = Main

local WIDTH, HEIGHT = 780, 560
Main.PLAYER_BAR_HEIGHT = 92

local frame
local views = {}       -- [tabIndex] = { frame = ..., OnShow = fn }

local function SelectTab(index)
    PanelTemplates_SetTab(frame, index)
    for i, view in ipairs(views) do
        view.frame:SetShown(i == index)
    end
    frame.Search:SetShown(index == 1)
    ns.charDB.lastTab = index
    if views[index].OnShow then views[index].OnShow() end
end

local function Build()
    frame = CreateFrame("Frame", "MusicForeverFrame", UIParent, "ButtonFrameTemplate")
    ButtonFrameTemplate_HidePortrait(frame)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    if frame.SetTitle then frame:SetTitle("MusicForever") end
    frame.Inset:Hide()
    UI.RestorePosition(frame, ns.charDB.window)
    UI.MakeMovable(frame, function() return ns.charDB.window end)
    tinsert(UISpecialFrames, "MusicForeverFrame")   -- Escape closes it
    frame:Hide()

    -- content area between the title bar and the player bar
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 10, -58)
    content:SetPoint("BOTTOMRIGHT", -10, Main.PLAYER_BAR_HEIGHT + 8)
    frame.Content = content

    -- search (Library tab)
    local search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
    search:SetSize(220, 20)
    search:SetPoint("TOPRIGHT", -16, -30)
    search:SetMaxLetters(40)
    frame.Search = search

    -- tabs under the frame
    local names = { ns.L["Library"], ns.L["Playlists"], ns.L["Mixer"] }
    for i, name in ipairs(names) do
        local tab = CreateFrame("Button", "MusicForeverFrameTab" .. i, frame, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(name)
        tab:SetScript("OnClick", function(self)
            PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
            SelectTab(self:GetID())
        end)
    end
    frame.Tabs[1]:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
    PanelTemplates_SetNumTabs(frame, #names)

    views[1] = ns.LibraryView.Build(content, search)
    views[2] = ns.PlaylistView.Build(content)
    views[3] = ns.MixerView.Build(content)
    ns.PlayerBar.Build(frame)

    frame:SetScript("OnShow", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
        SelectTab(ns.charDB.lastTab or 1)
    end)
    frame:SetScript("OnHide", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
    end)
end

function Main.Toggle()
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
end

function Main.Show(tab)
    if not frame then Build() end
    frame:Show()
    if tab then SelectTab(tab) end
end

function Main.IsShown()
    return frame ~= nil and frame:IsShown()
end
