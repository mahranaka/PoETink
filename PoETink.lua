local ADDON_NAME = "PoETink"
local SOUND_PATH = "Interface\\AddOns\\PoETink\\tink.ogg"
local CALLER_ID = "PoETink"

local defaults = {
    thresholdGold = 5,     -- Default: 5 gold
    useAuctionator = true, -- Check Auctionator AH prices if available
    useVendor = true,      -- Check raw vendor sell value
    soundStack = 2,        -- How many times to layer the sound simultaneously (1-10)
    triggerTimestamps = {},-- Saved Unix timestamps of all real tinks
}

local sessionStart = GetTime()
local sessionTinks = 0

local function InitDB()
    if type(PoETinkDB) ~= "table" then
        PoETinkDB = {}
    end
    for k, v in pairs(defaults) do
        if PoETinkDB[k] == nil then
            if type(v) == "table" then
                PoETinkDB[k] = {}
            else
                PoETinkDB[k] = v
            end
        end
    end
end

local function GetThresholdCopper()
    return (PoETinkDB.thresholdGold or 5) * 10000
end

local function RecordTink()
    sessionTinks = sessionTinks + 1
    table.insert(PoETinkDB.triggerTimestamps, time())
end

-- countTrigger = true for actual drops/quests; false/nil for manual previews
local function PlayTink(countTrigger)
    local count = math.max(1, math.min(10, math.floor(PoETinkDB.soundStack or 2)))
    for _ = 1, count do
        PlaySoundFile(SOUND_PATH, "Master")
    end
    if countTrigger then
        RecordTink()
    end
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%dh %dm %ds", hours, mins, secs)
    elseif mins > 0 then
        return string.format("%dm %ds", mins, secs)
    else
        return string.format("%ds", secs)
    end
end

local function PrintStats()
    local now = time()
    local lastHourCount = 0
    local totalSaved = #PoETinkDB.triggerTimestamps

    for i = totalSaved, 1, -1 do
        if (now - PoETinkDB.triggerTimestamps[i]) <= 3600 then
            lastHourCount = lastHourCount + 1
        else
            break -- Timestamps are chronological, so we can stop early
        end
    end

    local sessionElapsed = math.max(1, GetTime() - sessionStart)
    local sessionPerHour = (sessionTinks / sessionElapsed) * 3600

    print("|cff00ff00[PoETink]|r Trigger Statistics:")
    print(string.format("  Last 60 minutes (rolling): |cffffd100%d tinks|r", lastHourCount))
    print(string.format("  Current session: |cffffd100%d tinks|r in %s (|cffffd100%.1f / hour|r)",
        sessionTinks,
        FormatDuration(sessionElapsed),
        sessionPerHour
    ))
    print(string.format("  All-time recorded: |cffffd100%d tinks|r", totalSaved))
end

local function GetItemInfoCompat(itemLink)
    if C_Item and C_Item.GetItemInfo then
        return C_Item.GetItemInfo(itemLink)
    end
    return GetItemInfo(itemLink)
end

-- Returns the highest known unit value (in copper) between Vendor and Auctionator
local function GetUnitValueCopper(itemLink)
    if not itemLink then return 0 end

    local bestPrice = 0

    -- 1. Vendor sell price (works standalone with zero dependencies)
    if PoETinkDB.useVendor then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfoCompat(itemLink)
        if sellPrice and sellPrice > bestPrice then
            bestPrice = sellPrice
        end
    end

    -- 2. Auctionator AH price (optional, used if installed & scanned)
    if PoETinkDB.useAuctionator
        and Auctionator
        and Auctionator.API
        and Auctionator.API.v1
        and Auctionator.API.v1.GetAuctionPriceByItemLink then
        local ok, ahPrice = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, CALLER_ID, itemLink)
        if ok and ahPrice and ahPrice > bestPrice then
            bestPrice = ahPrice
        end
    end

    return bestPrice
end

local function CheckAndTink(itemLink, quantity)
    if not itemLink then return false end
    local thresholdCopper = GetThresholdCopper()
    if thresholdCopper <= 0 then return false end

    local count = (quantity and quantity > 0) and quantity or 1
    local totalCopper = GetUnitValueCopper(itemLink) * count

    if totalCopper >= thresholdCopper then
        PlayTink(true)
        return true
    end
    return false
end

-- Helper for uncached items: requests item data from server and re-evaluates once ready
local pendingItems = {}
local function EvaluateItem(itemLink, quantity)
    if not itemLink then return end
    local name = GetItemInfoCompat(itemLink)
    if name then
        CheckAndTink(itemLink, quantity)
    else
        local itemID = tonumber(itemLink:match("item:(%d+)"))
        if itemID then
            pendingItems[itemID] = { link = itemLink, count = quantity or 1 }
            if C_Item and C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(itemID)
            end
        end
    end
end

