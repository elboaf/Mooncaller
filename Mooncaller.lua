--[[
Name: Mooncaller
Description: Druid HoT-only healing addon with Banzai-1.0 aggro integration,
             dynamic tank detection, talent-aware rank selection, and mana-efficient
             deficit-based downranking.
Dependencies: Banzai-1.0 (which requires AceLibrary, AceEvent-2.0, RosterLib-2.0)
Client: TurtleWoW 1.12 / SuperWoW -- Lua 5.0 compatible, no goto statements
--]]

-------------------------------------------------------------------------------
-- Saved Variables
-------------------------------------------------------------------------------

MooncallerDB = MooncallerDB or {
    DEBUG_MODE            = false,
    REJUV_THRESHOLD       = 90,   -- Firehose/trickle Rejuv spread threshold; also gates Swiftmend
    TRICKLE_THRESHOLD     = 98,   -- Top-up Rejuv for anyone below this % (cheap low ranks)
    TRICKLE_MAX_RANK      = 3,    -- Max Rejuv rank used during trickle pass
    TRICKLE_MANA_FLOOR    = 40,   -- Skip trickle if mana below this %
    AUTO_TREE_FORM        = false,
    AUTO_MOTW             = true,
    MOTW_MANA_THRESHOLD   = 50,
    FOLLOW_ENABLED        = false,
    FOLLOW_TARGET_NAME    = nil,   -- legacy compat
    FOLLOW_TARGET_UNIT    = nil,   -- unitid: party1, raid1, etc. (set via /mpl)
    AOE_BLANKET_THRESHOLD       = 3,    -- uncovered players needed to trigger firehose-priority mode
    REGROWTH_NON_TANK_FLOOR     = 0.55, -- min pressure for Regrowth on non-tank units
    CRITICAL_THRESHOLD          = 70,   -- HP% below which active healing mode activates
    QUICKHEAL_AVOID             = false, -- skip lowest-HP target for Regrowth (yields to QuickHeal)
    SWIFTMEND_EXPIRY_WINDOW     = 3.5,  -- seconds remaining on Rejuv before expiry-path Swiftmend fires
    TANK_LIST                   = {},   -- saved tank names keyed by name for O(1) lookup
    OVERHEAL_TANKS              = false, -- always keep max Rejuv+Regrowth on listed tanks with live aggro
    SWIFTMEND_ENABLED           = true,  -- master enable for Swiftmend
    DISABLED_REJUV_RANKS        = {},    -- ranks to skip, keyed by rank number = true
    DISABLED_REGROWTH_RANKS     = {},    -- ranks to skip, keyed by rank number = true
}

-------------------------------------------------------------------------------
-- Local Settings (runtime copy)
-------------------------------------------------------------------------------

local settings = {}
for k, v in pairs(MooncallerDB) do settings[k] = v end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local Banzai          = nil     -- Banzai-1.0 library reference
local MooncallerEvents = nil    -- AceEvent-embedded stub for Banzai event hooks
local healBusy        = false   -- Mutex: prevents re-entrant heal calls
local inCombat        = false

-- aggroCount[unitName] = rolling integer, incremented on GainAggro, decays on timer
-- Used as the single source of truth for "how tank-like is this unit"
local aggroCount      = {}

-- liveAggro[unitName] = true/false, set directly from Banzai events
local liveAggro       = {}

-- tankList[unitName] = true — manually configured priority tanks
-- Mirrors MooncallerDB.TANK_LIST; populated on ADDON_LOADED.
local tankList        = {}

-- Spell rank disable tables — keyed by rank number, value = true means skip that rank.
-- Mirrors MooncallerDB.DISABLED_REJUV_RANKS / DISABLED_REGROWTH_RANKS.
local disabledRejuvRanks    = {}
local disabledRegrowthRanks = {}

-------------------------------------------------------------------------------
-- Heal Decision Log
-- Only active when logging is toggled on via /mclog.
-- logBuffer = nil means logging is OFF (zero memory footprint).
-- When ON, logBuffer is a table of strings, capped at LOG_MAX_ENTRIES.
-------------------------------------------------------------------------------

local LOG_MAX_ENTRIES = 500
local logBuffer       = nil   -- nil = logging OFF
local logEntryCount   = 0     -- total entries written this session (for display)

-- Cached talent modifiers (refreshed on PLAYER_ALIVE and after LEARNED_SPELL_IN_TAB)
local irMod = 1.0   -- Improved Rejuvenation  (Balance tree, tier 3 row 10)
local gnMod = 1.0   -- Gift of Nature          (Restoration tree, tier 3 row 12)
local mgMod = 1.0   -- Moonglow                (Balance tree, tier 2 row 14) -- mana reduction

-------------------------------------------------------------------------------
-- Spell ID Tables
-------------------------------------------------------------------------------

local SPELL_ID_LOOKUP = {
    ["Tree of Life Form"] = 45705,

    ["Mark of the Wild"] = {
        1126, 5232, 5234, 8907, 9884, 9885, 24752, 16878,
    },
    ["Gift of the Wild"] = 21850,

    -- Ranked lowest to highest so index == rank
    ["Rejuvenation"] = {
        774,    -- Rank 1
        1058,   -- Rank 2
        1430,   -- Rank 3
        2090,   -- Rank 4
        2091,   -- Rank 5
        3627,   -- Rank 6
        8910,   -- Rank 7
        9839,   -- Rank 8
        9840,   -- Rank 9
        9841,   -- Rank 10
        25299,  -- Rank 11
        26981,  -- Rank 12 (TBC era on TurtleWoW)
    },

    ["Regrowth"] = {
        8936, 8938, 8939, 8940, 8941,
        9750, 9856, 9857, 9858, 26980,
    },

    ["Swiftmend"] = 18562,
    ["Nature's Swiftness"] = 17116,
}

-- Rejuvenation rank base HoT values (total heal over full duration, no modifiers)
-- Used for deficit-based rank selection.  Approximate vanilla/TBC values.
local REJUV_RANK_HEAL = {
    32,   -- Rank 1
    56,   -- Rank 2
    116,  -- Rank 3
    180,  -- Rank 4
    244,  -- Rank 5
    304,  -- Rank 6
    388,  -- Rank 7
    488,  -- Rank 8
    608,  -- Rank 9  (note: base listed as 688 in some sources, using conservative)
    756,  -- Rank 10
    888,  -- Rank 11
    1000, -- Rank 12
}

-- Mana cost per rank (approximate)
local REJUV_RANK_MANA = {
    25,  -- Rank 1
    155, -- Rank 2
    185, -- Rank 3
    215, -- Rank 4
    265, -- Rank 5
    315, -- Rank 6
    380, -- Rank 7
    455, -- Rank 8
    545, -- Rank 9
    655, -- Rank 10
    655, -- Rank 11
    740, -- Rank 12
}

-- Regrowth rank direct heal values (approximate, no modifiers)
-- Direct heal component only — used for tank pressure rank selection.
local REGROWTH_RANK_DIRECT = {
    91,   -- Rank 1
    176,  -- Rank 2
    257,  -- Rank 3
    339,  -- Rank 4
    431,  -- Rank 5
    543,  -- Rank 6
    686,  -- Rank 7
    857,  -- Rank 8
    1061, -- Rank 9
    1300, -- Rank 10
}

-- Regrowth mana cost per rank (approximate)
local REGROWTH_RANK_MANA = {
    120,  -- Rank 1
    205,  -- Rank 2
    280,  -- Rank 3
    350,  -- Rank 4
    420,  -- Rank 5
    510,  -- Rank 6
    615,  -- Rank 7
    740,  -- Rank 8
    880,  -- Rank 9
    1020, -- Rank 10
}

-- +healing coefficients
-- Rejuv: pure HoT, 12s duration → 12/15 = 0.80
local REJUV_HEAL_COEFF    = 0.8000
-- Reverse lookup for debug
local SPELL_NAME_BY_ID = {}
for name, idOrTable in pairs(SPELL_ID_LOOKUP) do
    if type(idOrTable) == "table" then
        for _, id in ipairs(idOrTable) do SPELL_NAME_BY_ID[id] = name end
    else
        SPELL_NAME_BY_ID[idOrTable] = name
    end
end

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("Mooncaller: " .. msg)
end

local function Debug(msg)
    if settings.DEBUG_MODE then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ffffMooncaller:|r " .. msg)
    end
end

-------------------------------------------------------------------------------
-- Talent Cache
-------------------------------------------------------------------------------

local function RefreshTalentModifiers()
    -- Improved Rejuvenation: Balance tree, 5% per rank, up to rank 3 → 1.0..1.15
    local _, _, _, _, rank = GetTalentInfo(3, 10)
    irMod = 1.0 + (rank or 0) * 0.05

    -- Gift of Nature: Restoration tree, 2% per rank, up to rank 5 → 1.0..1.10
    local _, _, _, _, rank2 = GetTalentInfo(3, 12)
    gnMod = 1.0 + (rank2 or 0) * 0.02

    -- Moonglow: Balance tree, 3% mana reduction per rank → 0.91..1.0
    local _, _, _, _, rank3 = GetTalentInfo(1, 14)
    mgMod = 1.0 - (rank3 or 0) * 0.03

    Debug(string.format("Talents refreshed: irMod=%.2f gnMod=%.2f mgMod=%.2f",
          irMod, gnMod, mgMod))
end

-------------------------------------------------------------------------------
-- Buff Checking
-------------------------------------------------------------------------------

local function HasBuffById(unit, spellId)
    if not spellId or not unit then return false end
    for i = 1, 32 do
        local _, _, buffId = UnitBuff(unit, i)
        if not buffId then break end
        if buffId == spellId then return true end
    end
    return false
end

local function HasBuffByIdTable(unit, idTable)
    for i = 1, 32 do
        local _, _, buffId = UnitBuff(unit, i)
        if not buffId then break end
        for _, id in ipairs(idTable) do
            if buffId == id then return true end
        end
    end
    return false
end

local function IsInTreeForm()
    return HasBuffById("player", SPELL_ID_LOOKUP["Tree of Life Form"])
end

local function HasMarkOfTheWild(unit)
    return HasBuffByIdTable(unit, SPELL_ID_LOOKUP["Mark of the Wild"])
end

local function HasGiftOfTheWild(unit)
    return HasBuffById(unit, SPELL_ID_LOOKUP["Gift of the Wild"])
end

local function HasAnyDruidBuff(unit)
    return HasMarkOfTheWild(unit) or HasGiftOfTheWild(unit)
end

-- Returns the rank number (1-based) of the Rejuvenation currently on the unit,
-- or 0 if no Rejuvenation buff is present.
local function GetRejuvRank(unit)
    local ids = SPELL_ID_LOOKUP["Rejuvenation"]
    for i = 1, 32 do
        local _, _, buffId = UnitBuff(unit, i)
        if not buffId then break end
        for rank, id in ipairs(ids) do
            if buffId == id then return rank end
        end
    end
    return 0
end

-- Returns the rank number (1-based) of the Regrowth HoT currently on the unit,
-- or 0 if no Regrowth buff is present.
local function GetRegrowthRank(unit)
    local ids = SPELL_ID_LOOKUP["Regrowth"]
    for i = 1, 32 do
        local _, _, buffId = UnitBuff(unit, i)
        if not buffId then break end
        for rank, id in ipairs(ids) do
            if buffId == id then return rank end
        end
    end
    return 0
end

local function HasRejuvenation(unit)
    return GetRejuvRank(unit) > 0
end

local function HasRegrowth(unit)
    return GetRegrowthRank(unit) > 0
end

local function HasAnyHotForSwiftmend(unit)
    return HasRejuvenation(unit) or HasRegrowth(unit)
end

-- Returns the expiration time (abs server time from GetTime()) of the Rejuvenation
-- buff on the given unit, or nil if not present.
-- Requires SuperWoW — UnitBuff returns expirationTime as 5th value.
local function GetRejuvExpiryTime(unit)
    local ids = SPELL_ID_LOOKUP["Rejuvenation"]
    for i = 1, 32 do
        local _, _, buffId, _, expirationTime = UnitBuff(unit, i)
        if not buffId then break end
        for _, id in ipairs(ids) do
            if buffId == id then
                return expirationTime  -- may be 0 if duration unknown, caller handles
            end
        end
    end
    return nil
end

-- Returns true if Swiftmend is currently on cooldown.
local function IsSwiftmendOnCooldown()
    local start, duration = GetSpellCooldown("Swiftmend")
    if not start or start == 0 then return false end
    return (start + duration) > GetTime()
end

