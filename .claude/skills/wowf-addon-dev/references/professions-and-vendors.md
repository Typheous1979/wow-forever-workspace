# Professions, recipes, vendor prices and money on Forever

Sources: Blizzard's forever-branch docs and FrameXML, the WowfProbe dump (70374), and the Forever game
tables on wago.tools (70245). Names marked *runtime-only* are present in the client but missing from
Blizzard's docs: lint accepts them, `api show` reports "not in the index". Verify signatures with the probes.

## The professions UI and API [F-123]
- Forever uses the modern **`Blizzard_Professions`** (LoadOnDemand) with Camelot overrides; Forever forces
  "show unlearned recipes" off. There is no `Blizzard_TradeSkillUI` and no Craft frame: Enchanting uses the
  normal professions window. All Classic tradeskill and craft globals are gone (lint flags them).
- `C_TradeSkillUI` has 89 documented functions plus 57 runtime-only ones. `C_Professions` doesn't exist.

| Need | Call |
|---|---|
| Is the open window's data ready? | `C_TradeSkillUI.IsTradeSkillReady()` (runtime-only). Skip when `IsTradeSkillLinked()` / `IsTradeSkillGuild()` (runtime-only) or `IsNPCCrafting()` is true |
| Recipe IDs of the open profession | `C_TradeSkillUI.GetAllRecipeIDs()` (runtime-only, no arguments): **every** recipe of the skill line, learned or not, Season-of-Discovery ones included. `GetFilteredRecipeIDs()`: what the window shows, so with "show unlearned" forced off only learned ones, and it follows the filters [F-123] |
| Name, learned, skill-ups | `C_TradeSkillUI.GetRecipeInfo(recipeID)` → `{recipeID, name, learned, numSkillUps, canSkillUp, relativeDifficulty?, categoryID, ...}` or nil |
| Reagents and yield | `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` → `{quantityMin, quantityMax, outputItemID?, reagentSlotSchematics}`; each slot `{reagents = {{itemID?, currencyID?}}, quantityRequired, reagentType, required}` |
| Output link | `C_TradeSkillUI.GetRecipeOutputItemData(recipeID)` → `{icon, hyperlink?, itemID?}` (prefer it to the unverified `GetRecipeItemLink`) |
| Which profession | `C_TradeSkillUI.GetTradeSkillLineForRecipe(recipeID)` → tradeSkillID, name, parentTradeSkillID (runtime-only) |
| Cooldown | `C_TradeSkillUI.GetRecipeCooldown(recipeID)` → cooldown, isDayCooldown, charges, maxCharges (runtime-only) |
| The character's professions | `GetProfessions()` → **7** slots (2 primary, 5 secondary); `GetProfessionInfo(i)` → name, texture, rank, maxRank, numSpells, spellOffset, skillLine, rankModifier, specializationIndex, specializationOffset, skillLineName (both runtime-only) |
| Skill line info | `C_SkillInfo.GetSkillLineInfoByID(id)` (Forever-only) → `{rank, maxRank, ...}` or nil |
| Events | `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_DATA_SOURCE_CHANGED`, `TRADE_SKILL_CLOSE`, `NEW_RECIPE_LEARNED(recipeID, recipeLevel?, baseRecipeID?)`, `SKILL_LINES_CHANGED` |

Recipe data is client-side: `GetRecipeInfo` and `GetRecipeSchematic` work with no profession window open, for
known and unknown recipes [F-123, Probe 70425]. Blizzard's objective tracker relies on the same thing
(`Blizzard_ObjectiveTracker\Blizzard_ProfessionsRecipeTracker.lua`). But until that profession's window has been
opened in the session, `GetRecipeInfo(id).learned` reads false, `GetCraftableCount` 0 and `GetRecipeCooldown` nil
[F-123, Probe 70450]: read "known" from the spellbook (below), and counts from the bags.

### Crafting from an addon [F-135]
Proven on 70450 from a typed command (a key press):
1. **The window must be open on that profession.** `C_TradeSkillUI.CraftRecipe(recipeID, n)` with it closed does
   nothing at all: no event, no error, no block.
   - It's ready when `IsTradeSkillReady()` is true and `GetBaseProfessionInfo().professionID` is the recipe's skill
     line (129 First Aid, 165 Leatherworking …).
   - **`C_TradeSkillUI.OpenRecipe(recipeID)`**, from the player's click, opens it at the recipe. It casts the
     profession's spell, then `TRADE_SKILL_SHOW` and `OPEN_RECIPE_RESPONSE(recipeID, skillLine, childLine)`.
   - Don't load `Blizzard_Professions` yourself: `TRADE_SKILL_SHOW` makes Blizzard's own code load and show it.
