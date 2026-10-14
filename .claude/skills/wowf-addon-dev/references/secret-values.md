# Secret values on WoW Forever

Midnight's "addon disarmament" is active on Forever [F-001][F-040]. Some API results are **secrets**: values addon (tainted) code may hold and display but cannot inspect.

## The rules (tainted/addon code)
**Allowed:**
- store secrets in locals, upvalues and table *values*;
- pass them to Lua functions;
- concatenate them, and use `string.format`/`string.join`/`string.concat` (the result is secret);
- truth-test non-boolean secrets (`if x then` behaves like `x ~= nil`).

**Error immediately:**
- arithmetic, `<`/`>`/`==` comparisons, `#`;
- using a secret as a table **key**, indexing into it, calling it;
- truth-testing a **secret boolean**;
- `tonumber` on a secret string.

**Forever specifics:**
- **Printing** a secret throws and can blank the frame [F-046]. Guard before you print.
- SavedVariables can't hold secrets; they become nil on save.
- `type(secret)` still returns the real type, so `type()` can't detect a secret.

## Helpers
| Function | Use |
|---|---|
| `issecretvalue(v)` | **the** guard before compare/branch/print |
| `canaccessvalue(v)`, `canaccessallvalues(...)` | can this code read it? |
| `issecrettable(t)`, `canaccesstable(t)` | secret/forbidden tables ("attempt to index a forbidden table") |
| `hasanysecretvalues(...)` | any secret among args |
| `scrubsecretvalues(...)` | secrets become nil |
| `C_Secrets.HasSecretRestrictions()` | false means no API will return secrets on this build |
| `C_Secrets.Should*BeSecret(...)`, `C_Secrets.Get*Secrecy(...)` | predict secrecy (NeverSecret/AlwaysSecret/ContextuallySecret) |
| `C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.X)` | is Combat/Encounter/ChallengeMode/PvPMatch/Map/Chat restriction on |
| event `ADDON_RESTRICTION_STATE_CHANGED(type, state)` | fires before activation and after deactivation |

Always wrap the helpers in a presence check: `type(issecretvalue) == "function"`.

## Which APIs return secrets (from the forever-branch doc annotations) [F-041..F-045]
| API | Secrecy |
|---|---|
| `UnitHealth` | **always** (`SecretReturns`) |
| `UnitHealthMax` | when the unit isn't player-controlled |
| `UnitHealthPercent` | always |
| `UnitPower` / `UnitPowerMax` | power types not flagged never-secret; max for non-player-controlled units |
| `UnitName`, `UnitFullName`, `UnitGUID`, `UnitClass` (name), `UnitRace`, `UnitSex`, `UnitCreatureType` | when **unit identity is restricted**: the unit isn't player-controlled or in your group; on instanced maps everything except player, pet, vehicle and group |
| `UnitCastingInfo`, `UnitChannelInfo`, spell-cast event payloads | when the unit isn't the player or pet |
| `UnitIsAFK`/`UnitIsDND`, chat-line sender/text | during chat lockdown (encounter, M+, PvP, restricted maps) |
| aura data (`C_UnitAuras`), cooldowns (`C_Spell.GetSpellCooldown`) | when auras or cooldowns are restricted (combat, encounters, M+, PvP) |
| `UnitThreatSituation`, unit stats (`UnitArmor`, `UnitStat`…) | when restricted |
| `GetFrameStrata` on frames with the FrameStrata aspect | Forever 70291 [F-048] |

Not secret per the docs: `UnitExists`, `UnitCanAttack`, `UnitIsEnemy`, `UnitLevel`, `UnitIsPlayer`, `UnitIsDead`, `UnitAffectingCombat`, `GetZoneText`, `GetSubZoneText`, `C_Map.GetBestMapForUnit`. Community reports disagree for some of these, so guard when the unit isn't in your group.

Check any API with `python tools/wowf/cli.py api show NAME`, which prints `[secret:always|conditional]` and the predicate flags.

## Widgets that accept secrets
- **StatusBar:** `SetMinMaxValues`, `SetValue`, `SetTimerDuration`.
- **FontString:** `SetText`, `SetFormattedText`.
- **Visuals:** `SetShown`, `SetAlpha`, `SetVertexColor`, `SetStatusBarColor`, `SetTexCoord`, `SetScale`.
- **Others:** `GameTooltip:SetText`, `Cooldown:SetCooldownFromDurationObject`, `C_StringUtil`/`AbbreviateNumbers`/`WrapTextInColorCode`.

Passing a secret marks the widget with a **secret aspect**. The matching getters then return secrets, and anchoring secrecy propagates to frames anchored to it (never upward). Don't read values back from bars you fed secrets.

## Patterns
```lua
local addonName, ns = ...

local function IsSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) == true
end

-- Display a name only when it's plain; never print a secret.
local function SafeText(v, fallback)
    if v == nil or IsSecret(v) then return fallback end
    return tostring(v)
end

-- Health bar: no math, the widget does it.
local function PaintHealth(bar, unit)
    bar:SetMinMaxValues(0, UnitHealthMax(unit))
    bar:SetValue(UnitHealth(unit))
end

-- Label that degrades instead of erroring.
local function PaintLabel(fs, unit)
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if IsSecret(cur) or IsSecret(max) then
        fs:SetText("")                       -- or a fixed label like "Vitals"
    else
        fs:SetFormattedText("%d%%", math.floor(cur / max * 100 + 0.5))
    end
end
```
- **Percent text:** prefer `UnitHealthPercent(unit, true, curve)`, which returns a secret you can pass straight to `FontString:SetFormattedText` via a numeric formatter. Verify on the build with `wowf-api` first.
- **Testing:** in game, `/console addonCombatRestrictionsForced 1` simulates combat restrictions out of combat (not persisted).

## Errors you'll see
- `attempt to perform arithmetic on a secret number value (execution tainted by 'MyAddon')`
- `attempt to compare ... secret ...`
- `attempt to index a forbidden table`

`wowf-debug` maps these to fixes.