local function DetectClearcasting()
    -- Omen of Clarity clearcasting proc: texture "Spell_Shadow_ManaBurn"
    -- UnitBuff returns texture as first return value in 1.12
    for i = 1, 32 do
        local texture = UnitBuff("player", i)
        if not texture then break end
        if string.find(string.lower(texture), "manaburn") then
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Range Checking
-------------------------------------------------------------------------------

-- Range check using SuperWoW UnitPosition (40yd Rejuv range).
-- Does NOT use IsSpellInRange as it requires unit to be current target in 1.12.
local REJUV_RANGE = 40

local function IsUnitInRange(unit, spellName)
    if not unit then return false end
    if unit == "player" then return true end
    if not UnitPosition then return true end  -- SuperWoW unavailable, assume in range
    local px, py = UnitPosition("player")
    if not px then return true end  -- can't get own position, fail open
    local ux, uy = UnitPosition(unit)
    if not ux then return false end  -- unit position unknown = out of range
    local dx = px - ux
    local dy = py - uy
    return math.sqrt(dx*dx + dy*dy) <= REJUV_RANGE
end

-------------------------------------------------------------------------------
-- Tree of Life Form Management
-------------------------------------------------------------------------------

local function ManageTreeForm()
    if not settings.AUTO_TREE_FORM then return end
    local inForm = IsInTreeForm()
    if inCombat and not inForm then
        CastSpellByName("Tree of Life Form")
        Debug("Entering Tree of Life Form")
    elseif not inCombat and inForm then
        CastSpellByName("Tree of Life Form")
        Debug("Exiting Tree of Life Form")
    end
end

-------------------------------------------------------------------------------
-- Aggro Count Decay Timer
-- aggroCount decays by 1 every 3 seconds per unit, floored at 0.
-- This makes recently-tanking units score higher without requiring a static list.
-------------------------------------------------------------------------------

local aggroDecayFrame = CreateFrame("Frame")
local aggroDecayElapsed = 0
aggroDecayFrame:SetScript("OnUpdate", function()
    aggroDecayElapsed = aggroDecayElapsed + arg1
    if aggroDecayElapsed >= 3.0 then
        aggroDecayElapsed = 0
        for name, count in pairs(aggroCount) do
            local newVal = count - 1
            if newVal <= 0 then
                aggroCount[name] = nil
            else
                aggroCount[name] = newVal
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Movement Detection
-- Polls UnitPosition("player") every 0.1s. Sets isMoving = true when position
-- changes between samples, clears it when stable. Regrowth (cast-time spell)
-- is suppressed while moving; Rejuv and Swiftmend (instants) fire normally.
-------------------------------------------------------------------------------

local isMoving        = false
local moveLastX       = nil
local moveLastY       = nil
local moveElapsed     = 0
local MOVE_POLL_RATE  = 0.1

local movePollFrame = CreateFrame("Frame")
movePollFrame:SetScript("OnUpdate", function()
    moveElapsed = moveElapsed + arg1
    if moveElapsed < MOVE_POLL_RATE then return end
    moveElapsed = 0
    if not UnitPosition then return end  -- SuperWoW unavailable
    local x, y = UnitPosition("player")
    if not x then return end
    if moveLastX and (x ~= moveLastX or y ~= moveLastY) then
        isMoving = true
    else
        isMoving = false
    end
    moveLastX = x
    moveLastY = y
end)
-- Tooltip-scans all 19 equipment slots, weapon oils, and active buffs.
-- Buckets +damage and healing separately from +healing only.
-- Cache invalidates on inventory or aura change.
-- Active set bonuses detected by "^Set:" prefix (no leading number = active).
-------------------------------------------------------------------------------

local MCL_Tooltip = CreateFrame("GameTooltip", "MooncallerScanTooltip", nil, "GameTooltipTemplate")
MCL_Tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
local MCL_PREFIX = "MooncallerScanTooltip"

local healCache = {
    damage_and_healing = 0,
    healing_only       = 0,
    dirty              = true,
}

local healCacheFrame = CreateFrame("Frame")
healCacheFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
healCacheFrame:RegisterEvent("PLAYER_AURAS_CHANGED")
healCacheFrame:SetScript("OnEvent", function()
    if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
    healCache.dirty = true
end)

local function ScanHealingPower()
    local dah = 0
    local ho  = 0
    local countedSets = {}

    for slot = 1, 19 do
        local itemLink = GetInventoryItemLink("player", slot)
        if itemLink then
            local _, _, eqLink = string.find(itemLink, "(item:%d+:%d+:%d+:%d+)")
            if eqLink then
                MCL_Tooltip:ClearLines()
                MCL_Tooltip:SetHyperlink(eqLink)
                local setName = nil
                for line = 1, MCL_Tooltip:NumLines() do
                    local text = _G[MCL_PREFIX .. "TextLeft" .. line]:GetText()
                    if text then
                        local _, _, v

                        -- +damage and healing
                        _, _, v = string.find(text, "Increases damage and healing done by magical spells and effects by up to (%d+)%.")
                        if v and not string.find(text, "Set:") then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "Spell Damage %+(%d+)")
                        if v then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Spell Damage and Healing")
                        if v then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Damage and Healing Spells")
                        if v then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Spell Power")
                        if v then dah = dah + tonumber(v) end

                        -- +healing only
                        _, _, v = string.find(text, "Increases healing done by spells and effects by up to (%d+)%.")
                        if v and not string.find(text, "Set:") then ho = ho + tonumber(v) end

                        _, _, v = string.find(text, "Healing Spells %+(%d+)")
                        if v then ho = ho + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Healing Spells")
                        if v then ho = ho + tonumber(v) end

                        _, _, v = string.find(text, "Healing %+(%d+)")
                        if v then ho = ho + tonumber(v) end

                        -- Atiesh healing portion
                        _, _, v = string.find(text, "Increases your spell damage by up to %d+ and your healing by up to (%d+)%.")
                        if v then ho = ho + tonumber(v) end

                        -- Set name line e.g. "Stormcaller's Garb (2/8)"
                        _, _, v = string.find(text, "^(.+) %(%d/%d%)$")
                        if v then setName = v end

                        -- Set bonuses: active = "^Set:", inactive = "^(N) Set:"
                        if setName then
                            _, _, v = string.find(text, "^Set: Increases damage and healing done by magical spells and effects by up to (%d+)%.")
                            if v then
                                local key = setName .. "|dah|" .. v
                                if not countedSets[key] then
                                    dah = dah + tonumber(v)
                                    countedSets[key] = true
                                end
                            end

                            _, _, v = string.find(text, "^Set: Increases healing done by spells and effects by up to (%d+)%.")
                            if v then
                                local key = setName .. "|ho|" .. v
                                if not countedSets[key] then
                                    ho = ho + tonumber(v)
                                    countedSets[key] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Weapon oils
    if MCL_Tooltip:SetInventoryItem("player", 16) then
        for line = 1, MCL_Tooltip:NumLines() do
            local text = _G[MCL_PREFIX .. "TextLeft" .. line]:GetText()
            if text then
                if string.find(text, "^Brilliant Wizard Oil") then
                    dah = dah + 36; break
                elseif string.find(text, "^Lesser Wizard Oil") then
                    dah = dah + 16; break
                elseif string.find(text, "^Minor Wizard Oil") then
                    dah = dah + 8;  break
                elseif string.find(text, "^Wizard Oil") then
                    dah = dah + 24; break
                elseif string.find(text, "^Brilliant Mana Oil") then
                    ho = ho + 25;   break
                end
            end
        end
    end

    -- Aura (buff) scan
    for i = 1, 32 do
        local texture = UnitBuff("player", i)
        if not texture then break end
        MCL_Tooltip:ClearLines()
        MCL_Tooltip:SetUnitBuff("player", i)
        for line = 1, MCL_Tooltip:NumLines() do
            local text = _G[MCL_PREFIX .. "TextLeft" .. line]:GetText()
            if text then
                local _, _, v
                _, _, v = string.find(text, "Increases damage and healing done by magical spells and effects by up to (%d+)%.")
                if v then dah = dah + tonumber(v) end
                _, _, v = string.find(text, "Increases healing done by spells and effects by up to (%d+)%.")
                if v then ho = ho + tonumber(v) end
            end
        end
    end

    healCache.damage_and_healing = dah
    healCache.healing_only       = ho
    healCache.dirty              = false
    Debug(string.format("HealingPower scan: dah=%d ho=%d total=%d", dah, ho, dah+ho))
end

local function GetEffectiveHealingPower()
    if healCache.dirty then ScanHealingPower() end
    return healCache.damage_and_healing + healCache.healing_only
end

-------------------------------------------------------------------------------
-- Deficit-Based Rejuvenation Rank Selection
--
-- Returns the rank number (1-based index into SPELL_ID_LOOKUP["Rejuvenation"])
-- that is the minimum-sufficient rank to cover the heal deficit, gated by
-- current mana.  For aggro holders the deficit is inflated to anticipate
-- incoming damage.
-------------------------------------------------------------------------------

local function PickRejuvRank(unit, forceMax)
    local mana = UnitMana("player")
    local maxRank = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    local chosenRank = 1

    -- Clearcasting: mana is free, force max rank
    if DetectClearcasting() or forceMax then
        Debug("Clearcasting or forceMax: using max rank Rejuv")
        return maxRank
    end

    -- Compute deficit
    local maxHp = UnitHealthMax(unit)
    local curHp = UnitHealth(unit)
    local deficit = maxHp - curHp

    -- Inflate deficit for units with aggro history (they will keep taking hits)
    local unitName = UnitName(unit)
    local score = aggroCount[unitName] or 0
    local combatMult = 1.0
    if inCombat then
        -- k = 0.9 means we want rank whose output >= deficit * (1/0.9) ≈ deficit * 1.11
        -- For high aggro-score units bump to 1.20 anticipating sustained damage
        if score > 0 then
            combatMult = 1.0 + math.min(score, 10) * 0.02  -- up to 1.20
        else
            combatMult = 0.9
        end
    end
    local effectiveDeficit = deficit * combatMult

    -- Walk up rank table: pick lowest rank whose effective heal covers deficit,
    -- while respecting mana budget and applying talent modifiers.
    -- Effective heal includes +healing contribution via REJUV_HEAL_COEFF.
    local healingPower = GetEffectiveHealingPower()
    for rank = 1, maxRank do
        local baseHeal   = REJUV_RANK_HEAL[rank] or 0
        local scaledHeal = (baseHeal + healingPower * REJUV_HEAL_COEFF) * irMod * gnMod
        local manaCost   = (REJUV_RANK_MANA[rank] or 0) * mgMod

        if scaledHeal >= effectiveDeficit then
            if mana >= manaCost then
                chosenRank = rank
            end
            break
        end

        if mana >= manaCost then
            chosenRank = rank
        end
    end

    Debug(string.format("PickRejuvRank: %s deficit=%d effectiveDeficit=%d rank=%d",
          unitName, deficit, math.floor(effectiveDeficit), chosenRank))
    return chosenRank
end

local function CastRejuvByRank(rank)
    local ids = SPELL_ID_LOOKUP["Rejuvenation"]
    local maxRank = table.getn(ids)
    rank = math.max(1, math.min(rank, maxRank))
    -- Step down to nearest enabled rank
    while rank > 1 and disabledRejuvRanks[rank] do
        rank = rank - 1
    end
    if disabledRejuvRanks[rank] then
        Debug("CastRejuvByRank: all ranks disabled, skipping")
        return
    end
    local rankStr = rank == maxRank and "Rejuvenation" or ("Rejuvenation(Rank " .. rank .. ")")
    CastSpellByName(rankStr)
    Debug("Casting " .. rankStr)
end