-- Scan all loot slots when a corpse/chest opens
local function ScanLootWindow()
    local numItems = GetNumLootItems()
    local tinked = false
    for slot = 1, numItems do
        local link = GetLootSlotLink(slot)
        if link then
            local _, _, quantity = GetLootSlotInfo(slot)
            if CheckAndTink(link, quantity) then
                tinked = true
                break -- One tink per loot window even if multiple valuable items drop
            end
        end
    end
    -- Queue any uncached items if nothing tinked yet
    if not tinked then
        for slot = 1, numItems do
            local link = GetLootSlotLink(slot)
            if link and not GetItemInfoCompat(link) then
                local _, _, quantity = GetLootSlotInfo(slot)
                EvaluateItem(link, quantity)
            end
        end
    end
end

-- Scan quest raw gold and item rewards when viewing quest offer or turn-in screen
local function ScanQuestRewards()
    local thresholdCopper = GetThresholdCopper()
    if thresholdCopper <= 0 then return end

    -- 1. Check raw quest gold reward (GetRewardMoney returns copper)
    local rewardMoney = GetRewardMoney and GetRewardMoney() or 0
    if rewardMoney >= thresholdCopper then
        PlayTink(true)
        return
    end

    -- 2. Check selectable quest item rewards
    local numChoices = GetNumQuestChoices() or 0
    for i = 1, numChoices do
        local link = GetQuestItemLink("choice", i)
        if link then
            local _, _, quantity = GetQuestItemInfo("choice", i)
            if CheckAndTink(link, quantity) then
                return
            elseif not GetItemInfoCompat(link) then
                EvaluateItem(link, quantity)
            end
        end
    end

    -- 3. Check guaranteed quest item rewards
    local numRewards = GetNumQuestRewards() or 0
    for i = 1, numRewards do
        local link = GetQuestItemLink("reward", i)
        if link then
            local _, _, quantity = GetQuestItemInfo("reward", i)
            if CheckAndTink(link, quantity) then
                return
            elseif not GetItemInfoCompat(link) then
                EvaluateItem(link, quantity)
            end
        end
    end
end

-- Event Frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
    elseif event == "LOOT_OPENED" then
        ScanLootWindow()
    elseif event == "QUEST_COMPLETE" or event == "QUEST_DETAIL" then
        ScanQuestRewards()
    elseif event == "GET_ITEM_INFO_RECEIVED" and arg2 then
        local pending = pendingItems[arg1]
        if pending then
            pendingItems[arg1] = nil
            CheckAndTink(pending.link, pending.count)
        end
    end
end)

-- Slash Commands: /tink
SLASH_POETINK1 = "/tink"
SlashCmdList["POETINK"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    local num = tonumber(cmd)
    if num and num >= 0 then
        PoETinkDB.thresholdGold = num
        print(string.format("|cff00ff00[PoETink]|r Threshold set to |cffffd100%g gold|r.", num))
    elseif cmd == "stats" or cmd == "rate" then
        PrintStats()
    elseif cmd == "reset" then
        sessionTinks = 0
        sessionStart = GetTime()
        PoETinkDB.triggerTimestamps = {}
        print("|cff00ff00[PoETink]|r Trigger history and session stats reset.")
    elseif cmd == "stack" or cmd == "vol" then
        local stackNum = tonumber(arg)
        if stackNum and stackNum >= 1 and stackNum <= 10 then
            PoETinkDB.soundStack = math.floor(stackNum)
            print(string.format("|cff00ff00[PoETink]|r Sound stack set to |cffffd100%dx|r.", PoETinkDB.soundStack))
            PlayTink(false)
        else
            print("|cff00ff00[PoETink]|r Usage: |cffffd100/tink stack <1-10>|r (currently |cffffd100" .. PoETinkDB.soundStack .. "x|r)")
        end
    elseif cmd == "ah" then
        PoETinkDB.useAuctionator = not PoETinkDB.useAuctionator
        print("|cff00ff00[PoETink]|r Auctionator prices: " .. (PoETinkDB.useAuctionator and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
    elseif cmd == "vendor" then
        PoETinkDB.useVendor = not PoETinkDB.useVendor
        print("|cff00ff00[PoETink]|r Vendor prices: " .. (PoETinkDB.useVendor and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
    elseif cmd == "test" then
        PlayTink(false)
        print(string.format("|cff00ff00[PoETink]|r Playing test sound (%dx).", PoETinkDB.soundStack))
    else
        print(string.format("|cff00ff00[PoETink]|r Threshold: |cffffd100%g gold|r | Stack: |cffffd100%dx|r | AH: %s | Vendor: %s",
            PoETinkDB.thresholdGold,
            PoETinkDB.soundStack,
            PoETinkDB.useAuctionator and "ON" or "OFF",
            PoETinkDB.useVendor and "ON" or "OFF"
        ))
        print("  |cffffd100/tink <gold>|r - Set gold threshold (e.g. /tink 0.5)")
        print("  |cffffd100/tink stats|r - Show tinks in the last hour & session rate")
        print("  |cffffd100/tink reset|r - Reset trigger counter & session timer")
        print("  |cffffd100/tink stack <1-10>|r - Set simultaneous sound layers (e.g. /tink stack 3)")
        print("  |cffffd100/tink ah|r - Toggle Auctionator price checking")
        print("  |cffffd100/tink vendor|r - Toggle vendor price checking")
        print("  |cffffd100/tink test|r - Play the tink sound now")
    end
end