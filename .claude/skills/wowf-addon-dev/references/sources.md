# Sources and how to re-fetch them

## Primary (highest trust)
- **Blizzard UI source, `forever` branch.** Mirror: github.com/Gethe/wow-ui-source (branch `forever`; `version.txt` holds the build).
  - Local cache: `%LOCALAPPDATA%\wowf\wow-ui-source`, refreshed by `python tools/wowf/cli.py api update`.
  - Raw file: `https://raw.githubusercontent.com/Gethe/wow-ui-source/forever/<path>`.
  - Generated API docs: `Interface/AddOns/Blizzard_APIDocumentationGenerated/*Documentation.lua`.
- **WowfProbe** on Justin's client (`wowf-debug`). It's the only source for undocumented functions and real runtime presence.
- **Blizzard version server:** `http://us.patch.battle.net:1119/wow_classic_beta/versions` (beta) and `.../wowf/versions` (stress test/launch); `cli.py api builds`.

## Warcraft Wiki (Mainline docs, good for semantics)
- Use the API, not page scraping: `https://warcraft.wiki.gg/api.php?action=query&prop=revisions&rvprop=content&rvslots=main&redirects=1&format=json&formatversion=2&titles=A|B` (up to 50 titles). Most `API_X` pages now redirect to `API:X`.
- Send a descriptive User-Agent (e.g. `wowf-tools/1 (WoW Forever addon dev)`), respect `maxlag`, and cache results. Fall back to WebFetch if blocked.
- Key pages:
  - `TOC_format`, `Secret_Values`, `WOW_PROJECT_ID`;
  - `Patch_1.60.1/API_changes` (Forever!), `Patch_12.0.0/API_changes` … `Patch_12.1.5/API_changes`;
  - `Settings_API`, `Addon_compartment`, `Saving_variables_between_game_sessions`, `AddOn_loading_process`;
  - `API:PlaySoundFile`, `API:PlayMusic`, `Console_variables/Complete_list`.

## Community (verify before relying on)
- wowforeverguides.com/addons/developers (+ patterns, api-cheatsheet, pitfalls, code-templates, ai-prompts, forever-beacon), checked Sep 28 – Oct 13, 2026. Partly stale; see the corrections in forever-facts.md.
- warcraftforever.games/addons: beta notes on protected calls, sound and nameplates.
- wowforeverbuilds.com: build news and datamines.
- Blizzard forums (Discourse; append `.json` to a topic URL):
  - SV bug thread t/2356559;
  - dev notes t/2360696;
  - known issues t/2352687.
- github.com/justadakaje/wow-addons `docs/facts-build-*.md`: measured probe fact sheets.
- Shipped Forever addons (patterns only; respect licenses):
  - Questie (`Questie_Camelot.toc`);
  - Guidelime (`-Camelot.toc`);
  - RestedXP RXPGuides (inline `[AllowLoadGameType camelot]`);
  - Soundtrack (Dozer1170/Soundtrack: PlayMusic playlists).
- BigWigs packager (`BigWigsMods/packager` `release.sh`) supports `forever`: `16xxx` interfaces, `_Camelot.toc`, `@version-forever@`.

## Research method that worked
Fetch pages as text with a small Python HTML-to-text converter (stdlib `html.parser`) through Bash instead of summarizing fetchers, then read them in full. For GitHub, use raw.githubusercontent.com (no rate limit) and the git trees API sparingly (60 requests per hour without auth).