-- Cast Regrowth on a unit, respecting the HoT-clipping rule:
--
--   intendedRank  = the rank we would use on a fresh target
--   existingRank  = GetRegrowthRank(unit)  (0 = no existing HoT)
--
-- If existingRank == 0: cast at intendedRank normally (fresh HoT + direct heal).
-- If existingRank > 0: we must cast strictly below existingRank so the incoming
--   cast's weaker HoT does not overwrite the current one.  The direct heal still
--   lands.  If we cannot go lower (existingRank == 1) we skip and return false.
--
-- Returns true if a cast was made, false if skipped.
-- Cast Regrowth with correct HoT overwrite awareness.
--
-- WoW HoT overwrite rule: casting HIGHER rank overwrites the existing HoT.
-- Casting LOWER OR EQUAL rank leaves the existing HoT completely untouched
-- while still delivering the direct heal component of the cast.
--
-- Three zones based on existing HoT rank:
--
--   ZONE 1 — No HoT, or existing HoT is rank 1-5 (low rank):
--     Cast freely at intendedRank.  A low-rank HoT being replaced by something
--     stronger is a net gain, and protecting rank 1-5 ticks isn't worth
--     constraining our healing output.
--
--   ZONE 2 — Existing HoT is rank 6-9 (mid-high rank):
--     Prefer to cast one rank BELOW existingRank to preserve the ticks while
--     still landing a direct heal.  However if pressure is high (>= 0.55) OR
--     intendedRank is meaningfully higher (>= existingRank + 2), allow the
--     overwrite — a stronger HoT plus full direct heal is worth the lost ticks.
--     If casting below existingRank is not possible (existingRank == 6, safe = 5,
--     that's fine), proceed normally.
--
--   ZONE 3 — Existing HoT is max rank:
--     Never overwrite with a lower rank — it would weaken the HoT.
--     Cast one rank below max to get the direct heal while the max HoT keeps
--     ticking.  If intendedRank is also max (i.e. we genuinely want to refresh
--     max rank), allow it — same rank does overwrite but at equal strength.
--
-- pressure  optional 0.0-1.0 tank pressure score, used for zone 2 override.
--           Pass nil or 0 for non-tank healing paths.
--
-- Returns true if a cast was made, false if skipped.
local REGROWTH_PROTECT_FLOOR = 6   -- HoT ranks below this need no protection

local function CastRegrowthSafe(unit, intendedRank, pressure)
    local rgIds     = SPELL_ID_LOOKUP["Regrowth"]
    local maxRgRank = table.getn(rgIds)
    intendedRank    = math.max(1, math.min(intendedRank, maxRgRank))
    pressure        = pressure or 0

    local existingRank = GetRegrowthRank(unit)
    local castRank

    -- ZONE 1: no HoT or low-rank HoT — cast freely
    if existingRank == 0 or existingRank < REGROWTH_PROTECT_FLOOR then
        castRank = intendedRank
        if existingRank > 0 and intendedRank > existingRank then
            Debug(string.format("CastRegrowthSafe: overwriting low HoT R%d with R%d",
                  existingRank, intendedRank))
        end

    -- ZONE 3: existing HoT is max rank
    elseif existingRank == maxRgRank then
        if intendedRank == maxRgRank then
            -- Refreshing max rank with max rank — allowed (same strength overwrite)
            castRank = maxRgRank
            Debug("CastRegrowthSafe: refreshing max rank HoT")
        else
            -- Cast one below max for direct heal, max HoT keeps ticking
            castRank = maxRgRank - 1
            Debug(string.format("CastRegrowthSafe: existing max HoT, casting R%d for direct heal",
                  castRank))
        end

    -- ZONE 2: existing HoT is rank 6-9
    else
        -- Allow overwrite if pressure is high OR intendedRank is significantly stronger
        local highPressure  = pressure >= 0.55
        local bigUpgrade    = intendedRank >= existingRank + 2

        if highPressure or bigUpgrade then
            -- Overwrite with intendedRank — stronger HoT + full direct heal
            castRank = intendedRank
            Debug(string.format(
                  "CastRegrowthSafe: overwriting R%d HoT with R%d (pressure=%.2f bigUpgrade=%s)",
                  existingRank, castRank, pressure, tostring(bigUpgrade)))
        else
            -- Preserve ticks: cast one rank below existing so HoT is untouched,
            -- direct heal still lands.
            castRank = existingRank - 1
            -- castRank is guaranteed >= 1 because existingRank >= 6
            Debug(string.format(
                  "CastRegrowthSafe: preserving R%d HoT, casting R%d for direct heal",
                  existingRank, castRank))
        end
    end

    castRank = math.max(1, math.min(castRank, maxRgRank))
    -- Step down to nearest enabled rank
    while castRank > 1 and disabledRegrowthRanks[castRank] do
        castRank = castRank - 1
    end
    if disabledRegrowthRanks[castRank] then
        Debug("CastRegrowthSafe: all ranks disabled, skipping")
        return false
    end
    local rankStr = castRank == maxRgRank
        and "Regrowth"
        or  ("Regrowth(Rank " .. castRank .. ")")
    CastSpellByName(rankStr)
    Debug("Casting " .. rankStr .. " on " .. UnitName(unit))
    return true
end

-- Determine whether a low-rank Rejuv on a high-aggro unit should be upgraded.
-- Returns the rank to cast as an upgrade, or 0 meaning no upgrade warranted.
-- All four conditions must be true:
--   1. Ideal rank is at least 2 higher than what is currently rolling
--   2. Unit has live aggro OR aggroCount >= threshold (sustained tank behaviour)
--   3. Unit health is below REJUV_UPGRADE_HP_FLOOR (actively in danger)
--   4. We can afford max rank mana cost
local AGGRO_UPGRADE_THRESHOLD = 8   -- aggroCount score floor
local REJUV_UPGRADE_HP_FLOOR  = 75  -- health % ceiling for upgrade eligibility

local function ShouldUpgradeRejuv(unit, currentRank)
    local maxRank   = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    local idealRank = PickRejuvRank(unit, false)

    if (idealRank - currentRank) < 2 then return 0 end

    local name  = UnitName(unit)
    local score = aggroCount[name] or 0
    if not liveAggro[name] and score < AGGRO_UPGRADE_THRESHOLD then return 0 end

    local hp = (UnitHealth(unit) / UnitHealthMax(unit)) * 100
    if hp >= REJUV_UPGRADE_HP_FLOOR then return 0 end

    local manaCost = (REJUV_RANK_MANA[maxRank] or 0) * mgMod
    if UnitMana("player") < manaCost then return 0 end

    Debug(string.format("ShouldUpgradeRejuv: %s R%d->R%d hp=%.0f score=%d",
          name, currentRank, maxRank, hp, score))
    return maxRank
end

-------------------------------------------------------------------------------
-- Tank Pressure Score
--
-- A continuous 0.0–1.0 value representing how urgently a tank-like unit needs
-- healing RIGHT NOW.  This replaces static HP% band decisions for units with
-- significant aggro history or live aggro.
--
-- Inputs weighted:
--   hp deficit %       — how low they are (0 = full, 1 = dead)
--   liveAggro          — actively being hit right now (+0.25 flat)
--   aggroCount score   — sustained tank history, scaled to 0..0.25
--   HoT coverage       — existing ticking heals reduce urgency
--     each active HoT (Rejuv / Regrowth) subtracts a small amount
--     scaled by the rank of the HoT relative to max (stronger HoT = bigger reduction)
--
-- Result interpretation:
--   < 0.15  low pressure  — trickle is sufficient
--   0.15–0.40  moderate   — need active Regrowth, rank scales with score
--   0.40–0.65  high       — higher rank Regrowth, ensure Rejuv is solid
--   > 0.65  critical      — max rank response, Swiftmend if available
-------------------------------------------------------------------------------

local function ComputeTankPressureScore(unit)
    local maxHp   = UnitHealthMax(unit)
    local curHp   = UnitHealth(unit)
    local deficitPct = (maxHp - curHp) / maxHp   -- 0.0 (full) to 1.0 (dead)

    local name  = UnitName(unit)
    local score = aggroCount[name] or 0

    -- Base: deficit drives urgency
    local pressure = deficitPct

    -- Live aggro bonus: actively being hit
    if liveAggro[name] then
        pressure = pressure + 0.25
    end

    -- Historical aggro bonus: sustained tank, scaled 0..0.25
    pressure = pressure + math.min(score, 30) / 30 * 0.25

    -- Listed tank bonus: manually designated tanks get an additional flat boost
    -- so they always score above aggro-detected units at equivalent HP.
    if tankList[name] then
        pressure = pressure + 0.30
    end

    -- HoT coverage reduction: existing ticks lower urgency
    local maxRejuvRank  = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    local maxRegrowthRank = table.getn(SPELL_ID_LOOKUP["Regrowth"])

    local rejuvRank   = GetRejuvRank(unit)
    local regrowthRank = GetRegrowthRank(unit)

    if rejuvRank > 0 then
        -- Stronger Rejuv = bigger reduction, up to -0.15
        pressure = pressure - (rejuvRank / maxRejuvRank) * 0.15
    end
    if regrowthRank > 0 then
        -- Stronger Regrowth HoT = bigger reduction, up to -0.20
        pressure = pressure - (regrowthRank / maxRegrowthRank) * 0.20
    end

    -- Clamp to 0..1
    if pressure < 0 then pressure = 0 end
    if pressure > 1 then pressure = 1 end

    -- Safety floor: anyone below 20% hp gets pressure bumped to at least 0.75
    -- regardless of aggro history or HoT coverage.  Catches cloth wearers and
    -- other low-health-pool units who took spike damage and would otherwise
    -- score low due to having no aggro contribution.
    local hpPct = (UnitHealth(unit) / UnitHealthMax(unit)) * 100
    if hpPct < 20 and pressure < 0.75 then
        pressure = 0.75
    end

    Debug(string.format("TankPressure: %s deficit=%.0f%% live=%s score=%d rejuv=R%d rg=R%d -> %.2f",
          name, deficitPct*100, tostring(liveAggro[name] or false),
          score, rejuvRank, regrowthRank, pressure))

    return pressure
end

-- Returns true if this unit qualifies for dynamic tank healing
-- (has live aggro or a meaningful aggro history score)
local TANK_SCORE_FLOOR = 5  -- minimum aggroCount to be treated as a tank

local function IsListedTank(unit)
    local name = UnitName(unit)
    if not name then return false end
    return tankList[name] == true
end

local function IsTankLike(unit)
    local name = UnitName(unit)
    return tankList[name] or liveAggro[name] or (aggroCount[name] or 0) >= TANK_SCORE_FLOOR
end

-- Pick the appropriate Regrowth rank for a unit based on pressure score.
-- Returns intended rank (before CastRegrowthSafe applies the clip-safe adjustment).
-- Pressure thresholds:
--   > 0.70    → max rank (full response)
--   0.55–0.70 → Rank 7 (strong direct heal)
--   0.35–0.55 → Rank 5 (meaningful direct heal)
--   0.15–0.35 → Rank 3 (cheap direct heal)
--   0–0.15    → Rank 1 (consolation cast — always do something)
--   0 exactly → return 0 (unit is at full health, not in pool, skip)
-- Additionally gated by mana: if we can't afford the chosen rank, step down.
-- The mana step-down floors at rank 1, never returns 0 once a rank is chosen.
local function PickRegrowthRank(pressure)
    local maxRank = table.getn(SPELL_ID_LOOKUP["Regrowth"])
    local mana    = UnitMana("player")
    -- Note: Regrowth rank selection is pressure-threshold driven, not deficit-driven,
    -- because Regrowth's primary value is the HoT component which doesn't map cleanly
    -- to a single deficit number. +healing increases both direct and HoT components
    -- but doesn't change which rank is appropriate for a given pressure level.

    local intendedRank
    if pressure >= 0.70 then
        intendedRank = maxRank
    elseif pressure >= 0.55 then
        intendedRank = math.min(7, maxRank)
    elseif pressure >= 0.35 then
        intendedRank = math.min(5, maxRank)
    elseif pressure >= 0.15 then
        intendedRank = math.min(3, maxRank)
    elseif pressure > 0 then
        intendedRank = 1  -- small deficit: consolation rank 1, always cast something
    else
        return 0  -- no deficit at all, unit is full health
    end

    -- Step down if mana is tight, but never below rank 1
    while intendedRank > 1 do
        local cost = (REGROWTH_RANK_MANA[intendedRank] or 0) * mgMod
        if mana >= cost then break end
        intendedRank = intendedRank - 1
    end

    return intendedRank
end

-------------------------------------------------------------------------------
-- Effective Health Score for Sorting
--
-- Lower = higher priority.
-- Aggro holders are penalised (lower effectiveHealth) to rise in the queue.
-- liveAggro gives an immediate -10 bias; aggroCount adds up to -15 more.
-------------------------------------------------------------------------------

local function EffectiveHealthScore(unit)
    local hp = (UnitHealth(unit) / UnitHealthMax(unit)) * 100
    local name = UnitName(unit)
    local aggroBias = 0
    if tankList[name] then
        aggroBias = aggroBias + 20  -- listed tanks always sort above aggro-detected units
    end
    if liveAggro[name] then
        aggroBias = aggroBias + 10
    end
    local score = aggroCount[name] or 0
    aggroBias = aggroBias + math.min(score, 10) * 1.5
    return hp - aggroBias
end

local function SortByEffectiveHealth(a, b)
    return EffectiveHealthScore(a) < EffectiveHealthScore(b)
end

-------------------------------------------------------------------------------
-- Unit Iteration Helper
-------------------------------------------------------------------------------

local function IterateHealableUnits(callback)
    callback("player")
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            callback("raid" .. i)
        end
    else
        for i = 1, GetNumPartyMembers() do
            callback("party" .. i)
        end
    end
end

-------------------------------------------------------------------------------
-- Heal Decision Logging
-------------------------------------------------------------------------------

-- Returns a short HH:MM:SS timestamp using in-game time.
local function LogTimestamp()
    local gameTime = GetGameTime()
    local h  = math.mod(math.floor(gameTime), 24)
    local m  = math.floor(math.mod(gameTime, 1) * 60)
    local s  = math.floor(math.mod(math.mod(gameTime, 1) * 60, 1) * 60)
    local cs = math.floor(math.mod(GetTime(), 1) * 100)
    return string.format("%02d:%02d:%02d.%02d", h, m, s, cs)
end

-- Append one pipe-delimited line to the in-memory buffer.
-- Fields: timestamp | unit | hp% | pressure | rejuvRank | regrowthRank |
--         liveAggro | aggroScore | action | spellRank | healingPower | missingHP | isTank
-- No-op if logging is OFF (logBuffer == nil).
local function LogHealAction(unit, pressure, action, spellRank)
    if not logBuffer then return end

    local name        = UnitName(unit) or "?"
    local hp          = math.floor((UnitHealth(unit) / UnitHealthMax(unit)) * 100)
    local rejuvRank   = GetRejuvRank(unit)
    local rgRank      = GetRegrowthRank(unit)
    local live        = liveAggro[name] and "1" or "0"
    local score       = aggroCount[name] or 0
    local ts          = LogTimestamp()
    local healingPow  = GetEffectiveHealingPower()
    local missingHP   = UnitHealthMax(unit) - UnitHealth(unit)
    local tank        = IsTankLike(unit) and "1" or "0"

    local line = string.format("%s|%s|%d|%.2f|%d|%d|%s|%d|%s|%s|%d|%d|%s",
        ts, name, hp, pressure, rejuvRank, rgRank,
        live, score, action, tostring(spellRank),
        healingPow, missingHP, tank)

    if table.getn(logBuffer) >= LOG_MAX_ENTRIES then
        table.remove(logBuffer, 1)
    end
    table.insert(logBuffer, line)
    logEntryCount = logEntryCount + 1
end

-- Write the in-memory buffer to MooncallerLog.txt via SuperWoW ExportFile.
local function FlushLog()
    if not logBuffer then
        Print("Logging is not active. Use /mclog to start.")
        return
    end
    if table.getn(logBuffer) == 0 then
        Print("Log buffer is empty, nothing to export.")
        return
    end
    local lines = {}
    table.insert(lines, "# Mooncaller session export " .. LogTimestamp() ..
                         " zone=" .. (GetZoneText() or "?"))
    table.insert(lines, "# ts(hh:mm:ss.cs)|unit|hp%|pressure|rejuvRank|rgRank|liveAggro|aggroScore|action|spellRank|healingPower|missingHP|isTank")
    for _, line in ipairs(logBuffer) do
        table.insert(lines, line)
    end
    table.insert(lines, "# end entries=" .. table.getn(logBuffer) ..
                         " total_this_session=" .. logEntryCount)
    local payload = table.concat(lines, "\n")
    if ExportFile then
        ExportFile("MooncallerLog.txt", payload)
        Print(string.format("Log exported: %d entries -> MooncallerLog.txt",
              table.getn(logBuffer)))
    else
        Print("ExportFile not available — SuperWoW required for log export.")
    end
end

-- Toggle logging on/off.
local function ToggleLogging()
    if logBuffer then
        FlushLog()
        logBuffer     = nil
        logEntryCount = 0
        Print("Heal logging OFF. Buffer released.")
    else
        logBuffer     = {}
        logEntryCount = 0
        Print("Heal logging ON. Use /mcexport to write log, /mclog again to stop.")
    end
end

-------------------------------------------------------------------------------
-- Reactive Heal: fires on Banzai_UnitGainedAggro
-- Always casts max rank Rejuvenation on aggro pickup.
-- At the moment of aggro pickup the unit is typically at or near full health,
-- so deficit-based rank selection would return a trivially low rank.
-- Max rank is always correct here because we are anticipating incoming damage,
-- not reacting to existing deficit.
-------------------------------------------------------------------------------

-- Units that recently gained aggro and need a pre-emptive max rank Rejuv
-- on the next /mcheal keypress. Keyed by unit token, value = true.
local pendingReactiveRejuv = {}

local function OnUnitGainedAggro(unitId)
    local unitName = UnitName(unitId)
    if not unitName then return end

    -- Update tracking tables
    liveAggro[unitName] = true
    aggroCount[unitName] = math.min((aggroCount[unitName] or 0) + 10, 30)

    Debug("Banzai: " .. unitName .. " gained aggro (score=" ..
          tostring(aggroCount[unitName]) .. ")")

    if not UnitExists(unitId) then return end
    if UnitIsDeadOrGhost(unitId) then return end

    -- Flag for pre-emptive Rejuv on the next hardware-event keypress.
    -- Spell casts are blocked outside of hardware events in 1.12, so we
    -- cannot cast directly from this AceEvent callback.
    local maxRank = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    if GetRejuvRank(unitId) < maxRank then
        pendingReactiveRejuv[unitId] = true
        Debug("REACTIVE: flagged " .. unitName .. " for pre-emptive Rejuv on next keypress")
    end
end

local function OnUnitLostAggro(unitId)
    local unitName = UnitName(unitId)
    if unitName then
        liveAggro[unitName] = nil
        pendingReactiveRejuv[unitId] = nil
        Debug("Banzai: " .. unitName .. " lost aggro")
        -- aggroCount intentionally NOT reset: historical score persists for rank decisions
    end
end

-------------------------------------------------------------------------------
-- Main Healing Logic — four tiers processed in priority order each keypress:
--
--  1. CRITICAL CHECK  — if anyone is in active danger, skip trickle/firehose
--                       and go straight to tank-dynamic or normal healing.
--  2. TRICKLE PASS    — cheap low-rank Rejuv for anyone slightly below full,
--                       aggro holders skip the rank cap and use PickRejuvRank.
--  3. FIREHOSE PASS   — spread Rejuv across anyone below REJUV_THRESHOLD
--                       who doesn't already have one.
--  4a. TANK DYNAMIC   — for tank-like units (live aggro or high aggroCount),
--                       use ComputeTankPressureScore to pick Regrowth rank
--                       and Rejuv rank continuously rather than HP% bands.
--  4b. NORMAL HEALING — static HP% tier logic for non-tank raid members.
-------------------------------------------------------------------------------

local function HealPartyMembers()
    if healBusy then
        Debug("HealPartyMembers: busy, skipping")
        return
    end
    healBusy = true

    -- ---- Pending reactive Rejuvs (flagged by OnUnitGainedAggro) ----
    -- These must be cast from a hardware event (keypress), not from the
    -- AceEvent callback, so we deferred them here.
    local maxRejuvRank = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    for unitId in pairs(pendingReactiveRejuv) do
        pendingReactiveRejuv[unitId] = nil
        if UnitExists(unitId) and not UnitIsDeadOrGhost(unitId)
        and IsUnitInRange(unitId, "Rejuvenation")
        and GetRejuvRank(unitId) < maxRejuvRank then
            -- Only fire the pre-emptive Rejuv if the unit is healthy enough
            -- that Rejuv is the right call. If they're already damaged enough
            -- to warrant a Regrowth, drop the flag and let the normal healing
            -- loop handle it with proper pressure-based rank selection.
            local pressure = ComputeTankPressureScore(unitId)
            if pressure >= 0.35 then
                Debug("REACTIVE: " .. (UnitName(unitId) or unitId) ..
                      " pressure=" .. string.format("%.2f", pressure) ..
                      " too high for pre-emptive Rejuv, deferring to heal loop")
            else
                local unitName = UnitName(unitId) or unitId
                TargetUnit(unitId)
                CastRejuvByRank(maxRejuvRank)
                TargetLastTarget()
                LogHealAction(unitId, 1.0, "REACTIVE_REJUV", maxRejuvRank)
                Debug("REACTIVE: pre-emptive max Rejuv R" .. maxRejuvRank .. " on " .. unitName)
                healBusy = false
                return
            end
        end
    end

    ManageTreeForm()

    -- ---- Overheal Tanks pass ----
    -- When OVERHEAL_TANKS is ON: any listed tank with live aggro that is missing
    -- max rank Rejuv or max rank Regrowth gets it cast immediately, before any
    -- other logic runs. Rejuv takes priority over Regrowth (cast Rejuv first
    -- keypress, Regrowth next). Iterates all qualifying tanks per keypress and
    -- fires on the first in-range gap found.
    if settings.OVERHEAL_TANKS then
        local maxRejuvRank = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
        local maxRgRank    = table.getn(SPELL_ID_LOOKUP["Regrowth"])
        local overhealDone = false
        IterateHealableUnits(function(unit)
            if overhealDone then return end
            if not UnitExists(unit) then return end
            if UnitIsDeadOrGhost(unit) then return end
            if not IsListedTank(unit) then return end
            local name = UnitName(unit)
            if not liveAggro[name] then return end
            if not IsUnitInRange(unit, "Rejuvenation") then return end
            -- Rejuv gap: missing or below max rank
            if GetRejuvRank(unit) < maxRejuvRank then
                TargetUnit(unit)
                CastRejuvByRank(maxRejuvRank)
                TargetLastTarget()
                LogHealAction(unit, 1.0, "OVERHEAL_REJUV", maxRejuvRank)
                Debug("OVERHEAL: max Rejuv R" .. maxRejuvRank .. " on " .. name)
                overhealDone = true
            -- Regrowth gap: missing or below max rank (skipped while moving)
            elseif not isMoving
            and IsUnitInRange(unit, "Regrowth")
            and GetRegrowthRank(unit) < maxRgRank then
                TargetUnit(unit)
                CastRegrowthSafe(unit, maxRgRank, 1.0)
                TargetLastTarget()
                LogHealAction(unit, 1.0, "OVERHEAL_REGROWTH", maxRgRank)
                Debug("OVERHEAL: max Regrowth R" .. maxRgRank .. " on " .. name)
                overhealDone = true
            end
        end)
        if overhealDone then
            healBusy = false
            return
        end
    end

    -- ---- Expiry-path Swiftmend ----
    -- Fires on every keypress (trickle, firehose, or active mode) regardless of
    -- HP%.  Scans all members for a Rejuv within SWIFTMEND_EXPIRY_WINDOW seconds
    -- of expiring, then Swiftmends the soonest-expiring candidate to capture the
    -- heal before the remaining ticks are lost and keep Swiftmend on CD.
    -- Tanks excluded (Swiftmend consumes the HoT). Skipped if window == 0 or CD.
    local expiryWindow = settings.SWIFTMEND_EXPIRY_WINDOW or 3.5
    if (settings.SWIFTMEND_ENABLED ~= false) and expiryWindow > 0 and not IsSwiftmendOnCooldown() then
        local now        = GetTime()
        local bestUnit   = nil
        local bestExpiry = math.huge  -- pick the soonest-expiring Rejuv
        IterateHealableUnits(function(unit)
            if not UnitExists(unit) then return end
            if UnitIsDeadOrGhost(unit) then return end
            if not UnitIsConnected(unit) then return end
            if IsTankLike(unit) then return end
            if not IsUnitInRange(unit, "Swiftmend") then return end
            local expiry = GetRejuvExpiryTime(unit)
            if expiry and expiry > 0 then
                local remaining = expiry - now
                if remaining > 0 and remaining <= expiryWindow then
                    if remaining < bestExpiry then
                        bestExpiry = remaining
                        bestUnit   = unit
                    end
                end
            end
        end)
        if bestUnit then
            local name     = UnitName(bestUnit)
            local pressure = ComputeTankPressureScore(bestUnit)
            TargetUnit(bestUnit)
            CastSpellByName("Swiftmend")
            TargetLastTarget()
            LogHealAction(bestUnit, pressure, "SWIFTMEND_EXPIRY", 1)
            Debug(string.format("SWIFTMEND_EXPIRY on %s (%.1fs remaining)", name, bestExpiry))
            healBusy = false
            return
        end
    end

    -- ---- Build member lists ----
    local allMembers = {}   -- {unit, health}  all valid in-range members
    local lowMembers = {}   -- units below REJUV_THRESHOLD (for normal pass)

    local function CheckUnit(unit)
        if not UnitExists(unit) then return end
        if UnitIsDeadOrGhost(unit) then return end
        if not UnitIsConnected(unit) then return end
        if not IsUnitInRange(unit, "Rejuvenation") then return end
        local hp = (UnitHealth(unit) / UnitHealthMax(unit)) * 100
        table.insert(allMembers, { unit = unit, health = hp })
        if hp < settings.REJUV_THRESHOLD then
            table.insert(lowMembers, unit)
        end
    end

    IterateHealableUnits(CheckUnit)
    table.sort(lowMembers, SortByEffectiveHealth)

    -- ---- Critical check: is anyone in active danger? ----
    local critThresh = settings.CRITICAL_THRESHOLD or 70
    local someoneCritical = false
    for _, m in ipairs(allMembers) do
        if m.health < critThresh then
            someoneCritical = true
            break
        end
    end

    -- =========================================================
    -- TRICKLE + FIREHOSE (only when no one is critical)
    -- =========================================================
    if not someoneCritical then

        -- Mana check for trickle
        local manaPercent = (UnitMana("player") / UnitManaMax("player")) * 100

        -- ---- TRICKLE PASS ----
        -- Anyone below TRICKLE_THRESHOLD without Rejuv gets a cheap top-up.
        -- Tank-like units bypass the rank cap and use PickRejuvRank.
        if manaPercent >= settings.TRICKLE_MANA_FLOOR then
            Debug("TRICKLE PASS (mana=" .. math.floor(manaPercent) .. "%)")
            local trickleCandidates = {}
            for _, m in ipairs(allMembers) do
                if m.health < settings.TRICKLE_THRESHOLD
                and GetRejuvRank(m.unit) == 0 then
                    table.insert(trickleCandidates, m.unit)
                end
            end

            if table.getn(trickleCandidates) > 0 then
                table.sort(trickleCandidates, SortByEffectiveHealth)
                local target = trickleCandidates[1]
                if IsUnitInRange(target, "Rejuvenation") then
                    local rank
                    if IsTankLike(target) then
                        -- Tank: proper rank for deficit, ignore trickle cap
                        rank = PickRejuvRank(target, false)
                        Debug("TRICKLE(tank): Rejuv R" .. rank .. " on " .. UnitName(target))
                    else
                        -- Raid: cheap capped rank
                        rank = math.min(settings.TRICKLE_MAX_RANK,
                                        table.getn(SPELL_ID_LOOKUP["Rejuvenation"]))
                        Debug("TRICKLE: Rejuv R" .. rank .. " on " .. UnitName(target))
                    end
                    TargetUnit(target)
                    CastRejuvByRank(rank)
                    TargetLastTarget()
                    healBusy = false
                    return
                end
            end
        else
            Debug("TRICKLE skipped: mana=" .. math.floor(manaPercent) .. "% < floor")
        end

        -- ---- FIREHOSE PASS ----
        -- Spread Rejuv across anyone below REJUV_THRESHOLD without one.
        Debug("FIREHOSE PASS")
        local firehoseCandidates = {}
        for _, m in ipairs(allMembers) do
            if m.health < settings.REJUV_THRESHOLD
            and GetRejuvRank(m.unit) == 0 then
                table.insert(firehoseCandidates, m.unit)
            end
        end

        if table.getn(firehoseCandidates) > 0 then
            table.sort(firehoseCandidates, SortByEffectiveHealth)
            local target = firehoseCandidates[1]
            if IsUnitInRange(target, "Rejuvenation") then
                local rank = PickRejuvRank(target, false)
                TargetUnit(target)
                CastRejuvByRank(rank)
                TargetLastTarget()
                Debug("FIREHOSE: Rejuv R" .. rank .. " on " .. UnitName(target))
                healBusy = false
                return
            end
        end

        -- ---- SWIFTMEND PASS ----
        -- Fire Swiftmend on the lowest-health non-tank who is below REJUV_THRESHOLD
        -- and already has a HoT ticking. Runs here so Swiftmend is treated as a
        -- HoT-efficiency tool rather than an emergency heal. Tanks excluded.
        if (settings.SWIFTMEND_ENABLED ~= false) and not IsSwiftmendOnCooldown() then
            local smCandidates = {}
            for _, m in ipairs(allMembers) do
                if m.health < settings.REJUV_THRESHOLD
                and not IsTankLike(m.unit)
                and HasAnyHotForSwiftmend(m.unit)
                and IsUnitInRange(m.unit, "Swiftmend") then
                    table.insert(smCandidates, m.unit)
                end
            end
            if table.getn(smCandidates) > 0 then
                table.sort(smCandidates, SortByEffectiveHealth)
                local target   = smCandidates[1]
                local pressure = ComputeTankPressureScore(target)
                TargetUnit(target)
                CastSpellByName("Swiftmend")
                TargetLastTarget()
                Debug("SWIFTMEND on " .. UnitName(target) ..
                      string.format(" hp=%.0f%%", (UnitHealth(target)/UnitHealthMax(target))*100))
                LogHealAction(target, pressure, "SWIFTMEND", 1)
                healBusy = false
                return
            end
        end

        -- Nothing to do
        Debug("TRICKLE/FIREHOSE: all covered")
        healBusy = false
        if settings.FOLLOW_ENABLED then
            local followUnit = settings.FOLLOW_TARGET_UNIT
            if followUnit and UnitExists(followUnit) then
                FollowUnit(followUnit)
            elseif GetNumPartyMembers() > 0 then
                FollowUnit("party1")
            end
        end
        return
    end

    -- =========================================================
    -- ACTIVE HEALING (someone is below CRITICAL_THRESHOLD)
    --
    -- Decision tree per keypress:
    --   1. AoE blanket check — if uncovered players >= AOE_BLANKET_THRESHOLD,
    --      firehose Rejuv on highest-pressure uncovered unit.
    --      Exception: tanks always get Regrowth regardless of blanket mode.
    --   2. Single-target active — for highest-pressure candidate:
    --      a. Regrowth — tanks always; non-tanks only if pressure >= REGROWTH_NON_TANK_FLOOR
    --      b. Rejuv — fresh cast or upgrade
    -- =========================================================
    Debug("ACTIVE HEALING MODE")
    local healingDone = false

    -- Score every low-health member and sort highest pressure first
    local pressureCandidates = {}
    for _, unit in ipairs(lowMembers) do
        local pressure = ComputeTankPressureScore(unit)
        table.insert(pressureCandidates, { unit = unit, pressure = pressure })
    end
    table.sort(pressureCandidates, function(a, b) return a.pressure > b.pressure end)

    -- ---- Count uncovered players (no Rejuv, below threshold, in range) ----
    local uncoveredCount = 0
    local uncoveredUnits = {}
    for _, entry in ipairs(pressureCandidates) do
        if GetRejuvRank(entry.unit) == 0
        and IsUnitInRange(entry.unit, "Rejuvenation") then
            uncoveredCount = uncoveredCount + 1
            table.insert(uncoveredUnits, entry)
        end
    end

    local aoeThreshold  = settings.AOE_BLANKET_THRESHOLD or 3
    local rgFloor       = settings.REGROWTH_NON_TANK_FLOOR or 0.55
    local aoeMode       = uncoveredCount >= aoeThreshold

    Debug(string.format("uncovered=%d aoeThreshold=%d aoeMode=%s",
          uncoveredCount, aoeThreshold, tostring(aoeMode)))

    -- ---- Step 1: AoE blanket — firehose Rejuv when many are uncovered ----
    -- Tank-like units still get Regrowth even in AoE mode, but only if they
    -- don't already have a Regrowth HoT ticking — otherwise fall through to
    -- the Rejuv blanket immediately.
    if aoeMode then
        if table.getn(pressureCandidates) > 0 then
            local topEntry = pressureCandidates[1]
            local topUnit  = topEntry.unit
            local topPres  = topEntry.pressure
            if IsTankLike(topUnit) and GetRegrowthRank(topUnit) == 0
            and not isMoving and IsUnitInRange(topUnit, "Regrowth") then
                local rgRank = PickRegrowthRank(topPres)
                if rgRank > 0 then
                    TargetUnit(topUnit)
                    local cast = CastRegrowthSafe(topUnit, rgRank, topPres)
                    TargetLastTarget()
                    if cast then
                        Debug(string.format("AOE+TANK REGROWTH R%d on %s (pressure=%.2f)",
                              rgRank, UnitName(topUnit), topPres))
                        LogHealAction(topUnit, topPres, "REGROWTH", rgRank)
                        healBusy = false
                        return
                    end
                end
            end
        end

        -- Firehose: Rejuv on highest-pressure uncovered unit
        if table.getn(uncoveredUnits) > 0 then
            local target   = uncoveredUnits[1].unit
            local pressure = uncoveredUnits[1].pressure
            local rank     = PickRejuvRank(target, DetectClearcasting())
            TargetUnit(target)
            CastRejuvByRank(rank)
            TargetLastTarget()
            Debug(string.format("AOE BLANKET: Rejuv R%d on %s (pressure=%.2f uncovered=%d)",
                  rank, UnitName(target), pressure, uncoveredCount))
            LogHealAction(target, pressure, "REJUV_AOE", rank)
            healBusy = false
            return
        end
    end

    -- ---- Step 2: Single-target active healing ----
    -- QuickHeal avoidance: when ON, skip Regrowth on the lowest-pressure candidate
    -- so QuickHeal's direct heal lands there. Rejuv is unaffected.
    -- Waived when there is only one candidate.
    local qhAvoidUnit = nil
    if settings.QUICKHEAL_AVOID and table.getn(pressureCandidates) > 1 then
        qhAvoidUnit = pressureCandidates[table.getn(pressureCandidates)].unit
        Debug("QuickHeal avoid: deferring Regrowth on " .. (UnitName(qhAvoidUnit) or "?"))
    end

    for _, entry in ipairs(pressureCandidates) do
        local unit     = entry.unit
        local pressure = entry.pressure
        local name     = UnitName(unit)
        local hp       = (UnitHealth(unit) / UnitHealthMax(unit)) * 100
        local isTank   = IsTankLike(unit)

        if not IsUnitInRange(unit, "Rejuvenation") then
            Debug(name .. " out of range, skipping")
        else
            Debug(string.format("HEAL: %s hp=%.0f%% pressure=%.2f tank=%s",
                  name, hp, pressure, tostring(isTank)))

            -- Regrowth: tanks always; non-tanks only above REGROWTH_NON_TANK_FLOOR
            -- QuickHeal avoidance: skip Regrowth on lowest-pressure unit so their
            -- direct heal lands there. Rejuv still fires on them normally.
            local currentRejuvRank = GetRejuvRank(unit)
            local wantsRegrowth    = isTank or pressure >= rgFloor
            -- Skip Regrowth if no Rejuv yet and not urgent — lay Rejuv first
            local skipForRejuv     = (currentRejuvRank == 0 and not isTank and pressure < 0.70)
            local skipForQH        = (qhAvoidUnit == unit)
            local skipMoving       = isMoving  -- Regrowth has a cast time, suppress while moving

            if wantsRegrowth and not skipForRejuv and not skipForQH and not skipMoving
            and IsUnitInRange(unit, "Regrowth") then
                local rgRank = PickRegrowthRank(pressure)
                if rgRank > 0 then
                    TargetUnit(unit)
                    local cast = CastRegrowthSafe(unit, rgRank, pressure)
                    TargetLastTarget()
                    if cast then
                        Debug(string.format("REGROWTH R%d on %s (pressure=%.2f tank=%s)",
                              rgRank, name, pressure, tostring(isTank)))
                        LogHealAction(unit, pressure, "REGROWTH", rgRank)
                        healingDone = true
                        break
                    end
                end
            end

            -- Rejuv: fresh cast or upgrade
            if currentRejuvRank == 0 then
                local rank = PickRejuvRank(unit, DetectClearcasting())
                TargetUnit(unit)
                CastRejuvByRank(rank)
                TargetLastTarget()
                Debug("REJUV R" .. rank .. " on " .. name)
                LogHealAction(unit, pressure, "REJUV", rank)
                healingDone = true
                break
            else
                local upgradeRank = ShouldUpgradeRejuv(unit, currentRejuvRank)
                if upgradeRank > 0 then
                    TargetUnit(unit)
                    CastRejuvByRank(upgradeRank)
                    TargetLastTarget()
                    Debug("REJUV UPGRADE R" .. currentRejuvRank ..
                          "->R" .. upgradeRank .. " on " .. name)
                    LogHealAction(unit, pressure, "REJUV_UPGRADE",
                                  currentRejuvRank .. ">" .. upgradeRank)
                    healingDone = true
                    break
                end
            end
        end
    end

    healBusy = false

    if not healingDone then
        Debug("No healing action taken")
        if settings.FOLLOW_ENABLED then
            local followUnit = settings.FOLLOW_TARGET_UNIT
            if followUnit and UnitExists(followUnit) then
                FollowUnit(followUnit)
            elseif GetNumPartyMembers() > 0 then
                FollowUnit("party1")
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Buffing Logic (out of combat only)
-------------------------------------------------------------------------------

local function BuffPartyMembers()
    if UnitAffectingCombat("player") then
        Debug("In combat, skipping MOTW buffing")
        return
    end
    local mana = (UnitMana("player") / UnitManaMax("player")) * 100
    if mana < settings.MOTW_MANA_THRESHOLD then
        Print("Mana too low to buff (" .. math.floor(mana) .. "%)")
        return
    end

    local function CheckUnit(unit)
        if not UnitExists(unit) then return end
        if UnitIsDeadOrGhost(unit) then return end
        if not UnitIsConnected(unit) then return end
        if not IsUnitInRange(unit, "Mark of the Wild") then return end
        if not HasAnyDruidBuff(unit) then
            TargetUnit(unit)
            CastSpellByName("Mark of the Wild")
            TargetLastTarget()
            Debug("MOTW on " .. UnitName(unit))
            return true  -- signal: we acted
        end
    end

    -- Lua 5.0: no early-return from loop, use flag
    local done = false
    IterateHealableUnits(function(unit)
        if not done then
            if CheckUnit(unit) then done = true end
        end
    end)

    if not done then
        Debug("All members have druid buffs")
    end
end

-------------------------------------------------------------------------------
-- Debug Commands
-------------------------------------------------------------------------------

local function CheckBuffsCmd()
    Print("=== Player Buffs ===")
    for i = 1, 32 do
        local tex, _, id = UnitBuff("player", i)
        if not tex then break end
        local nm = SPELL_NAME_BY_ID[id] or "Unknown"
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  #%d id=%d name=%s", i, id or 0, nm))
    end
    Print("Tree form: " .. tostring(IsInTreeForm()))
    Print("Clearcasting: " .. tostring(DetectClearcasting()))
    Print("irMod=" .. irMod .. " gnMod=" .. gnMod .. " mgMod=" .. mgMod)
end

local function CheckAggroCmd()
    Print("=== Aggro Scores ===")
    local any = false
    for name, count in pairs(aggroCount) do
        local live = liveAggro[name] and " [LIVE]" or ""
        Print("  " .. name .. " = " .. count .. live)
        any = true
    end
    if not any then Print("  (none)") end
end

local function CheckRangeCmd(unit)
    if not unit or unit == "" then unit = "target" end
    if not UnitExists(unit) then
        Print("Unit does not exist: " .. tostring(unit))
        return
    end
    local nm = UnitName(unit)
    Print("=== Range for " .. nm .. " ===")
    for _, spell in ipairs({"Rejuvenation","Regrowth","Swiftmend","Mark of the Wild"}) do
        local r = IsSpellInRange(spell, unit)
        local s = r == 1 and "|cff00ff00IN|r" or r == 0 and "|cffff0000OUT|r" or "|cffffff00N/A|r"
        DEFAULT_CHAT_FRAME:AddMessage("  " .. spell .. ": " .. s)
    end
end

-------------------------------------------------------------------------------
-- Usage
-------------------------------------------------------------------------------

local function PrintUsage()
    Print("Commands:")
    Print("  /mcheal              - Heal party/raid")
    Print("  /mcbuff              - Cast Mark of the Wild on those missing it")
    Print("  /mctree              - Toggle auto Tree of Life Form")
    Print("  /mcfollow            - Toggle follow")
    Print("  /mcl                 - Set follow target to current target")
    Print("  /mcstatus            - Show healing power and Rejuv effective heals per rank")
    Print("  /mcdr                - Spell rank GUI (enable/disable individual Rejuv, Regrowth, Swiftmend)")
    Print("  /mcsettings          - Settings GUI (thresholds, Overheal Tanks, QuickHeal Avoidance)")
    Print("  /mctanks             - Priority tank list GUI")
    Print("  /mcaddtank [name]    - Add player to priority tank list (defaults to target)")
    Print("  /mcremovetank [name] - Remove player from priority tank list")
    Print("  /mccleartanks        - Clear the entire tank list")
    Print("  /mclisttanks         - Print current tank list")
    Print("  /mcqh                - Toggle QuickHeal avoidance")
    Print("  /mclog               - Toggle heal decision logging on/off")
    Print("  /mcexport            - Write log buffer to MooncallerLog.txt")
    Print("  /mclogclear          - Clear log buffer without writing")
    Print("  /mclogstat           - Show log buffer status")
    Print("  /mcrange [unit]      - Check spell ranges on unit (default: target)")
    Print("  /mccheckbuffs        - Show player buffs + talent modifiers")
    Print("  /mcbanzai            - Diagnose Banzai integration status")
    Print("  /mcpressure          - Show current pressure scores for all members")
    Print("  /mc                  - Show this help")
end

local MC_SLIDER_TOOLTIPS = {
    RgFloor      = { "Min pressure for non-tank units to receive Regrowth.", "Tanks always get Regrowth. Raise to be more selective." },
    AoeBlanket   = { "How many uncovered players trigger firehose mode.", "In firehose mode, Rejuvs are prioritised over Regrowth." },
    RejuvThresh  = { "HP% below which firehose/trickle Rejuvs are cast.", "Default 90 = anyone not at full health." },
    TrickleThresh= { "HP% below which trickle top-up Rejuvs are cast.", "Only runs when nobody is in active danger." },
    TrickleMana  = { "Min mana% required for trickle pass to run.", "Below this, trickle is skipped entirely." },
    TrickleRank  = { "Max Rejuv rank used during trickle pass.", "Tanks bypass this cap and use full rank selection." },
    CritThresh   = { "HP% below which active healing mode activates.", "Above this, only trickle/firehose runs." },
    MoTWMana     = { "Min mana% required to cast Mark of the Wild." },
    QHAvoid      = { "Skip Regrowth on the lowest-HP target so QuickHeal heals them.", "Rejuv casts on that target are unaffected. Waived if only one candidate." },
    SwiftExpiry  = { "Seconds remaining on Rejuv that triggers expiry-path Swiftmend.", "Fires on any keypress regardless of HP%. Set 0 to disable." },
}

local function MCMakeSlider(parent, sliderKey, name, yOffset, minVal, maxVal, step, fmt, getSetting, setSetting)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(1.0, 0.82, 0.0)
    lbl:SetText(name .. "  " .. string.format(fmt, getSetting()))

    -- Invisible button over label to catch mouseover for tooltip
    local tip = CreateFrame("Button", nil, parent)
    tip:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    tip:SetWidth(200)
    tip:SetHeight(14)
    tip:EnableMouse(true)
    local tipLines = MC_SLIDER_TOOLTIPS[sliderKey]
    if tipLines then
        tip:SetScript("OnEnter", function()
            GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(tipLines[1], 1, 1, 1)
            if tipLines[2] then
                GameTooltip:AddLine(tipLines[2], 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        tip:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    local s = CreateFrame("Slider", "MooncallerSlider"..sliderKey, parent,
                          "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset - 16)
    s:SetWidth(190)
    s:SetHeight(16)
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(step)
    s:SetValue(getSetting())

    local lo = _G[s:GetName().."Low"]
    local hi = _G[s:GetName().."High"]
    local tx = _G[s:GetName().."Text"]
    if lo then lo:SetText(string.format(fmt, minVal)) end
    if hi then hi:SetText(string.format(fmt, maxVal)) end
    if tx then tx:SetText("") end

    s:SetScript("OnValueChanged", function()
        local raw = s:GetValue()
        local v   = math.floor(raw / step + 0.5) * step
        setSetting(v)
        lbl:SetText(name .. "  " .. string.format(fmt, v))
    end)
end

local function MCMakeFrame(globalName, width, height)
    local f = CreateFrame("Frame", globalName, UIParent)
    f:SetWidth(width)
    f:SetHeight(height)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0.06, 0.06, 0.10, 0.85)
    return f
end

-------------------------------------------------------------------------------
-- Tank List Management
-------------------------------------------------------------------------------

-- Forward declaration: RefreshTankListPanel is assigned further below once the
-- GUI scroll child exists. TankListAdd/Remove/Clear call it safely because they
-- only execute at runtime (keypress/click), not at definition time.
local RefreshTankListPanel

local function TankListAdd(name)
    if not name or name == "" then return false end
    if tankList[name] then
        Print(name .. " is already in the tank list.")
        return false
    end
    tankList[name] = true
    if not MooncallerDB.TANK_LIST then MooncallerDB.TANK_LIST = {} end
    MooncallerDB.TANK_LIST[name] = true
    Print("Tank added: " .. name)
    RefreshTankListPanel()
    return true
end

local function TankListRemove(name)
    if not name or name == "" then return false end
    if not tankList[name] then
        Print(name .. " is not in the tank list.")
        return false
    end
    tankList[name] = nil
    if MooncallerDB.TANK_LIST then MooncallerDB.TANK_LIST[name] = nil end
    Print("Tank removed: " .. name)
    RefreshTankListPanel()
    return true
end

local function TankListClear()
    for k in pairs(tankList) do tankList[k] = nil end
    MooncallerDB.TANK_LIST = {}
    Print("Tank list cleared.")
    RefreshTankListPanel()
end

-------------------------------------------------------------------------------
-- GUI Windows
-- /mcdr       — Spell rank enable/disable
-- /mcsettings — All thresholds + behaviour toggles
-- /mctanks    — Priority tank list management
-------------------------------------------------------------------------------

local mcDrFrame       = nil
local mcSettingsFrame = nil
local mcTanksFrame    = nil

-- Shared helper: make a labelled checkbox
local function MCMakeCheckbox(parent, globalName, yOff, label, tooltip1, tooltip2,
                               getVal, setVal)
    local cb = CreateFrame("CheckButton", globalName, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOff)
    cb:SetWidth(20)
    cb:SetHeight(20)
    cb:SetChecked(getVal() and 1 or 0)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetTextColor(1.0, 0.82, 0.0)
    lbl:SetText(label)
    if tooltip1 then
        cb:SetScript("OnEnter", function()
            GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(tooltip1, 1, 1, 1)
            if tooltip2 then GameTooltip:AddLine(tooltip2, 0.8, 0.8, 0.8) end
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    cb:SetScript("OnClick", function()
        setVal(cb:GetChecked() == 1)
    end)
    return cb
end

-- ---- /mcdr: Spell rank enable/disable ----

local function BuildMCDRFrame()
    local rejuvMax   = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    local regrowthMax = table.getn(SPELL_ID_LOOKUP["Regrowth"])
    -- Height: title(20) + rejuv section label(16) + rejuvMax rows(18ea) +
    --         sep(8) + regrowth section label(16) + regrowthMax rows(18ea) +
    --         sep(8) + swiftmend row(20) + padding(16)
    local fh = 20 + 16 + rejuvMax*18 + 8 + 16 + regrowthMax*18 + 8 + 20 + 16
    local f = MCMakeFrame("MooncallerDRFrame", 200, fh)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("Mooncaller — Spell Ranks")
    title:SetTextColor(0.4, 0.8, 1.0)

    local y = -24

    -- Rejuvenation ranks
    local rjHdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rjHdr:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
    rjHdr:SetTextColor(0.6, 1.0, 0.6)
    rjHdr:SetText("Rejuvenation")
    y = y - 16
    for rank = 1, rejuvMax do
        local r = rank  -- capture
        MCMakeCheckbox(f, "MooncallerRejuvR"..r, y,
            "Rank " .. r,
            "Enable/disable Rejuvenation Rank " .. r,
            nil,
            function() return not disabledRejuvRanks[r] end,
            function(v)
                if v then
                    disabledRejuvRanks[r] = nil
                    if MooncallerDB.DISABLED_REJUV_RANKS then
                        MooncallerDB.DISABLED_REJUV_RANKS[r] = nil
                    end
                else
                    disabledRejuvRanks[r] = true
                    if not MooncallerDB.DISABLED_REJUV_RANKS then
                        MooncallerDB.DISABLED_REJUV_RANKS = {}
                    end
                    MooncallerDB.DISABLED_REJUV_RANKS[r] = true
                end
            end)
        y = y - 18
    end

    -- Separator
    y = y - 4
    local sep1 = f:CreateTexture(nil, "BACKGROUND")
    sep1:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, y)
    sep1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, y)
    sep1:SetHeight(1)
    sep1:SetTexture(0.4, 0.4, 0.4, 0.8)
    y = y - 8

    -- Regrowth ranks
    local rgHdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rgHdr:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
    rgHdr:SetTextColor(0.6, 1.0, 0.6)
    rgHdr:SetText("Regrowth")
    y = y - 16
    for rank = 1, regrowthMax do
        local r = rank
        MCMakeCheckbox(f, "MooncallerRgR"..r, y,
            "Rank " .. r,
            "Enable/disable Regrowth Rank " .. r,
            nil,
            function() return not disabledRegrowthRanks[r] end,
            function(v)
                if v then
                    disabledRegrowthRanks[r] = nil
                    if MooncallerDB.DISABLED_REGROWTH_RANKS then
                        MooncallerDB.DISABLED_REGROWTH_RANKS[r] = nil
                    end
                else
                    disabledRegrowthRanks[r] = true
                    if not MooncallerDB.DISABLED_REGROWTH_RANKS then
                        MooncallerDB.DISABLED_REGROWTH_RANKS = {}
                    end
                    MooncallerDB.DISABLED_REGROWTH_RANKS[r] = true
                end
            end)
        y = y - 18
    end

    -- Separator
    y = y - 4
    local sep2 = f:CreateTexture(nil, "BACKGROUND")
    sep2:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, y)
    sep2:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, y)
    sep2:SetHeight(1)
    sep2:SetTexture(0.4, 0.4, 0.4, 0.8)
    y = y - 8

    -- Swiftmend master toggle
    MCMakeCheckbox(f, "MooncallerSwiftmendCB", y,
        "Swiftmend",
        "Enable or disable all Swiftmend casts.",
        nil,
        function() return settings.SWIFTMEND_ENABLED ~= false end,
        function(v)
            settings.SWIFTMEND_ENABLED    = v
            MooncallerDB.SWIFTMEND_ENABLED = v
        end)

    f:Hide()
    mcDrFrame = f
    return f
