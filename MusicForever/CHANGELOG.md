# Changelog

## 0.2.0 (unreleased)
- New music-note icon (AddOn list, compartment, minimap button), drawn for MusicForever.
- Minimap button: left-click opens, right-click options, Shift-click play/stop, drag to move.
  Named so minimap-button collectors such as MinimapButtonButton gather it. Toggle in options
  or with /mf minimap.
- Signature: "MusicForever by Typheous" in the AddOn list, options page, tooltips and window.
- /mf verify saves its progress as it runs, so a reload mid-check keeps a partial result, and it now
  tests with C_Sound.IsPlaying (willPlay is always true on Forever).
- Catalog: 747 tracks. 22 encrypted Classic Era files that Forever can't play were removed
  (tools/wowf/data/music_unplayable.json).
- Slider labels and checkboxes no longer overlap; new playlists are named after their folder.

## 0.1.0 (unreleased)
- First build: Library (tree + search), player bar, playlists and favorites, mixer with presets
  and undo, key bindings, mini player, settings panel.
- Catalog: 769 tracks (402 Forever music) from Forever build 1.60.1.70245 tables, 100 KB.
- Tested on build: beta 1.60.1.70374 (in progress).
