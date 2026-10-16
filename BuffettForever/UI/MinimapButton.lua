local addonName, ns = ...

-- Minimap button. Named "BuffettForeverMinimapButton" and parented to Minimap, so minimap-button
-- collectors such as MinimapButtonButton gather it automatically (they collect Minimap
-- children whose name contains "MinimapButton").
-- Left-click: window. Right-click: options. Drag: move around the minimap edge (the
-- angle is saved account-wide in ns.db.minimap).

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local ICON = "Interface\\AddOns\\BuffettForever\\Media\\Icon.tga"
local button

local function Position()
    return ns.db.minimap
end

local function UpdatePosition()
    local angle = math.rad(Position().angle or 200)
    local radius = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    Position().angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
    UpdatePosition()
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("BuffettForever")
    GameTooltip:AddLine(ns.L["by Typheous"], 0.62, 0.62, 0.62)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns.L["Left-click: open. Right-click: options."], 1, 1, 1)
    GameTooltip:AddLine(ns.L["Drag: move."], 1, 1, 1)
    GameTooltip:Show()
end

local function Build()
    button = CreateFrame("Button", "BuffettForeverMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(24, 24)
    background:SetPoint("CENTER")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            if ns.OpenOptions then ns.OpenOptions() end
        elseif ns.Main then
            ns.Main.Toggle()
        end
    end)
    button:SetScript("OnMouseDown", function(self) self.icon:SetPoint("CENTER", 1, -1) end)
    button:SetScript("OnMouseUp", function(self) self.icon:SetPoint("CENTER", 0, 0) end)
    button:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self:SetScript("OnUpdate", OnDragUpdate)
        GameTooltip:Hide()
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)

    UpdatePosition()
end

-- Called from ADDON_LOADED, before minimap-button collectors scan at login.
function MinimapButton.Init()
    if not button then Build() end
    button:SetShown(Position().shown ~= false)
end

function MinimapButton.SetShown(shown)
    Position().shown = shown and true or false
    if button then button:SetShown(shown) end
end

function MinimapButton.Toggle()
    MinimapButton.SetShown(Position().shown == false)
end