end

-- ---- /mcsettings: thresholds + behaviour toggles ----

local function BuildMCSettingsFrame()
    local f = MCMakeFrame("MooncallerSettingsFrame", 240, 510)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("Mooncaller — Settings")
    title:SetTextColor(0.4, 0.8, 1.0)

    -- Thresholds
    MCMakeSlider(f, "RejuvThresh", "Rejuv threshold", -30, 0, 100, 1, "%d%%",
        function() return settings.REJUV_THRESHOLD or 90 end,
        function(v) settings.REJUV_THRESHOLD = v; MooncallerDB.REJUV_THRESHOLD = v end)

    MCMakeSlider(f, "TrickleThresh", "Trickle threshold", -76, 0, 100, 1, "%d%%",
        function() return settings.TRICKLE_THRESHOLD or 98 end,
        function(v) settings.TRICKLE_THRESHOLD = v; MooncallerDB.TRICKLE_THRESHOLD = v end)

    MCMakeSlider(f, "TrickleMana", "Trickle mana floor", -122, 0, 100, 5, "%d%%",
        function() return settings.TRICKLE_MANA_FLOOR or 40 end,
        function(v) settings.TRICKLE_MANA_FLOOR = v; MooncallerDB.TRICKLE_MANA_FLOOR = v end)

    MCMakeSlider(f, "TrickleRank", "Trickle max rank", -168, 1, 12, 1, "%d",
        function() return settings.TRICKLE_MAX_RANK or 3 end,
        function(v) settings.TRICKLE_MAX_RANK = v; MooncallerDB.TRICKLE_MAX_RANK = v end)

    MCMakeSlider(f, "CritThresh", "Active heal threshold", -214, 0, 100, 1, "%d%%",
        function() return settings.CRITICAL_THRESHOLD or 70 end,
        function(v) settings.CRITICAL_THRESHOLD = v; MooncallerDB.CRITICAL_THRESHOLD = v end)

    MCMakeSlider(f, "MoTWMana", "MoTW mana floor", -260, 0, 100, 5, "%d%%",
        function() return settings.MOTW_MANA_THRESHOLD or 50 end,
        function(v) settings.MOTW_MANA_THRESHOLD = v; MooncallerDB.MOTW_MANA_THRESHOLD = v end)

    MCMakeSlider(f, "RgFloor", "Regrowth floor", -306, 0, 1, 0.05, "%.2f",
        function() return settings.REGROWTH_NON_TANK_FLOOR or 0.55 end,
        function(v) settings.REGROWTH_NON_TANK_FLOOR = v; MooncallerDB.REGROWTH_NON_TANK_FLOOR = v end)

    MCMakeSlider(f, "AoeBlanket", "AoE blanket threshold", -352, 1, 15, 1, "%d",
        function() return settings.AOE_BLANKET_THRESHOLD or 3 end,
        function(v) settings.AOE_BLANKET_THRESHOLD = v; MooncallerDB.AOE_BLANKET_THRESHOLD = v end)

    MCMakeSlider(f, "SwiftExpiry", "Swiftmend expiry window", -398, 0, 10, 0.5, "%.1fs",
        function() return settings.SWIFTMEND_EXPIRY_WINDOW or 3.5 end,
        function(v) settings.SWIFTMEND_EXPIRY_WINDOW = v; MooncallerDB.SWIFTMEND_EXPIRY_WINDOW = v end)

    -- Checkboxes
    local cbY = -448
    local function nextCb() local y = cbY; cbY = cbY - 22; return y end

    MCMakeCheckbox(f, "MooncallerSettingsQH", nextCb(),
        "QuickHeal Avoidance",
        "Skip Regrowth on the lowest-HP target so QuickHeal heals them.",
        "Rejuv on that target is unaffected. Waived if only one candidate.",
        function() return settings.QUICKHEAL_AVOID end,
        function(v) settings.QUICKHEAL_AVOID = v; MooncallerDB.QUICKHEAL_AVOID = v end)

    MCMakeCheckbox(f, "MooncallerSettingsOH", nextCb(),
        "Overheal Tanks",
        "Always keep max Rejuv+Regrowth on listed tanks with live aggro.",
        "Fires before all other heal logic. Rejuv first, Regrowth next keypress.",
        function() return settings.OVERHEAL_TANKS end,
        function(v) settings.OVERHEAL_TANKS = v; MooncallerDB.OVERHEAL_TANKS = v end)

    f:Hide()
    mcSettingsFrame = f
    return f
