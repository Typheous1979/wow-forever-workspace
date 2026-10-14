local addonName, ns = ...

-- Player: plays catalog tracks with PlayMusic, keeps a queue, and hands the music
-- back to the game ("Return to game music") with StopMusic.
--
-- Facts this relies on (audio.md): PlayMusic(fileID) plays on the Music channel and
-- fades out the zone music; StopMusic() stops only addon-started music and the zone
-- music comes back by itself. There is no end-of-track event and no track-length
-- API, so the queue advances with timers using the catalog's lengths.

local Player = {}
ns.Player = Player

local GAP = 1.5            -- seconds of silence between queued tracks
local FADE_TIME = 1.2      -- seconds for the fade-out on Return to game music
local FADE_STEPS = 12

local state = {
    queue = {},            -- fileIDs
    order = {},            -- play order: indexes into queue (shuffled or not)
    pos = 0,               -- position in order
    label = nil,           -- what the queue came from ("Elwynn Forest")
    playing = false,
    current = nil,         -- fileID
    startedAt = 0,         -- GetTime() when the current track started
}
local advanceTimer, fadeTicker

local function Settings()
    return ns.db.settings
end

local function CancelAdvance()
    if advanceTimer then advanceTimer:Cancel(); advanceTimer = nil end
end

-- Fade ------------------------------------------------------------------------
-- The user's music volume is saved in charDB.fadeRestore before fading, so it is
-- restored even if the game closes mid-fade (OnLogout / OnLogin).

local function RestoreFadeVolume()
    if fadeTicker then fadeTicker:Cancel(); fadeTicker = nil end
    local saved = ns.charDB and ns.charDB.fadeRestore
    if saved then
        C_CVar.SetCVar("Sound_MusicVolume", saved)
        ns.charDB.fadeRestore = nil
    end
end

local function FadeOutThen(callback)
    local startValue = C_CVar.GetCVar("Sound_MusicVolume")
    local start = tonumber(startValue) or 0
    if not Settings().fadeOut or start <= 0 then
        callback()
        return
    end
    RestoreFadeVolume()
    ns.charDB.fadeRestore = startValue
    local step = 0
    fadeTicker = C_Timer.NewTicker(FADE_TIME / FADE_STEPS, function()
        step = step + 1
        local value = start * (1 - step / FADE_STEPS)
        -- the user moved the slider mid-fade: stop fading, keep their value, still stop
        if ns.charDB.fadeRestore == nil then
            fadeTicker:Cancel(); fadeTicker = nil
            callback()
            return
        end
        C_CVar.SetCVar("Sound_MusicVolume", string.format("%.2f", math.max(0, value)))
        if step >= FADE_STEPS then
            fadeTicker:Cancel(); fadeTicker = nil
            callback()
            -- give StopMusic a moment before the zone music comes back at full volume
            C_Timer.After(0.2, RestoreFadeVolume)
        end
    end, FADE_STEPS)
end

-- Queue -------------------------------------------------------------------------

local function BuildOrder(startIndex)
    wipe(state.order)
    for i = 1, #state.queue do state.order[i] = i end
    if Settings().shuffle and #state.order > 1 then
        for i = #state.order, 2, -1 do
            local j = math.random(i)
            state.order[i], state.order[j] = state.order[j], state.order[i]
        end
        -- keep the chosen track first
        if startIndex then
            for i, q in ipairs(state.order) do
                if q == startIndex then
                    state.order[1], state.order[i] = state.order[i], state.order[1]
                    break
                end
            end
        end
        state.pos = 1
    else
        state.pos = startIndex or 1
    end
end

local StartCurrent

local function ScheduleAdvance()
    CancelAdvance()
    local seconds = ns.Library.TrackSeconds(state.current)
    if seconds <= 0 then return end          -- unknown length: the track just loops
    advanceTimer = C_Timer.NewTimer(seconds + GAP, function()
        advanceTimer = nil
        Player.Advance(1, true)
    end)
end

StartCurrent = function()
    local index = state.order[state.pos]
    local fileID = index and state.queue[index]
    if not fileID then
        Player.ReturnToGame(true)
        return
    end
    RestoreFadeVolume()
    state.current = fileID
    state.playing = true
    state.startedAt = GetTime()
    if not ns.Mixer.IsMusicAudible() then
        ns.Fire("MUSIC_MUTED")
    end
    PlayMusic(fileID)
    ns.charDB.lastTrack = fileID
    ScheduleAdvance()
    ns.Fire("PLAYER_STATE")
end

-- Play a list of tracks, starting at startIndex (default 1).
function Player.PlayList(fileIDs, startIndex, label)
    if not fileIDs or #fileIDs == 0 then return end
    state.queue = {}
    for i, id in ipairs(fileIDs) do state.queue[i] = id end
    state.label = label
    BuildOrder(startIndex or 1)
    StartCurrent()
