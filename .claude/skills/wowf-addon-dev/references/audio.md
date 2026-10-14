# Audio and music on WoW Forever

Facts for building sound and music features (MusicForever and alerts). Each fact carries a status tag; the undocumented functions must be confirmed with WowfProbe on the current build [F-035].

## The functions
| Function | Accepts | Channel | Returns | Status |
|---|---|---|---|---|
| `PlaySound(soundKitID [, channel, forceNoDuplicates, runFinishCallback])` | **SoundKitID number** (`SOUNDKIT.X`); never a string | default "SFX" | `success, soundHandle` | [Source]; alias of `C_Sound.PlaySound` |
| `C_Sound.PlaySound(id, uiSoundSubType, forceNoDuplicates=false, runFinishCallback=false, overridePriority, volumeOverride)` | SoundKitID | `uiSoundSubType` (channel string) | `success, soundHandle` | [Source]; `volumeOverride` 12.1.0+ |
| `C_Sound.PlaySoundWithOptions({soundKitID=…, uiSoundSubType=…, runFinishCallback=…, volumeOverride=…})` | SoundKitID | field | `success, soundHandle` | [Source] |
| `PlaySoundFile(fileID or "Interface\\AddOns\\Me\\x.ogg" [, channel])` | **FileDataID** or **addon-folder path** (.ogg/.mp3) | default "SFX" | `willPlay, soundHandle` (`willPlay` is true even for bogus IDs; test with `C_Sound.IsPlaying(handle)` instead [F-112]) | undocumented, used on Forever [F-035] |
| `PlayMusic(fileID or addon path)` | FileDataID or addon path | always "Music" | `willPlay` (always true, even for bad paths) | undocumented; custom MP3s confirmed playing [F-102] |
| `StopMusic()` | — | Music | — | stops **only** `PlayMusic` music, immediately |
| `StopSound(soundHandle [, fadeoutMs])` | handle | — | — | Blizzard Forever code uses it [Source] |
| `C_Sound.IsPlaying(soundHandle)` | handle | — | bool | [Source]; the only way to detect the end of a `PlaySoundFile` sound |
| `C_Sound.GetSoundScaledVolume(soundHandle)` | handle | — | number | [Source] |
| `MuteSoundFile(fileID or path)` / `UnmuteSoundFile` | FileDataID or path | — | — | lasts through reload, not restart; [Unverified] on Forever |
| `GetFileIDFromPath(path)`, `C_UIFileAsset.GetFileID/IsKnownFile/IsLooseFile(asset)` | path | — | fileID / bool | validate assets [Source] |

**Channels:** "Master", "Music", "SFX", "Ambience", "Dialog". Blizzard code also passes "Voice". "Master" ignores every setting except master volume.

**Events:**
- `SOUNDKIT_FINISHED(soundHandle)`, only for `PlaySound` with `runFinishCallback=true`;
- `SOUND_DEVICE_UPDATE`;
- `CVAR_UPDATE(name, value)`.

**There are no music, jukebox or playlist events, and no API for track length, position, pause or seek** [F-104].

## Hard rules
1. **Internal game paths don't work** (`Sound\Interface\LevelUp.ogg`, `Sound\Music\...`). They have failed silently since 8.2.0 [F-101]. Use a FileDataID number, a SOUNDKIT ID, or a path in your own addon folder. Lint rule API006 enforces this.
2. **Ship your own audio** in the addon folder as `.ogg` (preferred) or `.mp3`, and reference it as `"Interface\\AddOns\\MyAddon\\Media\\track.ogg"`. Audio files don't go in the TOC.
3. **New files must exist before login or `/reload`.** The wiki says new files are picked up on `/reload`; the community says the client scans AddOns only at startup [F-024]. If a new file is silent, restart the client.
4. Files above `Sound_MaxCacheableSizeInBytes` (about 170 KB) **stream** instead of caching. That's fine for music.
5. Never raise the player's volume or unmute channels without an explicit opt-in. Restore anything you change.

## Finding IDs
- **SOUNDKIT names:** `python tools/wowf/cli.py api soundkit REGEX` (888 keys on 70374), e.g. `READY_CHECK = 8960`, `RAID_WARNING = 8959`, `IG_MAINMENU_OPEN = 850`, `TELL_MESSAGE = 3081`, `MAP_PING = 3175`.
- **FileDataIDs for game music and sounds:** wago.tools/files (search "sound/music/..."), the community listfile (github.com/wowdev/wow-listfile), and `GetFileIDFromPath` in game. Zone music is selected by the engine, so addons can't ask "what is playing".
- Forever ships new music (the OST released Oct 13; new sets for Zephras Isle, Riverglades, Hyjal, the Drowned City and Dalaran) [F-105]. Their FileDataIDs exist only in Forever builds, so look them up against the Forever listfile or wago.tools with the Forever product.