end

-- ---- /mctanks: priority tank list ----

local tankListScrollChild = nil
local tankListRows        = {}

RefreshTankListPanel = function()
    if not tankListScrollChild then return end
    for _, row in ipairs(tankListRows) do
        row.btn:Hide()
        row.lbl:Hide()
    end
    local names = {}
    for name in pairs(tankList) do table.insert(names, name) end
    table.sort(names)
    local rowH = 18
    for i, name in ipairs(names) do
        local row = tankListRows[i]
        if not row then
            local btn = CreateFrame("Button", nil, tankListScrollChild)
            btn:SetWidth(14)
            btn:SetHeight(14)
            btn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
            btn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
            local lbl = tankListScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetTextColor(1, 1, 1)
            row = { btn = btn, lbl = lbl }
            tankListRows[i] = row
        end
        local yOff = -(i - 1) * rowH - 2
        row.btn:ClearAllPoints()
        row.btn:SetPoint("TOPLEFT", tankListScrollChild, "TOPLEFT", 2, yOff)
        row.btn:Show()
        local capturedName = name
        row.btn:SetScript("OnClick", function() TankListRemove(capturedName) end)
        row.lbl:ClearAllPoints()
        row.lbl:SetPoint("LEFT", row.btn, "RIGHT", 4, 0)
        row.lbl:SetText(name)
        row.lbl:Show()
    end
    local contentH = math.max(table.getn(names) * rowH + 4, 20)
    tankListScrollChild:SetHeight(contentH)