end

function Player.PlayTrack(fileID, label)
    Player.PlayList({ fileID }, 1, label)
end

-- delta = 1 next, -1 previous. fromTimer: the track ended naturally.
function Player.Advance(delta, fromTimer)
    if #state.order == 0 then return end
    local mode = Settings().repeatMode
    if fromTimer and mode == "one" then
        StartCurrent()
        return
    end
    -- "Previous" more than 3 s into a track restarts it, like most players
    if delta < 0 and state.playing and GetTime() - state.startedAt > 3 then
        StartCurrent()
        return
    end
    local pos = state.pos + delta
    if pos > #state.order then
        if mode == "off" and fromTimer then
            Player.ReturnToGame(true)
            return
        end
        if Settings().shuffle then BuildOrder() end
        pos = 1
    elseif pos < 1 then
        pos = #state.order
    end
    state.pos = pos
    StartCurrent()
end

function Player.Next() Player.Advance(1) end
function Player.Previous() Player.Advance(-1) end

-- Play/stop toggle: stop returns the music to the game; play resumes the queue
-- (or the last track this character played).
function Player.TogglePlay()
    if state.playing then
        Player.ReturnToGame()
    elseif #state.order > 0 then
        StartCurrent()
    elseif ns.charDB.lastTrack and ns.Library.GetTrack(ns.charDB.lastTrack) then
        Player.PlayTrack(ns.charDB.lastTrack)
    else
        ns.Print(ns.L["Pick a track in the library first."])
    end
end

-- Stop our music and give control back to the game's own zone music.
function Player.ReturnToGame(quiet)
    CancelAdvance()
    local wasPlaying = state.playing
    state.playing = false
    ns.Fire("PLAYER_STATE")
    if not wasPlaying then
        StopMusic()
        RestoreFadeVolume()
        return
    end
    FadeOutThen(function()
        StopMusic()
        if not quiet then ns.Print(ns.L["Returned to the game's music."]) end
    end)
end

function Player.IsPlaying()
    return state.playing
end

-- current fileID, elapsed seconds, length, queue label, position, queue size
function Player.GetNowPlaying()
    if not state.current then return nil end
    local elapsed = state.playing and (GetTime() - state.startedAt) or 0
    return state.current, elapsed, ns.Library.TrackSeconds(state.current), state.label, state.pos, #state.order
end

function Player.SetRepeatMode(mode)
    Settings().repeatMode = mode
    if state.playing then ScheduleAdvance() end
    ns.Fire("PLAYER_STATE")
end

function Player.CycleRepeat()
    local nextMode = { all = "one", one = "off", off = "all" }
    Player.SetRepeatMode(nextMode[Settings().repeatMode] or "all")
end

function Player.SetShuffle(on)
    Settings().shuffle = on and true or false
    if #state.queue > 0 then
        local index = state.order[state.pos]
        BuildOrder(index)
        if not on then state.pos = index or 1 end
    end
    ns.Fire("PLAYER_STATE")
end

-- Lifecycle ---------------------------------------------------------------------

function Player.OnLogin()
    -- the game closed during a fade last session: put the volume back
    RestoreFadeVolume()
end

function Player.OnLogout()
    CancelAdvance()
    RestoreFadeVolume()
end

-- The user changed the music volume while we were fading: keep their value.
ns.On("MIXER_CHANGED", function()
    if fadeTicker and ns.charDB.fadeRestore then
        local now = C_CVar.GetCVar("Sound_MusicVolume")
        if tonumber(now) and tonumber(now) > (tonumber(ns.charDB.fadeRestore) or 0) then
            ns.charDB.fadeRestore = nil
        end
    end
end)

-- Optional automatic return to the game's music.
local lastInstance
function ns.events:PLAYER_ENTERING_WORLD()
    local inInstance = IsInInstance()
    if state.playing and Settings().revertOnInstance and inInstance and not lastInstance then
        Player.ReturnToGame()
    end
    lastInstance = inInstance
end

local zoneTimer
function ns.events:ZONE_CHANGED_NEW_AREA()
    if not (state.playing and Settings().revertOnZone) then return end
    -- several zone events fire per transition: debounce
    if zoneTimer then zoneTimer:Cancel() end
    zoneTimer = C_Timer.NewTimer(0.5, function()
        zoneTimer = nil
        if state.playing then Player.ReturnToGame() end
    end)
end

function ns.events:PLAYER_REGEN_DISABLED()
    if state.playing and Settings().revertOnCombat then
        Player.ReturnToGame()
    end
end

ns.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
ns.eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ns.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
