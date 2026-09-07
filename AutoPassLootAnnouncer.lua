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
    -- presets = { { name = ..., values = { ... } } } with activePreset pointing
    -- into it, built in ADDON_LOADED out of whatever is already set
}

-- What a preset carries: everything that decides what gets announced and what
-- gets rolled. Deliberately not in here are the things that belong to the
-- account rather than to a role you switch into -- where the windows sit,
-- whether the minimap button is shown, the drop log itself, the debug flag --
-- and not `autopass` either, which is forced off at every login and so is
-- never a stored setting in the first place.
local PRESET_KEYS = {
    "announce", "channel", "minQuality", "prefix", "pepe", "loginArm",
    "track", "trackMin", "actionsBoP", "actionsBoE", "actionsBoEStack",
}

local db   -- declared before anything that reads it, or it resolves to a nil global

-- Redrawing everything a preset can have changed. Defined down with the
-- windows, once there is something to redraw.
local RefreshAll

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

----------------------------------------------------------------
-- Presets
----------------------------------------------------------------
-- Presets are profiles rather than saved snapshots: the live settings *are*
-- the active preset, so anything you change is already in it and there is no
-- Save button to forget. Switching files the settings you are leaving back
-- into the preset they came from first.
--
-- The live copy stays at the root of the saved variables, where it has always
-- been, rather than moving inside the preset that owns it. Every read of a
-- setting is still a plain db.channel, a file written by an earlier version
-- loads unchanged, and a file written by this one still loads in that version.
-- What it costs is that the active preset's stored values are a stale copy of
-- the live ones; nothing reads them, because a preset's values are only ever
-- read on the way in.
local DEFAULT_PRESET_NAME = "Preset 1"
local MAX_PRESET_NAME = 24

local function CloneValues(src)
    local out = {}
    for _, key in ipairs(PRESET_KEYS) do
        local v = src[key]
        if type(v) == "table" then
            local t = {}
            for k, tv in pairs(v) do t[k] = tv end
            out[key] = t
        elseif v ~= nil then
            out[key] = v
        end
    end
    return out
end

-- Every quality in every kind ends up with an action, whatever the thing we
-- read it from was short of: an older saved layout, a preset written before a
-- kind existed, or a share code that never carried one.
local function FillActions()
    for _, kind in ipairs(KINDS) do
        if type(db[kind.key]) ~= "table" then db[kind.key] = {} end
        for q = MIN_ACTION_QUALITY, 5 do
            if db[kind.key][q] == nil then db[kind.key][q] = DEFAULT_ACTION end
        end
        -- the rows below the grid that 1.3.x kept: those qualities are left
        -- alone now, so a stored setting for them would never be read again
        for q = 0, MIN_ACTION_QUALITY - 1 do db[kind.key][q] = nil end
    end
end

local function ActivePreset()
    return db.presets and db.presets[db.activePreset]
end

local function ActivePresetName()
    local p = ActivePreset()
    return p and p.name or DEFAULT_PRESET_NAME
end

-- files the settings you have right now back into the preset they belong to
local function StoreActive()
    local p = ActivePreset()
    if p then p.values = CloneValues(db) end
end

local function ApplyValues(values)
    for _, key in ipairs(PRESET_KEYS) do
        local v = values and values[key]
        if v == nil then v = defaults[key] end   -- a preset short of one takes the default
        if type(v) == "table" then
            local t = {}
            for k, tv in pairs(v) do t[k] = tv end
            db[key] = t
        else
            db[key] = v
        end
    end
    -- the action tables are not in `defaults` (a table there would be shared by
    -- reference), so anything missing lands here as nil and is filled in
    FillActions()
end

