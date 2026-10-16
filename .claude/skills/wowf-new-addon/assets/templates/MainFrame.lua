local addonName, ns = ...

-- Main window: a Blizzard-style frame (ButtonFrameTemplate) with the title, Escape to
-- close and a saved position. Built on first open. Put your content in Main.Content;
-- ns.On("MAIN_BUILT", function(frame, content) ... end) runs once it exists.

local UI = ns.UI
local Main = {}
ns.Main = Main

local WIDTH, HEIGHT = 640, 440
local FRAME_NAME = "${NAME}Frame"

local frame

local function Store()
    return $WINDOW_STORE.window
end

local function Build()
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    ButtonFrameTemplate_HidePortrait(frame)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    if frame.SetTitle then frame:SetTitle("$TITLE") end
    frame.Inset:Hide()
    UI.RestorePosition(frame, Store())
    UI.MakeMovable(frame, Store)
    tinsert(UISpecialFrames, FRAME_NAME)   -- Escape closes it

$WINDOW_SIGNATURE    frame:Hide()

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 10, -30)
    content:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.Content = content
    Main.Content = content

    frame:SetScript("OnShow", function() PlaySound(SOUNDKIT.IG_MAINMENU_OPEN) end)
    frame:SetScript("OnHide", function() PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE) end)
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
