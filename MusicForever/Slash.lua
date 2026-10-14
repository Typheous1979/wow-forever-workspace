local addonName, ns = ...

-- /mf commands. Plain /mf opens the window.

local function Help()
    local L = ns.L
    ns.Print("/mf  " .. L["open or close the window"])
    ns.Print("/mf play | stop | next | prev  " .. L["control the music"])
    ns.Print("/mf revert  " .. L["return to the game's music"])
    ns.Print("/mf mixer | playlists  " .. L["open a tab"])
    ns.Print("/mf preset <name>  " .. L["apply a mixer preset"])
    ns.Print("/mf mini  " .. L["show or hide the mini player"])
    ns.Print("/mf minimap  " .. L["show or hide the minimap button"])
    ns.Print("/mf options  " .. L["open the settings"])
    ns.Print("/mf verify  " .. L["check which catalog tracks this client can play (silent, ~10 s)"])
end

-- Availability check: plays every catalog file on the Master channel with the
-- master volume at 0 and stops it at once, recording PlaySoundFile's results in
-- MusicForeverDB.verify for the catalog tool (music-catalog --prune-from-probe).
local verifying
local function Verify()
    if verifying then return end
    if ns.Player.IsPlaying() then ns.Player.ReturnToGame(true) end
    local ids = {}
    for id in pairs(ns.CatalogTracks or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    -- controls: an ID that is not a sound file, and one that cannot exist
    table.insert(ids, 1, 1)
    table.insert(ids, 2, 999999999)

    verifying = true
    local savedMaster = C_CVar.GetCVar("Sound_MasterVolume")
    ns.charDB.verifyRestoreMaster = savedMaster
    C_CVar.SetCVar("Sound_MasterVolume", "0")
    -- saved from the start and updated as it goes, so a reload mid-run keeps a partial result
    local result = { build = select(2, GetBuildInfo()), version = (GetBuildInfo()),
                     catalog = ns.CatalogBuild, total = #ids, checked = 0, played = 0, done = false,
                     refused = {}, noHandle = {} }
    ns.db.verify = result
    ns.Print(string.format(ns.L["Checking %d tracks silently..."], #ids))

    -- PlaySoundFile's willPlay is true even for IDs that are not sound files (70374), so
    -- each batch is started, then checked with C_Sound.IsPlaying on the next tick and
    -- stopped. The two control IDs show whether IsPlaying tells real files from bogus ones.
    result.method = "isplaying"
    result.controls = {}
    result.silent = {}
    local BATCH, TICK = 16, 0.25
    local i = 0
    local pending = {}   -- { id, handle }
    local ticker
    ticker = C_Timer.NewTicker(TICK, function()
        for _, p in ipairs(pending) do
            local playing = p.handle ~= nil and C_Sound.IsPlaying(p.handle) == true
            if p.handle then StopSound(p.handle) end
            if p.id == 1 or p.id == 999999999 then
                result.controls[tostring(p.id)] = playing
            elseif playing then
                result.played = result.played + 1
            else
                result.silent[#result.silent + 1] = p.id
            end
        end
        wipe(pending)
        if i >= #ids then
            ticker:Cancel()
            C_CVar.SetCVar("Sound_MasterVolume", savedMaster)
            ns.charDB.verifyRestoreMaster = nil
            verifying = false
            result.done = true
            ns.Print(string.format(ns.L["Done: %d playing, %d silent. Type /reload to save the results."],
                result.played, #result.silent))
            return
        end
        for _ = 1, BATCH do
            i = i + 1
            local id = ids[i]
            if not id then break end
            result.checked = i
            local ok, willPlay, handle = pcall(PlaySoundFile, id, "Master")
            if ok and willPlay then
                pending[#pending + 1] = { id = id, handle = handle }
                if not handle then result.noHandle[#result.noHandle + 1] = id end
            else
                result.refused[#result.refused + 1] = id
            end
        end
    end)
end

SLASH_MUSICFOREVER1 = "/mf"
SLASH_MUSICFOREVER2 = "/musicforever"
SlashCmdList["MUSICFOREVER"] = function(msg)
    local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    local Player = ns.Player
    if cmd == "" then
        ns.Main.Toggle()
    elseif cmd == "help" then
        Help()
    elseif cmd == "play" then
        if not Player.IsPlaying() then Player.TogglePlay() end
    elseif cmd == "stop" or cmd == "revert" then
        Player.ReturnToGame()
    elseif cmd == "next" then
        Player.Next()
    elseif cmd == "prev" or cmd == "previous" then
        Player.Previous()
    elseif cmd == "mixer" then
        ns.Main.Show(3)
    elseif cmd == "playlists" then
        ns.Main.Show(2)
    elseif cmd == "library" then
        ns.Main.Show(1)
    elseif cmd == "preset" then
        local preset = ns.Mixer.FindPreset(rest)
        if preset then
            ns.Mixer.ApplyPreset(preset)
        else
            local names = {}
            for _, p in ipairs(ns.Mixer.GetPresets()) do names[#names + 1] = p.name end
            ns.Print(ns.L["Presets:"] .. " " .. table.concat(names, ", "))
        end
    elseif cmd == "mini" then
        ns.MiniPlayer.Toggle()
    elseif cmd == "minimap" then
        ns.MinimapButton.Toggle()
    elseif cmd == "options" then
        ns.OpenOptions()
    elseif cmd == "verify" then
        Verify()
    elseif cmd == "test" then
        local id = tonumber(rest)
        if id then Player.PlayTrack(id, "test " .. id) end
    else
        ns.Print(ns.L["Unknown command:"] .. " " .. cmd)
        Help()
    end
end

-- A verify interrupted by a reload or logout: put the master volume back.
local function RestoreMaster()
    local saved = ns.charDB and ns.charDB.verifyRestoreMaster
    if saved then
        C_CVar.SetCVar("Sound_MasterVolume", saved)
        ns.charDB.verifyRestoreMaster = nil
    end
end
ns.On("LOGIN", RestoreMaster)
ns.On("LOGOUT", RestoreMaster)
