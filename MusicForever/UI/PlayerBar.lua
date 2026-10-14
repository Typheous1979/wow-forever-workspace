local addonName, ns = ...

-- Player bar along the bottom of the main window: transport buttons, now playing
-- with a progress bar, quick Music/Master volume, and Return to game music.

local UI = ns.UI
local Library = ns.Library
local Player = ns.Player
local Mixer = ns.Mixer
local PlayerBar = {}
ns.PlayerBar = PlayerBar

local REPEAT_TEXT = { all = "Repeat: All", one = "Repeat: One", off = "Repeat: Off" }

function PlayerBar.Build(main)
    local bar = UI.Panel(main)
    bar:SetPoint("BOTTOMLEFT", 10, 8)
    bar:SetPoint("BOTTOMRIGHT", -10, 8)
    bar:SetHeight(ns.Main.PLAYER_BAR_HEIGHT)

    -- row 1: transport + now playing
    local prev = UI.Button(bar, "<<", 40, function() Player.Previous() end)
    prev:SetPoint("TOPLEFT", 10, -10)
    UI.Tooltip(prev, ns.L["Previous"])
    local play = UI.Button(bar, ns.L["Play"], 64, function() Player.TogglePlay() end)
    play:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    local nextB = UI.Button(bar, ">>", 40, function() Player.Next() end)
    nextB:SetPoint("LEFT", play, "RIGHT", 4, 0)
    UI.Tooltip(nextB, ns.L["Next"])

    local repeatB = UI.Button(bar, ns.L[REPEAT_TEXT.all], 100, function() Player.CycleRepeat() end)
    repeatB:SetPoint("LEFT", nextB, "RIGHT", 10, 0)
    UI.Tooltip(repeatB, ns.L["Repeat"], ns.L["All: loop the list. One: loop this track. Off: stop at the end."])
    local shuffle = UI.Check(bar, ns.L["Shuffle"], function(on) Player.SetShuffle(on) end)
    shuffle:SetPoint("LEFT", repeatB, "RIGHT", 8, 0)

    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", shuffle, "TOPRIGHT", 70, 2)
    title:SetPoint("RIGHT", -12, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    local where = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    where:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    where:SetPoint("RIGHT", -12, 0)
    where:SetJustifyH("LEFT")
    where:SetWordWrap(false)

    -- row 2: progress
    local progress = CreateFrame("StatusBar", nil, bar)
    progress:SetStatusBarTexture(UI.BAR_TEXTURE)
    progress:SetStatusBarColor(0.25, 0.6, 1)
    progress:SetMinMaxValues(0, 1)
    progress:SetHeight(10)
    progress:SetPoint("TOPLEFT", 12, -40)
    progress:SetPoint("TOPRIGHT", -70, -40)
    local progressBg = progress:CreateTexture(nil, "BACKGROUND")
    progressBg:SetAllPoints()
    progressBg:SetColorTexture(0, 0, 0, 0.5)
    local timeText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timeText:SetPoint("LEFT", progress, "RIGHT", 8, 0)

    -- row 3: quick volume + return
    local musicLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    musicLabel:SetPoint("TOPLEFT", 12, -62)
    musicLabel:SetText(ns.L["Music"])
    local musicSlider = UI.Slider(bar, 180, function(v) Mixer.SetVolume("music", v) end)
    musicSlider:SetPoint("LEFT", musicLabel, "RIGHT", 2, 0)
    local masterLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    masterLabel:SetPoint("LEFT", musicSlider, "RIGHT", 10, 0)
    masterLabel:SetText(ns.L["Master"])
    local masterSlider = UI.Slider(bar, 180, function(v) Mixer.SetVolume("master", v) end)
    masterSlider:SetPoint("LEFT", masterLabel, "RIGHT", 2, 0)

    local revert = UI.Button(bar, ns.L["Return to game music"], 170, function() Player.ReturnToGame() end)
    revert:SetPoint("BOTTOMRIGHT", -10, 8)
    UI.Tooltip(revert, ns.L["Return to game music"],
        ns.L["Stop MusicForever's music. The game's own zone music takes over again."])

    -- shown when PlayMusic would be silent
    local muted = CreateFrame("Frame", nil, bar)
    muted:SetPoint("TOPLEFT", progress, "TOPLEFT")
    muted:SetPoint("BOTTOMRIGHT", progress, "BOTTOMRIGHT", 0, -2)
    muted:Hide()
    local mutedText = muted:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    mutedText:SetPoint("LEFT")
    mutedText:SetText(ns.L["Game music is turned off, so nothing can be heard."])
    local unmute = UI.Button(muted, ns.L["Turn music on"], 120, function()
        Mixer.SetEnabled("master", true)
        Mixer.SetEnabled("music", true)
        if Mixer.GetVolume("music") <= 0 then Mixer.SetVolume("music", 0.4) end
        if Mixer.GetVolume("master") <= 0 then Mixer.SetVolume("master", 0.5) end
    end, 18)
    unmute:SetPoint("LEFT", mutedText, "RIGHT", 8, 0)

    local function UpdateProgress()
        local id, elapsed, length = Player.GetNowPlaying()
        if not id or not Player.IsPlaying() then
            progress:SetValue(0)
            timeText:SetText("")
            return
        end
        if length and length > 0 then
            progress:SetValue(math.min(1, elapsed / length))
            timeText:SetText(Library.FormatTime(math.min(elapsed, length)) .. " / " .. Library.FormatTime(length))
        else
            progress:SetValue(1)
            timeText:SetText(Library.FormatTime(elapsed) .. " " .. ns.L["(loops)"])
        end
    end

    local function UpdateState()
        local id, _, _, label, pos, count = Player.GetNowPlaying()
        local playing = Player.IsPlaying()
        play:SetText(playing and ns.L["Stop"] or ns.L["Play"])
        repeatB:SetText(ns.L[REPEAT_TEXT[ns.db.settings.repeatMode] or REPEAT_TEXT.all])
        shuffle:SetChecked(ns.db.settings.shuffle)
        if id and playing then
            title:SetText(Library.TrackName(id))
            local text = label or Library.Where(id)
            if count and count > 1 then text = string.format("%s   ·   %d / %d", text, pos, count) end
            where:SetText(text)
        else
            title:SetText(ns.L["Game music"])
            where:SetText(ns.L["The game is choosing the music. Pick a track to take over."])
        end
        muted:SetShown(playing and not Mixer.IsMusicAudible())
        UpdateProgress()
    end

    local function UpdateVolumes()
        musicSlider:SetValueSilently(Mixer.GetVolume("music"))
        masterSlider:SetValueSilently(Mixer.GetVolume("master"))
        muted:SetShown(Player.IsPlaying() and not Mixer.IsMusicAudible())
    end

    local ticker
    bar:SetScript("OnShow", function()
        UpdateState()
        UpdateVolumes()
        ticker = C_Timer.NewTicker(0.5, UpdateProgress)
    end)
    bar:SetScript("OnHide", function()
        if ticker then ticker:Cancel(); ticker = nil end
    end)

    ns.On("PLAYER_STATE", function() if bar:IsVisible() then UpdateState() end end)
    ns.On("MIXER_CHANGED", function() if bar:IsVisible() then UpdateVolumes() end end)
    ns.On("MUSIC_MUTED", function() if bar:IsVisible() then muted:Show() end end)
end
