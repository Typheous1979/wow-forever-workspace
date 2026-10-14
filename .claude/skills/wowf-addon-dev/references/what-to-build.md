# What is worth building on WoW Forever

| Area | Verdict | Why |
|---|---|---|
| Bags, bank, vendor, tooltips, mail | **Build** | presents data the UI already shows |
| Quest log helpers, route and guide addons, map pins | **Build** | use `C_Map.SetUserWaypoint`, not super-track [F-050] |
| Audio and music (zone/event soundtracks, alert sounds) | **Build** | sound APIs aren't restricted; see audio.md |
| Notes, journals, collections, professions, AH helpers | **Build** | the modern `C_AuctionHouse` is present |
| UI skins, fonts, layout, minimap tidy-up | **Build carefully** | don't move Blizzard Edit Mode frames; style your own |
| Nameplate art | **Build carefully** | the unit may not be ready at `NAME_PLATE_UNIT_ADDED` [F-063]; names can be secret |
| Personal status strips (health and power bars) | **Build** | StatusBar accepts secrets; no math |
| Damage or healing meters | **Don't** | built in; the combat log is gone [F-070] |
| Boss mods and timers from the combat log | **Don't** | no CLEU; use the built-in features |
| Cooldown trackers | **Don't** | built-in cooldown manager (all classes, racials, trinkets) |
| Swing timers | **Don't** | built in (Edit Mode, `C_SwingTimer`) |
| Click-cast healer frames | **Don't** | native Click Cast Bindings plus mouseover cast; secure snippets are retest-only |
| Raid marker automation | **Don't** | `SetRaidTarget` forbidden [F-051] |
| Combat automation of any kind | **Never** | against the rules; secrets block it anyway |
| Encounter Journal-dependent features | **Don't** | the Encounter Journal isn't loaded on Camelot [F-038] |

Before building anything, ask "does Blizzard already ship this?", and check `python tools/wowf/cli.py api addon Blizzard_<Name>`.

## License etiquette
- Read other addons only to learn behaviour unless their license allows reuse.
- Never copy All-Rights-Reserved code.
- Credit MIT/BSD sources.
- Ship only audio and art you have rights to.