end

local function BuildMCTanksFrame()
    local f = MCMakeFrame("MooncallerTanksFrame", 220, 280)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("Mooncaller — Priority Tanks")
    title:SetTextColor(0.4, 0.8, 1.0)

    -- Add Target button
    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -26)
    addBtn:SetWidth(90)
    addBtn:SetHeight(20)
    addBtn:SetText("Add Target")
    addBtn:SetScript("OnClick", function()
        if UnitExists("target") and UnitIsPlayer("target") then
            TankListAdd(UnitName("target"))
        else
            Print("No valid player target selected.")
        end
    end)

    -- Clear All button
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -26)
    clearBtn:SetWidth(90)
    clearBtn:SetHeight(20)
    clearBtn:SetText("Clear All")
    clearBtn:SetScript("OnClick", function()
        TankListClear()
    end)

    -- Separator
    local sep = f:CreateTexture(nil, "BACKGROUND")
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -50)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -50)
    sep:SetHeight(1)
    sep:SetTexture(0.4, 0.4, 0.4, 0.8)

    -- Scroll list
    local clipFrame = CreateFrame("ScrollFrame", nil, f)
    clipFrame:SetPoint("TOPLEFT",     f, "TOPLEFT",     8, -54)
    clipFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)

    local scrollChild = CreateFrame("Frame", nil, clipFrame)
    scrollChild:SetWidth(204)
    scrollChild:SetHeight(20)
    clipFrame:SetScrollChild(scrollChild)

    tankListScrollChild = scrollChild
    RefreshTankListPanel()

    f:Hide()
    mcTanksFrame = f
    return f
