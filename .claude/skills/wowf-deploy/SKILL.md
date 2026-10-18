---
name: wowf-deploy
description: Install a workspace addon into the World of Warcraft Forever client by linking its folder into the client's Interface AddOns directory with a Windows directory junction (or a copy), show what is deployed, or remove a deployment safely. Handles the beta client folder _classic_beta_ and the stress-test and launch folder _forever_. Use when asked to deploy, install, link, put an addon in the game, test it in game, or check or remove what is installed.
argument-hint: "[Addon] [--client beta|forever|all] [--remove] [--status]"
allowed-tools: Bash(python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" --status)
---

# wowf-deploy

Clients are auto-discovered: any `World of Warcraft\_*_\` folder with `Wow*.exe` whose folder is a Forever product.
- **beta**: `_classic_beta_` (`WowB.exe`, product `wow_classic_beta`).
- **forever**: `_forever_` (`Wow.exe`, product `wowf`). It appears once Justin installs the stress test (Oct 19) or launch (Nov 4).

Extra search roots or explicit paths go in the gitignored `wowf.local.json` (`client_search_roots`, `clients`).

## Commands
```
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" --status                       # what's linked where (safe, read-only)
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" MusicForever                    # junction into the beta client
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" MusicForever --client all       # beta and forever
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" WowfProbe                       # the dev probe (lives in wowf-debug/assets)
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" MusicForever --remove           # unlink (source untouched)
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" MusicForever --mode copy        # copy instead of link (marker-tracked)
python "${CLAUDE_SKILL_DIR}/scripts/deploy.py" --prune                         # drop dangling junctions into this repo
```

## Before deploying
1. Lint first (`wowf-review`). Don't deploy with lint errors.
2. The folder name must equal the TOC name; deploy refuses otherwise.

## After deploying, tell Justin
- **A brand-new addon:** restart the client, or at least `/reload` (the community says a restart is needed [F-024]). Then enable it in the AddOns list at character select. Ask what happened and record it.
- **Code edits:** with a junction, edits are live after `/reload`. Changes to the TOC or new files may need a restart.
- **SavedVariables** are written only at `/reload` or logout.

## Safety rules (non-negotiable)
- Junction removal only unlinks. **Never** delete a deployed addon folder with `Remove-Item -Recurse`, `rmdir /s`, `del /s` or Explorer. Through a junction that deletes the **source files in OneDrive**. Always use `--remove`.
- Deploy refuses to replace a real folder (an addon installed from CurseForge). `--replace-copy --yes` first moves it to `Interface\AddOns.wowf-backup\`. Ask Justin before using it.
- `_forever_` and `_classic_beta_` have separate WTF folders. Settings don't carry over.
- If deploy warns about **OneDrive online-only files**: right-click the AddOns workspace folder and choose OneDrive → **Always keep on this device**.

## Releasing on CurseForge
Done for MusicForever 0.2.0 and BuffettForever 1.0.0.
1. Bring the addon's README up to date, add the release to its CHANGELOG.md, and set `## Version`.
2. Write the project page, `docs/<Addon>-curseforge.md`, using `docs/MusicForever-curseforge.md` as the model:
   - a one-line pitch;
   - the features, by section;
   - how it works;
   - a feedback line and the signature.
3. Make the 512 px logo in `dist/` with make-icon, `--size 512` with `--out` and `--preview` (wowf-new-addon, Icon).
4. Run `python tools/wowf/cli.py package <Addon>`. It writes `dist/<Addon>-<Version>.zip`.
   - The lint must pass.
   - The zip has one root folder, with no CLAUDE.md, Screenshots or dot-folders.
   - It refuses when its rules would leave out a file the TOC loads, or the TOC's IconTexture.
5. Justin takes the screenshots in game and uploads, because the upload is outward-facing:
   - the zip, the logo and the page text;
   - the game version, WoW Forever;
   - the release type: Beta until the addon has run on the launch client.
6. Before launch, deploy to `_forever_` (`--client forever`) and check it there: `/reload`, the addon's self-test if
   it has one, and a real play session.

While the release files wait for Justin's review, code still gets committed. Leave the README, the CHANGELOG, the
page and `## Version` out of those commits. New Lua files still need their TOC lines, so stage the TOC with
`python tools/wowf/cli.py toc-stage <Addon>`. It stages the working copy's file list under the committed `##`
header, and lists the header lines it kept back (`--dry-run` shows the result first). Used for BuffettForever 1.0.0.