2. **Craft:** `CraftRecipe(recipeID, n)` inside the click. Blizzard's Create passes the box's count, and Create All
   passes the craftable count. Basic reagents aren't passed. The events:
   - `TRADE_SKILL_CRAFT_BEGIN(recipeID)` fires inside the call;
   - each cast gives `UNIT_SPELLCAST_START`, then `SUCCEEDED` and `STOP`, with spellID = the recipe ID;
   - `TRADE_SKILL_ITEM_CRAFTED_RESULT(data)` follows (itemID, quantity, itemGUID).
3. **Stop a batch:** `C_TradeSkillUI.StopRecipeRepeat()` (runtime-only). The cast under way finishes and the rest
   are cancelled: `UPDATE_TRADESKILL_CAST_STOPPED` fires and `GetRemainingRecasts()` reads 0. Moving or
   `UNIT_SPELLCAST_INTERRUPTED`/`FAILED` also ends it. There's no `UPDATE_TRADESKILL_CAST_COMPLETE` on Forever.
4. **What Blizzard checks before enabling Create** (`ValidateControls` in `Blizzard_ProfessionsCrafting.lua`,
   [Source 70450]), in this order:
   1. `learned`;
   2. `craftable` and not `disabled`;
   3. the cooldown;
   4. `GetRecipeRequirements(recipeID)`: `{name, met, type}`, where type 0 is SpellFocus (an anvil, a forge, a
      Cooking Fire), 1 Totem (a tool) and 2 Area;
   5. enough reagents.

   It has no combat check.
5. **Where reagents count:** Blizzard's `ItemUtil.GetCraftingReagentCount` uses
   `GetItemCount(id, bank, false, bank, bank)` with `bank = ReagentsFromBankAllowed()`. That's **false on
   Forever**, so the bags only.