end

-- Threshold Setters
-------------------------------------------------------------------------------

local function SetThreshold(name, display, percent)
    percent = tonumber(percent)
    if percent and percent >= 0 and percent <= 100 then
        settings[name] = percent
        MooncallerDB[name] = percent
        Print(display .. " threshold set to " .. percent .. "%")
    else
        Print("Invalid value. Use a number 0-100.")
    end
end

-------------------------------------------------------------------------------
-- Event Handling
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("VARIABLES_LOADED")          -- fires after all addons fully loaded
eventFrame:RegisterEvent("PLAYER_ALIVE")           -- fires after a rez and on login
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- combat start
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- combat end
eventFrame:RegisterEvent("SPELLCAST_STOP")
eventFrame:RegisterEvent("SPELLCAST_FAILED")
eventFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")   -- talent point spent

local function InitBanzai()
    if MooncallerEvents then return end  -- already initialised
    if not (AceLibrary and AceLibrary:HasInstance("Banzai-1.0")
                       and AceLibrary:HasInstance("AceEvent-2.0")) then
        Print("WARNING: Banzai-1.0 or AceEvent-2.0 not found. Aggro-based features disabled.")
        return
    end
    Banzai = AceLibrary("Banzai-1.0")
    MooncallerEvents = {
        Banzai_UnitGainedAggro = function(self, unitId)
            OnUnitGainedAggro(unitId)
        end,
        Banzai_UnitLostAggro = function(self, unitId)
            OnUnitLostAggro(unitId)
        end,
    }
    AceLibrary("AceEvent-2.0"):embed(MooncallerEvents)
    MooncallerEvents:RegisterEvent("Banzai_UnitGainedAggro", "Banzai_UnitGainedAggro")
    MooncallerEvents:RegisterEvent("Banzai_UnitLostAggro",   "Banzai_UnitLostAggro")
    Print("Banzai-1.0 integration active.")
end

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "Mooncaller" then
        -- Sync settings from SavedVariables
        for k, v in pairs(MooncallerDB) do settings[k] = v end
        -- Sync tank list
        if MooncallerDB.TANK_LIST then
            for name in pairs(MooncallerDB.TANK_LIST) do
                tankList[name] = true
            end
        end
        -- Sync spell rank disable tables
        if MooncallerDB.DISABLED_REJUV_RANKS then
            for rank in pairs(MooncallerDB.DISABLED_REJUV_RANKS) do
                disabledRejuvRanks[rank] = true
            end
        end
        if MooncallerDB.DISABLED_REGROWTH_RANKS then
            for rank in pairs(MooncallerDB.DISABLED_REGROWTH_RANKS) do
                disabledRegrowthRanks[rank] = true
            end
        end
        RefreshTalentModifiers()
        BuildMCDRFrame()
        BuildMCSettingsFrame()
        BuildMCTanksFrame()
        Print("Loaded. Type /mc for help.")

    elseif event == "VARIABLES_LOADED" then
        -- All addons are fully loaded and registered with AceLibrary by now
        InitBanzai()

    elseif event == "PLAYER_ALIVE" then
        RefreshTalentModifiers()

    elseif event == "LEARNED_SPELL_IN_TAB" then
        RefreshTalentModifiers()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        ManageTreeForm()

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        -- Clear live aggro, aggro history, and pending reactive flags when combat ends
        for k in pairs(liveAggro)  do liveAggro[k]  = nil end
        for k in pairs(aggroCount) do aggroCount[k] = nil end
        for k in pairs(pendingReactiveRejuv) do pendingReactiveRejuv[k] = nil end
        healBusy = false
        ManageTreeForm()
        -- Auto-flush log at end of combat if logging is active and buffer has entries
        if logBuffer and table.getn(logBuffer) > 0 then
            FlushLog()
        end

    elseif event == "SPELLCAST_STOP" or event == "SPELLCAST_FAILED" then
        healBusy = false
    end