## Sound CVars (read with `C_CVar.GetCVar`, not secure) [F-103]
| CVar | Default | Meaning |
|---|---|---|
| `Sound_EnableAllSound` / `Sound_MasterVolume` | 1 / 1.0 | master toggle and volume |
| `Sound_EnableMusic` / `Sound_MusicVolume` | 1 / 0.4 | music; `PlayMusic` is silent when disabled |
| `Sound_ZoneMusicNoDelay` | 0 | the **"Loop Music"** checkbox: no silence between zone tracks |
| `Sound_EnableSoundWhenGameIsInBG` | 0 | play audio while the client is in the background |
| `Sound_EnableSFX`, `Sound_SFXVolume`, `Sound_EnableAmbience`, `Sound_AmbienceVolume`, `Sound_EnableDialog`, `Sound_DialogVolume` | | |
| `Sound_MaxCacheableSizeInBytes` | 174762 | larger files stream |

- `C_CVar.SetTempCVar(name, value)` / `RemoveTempCVar(name)` (Forever-only) set a value that isn't persisted. That suits fades without leaving modified settings behind; semantics are inferred from Blizzard_Gamepad, so verify them.
- `Sound.log` in the client's `Logs` folder records the current audio settings at startup (`cli.py logs show Sound`).

## Triggers for music logic
| Trigger | Source |
|---|---|
| zone / subzone | `ZONE_CHANGED_NEW_AREA`, `ZONE_CHANGED`, `ZONE_CHANGED_INDOORS`, then `GetZoneText()`, `GetSubZoneText()`, `C_Map.GetBestMapForUnit("player")` (not secret) |
| instance | `PLAYER_ENTERING_WORLD`, `IsInInstance()`, `GetInstanceInfo()` |
| combat | `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` |
| boss | `ENCOUNTER_START` / `ENCOUNTER_END` |
| day/night | `DIEL_CYCLE_CHANGED(isDayTime)`, `C_DateAndTime.IsDayTime()` (Forever-only) |
| weather | `WEATHER_CHANGED`, `C_Weather.GetCurrentWeather()` → `{type = Enum.WeatherType, intensity}` |
| resting / taxi / mounted | `PLAYER_UPDATE_RESTING`/`IsResting()`, `PLAYER_CONTROL_LOST/GAINED`/`UnitOnTaxi("player")`, `PLAYER_MOUNT_DISPLAY_CHANGED`/`IsMounted()` |
| death | `PLAYER_DEAD`, `PLAYER_ALIVE`, `PLAYER_UNGHOST` |

Debounce zone changes, because several events fire per transition: `C_Timer.NewTimer(0.5, ...)`, cancelling the previous one.

New zones may have no continent parent. Soundtrack keyed Zephras Isle as "Unknown/Zephras Isle", so key by `uiMapID` plus the zone name, and handle missing parents [F-110].

## Proven techniques (from the Soundtrack addon, adapted)
- **Playlists:** you must know each track's length, since there's no end event for `PlayMusic`. Store `{file, seconds}`. Schedule the next track with `C_Timer.NewTimer(length + gap, next)`, and cancel it on stop or zone change.
- **Silence the zone music:** while your music plays, `PlayMusic` already fades out the built-in music. To silence it *without* your own track, play a short silent `.ogg` you ship (`PlayMusic("Interface\\AddOns\\MyAddon\\Media\\silence.ogg")`).
- **Fades:** step `Sound_MusicVolume` over about 1 s with a ticker. Save the user's value first, and restore it on stop and in `PLAYER_LOGOUT`. Track `CVAR_UPDATE` so you don't overwrite a change the user makes mid-fade. `SetTempCVar` may be cleaner (verify first).
- **Sound effects with end detection:** `local ok, h = PlaySoundFile(path, "SFX")`, then poll `C_Sound.IsPlaying(h)` with a ticker (about 0.25 s), or use SOUNDKIT plus `runFinishCallback`.

```lua
local addonName, ns = ...
local current, nextTimer

local function Stop()
    if nextTimer then nextTimer:Cancel(); nextTimer = nil end
    StopMusic()
    current = nil
end

local function PlayList(list, index)
    Stop()
    index = ((index or 1) - 1) % #list + 1
    local track = list[index]
    PlayMusic(track.file)                          -- fileID or "Interface\\AddOns\\..." path
    current = { list = list, index = index }
    nextTimer = C_Timer.NewTimer(track.seconds + 2, function() PlayList(list, index + 1) end)
end
ns.PlayList, ns.StopMusic = PlayList, Stop
```

## Licensing
Ship only audio you have rights to. Game music may be referenced by FileDataID, which streams it from the client; never extract and redistribute game files.
