local ADDON = ...

local DEFAULTS = {
    sellJunk = true,     -- sell grey items at every vendor
    sellListOn = true,   -- sell the items on your sell list
    autoRepair = true,
    repairLimit = 0,     -- gold; 0 means no limit
    restockOn = true,
    showCounts = true,   -- "in bags" count on vendor items
    showKnown = true,    -- mark recipes and items you already know
    quiet = false,
}

local db
local merchantOpen, visit = false, 0

local function Print(msg)
    if not db.quiet then
        print("|cff33ff99Better|rErrands: " .. msg)
    end
end

-- Features another addon already does, so we don't do them twice. Told once per session.
local OTHER_ADDONS = {
    sellJunk = { addon = "Leatrix_Plus", title = "Leatrix Plus", vars = "LeaPlusDB", key = "AutoSellJunk" },
    autoRepair = { addon = "Leatrix_Plus", title = "Leatrix Plus", vars = "LeaPlusDB", key = "AutoRepairGear" },
}
local told = {}

local function HandledElsewhere(feature, what)
    local other = OTHER_ADDONS[feature]
    local vars = C_AddOns.IsAddOnLoaded(other.addon) and _G[other.vars]
    if not (vars and vars[other.key] == "On") then return false end
    if not told[feature] then
        told[feature] = true
        Print(other.title .. " is " .. what .. ", so BetterErrands won't")
    end
    return true
end

local function Link(itemID)
    return select(2, C_Item.GetItemInfo(itemID)) or ("item:" .. itemID)
end

---------------------------------------------------------------------------
-- Repair
---------------------------------------------------------------------------
local function Repair()
    if not db.autoRepair or not CanMerchantRepair() then return end
    if HandledElsewhere("autoRepair", "repairing") then return end
    local cost, canRepair = GetRepairAllCost()
    if not canRepair or cost == 0 then return end
    if db.repairLimit > 0 and cost > db.repairLimit * 10000 then
        Print("repair costs " .. GetMoneyString(cost) .. ", above your limit; not repaired")
        return
    end
    if GetMoney() < cost then
        Print("not enough money to repair (" .. GetMoneyString(cost) .. ")")
        return
    end
    RepairAllItems()
    Print("repaired for " .. GetMoneyString(cost))
end