end)

-------------------------------------------------------------------------------
-- Slash Commands
-------------------------------------------------------------------------------

-- Main heal
SLASH_MCHEAL1 = "/mcheal"
SlashCmdList["MCHEAL"] = HealPartyMembers

-- Buff
SLASH_MCBUFF1 = "/mcbuff"
SlashCmdList["MCBUFF"] = BuffPartyMembers

-- Tree of Life toggle
SLASH_MCTREE1 = "/mctree"
SlashCmdList["MCTREE"] = function()
    settings.AUTO_TREE_FORM = not settings.AUTO_TREE_FORM
    MooncallerDB.AUTO_TREE_FORM = settings.AUTO_TREE_FORM
    Print("Auto Tree of Life Form: " .. (settings.AUTO_TREE_FORM and "ON" or "OFF"))
end

-- Thresholds
SLASH_MCREJUV1 = "/mcrejuv"
SlashCmdList["MCREJUV"] = function(a)
    SetThreshold("REJUV_THRESHOLD", "Rejuvenation firehose/trickle", a)
end

SLASH_MCMANA1 = "/mcmana"
SlashCmdList["MCMANA"] = function(a)
    SetThreshold("MOTW_MANA_THRESHOLD", "MOTW mana", a)
end

SLASH_MCTRICKLE1 = "/mctrickle"
SlashCmdList["MCTRICKLE"] = function(a)
    SetThreshold("TRICKLE_THRESHOLD", "Trickle top-up", a)
end

SLASH_MCTRICKLERANK1 = "/mctricklerank"
SlashCmdList["MCTRICKLERANK"] = function(a)
    local n = tonumber(a)
    local maxRank = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    if n and n >= 1 and n <= maxRank then
        settings.TRICKLE_MAX_RANK    = n
        MooncallerDB.TRICKLE_MAX_RANK = n
        Print("Trickle max rank set to " .. n)
    else
        Print("Invalid rank. Use 1-" .. maxRank)
    end
end

SLASH_MCTRICKLEMANA1 = "/mctricklemana"
SlashCmdList["MCTRICKLEMANA"] = function(a)
    SetThreshold("TRICKLE_MANA_FLOOR", "Trickle mana floor", a)
end

-- Logging
SLASH_MCLOG1 = "/mclog"
SlashCmdList["MCLOG"] = ToggleLogging

SLASH_MCEXPORT1 = "/mcexport"
SlashCmdList["MCEXPORT"] = FlushLog

SLASH_MCLOGCLEAR1 = "/mclogclear"
SlashCmdList["MCLOGCLEAR"] = function()
    if not logBuffer then
        Print("Logging is not active.")
        return
    end
    logBuffer     = {}
    logEntryCount = 0
    Print("Log buffer cleared.")
end

SLASH_MCLOGSTAT1 = "/mclogstat"
SlashCmdList["MCLOGSTAT"] = function()
    if not logBuffer then
        Print("Logging is OFF. Use /mclog to start.")
    else
        Print(string.format("Logging is ON. Buffer: %d/%d entries (total this session: %d).",
              table.getn(logBuffer), LOG_MAX_ENTRIES, logEntryCount))
    end
end

-- Follow
SLASH_MCFOLLOW1 = "/mcfollow"
SlashCmdList["MCFOLLOW"] = function()
    settings.FOLLOW_ENABLED = not settings.FOLLOW_ENABLED
    MooncallerDB.FOLLOW_ENABLED = settings.FOLLOW_ENABLED
    Print("Follow: " .. (settings.FOLLOW_ENABLED and "ON" or "OFF"))
end

SLASH_MCL1 = "/mcl"
SlashCmdList["MCL"] = function()
    if not UnitExists("target") or not UnitIsPlayer("target") then
        Print("No valid player target selected.")
        return
    end
    local targetGUID = UnitGUID("target")
    local found = nil
    -- Resolve target to a stable unitid via GUID matching
    local function checkUnit(uid)
        if UnitExists(uid) and UnitGUID(uid) == targetGUID then
            found = uid
        end
    end
    checkUnit("player")
    for i = 1, GetNumPartyMembers() do checkUnit("party"..i) end
    for i = 1, GetNumRaidMembers()  do checkUnit("raid"..i)  end
    if found then
        settings.FOLLOW_TARGET_UNIT    = found
        settings.FOLLOW_TARGET_NAME    = UnitName("target")
        MooncallerDB.FOLLOW_TARGET_UNIT = found
        MooncallerDB.FOLLOW_TARGET_NAME = UnitName("target")
        Print("Follow target set to " .. UnitName("target") .. " (" .. found .. ")")
    else
        Print("Could not resolve target to a party/raid unitid.")
    end
end

-- Spell rank enable/disable GUI
SLASH_MCDR1 = "/mcdr"
SlashCmdList["MCDR"] = function()
    if not mcDrFrame then BuildMCDRFrame() end
    if mcDrFrame:IsShown() then mcDrFrame:Hide() else mcDrFrame:Show() end
end

-- Settings GUI
SLASH_MCSETTINGS1 = "/mcsettings"
SlashCmdList["MCSETTINGS"] = function()
    if not mcSettingsFrame then BuildMCSettingsFrame() end
    if mcSettingsFrame:IsShown() then mcSettingsFrame:Hide() else mcSettingsFrame:Show() end
end

-- Tank list GUI
SLASH_MCTANKS1 = "/mctanks"
SlashCmdList["MCTANKS"] = function()
    if not mcTanksFrame then BuildMCTanksFrame() end
    if mcTanksFrame:IsShown() then mcTanksFrame:Hide() else mcTanksFrame:Show() end
end

-- QuickHeal avoidance toggle
SLASH_MCQH1 = "/mcqh"
SlashCmdList["MCQH"] = function()
    settings.QUICKHEAL_AVOID     = not settings.QUICKHEAL_AVOID
    MooncallerDB.QUICKHEAL_AVOID  = settings.QUICKHEAL_AVOID
    Print("QuickHeal avoidance: " .. (settings.QUICKHEAL_AVOID and "ON" or "OFF"))
end

-- Tank list management
SLASH_MCADDTANK1 = "/mcaddtank"
SlashCmdList["MCADDTANK"] = function(a)
    local name = (a and a ~= "") and a or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
    if name then
        TankListAdd(name)
    else
        Print("Usage: /mcaddtank [name]  (or target a player)")
    end
end

SLASH_MCREMOVETANK1 = "/mcremovetank"
SlashCmdList["MCREMOVETANK"] = function(a)
    local name = (a and a ~= "") and a or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
    if name then
        TankListRemove(name)
    else
        Print("Usage: /mcremovetank [name]  (or target a player)")
    end
end

SLASH_MCCLEARTANKS1 = "/mccleartanks"
SlashCmdList["MCCLEARTANKS"] = function()
    TankListClear()
end

SLASH_MCLISTTANKS1 = "/mclisttanks"
SlashCmdList["MCLISTTANKS"] = function()
    local names = {}
    for name in pairs(tankList) do table.insert(names, name) end
    if table.getn(names) == 0 then
        Print("Tank list is empty.")
    else
        table.sort(names)
        Print("Priority tanks: " .. table.concat(names, ", "))
    end
end

-- Debug
SLASH_MCDEBUG1 = "/mcdebug"
SlashCmdList["MCDEBUG"] = function()
    settings.DEBUG_MODE    = not settings.DEBUG_MODE
    MooncallerDB.DEBUG_MODE = settings.DEBUG_MODE
    Print("Debug mode: " .. (settings.DEBUG_MODE and "ON" or "OFF"))
end

-- Diagnostic commands
SLASH_MCRANGE1 = "/mcrange"
SlashCmdList["MCRANGE"] = CheckRangeCmd

SLASH_MCCHECKBUFFS1 = "/mccheckbuffs"
SlashCmdList["MCCHECKBUFFS"] = CheckBuffsCmd

SLASH_MCAGGRO1 = "/mcaggro"
SlashCmdList["MCAGGRO"] = CheckAggroCmd

SLASH_MCPRESSURE1 = "/mcpressure"
SlashCmdList["MCPRESSURE"] = function()
    Print("=== Pressure Scores ===")
    IterateHealableUnits(function(unit)
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            local name     = UnitName(unit)
            local hp       = (UnitHealth(unit) / UnitHealthMax(unit)) * 100
            local pressure = ComputeTankPressureScore(unit)
            local rejuv    = GetRejuvRank(unit)
            local rg       = GetRegrowthRank(unit)
            local tankStr  = IsTankLike(unit) and " [TANK]" or ""
            Print(string.format("  %s hp=%.0f%% p=%.2f rejuv=R%d rg=R%d%s",
                  name, hp, pressure, rejuv, rg, tankStr))
        end
    end)
end

SLASH_MCBANZAI1 = "/mcbanzai"
SlashCmdList["MCBANZAI"] = function()
    Print("=== Banzai Diagnostic ===")

    -- 1. AceLibrary availability
    if not AceLibrary then
        Print("  AceLibrary: NOT FOUND")
        return
    end
    Print("  AceLibrary: ok")
    Print("  Banzai-1.0 instance: " .. tostring(AceLibrary:HasInstance("Banzai-1.0")))
    Print("  AceEvent-2.0 instance: " .. tostring(AceLibrary:HasInstance("AceEvent-2.0")))

    -- 2. Our registration stub
    if not MooncallerEvents then
        Print("  MooncallerEvents: NIL (registration never ran)")
    else
        Print("  MooncallerEvents: exists")
        Print("  RegisterEvent method: " .. tostring(type(MooncallerEvents.RegisterEvent)))
        Print("  GainedAggro handler: " .. tostring(type(MooncallerEvents.Banzai_UnitGainedAggro)))
    end

    -- 3. Banzai live aggro poll — what does Banzai think right now?
    if not Banzai then
        Print("  Banzai object: NIL")
    else
        Print("  Banzai object: exists")
        local found = false
        local units = {"player", "party1", "party2", "party3", "party4"}
        for i = 1, GetNumRaidMembers() do
            table.insert(units, "raid" .. i)
        end
        for _, uid in ipairs(units) do
            if UnitExists(uid) then
                local hasAggro = Banzai:GetUnitAggroByUnitId(uid)
                if hasAggro then
                    Print("  Banzai aggro: " .. UnitName(uid) .. " (" .. uid .. ")")
                    found = true
                end
            end
        end
        if not found then Print("  Banzai aggro: none detected") end
    end

    -- 4. Our internal tables
    local liveCount = 0
    for _ in pairs(liveAggro) do liveCount = liveCount + 1 end
    local scoreCount = 0
    for _ in pairs(aggroCount) do scoreCount = scoreCount + 1 end
    Print("  liveAggro entries: " .. liveCount)
    Print("  aggroCount entries: " .. scoreCount)
end

-- Status
SLASH_MCSTATUS1 = "/mcstatus"
SlashCmdList["MCSTATUS"] = function()
    local hp = GetEffectiveHealingPower()
    Print("=== Healing Power ===")
    Print(string.format("  +Damage & healing: %d", healCache.damage_and_healing))
    Print(string.format("  +Healing only:     %d", healCache.healing_only))
    Print(string.format("  Total:             %d", hp))
    Print("=== Rejuv effective heals (with talents) ===")
    local maxRank = table.getn(SPELL_ID_LOOKUP["Rejuvenation"])
    for rank = 1, maxRank do
        local base = REJUV_RANK_HEAL[rank] or 0
        local eff  = (base + hp * REJUV_HEAL_COEFF) * irMod * gnMod
        Print(string.format("  R%02d: base=%4d  effective=%.0f  mana=%d",
              rank, base, eff, math.floor((REJUV_RANK_MANA[rank] or 0) * mgMod)))
    end
end

-- Help
SLASH_MC1 = "/mc"
SLASH_MC2 = "/mooncaller"
SlashCmdList["MC"] = PrintUsage