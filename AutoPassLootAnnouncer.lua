local ADDON_NAME = ...

--[[ AutoPassLootAnnouncer
     Announces what drops the moment it drops, and (optionally) auto-passes every roll.

     Two independent announce paths:
       1) START_LOOT_ROLL  -> requires Blizzard's "Pass on Loot" option to be OFF.
                              The only way to learn about a drop the instant it drops.
       2) LOOT_READY       -> works even with Pass on Loot ON, but only when *you*
                              open the corpse. Off at every login.

     Auto-pass and corpse announce are always OFF at login, deliberately.

     Minimap button:  left click = arm/disarm auto-pass, right click = settings, drag = move
                      green P = armed, silver P = normal rolls
     /apla       open the settings panel (/lap still works)
]]

----------------------------------------------------------------
-- Config (saved per account in AutoPassLootAnnouncerDB)
----------------------------------------------------------------
local defaults = {
    autopass     = false,  -- master switch for automated rolling; forced off at every login
    announce     = true,   -- false = print to your own chat frame only
    channel      = 3,      -- widest channel to use: 1 say, 2 party, 3 raid, 4 yell
    minQuality   = 3,      -- announce threshold: 2=green 3=blue 4=epic
    -- actions[quality + 1] = -1 leave / 0 pass / 1 need / 2 greed. Built in
    -- ADDON_LOADED because a table in `defaults` would be shared by reference.
    fromCorpse   = false,  -- also announce when you open a corpse; forced off at every login
    prefix       = "Drop:",
    pepe         = false,  -- prepend a random happy pepe to every announce
    coop         = true,   -- when several of us run this, only one announces
    debug        = false,  -- /apla debug: log every roll decision
    minimapAngle = 200,
    minimapHide  = false,
}

local db   -- declared before anything that reads it, or it resolves to a nil global

local QUALITY_NAME = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" }
local CHANNEL_NAME = { "Say", "Party", "Raid", "Yell" }

-- Pepe mode. Twitch Emotes 2.0 swaps these words for pictures on the reading
-- end, so anyone without that addon sees the bare word instead. Picked by
-- looking at the artwork rather than trusting the names, since plenty of
-- cheerful-sounding ones (PepeHands, PepeCry, PepegaSad) are miserable.
local PEPE_HAPPY = {
    "PepeD", "PepeJAM", "PepePogO", "PogChampPepe", "Pepeggers", "PepeXD",
    "PepeLaugh", "PepeLaff", "PepeLMAO", "PepegaLaugh", "pepeGiggle", "Pepega",
    "PepeThumbsUp", "pepeW", "pepeWave", "pepeOK", "PepeOuuuhh", "PepeSmile",
    "pajaPepe", "PepeAyy", "PepeHeart", "PepeLove", "PepeHug", "pepeKingLove",
}

