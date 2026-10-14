# MusicForever

A game audio mixer and a jukebox for every piece of music in World of Warcraft Forever.

- **Library**: browse 769 tracks by Zones › Continent › Zone › Day/Night/Intro, Cities (districts
  and taverns), Dungeons, Raids, Battlegrounds, Music Sets, and Other Music. Search finds tracks
  and folders at every level. Forever's new and remastered music is marked with a blue `*`.
- **Player**: double-click to play; Play all, Shuffle, Repeat (all/one/off), Previous/Next, and a
  progress bar. **Return to game music** hands the music back to the game's own zone music.
- **Playlists**: Favorites (click the star) and your own playlists, shared by all your characters.
- **Mixer**: every sound channel Blizzard exposes (Master, Music, Effects, Ambience, Dialog,
  Gameplay Sounds, Combat Warnings, Pings) with on/off and volume, the sound options (Loop Music,
  Sound in Background, Reverb, Distance Filtering, Hear from Character, Error Speech, Emote and Pet
  sounds), built-in presets, your own presets and one-step Undo. WoW has no frequency equalizer;
  the mixer is the full set of controls the game offers.
- **Key bindings** (Options › Keybindings › MusicForever): open/close, play/stop, next, previous,
  return to game music, music and master volume up/down, game music on/off, next preset, mini player.
- **Mini player**: a small movable bar (Options › AddOns › MusicForever, or `/mf mini`).

## Commands
`/mf` opens the window. `/mf help` lists the rest: `play`, `stop`, `next`, `prev`, `revert`,
`mixer`, `playlists`, `preset <name>`, `mini`, `options`.

## How it works
The catalog (`Data/Catalog.lua`) is generated from Forever's own game tables by
`tools/wowf/music_catalog.py` in the workspace and holds only file IDs, names and lengths; the game
client streams the music itself. WoW has no end-of-track event, so the next track is scheduled from
the catalog's track lengths.

SavedVariables: `MusicForeverDB` (favorites, playlists, presets, settings) and
`MusicForeverCharDB` (window positions, last track).
