local addonName, ns = ...

-- Mixer tab: every volume channel (on/off + slider), the sound options, and
-- presets (built-in and your own, with one-step undo). WoW has no frequency
-- equalizer; this page is the game's full sound control surface instead.

local UI = ns.UI
local Mixer = ns.Mixer
local MixerView = {}
ns.MixerView = MixerView

function MixerView.Build(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local volumes = UI.Panel(frame)
    volumes:SetPoint("TOPLEFT")
    volumes:SetPoint("BOTTOMLEFT")
    volumes:SetWidth(430)

    local title = volumes:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText(ns.L["Volume"])

    local rows = {}
    local y = -40
    for _, ch in ipairs(ns.Channels) do
        if Mixer.IsChannelSupported(ch.key) then
            local check = UI.Check(volumes, ns.L[ch.label], function(on) Mixer.SetEnabled(ch.key, on) end)
            check:SetPoint("TOPLEFT", 12, y)
            UI.Tooltip(check, ns.L[ch.label], ns.L["Turn this sound channel on or off."])
            -- label column on the left, slider after it, its "%" label inside the panel
            local slider = UI.Slider(volumes, 210, function(value) Mixer.SetVolume(ch.key, value) end)
            slider:SetPoint("TOPLEFT", volumes, "TOPLEFT", 160, y)
            slider:SetPoint("TOPRIGHT", volumes, "TOPRIGHT", -(UI.SLIDER_LABEL_SPACE + 4), y)
            rows[#rows + 1] = { ch = ch, check = check, slider = slider }
            y = y - 34
        end
    end

    local right = UI.Panel(frame)
    right:SetPoint("TOPLEFT", volumes, "TOPRIGHT", 6, 0)
    right:SetPoint("BOTTOMRIGHT")

    local optTitle = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    optTitle:SetPoint("TOPLEFT", 12, -10)
    optTitle:SetText(ns.L["Sound options"])

    local options = {}
    y = -36
    for _, opt in ipairs(ns.SoundOptions) do
        if Mixer.IsOptionSupported(opt.key) then
            local check = UI.Check(right, ns.L[opt.label], function(on) Mixer.SetOption(opt.key, on) end)
            check:SetPoint("TOPLEFT", 12, y)
            UI.Tooltip(check, ns.L[opt.label], ns.L[opt.tip])
            options[#options + 1] = { opt = opt, check = check }
            y = y - 28
        end
    end

    -- presets
    local presetTitle = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    presetTitle:SetPoint("TOPLEFT", 12, y - 10)
    presetTitle:SetText(ns.L["Presets"])

    local apply = UI.Button(right, ns.L["Apply preset"], 130)
    apply:SetPoint("TOPLEFT", presetTitle, "BOTTOMLEFT", -2, -8)
    apply:SetScript("OnClick", function(self)
        MenuUtil.CreateContextMenu(self, function(_, root)
            local userStarted = false
            for _, p in ipairs(Mixer.GetPresets()) do
                if p.user and not userStarted then
                    root:CreateDivider()
                    userStarted = true
                end
                local button = root:CreateButton(p.name, function() Mixer.ApplyPreset(p) end)
                if p.desc then
                    button:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, p.name)
                        GameTooltip_AddNormalLine(tooltip, ns.L[p.desc])
                    end)
                end
            end
        end)
    end)

    local undo = UI.Button(right, ns.L["Undo"], 80, function() Mixer.Undo() end)
    undo:SetPoint("LEFT", apply, "RIGHT", 6, 0)

    local nameBox = UI.Input(right, 150, ns.L["New preset name"])
    nameBox:SetPoint("TOPLEFT", apply, "BOTTOMLEFT", 8, -10)
    local save = UI.Button(right, ns.L["Save"], 64)
    save:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
    local function Save()
        local name = strtrim(nameBox:GetText() or "")
        if name == "" then
            ns.Print(ns.L["Type a name for the preset first."])
            return
        end
        if Mixer.SaveUserPreset(name) then
            nameBox:SetText("")
            nameBox:ClearFocus()
        else
            ns.Print(ns.L["That name belongs to a built-in preset."])
        end
    end
    save:SetScript("OnClick", Save)
    nameBox:SetScript("OnEnterPressed", Save)
    UI.Tooltip(save, ns.L["Save"], ns.L["Save the current settings as your own preset."])

    local delete = UI.Button(right, ns.L["Delete preset"], 130)
    delete:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", -8, -8)
    delete:SetScript("OnClick", function(self)
        MenuUtil.CreateContextMenu(self, function(_, root)
            local any = false
            for _, p in ipairs(Mixer.GetPresets()) do
                if p.user then
                    any = true
                    root:CreateButton(p.name, function() Mixer.DeleteUserPreset(p.name) end)
                end
            end
            if not any then root:CreateTitle(ns.L["You have no saved presets yet."]) end
        end)
    end)

    local function Refresh()
        if not frame:IsVisible() then return end
        for _, r in ipairs(rows) do
            local enabled = Mixer.IsEnabled(r.ch.key)
            r.check:SetChecked(enabled)
            r.slider:SetValueSilently(Mixer.GetVolume(r.ch.key))
            r.slider:SetEnabled(enabled and (r.ch.key == "master" or Mixer.IsEnabled("master")))
        end
        for _, o in ipairs(options) do
            o.check:SetChecked(Mixer.GetOption(o.opt.key))
        end
        local canUndo, name = Mixer.CanUndo()
        undo:SetEnabled(canUndo)
        if canUndo then
            undo.tooltipText = string.format(ns.L["Undo %s"], name or "")
        end
    end

    ns.On("MIXER_CHANGED", Refresh)
    ns.On("PRESETS_CHANGED", Refresh)

    return { frame = frame, OnShow = Refresh }
end
