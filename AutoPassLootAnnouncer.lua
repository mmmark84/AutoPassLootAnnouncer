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
    loginArm     = "off",  -- what automated rolling does at login: off / on / ask.
                           -- Account-wide, not per preset: it is a question about
                           -- this session rather than about a role, and when it is
                           -- "ask" the prompt is where you pick the preset anyway.
    hud          = false,  -- the loot popup: say what dropped as it drops
    grace        = 0,      -- seconds to wait before answering a roll, 0 = straight away
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
    "announce", "channel", "minQuality", "prefix", "pepe", "hud", "grace",
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
-- The loot popup, as one cycle button rather than two controls. Showing what
-- dropped and holding a roll long enough to take it back were asked for
-- separately, and they are separable -- but they are points on one line, from
-- "tell me nothing" through "tell me" to "tell me and wait for me", so one
-- button walks it and the panel keeps its height.
local HUD_STEPS = {
    { hud = false, grace = 0  },
    { hud = true,  grace = 0  },   -- says what dropped, answers rolls at once
    { hud = true,  grace = 3  },
    { hud = true,  grace = 5  },
    { hud = true,  grace = 8  },
    { hud = true,  grace = 12 },
}

local function NextHud(hud, grace)
    grace = tonumber(grace) or 0
    for i, step in ipairs(HUD_STEPS) do
        if step.hud == (hud and true or false) and step.grace == grace then
            return HUD_STEPS[i % #HUD_STEPS + 1]
        end
    end
    -- a grace set by slash command to something not on the list: the next
    -- click starts the walk again rather than getting stuck
    return HUD_STEPS[1]
end

local function HudLabel(hud, grace)
    if not hud then return "off" end
    grace = tonumber(grace) or 0
    if grace <= 0 then return "drops only" end
    return grace .. "s grace"
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

-- Answering a roll, once something has decided what the answer is. Split out
-- because the grace period answers from a timer rather than from ProcessRoll.
local function DoRoll(rollID, action, link)
    autoRolls[rollID] = action
    RollOnLoot(rollID, action)               -- 0 pass, 1 need, 2 greed
    C_Timer.After(10, function() autoRolls[rollID] = nil end)
    if action == 1 and link then
        print("|cff66ccffAPLA|r auto-needed: " .. link)
    end
end

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

    -- "At login" used to be part of a preset. It is an account setting now, so
    -- the copy each one is carrying is dead weight: the live value at the root
    -- is the one that counts, and it is already whatever the preset you were
    -- last on had set.
    for _, p in ipairs(db.presets) do p.values.loginArm = nil end

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
        ("h=%d"):format(v.hud and 1 or 0),
        ("g=%d"):format(tonumber(v.grace) or defaults.grace),
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
        hud        = flag("h", defaults.hud),
        grace      = num("g", 0, 60, defaults.grace),
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
local AddPendingRoll, CancelPendingRoll, RefreshRollWindow, CloseRollWindow

----------------------------------------------------------------
-- Output
----------------------------------------------------------------
-- The channel slider sets the WIDEST channel allowed, not a fixed one. We step down
-- from that cap to the widest channel actually available right now:
--   cap Yell  -> always yell
--   cap Raid  -> raid, or party when only grouped, or nothing when solo
--   cap Party -> party when grouped, nothing when solo
--   cap Say   -> always say
-- A dungeon-finder party, a battleground or an arena team is an "instance"
-- group, and everything sent to one -- chat and addon traffic alike -- goes to
-- INSTANCE_CHAT. Sent to RAID instead, the client rejects it and says "You are
-- not in a raid group", which is the message rather than anything we printed.
-- Guarded on the constant because a client old enough not to have it has no
-- instance groups either, and there falls through to the old answer.
local function InstanceGroup()
    return LE_PARTY_CATEGORY_INSTANCE ~= nil
        and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) == true
end

local function ResolveChannel()
    if not db.announce then return nil end
    local cap = db.channel or 3
    if cap >= 4 then return "YELL" end
    if cap >= 3 and IsInRaid() then
        return InstanceGroup() and "INSTANCE_CHAT" or "RAID"
    end
    if cap >= 2 and IsInGroup() then                      -- your subgroup while in a raid
        return InstanceGroup() and "INSTANCE_CHAT" or "PARTY"
    end
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
    if not action then
        print("|cff66ccffAPLA|r left for you to roll: " .. (link or ("roll #" .. rollID)))
        return
    end

    -- With grace off the answer goes out here and now, exactly as it always
    -- has. With it on, the roll window takes the roll and answers it when the
    -- countdown runs out, unless you claim it first.
    local grace = tonumber(db.grace) or 0
    if grace <= 0 then
        DoRoll(rollID, action, link)
    else
        AddPendingRoll(rollID, action, link, grace)
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
    -- A battleground or arena is a group this addon has no business in: there
    -- is no group loot to announce, and a battleground roster churns hard
    -- enough that the hello on every GROUP_ROSTER_UPDATE became one message
    -- every three seconds.
    local _, kind = IsInInstance()
    if kind == "pvp" or kind == "arena" then return nil end
    if InstanceGroup() then return "INSTANCE_CHAT" end
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
-- Tracking takes everything, and the slider in the log window filters what you
-- are looking at rather than what gets kept. It reads as a filter, so it had
-- better be one; and a threshold on the way in throws away rows you cannot ask
-- for later, where a filter on the way out can always be widened.
--
-- The room is because of that: with greys and quest items now landing in the
-- log too, 500 rows was a couple of hours of trash before the epics started
-- falling off the far end.
local MAX_LOOT_ROWS     = 1000
local LOOT_MATCH_WINDOW = 180   -- seconds a row waits for its winner
-- A master-looted item waits on the loot master rather than on a ten-second
-- roll, and that can be most of a boss fight later, so an announced row is
-- given the rest of the raid to find its name.
local ANNOUNCED_MATCH_WINDOW = 1800

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

-- Two windows read the drop log, and LogDrop has three ways out. Both of those
-- facts arrived after the first one was written, and the result was that a row
-- gaining its winner redrew the log window and not the loot window: the loot
-- window sat on "nobody" until some later drop happened to leave through the
-- bottom of the function. So there is one way to say the log changed.
local function LootChanged()
    RefreshTracker()
    RefreshRollWindow()
end

