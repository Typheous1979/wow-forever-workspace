local addonName, ns = ...

-- Sound settings the mixer controls. These are the CVars Blizzard's own Audio
-- settings page uses on Forever (Blizzard_SettingsDefinitions_Shared/Audio.lua and
-- Blizzard_Settings_Shared/Mainline/AudioOverrides.lua, build 70374).

-- Volume channels: slider (0..1) plus an on/off toggle.
ns.Channels = {
    { key = "master",   label = "Master",          volume = "Sound_MasterVolume",           enable = "Sound_EnableAllSound" },
    { key = "music",    label = "Music",           volume = "Sound_MusicVolume",            enable = "Sound_EnableMusic" },
    { key = "effects",  label = "Effects",         volume = "Sound_SFXVolume",              enable = "Sound_EnableSFX" },
    { key = "ambience", label = "Ambience",        volume = "Sound_AmbienceVolume",         enable = "Sound_EnableAmbience" },
    { key = "dialog",   label = "Dialog",          volume = "Sound_DialogVolume",           enable = "Sound_EnableDialog" },
    { key = "gameplay", label = "Gameplay Sounds", volume = "Sound_GameplaySFX",            enable = "Sound_EnableGameplaySFX" },
    { key = "warnings", label = "Combat Warnings", volume = "Sound_EncounterWarningsVolume", enable = "Sound_EnableEncounterWarningsSounds" },
    { key = "ping",     label = "Pings",           volume = "Sound_PingVolume",             enable = "Sound_EnablePingSounds" },
}

-- On/off sound options.
ns.SoundOptions = {
    { key = "loopMusic",   label = "Loop Music",                 cvar = "Sound_ZoneMusicNoDelay",
      tip = "Play zone music continuously instead of with long silences between tracks." },
    { key = "background",  label = "Sound in Background",        cvar = "Sound_EnableSoundWhenGameIsInBG",
      tip = "Keep playing sound when the game window is not focused." },
    { key = "reverb",      label = "Reverb",                     cvar = "Sound_EnableReverb",
      tip = "Echo and room effects in caves, buildings and dungeons." },
    { key = "lowpass",     label = "Distance Filtering",         cvar = "Sound_EnablePositionalLowPassFilter",
      tip = "Muffle distant sounds the way real distance does." },
    { key = "listener",    label = "Hear from Character",        cvar = "Sound_ListenerAtCharacter",
      tip = "Hear the world from your character's position instead of the camera's." },
    { key = "errorSpeech", label = "Error Speech",               cvar = "Sound_EnableErrorSpeech",
      tip = "Your character's voice lines for errors such as \"Not enough mana\"." },
    { key = "emotes",      label = "Emote Sounds",               cvar = "Sound_EnableEmoteSounds",
      tip = "Voice sounds for emotes such as /cheer and /laugh." },
    { key = "pets",        label = "Pet Sounds",                 cvar = "Sound_EnablePetSounds",
      tip = "Sounds made by companion pets." },
}

-- Built-in presets. Only the keys listed are changed; everything else is left alone.
-- Volumes are 0..1; enables and options are true/false.
ns.BuiltinPresets = {
    {
        name = "Blizzard Default",
        desc = "The game's default sound settings.",
        volume = { master = 1.0, music = 0.4, effects = 1.0, ambience = 0.6, dialog = 1.0, gameplay = 1.0, warnings = 1.0, ping = 1.0 },
        enable = { master = true, music = true, effects = true, ambience = true, dialog = true, gameplay = true, warnings = true, ping = true },
    },
    {
        name = "Music Focus",
        desc = "Music up front, the world turned down.",
        volume = { music = 0.9, effects = 0.45, ambience = 0.3, dialog = 0.6 },
        enable = { master = true, music = true },
        options = { loopMusic = true },
    },
    {
        name = "Immersive",
        desc = "Full ambience, reverb and distance filtering; music at a gentle level.",
        volume = { music = 0.5, effects = 0.9, ambience = 1.0, dialog = 1.0 },
        enable = { master = true, music = true, effects = true, ambience = true, dialog = true },
        options = { reverb = true, lowpass = true, listener = true },
    },
    {
        name = "Quiet",
        desc = "Everything softer, for late nights.",
        volume = { master = 0.3, music = 0.3, effects = 0.5, ambience = 0.3, dialog = 0.6 },
        options = { errorSpeech = false, emotes = false },
    },
    {
        name = "Raid Focus",
        desc = "Effects, warnings and pings clear; music and ambience low.",
        volume = { music = 0.15, effects = 1.0, ambience = 0.2, dialog = 0.8, warnings = 1.0, ping = 1.0 },
        enable = { effects = true, warnings = true, ping = true },
        options = { errorSpeech = false },
    },
    {
        name = "Game Music Off",
        desc = "Mutes only the game's music, for listening to your own music outside the game.",
        enable = { music = false },
        options = { background = true },
    },
}
