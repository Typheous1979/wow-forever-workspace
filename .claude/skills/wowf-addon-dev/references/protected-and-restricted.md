# Protected, forbidden and restricted actions

## Taint in one paragraph
All addon code and its SavedVariables are **tainted**. Taint spreads to any value or table that tainted code writes, and lasts until reload. **Protected** functions and frame operations fail when the call path is tainted: in combat, from insecure code, or on secure frames. Blizzard code becomes tainted if you overwrite Blizzard globals or fields (lint flags writes to read-only globals as LCW121).

**Don't drive Blizzard's frames from addon code; read them.** Reading a Blizzard frame's fields and state is fine:
`AuctionHouseFrame.BuyDialog:IsShown()`, the sell frames' `pendingPost`, `InboxFrame.OpenAllMail:IsEnabled()`,
`StaticPopup_Visible(name)`. Running Blizzard's code paths from tainted code taints what they write, and a later
protected action through them can fail:
- calling a frame method that sets its state (`AuctionHouseFrame:SetPostItem`);
- hiding or showing Blizzard's dialogs (`StaticPopup_Hide` on the shared popup frames);
- loading a Blizzard LoadOnDemand UI yourself (`Blizzard_Professions`). An event like `TRADE_SKILL_SHOW` makes
  Blizzard's own code load it.

If Blizzard's own popup answers an event your call caused, leave it and explain in your UI: on the AH, its post
warning can't confirm an addon's post (auction-house.md, "Posting"). Put your buttons beside Blizzard's windows, as
children with no hooks (ui-patterns.md, "A button on a Blizzard window").

## Silent failures on Forever [F-050]
These produce **no Lua error**, and `pcall` doesn't help. The only symptoms are "Interface action failed because of an AddOn" and a counter in the AddOns panel that clears only on a **full client restart**.

| Don't call | Do instead |
|---|---|
| `ChatFrame_OpenChat`, `ChatEdit_ActivateChat` | let the player open chat; links via `HandleModifiedItemClick(link)` |
| `C_SuperTrack.SetSuperTrackedUserWaypoint` | `C_Map.SetUserWaypoint(UiMapPoint...)` |
| `frame:SetAttribute(...)` on Blizzard unit frames | your own buttons placed over them (out of combat) |
| `SetRaidTarget` | not available to addons on Forever [F-051] |

## Combat lockdown
- `InCombatLockdown()` is true after `PLAYER_REGEN_DISABLED` until just before `PLAYER_REGEN_ENABLED`.
- While locked down, you can't show, hide, move, resize or change the attributes of **protected** frames (or their parents and anchors), change bindings or macros, or call protected functions. Queue those changes (ui-patterns.md).
- Out of combat, addons *may* write bindings, place action slots and create macros [F-051].

## Doc flags (via `wowf-api show`) [F-052]
| Flag | Meaning | Lint |
|---|---|---|
| `IsProtectedFunction` | protected; mostly widget methods like `SetAttribute`. Blocked in combat or on protected frames | SEC003 (W) |
| `HasRestrictions` | may do nothing in restricted states (combat, encounter, M+, PvP, chat lockdown) | API004 (I) |
| `Environment = "SecureOnly"` system | can't be called by addons (e.g. `C_CombatLogSecure`) | API004 (E) |
| `SecretArguments = "NotAllowed"` | never pass secrets in (e.g. `SendAddonMessage`, `C_CVar.*`) | SEC004 (later) |
| `RequiresNonSecureCVar`… | CVar setters silently return nothing for secure CVars | |

## Restriction states
- `Enum.AddOnRestrictionType`: Combat, Encounter, ChallengeMode, PvPMatch, Map, Chat. Query with `C_RestrictedActions.IsAddOnRestrictionActive(type)`.
- Listen for `ADDON_RESTRICTION_STATE_CHANGED`.
- Test out of combat with `/console addonCombatRestrictionsForced 1` (also Encounter, ChallengeMode, PvPMatch, Map, Chat).

## Chat and addon messages [F-090][F-053]
- `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` registers a prefix of at most 16 characters, and must be called every session.
- `C_ChatInfo.SendAddonMessage(prefix, msg, chatType, target)` returns an `Enum.SendAddonMessageResult`:
  - messages are at most 255 bytes;
  - the throttle allows 10 per prefix and regains 1 per second;
  - result 11 means a lockdown is active (encounter, M+, PvP, restricted maps).
- Never put ASCII control characters (0x01–0x1F, 0x7F) in messages; `~` makes a safe field separator.
- Trial accounts can't send addon messages.
- `C_ChatInfo.SendChatMessage` is restricted. EMOTE, SAY and YELL need a hardware event (a click) outside instances. Only send chat on a deliberate player action.

## hooksecurefunc
- `hooksecurefunc([tbl,] "Name", fn)` runs after the original with the same arguments. Its return is ignored, and it can't be undone.
- Use `frame:HookScript("OnShow", fn)` for scripts.
- Never replace Blizzard functions.

## Secure snippets [F-061]
Click-casting and action-bar paging use secure snippets. Believed working since 70009. Forever also has native click-cast bindings and mouseover cast, so don't rebuild those.