-- winner nil means "this dropped, nobody has won it yet"
function LogDrop(link, count, winner)
    if not db.track or not link then return end

    -- Recorded on the row rather than asked of the item later: the log outlives
    -- the client's item cache, and this is what the window filters on.
    local quality = QualityOf(link)

    local id = ItemID(link)
    if not id then return end

    local entries = db.loot.entries
    -- a count above one settles it; otherwise ask the item itself
    local stacks = (count and count > 1) or IsStackable(link) == true

    if stacks then
        if not winner then return end   -- wait for the loot message to say how many
        -- An announcement can have put a winner-less row in for this item
        -- before anyone had it. A stack keeps its tally on one row of its own
        -- instead, so the placeholder has done its job, and left alone it would
        -- sit at "nobody" for the rest of the night.
        for i = #entries, 1, -1 do
            local e = entries[i]
            if e.id == id and e.announced and not e.stack and not e.winner then
                table.remove(entries, i)
            end
        end
        for _, e in ipairs(entries) do
            if e.id == id and e.stack then
                e.count, e.t = e.count + count, time()
                -- who took how many, so a stack can still be split back out per
                -- character. A non-stackable row does not need this: it has one
                -- winner and that name is already on it.
                e.by = e.by or {}
                e.by[winner] = (e.by[winner] or 0) + count
                LootChanged()
                return
            end
        end
        entries[#entries + 1] = { id = id, link = link, count = count, stack = true,
                                  by = { [winner] = count }, q = quality, t = time() }
    elseif winner then
        -- fill the oldest row still waiting on this item, so names land in the
        -- order the rolls did rather than backwards
        for _, e in ipairs(entries) do
            if e.id == id and not e.stack and not e.winner
                and (time() - e.t)
                    <= (e.announced and ANNOUNCED_MATCH_WINDOW or LOOT_MATCH_WINDOW) then
                e.winner = winner
                LootChanged()
                return
            end
        end
        entries[#entries + 1] =
            { id = id, link = link, count = 1, winner = winner, q = quality, t = time() }
    else
        entries[#entries + 1] = { id = id, link = link, count = 1, q = quality, t = time() }
    end

    db.loot.started = db.loot.started or time()
    while #entries > MAX_LOOT_ROWS do table.remove(entries, 1) end
    Dbg("logged %s x%d winner=%s", tostring(link), count or 1, tostring(winner))
    LootChanged()
end

----------------------------------------------------------------
-- What the loot addons announce
----------------------------------------------------------------
-- Under master loot nothing reaches the log until an item is handed over:
-- there is no START_LOOT_ROLL to hang a drop on, and "receives loot" is the end
-- of the story rather than the start of it. What the raid does see is the loot
-- master's addon announcing the drop, and that is where these rows come from.
--
-- Only two shapes are read, and both of them are an addon talking rather than a
-- person. Gargul prefixes everything it says to the group with a raid marker,
-- its own name and a colon, and follows the item with a separate "Reserved by"
-- line; LootReserve says it on one line as "<item> is reserved by: ...". A
-- raider linking an item to ask who needs it is not an announcement and is left
-- alone, which is the whole reason for matching shapes instead of every link
-- that goes past.
local ITEM_LINK   = "|c%x+|Hitem:.-|h.-|h|r"
local GARGUL_SAID = "^%s*(.-)Gargul%s*:%s*(.+)$"

-- Gargul stamps a raid marker in front of its name. That reaches us as the
-- "{rt3}" the sender typed, or as the texture the client made of it, or not at
-- all on a client or version that leaves it off -- so all three are allowed,
-- and nothing else is. Without that last part "who reserved this, Gargul : ..."
-- typed by a raider would read as an announcement.
local function IsMarker(head)
    return head == "" or head:match("^{%a*%d*}%s*$") ~= nil
        or head:match("^|T.-|t%s*$") ~= nil
end

-- Returns the item link and the reserves, either of which can be missing: an
-- item on its own is a drop with nobody on it yet, and reserves on their own
-- belong to the item announced a moment ago.
local function ParseAnnouncement(msg)
    if not msg then return end
    if not msg:find("|Hitem:", 1, true) and not msg:find("eserved", 1, true) then
        return   -- neither half of an announcement, and most chat is neither
    end

    -- LootReserve, which carries both halves and announces under its own name
    local link, names = msg:match("^(" .. ITEM_LINK .. ")%s+is reserved by:%s*(.+)$")
    if link then return link, names end

    local head, said = msg:match(GARGUL_SAID)
    if not said or not IsMarker(head) then return end

    names = said:match("^Reserved by:%s*(.+)$")
    if names then return nil, names end

    -- the item by itself, or the same line with the hard-reserve note on it
    link = said:match("^(" .. ITEM_LINK .. ")%s*$")
        or said:match("^(" .. ITEM_LINK .. ")%s*%(This item is hard%-reserved!%)%s*$")
    if link then return link end
end

-- The row the next "Reserved by" line belongs to. Kept as a reference rather
-- than an index because the log trims from the front, and short-lived because
-- the two lines are sent back to back: a reserve line that arrives long after
-- its item has nothing to do with it.
local lastAnnounced, lastAnnouncedAt = nil, 0
local ANNOUNCE_PAIR_WINDOW = 15

-- link nil means "the reserves for the item announced a moment ago"
function LogAnnounced(link, reserves)
    if not db.track then return end

    if not link then
        if reserves and lastAnnounced
            and (time() - lastAnnouncedAt) <= ANNOUNCE_PAIR_WINDOW then
            lastAnnounced.res = reserves
            LootChanged()
        end
        return
    end

    local id = ItemID(link)
    if not id then return end

    local entries = db.loot.entries

    -- The same drop can be both announced and rolled -- group loot fires
    -- START_LOOT_ROLL and Gargul announces the item alongside it -- so fill the
    -- row already waiting for a winner rather than listing the item twice.
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.id == id and not e.stack and not e.winner
            and (time() - e.t) <= LOOT_MATCH_WINDOW then
            if reserves then e.res = reserves end
            lastAnnounced, lastAnnouncedAt = e, time()
            LootChanged()
            return
        end
    end

    local e = { id = id, link = link, count = 1, q = QualityOf(link), t = time(),
                announced = true, res = reserves }
    entries[#entries + 1] = e
    lastAnnounced, lastAnnouncedAt = e, time()

    db.loot.started = db.loot.started or time()
    while #entries > MAX_LOOT_ROWS do table.remove(entries, 1) end
    Dbg("announced %s res=%s", tostring(link), tostring(reserves))
    LootChanged()
end

function LogMoney(copper)
    if not db.track or not copper or copper <= 0 then return end
    db.loot.money = (db.loot.money or 0) + copper
    db.loot.started = db.loot.started or time()
    RefreshTracker()
end

function ClearLog()
    db.loot = { entries = {}, money = 0, started = time() }
    LootChanged()
    print("|cff66ccffAPLA|r drop log cleared, new session started")
end

-- A night of drops, and nothing that brings them back. It is one button in the
-- log window, where you went deliberately, but it is also an entry in a menu
-- you open to change a quality filter, and a slip there should not cost the
-- night. So both go through here.
StaticPopupDialogs["AUTOPASSLOOTANNOUNCER_CLEAR_LOG"] = {
    text = "Empty the drop log?\n\nEverything recorded this session goes, here and in "
        .. "the loot window, and a new session starts.",
    button1 = "Clear it",
    button2 = "Cancel",
    OnAccept = function() ClearLog() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,   -- the low indices are the ones that pick up taint
}

local function ConfirmClearLog()
    if #db.loot.entries == 0 and (db.loot.money or 0) == 0 then
        ClearLog()   -- nothing to lose, so do not ask
        return
    end
    StaticPopup_Show("AUTOPASSLOOTANNOUNCER_CLEAR_LOG")
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

----------------------------------------------------------------
-- Login prompt
----------------------------------------------------------------
-- What "At login: ask" puts in front of you. A frame of its own rather than a
-- StaticPopup because it carries a preset dropdown, and a StaticPopup is one
-- shared, recycled frame with a fixed set of widgets in it.
--
-- Arming and which preset to arm are the same question at login -- you are not
-- picking a role in the abstract, you are deciding how tonight is going to go --
-- so they are asked together, and the preset you were last on is the one
-- already selected.
local armPrompt

-- Just the presets. The settings panel's menu carries new/rename/delete/share
-- as well, which is housekeeping and has no business in a prompt.
local function ArmPresetMenu(_, level)
    level = level or 1
    if level ~= 1 then return end
    for i, p in ipairs(db.presets) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = p.name
        info.checked = (i == db.activePreset)
        info.func = function()
            -- Applied there and then rather than held until "Arm it". Picking a
            -- preset and picking whether to arm are two answers, and you are
            -- allowed to change one without the other.
            SelectPreset(i)
            UIDropDownMenu_SetText(armPrompt.dd, ActivePresetName())
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local function BuildArmPrompt()
    armPrompt = CreateFrame("Frame", "AutoPassLootAnnouncerArmPrompt", UIParent,
        "BasicFrameTemplateWithInset")
    armPrompt:SetSize(400, 200)
    armPrompt:SetPoint("CENTER", 0, 120)   -- clear of the middle of the screen
    armPrompt:SetMovable(true)
    armPrompt:EnableMouse(true)
    armPrompt:RegisterForDrag("LeftButton")
    armPrompt:SetScript("OnDragStart", armPrompt.StartMoving)
    armPrompt:SetScript("OnDragStop", armPrompt.StopMovingOrSizing)
    armPrompt:SetClampedToScreen(true)
    armPrompt:SetFrameStrata("DIALOG")   -- the same strata as the rest, see the panel
    armPrompt:SetToplevel(true)
    armPrompt:Hide()
    -- Escape closes it, which means "leave it off": the prompt exists so that
    -- arming is never something that happened without you saying so.
    tinsert(UISpecialFrames, "AutoPassLootAnnouncerArmPrompt")

    local title = armPrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("Auto Pass Loot Announcer")

    local msg = armPrompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    msg:SetPoint("TOPLEFT", 20, -38)
    msg:SetPoint("TOPRIGHT", -20, -38)
    msg:SetJustifyH("CENTER")
    msg:SetText("Arm automated rolling for this session?\n\n"
        .. "While armed it answers loot rolls for you, by quality and bind type.")

    -- The row and the buttons are anchored up from the bottom edge, so however
    -- many lines the message above wraps to, nothing below it moves.
    local label = armPrompt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", 24, 52)
    label:SetText("Preset")

    armPrompt.dd = CreateFrame("Frame", "APLAArmPresetDropDown", armPrompt,
        "UIDropDownMenuTemplate")
    armPrompt.dd:SetPoint("BOTTOMLEFT", 56, 44)
    UIDropDownMenu_SetWidth(armPrompt.dd, 260)
    UIDropDownMenu_Initialize(armPrompt.dd, ArmPresetMenu)
    if UIDropDownMenu_JustifyText then UIDropDownMenu_JustifyText(armPrompt.dd, "LEFT") end

    local arm = CreateFrame("Button", nil, armPrompt, "UIPanelButtonTemplate")
    arm:SetSize(150, 24)
    arm:SetPoint("BOTTOMLEFT", 24, 14)
    arm:SetText("Arm it")
    arm:SetScript("OnClick", function()
        armPrompt:Hide()
        db.autopass = true
        UpdateButtonLook()
        print(("|cff66ccffAPLA|r auto-roll |cff00ff00armed|r on |cffffd100%s|r")
            :format(ActivePresetName()))
        if panel and panel:IsShown() then RefreshPanel() end
    end)

    local leave = CreateFrame("Button", nil, armPrompt, "UIPanelButtonTemplate")
    leave:SetSize(150, 24)
    leave:SetPoint("BOTTOMRIGHT", -24, 14)
    leave:SetText("Leave it off")
    leave:SetScript("OnClick", function() armPrompt:Hide() end)

    -- Rebuilt on the way up rather than at build time: a preset can have been
    -- renamed, added or deleted since the last time this was on screen.
    armPrompt:SetScript("OnShow", function()
        UIDropDownMenu_SetText(armPrompt.dd, ActivePresetName())
    end)
end

local function ShowArmPrompt()
    if not armPrompt then return end
    armPrompt:Show()
    armPrompt:Raise()
end

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

-- The bar of buttons across the bottom. Without it they sat on top of the
-- last checkbox, which is what the panel used to end with.
local BOTTOM_BAR_H = 26

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
    panel:SetSize(340, 516 + PRESET_BAR_H + BOTTOM_BAR_H)
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
        function(v) db.track = v; LootChanged() end)

    -- On the bottom bar rather than a row of its own: the panel is already as
    -- tall as some people's screens, and this is a cycle button like At login
    -- rather than anything that wants a slider's width.
    panel.hud = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.hud:SetSize(160, 22)
    panel.hud:SetPoint("BOTTOMLEFT", 16, 12)
    panel.hud:SetScript("OnClick", function()
        local step = NextHud(db.hud, db.grace)
        db.hud, db.grace = step.hud, step.grace
        RefreshPanel()
        RefreshRollWindow()
    end)
    AttachTooltip(panel.hud, "Loot popup", {
        "A small window that says what dropped, and optionally holds the roll long enough for "
            .. "you to take it back. Click to cycle.",
        "|cffffd100Off|r - nothing on screen. Rolls are answered the moment they drop and "
            .. "Blizzard's roll windows are left alone, exactly as without this setting.",
        "|cffffd100Drops only|r - lists what dropped and who took it, as it happens. Rolls are "
            .. "still answered straight away. Needs Track drops on, since it reads that log.",
        "|cffffd1003s and up|r - also holds each roll the addon is going to answer for that long "
            .. "and counts down to it, with Blizzard's window held back for those rolls only.",
        "Click a row there to take that one back: the auto-roll is dropped and the normal roll "
            .. "window opens for it, with the full timer still on it.",
        "Doing nothing still rolls for you. That is the point of it.",
    })

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
    panel.hud:SetText("Popup: " .. HudLabel(db.hud, db.grace))
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
-- The quality a row was logged at. Rows written before the log recorded it
-- fall back to the item's own link, which carries the colour whether or not
-- the client still remembers the item, and the answer is kept on the row so
-- the lookup happens once rather than on every redraw.
local function EntryQuality(e)
    if not e.q then e.q = QualityOf(e.link) or 0 end
    return e.q
end

-- A stacked row records who took how many, so it can be drawn as one line per
-- winner rather than a single "stacked" that says nothing about where the
-- stack went. One winner is the common case and stays one line, with the name
-- on it and the whole count. Rows logged before the per-winner counts existed
-- have no answer to give and keep saying "stacked".
local function SplitStack(e, out)
    local names = {}
    for who in pairs(e.by or {}) do names[#names + 1] = who end
    if #names == 0 then
        out[#out + 1] = e
        return out
    end
    -- biggest share first, and by name where two shares are equal, so the
    -- order does not shuffle between redraws the way pairs() would
    table.sort(names, function(a, b)
        if e.by[a] ~= e.by[b] then return e.by[a] > e.by[b] end
        return a < b
    end)
    for _, who in ipairs(names) do
        out[#out + 1] = { id = e.id, link = e.link, count = e.by[who], stack = true,
                          winner = who, q = EntryQuality(e), t = e.t }
    end
    return out
end

-- "Hikø +2" out of "Hikø, Perhorn, Grendl". The winner column is one name
-- wide and the row is not worth widening for a list that is on its tooltip
-- anyway, so the column says who is first in line and how many are behind.
local function ShortReserve(res)
    local first, rest = res:match("^%s*([^,]+)%s*,%s*(.+)$")
    if not first then return (res:gsub("%s+$", "")) end
    local more = 1
    for _ in rest:gmatch(",") do more = more + 1 end
    return ("%s +%d"):format((first:gsub("%s+$", "")), more)
end

-- Returns the list, and how many rows this tab holds that the quality slider
-- is hiding, so the header can own up to them.
local function ViewEntries()
    local all  = db.loot.entries
    local mine = tracker.view == "mine"
    local me   = mine and Me() or nil
    local min  = db.trackMin or 0

    -- how much of this row belongs in this tab: the whole thing on Everything,
    -- and on Mine your own share of a stack or nothing at all
    local function share(e)
        if not mine then return e.count end
        if e.stack then return e.by and e.by[me] or 0 end
        return e.winner == me and e.count or 0
    end

    local stacks, singles, hidden = {}, {}, 0
    for i = #all, 1, -1 do   -- newest first
        local e = all[i]
        local n = share(e)
        if n > 0 then
            if EntryQuality(e) < min then
                hidden = hidden + 1
            elseif e.stack and mine then
                stacks[#stacks + 1] = { id = e.id, link = e.link, count = n,
                                        stack = true, q = e.q, t = e.t }
            elseif e.stack then
                SplitStack(e, stacks)
            else
                singles[#singles + 1] = e
            end
        end
    end

    for _, e in ipairs(singles) do stacks[#stacks + 1] = e end
    return stacks, hidden
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
            if self.res then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Reserved by: " .. self.res, 1, 0.82, 0, true)
            end
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

    -- Filters what is on screen, not what gets kept: tracking takes the lot.
    -- It lives here rather than in the settings panel because this is the
    -- window where you notice the list filling up with things you do not want.
    --
    -- The guard is against SetValue in RefreshTracker coming back round through
    -- this handler and refreshing again; the client does not fire the handler
    -- for a value that has not moved, but a redraw loop is not worth the risk.
    tracker.slider = MakeSlider(tracker, "APLATrackSlider", 0, 0, 5, "Poor", "Legendary",
        "Show: ", MinLabel, function(v)
            if v == db.trackMin then return end
            db.trackMin = v
            RefreshTracker()
        end)
    tracker.slider:ClearAllPoints()   -- bottom-anchored, so resizing leaves it alone
    tracker.slider:SetPoint("BOTTOMLEFT", 24, 52)

    local clear = CreateFrame("Button", nil, tracker, "UIPanelButtonTemplate")
    clear:SetSize(90, 22)
    clear:SetPoint("BOTTOMRIGHT", -26, 12)   -- clear of the resize grip
    clear:SetText("Clear")
    clear.tooltipText = "Empties the log and starts a new session. Asks first."
    clear:SetScript("OnClick", function() ConfirmClearLog() end)

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

    local entries, hidden = ViewEntries()
    local n = #entries
    local shown = tracker.visibleRows or 1

    local when = db.loot.started and date("%d %b %H:%M", db.loot.started) or "nothing yet"
    -- "3 of 63" whenever the slider is holding rows back, so a short list never
    -- looks like a session that did not happen
    local count = hidden > 0 and ("%d of %d"):format(n, n + hidden) or tostring(n)
    tracker.stats:SetText(("%s %s since %s          %s%s"):format(
        count, (n + hidden) == 1 and "line" or "lines", when,
        GetCoinTextureString(db.loot.money or 0),
        db.track and "" or "   |cffff8000(tracking is off)|r"))

    FauxScrollFrame_Update(tracker.scroll, n, shown, TRACK_ROW_H)
    local offset = FauxScrollFrame_GetOffset(tracker.scroll)

    for i, row in ipairs(tracker.rows) do
        local e = (i <= shown) and entries[offset + i] or nil   -- already in draw order
        if e then
            row.link, row.res = e.link, e.res
            row.icon:SetTexture(select(10, GetItemInfo(e.link)) or UNKNOWN_ICON)
            row.text:SetText(e.count > 1 and (e.link .. " |cffffffffx" .. e.count .. "|r") or e.link)
            if tracker.view == "mine" then
                row.who:SetText(e.stack and "|cff808080your share|r" or "|cff808080yours|r")
            elseif e.winner then
                row.who:SetText("|cffffff00" .. e.winner .. "|r")
            elseif e.stack then
                row.who:SetText("|cff808080stacked|r")
            elseif e.res then
                row.who:SetText("|cff9d7fd0" .. ShortReserve(e.res) .. "|r")
            else
                row.who:SetText("|cff808080nobody|r")
            end
            row:Show()
        else
            row.link, row.res = nil, nil
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

----------------------------------------------------------------
-- Loot window
----------------------------------------------------------------
-- What dropped, as it drops, and optionally a grace period in front of the
-- automatic roll so there is a moment to take one back.
--
-- The thing this is careful not to become is Blizzard's roll window with a
-- shorter timer. What keeps it from being that is which way round the default
-- sits: doing nothing here still means the addon rolls as configured, where
-- doing nothing in Blizzard's window loses you the item. So the pending rows
-- have exactly one action, and it is "not this one" -- click a row and the
-- pending roll is dropped and that item handed back to Blizzard's own frame
-- with the whole of the server's two minutes still on it. Need, greed and pass
-- are not duplicated here; the UI built for that decision is one click away
-- and is better at it than anything that would fit in a row.
--
-- It sits on screen for as long as the setting is on, rather than appearing and
-- vanishing: a window that comes and goes is one nobody can find, aim at, or
-- resize. Off is the way to get rid of it, and the X in its header is off.
local ROLL_HEADER     = 22
local ROLL_ROW_H      = 18   -- a pending roll
local ROLL_RECENT_H   = 16   -- a line of what already happened
local ROLL_FOOTER     = 8
local MAX_ROLL_ROWS   = 8    -- a raid boss drops five or six at once at most
local MAX_ROLL_RECENT = 30   -- enough for the tallest the window is allowed to get
local ROLL_MIN_W, ROLL_MIN_H = 260, 120
local ROLL_MAX_W, ROLL_MAX_H = 600, 700

local rollWin
local pendingRolls = {}   -- [rollID] = { action, link, itemID, grace, deadline }
local suppressed   = {}   -- [rollID] = true while we hold the default frame down
local LayoutRollWindow    -- defined below, called from the redraw above it

----------------------------------------------------------------
-- Blizzard's own roll frames
----------------------------------------------------------------
-- Held down rather than torn out: they are ordinary frames, and the addon only
-- ever hides one belonging to a roll it has taken responsibility for. A roll it
-- is not going to answer keeps its window exactly as before, which is what the
-- Window action in the grid promises.
local function EachDefaultFrame(fn)
    for i = 1, 4 do
        local f = _G["GroupLootFrame" .. i]
        if f then fn(f) end
    end
end

local function HideDefaultFrame(rollID)
    EachDefaultFrame(function(f)
        if f.rollID == rollID and f:IsShown() then
            -- Newer builds lay these out through a container, which has to be
            -- told or it leaves a hole where the frame was. Older ones have no
            -- container and a plain Hide is the whole job.
            if GroupLootContainer and GroupLootContainer_RemoveFrame then
                GroupLootContainer_RemoveFrame(GroupLootContainer, f)
            else
                f:Hide()
            end
        end
    end)
end

-- Blizzard's START_LOOT_ROLL handler and ours race, and it usually wins, so
-- the frame is normally already up by the time we decide; HideDefaultFrame
-- covers that. This covers the other order, where a frame opens afterwards.
local function HookDefaultFrames()
    EachDefaultFrame(function(f)
        f:HookScript("OnShow", function(self)
            if suppressed[self.rollID] then HideDefaultFrame(self.rollID) end
        end)
    end)
end

----------------------------------------------------------------
-- The window
----------------------------------------------------------------
-- The drop log's newest rows rather than a second list of its own, so the
-- quality slider in the log window filters this too and there is only ever one
-- list to keep straight.
local function RecentEntries()
    -- START_LOOT_ROLL puts a winner-less row in the log for the same drop that
    -- is sitting in the pending list above, and one item on two lines of a
    -- small window is noise. Skipped until it has a winner, at which point it
    -- has stopped being the thing overhead and become the thing that happened.
    local waiting = {}
    for _, p in pairs(pendingRolls) do
        if p.itemID then waiting[p.itemID] = true end
    end

    local out, all = {}, db.loot.entries
    for i = #all, 1, -1 do
        if #out >= MAX_ROLL_RECENT then break end
        local e = all[i]
        local stillRolling = waiting[e.id] and not e.winner and not e.stack
        if not stillRolling and EntryQuality(e) >= (db.trackMin or 0) then
            -- a stack split per winner can push the list past the cap, so the
            -- trim happens after rather than the count being guessed before
            if e.stack then SplitStack(e, out) else out[#out + 1] = e end
        end
    end
    while #out > MAX_ROLL_RECENT do out[#out] = nil end
    return out
end

-- Soonest deadline first, so rows leave from the top and the ones below do not
-- shuffle upwards under the cursor
local function SortedPending()
    local out = {}
    for rollID, p in pairs(pendingRolls) do out[#out + 1] = { id = rollID, p = p } end
    table.sort(out, function(a, b)
        if a.p.deadline == b.p.deadline then return a.id < b.id end
        return a.p.deadline < b.p.deadline
    end)
    return out
end

function RefreshRollWindow()
    if not rollWin then return end
    if not db.hud then rollWin:Hide(); return end

    local rolls  = SortedPending()
    local recent = RecentEntries()
    local now    = GetTime()

    -- However many are pending, only as many as there is window for. The ones
    -- that do not fit are still answered on time: the countdown is C_Timer's
    -- and the rows are only the picture of it.
    local room  = rollWin:GetHeight() - ROLL_HEADER - ROLL_FOOTER
    local npend = math.min(#rolls, MAX_ROLL_ROWS, math.max(0, math.floor(room / ROLL_ROW_H)))

    local shown = LayoutRollWindow(npend)

    for i, row in ipairs(rollWin.rows) do
        local r = i <= npend and rolls[i] or nil
        if r then
            local left = math.max(0, r.p.deadline - now)
            local frac = r.p.grace > 0 and (left / r.p.grace) or 0
            row.rollID = r.id
            row.icon:SetTexture(select(10, GetItemInfo(r.p.link)) or UNKNOWN_ICON)
            row.text:SetText(r.p.link or ("roll #" .. r.id))
            row.action:SetText("|cffffd100" .. (ACTION_SHORT[r.p.action] or "?") .. "|r")
            row.secs:SetText(("%ds"):format(math.ceil(left)))

            -- Drains leftwards, and warms up as it goes, so how long is left
            -- reads without the number being read. Kept faint: it is behind
            -- an item link, and a link you cannot make out is worse than no
            -- bar at all.
            row.fill:SetWidth(math.max(1, row:GetWidth() * frac))
            if frac > 0.5 then
                Fill(row.fill, 0.20, 0.70, 0.25, 0.35)
            elseif frac > 0.2 then
                Fill(row.fill, 0.85, 0.65, 0.15, 0.35)
            else
                Fill(row.fill, 0.85, 0.25, 0.20, 0.40)
            end
            row:Show()
        else
            row.rollID = nil
            row:Hide()
        end
    end

    FauxScrollFrame_Update(rollWin.scroll, #recent, shown, ROLL_RECENT_H)
    local offset = FauxScrollFrame_GetOffset(rollWin.scroll)

    for i, row in ipairs(rollWin.recent) do
        local e = (i <= shown) and recent[offset + i] or nil
        if e then
            row.link, row.res = e.link, e.res
            row.icon:SetTexture(select(10, GetItemInfo(e.link)) or UNKNOWN_ICON)
            row.text:SetText(e.count > 1 and (e.link .. " |cffffffffx" .. e.count .. "|r")
                or e.link)
            if not e.winner and not e.stack and e.res then
                row.who:SetText("|cff9d7fd0" .. ShortReserve(e.res) .. "|r")
            else
                row.who:SetText("|cff808080"
                    .. (e.winner or (e.stack and "stacked") or "nobody") .. "|r")
            end
            row:Show()
        else
            row.link, row.res = nil, nil
            row:Hide()
        end
    end

    -- a divider only when there is something on both sides of it
    if npend > 0 and #recent > 0 then rollWin.rule:Show() else rollWin.rule:Hide() end

    if npend == 0 and #recent == 0 then
        -- The one dependency worth spelling out: the drops half of this window
        -- reads the drop log, and there is no log until tracking is on.
        rollWin.hint:SetText(db.track and "Nothing yet."
            or "Turn on Track drops to list what you loot here.")
        rollWin.hint:Show()
    else
        rollWin.hint:Hide()
    end

    rollWin:Show()
end

local function ClaimRoll(rollID)
    local p = pendingRolls[rollID]
    if not p then return end
    pendingRolls[rollID] = nil
    suppressed[rollID] = nil

    -- Handed back with whatever the server still has on it, which is most of
    -- two minutes. Nothing here shortens a roll.
    local left = GetLootRollTimeLeft(rollID)
    if left and left > 0 and GroupLootFrame_OpenNewFrame then
        GroupLootFrame_OpenNewFrame(rollID, left)
        print("|cff66ccffAPLA|r yours to answer: " .. (p.link or ("roll #" .. rollID)))
    else
        print("|cff66ccffAPLA|r that roll is already over")
    end
    RefreshRollWindow()
end

local function FirePending(rollID)
    local p = pendingRolls[rollID]
    if not p then return end          -- claimed, or cancelled under us
    pendingRolls[rollID] = nil
    suppressed[rollID] = nil

    -- Answered by hand in the meantime, or expired: either way there is nothing
    -- to answer and rolling into it would be an error in the client.
    local left = GetLootRollTimeLeft(rollID)
    if not left or left <= 0 then
        Dbg("roll %d was gone by the time its grace ran out", rollID)
        RefreshRollWindow()
        return
    end

    DoRoll(rollID, p.action, p.link)
    RefreshRollWindow()
end

-- The one door in from ProcessRoll. Timing is C_Timer's job rather than the
-- window's, so a roll still fires on time with the window closed, the game
-- paused on a loading screen, or the row scrolled out of sight.
function AddPendingRoll(rollID, action, link, grace)
    pendingRolls[rollID] = {
        action = action, link = link, itemID = ItemID(link),
        grace = grace, deadline = GetTime() + grace,
    }
    suppressed[rollID] = true
    HideDefaultFrame(rollID)
    C_Timer.After(grace, function() FirePending(rollID) end)
    RefreshRollWindow()
end

-- A roll that ends for any other reason: somebody else's action, the master
-- looter stepping in, the group breaking up.
function CancelPendingRoll(rollID)
    if not pendingRolls[rollID] and not suppressed[rollID] then return end
    pendingRolls[rollID] = nil
    suppressed[rollID] = nil
    RefreshRollWindow()
end

-- The X in the header, and /apla popup. Off takes the grace period with it: a
-- roll held back with nowhere to see it is worse than either setting alone.
function CloseRollWindow()
    db.hud, db.grace = false, 0
    RefreshRollWindow()
    if panel and panel:IsShown() then RefreshPanel() end
    print("|cff66ccffAPLA|r loot popup off, and the grace period with it")
end

----------------------------------------------------------------
-- Right-click menu
----------------------------------------------------------------
-- The threshold, offered as the qualities themselves rather than as a slider
-- position you have to translate: each row is the name in its own colour, with
-- a tick on the one you are on, so you pick the thing you want by looking at
-- it. Same setting as the slider in the drop log -- one threshold, two places
-- to reach it -- so the log follows and vice versa.
--
-- "Track drops" is in here too, because it is the other thing that can leave
-- this window empty, and the empty window says so.
local rollMenu

local function RollMenuInit(_, level)
    level = level or 1
    if level ~= 1 then return end

    local function Add(fields)
        local info = UIDropDownMenu_CreateInfo()
        for k, v in pairs(fields) do info[k] = v end
        UIDropDownMenu_AddButton(info, level)
    end

    Add({
        text = "Track drops",
        checked = db.track and true or false,
        func = function()
            db.track = not db.track
            RefreshTracker()
            RefreshRollWindow()
            if panel and panel:IsShown() then RefreshPanel() end
        end,
    })

    Add({ text = "", isTitle = true, notCheckable = true, disabled = true })
    Add({ text = "Show", isTitle = true, notCheckable = true })

    for q = 0, 5 do
        Add({
            -- MinLabel already colours the quality; it is written lower case
            -- for the middle of a slider caption, which is not this
            text = q == 0 and "Everything" or MinLabel(q),
            checked = (db.trackMin or 0) == q,
            func = function()
                db.trackMin = q
                RefreshTracker()
                RefreshRollWindow()
                CloseDropDownMenus()
            end,
        })
    end

    Add({ text = "", isTitle = true, notCheckable = true, disabled = true })
    Add({
        -- named for the log rather than for this window, because that is what
        -- it empties: the drop log both this and the log window read
        text = "Clear the drop log",
        notCheckable = true,
        func = function()
            CloseDropDownMenus()
            ConfirmClearLog()
        end,
    })
    Add({
        text = "Close this window",
        notCheckable = true,
        func = function() CloseRollWindow() end,
    })
end

local function ShowRollMenu()
    if not rollMenu then
        rollMenu = CreateFrame("Frame", "APLARollMenu", UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(rollMenu, RollMenuInit, "MENU")
    end
    ToggleDropDownMenu(1, nil, rollMenu, "cursor", 0, 0)
end

local function MakeRollRow(parent, h)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(h)
    -- A button swallows whatever it is not registered for, and the menu has to
    -- be reachable over a row as much as beside one.
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(h - 5, h - 5)
    row.icon:SetPoint("LEFT", 0, 0)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", h + 1, 0)
    row.text:SetJustifyH("LEFT")

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    Fill(hl, 1, 1, 1, 0.10)

    row:Hide()
    return row
end

local function BuildRollWindow()
    -- No frame template. This one sits over the game while you are fighting,
    -- so it gets a dark panel and a hairline rather than the inset art the
    -- addon's other windows use, which is opaque and much heavier.
    rollWin = CreateFrame("Frame", "AutoPassLootAnnouncerRollWindow", UIParent)
    rollWin:SetSize(db.rollSize and db.rollSize.w or 320,
                    db.rollSize and db.rollSize.h or 200)
    rollWin:SetPoint("CENTER", 0, 180)
    rollWin:SetMovable(true)
    rollWin:SetResizable(true)
    -- SetResizeBounds is the modern name for the pair below it, guarded the way
    -- SetObeyStepOnDrag and SetColorTexture are
    if rollWin.SetResizeBounds then
        rollWin:SetResizeBounds(ROLL_MIN_W, ROLL_MIN_H, ROLL_MAX_W, ROLL_MAX_H)
    else
        rollWin:SetMinResize(ROLL_MIN_W, ROLL_MIN_H)
        rollWin:SetMaxResize(ROLL_MAX_W, ROLL_MAX_H)
    end
    rollWin:EnableMouse(true)
    rollWin:SetClampedToScreen(true)
    -- LOW, and deliberately the lowest of the addon's windows. This one is
    -- always up, so it must never be the thing in front: at HIGH it sat over
    -- the bags, which live there too. Everything in the default UI you can
    -- open is MEDIUM or above, so from down here it covers none of it, and it
    -- has no SetToplevel either -- clicking or dragging it must not promote it
    -- past the panel it is behind.
    rollWin:SetFrameStrata("LOW")
    rollWin:Hide()

    local function SavePos(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        db.rollPos = { point = point, rel = rel, x = x, y = y }
    end

    -- Draggable by the body as well as the header, because a window you have
    -- to aim at is a window you swear at.
    rollWin:RegisterForDrag("LeftButton")
    rollWin:SetScript("OnDragStart", rollWin.StartMoving)
    rollWin:SetScript("OnDragStop", SavePos)
    rollWin:SetScript("OnMouseUp", function(_, mouseButton)
        if mouseButton == "RightButton" then ShowRollMenu() end
    end)

    if db.rollPos then
        rollWin:ClearAllPoints()
        rollWin:SetPoint(db.rollPos.point, UIParent, db.rollPos.rel,
            db.rollPos.x, db.rollPos.y)
    end

    local edge = rollWin:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    Fill(edge, 1, 1, 1, 0.10)

    local bg = rollWin:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    Fill(bg, 0, 0, 0, 0.60)   -- semi-transparent: it sits over the fight

    -- The header. Its own frame rather than a texture so it can be the thing
    -- you grab, which is what a header is for.
    local head = CreateFrame("Frame", nil, rollWin)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(ROLL_HEADER)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function() rollWin:StartMoving() end)
    head:SetScript("OnDragStop", function() SavePos(rollWin) end)
    head:SetScript("OnMouseUp", function(_, mouseButton)
        if mouseButton == "RightButton" then ShowRollMenu() end
    end)

    local headBg = head:CreateTexture(nil, "ARTWORK")
    headBg:SetAllPoints()
    Fill(headBg, 1, 1, 1, 0.08)

    local title = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", 8, 0)
    title:SetText("Loot")

    local hintText = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintText:SetPoint("LEFT", title, "RIGHT", 8, 0)
    hintText:SetText("right-click for options")

    local close = CreateFrame("Button", nil, head, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("RIGHT", 1, 0)
    close:SetScript("OnClick", function() CloseRollWindow() end)

    rollWin.rule = rollWin:CreateTexture(nil, "ARTWORK")
    rollWin.rule:SetHeight(1)
    Fill(rollWin.rule, 1, 1, 1, 0.14)
    rollWin.rule:Hide()

    rollWin.hint = rollWin:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rollWin.hint:SetPoint("TOPLEFT", 8, -(ROLL_HEADER + 8))
    rollWin.hint:SetPoint("TOPRIGHT", -8, -(ROLL_HEADER + 8))
    rollWin.hint:SetJustifyH("LEFT")
    rollWin.hint:Hide()

    rollWin.rows = {}
    for i = 1, MAX_ROLL_ROWS do
        local row = MakeRollRow(rollWin, ROLL_ROW_H)

        -- What the addon is about to do, so a row can be read without knowing
        -- the grid off by heart.
        -- The countdown is the row rather than a bar off to one side of it: a
        -- band the full width, draining away leftwards behind the item, with
        -- the item and the numbers drawn over the top. It reads at a glance
        -- from the corner of your eye, which is the only way it is ever going
        -- to be read, and it costs no width -- so the item name gets the room
        -- the old 46-pixel bar was using.
        --
        -- Layers matter here. BACKGROUND and BORDER are both under ARTWORK,
        -- where the icon is, and under OVERLAY, where the text is, so nothing
        -- is drawn on top of the words.
        local band = row:CreateTexture(nil, "BACKGROUND")
        band:SetAllPoints()
        Fill(band, 1, 1, 1, 0.05)

        row.fill = row:CreateTexture(nil, "BORDER")
        row.fill:SetPoint("TOPLEFT")
        row.fill:SetPoint("BOTTOMLEFT")

        row.action = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.action:SetPoint("RIGHT", -30, 0)
        row.action:SetWidth(42)
        row.action:SetJustifyH("RIGHT")

        row.secs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.secs:SetPoint("RIGHT", -4, 0)
        row.secs:SetWidth(24)
        row.secs:SetJustifyH("RIGHT")

        row:SetScript("OnEnter", function(self)
            if not self.rollID then return end
            local p = pendingRolls[self.rollID]
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            if p and p.link then GameTooltip:SetHyperlink(p.link) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffeda55fClick|r to stop the auto-roll and answer this one "
                .. "yourself, with the full roll timer", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" then ShowRollMenu()
            elseif self.rollID then ClaimRoll(self.rollID) end
        end)

        rollWin.rows[i] = row
    end

    -- The recent list scrolls. Rows are built once and drawn into as it moves,
    -- so resizing only has to decide how many of them are on show.
    local scroll = CreateFrame("ScrollFrame", "APLARollScroll", rollWin,
        "FauxScrollFrameTemplate")
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROLL_RECENT_H, RefreshRollWindow)
    end)
    rollWin.scroll = scroll

    rollWin.recent = {}
    for i = 1, MAX_ROLL_RECENT do
        local row = MakeRollRow(rollWin, ROLL_RECENT_H)

        row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.who:SetPoint("RIGHT", -2, 0)
        row.who:SetWidth(90)
        row.who:SetJustifyH("RIGHT")

        row:SetScript("OnEnter", function(self)
            if not self.link then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(self.link)
            if self.res then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Reserved by: " .. self.res, 1, 0.82, 0, true)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" then ShowRollMenu()
            elseif self.link then HandleModifiedItemClick(self.link) end
        end)

        rollWin.recent[i] = row
    end

    local grip = CreateFrame("Button", nil, rollWin)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() rollWin:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        rollWin:StopMovingOrSizing()
        db.rollSize = { w = rollWin:GetWidth(), h = rollWin:GetHeight() }
        RefreshRollWindow()
    end)

    rollWin:SetScript("OnSizeChanged", RefreshRollWindow)

    -- Only the countdown bars animate, so there is nothing to redraw once the
    -- last pending row has gone: sitting open and idle costs one table lookup
    -- a frame. Throttled because a countdown does not need sixty of them.
    local since = 0
    rollWin:SetScript("OnUpdate", function(_, elapsed)
        if not next(pendingRolls) then return end
        since = since + elapsed
        if since < 0.05 then return end
        since = 0
        RefreshRollWindow()
    end)

    HookDefaultFrames()
end

-- Rows hang from the top, so where the recent list starts depends on how many
-- pending rows are above it, and how many of it fit depends on the height the
-- window has been dragged to. Both change, so this runs on every redraw.
-- Returns how many recent rows are on show.
function LayoutRollWindow(npend)
    if not rollWin then return 0 end
    local w, h = rollWin:GetWidth(), rollWin:GetHeight()

    local y = ROLL_HEADER + 4
    for i, row in ipairs(rollWin.rows) do
        row:SetPoint("TOPLEFT", 6, -(y + (i - 1) * ROLL_ROW_H))
        row:SetPoint("TOPRIGHT", -6, -(y + (i - 1) * ROLL_ROW_H))
        row.text:SetWidth(math.max(40, w - 110))   -- icon, action, seconds
    end

    y = y + npend * ROLL_ROW_H
    if npend > 0 then
        rollWin.rule:SetPoint("TOPLEFT", 6, -(y + 3))
        rollWin.rule:SetPoint("TOPRIGHT", -6, -(y + 3))
        y = y + 7
    end

    local shown = math.floor((h - y - ROLL_FOOTER) / ROLL_RECENT_H)
    if shown < 0 then shown = 0 end
    if shown > MAX_ROLL_RECENT then shown = MAX_ROLL_RECENT end

    rollWin.scroll:ClearAllPoints()
    rollWin.scroll:SetPoint("TOPLEFT", 4, -y)
    rollWin.scroll:SetSize(math.max(1, w - 34), math.max(1, shown * ROLL_RECENT_H))

    for i, row in ipairs(rollWin.recent) do
        row:SetPoint("TOPLEFT", 6, -(y + (i - 1) * ROLL_RECENT_H))
        row:SetPoint("TOPRIGHT", -24, -(y + (i - 1) * ROLL_RECENT_H))   -- clear of the bar
        row.text:SetWidth(math.max(40, w - 140))
    end

    rollWin.hint:ClearAllPoints()
    rollWin.hint:SetPoint("TOPLEFT", 8, -(ROLL_HEADER + 8))
    rollWin.hint:SetPoint("TOPRIGHT", -8, -(ROLL_HEADER + 8))

    return shown
end

function RefreshAll()
    if panel and panel:IsShown() then
        RefreshPanel()   -- which ends by updating the minimap button too
    else
        UpdateButtonLook()
    end
    RefreshTracker()
    RefreshRollWindow()
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
f:RegisterEvent("CANCEL_LOOT_ROLL")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_LOOT")
f:RegisterEvent("CHAT_MSG_MONEY")
-- Where a loot addon announces what the master looter is holding. Party and
-- instance chat as well as raid, because a five-man can run master loot too.
for _, ch in ipairs({ "RAID", "RAID_LEADER", "RAID_WARNING", "PARTY", "PARTY_LEADER",
                      "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER" }) do
    f:RegisterEvent("CHAT_MSG_" .. ch)
end

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
        BuildArmPrompt()
        BuildTracker()
        BuildRollWindow()
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

    elseif event:find("^CHAT_MSG_RAID") or event:find("^CHAT_MSG_PARTY")
        or event:find("^CHAT_MSG_INSTANCE_CHAT") then
        local link, reserves = ParseAnnouncement(arg1 or "")
        if link or reserves then LogAnnounced(link, reserves) end

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
            C_Timer.After(3, ShowArmPrompt)
        end

    elseif event == "START_LOOT_ROLL" then
        ProcessRoll(arg1, 0)

    elseif event == "CANCEL_LOOT_ROLL" then
        -- the roll went away without us: somebody else acted, the master
        -- looter stepped in, the group broke up
        CancelPendingRoll(arg1)

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
    elseif cmd == "popup" or cmd == "roll" then
        -- Turning the window off turns the grace off with it. A roll held back
        -- with nowhere to see it is worse than either setting on its own.
        db.hud = not db.hud
        if not db.hud then db.grace = 0 end
        print("|cff66ccffAPLA|r loot popup: " .. HudLabel(db.hud, db.grace))
        RefreshRollWindow()
    elseif cmd == "grace" then
        local n = tonumber(val)
        if n and n >= 0 and n <= 60 then
            db.grace = math.floor(n)
            -- and the window on, for the same reason
            if db.grace > 0 then db.hud = true end
            print("|cff66ccffAPLA|r loot popup: " .. HudLabel(db.hud, db.grace))
            RefreshRollWindow()
        else
            print("|cff66ccffAPLA|r /apla grace <0-60>, seconds; 0 answers straight away")
        end
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