---------------------------------------------------------------------------
-- Selling: junk and the sell list, a few items per step so the server keeps up
---------------------------------------------------------------------------
local BUYBACK_SLOTS = 12
local function Sell()
    local sellJunk = db.sellJunk and not HandledElsewhere("sellJunk", "selling junk")
    local queue, listed = {}, {}
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and not info.isLocked and not info.hasNoValue then
                local junk = sellJunk and info.quality == Enum.ItemQuality.Poor
                local onList = db.sellListOn and db.sellList[info.itemID]
                if junk or onList then
                    local price = select(11, C_Item.GetItemInfo(info.itemID)) or 0
                    local entry = { bag = bag, slot = slot, itemID = info.itemID, value = price * info.stackCount }
                    if junk then queue[#queue + 1] = entry else listed[#listed + 1] = entry end
                end
            end
        end
    end
    -- Junk goes first and the sell list is capped at one Buyback's worth, so every
    -- stack sold from the list can still be bought back after the visit.
    for i = 1, math.min(#listed, BUYBACK_SLOTS) do queue[#queue + 1] = listed[i] end
    local kept = #listed - BUYBACK_SLOTS
    if kept > 0 then
        Print(("%d sell list stack%s kept for the next vendor, so everything sold fits in Buyback"):format(
            kept, kept == 1 and "" or "s"))
    end
    if #queue == 0 then return end
    local thisVisit, pos, sold, total = visit, 1, 0, 0
    local function Step()
        if not merchantOpen or visit ~= thisVisit then return end
        for _ = 1, 8 do
            local q = queue[pos]
            if not q then
                if sold > 0 then
                    Print(("sold %d item%s for %s"):format(sold, sold == 1 and "" or "s", GetMoneyString(total)))
                end
                return
            end
            pos = pos + 1
            local info = C_Container.GetContainerItemInfo(q.bag, q.slot)
            if info and info.itemID == q.itemID and not info.isLocked then
                C_Container.UseContainerItem(q.bag, q.slot)
                sold, total = sold + 1, total + q.value
            end
        end
        C_Timer.After(0.2, Step)
    end
    Step()
end

---------------------------------------------------------------------------
-- Restock: buy up to the amount set per item
---------------------------------------------------------------------------
-- Purchases are confirmed by the server later, so money and counts are tracked here, not re-read.
local function Restock()
    if not db.restockOn or not next(db.restock) then return end
    local money = GetMoney()
    for i = 1, GetMerchantNumItems() do
        local itemID = GetMerchantItemID(i)
        local want = itemID and db.restock[itemID]
        if want then
            local need = want - C_Item.GetItemCount(itemID)
            local info = C_MerchantFrame.GetItemInfo(i)
            local price, batch, available = info.price, info.stackCount, info.numAvailable
            local maxStack = math.max(1, GetMerchantItemMaxStack(i) or 1)
            local bought = 0
            while need > 0 and available ~= 0 do
                local n = batch > 1 and batch or math.min(need, maxStack)
                local cost = batch > 1 and price or price * n
                if money < cost then
                    Print("not enough money to restock " .. Link(itemID))
                    break
                end
                if batch > 1 then BuyMerchantItem(i) else BuyMerchantItem(i, n) end
                money, need, bought = money - cost, need - n, bought + n
                if available > 0 then available = available - 1 end
            end
            if bought > 0 then
                Print(("restocked %d x %s"):format(bought, Link(itemID)))
            end
        end
    end
end

---------------------------------------------------------------------------
-- Vendor window: bag counts, known marks and search
---------------------------------------------------------------------------
local search = ""
local slots = {}

-- Only recipes, mounts and pets can be "Already known", so nothing else gets a tooltip scan,
-- and a known item stays known for the rest of the visit.
local SCANNABLE = { [Enum.ItemClass.Recipe] = true, [Enum.ItemClass.Miscellaneous] = true }
local GetMerchantItemTooltip = C_TooltipInfo and C_TooltipInfo.GetMerchantItem
local known = {}

local function IsKnown(index, itemID)
    if known[itemID] then return true end
    local classID = select(6, C_Item.GetItemInfoInstant(itemID))
    if not (SCANNABLE[classID] and GetMerchantItemTooltip) then return false end
    local data = GetMerchantItemTooltip(index)
    for _, line in ipairs(data and data.lines or {}) do
        if line.leftText == ITEM_SPELL_KNOWN then
            known[itemID] = true
            return true
        end
    end
    return false
end

local function Matches(index)
    local info = C_MerchantFrame.GetItemInfo(index)
    local name = info and info.name
    return name and name:lower():find(search, 1, true) ~= nil
end

-- Puts vendor item `index` in slot `slot`, the way Blizzard's MerchantFrame_UpdateMerchantInfo does.
-- Buying, tooltips and links read the button's ID, so they follow the item.
local function FillSlot(s, index)
    if not index then
        s.frame:Hide()
        return
    end
    local info = C_MerchantFrame.GetItemInfo(index)
    local button = s.button
    s.name:SetText(info.name)
    SetItemButtonCount(button, info.stackCount)
    SetItemButtonStock(button, info.numAvailable)
    SetItemButtonTexture(button, info.texture)
    if info.price > 0 then
        MoneyFrame_Update(s.money:GetName(), info.price)
        s.money:Show()
    else
        s.money:Hide()
    end
    if info.hasExtendedCost then
        MerchantFrame_UpdateAltCurrency(index, s.index, true)
    else
        s.altCurrency:Hide()
    end
    local r, g, b = 1, 1, 1
    if not info.isUsable then r, g, b = 0.9, 0, 0 end
    SetItemButtonTextureVertexColor(button, r, g, b)
    SetItemButtonSlotVertexColor(s.frame, r, g, b)
    SetItemButtonNameFrameVertexColor(s.frame, info.isUsable and 0.5 or 0.9, info.isUsable and 0.5 or 0, info.isUsable and 0.5 or 0)
    button:SetID(index)
    button.link = GetMerchantItemLink(index)
    button.name, button.texture = info.name, info.texture
    button.price, button.extendedCost = info.price, info.hasExtendedCost
    button.hasItem = true
    button:Show()
    s.frame:Show()
end

-- While searching, the slots show only matches from every page, and the pager counts matches.
local function ShowMatches()
    local matches = {}
    for index = 1, GetMerchantNumItems() do
        if Matches(index) then matches[#matches + 1] = index end
    end
    local pages = math.max(1, math.ceil(#matches / MERCHANT_ITEMS_PER_PAGE))
    MerchantFrame.page = math.min(MerchantFrame.page, pages)
    local first = (MerchantFrame.page - 1) * MERCHANT_ITEMS_PER_PAGE
    for i, s in ipairs(slots) do
        FillSlot(s, matches[first + i])
    end
    MerchantPageText:SetFormattedText(MERCHANT_PAGE_NUMBER, MerchantFrame.page, pages)
    MerchantPrevPageButton:SetEnabled(MerchantFrame.page > 1)
    MerchantNextPageButton:SetEnabled(MerchantFrame.page < pages)
end

-- Blizzard never re-shows slots that ShowMatches hid.
local function ShowAllSlots()
    for _, s in ipairs(slots) do s.frame:Show() end
end

local function ClearOverlays()
    for _, s in ipairs(slots) do
        s.count:SetText("")
        s.known:Hide()
    end
end

local function UpdateOverlays()
    if MerchantFrame.selectedTab == 2 then return end
    local numItems = GetMerchantNumItems()
    for _, s in ipairs(slots) do
        local index = s.button:GetID()
        local itemID = s.frame:IsShown() and index > 0 and index <= numItems and GetMerchantItemID(index)
        local count = itemID and db.showCounts and C_Item.GetItemCount(itemID) or 0
        s.count:SetText(count > 0 and count or "")
        s.known:SetShown(itemID and db.showKnown and IsKnown(index, itemID) or false)
    end
end

local function Decorate()
    if search ~= "" then
        ShowMatches()
    else
        ShowAllSlots()
    end
    UpdateOverlays()
end

local searchBox

local function CreateVendorUI()
    for i = 1, MERCHANT_ITEMS_PER_PAGE do
        local button = _G["MerchantItem" .. i .. "ItemButton"]
        local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        count:SetPoint("TOPRIGHT", -1, -2)
        local knownMark = button:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
        knownMark:SetPoint("BOTTOM", 0, 2)
        knownMark:SetText("known")
        slots[i] = {
            index = i,
            frame = _G["MerchantItem" .. i],
            button = button,
            name = _G["MerchantItem" .. i .. "Name"],
            money = _G["MerchantItem" .. i .. "MoneyFrame"],
            altCurrency = _G["MerchantItem" .. i .. "AltCurrencyFrame"],
            count = count,
            known = knownMark,
        }
    end

    searchBox = CreateFrame("EditBox", nil, MerchantFrame, "SearchBoxTemplate")
    searchBox:SetSize(130, 20)
    searchBox:SetPoint("BOTTOMRIGHT", slots[2].frame, "TOPRIGHT", -1, 15)
    searchBox:HookScript("OnTextChanged", function(self)
        local text = self:GetText():lower()
        if text == search then return end
        search = text
        MerchantFrame.page = 1
        if MerchantFrame:IsShown() then MerchantFrame_Update() end
    end)
    searchBox:SetScript("OnEnterPressed", EditBox_ClearFocus)

    hooksecurefunc("MerchantFrame_Update", function()
        local buyback = MerchantFrame.selectedTab == 2
        searchBox:SetShown(not buyback)
        if buyback then
            ShowAllSlots()
            ClearOverlays()
        end
    end)
    hooksecurefunc("MerchantFrame_UpdateMerchantInfo", Decorate)
end

---------------------------------------------------------------------------
-- Sell list: alt-click an item in your bags while at a vendor
---------------------------------------------------------------------------
local RefreshSellList

local function SetSell(itemID, on)
    db.sellList[itemID] = on or nil
    Print(Link(itemID) .. (on and " added to" or " removed from") .. " the sell list")
    RefreshSellList()
end

local function ToggleSell(itemID)
    SetSell(itemID, not db.sellList[itemID])
end

hooksecurefunc("HandleModifiedItemClick", function(link)
    if not (merchantOpen and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown()) then return end
    local itemID = link and tonumber(link:match("item:(%d+)"))
    if itemID then ToggleSell(itemID) end
end)

-- Runs for every item tooltip in the game, so it leaves early unless there is something to say.
local function AddTooltipLines(tooltip, itemID)
    if not (db and itemID) then return end
    local listed, restock = db.sellList[itemID], db.restock[itemID]
    if not (merchantOpen or listed or restock) then return end
    local hint = false
    if merchantOpen then
        local owner = tooltip:GetOwner()
        local ownerName = owner and owner:GetName() or ""
        local sellPrice = select(11, C_Item.GetItemInfo(itemID)) or 0
        hint = not ownerName:find("^Merchant") and sellPrice > 0 and C_Item.GetItemCount(itemID) > 0
    end
    if listed then
        tooltip:AddLine("|cff33ff99Better|rErrands: on sell list" .. (hint and " (alt-click to remove)" or ""))
    elseif hint then
        tooltip:AddLine("|cff33ff99Better|rErrands: alt-click to add to sell list")
    end
    if restock then
        tooltip:AddLine("|cff33ff99Better|rErrands: restock to " .. restock)
    end
end

if TooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        AddTooltipLines(tooltip, data and data.id)
    end)
else
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        AddTooltipLines(tooltip, link and tonumber(link:match("item:(%d+)")))
    end)
end

---------------------------------------------------------------------------
-- Settings panel
---------------------------------------------------------------------------
local settingsCategory

local ROW_HEIGHT = 24

local function CreateSellListPanel(category)
    local panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Sell list")
    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    help:SetPoint("RIGHT", -16, 0)
    help:SetJustifyH("LEFT")
    help:SetText("These items are sold at every vendor. To add one, drag it onto the box, "
        .. "shift-click it into the box, or type its item ID. At a vendor you can also alt-click items in your bags.")

    local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    box:SetSize(240, 20)
    box:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 6, -12)
    box:SetAutoFocus(false)
    local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addButton:SetSize(70, 22)
    addButton:SetPoint("LEFT", box, "RIGHT", 8, 0)
    addButton:SetText("Add")

    local function Add(itemID)
        itemID = tonumber(itemID)
        if itemID and C_Item.GetItemInfoInstant(itemID) then
            SetSell(itemID, true)
        else
            Print("that isn't an item; drop, shift-click or type an item ID")
        end
        box:SetText("")
        box:ClearFocus()
    end
    local function AddFromBox()
        local text = box:GetText()
        Add(text:match("item:(%d+)") or text:match("^%s*(%d+)%s*$"))
    end
    local function AddFromCursor()
        local kind, itemID = GetCursorInfo()
        if kind == "item" then
            ClearCursor()
            Add(itemID)
        end
    end
    box:SetScript("OnEnterPressed", AddFromBox)
    box:SetScript("OnReceiveDrag", AddFromCursor)
    box:HookScript("OnMouseDown", AddFromCursor)
    addButton:SetScript("OnClick", AddFromBox)
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if box:HasFocus() and link then box:SetText(link) end
    end)

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -16)
    scroll:SetPoint("BOTTOMRIGHT", -32, 16)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    local empty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -4)
    empty:SetText("Your sell list is empty.")

    local rows = {}
    local function Row(i)
        if rows[i] then return rows[i] end
        local row = CreateFrame("Button", nil, content)
        row:SetHeight(ROW_HEIGHT - 2)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", scroll, "RIGHT")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT")
        row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.remove:SetSize(80, 20)
        row.remove:SetPoint("RIGHT")
        row.remove:SetText("Remove")
        row.remove:SetScript("OnClick", function() SetSell(row.itemID, false) end)
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
        row.text:SetJustifyH("LEFT")
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        rows[i] = row
        return row
    end

    RefreshSellList = function()
        if not panel:IsVisible() then return end
        local entries = {}
        for itemID in pairs(db.sellList) do
            local name = C_Item.GetItemInfo(itemID)
            if not name then Item:CreateFromItemID(itemID):ContinueOnItemLoad(RefreshSellList) end
            entries[#entries + 1] = { itemID = itemID, name = name or "" }
        end
        table.sort(entries, function(a, b) return a.name < b.name end)
        content:SetSize(scroll:GetWidth(), math.max(1, #entries * ROW_HEIGHT))
        for i, entry in ipairs(entries) do
            local row = Row(i)
            row.itemID = entry.itemID
            row.icon:SetTexture(C_Item.GetItemIconByID(entry.itemID))
            row.text:SetText(Link(entry.itemID))
            row:Show()
        end
        for i = #entries + 1, #rows do rows[i]:Hide() end
        empty:SetShown(#entries == 0)
    end
    panel:SetScript("OnShow", RefreshSellList)

    Settings.RegisterCanvasLayoutSubcategory(category, panel, "Sell list")
end

local function RegisterSettings()
    local category = Settings.RegisterVerticalLayoutCategory("|cff33ff99Better|rErrands")
    local function Checkbox(key, name, tooltip)
        local setting = Settings.RegisterProxySetting(category, "BE_" .. key, Settings.VarType.Boolean, name,
            DEFAULTS[key], function() return db[key] end, function(value) db[key] = value end)
        Settings.CreateCheckbox(category, setting, tooltip)
    end
    Checkbox("sellJunk", "Sell junk",
        "Sell all grey items when you open a vendor. Skipped while Leatrix Plus sells junk.")
    Checkbox("sellListOn", "Sell list",
        "Sell the items on your sell list when you open a vendor. Alt-click an item in your bags at a vendor to add or remove it.")
    Checkbox("autoRepair", "Repair",
        "Repair all gear when you open a vendor that can repair. Skipped while Leatrix Plus repairs.")
    local limit = Settings.RegisterProxySetting(category, "BE_repairLimit", Settings.VarType.Number, "Repair limit",
        DEFAULTS.repairLimit, function() return db.repairLimit end, function(value) db.repairLimit = value end)
    local options = Settings.CreateSliderOptions(0, 100, 1)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
        return value == 0 and "no limit" or (value .. "g")
    end)
    Settings.CreateSlider(category, limit, options, "Don't repair automatically when it costs more than this.")
    Checkbox("restockOn", "Restock",
        "Buy items back up to the amount you set with /be restock when you open a vendor that sells them.")
    Checkbox("showCounts", "Show bag counts", "Show how many of each vendor item you carry.")
    Checkbox("showKnown", "Mark known items", "Mark recipes and items the vendor sells that you already know.")
    Checkbox("quiet", "Mute chat messages", "Don't print what was sold, repaired or restocked.")
    CreateSellListPanel(category)
    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_BETTERERRANDS1 = "/be"
SLASH_BETTERERRANDS2 = "/bettererrands"
SlashCmdList.BETTERERRANDS = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local itemID = tonumber(rest:match("item:(%d+)") or rest:match("^(%d+)"))
    if cmd == "" or cmd == "options" then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif cmd == "sell" and itemID then
        ToggleSell(itemID)
    elseif cmd == "restock" and itemID then
        local amount = tonumber(rest:match("(%d+)%s*$"))
        if rest:match("item:") and amount == itemID then amount = nil end
        if amount and amount > 0 then
            db.restock[itemID] = amount
            Print(("restock %s to %d"):format(Link(itemID), amount))
        else
            db.restock[itemID] = nil
            Print(Link(itemID) .. " no longer restocked")
        end
    elseif cmd == "list" then
        Print("sell list:")
        for id in pairs(db.sellList) do print("  " .. Link(id)) end
        Print("restock:")
        for id, n in pairs(db.restock) do print(("  %s to %d"):format(Link(id), n)) end
    else
        Print("commands:")
        print("  /be - open the settings")
        print("  /be sell <item> - add or remove an item on the sell list (or alt-click it in your bags at a vendor)")
        print("  /be restock <item> <amount> - keep that many in your bags; amount 0 stops")
        print("  /be list - show the sell and restock lists")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        BetterErrandsDB = BetterErrandsDB or {}
        db = BetterErrandsDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        db.sellList = db.sellList or {}
        db.restock = db.restock or {}
        frame:UnregisterEvent("ADDON_LOADED")
        RegisterSettings()
        CreateVendorUI()
        frame:RegisterEvent("MERCHANT_SHOW")
        frame:RegisterEvent("MERCHANT_CLOSED")
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        visit = visit + 1
        local thisVisit = visit
        frame:RegisterEvent("BAG_UPDATE_DELAYED")
        -- Other vendor addons act on MERCHANT_SHOW too; going second means we only
        -- pick up what they left, since repair skips a zero cost and selling skips sold items.
        C_Timer.After(0.5, function()
            if not merchantOpen or visit ~= thisVisit then return end
            Repair()
            Sell()
            Restock()
        end)
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        frame:UnregisterEvent("BAG_UPDATE_DELAYED")
        wipe(known)
        searchBox:SetText("")
    elseif event == "BAG_UPDATE_DELAYED" then
        UpdateOverlays()
    end
end)
