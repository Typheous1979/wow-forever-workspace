local addonName, ns = ...

-- Addon compartment (minimap dropdown) callbacks. These must be GLOBAL and named
-- exactly as in the TOC (AddonCompartmentFunc / OnEnter / OnLeave).

function MusicForever_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then
        ns.OpenOptions()
    else
        ns.Main.Toggle()
    end
end

function MusicForever_OnAddonCompartmentEnter(_, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("MusicForever")
    local id = ns.Player.GetNowPlaying()
    if id and ns.Player.IsPlaying() then
        GameTooltip:AddLine(ns.Library.TrackName(id), 0.4, 0.8, 1)
        GameTooltip:AddLine(ns.Library.Where(id), 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(ns.L["Game music"], 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(ns.L["Left-click: open. Right-click: options."], 1, 1, 1)
    GameTooltip:Show()
end

function MusicForever_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