local function EnsurePresets()
    if type(db.presets) ~= "table" then db.presets = {} end

    -- Throw out anything not shaped like a preset, so a hand-edited or
    -- half-written file cannot leave the menu with a hole in it.
    for i = #db.presets, 1, -1 do
        local p = db.presets[i]
        if type(p) ~= "table" or type(p.name) ~= "string" or type(p.values) ~= "table" then
            table.remove(db.presets, i)
        end
    end

    if #db.presets == 0 then
        -- First run under this version: whatever is set right now becomes the
        -- one preset, so nothing changes for anyone who never opens the menu.
        db.presets[1] = { name = DEFAULT_PRESET_NAME, values = CloneValues(db) }
        db.activePreset = 1
    end

    db.activePreset = tonumber(db.activePreset) or 1
    if not db.presets[db.activePreset] then db.activePreset = 1 end
end

local function CleanName(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil end
    return name:sub(1, MAX_PRESET_NAME)
end

-- "Preset 3" when 1 and 2 are taken, whatever they have since been renamed to
local function SuggestName()
    local taken = {}
    for _, p in ipairs(db.presets) do taken[p.name:lower()] = true end
    local n = #db.presets + 1
    while taken[("preset %d"):format(n)] do n = n + 1 end
    return ("Preset %d"):format(n)
end

-- Two presets under one name makes the menu unreadable and a lookup by name
-- ambiguous, so a clash takes a number instead of being allowed to happen.
-- `skip` is the preset being renamed, which does not clash with itself.
local function UniqueName(name, skip)
    local taken = {}
    for i, p in ipairs(db.presets) do
        if i ~= skip then taken[p.name:lower()] = true end
    end
    if not taken[name:lower()] then return name end
    local n = 2
    while taken[(("%s %d"):format(name, n)):lower()] do n = n + 1 end
    return ("%s %d"):format(name, n)
end

-- an index or a name, so the slash command takes whichever you have to hand
local function FindPreset(want)
    local i = tonumber(want)
    if i and db.presets[i] then return i end
    want = tostring(want or ""):lower()
    if want == "" then return nil end
    for j, p in ipairs(db.presets) do
        if p.name:lower() == want then return j end
    end
    return nil
end

local function SelectPreset(i)
    local p = db.presets[i]
    if not p then return false end
    if i ~= db.activePreset then
        StoreActive()
        db.activePreset = i
        ApplyValues(p.values)
    end
    if RefreshAll then RefreshAll() end
    print("|cff66ccffAPLA|r preset: |cffffd100" .. p.name .. "|r")
    return true
end

local function NewPreset(name)
    name = UniqueName(CleanName(name) or SuggestName())
    StoreActive()
    db.presets[#db.presets + 1] = { name = name, values = CloneValues(db) }
    db.activePreset = #db.presets
    -- a copy of what is already live, so there is nothing to apply
    if RefreshAll then RefreshAll() end
    print(("|cff66ccffAPLA|r new preset |cffffd100%s|r, a copy of your current settings")
        :format(name))
    return db.activePreset
end

local function RenameActive(name)
    name = CleanName(name)
    local p = ActivePreset()
    if not name or not p then return false end
    local was = p.name
    p.name = UniqueName(name, db.activePreset)
    if RefreshAll then RefreshAll() end
    print(("|cff66ccffAPLA|r preset |cffffd100%s|r is now |cffffd100%s|r"):format(was, p.name))
    return true
end

local function DeletePreset(i)
    if not db.presets[i] then return false end
    if #db.presets <= 1 then
        print("|cff66ccffAPLA|r there has to be one preset left")
        return false
    end

    local gone = db.presets[i].name
    local wasActive = (i == db.activePreset)
    table.remove(db.presets, i)

    if wasActive then
        -- whichever one took its place in the list, or the last one if the one
        -- deleted was the last
        db.activePreset = math.min(i, #db.presets)
        ApplyValues(db.presets[db.activePreset].values)
    elseif db.activePreset > i then
        db.activePreset = db.activePreset - 1   -- everything after it shifted down
    end

    if RefreshAll then RefreshAll() end
    print(("|cff66ccffAPLA|r deleted |cffffd100%s|r, now on |cffffd100%s|r")
        :format(gone, ActivePresetName()))
    return true
end

----------------------------------------------------------------
-- Share codes
----------------------------------------------------------------
-- One line you can paste into chat or a forum post. Labelled fields rather
-- than a positional CSV: a positional line breaks the moment a setting is
-- added in the middle of it, where an unknown label can simply be ignored and
-- a missing one falls back to the default. The version at the front is so a
-- code that genuinely cannot be read says so instead of half-importing.
local CODE_TAG     = "APLA"
local CODE_VERSION = 1

-- One letter per action, so an action string reads as itself: bop=wppg is
-- window, pass, pass, greed for uncommon, rare, epic and legendary.
local ACTION_CODE = { [-1] = "w", [0] = "p", [1] = "n", [2] = "g" }
local CODE_ACTION = { w = -1, p = 0, n = 1, g = 2 }

-- Everything but letters, digits and -_. is escaped, so a code comes out as
-- one whitespace-free token that survives any copy and paste. Names and
-- prefixes are short, so being blunt about it costs a few percent signs.
local function Esc(s)
    return (tostring(s or ""):gsub("[^%w%-_%.]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

local function Unesc(s)
    return (tostring(s or ""):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function EncodeActions(t)
    local out = {}
    for q = MIN_ACTION_QUALITY, 5 do
        out[#out + 1] = ACTION_CODE[t and t[q]] or ACTION_CODE[DEFAULT_ACTION]
    end
    return table.concat(out)
end

local function DecodeActions(s)
    local t = {}
    for q = MIN_ACTION_QUALITY, 5 do
        local at = q - MIN_ACTION_QUALITY + 1
        t[q] = CODE_ACTION[s:sub(at, at)] or DEFAULT_ACTION
    end
    return t
end

local function EncodePreset(name, v)
    local parts = {
        ("n=%s"):format(Esc(name)),
        ("a=%d"):format(v.announce and 1 or 0),
        ("c=%d"):format(tonumber(v.channel) or defaults.channel),
        ("q=%d"):format(tonumber(v.minQuality) or defaults.minQuality),
        ("pe=%d"):format(v.pepe and 1 or 0),
        ("t=%d"):format(v.track and 1 or 0),
        ("tq=%d"):format(tonumber(v.trackMin) or defaults.trackMin),
        ("la=%s"):format(LOGIN_ARM_LABEL[v.loginArm or ""] and v.loginArm or defaults.loginArm),
        ("bop=%s"):format(EncodeActions(v.actionsBoP)),
        ("boe=%s"):format(EncodeActions(v.actionsBoE)),
        ("bes=%s"):format(EncodeActions(v.actionsBoEStack)),
        -- last, because it is the only field whose length is worth reading past
        ("p=%s"):format(Esc(v.prefix)),
    }
    return ("%s%d:%s"):format(CODE_TAG, CODE_VERSION, table.concat(parts, ","))
end

-- Returns name, values, version -- or nil and something to print. Unknown
-- fields are ignored and missing ones left to the default, so a code from a
-- later version still imports as much of itself as this one understands.
local function DecodePreset(code)
    code = tostring(code or ""):gsub("%s+", "")
    local ver, body = code:match("^" .. CODE_TAG .. "(%d+):(.+)$")
    if not ver then
        return nil, ("that does not look like a preset code, they start with %s%d:")
            :format(CODE_TAG, CODE_VERSION)
    end

    local f = {}
    for key, value in body:gmatch("(%w+)=([^,]*)") do f[key] = value end
    if not next(f) then return nil, "that code has no settings in it" end

    local function num(key, lo, hi, fallback)
        local n = tonumber(f[key])
        if not n then return fallback end
        n = math.floor(n)
        if n < lo or n > hi then return fallback end
        return n
    end

    local function flag(key, fallback)
        if f[key] == "1" then return true end
        if f[key] == "0" then return false end
        return fallback
    end

    local v = {
        announce   = flag("a", defaults.announce),
        channel    = num("c", 1, 4, defaults.channel),
        minQuality = num("q", 0, 5, defaults.minQuality),
        pepe       = flag("pe", defaults.pepe),
        track      = flag("t", defaults.track),
        trackMin   = num("tq", 0, 5, defaults.trackMin),
        loginArm   = LOGIN_ARM_LABEL[f.la or ""] and f.la or defaults.loginArm,
        prefix     = f.p and Unesc(f.p) or defaults.prefix,
        actionsBoP      = DecodeActions(f.bop or ""),
        actionsBoE      = DecodeActions(f.boe or ""),
        actionsBoEStack = DecodeActions(f.bes or ""),
    }
    return CleanName(f.n and Unesc(f.n)) or "Imported", v, tonumber(ver)
end

-- The active preset is the live settings, so its code comes off db rather than
-- out of the stored copy, which is stale by design.
local function ActiveCode()
    return EncodePreset(ActivePresetName(), db)
end

-- Always a new preset, never over the top of one you already have: an import
-- is the one thing here that arrives from outside and cannot be undone.
local function ImportCode(code)
    local name, v, ver = DecodePreset(code)
    if not name then return false, v end
    if ver > CODE_VERSION then
        print(("|cff66ccffAPLA|r that code was written by a newer version (%d), importing "
            .. "the parts this one understands"):format(ver))
    end

    StoreActive()
    db.presets[#db.presets + 1] = { name = UniqueName(name), values = v }
    db.activePreset = #db.presets
    ApplyValues(v)
    if RefreshAll then RefreshAll() end
    print(("|cff66ccffAPLA|r imported |cffffd100%s|r and switched to it")
        :format(db.presets[db.activePreset].name))
    return true
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
    GameTooltip:AddDoubleLine("Preset", "|cffffd100" .. ActivePresetName() .. "|r")
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

-- Height the preset bar adds to the top of the settings panel. Everything that
-- was already in the panel hangs off a container shifted down by this much, so
-- adding the bar cost one number rather than every coordinate underneath it.
local PRESET_BAR_H = 34

local presetCode           -- the share-code window, built alongside the panel
local TogglePresetCode     -- defined with it, used by the panel and the menu

StaticPopupDialogs["AUTOPASSLOOTANNOUNCER_PRESET_NEW"] = {
    text = "Name for the new preset\n\nIt starts as a copy of the settings you have now.",
    button1 = "Create",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = MAX_PRESET_NAME,
    OnShow = function(self)
        local e = self.editBox or _G[self:GetName() .. "EditBox"]
        e:SetText(SuggestName())
        e:HighlightText()
        e:SetFocus()
    end,
    OnAccept = function(self)
        local e = self.editBox or _G[self:GetName() .. "EditBox"]
        NewPreset(e:GetText())
    end,
    -- EditBox handlers are handed the box, not the popup
    EditBoxOnEnterPressed = function(self)
        NewPreset(self:GetText())
        self:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,   -- the low indices are the ones that pick up taint
}

StaticPopupDialogs["AUTOPASSLOOTANNOUNCER_PRESET_RENAME"] = {
    text = "Rename the preset\n\nIt is called %s now.",
    button1 = "Rename",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = MAX_PRESET_NAME,
    OnShow = function(self)
        local e = self.editBox or _G[self:GetName() .. "EditBox"]
        e:SetText(ActivePresetName())
        e:HighlightText()
        e:SetFocus()
    end,
    OnAccept = function(self)
        local e = self.editBox or _G[self:GetName() .. "EditBox"]
        RenameActive(e:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        RenameActive(self:GetText())
        self:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["AUTOPASSLOOTANNOUNCER_PRESET_DELETE"] = {
    text = "Delete the preset %s?\n\nEverything set in it goes with it. Take its code first "
        .. "if you might want it back.",
    button1 = "Delete",
    button2 = "Cancel",
    -- the index is passed as StaticPopup_Show's data argument rather than read
    -- off db here, so the prompt deletes the preset it was raised for
    OnAccept = function(self) DeletePreset(self.data) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- The presets themselves, then what you can do to them. One menu rather than a
-- row of buttons: the list is the thing you came for and the rest is rare.
local function PresetMenu(_, level)
    level = level or 1
    if level ~= 1 then return end

    local function Add(fields)
        local info = UIDropDownMenu_CreateInfo()
        for k, v in pairs(fields) do info[k] = v end
        UIDropDownMenu_AddButton(info, level)
    end

    for i, p in ipairs(db.presets) do
        Add({
            text = p.name,
            checked = (i == db.activePreset),
            func = function()
                SelectPreset(i)
                CloseDropDownMenus()
            end,
        })
    end

    Add({ text = "", isTitle = true, notCheckable = true, disabled = true })   -- a rule

    Add({
        text = "New from current...",
        notCheckable = true,
        func = function() StaticPopup_Show("AUTOPASSLOOTANNOUNCER_PRESET_NEW") end,
    })

    Add({
        text = "Rename...",
        notCheckable = true,
        func = function()
            StaticPopup_Show("AUTOPASSLOOTANNOUNCER_PRESET_RENAME", ActivePresetName())
        end,
    })

    Add({
        text = "Delete " .. ActivePresetName(),
        notCheckable = true,
        -- there has to be one left, and the only one on offer here is the one
        -- you are on, so with a single preset there is nothing to delete
        disabled = #db.presets <= 1,
        func = function()
            StaticPopup_Show("AUTOPASSLOOTANNOUNCER_PRESET_DELETE",
                ActivePresetName(), nil, db.activePreset)
        end,
    })

    Add({
        text = "Share code...",
        notCheckable = true,
        -- the menu is the only way to the code window, so the explanation of
        -- what one is for rides along here
        tooltipTitle = "Preset code",
        tooltipText = "One line carrying this whole preset, to paste into chat "
            .. "or take from someone who did.",
        tooltipOnButton = true,
        func = function()
            CloseDropDownMenus()
            TogglePresetCode()
        end,
    })
end

-- The box always opens on your own code, so the window is a share button first
-- and an import field second.
local function RefreshPresetCode()
    if not presetCode then return end
    presetCode.box:SetText(ActiveCode())
    presetCode.box:HighlightText()
    presetCode.box:SetFocus()
end

local function BuildPresetCode()
    presetCode = CreateFrame("Frame", "AutoPassLootAnnouncerPresetCode", UIParent,
        "BasicFrameTemplateWithInset")
    presetCode:SetSize(420, 224)
    presetCode:SetPoint("CENTER")
    presetCode:SetMovable(true)
    presetCode:EnableMouse(true)
    presetCode:RegisterForDrag("LeftButton")
    presetCode:SetScript("OnDragStart", presetCode.StartMoving)
    presetCode:SetScript("OnDragStop", presetCode.StopMovingOrSizing)
    presetCode:SetClampedToScreen(true)
    presetCode:SetFrameStrata("DIALOG")   -- the same strata as the other two, see the panel
    presetCode:SetToplevel(true)
    presetCode:Hide()
    tinsert(UISpecialFrames, "AutoPassLootAnnouncerPresetCode")   -- Escape closes it

    local title = presetCode:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Preset code")

    local help = presetCode:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 14, -30)
    help:SetPoint("TOPRIGHT", -14, -30)
    help:SetJustifyH("LEFT")
    help:SetText("Ctrl+A then Ctrl+C copies the line below. Paste someone else's in instead "
        .. "and Import adds it as a new preset, leaving the ones you have alone.")

    -- A dark box with a hairline round it, holding the one thing this window is
    -- for. A code is a line or two long, so it fits without a scroll frame.
    local well = CreateFrame("Frame", nil, presetCode)
    well:SetPoint("TOPLEFT", 14, -78)
    well:SetPoint("BOTTOMRIGHT", -14, 44)

    local edge = well:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    Fill(edge, 1, 1, 1, 0.14)

    local inner = well:CreateTexture(nil, "BORDER")
    inner:SetPoint("TOPLEFT", 1, -1)
    inner:SetPoint("BOTTOMRIGHT", -1, 1)
    Fill(inner, 0, 0, 0, 0.72)

    local box = CreateFrame("EditBox", nil, well)
    box:SetPoint("TOPLEFT", 5, -4)
    box:SetPoint("BOTTOMRIGHT", -5, 4)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    presetCode.box = box

    local mine = CreateFrame("Button", nil, presetCode, "UIPanelButtonTemplate")
    mine:SetSize(100, 22)
    mine:SetPoint("BOTTOMLEFT", 14, 12)
    mine:SetText("Show mine")
    mine.tooltipText = "Put your own code back in the box."
    mine:SetScript("OnClick", RefreshPresetCode)

    local import = CreateFrame("Button", nil, presetCode, "UIPanelButtonTemplate")
    import:SetSize(150, 22)
    import:SetPoint("BOTTOMRIGHT", -14, 12)
    import:SetText("Import as new preset")
    import:SetScript("OnClick", function()
        local ok, err = ImportCode(box:GetText())
        if ok then
            presetCode:Hide()
        else
            print("|cff66ccffAPLA|r " .. tostring(err))
        end
    end)

    presetCode:SetScript("OnShow", RefreshPresetCode)
end

function TogglePresetCode()
    if not presetCode then return end
    if presetCode:IsShown() then presetCode:Hide() else presetCode:Show() end
end

local function BuildPanel()
    panel = CreateFrame("Frame", "AutoPassLootAnnouncerPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(340, 516 + PRESET_BAR_H)
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

    -- Centred on the title text rather than hung off the top edge, and small
    -- enough to sit inside the title bar: at 26 it hung far enough below the
    -- bar to overlap the inset behind it.
    panel.icon = panel:CreateTexture(nil, "ARTWORK")
    panel.icon:SetSize(18, 18)
    panel.icon:SetPoint("LEFT", panel, "TOPLEFT", 8, -12)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Auto Pass Loot Announcer")

    -- The preset bar, and then everything that was already here below it.
    local presetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    presetLabel:SetPoint("TOPLEFT", 20, -36)
    presetLabel:SetText("Preset")

    -- Takes the whole row, now that the menu is the only way in and there is
    -- nothing sitting beside it. Ends level with the At login button below.
    panel.presetDD = CreateFrame("Frame", "APLAPresetDropDown", panel, "UIDropDownMenuTemplate")
    panel.presetDD:SetPoint("TOPLEFT", 40, -28)
    UIDropDownMenu_SetWidth(panel.presetDD, 230)
    UIDropDownMenu_Initialize(panel.presetDD, PresetMenu)
    UIDropDownMenu_SetText(panel.presetDD, ActivePresetName())   -- correct from birth
    if UIDropDownMenu_JustifyText then UIDropDownMenu_JustifyText(panel.presetDD, "LEFT") end

    -- Everything under the bar hangs off this rather than off the panel, so
    -- the bar could be added without moving every coordinate below it. It is a
    -- plain container: no backdrop, no mouse, nothing but an origin.
    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 0, -PRESET_BAR_H)
    body:SetPoint("BOTTOMRIGHT")

    panel.pass = MakeCheck(body, "APLACheckPass", "Roll automatically", 16, -34,
        "Master switch for the grid below. With everything set to Pass it just passes on the lot, "
            .. "the same net effect as Blizzard's Pass on Loot checkbox. Never carried between "
            .. "sessions; the button beside this one decides what happens at login.",
        function(v) db.autopass = v; UpdateButtonLook() end)

    -- Sits on the checkbox's own line rather than a row of its own, which keeps
    -- it next to the thing it qualifies and leaves everything below where it is.
    panel.loginArm = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
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

    panel.announce = MakeCheck(body, "APLACheckAnnounce", "Announce to chat", 16, -60,
        "Off = print to your own chat frame only, nothing is sent to the group.",
        function(v) db.announce = v; SendHello(true) end)

    panel.minimap = MakeCheck(body, "APLACheckMinimap", "Show minimap button", 16, -86,
        nil,
        function(v)
            db.minimapHide = not v
            if v then button:Show() else button:Hide() end
        end)

    panel.chSlider = MakeSlider(body, "APLAChannelSlider", -126, 1, 4, "Say", "Yell",
        "Announce up to: ", function(v) return CHANNEL_NAME[v] end,
        function(v) db.channel = v end)
    panel.chSlider.tooltipText = "The widest channel to use. It steps down to whatever is actually available: set to Raid, you get raid in a raid and party in a party."

    panel.slider = MakeSlider(body, "APLAQualitySlider", -170, 0, 5, "Poor", "Legendary",
        "Announce: ", MinLabel, function(v) db.minQuality = v end)

    panel.summary = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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

    local gridHead = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gridHead:SetPoint("TOPLEFT", 24, -196)
    gridHead:SetText("What to do with each roll   |cff808080(below "
        .. QUALITY_NAME[MIN_ACTION_QUALITY]:lower() .. ": left alone)|r")

    local headHover = CreateFrame("Frame", nil, body)
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
        local tb = MakeTab(body, TAB_W, TAB_H, QUALITY_NAME[q])
        tb:SetPoint("TOPLEFT", 22 + (q - MIN_ACTION_QUALITY) * (TAB_W + 3), -212)
        tb:SetScript("OnClick", function() SelectQuality(q) end)
        panel.tabs[q] = tb
    end

    -- a rule across the full width, so the active tab reads as sitting on the
    -- section it opens rather than floating above it
    local tabRule = body:CreateTexture(nil, "BACKGROUND")
    tabRule:SetPoint("TOPLEFT", 22, -236)
    tabRule:SetPoint("TOPRIGHT", -22, -236)
    tabRule:SetHeight(1)
    Fill(tabRule, 1, 1, 1, 0.12)

    local COLX = { 150, 195, 240, 285 }
    for i, a in ipairs(ACTIONS) do
        local h = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOP", body, "TOPLEFT", COLX[i] + 8, -244)
        h:SetText(a.label)
    end

    -- One row per kind, built once and pointed at whichever quality the tabs
    -- are showing. Each carries a hover explaining what lands in it.
    panel.rows = {}
    for r, kind in ipairs(KINDS) do
        local y = -260 - (r - 1) * 20
        local row = { key = kind.key, buttons = {} }

        row.label = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("TOPLEFT", 40, y - 2)
        row.label:SetText(kind.label)

        local hover = CreateFrame("Frame", nil, body)
        hover:SetPoint("TOPLEFT", 36, y + 1)
        hover:SetSize(108, 18)
        AttachTooltip(hover, kind.label, kind.tip)

        for i, a in ipairs(ACTIONS) do
            local rb = CreateFrame("CheckButton", "APLAAction" .. r .. "_" .. i,
                body, "UIRadioButtonTemplate")
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

    local prefixLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixLabel:SetPoint("TOPLEFT", 24, -398)
    prefixLabel:SetText("Chat prefix")

    local edit = CreateFrame("EditBox", "APLAPrefixEdit", body, "InputBoxTemplate")
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

    panel.pepe = MakeCheck(body, "APLACheckPepe", "Pepe mode", 16, -446,
        "Puts a random happy pepe in front of the prefix. It shows as a picture for anyone running "
            .. "Twitch Emotes 2.0; everyone else sees the emote name as plain text.",
        function(v) db.pepe = v end)

    panel.track = MakeCheck(body, "APLACheckTrack", "Track drops", 16, -474,
        "Keeps a list of what dropped this session and who won it. Middle-click the minimap "
            .. "button to open it. The list is kept between logins until you clear it.",
        function(v) db.track = v; RefreshTracker() end)

    local test = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    test:SetSize(80, 22)
    test:SetPoint("BOTTOMRIGHT", -12, 12)
    test:SetText("Test")
    test:SetScript("OnClick", function()
        edit:ClearFocus()   -- commit a half-typed prefix so the test uses it
        TestAnnounce()
    end)
end

function RefreshPanel()
    UIDropDownMenu_SetText(panel.presetDD, ActivePresetName())
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

-- Redrawing after a preset has been switched, renamed or imported. A preset
-- reaches into all three windows and into the announcer election, so rather
-- than have every caller remember which, they all go through here.
function RefreshAll()
    if panel and panel:IsShown() then
        RefreshPanel()   -- which ends by updating the minimap button too
    else
        UpdateButtonLook()
    end
    RefreshTracker()
    -- whether this copy announces at all is part of a preset, so the group's
    -- election has to hear about it rather than wait for the next heartbeat
    SendHello(true)
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
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

        -- fill any gap a file written by an older layout is short of, and drop
        -- the rows below rare that 1.3.x kept
        FillActions()

        -- never remembered between sessions. Whether it comes back on is the
        -- "At login" setting's business, handled at PLAYER_LOGIN once the rest
        -- of the addon is up.
        db.autopass = false

        -- dropped settings, cleared out of a saved file written by an older version
        db.fromCorpse, db.coop, db.actions = nil, nil, nil

        if type(db.loot) ~= "table" then db.loot = {} end
        db.loot.entries = db.loot.entries or {}
        db.loot.money   = db.loot.money or 0

        -- Last, so the preset it makes on a first run under this version is a
        -- copy of the settings after every migration above has run, not of the
        -- half-converted ones on the way in.
        EnsurePresets()

        BuildButton()
        BuildPanel()
        BuildPresetCode()
        BuildTracker()
        UpdateButtonLook()

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(COMM_PREFIX)
        end

    elseif event == "PLAYER_LOGOUT" then
        -- The live settings are the active preset, so its stored copy is stale
        -- all session. Nothing reads it while we are running, but filing it
        -- back on the way out leaves the saved file consistent with itself.
        StoreActive()

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
-- The keywords below win over a preset that happens to share a name with one,
-- which is what "use" is for.
local function PresetCommand(line)
    local word, rest = line:match("^(%S*)%s*(.-)%s*$")
    local key = word:lower()

    if key == "" or key == "list" then
        print("|cff66ccffAPLA|r presets:")
        for i, p in ipairs(db.presets) do
            print(("  %d. %s%s"):format(i, p.name,
                i == db.activePreset and "  |cff00ff00(active)|r" or ""))
        end
        -- No pipes in this line. The client reads them as escape sequences, so
        -- "|number" would come out as a line break and "|code" as a colour.
        print("  |cff888888switch with a name or a number, or say "
            .. "new, rename, delete, code, import|r")

    elseif key == "new" then
        NewPreset(rest)

    elseif key == "rename" then
        if not RenameActive(rest) then print("|cff66ccffAPLA|r /apla preset rename <name>") end

    elseif key == "delete" then
        local i = FindPreset(rest ~= "" and rest or db.activePreset)
        if i then
            DeletePreset(i)
        else
            print("|cff66ccffAPLA|r no preset called " .. rest)
        end

    elseif key == "code" then
        TogglePresetCode()

    elseif key == "import" then
        local ok, err = ImportCode(rest)
        if not ok then print("|cff66ccffAPLA|r " .. err) end

    else
        local want = (key == "use") and rest or line
        if want:match("^" .. CODE_TAG .. "%d+:") then
            -- a share code pasted straight in, which is the only thing anyone
            -- could have meant by it
            local ok, err = ImportCode(want)
            if not ok then print("|cff66ccffAPLA|r " .. err) end
        else
            local i = FindPreset(want)
            if i then
                SelectPreset(i)
            else
                print(("|cff66ccffAPLA|r no preset called %s  |cff888888(/apla preset lists them)|r")
                    :format(want))
            end
        end
    end
end

SLASH_AUTOPASSLOOTANNOUNCER1 = "/apla"
SLASH_AUTOPASSLOOTANNOUNCER2 = "/lap"
SlashCmdList.AUTOPASSLOOTANNOUNCER = function(msg)
    local cmd, val = msg:lower():match("^(%S*)%s*(.-)%s*$")
    -- The same argument with its case intact. Everything that was already here
    -- wants it folded; preset names and share codes do not.
    local raw = msg:match("^%s*%S*%s*(.-)%s*$")
    if cmd == "pass" then
        ToggleAutopass()
        return
    elseif cmd == "preset" then
        PresetCommand(raw)
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