6. **Count finished crafts** on `UNIT_SPELLCAST_SUCCEEDED` (`RegisterUnitEvent(..., "player")`): one per craft, from
   any window, never for a failed one. The recipe's reagents come from your data by spell ID. Guard the spellID
   with `issecretvalue` (it wasn't secret on 70450).
- Working code: BuffettForever `Crafting/Craft.lua` (`/bf crafttest`, logged in `diag.crafts`).

### The character's professions and skill-up colours [F-133]
- **Professions without the window:** `GetProfessions()` returns 7 slot indexes, any of which may be nil. Pass each
  to `GetProfessionInfo(i)`; its 7th return is the Classic skill line (165 Leatherworking …), which your recipe data
  uses. On 70450, slot 3 held First Aid and slot 5 Cooking. If a line ever comes back as a Forever child line
  (2937–2948 [F-126]), map it with `C_TradeSkillUI.GetProfessionInfoBySkillLineID(line).parentProfessionID`.
- Re-read on `SKILL_LINES_CHANGED`. It fires for weapon skill-ups too, so compare a signature (line, rank, max rank)
  before redrawing.
- **A recipe's colour comes from the rank and its thresholds:** below the yellow threshold orange, below
  `floor((yellow + grey) / 2)` yellow, below grey green, the rest grey. Colour it with the globals
  `DIFFICULT_DIFFICULTY_COLOR`, `FAIR_`, `EASY_` and `TRIVIAL_DIFFICULTY_COLOR` (ColorMixins:
  `:GenerateHexColorMarkup()`), as the profession window does.
- **Don't take `GetRecipeInfo(id).relativeDifficulty` with the window closed.** It reads Optimal for every recipe
  of a profession whose window hasn't been opened, so after a `/reload` every recipe looks orange [F-133]. Where
  it was valid, it agreed with the thresholds on every recipe.
- Working code: BuffettForever `Crafting/Harvest.lua` (`Professions`, `Difficulty`), `Crafting/RecipeIndex.lua`
  (`Difficulty`).

### Recording which recipes a character knows
**Read them at login; no window needed.** Recipes are spells, and `C_SpellBook.IsSpellKnown(recipeID,
Enum.SpellBookSpellBank.Player)` agreed with `GetRecipeInfo(id).learned` on all 592 Leatherworking recipes checked
[F-123]. Check every recipe ID in your data and **replace** the character's set, so a dropped profession drops its
recipes too:
```lua
local addonName, ns = ...

local function ReadKnownRecipes()
    local known = {}
    for recipeID in pairs(ns.Recipes) do                  -- your recipe data (Data/Recipes.lua)
        if C_SpellBook.IsSpellKnown(recipeID, Enum.SpellBookSpellBank.Player) then known[recipeID] = true end
    end
    ns.db.recipesKnown[ns.CharKey()] = known              -- account-wide, keyed "First Surname"
end
ns.On("LOGIN", function() C_Timer.After(5, ReadKnownRecipes) end)
```
- Don't use `IsPlayerSpell`: it's a deprecation fallback that exists only when `loadDeprecationFallbacks` is on.
- `NEW_RECIPE_LEARNED(recipeID)` covers recipes learned during the session.
- The profession window still helps for diagnostics. On `TRADE_SKILL_LIST_UPDATE` (debounced), skip linked,
  guild and NPC windows (`IsTradeSkillLinked()`, `IsTradeSkillGuild()`, `IsNPCCrafting()`). Then
  `GetAllRecipeIDs()` + `GetRecipeInfo(id).learned` show learned recipes your data lacks.
- **Don't count a recipe as "available on Forever" just because `GetAllRecipeIDs` lists it**: the list is the whole
  skill line, Season-of-Discovery recipes included. Evidence that a recipe is real is a character knowing it, or its
  output (or its recipe item) seen on the AH.
- Working code: BuffettForever `Crafting/Harvest.lua`.

## Recipe data offline: the Forever game tables [F-126]
`tools/wowf/music_catalog.py` fetches DB2 CSVs for a Forever build from
`https://wago.tools/db2/<Table>/csv?build=<build>`. The same tables hold every recipe (checked on 1.60.1.70245):

| Table | Columns that matter |
|---|---|
| SkillLine | `ID`, `DisplayName_lang`, `CategoryID` (11 profession, 9 secondary), `ParentSkillLineID` |
| SkillLineAbility | `SkillLine`, `Spell`, `MinSkillLineRank`, `TrivialSkillLineRankLow/High`, `NumSkillUps`, `AcquireMethod`, `TradeSkillCategoryID` |
| SpellReagents | `SpellID`, `Reagent_0..7`, `ReagentCount_0..7` |
| SpellEffect | `SpellID`, `Effect` (24 = create item, 53 = enchant), `EffectItemType` (output item), `EffectBasePointsF` (count) |
| ItemSparse | `ID`, `Display_lang`, `SellPrice`, `BuyPrice`, `VendorStackCount`, `Stackable`, `Bonding` (1 = BoP), `OverallQualityID`, `ItemLevel` |
| Item | `ID`, `ClassID` (7 = Tradeskill, 9 = Recipe), `SubclassID` |

- Worked rows: Bolt of Linen Cloth (spell 2963) = 2 × Linen Cloth (2589) → 1 × item 2996; Smelt Bronze (2659) =
  Copper Bar (2840) + Tin Bar (3576) → 2 × Bronze Bar (2841).
- Professions are lines 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393 and 129. Each has a Forever child line
  (2937–2948); 70245's recipes sit on the parent lines. Skip riding, racial and `[DNT]` lines; Poisons (40) is
  the rogue class skill, not a profession.
- Gotchas:
  - An item missing from ItemSparse is encrypted (unreleased) in that build: drop its recipes until a later build.
  - **An output count (`EffectBasePointsF`) of 0 means 1** (every transmute) [F-126].
  - `MinSkillLineRank` isn't the skill needed to learn a recipe. `TrivialSkillLineRankLow/High` are the yellow and
    grey thresholds.
  - IDs added after Classic: Season-of-Discovery spells (400k–1M) and **Forever-new recipes** (spells ≥ 1.2M). 117 of
    the Forever-new outputs were on the beta AH, so many are real. Mark a recipe confirmed only when a character
    knows it or its output is seen on the AH. A profession window listing it proves nothing: `GetAllRecipeIDs`
    lists Season-of-Discovery recipes too.
  - Enchants (Effect 53) create no item; only wands, oils and rods do.
  - `BuyPrice / VendorStackCount` is what a merchant charges (checked on 70425). But `BuyPrice` exists on every
    item, and **which** items a vendor sells is server-side, so keep an evidence list.
  - SkillLine and SkillLineAbility CSVs don't start with `ID`: validate the header by column name.
  - Regenerate when a new build lands (part of `/wowf-refresh`).
- **The tool:** `python tools/wowf/cli.py recipe-catalog fetch | build | show [--item ID] | vendor-merge [--build B]`
  (`tools/wowf/recipe_catalog.py`, with tests).
  - It writes BuffettForever's `Data/Recipes.lua`, one numeric row per recipe:
    `{profession, minRank, yellowAt, greyAt, flags, output, count, reagent, count, ...}`. Flag 1 = added after
    Classic, 2 = BoP output.
  - It also writes `Data/Vendor.lua`: unit prices for the reagents in `tools/wowf/data/vendor_reagents.json`.
  - `vendor-merge` adds every reagent BuffettForever's merchant harvest saw on sale (from SavedVariables), with
    evidence. It also lists cheap reagents that look vendor-sold but are still unconfirmed.

## Vendor prices [F-124]
- **What a vendor pays you:** `sellPrice`, the 11th return of `C_Item.GetItemInfo(itemID)` (nil until cached; see the
  async pattern in api-migration.md). The 14th return `bindType` (1 = BoP: no AH exit) and the 17th
  `isCraftingReagent` matter for crafting tools.
- **What a vendor charges:** only readable while a merchant is open. On `MERCHANT_SHOW` / `MERCHANT_UPDATE`, loop
  `i = 1, GetMerchantNumItems()` (runtime-only): `C_MerchantFrame.GetItemInfo(i)` →
  `{name?, texture, price, stackCount, numAvailable, isPurchasable, isUsable, hasExtendedCost, currencyID?, ...}` and
  `GetMerchantItemID(i)`. `price` buys `stackCount` units, so unit price = price / stackCount. Skip
  `hasExtendedCost` items (token or currency costs). A limited supply shows in `numAvailable`; **-1 means
  unlimited** (confirmed on 70425 [F-124]). Reputation discounts are already applied.
- Working code: BuffettForever `Pricing\Merchant.lua` (MERCHANT_SHOW/UPDATE, 0.2 s debounce, tested on 70425).
- `GetMerchantItemInfo` is gone; Blizzard's own merchant frame uses `C_MerchantFrame.GetItemInfo`.
- **Buying from a vendor** (proven on 70450 from a button's click [F-124]): `BuyMerchantItem(index, quantity)`,
  runtime-only, quantity in items. Blizzard's merchant frame (Mainline `MerchantFrame.lua`, which Forever loads)
  [Source 70450]:
  - A right-click buys one stack: `BuyMerchantItem(index)`, `stackCount` items. A left-click picks the item up
    (`PickupMerchantItem`).
  - Shift-click opens the stack split, in steps of `stackCount` up to `min(GetMerchantItemMaxStack(index), what your
    gold buys)`, then calls `BuyMerchantItem(index, split)`.
  - At 150g or more (`MERCHANT_HIGH_PRICE_COST = 1500000`) it asks first (`CONFIRM_HIGH_COST_ITEM`).

  So buy whole stacks, at most `GetMerchantItemMaxStack` a call (the item's stack size), and no more than
  `numAvailable` when it isn't -1. The items go **straight to the bags**, unlike AH purchases, so the bag count's
  rise confirms the purchase. Re-check `GetMerchantItemID(index)` before the call: the merchant's list can change.
  Working code: BuffettForever `Pricing\Merchant.lua` (`Merchant.BuyQty`, `Merchant.Find`) and `Pricing\Buy.lua`
  (`Buy.StartVendor`).

## Money
- Coin icons: `C_CurrencyInfo.GetCoinTextureString(copper[, fontHeight])`; plain text:
  `C_CurrencyInfo.GetCoinText(copper, separator)`; FrameXML's `GetMoneyString(money, separateThousands)` also
  loads. The globals `GetCoinTextureString` and `GetCoinText` are gone.
- `COPPER_PER_GOLD` / `COPPER_PER_SILVER` live only in FrameXML (not seen at runtime). Define
  `local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000` yourself.

## Item slots, drag-and-drop and bag clicks [F-125]
- `ItemButtonTemplate` does **not** exist on Forever. Use `CreateFrame("ItemButton", ...)` (an intrinsic type), or
  `LargeItemButtonTemplate` / `SmallItemButtonTemplate`, or a plain Button with your own textures. Helpers:
  `SetItemButtonTexture`, `SetItemButtonCount(button, count, abbreviate)`, `SetItemButtonQuality(button, quality, itemIDOrLink)`.
- Empty-slot art Blizzard uses on Forever: `Interface\Buttons\UI-EmptySlot-Disabled` (45×45 on a 36×36 button,
  texcoords 0.140625–0.84375) and `Interface\Buttons\UI-EmptySlot`.
- A drop target: in `OnReceiveDrag` and `OnClick`, `local kind, itemID, link = GetCursorInfo()`; when
  `kind == "item"`, take the item and call `ClearCursor()` (the item returns to its bag). `C_Cursor.GetCursorItem()`
  gives the ItemLocation. The global `PickupItem` is gone: `C_Item.PickupItem`.
- Bag clicks: plain clicks use, sell (at a vendor) or post (at the AH) the item. Modified clicks go to
  `ContainerFrameItemButtonMixin:OnModifiedClick` → `HandleModifiedItemClick(link, itemLocation)`; ALT isn't bound
  for bag items in `Bindings_Camelot.xml`. Post-hook `HandleModifiedItemClick` for Alt+click features.
- `ChatEdit_InsertLink` is a deprecated alias: `ChatFrameUtil.InsertLink(link)`.

## Tooltips
- `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data) ... end)`; `data.id`
  is the itemID (ui-patterns.md). `TooltipUtil.GetDisplayedItem(tooltip)` → name, link, id.
- Blizzard's own sell-price line is a `data.lines` entry with `type == Enum.TooltipDataLineType.SellPrice` (11)
  and a `price` (`TooltipDataRules.SellPrice`). Check for it before adding your own "vendor pays" line.
- Skip `tooltip.isShopping` (comparison tooltips), and limit lines to `GameTooltip` / `ItemRefTooltip` unless you
  want them everywhere. Working code: BuffettForever `Tooltip.lua` (tested on 70425).
- `GameTooltip:SetItemByID` / `:SetHyperlink` can return false silently [F-125].

## Probes (paste in game; record results in forever-facts.md with the build)
BuffettForever's harvest answers the profession probes itself (`diag.harvest`, read with `savedvars.py`). Results on
70425 are in [F-123].
- Schematic with the window closed: open a profession, `/run WOWF_R=C_TradeSkillUI.GetFilteredRecipeIDs()[1] print(WOWF_R)`,
  close it, then `/run local ok,s=pcall(C_TradeSkillUI.GetRecipeSchematic,WOWF_R,false) print(ok,s and s.name,s and s.outputItemID,s and #s.reagentSlotSchematics)`
  → 70425: works.
- Schematic for a recipe the character doesn't know (2330 = Minor Healing Potion if Classic IDs carried over):
  `/run local ok,s=pcall(C_TradeSkillUI.GetRecipeSchematic,2330,false) if ok and s then for _,r in ipairs(s.reagentSlotSchematics) do local g=r.reagents[1] print(s.name,r.quantityRequired,g and g.itemID) end else print(ok,s) end`
  → 70425: works, and matches the game tables.
- Recipe info with the window closed: `/run local ok,i=pcall(C_TradeSkillUI.GetRecipeInfo,2330) print(ok,i and i.name,i and i.learned)`
  → 70425: works.
- `GetAllRecipeIDs`, once closed and once open: `/run local t=C_TradeSkillUI.GetAllRecipeIDs() print(type(t),type(t)=="table" and #t)`
  → 70425, open: a table of every recipe of the skill line (592 for Leatherworking). Closed: untested.
- Learned recipes without the window (a tailor who knows Bolt of Linen Cloth):
  `/run print(C_SpellBook.IsSpellKnown(2963, Enum.SpellBookSpellBank.Player))` → 70425: reliable (592 of 592 agreed).
- Merchant data: `/run local i=C_MerchantFrame.GetItemInfo(1) print(i and i.name,i and i.price,i and i.stackCount,i and i.numAvailable,GetMerchantItemID(1))`
- Bag hook: `/run hooksecurefunc("HandleModifiedItemClick",function(l) print("HMIC",l,IsAltKeyDown(),GetMouseButtonClicked()) end)`,
  then Alt+Right-click a bag item (stays until `/reload`).
