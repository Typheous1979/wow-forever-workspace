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
