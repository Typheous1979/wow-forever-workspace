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
- **A released addon and its dev junction can't share a client.** If the CurseForge app installs or updates an addon in
  a client where `Interface\AddOns\<Addon>` is a junction into the workspace, it writes through the junction into the
  source.
  - To play the released build there, unlink first (`--remove`), then install it.
  - To develop again, remove the installed copy with the CurseForge app, then deploy.
  - Tell Justin this after every release; BuffettForever 1.0.0 was the first.

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
   - the release type, which is his call. Beta until the addon has run on the launch client is the cautious choice.
     BuffettForever 1.0.0 went up as a Release.
6. Before launch, deploy to `_forever_` (`--client forever`) and check it there: `/reload`, the addon's self-test if
   it has one, and a real play session.

While the release files wait for Justin's review, code still gets committed. Leave the README, the CHANGELOG, the
page and `## Version` out of those commits. New Lua files still need their TOC lines, so stage the TOC with
`python tools/wowf/cli.py toc-stage <Addon>`. It stages the working copy's file list under the committed `##`
header, and lists the header lines it kept back (`--dry-run` shows the result first). Used for BuffettForever 1.0.0.

## Publishing to the addon's own repo
Done for BuffettForever 1.0.0 (github.com/Typheous1979/BuffettForever, 2026-10-18). Development stays in this
workspace, with the shared tools and skills. The addon's repo gets only its folder's history, for players and for
CurseForge's source link. Justin creates the repo; pushing to it is outward-facing, so do it when he asks.
```
python tools/wowf/cli.py publish <Addon>                                  # split + privacy scan; pushes nothing
python tools/wowf/cli.py publish <Addon> --repo <url> --push              # then a plain push to its main
```
1. **Commit everything first.** The split takes committed history only, and refuses while the folder has changes.
   `Screenshots/` stays out (gitignored).
2. **The split** is `publish/<addon>`, from `git subtree split --prefix=<Addon>`. The same commits get the same IDs
   every time, so each later publish is a fast-forward push.
3. **The privacy scan** reads the split's whole history. It checks:
   - this machine's paths and WTF account names (wowf.local.json and the clients' `WTF\Account` folders);
   - user paths and AppData;
   - account-ID shapes;
   - email addresses other than noreply ones and the committer's own.

   It prints counts only, and any hit stops the publish.
4. **The first push to a repo GitHub created with a README or LICENSE** is refused as not a fast-forward.
   1. Look at what's there (`git fetch <url> main:refs/remotes/<addon>/main`, then `git ls-tree` and `git show`).
   2. Keep its LICENSE: copy it into the addon folder word for word, add `## X-License: <name>` to the TOC
      (`package` ships it), commit, and publish again.
   3. Push once with the lease the tool prints: `git push --force-with-lease=main:<its commit> <url>
      publish/<addon>:main`. It fails if anything new arrived. Its README is replaced by the addon's.
   4. If the repo holds anything else, ask Justin first.

   BuffettForever's repo had GitHub's MIT LICENSE and a two-line README.
5. **Push the workspace too** (wow-forever-workspace). It's the dev home and public as well, so push it through the
   scan: `python tools/wowf/cli.py publish --scan origin/main..HEAD --push`. It pushes only when the scan is clean.
   - Never chain a gate in the shell. `publish --scan ... | tail -2 && git push` pushed anyway on 2026-10-18,
     because the pipe's status is `tail`'s. The hits were only the scanner's own test fixtures, now assembled at
     run time.
   - The scan reads what a push adds: commit messages and the added lines of `-U0` diffs.
   - Its email check skips noreply addresses, reserved example domains and the committer's own. A decorator after a
     diff's `+` isn't an address.
