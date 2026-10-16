local addonName, ns = ...

-- Addon compartment (minimap dropdown) callbacks. These must be GLOBAL and named
-- exactly as in the TOC (AddonCompartmentFunc / OnEnter / OnLeave).

function ${NAME}_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" and ns.OpenOptions then
        ns.OpenOptions()
    else
        ns.Main.Toggle()
    end
end

function ${NAME}_OnAddonCompartmentEnter(_, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("$TITLE")
$TOOLTIP_SIGNATURE    GameTooltip:AddLine(ns.L["Left-click: open. Right-click: options."], 1, 1, 1)
    GameTooltip:Show()
end

function ${NAME}_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
