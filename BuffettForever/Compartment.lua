local addonName, ns = ...

-- Addon compartment (minimap dropdown) callbacks. These must be GLOBAL and named
-- exactly as in the TOC (AddonCompartmentFunc / OnEnter / OnLeave).

function BuffettForever_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" and ns.OpenOptions then
        ns.OpenOptions()
    else
        ns.Main.Toggle()
    end
end

function BuffettForever_OnAddonCompartmentEnter(_, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("BuffettForever")
    GameTooltip:AddLine(ns.L["by Typheous"], 0.62, 0.62, 0.62)
    GameTooltip:AddLine(ns.L["Left-click: open. Right-click: options."], 1, 1, 1)
    GameTooltip:Show()
end

function BuffettForever_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
