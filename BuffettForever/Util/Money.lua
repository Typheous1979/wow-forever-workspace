local addonName, ns = ...

-- Money display. Amounts are copper and may carry fractions (a unit price taken from a stack);
-- keep full precision in the math and round only here. COPPER_PER_SILVER / COPPER_PER_GOLD
-- live only in FrameXML on Forever, so they are defined locally.

local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000

local Money = {}
ns.Money = Money
Money.COPPER_PER_SILVER = COPPER_PER_SILVER
Money.COPPER_PER_GOLD = COPPER_PER_GOLD

-- Coin icons ("12g 3s 4c" as textures) for frames, tooltips and chat. Negative amounts get a
-- minus sign; non-numbers show "?" (unknown is never 0).
function Money.Format(copper, fontHeight)
    if type(copper) ~= "number" or copper ~= copper then return "?" end
    local sign = ""
    if copper < 0 then sign, copper = "-", -copper end
    local whole = math.floor(copper + 0.5)
    if fontHeight then
        return sign .. C_CurrencyInfo.GetCoinTextureString(whole, fontHeight)
    end
    return sign .. C_CurrencyInfo.GetCoinTextureString(whole)
end