local lastPepe
local function RandomPepe()
    local pick = PEPE_HAPPY[math.random(#PEPE_HAPPY)]
    if pick == lastPepe then
        pick = PEPE_HAPPY[math.random(#PEPE_HAPPY)]   -- one re-roll, so it rarely doubles up
    end
    lastPepe = pick
    return pick
end

local function QualityLabel(v)
    if v < 0 then return "|cff808080nothing|r" end
    return ITEM_QUALITY_COLORS[v].hex .. QUALITY_NAME[v] .. "|r"
end

-- the announce threshold is a minimum (quality >= setting), so spell it out rather
-- than saying "up to", which reads like the roll settings but means the opposite
local function MinLabel(v)
    if v <= 0 then return "everything" end
    if v >= 5 then return QualityLabel(v) .. " only" end
    return QualityLabel(v) .. " and better"
end

-- one action per quality, no precedence rules and no inclusive/exclusive edges
local ACTIONS = {
    { value = -1, label = "Window" },
    { value =  0, label = "Pass"  },
    { value =  2, label = "Greed" },
    { value =  1, label = "Need"  },
}
local ACTION_VERB = { [-1] = "roll window stays up", [0] = "passed", [1] = "NEEDED", [2] = "greeded" }

local function ActionSummary()
    local groups = {}
    for q = 0, 5 do
        local a = db.actions[q + 1] or -1
        groups[a] = groups[a] or {}
        table.insert(groups[a], QualityLabel(q))
    end
    local parts = {}
    for _, a in ipairs({ 1, 2, 0, -1 }) do
        if groups[a] then
            parts[#parts + 1] = table.concat(groups[a], ", ") .. ": " .. ACTION_VERB[a]
        end
    end
    return table.concat(parts, "  |  ")
end

-- rolls this addon made itself, so we only auto-confirm BoP prompts we caused
local autoRolls = {}

-- Returns nil for "leave the roll window up and let the user decide".
local function RollAction(quality)
    if not quality then return nil end          -- quality unknown: never touch it
    local a = db.actions[quality + 1]
    if a == nil or a < 0 then return nil end
    return a
end

local pending, flushScheduled = {}, false
local Dbg, IsAnnouncer, Announcer, SendHello, Comm   -- defined further down
local SayList
local seenSource   = {}   -- [key]    = GetTime(), corpses already announced
local rollSeen     = {}   -- [itemID] = GetTime(), announced from a roll window
local corpseSeen   = {}   -- [itemID] = GetTime(), announced from a corpse
local lootAnnounced = false

-- an item can reach us down both paths for the same kill, in either order:
-- corpse first (you open the body, then the roll pops) or roll first.
local function CrossPathDupe(tbl, itemID)
    return itemID and tbl[itemID] and (GetTime() - tbl[itemID]) < 120
end

----------------------------------------------------------------
-- Output
----------------------------------------------------------------
-- The channel slider sets the WIDEST channel allowed, not a fixed one. We step down
-- from that cap to the widest channel actually available right now:
--   cap Yell  -> always yell
--   cap Raid  -> raid, or party when only grouped, or nothing when solo
--   cap Party -> party when grouped, nothing when solo
--   cap Say   -> always say
local function ResolveChannel()
    if not db.announce then return nil end
    local cap = db.channel or 3
    if cap >= 4 then return "YELL" end
    if cap >= 3 and IsInRaid() then return "RAID" end
    if cap >= 2 and IsInGroup() then return "PARTY" end   -- your subgroup while in a raid
    if cap <= 1 then return "SAY" end
    return nil                                            -- grouped-only cap, but solo
end

local function Say(msg)
    local ch = ResolveChannel()
    if not ch then
        print("|cff66ccffAPLA|r " .. msg)
        return
    end
    SendChatMessage(msg, ch)
end

-- one message per item, never combined onto a line
function SayList(links, force)
    if not force and not IsAnnouncer() then
        Dbg("%s is announcing this one, staying quiet", tostring(Announcer()))
        return
    end
    for _, link in ipairs(links) do
        -- pepe first, then your prefix, then the item. Each part is space
        -- separated because Twitch Emotes only matches whole words.
        local parts = {}
        if db.pepe then tinsert(parts, RandomPepe()) end
        if db.prefix and db.prefix ~= "" then tinsert(parts, db.prefix) end
        tinsert(parts, link)
        Say(table.concat(parts, " "))
    end
end

local function Flush()
    flushScheduled = false
    if #pending > 0 then
        SayList(pending)
        wipe(pending)
    end
end

local function Queue(link)
    table.insert(pending, link)
    if not flushScheduled then
        flushScheduled = true
        C_Timer.After(1.0, Flush)   -- batch items from the same kill into one line
    end
end

local function QualityOf(link)
    if not link then return nil end
    local q = select(3, GetItemInfo(link))
    if q then return q end
    -- fall back to the colour code embedded in the link
    local hex = link:match("|c(%x%x%x%x%x%x%x%x)")
    local map = { ff9d9d9d = 0, ffffffff = 1, ff1eff00 = 2, ff0070dd = 3, ffa335ee = 4, ffff8000 = 5 }
    return hex and map[hex:lower()]
end

function Dbg(fmt, ...)
    if db.debug then print("|cff66ccffAPLA|r |cff888888" .. fmt:format(...) .. "|r") end
end

-- An item the client has never seen has no cached info yet, so at the instant
-- START_LOOT_ROLL fires both GetLootRollItemInfo and GetItemInfo can come back
-- empty. Rolls run for two minutes, so retry for a few seconds instead of
-- silently skipping the item.
local function ProcessRoll(rollID, tries)
    local timeLeft = GetLootRollTimeLeft(rollID)
    if not timeLeft or timeLeft <= 0 then
        Dbg("roll %d expired before we could read it", rollID)
        return                                   -- roll already over
    end

    local link = GetLootRollItemLink(rollID)
    local quality = select(4, GetLootRollItemInfo(rollID)) or QualityOf(link)

    if (not link or not quality) and tries < 12 then
        C_Timer.After(0.25, function() ProcessRoll(rollID, tries + 1) end)
        return
    end

    Dbg("roll %d: link=%s quality=%s tries=%d", rollID, tostring(link), tostring(quality), tries)

    local itemID = link and link:match("item:(%d+)")
    if link and not CrossPathDupe(corpseSeen, itemID) and (quality or 99) >= db.minQuality then
        Queue(link)
    end
    if itemID then rollSeen[itemID] = GetTime() end

    if not db.autopass then
        Dbg("not armed, leaving roll %d alone", rollID)
        return
    end

    local action = RollAction(quality)
    Dbg("action for roll %d = %s", rollID, tostring(action))
    if action then
        autoRolls[rollID] = action
        RollOnLoot(rollID, action)               -- 0 pass, 1 need, 2 greed
        C_Timer.After(10, function() autoRolls[rollID] = nil end)
        if action == 1 and link then
            print("|cff66ccffAPLA|r auto-needed: " .. link)
        end
    else
        print("|cff66ccffAPLA|r left for you to roll: " .. (link or ("roll #" .. rollID)))
    end
end

----------------------------------------------------------------
-- Talking to other copies of this addon
----------------------------------------------------------------
local COMM_PREFIX = "APLAnnounce"
local peers = {}          -- [name] = { seen = GetTime(), willing = bool, coop = bool }
local lastHello = 0

local function Me() return UnitName("player") end

local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function Comm(msg)
    local ch = GroupChannel()
    if not ch then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, ch)
    else
        SendAddonMessage(COMM_PREFIX, msg, ch)
    end
end

function SendHello(force)
    local now = GetTime()
    if not force and (now - lastHello) < 3 then return end
    lastHello = now
    -- willing: this copy would announce at all. coop: it defers to an election.
    Comm(("H:%s:%s"):format(db.announce and 1 or 0, db.coop and 1 or 0))
end

-- Everyone runs the same election over the same roster, so no negotiation is
-- needed per drop: lowest name alphabetically among the willing copies wins.
function Announcer()
    local best = db.announce and Me() or nil
    local now = GetTime()
    for name, info in pairs(peers) do
        if info.willing and (now - info.seen) < 900 then
            if not best or name < best then best = name end
        end
    end
    return best
end

function IsAnnouncer()
    if not db.coop then return true end          -- opted out of coordination
    local a = Announcer()
    return a == nil or a == Me()
end

local function PruneToGroup()
    if not IsInGroup() then wipe(peers); return end
    local present = {}
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, GetNumGroupMembers() do
        local n = UnitName(prefix .. i)
        if n then present[n] = true end
    end
    for name in pairs(peers) do
        if not present[name] then peers[name] = nil end
    end
end

----------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------
local button, panel, RefreshPanel

-- built from the folder name, so renaming the addon folder can't break the paths
local TEX_ON  = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\pass-on.tga"
local TEX_OFF = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\pass-off.tga"

local function UpdateButtonLook()
    local tex = db.autopass and TEX_ON or TEX_OFF   -- green P = passing, silver P = normal rolls
    if button and button.icon then button.icon:SetTexture(tex) end
    if panel  and panel.icon  then panel.icon:SetTexture(tex) end
end

local function UpdateButtonPos()
    local a = math.rad(db.minimapAngle)
    button:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
end

local function ChannelSummary()
    if not db.announce then return "|cffff0000off|r" end
    local ch = ResolveChannel()
    local cap = CHANNEL_NAME[db.channel or 3]:lower()
    if not ch then return "|cffffff00self only|r (up to " .. cap .. ")" end
    return "|cff00ff00" .. ch:lower() .. "|r (up to " .. cap .. ")"
end

local function ButtonTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Auto Pass Loot Announcer")
    GameTooltip:AddDoubleLine("Auto-roll", db.autopass and "|cff00ff00ARMED|r" or "|cffff0000off|r")
    if db.autopass then
        GameTooltip:AddLine(ActionSummary(), 1, 1, 1, true)
    end
    GameTooltip:AddDoubleLine("Announcing to", ChannelSummary())
    if db.coop and next(peers) then
        local a = Announcer()
        GameTooltip:AddDoubleLine("Announcer", (a == Me()) and "|cff00ff00you|r" or ("|cffffff00" .. tostring(a) .. "|r"))
    end
    GameTooltip:AddDoubleLine("Corpse announce", db.fromCorpse and "|cff00ff00on|r" or "|cffff0000off|r")
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffeda55fLeft click|r arm/disarm auto-pass", 1, 1, 1)
    GameTooltip:AddLine("|cffeda55fRight click|r settings", 1, 1, 1)
    GameTooltip:AddLine("|cffeda55fDrag|r move", 1, 1, 1)
    GameTooltip:Show()
end

local function ToggleAutopass()
    db.autopass = not db.autopass
    UpdateButtonLook()
    if panel and panel:IsShown() then RefreshPanel() end
    print("|cff66ccffAPLA|r auto-pass: " .. (db.autopass and "|cff00ff00ARMED|r" or "|cffff0000off|r"))
end

local function BuildButton()
    button = CreateFrame("Button", "AutoPassLootAnnouncerMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    -- standard minimap button geometry, same as LibDBIcon uses, so this sits in line
    -- with every other addon button: 31x31 button, 17x17 icon at (7,-5), 53x53 rim
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(17, 17)
    button.icon:SetPoint("TOPLEFT", 7, -5)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local function DragUpdate()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
        UpdateButtonPos()
    end

    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", DragUpdate)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            if panel:IsShown() then panel:Hide() else RefreshPanel(); panel:Show() end
        else
            ToggleAutopass()
            ButtonTooltip(self)
        end
    end)

    button:SetScript("OnEnter", ButtonTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateButtonLook()
    UpdateButtonPos()
    if db.minimapHide then button:Hide() end
end

----------------------------------------------------------------
-- Options panel
----------------------------------------------------------------
local function MakeCheck(parent, name, text, x, y, tip, onClick)
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    local label = cb.Text or _G[name .. "Text"]
    label:SetText(text)
    cb.tooltipText = tip
    cb:SetScript("OnClick", function(self)
        onClick(self:GetChecked() and true or false)
    end)
    return cb
end

local function BuildPanel()
    panel = CreateFrame("Frame", "AutoPassLootAnnouncerPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(340, 540)
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetClampedToScreen(true)
    panel:Hide()
    tinsert(UISpecialFrames, "AutoPassLootAnnouncerPanel")   -- Escape closes it

    panel.icon = panel:CreateTexture(nil, "ARTWORK")
    panel.icon:SetSize(26, 26)
    panel.icon:SetPoint("TOPLEFT", 8, -3)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Auto Pass Loot Announcer")

    panel.pass = MakeCheck(panel, "APLACheckPass", "Roll automatically", 16, -34,
        "Master switch for the three sliders below. With need and greed set to None it just passes on everything, the same net effect as Blizzard's Pass on Loot checkbox. Off at every login.",
        function(v) db.autopass = v; UpdateButtonLook() end)

    panel.announce = MakeCheck(panel, "APLACheckAnnounce", "Announce to chat", 16, -60,
        "Off = print to your own chat frame only, nothing is sent to the group.",
        function(v) db.announce = v; SendHello(true) end)

    panel.coop = MakeCheck(panel, "APLACheckCoop", "Only one of us announces", 16, -86,
        "When several people in the group run this addon, they elect a single announcer so the drop is only posted once. Turn this off to always announce yourself.",
        function(v) db.coop = v; SendHello(true) end)

    panel.corpse = MakeCheck(panel, "APLACheckCorpse", "Also announce when I open a corpse", 16, -112,
        "Only useful if you keep Blizzard's Pass on Loot checkbox on. Doubles up with the roll window when you are the one looting. Off at every login.",
        function(v) db.fromCorpse = v end)

    panel.minimap = MakeCheck(panel, "APLACheckMinimap", "Show minimap button", 16, -138,
        nil,
        function(v)
            db.minimapHide = not v
            if v then button:Show() else button:Hide() end
        end)

    local function MakeSlider(name, y, minv, maxv, low, high, caption, textFor, set)
        local sl = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
        sl:SetPoint("TOPLEFT", 24, y)
        sl:SetWidth(280)
        sl:SetMinMaxValues(minv, maxv)
        sl:SetValueStep(1)
        if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
        _G[name .. "Low"]:SetText(low)
        _G[name .. "High"]:SetText(high)
        sl:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5)
            set(v)
            _G[name .. "Text"]:SetText(caption .. textFor(v))
        end)
        return sl
    end

    panel.chSlider = MakeSlider("APLAChannelSlider", -178, 1, 4, "Say", "Yell",
        "Announce up to: ", function(v) return CHANNEL_NAME[v] end,
        function(v) db.channel = v end)
    panel.chSlider.tooltipText = "The widest channel to use. It steps down to whatever is actually available: set to Raid, you get raid in a raid and party in a party."

    panel.slider = MakeSlider("APLAQualitySlider", -222, 0, 5, "Poor", "Legendary",
        "Announce: ", MinLabel, function(v) db.minQuality = v end)

    panel.summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.summary:SetPoint("TOPLEFT", 24, -416)
    panel.summary:SetWidth(292)
    panel.summary:SetJustifyH("LEFT")

    local function UpdateGrid()
        for q = 0, 5 do
            for i, a in ipairs(ACTIONS) do
                panel.radios[q][i]:SetChecked((db.actions[q + 1] or -1) == a.value)
            end
        end
        panel.summary:SetText(ActionSummary())
    end
    panel.UpdateGrid = UpdateGrid

    local gridHead = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gridHead:SetPoint("TOPLEFT", 24, -248)
    gridHead:SetText("What to do with each quality")
    gridHead.tooltipText = "Window = do nothing, so the roll window stays on screen for you to answer."

    local COLX = { 150, 195, 240, 285 }
    for i, a in ipairs(ACTIONS) do
        local h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOP", panel, "TOPLEFT", COLX[i] + 8, -264)
        h:SetText(a.label)
    end

    panel.radios = {}
    for q = 0, 5 do
        local y = -280 - q * 22
        local name = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOPLEFT", 30, y - 2)
        name:SetText(QualityLabel(q))

        panel.radios[q] = {}
        for i, a in ipairs(ACTIONS) do
            local rb = CreateFrame("CheckButton", "APLAAction" .. q .. "_" .. i, panel, "UIRadioButtonTemplate")
            rb:SetPoint("TOPLEFT", COLX[i], y)
            rb:SetScript("OnClick", function()
                db.actions[q + 1] = a.value
                UpdateGrid()
            end)
            panel.radios[q][i] = rb
        end
    end

    local prefixLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixLabel:SetPoint("TOPLEFT", 24, -454)
    prefixLabel:SetText("Chat prefix")

    local edit = CreateFrame("EditBox", "APLAPrefixEdit", panel, "InputBoxTemplate")
    edit:SetPoint("TOPLEFT", 96, -450)
    edit:SetSize(190, 20)
    edit:SetAutoFocus(false)
    -- Commit on focus lost, not only on Enter. Clicking Test does not press
    -- Enter for you, and reverting the box there threw away what you typed
    -- while leaving it on screen, so the prefix looked applied but was not.
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusLost", function(self) db.prefix = self:GetText() end)
    edit:SetScript("OnEscapePressed", function(self)
        self:SetText(db.prefix)   -- Escape is the one way to discard an edit
        self:ClearFocus()
    end)
    panel.edit = edit

    -- Ask the client for the link instead of writing an item string by hand.
    -- A hand-written one is short of the fields this client emits, and the
    -- server drops a chat message carrying a malformed link without a word,
    -- so Test did nothing in a group while printing fine when solo.
    local TEST_ITEM = 32235   -- Cursed Vision of Sargeras

    local function TestSay(link)
        if not db.announce then
            print("|cff66ccffAPLA|r announce to chat is off, so this only prints here")
        elseif not ResolveChannel() then
            print(("|cff66ccffAPLA|r cap is %s and you are not in a group, so this only prints here")
                :format(CHANNEL_NAME[db.channel] or "?"))
        end
        SayList({ link }, true)
    end

    local function TestAnnounce()
        local link = select(2, GetItemInfo(TEST_ITEM))
        if link then
            TestSay(link)
            return
        end
        -- That call asked the server for the item, so give it a moment.
        C_Timer.After(1, function()
            local retry = select(2, GetItemInfo(TEST_ITEM))
            if retry then
                TestSay(retry)
            else
                print("|cff66ccffAPLA|r could not load the test item, click Test again")
            end
        end)
    end

    panel.pepe = MakeCheck(panel, "APLACheckPepe", "Pepe mode", 16, -502,
        "Puts a random happy pepe in front of the prefix. It shows as a picture for anyone running "
            .. "Twitch Emotes 2.0; everyone else sees the emote name as plain text.",
        function(v) db.pepe = v end)

    local test = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    test:SetSize(80, 22)
    test:SetPoint("BOTTOMRIGHT", -12, 12)
    test:SetText("Test")
    test:SetScript("OnClick", function()
        edit:ClearFocus()   -- commit a half-typed prefix so the test uses it
        TestAnnounce()
    end)
end

function RefreshPanel()
    panel.pass:SetChecked(db.autopass)
    panel.announce:SetChecked(db.announce)
    panel.coop:SetChecked(db.coop)
    panel.corpse:SetChecked(db.fromCorpse)
    panel.minimap:SetChecked(not db.minimapHide)
    panel.pepe:SetChecked(db.pepe)
    panel.chSlider:SetValue(db.channel)
    panel.slider:SetValue(db.minQuality)
    panel.UpdateGrid()
    panel.edit:SetText(db.prefix)
    UpdateButtonLook()
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CONFIRM_LOOT_ROLL")
f:RegisterEvent("LOOT_READY")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("LOOT_CLOSED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("GROUP_ROSTER_UPDATE")

f:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        AutoPassLootAnnouncerDB = AutoPassLootAnnouncerDB or {}
        db = AutoPassLootAnnouncerDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end

        if type(db.actions) ~= "table" then
            -- fresh install, or migrate the old need/greed/pass band settings
            local need, greed, pass = db.needMax or -1, db.greedMax or -1, db.passMax or 5
            db.actions = {}
            for q = 0, 5 do
                local a = -1
                if     q <= need  then a = 1
                elseif q <= greed then a = 2
                elseif q <= pass  then a = 0 end
                db.actions[q + 1] = a
            end
            db.needMax, db.greedMax, db.passMax = nil, nil, nil
        end

        -- these two are deliberately NOT remembered between sessions, so they can
        -- never be left armed by accident
        db.autopass   = false
        db.fromCorpse = false

        BuildButton()
        BuildPanel()
        UpdateButtonLook()

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(COMM_PREFIX)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        PruneToGroup()
        SendHello()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, _, sender = arg1, arg2, arg3, arg4
        if prefix ~= COMM_PREFIX then return end
        sender = Ambiguate(sender, "none")
        if sender == Me() then return end
        local willing, coop = message:match("^H:(%d):(%d)$")
        if willing then
            local known = peers[sender] ~= nil
            peers[sender] = { seen = GetTime(), willing = willing == "1", coop = coop == "1" }
            Dbg("peer %s (willing=%s coop=%s)", sender, willing, coop)
            if not known then
                -- new arrival: tell them we exist, staggered so 20 copies don't burst
                C_Timer.After(0.5 + math.random() * 2, function() SendHello(true) end)
            end
        end

    elseif event == "PLAYER_LOGIN" then
        math.randomseed(time())   -- unseeded Lua repeats the same sequence every session
        SendHello(true)
        print("|cff66ccffAutoPassLootAnnouncer|r loaded. Auto-pass |cffff0000off|r, corpse announce "
            .. "|cffff0000off|r - left-click the minimap button to arm auto-pass.")

    elseif event == "START_LOOT_ROLL" then
        ProcessRoll(arg1, 0)

    elseif event == "CONFIRM_LOOT_ROLL" then
        -- needing or greeding a BoP item raises a confirmation. Only auto-answer it
        -- when the roll was ours; a prompt from your own click stays on screen.
        local rollID, rollType = arg1, arg2
        if autoRolls[rollID] then
            ConfirmLootRoll(rollID, rollType)
            autoRolls[rollID] = nil
        end

    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        if not db.fromCorpse or lootAnnounced then return end
        local n = GetNumLootItems() or 0
        if n == 0 then return end

        local now = GetTime()
        local links, sig = {}, {}
        for i = 1, n do
            local link = GetLootSlotLink(i)   -- nil for money slots
            if link then
                sig[#sig + 1] = link
                local itemID = link:match("item:(%d+)")
                local quality = QualityOf(link)
                if not CrossPathDupe(rollSeen, itemID) and (quality or 99) >= db.minQuality then
                    links[#links + 1] = link
                    if itemID then corpseSeen[itemID] = now end
                end
            end
        end
        if #sig == 0 then return end

        -- LOOT_READY and LOOT_OPENED each fire several times per corpse, and the slot
        -- list changes as you take things, so announce at most once per loot window.
        -- Key on the source GUID when the client gives us one (it is often nil at
        -- LOOT_READY), otherwise on the item list itself.
        local guid = GetLootSourceInfo and GetLootSourceInfo(1)
        local key = guid or table.concat(sig)
        lootAnnounced = true
        if seenSource[key] and (now - seenSource[key]) < 60 then return end
        seenSource[key] = now

        for k, t in pairs(seenSource) do if now - t > 600 then seenSource[k] = nil end end
        for k, t in pairs(rollSeen)   do if now - t > 600 then rollSeen[k]   = nil end end
        for k, t in pairs(corpseSeen) do if now - t > 600 then corpseSeen[k] = nil end end

        if #links > 0 then SayList(links) end

    elseif event == "LOOT_CLOSED" then
        lootAnnounced = false
    end
end)

----------------------------------------------------------------
-- /apla
----------------------------------------------------------------
SLASH_AUTOPASSLOOTANNOUNCER1 = "/apla"
SLASH_AUTOPASSLOOTANNOUNCER2 = "/lap"
SlashCmdList.AUTOPASSLOOTANNOUNCER = function(msg)
    local cmd, val = msg:lower():match("^(%S*)%s*(.-)%s*$")
    if cmd == "pass" then
        ToggleAutopass()
        return
    elseif cmd == "announce" then
        db.announce = not db.announce
        print("|cff66ccffAPLA|r chat announce: " .. tostring(db.announce))
    elseif cmd == "channel" then
        local n = { say = 1, party = 2, raid = 3, yell = 4 }
        if n[val] then
            db.channel = n[val]
            print("|cff66ccffAPLA|r announce up to: " .. CHANNEL_NAME[db.channel])
        else
            print("|cff66ccffAPLA|r /apla channel say|party|raid|yell")
        end
    elseif cmd == "corpse" then
        db.fromCorpse = not db.fromCorpse
        print("|cff66ccffAPLA|r announce from corpse: " .. tostring(db.fromCorpse))
    elseif cmd == "quality" and tonumber(val) then
        db.minQuality = tonumber(val)
    elseif cmd == "set" then
        local q, act = val:match("^(%d)%s+(%a+)$")
        local map = { window = -1, leave = -1, pass = 0, need = 1, greed = 2 }
        q = tonumber(q)
        if q and q >= 0 and q <= 5 and map[act or ""] then
            db.actions[q + 1] = map[act]
            print("|cff66ccffAPLA|r " .. QualityLabel(q) .. ": " .. ACTION_VERB[map[act]])
        else
            print("|cff66ccffAPLA|r /apla set <0-5> <window|pass|greed|need>")
        end
    elseif cmd == "coop" then
        db.coop = not db.coop
        SendHello(true)
        print("|cff66ccffAPLA|r coordinate: " .. tostring(db.coop))
    elseif cmd == "who" then
        SendHello(true)
        print("|cff66ccffAPLA|r announcer: " .. tostring(Announcer()))
        for name, info in pairs(peers) do
            print(("  %s  willing=%s coop=%s"):format(name, tostring(info.willing), tostring(info.coop)))
        end
    elseif cmd == "pepe" then
        db.pepe = not db.pepe
        print("|cff66ccffAPLA|r pepe mode: " .. tostring(db.pepe))
    elseif cmd == "debug" then
        db.debug = not db.debug
        print("|cff66ccffAPLA|r debug: " .. tostring(db.debug))
    elseif cmd == "minimap" then
        db.minimapHide = not db.minimapHide
        if db.minimapHide then button:Hide() else button:Show() end
    else
        RefreshPanel()
        panel:Show()
        return
    end
    if panel:IsShown() then RefreshPanel() end
end
