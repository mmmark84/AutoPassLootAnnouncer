local ADDON_NAME = ...

--[[ AutoPassLootAnnouncer
     Announces what drops the moment it drops, and (optionally) auto-passes every roll.

     Announcing hangs off START_LOOT_ROLL, which requires Blizzard's "Pass on Loot"
     option to be OFF. It is the only way to learn about a drop the instant it drops,
     and it reports the kill whoever ends up opening the corpse.

     Auto-pass is never remembered between sessions. What happens at login is
     the "At login" setting: off, armed straight away, or a prompt each time.

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
    -- actionsBoP[quality] and actionsBoE[quality] = -1 leave / 0 pass / 1 need /
    -- 2 greed, rare and up only. Built in ADDON_LOADED because a table in
    -- `defaults` would be shared by reference.
    prefix       = "Drop:",
    pepe         = false,  -- prepend a random happy pepe to every announce
    loginArm     = "off",  -- what automated rolling does at login: off / on / ask
    track        = false,  -- keep a log of what dropped; off until you ask for it
    trackMin     = 2,      -- log uncommon and better
    -- loot = { entries = {}, money = 0, started = <time> }, built in ADDON_LOADED
    -- for the same reason the action tables are
    debug        = false,  -- /apla debug: log every roll decision
    minimapAngle = 200,
    minimapHide  = false,
}

local db   -- declared before anything that reads it, or it resolves to a nil global

local QUALITY_NAME = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- What automated rolling does at login. Armed is never carried between
-- sessions, so this decides what happens each time rather than remembering.
local LOGIN_ARM_ORDER = { "off", "on", "ask" }
local LOGIN_ARM_LABEL = { off = "Off", on = "On", ask = "Ask" }

local function NextLoginArm(cur)
    for i, v in ipairs(LOGIN_ARM_ORDER) do
        if v == cur then return LOGIN_ARM_ORDER[i % #LOGIN_ARM_ORDER + 1] end
    end
    return LOGIN_ARM_ORDER[1]
end
local CHANNEL_NAME = { "Say", "Party", "Raid", "Yell" }

-- Uncommon is the lowest quality the addon will answer for. Poor and common are
-- left alone entirely: no auto-roll, the window stays up exactly as it would
-- without the addon running.
--
-- Every quality above that gets the same three rows. Uncommon had a single row
-- back when they were all stacked flat and each one cost height; behind a tab
-- it costs nothing, and green mats split from green gear the same way epic ones
-- do, so there is no reason left to special-case it.
local MIN_ACTION_QUALITY = 2

-- what a quality is set to on a fresh install. Auto-roll is disarmed at every
-- login, so this only takes effect once you arm it deliberately.
local DEFAULT_ACTION = 0    -- pass

-- What a drop binds as, and whether it stacks, decide more about who wants it
-- than its quality does. A BoE epic gem is a commodity somebody will buy; the
-- BoE pattern off the same boss is a drop one person has been waiting weeks
-- for; the BoP version of either is neither. So each is answered separately.
--
-- Stack size stands in for "is this a commodity": gems, primals and mats stack,
-- gear and recipes do not. It is only asked of BoE items, because a BoP one is
-- already answered by the time it would matter.
local KINDS = {
    {
        key = "actionsBoP", label = "BoP",
        tip = {
            "Bind on pickup. It binds to whoever wins it, so it is only ever worth a roll to "
                .. "someone who is going to use it.",
            "Tier tokens, boss gear, BoP crafting reagents.",
        },
    },
    {
        key = "actionsBoE", label = "BoE",
        tip = {
            "Bind on equip, and does not stack. The one-off drops, where somebody in the raid "
                .. "may have been waiting weeks for this exact item.",
            "Patterns and recipes, BoE weapons and armour.",
        },
    },
    {
        key = "actionsBoEStack", label = "BoE stack",
        tip = {
            "Bind on equip, and stacks. Commodities: worth gold on the auction house rather "
                .. "than a raid slot, and one more on the pile is much like the last.",
            "Epic gems, motes and primals, void crystals, nether vortexes.",
            "Told apart from the row above by the item's maximum stack size.",
        },
    },
}

local function ActionKey(bop, stackable)
    if bop then return "actionsBoP" end
    return stackable and "actionsBoEStack" or "actionsBoE"
end

-- Pepe mode. Twitch Emotes 2.0 swaps these words for pictures on the reading
-- end, so anyone without that addon sees the bare word instead. Picked by
-- looking at the artwork rather than trusting the names, since plenty of
-- cheerful-sounding ones (PepeHands, PepeCry, PepegaSad) are miserable.
--
-- Still frames only. Twitch Emotes animates an emote by rewriting the whole
-- chat line and calling SetText on it 30 times a second, which tears down the
-- links in that line as you are pointing at one, so the item tooltip never
-- settles. It guards its own tel: links against that and nothing else. Only
-- PepeD and PepeJAM of the ones below were animated, so both are gone.
local PEPE_HAPPY = {
    "PepePogO", "PogChampPepe", "Pepeggers", "PepeXD", "PepeLaugh", "PepeLaff",
    "PepeLMAO", "PepegaLaugh", "pepeGiggle", "Pepega", "PepeThumbsUp", "pepeW",
    "pepeWave", "pepeOK", "PepeOuuuhh", "PepeSmile", "pajaPepe", "PepeAyy",
    "PepeHeart", "PepeLove", "PepeHug", "pepeKingLove",
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

-- one action per quality and bind type, no precedence rules and no
-- inclusive/exclusive edges
local ACTIONS = {
    { value = -1, label = "Window" },
    { value =  0, label = "Pass"  },
    { value =  2, label = "Greed" },
    { value =  1, label = "Need"  },
}
local ACTION_VERB = { [-1] = "roll window stays up", [0] = "passed", [1] = "NEEDED", [2] = "greeded" }

-- The panel summary uses the column headers instead. The long verbs read well
-- in a one-off line of chat, but three of them per row wrapped the summary into
-- the chat prefix field below it.
local ACTION_SHORT = {}
for _, a in ipairs(ACTIONS) do ACTION_SHORT[a.value] = a.label end

local function KindSummary(actions)
    local groups = {}
    for q = MIN_ACTION_QUALITY, 5 do
        local a = actions[q] or -1
        groups[a] = groups[a] or {}
        table.insert(groups[a], QualityLabel(q))
    end
    local parts = {}
    for _, a in ipairs({ 1, 2, 0, -1 }) do
        if groups[a] then
            parts[#parts + 1] = table.concat(groups[a], ", ") .. ": " .. ACTION_SHORT[a]
        end
    end
    return table.concat(parts, "  |  ")
end

local function ActionSummary()
    local lines = {}
    for _, kind in ipairs(KINDS) do
        lines[#lines + 1] = kind.label .. "  " .. KindSummary(db[kind.key])
    end
    return table.concat(lines, "\n")
end

-- rolls this addon made itself, so we only auto-confirm BoP prompts we caused
local autoRolls = {}

-- Returns nil for "leave the roll window up and let the user decide".
local function RollAction(quality, bop, stackable)
    if not quality then return nil end                  -- quality unknown
    if quality < MIN_ACTION_QUALITY then return nil end  -- below the grid: not ours
    if bop == nil then return nil end                   -- bind type not settled yet
    if not bop and stackable == nil then return nil end -- BoE, but which kind is unclear

    local a = db[ActionKey(bop, stackable)][quality]
    if a == nil or a < 0 then return nil end
    return a
end

local pending, flushScheduled = {}, false
local Dbg, IsAnnouncer, Announcer, SendHello, Comm   -- defined further down
local SayList
local LogDrop, LogMoney, ClearLog, RefreshTracker, ToggleTracker

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

-- GetLootRollItemInfo's bindOnPickUp is the server's own answer for this exact
-- roll, so it wins whenever that call returned anything at all; a nil there
-- next to a real quality means "not BoP", not "unknown". Before the item is
-- cached the call returns nothing and GetItemInfo's bindType (1 = BoP, 2 = BoE)
-- has to answer instead, which is nil for the same reason. nil = still unknown,
-- and the caller leaves the roll alone.
local function BindOnPickup(rollQuality, rollBoP, link)
    if rollQuality ~= nil then return rollBoP and true or false end
    if not link then return nil end
    local bindType = select(14, GetItemInfo(link))
    if bindType == nil then return nil end
    return bindType == 1
end

-- GetItemInfo return 8 is the item's maximum stack size, not the number that
-- dropped -- one epic gem drops as a count of 1 but stacks to 20. There is no
-- roll-level fallback for it the way bindOnPickUp backs up bind type, so it is
-- nil until the client has the item cached. nil = still unknown.
local function IsStackable(link)
    if not link then return nil end
    local stackCount = select(8, GetItemInfo(link))
    if stackCount == nil then return nil end
    return stackCount > 1
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
    local rollQuality, rollBoP = select(4, GetLootRollItemInfo(rollID))
    local quality = rollQuality or QualityOf(link)
    local bop = BindOnPickup(rollQuality, rollBoP, link)
    local stackable = IsStackable(link)

    -- Nothing below the grid is held up waiting on either of these, and a BoP item
    -- never has its stack size read, so neither is waited on unless the answer
    -- is actually going to be used.
    local needBind  = (quality or 0) >= MIN_ACTION_QUALITY
    local needStack = needBind and bop == false

    if (not link or not quality
        or (needBind and bop == nil)
        or (needStack and stackable == nil)) and tries < 12 then
        C_Timer.After(0.25, function() ProcessRoll(rollID, tries + 1) end)
        return
    end

    Dbg("roll %d: link=%s quality=%s bop=%s stack=%s tries=%d", rollID, tostring(link),
        tostring(quality), tostring(bop), tostring(stackable), tries)

    if link and (quality or 99) >= db.minQuality then
        Queue(link)
    end

    LogDrop(link)

    if not db.autopass then
        Dbg("not armed, leaving roll %d alone", rollID)
        return
    end

    local action = RollAction(quality, bop, stackable)
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
                          -- coop is only ever false for a peer on an older version,
                          -- back when announcing alone could be switched off
-- A peer is only counted in the election for as long as we keep hearing from
-- it. Hellos used to go out at login, on roster changes and nowhere else, which
-- in a settled raid can mean no traffic at all for longer than the timeout:
-- every copy then times every other one out, each decides it is the announcer,
-- and the drop goes out twice. The heartbeat sits well inside the timeout so
-- that cannot happen, and is quiet enough to be free -- one addon message every
-- four minutes, only while grouped.
local PEER_TIMEOUT   = 900
local HELLO_INTERVAL = 240
local REQUEST_THROTTLE = 30

local lastHello, lastRequest = 0, 0

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
    -- willing: this copy would announce at all. The second field is the old
    -- opt-out flag, still sent as 1 so copies on older versions can read us.
    Comm(("H:%s:1"):format(db.announce and 1 or 0))
end

-- Sent when we think our picture of the group has gone stale. Copies on older
-- versions do not recognise it and carry on; they are still heard on their own
-- hellos. Throttled because every copy that prunes could otherwise ask at once.
local function RequestHellos()
    local now = GetTime()
    if (now - lastRequest) < REQUEST_THROTTLE then return end
    lastRequest = now
    Comm("H?")
end

-- Everyone runs the same election over the same roster, so no negotiation is
-- needed per drop: lowest name alphabetically among the willing copies wins.
function Announcer()
    local best = db.announce and Me() or nil
    local now = GetTime()
    for name, info in pairs(peers) do
        if info.willing and (now - info.seen) < PEER_TIMEOUT then
            if not best or name < best then best = name end
        end
    end
    return best
end

function IsAnnouncer()
    local a = Announcer()
    return a == nil or a == Me()
end

local function PruneToGroup()
    if not IsInGroup() then wipe(peers); return end

    local present, found = {}, 0
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, GetNumGroupMembers() do
        local n = UnitName(prefix .. i)
        if n then present[n] = true; found = found + 1 end
    end

    -- GROUP_ROSTER_UPDATE can arrive before the unit table has caught up, and
    -- pruning against a roster that is not there yet throws away peers we are
    -- still grouped with. Leave them be; the timeout sees off anyone who has
    -- really gone.
    if found == 0 then return end

    local dropped = false
    for name in pairs(peers) do
        if not present[name] then peers[name] = nil; dropped = true end
    end

    -- If that was wrong -- a name the client had not filled in yet, say -- we
    -- have just made ourselves think we are alone. Ask for a recount rather
    -- than announcing over someone for the next few minutes.
    if dropped then RequestHellos() end
end

----------------------------------------------------------------
-- Drop tracker
----------------------------------------------------------------
-- A session lasts as long as you leave it: the log is saved between logins and
-- emptied only by the Clear button, so a night of trash runs with a logout in
-- the middle is still one list.
--
-- Rows come from CHAT_MSG_LOOT, which is the only thing that carries a winner's
-- name or says how many of something changed hands. START_LOOT_ROLL adds a row
-- too, but only for items that do not stack: it fires before anyone has won, so
-- the row waits with no winner until a loot message fills it in, and a row that
-- is never filled in is a drop nobody took. Stackables are left to the loot
-- message alone, because counting them from both events would count them twice.
local MAX_LOOT_ROWS     = 500
local LOOT_MATCH_WINDOW = 180   -- seconds a row waits for its winner

-- "%s receives loot: %sx%d." and friends are format strings, not patterns, so
-- escape everything magic and turn the placeholders into captures.
local function ToPattern(fmt)
    local out = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    out = out:gsub("%%%%s", "(.+)")
    out = out:gsub("%%%%d", "(%%d+)")
    return "^" .. out .. "$"
end

-- The multiple forms are tried first. "receives loot: [Item]x3." also matches
-- the singular pattern, with the "x3" swallowed into the item capture.
local lootForms
local function LootForms()
    if not lootForms then
        lootForms = {
            { p = ToPattern(LOOT_ITEM_SELF_MULTIPLE), link = 1, count = 2 },
            { p = ToPattern(LOOT_ITEM_SELF),          link = 1 },
            { p = ToPattern(LOOT_ITEM_MULTIPLE),      who = 1, link = 2, count = 3 },
            { p = ToPattern(LOOT_ITEM),               who = 1, link = 2 },
        }
    end
    return lootForms
end

local function ParseLoot(msg)
    for _, form in ipairs(LootForms()) do
        local caps = { msg:match(form.p) }
        local link = caps[form.link]
        if link and link:find("|Hitem:", 1, true) then
            local who = form.who and Ambiguate(caps[form.who], "none") or Me()
            return link, tonumber(form.count and caps[form.count]) or 1, who
        end
    end
end

-- The money line reads "Your share of the loot is 1 Gold, 20 Silver." Rather
-- than match the whole sentence, pick the three amounts out of wherever they
-- land, which also copes with the ones that are left out when they are zero.
local coinPats
local function MoneyFromText(text)
    if not coinPats then
        local function amount(fmt)
            local out = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
            return (out:gsub("%%%%d", "(%%d+)"))
        end
        coinPats = { amount(GOLD_AMOUNT), amount(SILVER_AMOUNT), amount(COPPER_AMOUNT) }
    end
    local g = tonumber(text:match(coinPats[1])) or 0
    local s = tonumber(text:match(coinPats[2])) or 0
    local c = tonumber(text:match(coinPats[3])) or 0
    return g * 10000 + s * 100 + c
end

local function ItemID(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- winner nil means "this dropped, nobody has won it yet"
function LogDrop(link, count, winner)
    if not db.track or not link then return end

    local quality = QualityOf(link)
    if not quality or quality < (db.trackMin or 2) then return end

    local id = ItemID(link)
    if not id then return end

    local entries = db.loot.entries
    -- a count above one settles it; otherwise ask the item itself
    local stacks = (count and count > 1) or IsStackable(link) == true

    if stacks then
        if not winner then return end   -- wait for the loot message to say how many
        for _, e in ipairs(entries) do
            if e.id == id and e.stack then
                e.count, e.t = e.count + count, time()
                -- who took how many, so a stack can still be split back out per
                -- character. A non-stackable row does not need this: it has one
                -- winner and that name is already on it.
                e.by = e.by or {}
                e.by[winner] = (e.by[winner] or 0) + count
                RefreshTracker()
                return
            end
        end
        entries[#entries + 1] = { id = id, link = link, count = count, stack = true,
                                  by = { [winner] = count }, t = time() }
    elseif winner then
        -- fill the oldest row still waiting on this item, so names land in the
        -- order the rolls did rather than backwards
        for _, e in ipairs(entries) do
            if e.id == id and not e.stack and not e.winner
                and (time() - e.t) <= LOOT_MATCH_WINDOW then
                e.winner = winner
                RefreshTracker()
                return
            end
        end
        entries[#entries + 1] = { id = id, link = link, count = 1, winner = winner, t = time() }
    else
        entries[#entries + 1] = { id = id, link = link, count = 1, t = time() }
    end

    db.loot.started = db.loot.started or time()
    while #entries > MAX_LOOT_ROWS do table.remove(entries, 1) end
    Dbg("logged %s x%d winner=%s", tostring(link), count or 1, tostring(winner))
    RefreshTracker()
end

function LogMoney(copper)
    if not db.track or not copper or copper <= 0 then return end
    db.loot.money = (db.loot.money or 0) + copper
    db.loot.started = db.loot.started or time()
    RefreshTracker()
end

function ClearLog()
    db.loot = { entries = {}, money = 0, started = time() }
    RefreshTracker()
    print("|cff66ccffAPLA|r drop log cleared, new session started")
end

----------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------
local button, panel, tracker, RefreshPanel

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

StaticPopupDialogs["AUTOPASSLOOTANNOUNCER_ARM"] = {
    text = "Auto Pass Loot Announcer\n\nArm automated rolling for this session?\n"
        .. "While armed it answers loot rolls for you, by quality and bind type.",
    button1 = "Arm it",
    button2 = "Leave it off",
    OnAccept = function()
        db.autopass = true
        UpdateButtonLook()
        print("|cff66ccffAPLA|r auto-roll |cff00ff00armed|r")
        if panel and panel:IsShown() then RefreshPanel() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,   -- the low indices are the ones that pick up taint
}

local function ButtonTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Auto Pass Loot Announcer")
    GameTooltip:AddDoubleLine("Auto-roll", db.autopass and "|cff00ff00ARMED|r" or "|cffff0000off|r")
    if db.autopass then
        GameTooltip:AddLine(ActionSummary(), 1, 1, 1, true)
    end
    GameTooltip:AddDoubleLine("Announcing to", ChannelSummary())
    if next(peers) then
        local a = Announcer()
        GameTooltip:AddDoubleLine("Announcer", (a == Me()) and "|cff00ff00you|r" or ("|cffffff00" .. tostring(a) .. "|r"))
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffeda55fLeft click|r arm/disarm auto-pass", 1, 1, 1)
    GameTooltip:AddLine("|cffeda55fRight click|r settings", 1, 1, 1)
    GameTooltip:AddLine("|cffeda55fMiddle click|r drop log", 1, 1, 1)
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
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
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
        elseif mouseButton == "MiddleButton" then
            ToggleTracker()
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

-- SetColorTexture is the modern name; the old signature still answers on the
-- clients that predate it, the same way SetObeyStepOnDrag is guarded above.
local function Fill(tex, r, g, b, a)
    if tex.SetColorTexture then
        tex:SetColorTexture(r, g, b, a)
    else
        tex:SetTexture(r, g, b, a)
    end
end

-- A flat block that fills and underlines when it is the one you are on. The
-- caller paints it rather than the widget doing it itself, because the settings
-- panel colours its tabs by quality and the loot log does not.
local function MakeTab(parent, w, h, text)
    local tb = CreateFrame("Button", nil, parent)
    tb:SetSize(w, h)

    tb.bg = tb:CreateTexture(nil, "BACKGROUND")
    tb.bg:SetAllPoints()

    tb.rule = tb:CreateTexture(nil, "ARTWORK")
    tb.rule:SetPoint("BOTTOMLEFT")
    tb.rule:SetPoint("BOTTOMRIGHT")
    tb.rule:SetHeight(2)

    tb.text = tb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tb.text:SetPoint("CENTER", 0, 1)
    tb.text:SetText(text)

    local hl = tb:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    Fill(hl, 1, 1, 1, 0.10)

    return tb
end

local function PaintTab(tb, r, g, b, on)
    Fill(tb.bg,   r, g, b, on and 0.30 or 0.06)
    Fill(tb.rule, r, g, b, on and 1.00 or 0.00)
    tb.text:SetTextColor(r, g, b, on and 1 or 0.5)
end

-- FontStrings take no mouse input, so anything that wants a tooltip gets an
-- invisible frame laid over it.
local function AttachTooltip(frame, title, lines)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title)
        for _, line in ipairs(lines) do
            GameTooltip:AddLine(line, 1, 1, 1, true)   -- true wraps rather than clipping
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function MakeSlider(parent, name, y, minv, maxv, low, high, caption, textFor, set)
    local sl = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
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

local function BuildPanel()
    panel = CreateFrame("Frame", "AutoPassLootAnnouncerPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(340, 516)
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetClampedToScreen(true)
    -- Both of the addon's windows sit in one strata and raise on click. Left on
    -- the default they inherit MEDIUM with frame levels handed out in creation
    -- order, and overlapping them interleaves their children: the checkboxes
    -- here drew straight through the loot log's background.
    panel:SetFrameStrata("DIALOG")
    panel:SetToplevel(true)
    panel:Hide()
    tinsert(UISpecialFrames, "AutoPassLootAnnouncerPanel")   -- Escape closes it

    panel.icon = panel:CreateTexture(nil, "ARTWORK")
    panel.icon:SetSize(26, 26)
    panel.icon:SetPoint("TOPLEFT", 8, -3)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Auto Pass Loot Announcer")

    panel.pass = MakeCheck(panel, "APLACheckPass", "Roll automatically", 16, -34,
        "Master switch for the grid below. With everything set to Pass it just passes on the lot, "
            .. "the same net effect as Blizzard's Pass on Loot checkbox. Never carried between "
            .. "sessions; the button beside this one decides what happens at login.",
        function(v) db.autopass = v; UpdateButtonLook() end)

    -- Sits on the checkbox's own line rather than a row of its own, which keeps
    -- it next to the thing it qualifies and leaves everything below where it is.
    panel.loginArm = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.loginArm:SetSize(120, 20)   -- ends at x=320, inside the frame's inset
    panel.loginArm:SetPoint("TOPLEFT", 200, -33)
    panel.loginArm:SetScript("OnClick", function()
        db.loginArm = NextLoginArm(db.loginArm)
        RefreshPanel()
    end)
    AttachTooltip(panel.loginArm, "At login", {
        "What automated rolling does when you log in or reload. Click to cycle.",
        "|cffffd100Off|r - stays disarmed until you arm it yourself.",
        "|cffffd100On|r - armed straight away.",
        "|cffffd100Ask|r - a prompt each time, so it is never on without you saying so.",
    })

    panel.announce = MakeCheck(panel, "APLACheckAnnounce", "Announce to chat", 16, -60,
        "Off = print to your own chat frame only, nothing is sent to the group.",
        function(v) db.announce = v; SendHello(true) end)

    panel.minimap = MakeCheck(panel, "APLACheckMinimap", "Show minimap button", 16, -86,
        nil,
        function(v)
            db.minimapHide = not v
            if v then button:Show() else button:Hide() end
        end)

    panel.chSlider = MakeSlider(panel, "APLAChannelSlider", -126, 1, 4, "Say", "Yell",
        "Announce up to: ", function(v) return CHANNEL_NAME[v] end,
        function(v) db.channel = v end)
    panel.chSlider.tooltipText = "The widest channel to use. It steps down to whatever is actually available: set to Raid, you get raid in a raid and party in a party."

    panel.slider = MakeSlider(panel, "APLAQualitySlider", -170, 0, 5, "Poor", "Legendary",
        "Announce: ", MinLabel, function(v) db.minQuality = v end)

    panel.summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.summary:SetPoint("TOPLEFT", 24, -326)
    panel.summary:SetWidth(292)
    panel.summary:SetJustifyH("LEFT")

    -- One quality at a time, picked with the tabs. Three kinds across three
    -- qualities laid out flat is nine rows of radio buttons, which made the
    -- panel taller than some people's screens; the summary underneath still
    -- spells out every quality at once, so nothing is hidden, only folded.
    local SelectQuality

    local function UpdateGrid()
        for _, row in ipairs(panel.rows) do
            for i, a in ipairs(ACTIONS) do
                row.buttons[i]:SetChecked((db[row.key][panel.quality] or -1) == a.value)
            end
        end
        panel.summary:SetText(ActionSummary())
    end

    function SelectQuality(q)
        panel.quality = q
        for tq, tb in pairs(panel.tabs) do
            -- the active tab is filled in the quality's own colour and
            -- underlined into the rows below it
            local c = ITEM_QUALITY_COLORS[tq]
            PaintTab(tb, c.r, c.g, c.b, tq == q)
        end
        UpdateGrid()
    end

    panel.UpdateGrid = UpdateGrid
    panel.SelectQuality = SelectQuality

    local gridHead = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gridHead:SetPoint("TOPLEFT", 24, -196)
    gridHead:SetText("What to do with each roll   |cff808080(below "
        .. QUALITY_NAME[MIN_ACTION_QUALITY]:lower() .. ": left alone)|r")

    local headHover = CreateFrame("Frame", nil, panel)
    headHover:SetPoint("TOPLEFT", gridHead, "TOPLEFT", 0, 2)
    headHover:SetSize(gridHead:GetStringWidth(), 16)
    AttachTooltip(headHover, "Roll actions", {
        "Window = do nothing, so the roll window stays on screen for you to answer.",
        "Anything below " .. QUALITY_NAME[MIN_ACTION_QUALITY]:lower()
            .. " is left alone the same way, whatever it binds as.",
    })

    -- Drawn here rather than borrowed from one of Blizzard's tab templates.
    -- Those differ between clients, want the PanelTemplates_ helpers, and are
    -- drawn to hang off the bottom edge of a frame, which is not where these
    -- sit. A block filled in the quality's own colour, underlined into the rows
    -- it controls, says which one you are on without having to be read.
    local TAB_W, TAB_H = 71, 24
    panel.tabs = {}
    for q = MIN_ACTION_QUALITY, 5 do
        local tb = MakeTab(panel, TAB_W, TAB_H, QUALITY_NAME[q])
        tb:SetPoint("TOPLEFT", 22 + (q - MIN_ACTION_QUALITY) * (TAB_W + 3), -212)
        tb:SetScript("OnClick", function() SelectQuality(q) end)
        panel.tabs[q] = tb
    end

    -- a rule across the full width, so the active tab reads as sitting on the
    -- section it opens rather than floating above it
    local tabRule = panel:CreateTexture(nil, "BACKGROUND")
    tabRule:SetPoint("TOPLEFT", 22, -236)
    tabRule:SetPoint("TOPRIGHT", -22, -236)
    tabRule:SetHeight(1)
    Fill(tabRule, 1, 1, 1, 0.12)

    local COLX = { 150, 195, 240, 285 }
    for i, a in ipairs(ACTIONS) do
        local h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOP", panel, "TOPLEFT", COLX[i] + 8, -244)
        h:SetText(a.label)
    end

    -- One row per kind, built once and pointed at whichever quality the tabs
    -- are showing. Each carries a hover explaining what lands in it.
    panel.rows = {}
    for r, kind in ipairs(KINDS) do
        local y = -260 - (r - 1) * 20
        local row = { key = kind.key, buttons = {} }

        row.label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("TOPLEFT", 40, y - 2)
        row.label:SetText(kind.label)

        local hover = CreateFrame("Frame", nil, panel)
        hover:SetPoint("TOPLEFT", 36, y + 1)
        hover:SetSize(108, 18)
        AttachTooltip(hover, kind.label, kind.tip)

        for i, a in ipairs(ACTIONS) do
            local rb = CreateFrame("CheckButton", "APLAAction" .. r .. "_" .. i,
                panel, "UIRadioButtonTemplate")
            rb:SetPoint("TOPLEFT", COLX[i], y)
            rb:SetScript("OnClick", function()
                db[kind.key][panel.quality] = a.value
                UpdateGrid()
            end)
            row.buttons[i] = rb
        end

        panel.rows[r] = row
    end

    SelectQuality(4)   -- epic is the one people actually come here to set

    local prefixLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixLabel:SetPoint("TOPLEFT", 24, -398)
    prefixLabel:SetText("Chat prefix")

    local edit = CreateFrame("EditBox", "APLAPrefixEdit", panel, "InputBoxTemplate")
    edit:SetPoint("TOPLEFT", 96, -394)
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

    panel.pepe = MakeCheck(panel, "APLACheckPepe", "Pepe mode", 16, -446,
        "Puts a random happy pepe in front of the prefix. It shows as a picture for anyone running "
            .. "Twitch Emotes 2.0; everyone else sees the emote name as plain text.",
        function(v) db.pepe = v end)

    panel.track = MakeCheck(panel, "APLACheckTrack", "Track drops", 16, -474,
        "Keeps a list of what dropped this session and who won it. Middle-click the minimap "
            .. "button to open it. The list is kept between logins until you clear it.",
        function(v) db.track = v; RefreshTracker() end)

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
    panel.minimap:SetChecked(not db.minimapHide)
    panel.pepe:SetChecked(db.pepe)
    panel.track:SetChecked(db.track)
    panel.loginArm:SetText("At login: " .. (LOGIN_ARM_LABEL[db.loginArm] or "Off"))
    panel.chSlider:SetValue(db.channel)
    panel.slider:SetValue(db.minQuality)
    panel.SelectQuality(panel.quality or 4)
    panel.edit:SetText(db.prefix)
    UpdateButtonLook()
end

----------------------------------------------------------------
-- Tracker window
----------------------------------------------------------------
-- Row frames are built once and the list is drawn into them as it scrolls, so
-- the only thing resizing has to do is decide how many of them are on show.
-- Forty covers the tallest the window is allowed to get.
local TRACK_ROW_H, MAX_TRACK_ROWS = 18, 40
local TRACK_MIN_W, TRACK_MIN_H = 360, 286
local TRACK_MAX_W, TRACK_MAX_H = 900, 800
local TRACK_LIST_TOP = 78   -- below the title, the tabs and the stats line
local TRACK_FOOTER   = 90   -- room for the threshold slider and the Clear button
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local TRACK_VIEWS = {
    { key = "all",  label = "Everything" },
    { key = "mine", label = "Mine" },
}

-- Built fresh on each redraw rather than kept alongside the real log, so there
-- is only ever one list to keep straight. A stack is split back out through the
-- per-winner counts on the row.
--
-- The result comes back in the order it is drawn: stacked rows first, then the
-- rest, newest first within each. Stacks are the part of the list that stays
-- the same length however long the night runs, so they belong at the top where
-- they can be read at a glance instead of scrolled past.
local function ViewEntries()
    local all  = db.loot.entries
    local mine = tracker.view == "mine"
    local me   = mine and Me() or nil

    local stacks, singles = {}, {}
    for i = #all, 1, -1 do   -- newest first
        local e = all[i]
        if e.stack then
            if not mine then
                stacks[#stacks + 1] = e
            else
                local n = e.by and e.by[me]
                if n and n > 0 then
                    stacks[#stacks + 1] =
                        { id = e.id, link = e.link, count = n, stack = true, t = e.t }
                end
            end
        elseif not mine or e.winner == me then
            singles[#singles + 1] = e
        end
    end

    for _, e in ipairs(singles) do stacks[#stacks + 1] = e end
    return stacks
end

local function LayoutTracker()
    if not tracker or not tracker.rows then return end

    local w, h = tracker:GetWidth(), tracker:GetHeight()
    local shown = math.floor((h - TRACK_LIST_TOP - TRACK_FOOTER) / TRACK_ROW_H)
    if shown < 1 then shown = 1 end
    if shown > MAX_TRACK_ROWS then shown = MAX_TRACK_ROWS end
    tracker.visibleRows = shown

    tracker.stats:SetWidth(w - 30)
    tracker.scroll:SetSize(w - 50, shown * TRACK_ROW_H)   -- less the scrollbar
    tracker.slider:SetWidth(w - 150)                      -- less the Clear button

    local rowW = w - 70
    for _, row in ipairs(tracker.rows) do
        row:SetWidth(rowW)
        row.text:SetWidth(rowW - 130)   -- icon, gap and the winner column
    end

    RefreshTracker()
end

local function BuildTracker()
    tracker = CreateFrame("Frame", "AutoPassLootAnnouncerTracker", UIParent,
        "BasicFrameTemplateWithInset")
    tracker:SetSize(db.trackerSize and db.trackerSize.w or 440,
                    db.trackerSize and db.trackerSize.h or 430)
    tracker:SetPoint("CENTER")
    tracker:SetMovable(true)
    tracker:SetResizable(true)
    -- SetResizeBounds is the modern name for the pair below it, guarded the way
    -- SetObeyStepOnDrag and SetColorTexture are
    if tracker.SetResizeBounds then
        tracker:SetResizeBounds(TRACK_MIN_W, TRACK_MIN_H, TRACK_MAX_W, TRACK_MAX_H)
    else
        tracker:SetMinResize(TRACK_MIN_W, TRACK_MIN_H)
        tracker:SetMaxResize(TRACK_MAX_W, TRACK_MAX_H)
    end
    tracker:EnableMouse(true)
    tracker:RegisterForDrag("LeftButton")
    tracker:SetScript("OnDragStart", tracker.StartMoving)
    tracker:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        db.trackerPos = { point = point, rel = rel, x = x, y = y }
    end)
    tracker:SetClampedToScreen(true)
    tracker:SetFrameStrata("DIALOG")   -- same strata as the settings panel, see there
    tracker:SetToplevel(true)
    tracker:Hide()
    tinsert(UISpecialFrames, "AutoPassLootAnnouncerTracker")   -- Escape closes it

    if db.trackerPos then
        tracker:ClearAllPoints()
        tracker:SetPoint(db.trackerPos.point, UIParent, db.trackerPos.rel,
            db.trackerPos.x, db.trackerPos.y)
    end

    local title = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Session loot")

    -- "Mine" is this character, not the account. The log is shared between your
    -- characters and a winner's name is the only thing that says whose a drop
    -- was, so it can only ever answer per character.
    local function SelectView(key)
        tracker.view = key
        db.trackerView = key
        for i, v in ipairs(TRACK_VIEWS) do
            PaintTab(tracker.tabs[i], 1, 0.82, 0, v.key == key)
        end
        local bar = _G["APLATrackerScrollScrollBar"]
        if bar then bar:SetValue(0) end   -- a new list starts at the top
        RefreshTracker()
    end

    tracker.tabs = {}
    for i, v in ipairs(TRACK_VIEWS) do
        local tb = MakeTab(tracker, 104, 22, v.label)
        tb:SetPoint("TOPLEFT", 14 + (i - 1) * 107, -32)
        tb:SetScript("OnClick", function() SelectView(v.key) end)
        tracker.tabs[i] = tb
    end

    tracker.stats = tracker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tracker.stats:SetPoint("TOPLEFT", 14, -58)
    tracker.stats:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", "APLATrackerScroll", tracker,
        "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -TRACK_LIST_TOP)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, TRACK_ROW_H, RefreshTracker)
    end)
    tracker.scroll = scroll

    tracker.rows = {}
    for i = 1, MAX_TRACK_ROWS do
        local row = CreateFrame("Button", nil, tracker)
        row:SetHeight(TRACK_ROW_H)
        row:SetPoint("TOPLEFT", 14, -TRACK_LIST_TOP - (i - 1) * TRACK_ROW_H)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", 0, 0)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 20, 0)
        row.text:SetJustifyH("LEFT")

        row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.who:SetPoint("RIGHT", -4, 0)
        row.who:SetWidth(100)
        row.who:SetJustifyH("RIGHT")

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Fill(hl, 1, 1, 1, 0.08)

        row:SetScript("OnEnter", function(self)
            if not self.link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- shift-click drops the link into whatever you are typing, the same way
        -- clicking an item anywhere else in the UI does
        row:SetScript("OnClick", function(self)
            if self.link then HandleModifiedItemClick(self.link) end
        end)

        row:Hide()
        tracker.rows[i] = row
    end

    -- the threshold lives here rather than in the settings panel: this is the
    -- window where you notice the list filling up with things you do not want
    tracker.slider = MakeSlider(tracker, "APLATrackSlider", 0, 0, 5, "Poor", "Legendary",
        "Log: ", MinLabel, function(v) db.trackMin = v end)
    tracker.slider:ClearAllPoints()   -- bottom-anchored, so resizing leaves it alone
    tracker.slider:SetPoint("BOTTOMLEFT", 24, 52)

    local clear = CreateFrame("Button", nil, tracker, "UIPanelButtonTemplate")
    clear:SetSize(90, 22)
    clear:SetPoint("BOTTOMRIGHT", -26, 12)   -- clear of the resize grip
    clear:SetText("Clear")
    clear.tooltipText = "Empties the log and starts a new session."
    clear:SetScript("OnClick", function() ClearLog() end)

    local grip = CreateFrame("Button", nil, tracker)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() tracker:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        tracker:StopMovingOrSizing()
        db.trackerSize = { w = tracker:GetWidth(), h = tracker:GetHeight() }
        LayoutTracker()
    end)

    tracker:SetScript("OnSizeChanged", LayoutTracker)
    tracker:SetScript("OnShow", function() RefreshTracker() end)
    SelectView(db.trackerView == "mine" and "mine" or "all")
    LayoutTracker()
end

function RefreshTracker()
    if not tracker or not tracker:IsShown() then return end

    local entries = ViewEntries()
    local n = #entries
    local shown = tracker.visibleRows or 1

    local when = db.loot.started and date("%d %b %H:%M", db.loot.started) or "nothing yet"
    tracker.stats:SetText(("%d %s since %s          %s%s"):format(
        n, n == 1 and "line" or "lines", when,
        GetCoinTextureString(db.loot.money or 0),
        db.track and "" or "   |cffff8000(tracking is off)|r"))

    FauxScrollFrame_Update(tracker.scroll, n, shown, TRACK_ROW_H)
    local offset = FauxScrollFrame_GetOffset(tracker.scroll)

    for i, row in ipairs(tracker.rows) do
        local e = (i <= shown) and entries[offset + i] or nil   -- already in draw order
        if e then
            row.link = e.link
            row.icon:SetTexture(select(10, GetItemInfo(e.link)) or UNKNOWN_ICON)
            row.text:SetText(e.count > 1 and (e.link .. " |cffffffffx" .. e.count .. "|r") or e.link)
            if tracker.view == "mine" then
                row.who:SetText(e.stack and "|cff808080your share|r" or "|cff808080yours|r")
            elseif e.stack then
                row.who:SetText("|cff808080stacked|r")
            elseif e.winner then
                row.who:SetText("|cffffff00" .. e.winner .. "|r")
            else
                row.who:SetText("|cff808080nobody|r")
            end
            row:Show()
        else
            row.link = nil
            row:Hide()
        end
    end

    tracker.slider:SetValue(db.trackMin or 2)
end

function ToggleTracker()
    if not tracker then return end
    if tracker:IsShown() then tracker:Hide() else tracker:Show() end
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CONFIRM_LOOT_ROLL")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_LOOT")
f:RegisterEvent("CHAT_MSG_MONEY")

f:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        AutoPassLootAnnouncerDB = AutoPassLootAnnouncerDB or {}
        db = AutoPassLootAnnouncerDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end

        if type(db.actionsBoP) ~= "table" or type(db.actionsBoE) ~= "table" then
            -- Whatever the last version stored goes to both bind types, so the
            -- upgrade changes nothing until you split the two yourself.
            local from = type(db.actions) == "table" and db.actions or nil
            if not from then
                -- older still: the need/greed/pass band settings
                local need, greed, pass = db.needMax or -1, db.greedMax or -1, db.passMax or 5
                from = {}
                for q = 0, 5 do
                    local a = -1
                    if     q <= need  then a = 1
                    elseif q <= greed then a = 2
                    elseif q <= pass  then a = 0 end
                    from[q + 1] = a
                end
            end
            db.actionsBoP, db.actionsBoE = {}, {}
            for q = MIN_ACTION_QUALITY, 5 do
                local a = from[q + 1]
                if a == nil then a = DEFAULT_ACTION end
                db.actionsBoP[q], db.actionsBoE[q] = a, a
            end
            db.needMax, db.greedMax, db.passMax = nil, nil, nil
        end

        -- The stackable BoE row arrived after the other two, so a file written
        -- before it has no table for it. Seed it from the plain BoE row, which
        -- is what stackable BoE drops were being answered with until now.
        if type(db.actionsBoEStack) ~= "table" then
            db.actionsBoEStack = {}
            for q = MIN_ACTION_QUALITY, 5 do
                db.actionsBoEStack[q] = db.actionsBoE[q]
            end
        end

        -- Fill any gap a file written by an older layout is short of, and drop
        -- the rows below rare that 1.3.x kept: those qualities are left alone
        -- now, so a stored setting for them would never be read again.
        for _, kind in ipairs(KINDS) do
            for q = MIN_ACTION_QUALITY, 5 do
                if db[kind.key][q] == nil then db[kind.key][q] = DEFAULT_ACTION end
            end
            for q = 0, MIN_ACTION_QUALITY - 1 do db[kind.key][q] = nil end
        end

        -- never remembered between sessions. Whether it comes back on is the
        -- "At login" setting's business, handled at PLAYER_LOGIN once the rest
        -- of the addon is up.
        db.autopass = false

        -- dropped settings, cleared out of a saved file written by an older version
        db.fromCorpse, db.coop, db.actions = nil, nil, nil

        if type(db.loot) ~= "table" then db.loot = {} end
        db.loot.entries = db.loot.entries or {}
        db.loot.money   = db.loot.money or 0

        BuildButton()
        BuildPanel()
        BuildTracker()
        UpdateButtonLook()

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(COMM_PREFIX)
        end

    elseif event == "CHAT_MSG_LOOT" then
        local link, count, who = ParseLoot(arg1 or "")
        if link then LogDrop(link, count, who) end

    elseif event == "CHAT_MSG_MONEY" then
        LogMoney(MoneyFromText(arg1 or ""))

    elseif event == "GROUP_ROSTER_UPDATE" then
        PruneToGroup()
        SendHello()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, _, sender = arg1, arg2, arg3, arg4
        if prefix ~= COMM_PREFIX then return end
        sender = Ambiguate(sender, "none")
        if sender == Me() then return end

        if message == "H?" then
            -- someone has lost track of the group and wants a recount
            C_Timer.After(0.5 + math.random() * 2, function() SendHello(true) end)
            return
        end

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
        -- no math.randomseed here: the client already seeds math.random, and
        -- Blizzard removed randomseed from the addon environment
        SendHello(true)
        C_Timer.NewTicker(HELLO_INTERVAL, function()
            if GroupChannel() then SendHello(true) end
        end)

        if db.loginArm == "on" then
            db.autopass = true
            UpdateButtonLook()
        end

        print("|cff66ccffAutoPassLootAnnouncer|r loaded. Auto-roll "
            .. (db.autopass and "|cff00ff00armed|r" or "|cffff0000off|r")
            .. " - left-click the minimap button to change it.")

        if db.loginArm == "ask" then
            -- fired at PLAYER_LOGIN it lands behind the loading screen, so give
            -- the client a moment to finish getting out of the way
            C_Timer.After(3, function() StaticPopup_Show("AUTOPASSLOOTANNOUNCER_ARM") end)
        end

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
    elseif cmd == "quality" and tonumber(val) then
        db.minQuality = tonumber(val)
    elseif cmd == "set" then
        local bind, q, act = val:match("^(%a+)%s+(%d)%s+(%a+)$")
        local map   = { window = -1, leave = -1, pass = 0, need = 1, greed = 2 }
        local ALL = { "actionsBoP", "actionsBoE", "actionsBoEStack" }
        local binds = {
            bop   = { keys = { "actionsBoP" },      label = "BoP" },
            boe   = { keys = { "actionsBoE" },      label = "BoE" },
            stack = { keys = { "actionsBoEStack" }, label = "BoE stack" },
            all   = { keys = ALL,                   label = "every kind" },
            both  = { keys = ALL,                   label = "every kind" },   -- pre-1.4 name
        }
        local b = binds[bind or ""]
        q = tonumber(q)
        if b and q and q >= MIN_ACTION_QUALITY and q <= 5 and map[act or ""] then
            -- below the split every bind type shares one setting, so whichever
            -- one was typed writes the pair
            for _, key in ipairs(b.keys) do db[key][q] = map[act] end
            print(("|cff66ccffAPLA|r %s %s: %s"):format(b.label, QualityLabel(q), ACTION_VERB[map[act]]))
        else
            print(("|cff66ccffAPLA|r /apla set <bop|boe|stack|all> <%d-5> <window|pass|greed|need>")
                :format(MIN_ACTION_QUALITY))
        end
    elseif cmd == "who" then
        SendHello(true)
        RequestHellos()
        local who, now = Announcer(), GetTime()
        print(("|cff66ccffAPLA|r announcer: %s%s"):format(
            tostring(who), who == Me() and " |cff00ff00(you)|r" or ""))
        if not next(peers) then
            print("  no other copies heard from")
        end
        for name, info in pairs(peers) do
            local age = now - info.seen
            print(("  %s  willing=%s  heard %ds ago%s"):format(
                name, tostring(info.willing), math.floor(age),
                age >= PEER_TIMEOUT and "  |cffff0000timed out|r" or ""))
        end
    elseif cmd == "login" then
        if LOGIN_ARM_LABEL[val] then
            db.loginArm = val
            print("|cff66ccffAPLA|r at login: " .. LOGIN_ARM_LABEL[val])
        else
            print("|cff66ccffAPLA|r /apla login off|on|ask")
        end
    elseif cmd == "loot" then
        ToggleTracker()
        return
    elseif cmd == "track" then
        db.track = not db.track
        print("|cff66ccffAPLA|r drop tracking: " .. tostring(db.track))
        RefreshTracker()
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
