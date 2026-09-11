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
    sayMode      = "prefix",  -- what goes in front of the item: your prefix, a
                              -- random happy pepe, or a random silly phrase
    loginArm     = "off",  -- what automated rolling does at login: off / on / ask.
                           -- Account-wide, not per preset: it is a question about
                           -- this session rather than about a role, and when it is
                           -- "ask" the prompt is where you pick the preset anyway.
    hud          = false,  -- the loot window: say what dropped as it drops
    grace        = 0,      -- seconds to wait before answering a roll, 0 = straight away
    popup        = 0,      -- seconds the drop popup shows for, 0 = no popup
    trackMin     = 2,      -- the lowest quality worth showing; see MIN_TRACK
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
    "announce", "channel", "minQuality", "prefix", "sayMode", "hud", "grace", "popup",
    "trackMin", "actionsBoP", "actionsBoE", "actionsBoEStack",
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
-- The loot window, as one cycle button rather than two controls. Showing what
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

-- What goes in front of the item link, as one setting rather than as a
-- checkbox per idea: only one thing can lead a line, and stacking a pepe, a
-- phrase and a prefix onto one announce reads as noise rather than as three
-- settings. So it is a straight choice of the three.
local SAY_MODES = { "prefix", "pepe", "random" }
local SAY_MODE_LABEL = { prefix = "Prefix", pepe = "Pepe", random = "Random" }

local function NextSayMode(cur)
    for i, v in ipairs(SAY_MODES) do
        if v == cur then return SAY_MODES[i % #SAY_MODES + 1] end
    end
    return SAY_MODES[1]
end

-- nil rather than a default for anything that is not one of the three, so the
-- caller can tell "not set" from "set to prefix" and fall back to whatever it
-- has to fall back on -- an older pepe flag, or the default.
local function ValidSayMode(v)
    return SAY_MODE_LABEL[v] and v or nil
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

-- Random mode. Plain text, so it reads the same for everyone whatever they
-- have installed, which is the difference between this and pepe mode. Kept
-- short enough to leave room for the item link on one chat line, and kept
-- clean: this goes out to a raid of strangers under your name.
local RANDOM_LINES = {
    "Ooh, a piece of candy!",
    "Another one.",
    "Ooh, shiny!",
    "My precious...",
    "Mine! Mine! Mine!",
    "It's dangerous to go alone, take this:",
    "A wild item appeared:",
    "Well well well, look at this:",
    "And there it is:",
    "Behold!",
    "Feast your eyes:",
    "Look what the boss coughed up:",
    "The boss dropped its wallet:",
    "Christmas came early:",
    "Delivery for the raid:",
    "Attention shoppers:",
    "Fresh out of the boss:",
    "Somebody order this?",
    "For me? You shouldn't have.",
    "I'll take that, thank you.",
    "Yoink!",
    "Cha-ching!",
    "Ding!",
    "Jackpot!",
    "Winner winner:",
    "Nice.",
    "Not bad. Not bad at all.",
    "That'll do nicely:",
    "Now that's what I call loot:",
    "Certified banger:",
    "Big loot energy:",
    "Loot goblin activated:",
    "Straight to the auction house:",
    "The RNG gods have spoken:",
    "Guess what dropped:",
    "Say hello to:",
    "Somebody's getting an upgrade:",
    "Roll for it, cowards:",
    "Gimme gimme gimme:",
    "Wow. Such loot.",
    "Sheesh:",
    "Rare candy:",
    "Look Mom, I found something:",
    "Shut up and take my gold:",
    "One does not simply pass on this:",
    "Yippee!",
    "Sweet, sweet loot:",
    "Loot check:",
    "Hey look, an item!",
    "May I present:",
}

-- One re-roll when the pick repeats the last one, so it rarely doubles up.
-- Both lists want it, and neither wants to remember more than the last pick:
-- shuffling a bag would stop repeats entirely, and would also mean the same
-- fifty lines in a fixed cycle, which reads as scripted rather than as random.
local function PickFresh(list, last)
    local pick = list[math.random(#list)]
    if pick == last and #list > 1 then
        pick = list[math.random(#list)]
    end
    return pick
end

local lastPepe, lastLine
local function RandomPepe()
    lastPepe = PickFresh(PEPE_HAPPY, lastPepe)
    return lastPepe
end

local function RandomLine()
    lastLine = PickFresh(RANDOM_LINES, lastLine)
    return lastLine
end

-- What leads an announce, or nil for nothing in front of the item at all.
local function SayLead()
    if db.sayMode == "pepe" then return RandomPepe() end
    if db.sayMode == "random" then return RandomLine() end
    if db.prefix and db.prefix ~= "" then return db.prefix end
    return nil
end

local function QualityLabel(v)
    if v < 0 then return "|cff808080nothing|r" end
    return ITEM_QUALITY_COLORS[v].hex .. QUALITY_NAME[v] .. "|r"
end

-- the announce threshold is a minimum (quality >= setting), so spell it out rather
-- than saying "up to", which reads like the roll settings but means the opposite
-- Nothing below uncommon is ever logged: the server only rolls for items at
-- the group's loot threshold and up, and that cannot be set below uncommon. So
-- the threshold starts there, and "everything" would have been a synonym for
-- it rather than a wider answer.
local MIN_TRACK = 2

local function MinLabel(v)
    if v <= MIN_TRACK then return QualityLabel(MIN_TRACK) .. " and better" end
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

    -- and the same for the pepe checkbox each preset was carrying
    for _, p in ipairs(db.presets) do
        local v = p.values
        v.sayMode = ValidSayMode(v.sayMode) or (v.pepe and "pepe") or "prefix"
        v.pepe = nil
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
        -- The mode by name: it is a word either way, since prefix and pepe
        -- share a first letter. pe= goes out alongside it for 1.8 and
        -- earlier, which knew pepe as a checkbox and nothing else.
        ("sm=%s"):format(ValidSayMode(v.sayMode) or defaults.sayMode),
        ("pe=%d"):format(v.sayMode == "pepe" and 1 or 0),
        ("tq=%d"):format(tonumber(v.trackMin) or defaults.trackMin),
        ("h=%d"):format(v.hud and 1 or 0),
        ("g=%d"):format(tonumber(v.grace) or defaults.grace),
        ("f=%d"):format(tonumber(v.popup) or defaults.popup),
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
        sayMode    = ValidSayMode(f.sm and f.sm:lower()) or (flag("pe", false) and "pepe")
                        or defaults.sayMode,
        trackMin   = num("tq", MIN_TRACK, 5, defaults.trackMin),
        hud        = flag("h", defaults.hud),
        grace      = num("g", 0, 60, defaults.grace),
        popup      = num("f", 0, 60, defaults.popup),
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
local LogDrop, LogAnnounced, LogMoney, ClearLog
local AddPendingRoll, CancelPendingRoll, RefreshRollWindow, CloseRollWindow

-- The drop popup. Everything it owns hangs off this one table: the drop log
-- wakes it from a long way above where it is built, and this chunk is at Lua's
-- limit of 200 locals, so it is one name rather than a dozen. Filled in down in
-- its own section.
local pop = {
    W        = 300,   -- the default; db.popupW once it has been dragged
    MIN_W    = 180,
    MAX_W    = 600,
    ROW_H    = 18,
    PAD      = 5,
    MAX_ROWS = 10,    -- rows it can show at once
    MAX_HELD = 20,    -- rows it will hold to be scrolled back through
    offset   = 0,     -- how far back through them the wheel has gone
    FADE     = 0.5,   -- the fade itself, once the wait is over
    STEPS    = { 0, 3, 5, 10 },
    rows     = {},
    burst    = {},    -- the rows this showing is about, oldest first
    queued   = false,
}

function pop.on() return (tonumber(db.popup) or 0) > 0 end

function pop.label(secs)
    secs = tonumber(secs) or 0
    if secs <= 0 then return "off" end
    return secs .. "s"
end

function pop.next(secs)
    secs = tonumber(secs) or 0
    for i, step in ipairs(pop.STEPS) do
        if step == secs then return pop.STEPS[i % #pop.STEPS + 1] end
    end
    return 0   -- a time set by slash command to something off the list
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
        -- Whatever leads the line, then the item. Space separated because
        -- Twitch Emotes only matches a pepe as a whole word.
        local lead = SayLead()
        Say(lead and (lead .. " " .. link) or link)
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
    -- Return 3 is how many dropped for this roll, which is the one thing that
    -- knows the size of a stack before anybody has looted it.
    local rollCount, rollQuality, rollBoP = select(3, GetLootRollItemInfo(rollID))
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

    LogDrop(link, rollCount, nil, true)

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
        AddPendingRoll(rollID, action, link, grace, rollCount)
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
-- The drop log
----------------------------------------------------------------
-- A session lasts as long as you leave it: the log is saved between logins and
-- emptied only when you ask, so a night of trash runs with a logout in
-- the middle is still one list.
--
-- What the log is: the drops that were put to the group. An item the server
-- rolled for -- the window you would have answered without this addon -- and,
-- under master loot, one a loot addon announced. Nothing else.
--
-- It used to be anything that said "receives loot", and that line cannot tell a
-- drop from a disenchant. A run of Stockades came back with Soul Dust and
-- Lesser Astral Essence listed as loot, because they are: someone shredded the
-- greens they had just won. Vashj was worse -- six lines of Vashj's Vial
-- Remnant and four of Tainted Core, which are fight mechanics that arrive
-- through the loot system. None of it was ever offered to anyone, and it buried
-- the drops that were.
--
-- So START_LOOT_ROLL is what makes an item loggable, and the loot message only
-- says who ended up with it. The roll fires before anyone has won, so a drop
-- gets its row there and waits for a name -- one that never gets a name is a
-- drop nobody took.
--
-- A stack is no different, because the roll says how many dropped as well as
-- what did. It used to wait for the loot message on the grounds that nothing
-- else knew the size of it, and the cost of waiting was that a stack was
-- invisible until somebody looted it: no row overhead, no popup, nothing to
-- tell you an epic mat had just dropped. It also meant a stack could only be
-- one row per item with a running total, because there was nothing to hang a
-- drop on -- so the number you read was the night's tally rather than what had
-- just dropped. A row per drop, counted once at the roll and named at the
-- message, answers both.
--
-- The quality slider still filters the view rather than what is kept: a
-- threshold on the way in throws away rows you cannot ask for later, where a
-- filter on the way out can always be widened.
-- Ten thousand is a stop on the saved file rather than a working limit. A
-- night of trash is a few hundred rows, and the loot window adds up what it
-- shows from the whole log, so a row that falls off the front is a drop gone
-- from somebody's total. This is only there so a log nobody ever clears cannot
-- grow without end.
local MAX_LOOT_ROWS     = 10000
local LOOT_MATCH_WINDOW = 180   -- seconds a row waits for its winner
-- How long an item stays loggable after the server offered it. Longer than a
-- roll's two minutes, because the loot message comes when the corpse is looted
-- rather than when the roll ends, and generous is safe here: a disenchant, a
-- quest pickup or a fight's own hand-outs are different items entirely, so a
-- stale entry cannot let one of those through.
local ROLL_MEMORY       = 600
local rolled = {}   -- [itemID] = when the server last put it up for a roll
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
-- `entry` is the log row that changed, and nil means the log was emptied
-- rather than added to. The windows redraw either way; the popup only has
-- something to appear about when there is a row.
--
-- `filled` is that row having been completed rather than added: a name landing
-- on a drop already logged, or its reserves. That is not a new drop and must
-- not read as one -- a popup that has been and gone coming back when somebody
-- loots the corpse says "this dropped" a second time, about an item that only
-- dropped once, which is exactly the wrong thing to tell a raid.
local function LootChanged(entry, filled)
    RefreshRollWindow()
    if filled then pop.update(entry) else pop.wake(entry) end
end

-- winner nil means "this dropped, nobody has won it yet". `offered` is
-- ProcessRoll saying the server has just put this item up for a roll, which is
-- the one moment anything can be sure it is a drop rather than a disenchant.
function LogDrop(link, count, winner, offered)
    if not link then return end

    -- Recorded on the row rather than asked of the item later: the log outlives
    -- the client's item cache, and these are what the window filters and groups
    -- on. Whether it stacks is nil until the client has seen the item, and the
    -- window fills that in when it can -- see EntryStacks.
    local quality = QualityOf(link)
    local stacks  = IsStackable(link)

    local id = ItemID(link)
    if not id then return end

    local entries = db.loot.entries

    if offered then
        rolled[id] = time()
    else
        -- Not from a roll, so it has to be something already accounted for: an
        -- item the server offered a moment ago, or a master-looted one that an
        -- addon announced and which is still waiting to be handed over.
        local known = rolled[id] and (time() - rolled[id]) <= ROLL_MEMORY
        if not known then
            for _, e in ipairs(entries) do
                if e.id == id and e.announced and not e.winner
                    and (time() - e.t) <= ANNOUNCED_MATCH_WINDOW then
                    known = true
                    break
                end
            end
        end
        if not known then
            Dbg("nobody was offered %s, so it is not a drop", tostring(link))
            return
        end
    end

    -- The roll and the loot message both say how many. An announcement does
    -- not, so its row goes in as one and is corrected when the message names a
    -- winner -- an announcement is what dropped, not how much of it.
    local n = count or 1

    if winner then
        -- The row this drop is already on, so the roll and the loot message
        -- between them count it once. Oldest first, so names land in the order
        -- the rolls did rather than backwards -- except where a row is waiting
        -- on this exact count, which is what tells two stacks of the same item
        -- apart when both are in the air.
        local oldest, exact
        for _, e in ipairs(entries) do
            if e.id == id and not e.winner
                and (time() - e.t)
                    <= (e.announced and ANNOUNCED_MATCH_WINDOW or LOOT_MATCH_WINDOW) then
                oldest = oldest or e
                if e.count == n and not exact then exact = e end
            end
        end
        local row = exact or oldest
        if row then
            row.winner, row.count = winner, n
            LootChanged(row, true)
            return
        end
        entries[#entries + 1] = { id = id, link = link, count = n, winner = winner,
                                  q = quality, s = stacks, t = time() }
    else
        entries[#entries + 1] = { id = id, link = link, count = n,
                                  q = quality, s = stacks, t = time() }
    end

    db.loot.started = db.loot.started or time()
    while #entries > MAX_LOOT_ROWS do table.remove(entries, 1) end
    Dbg("logged %s x%d winner=%s", tostring(link), n, tostring(winner))
    LootChanged(entries[#entries])
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

    if not link then
        if reserves and lastAnnounced
            and (time() - lastAnnouncedAt) <= ANNOUNCE_PAIR_WINDOW then
            lastAnnounced.res = reserves
            LootChanged(lastAnnounced, true)
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
        if e.id == id and not e.winner
            and (time() - e.t) <= LOOT_MATCH_WINDOW then
            if reserves then e.res = reserves end
            lastAnnounced, lastAnnouncedAt = e, time()
            LootChanged(e, true)
            return
        end
    end

    local e = { id = id, link = link, count = 1, q = QualityOf(link), s = IsStackable(link),
                t = time(), announced = true, res = reserves }
    entries[#entries + 1] = e
    lastAnnounced, lastAnnouncedAt = e, time()

    db.loot.started = db.loot.started or time()
    while #entries > MAX_LOOT_ROWS do table.remove(entries, 1) end
    Dbg("announced %s res=%s", tostring(link), tostring(reserves))
    LootChanged(e)
end

function LogMoney(copper)
    if not copper or copper <= 0 then return end
    db.loot.money = (db.loot.money or 0) + copper
    db.loot.started = db.loot.started or time()
    RefreshRollWindow()
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
    GameTooltip:AddLine("|cffeda55fMiddle click|r loot window", 1, 1, 1)
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
            -- What used to open the session log. The loot window is the list
            -- now, so this is the switch for it -- and turning it off takes the
            -- grace period with it, the way every other route to off does.
            db.hud = not db.hud
            if not db.hud then db.grace = 0 end
            RefreshRollWindow()
            if panel and panel:IsShown() then RefreshPanel() end
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

-- What the panel starts at. It ends up whatever its rows come to -- the roll
-- summary is as tall as the roll table is wordy, and everything under it is
-- anchored to its bottom -- so this is only the height it is born with, before
-- the first sizing pass.
local PANEL_H = 574

-- Margin under the last row.
local PANEL_PAD = 14

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

-- As tall as its rows, no taller: the last row is the Say it with button, and
-- what moves is the roll summary above it, which grows a line every time the
-- roll table needs another one. Called after the panel is built and again
-- whenever that summary is rewritten.
local function SizePanel()
    if not (panel and panel.sayMode) then return end
    local top, bottom = panel:GetTop(), panel.sayMode:GetBottom()
    -- Both are nil until the frame has a position to be measured from. It has
    -- one from birth, being anchored to the screen, but a client that answers
    -- differently gets the height it was built with rather than an error.
    if not (top and bottom) then return end
    panel:SetHeight(top - bottom + PANEL_PAD)
end

local function BuildPanel()
    panel = CreateFrame("Frame", "AutoPassLootAnnouncerPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(340, PANEL_H)
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

    panel.minimap = MakeCheck(body, "APLACheckMinimap", "Show minimap button", 16, -34,
        nil,
        function(v)
            db.minimapHide = not v
            if v then button:Show() else button:Hide() end
        end)

    panel.pass = MakeCheck(body, "APLACheckPass", "Roll automatically", 16, -60,
        "Master switch for the grid below. With everything set to Pass it just passes on the lot, "
            .. "the same net effect as Blizzard's Pass on Loot checkbox. Never carried between "
            .. "sessions; the button beside this one decides what happens at login.",
        function(v) db.autopass = v; UpdateButtonLook() end)

    -- Sits on the checkbox's own line rather than a row of its own, which keeps
    -- it next to the thing it qualifies and leaves everything below where it is.
    panel.loginArm = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.loginArm:SetSize(120, 20)   -- ends at x=320, inside the frame's inset
    panel.loginArm:SetPoint("TOPLEFT", 200, -59)
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


    -- Placed once the rows below have been laid out, so it cannot land on top
    -- of them: see the anchor after the grid loop.
    panel.summary = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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
        SizePanel()   -- the summary just changed height; the panel follows it
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
    gridHead:SetPoint("TOPLEFT", 24, -96)
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
        tb:SetPoint("TOPLEFT", 22 + (q - MIN_ACTION_QUALITY) * (TAB_W + 3), -112)
        tb:SetScript("OnClick", function() SelectQuality(q) end)
        panel.tabs[q] = tb
    end

    -- a rule across the full width, so the active tab reads as sitting on the
    -- section it opens rather than floating above it
    local tabRule = body:CreateTexture(nil, "BACKGROUND")
    tabRule:SetPoint("TOPLEFT", 22, -136)
    tabRule:SetPoint("TOPRIGHT", -22, -136)
    tabRule:SetHeight(1)
    Fill(tabRule, 1, 1, 1, 0.12)

    local COLX = { 150, 195, 240, 285 }
    for i, a in ipairs(ACTIONS) do
        local h = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOP", body, "TOPLEFT", COLX[i] + 8, -144)
        h:SetText(a.label)
    end

    -- One row per kind, built once and pointed at whichever quality the tabs
    -- are showing. Each carries a hover explaining what lands in it.
    local ROW_TOP, ROW_H = -160, 20
    panel.rows = {}
    for r, kind in ipairs(KINDS) do
        local y = ROW_TOP - (r - 1) * ROW_H
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

    -- Under the last row rather than at a fixed offset: with the grid a row
    -- taller than it once was, the old constant put the first line of the
    -- summary behind the BoE stack radio buttons.
    panel.summary:SetPoint("TOPLEFT", 24, ROW_TOP - #KINDS * ROW_H - 12)

    SelectQuality(4)   -- epic is the one people actually come here to set


    -- Hung off the summary rather than placed under it. The summary is the one
    -- thing on the panel whose height depends on what it says, so everything
    -- below it is anchored to its bottom and the panel is sized to whatever
    -- that comes to. At a fixed offset instead, a wordy roll table would draw
    -- straight through these buttons.
    panel.hud = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.hud:SetSize(180, 22)
    panel.hud:SetPoint("TOPLEFT", panel.summary, "BOTTOMLEFT", -8, -14)
    panel.hud:SetScript("OnClick", function()
        local step = NextHud(db.hud, db.grace)
        db.hud, db.grace = step.hud, step.grace
        RefreshPanel()
        RefreshRollWindow()
    end)
    AttachTooltip(panel.hud, "Loot window", {
        "A small window that says what dropped, and optionally holds the roll long enough for "
            .. "you to take it back. Click to cycle.",
        "|cffffd100Off|r - nothing on screen. Rolls are answered the moment they drop and "
            .. "Blizzard's roll windows are left alone, exactly as without this setting.",
        "|cffffd100Drops only|r - lists what dropped and who took it, as it happens. Rolls are "
            .. "still answered straight away.",
        "|cffffd1003s and up|r - also holds each roll the addon is going to answer for that long "
            .. "and counts down to it, with Blizzard's window held back for those rolls only.",
        "Click a row there to take that one back: the auto-roll is dropped and the normal roll "
            .. "window opens for it, with the full timer still on it.",
        "Doing nothing still rolls for you. That is the point of it.",
    })

    -- The other window. Its own control because it is its own window: this one
    -- has nothing to do with rolls, so it has no grace period on it and there
    -- is nothing to walk through but how long it stays.
    panel.popup = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.popup:SetSize(180, 22)
    panel.popup:SetPoint("TOPLEFT", panel.hud, "TOPLEFT", 0, -26)
    panel.popup:SetScript("OnClick", function()
        db.popup = pop.next(db.popup)
        RefreshPanel()
        -- Show it while you are setting it, because a window that only appears
        -- when something drops is one you can never find to put anywhere. It
        -- fades on its own like any other showing.
        if pop.on() then pop.preview() else pop.gone() end
    end)
    AttachTooltip(panel.popup, "Drop popup", {
        "A small window that appears when something drops, says what it was, and goes again. "
            .. "Click to cycle how long it stays.",
        "Not the loot window in another guise: that one stays where you put it and is where a "
            .. "roll counts down. This has nothing to answer, so it can leave.",
        "Each drop puts the clock back to the full time, so a pack arrives as one window rather "
            .. "than as five, and it is emptied when it goes -- the next pull starts clean.",
        "|cffffd100Never in combat.|r What drops while you are fighting is held back and shown "
            .. "the moment you are not, which is the point of it: you read it while the healer "
            .. "drinks, not while you are being hit.",
        "Drag it by its rows to move it; right-click puts it away early and shift-click links "
            .. "a row in chat.",
        "The corner grip sets the size. Pulled |cffffd100down|r past one row it keeps that "
            .. "height every time, and anything past it scrolls on the mouse wheel, newest at "
            .. "the top. Squashed back to |cffffd100one row|r it goes back to growing with "
            .. "whatever dropped.",
        "It only appears for drops the |cffffd100Show|r threshold lets through, which is set on "
            .. "the loot window's right-click menu. |cffffd100Test|r fakes a pull so you can see "
            .. "it and place it.",
    })

    local test = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    test:SetSize(80, 22)
    test:SetPoint("TOPLEFT", panel.popup, "TOPRIGHT", 52, 0)
    test:SetText("Test")
    test:SetScript("OnClick", function()
        panel.edit:ClearFocus()   -- commit a prefix typed but never entered
        pop.demo()
    end)
    AttachTooltip(test, "Test", {
        "Fakes a pull's worth of drops so you can see the |cffffd100Drop popup|r appear, fill "
            .. "up and go again -- and drag it somewhere while it is there.",
        "None of it is real: nothing is announced, nothing is rolled for, and nothing goes into "
            .. "the drop log.",
    })

    panel.announce = MakeCheck(body, "APLACheckAnnounce", "Announce to chat", 16, 0,
        "Off = print to your own chat frame only, nothing is sent to the group.",
        function(v) db.announce = v; SendHello(true) end)
    panel.announce:ClearAllPoints()
    panel.announce:SetPoint("TOPLEFT", panel.popup, "BOTTOMLEFT", 0, -16)

    panel.chSlider = MakeSlider(body, "APLAChannelSlider", 0, 1, 4, "Say", "Yell",
        "Announce up to: ", function(v) return CHANNEL_NAME[v] end,
        function(v) db.channel = v end)
    panel.chSlider:ClearAllPoints()
    panel.chSlider:SetPoint("TOPLEFT", panel.announce, "TOPLEFT", 8, -40)
    panel.chSlider.tooltipText = "The widest channel to use. It steps down to whatever is actually available: set to Raid, you get raid in a raid and party in a party."

    panel.slider = MakeSlider(body, "APLAQualitySlider", 0, 0, 5, "Poor", "Legendary",
        "Announce: ", MinLabel, function(v) db.minQuality = v end)
    -- Top to top, at the gap these two have always had: a slider carries its
    -- caption above the bar and its end labels below it, so measuring from one
    -- bottom to the next top would be measuring the wrong thing.
    panel.slider:ClearAllPoints()
    panel.slider:SetPoint("TOPLEFT", panel.chSlider, "TOPLEFT", 0, -44)

    -- The last two announce settings. Everything from the checkbox above down
    -- to here decides what gets announced and how it reads; the roll grid and
    -- the two windows above have nothing to do with either, which is the order
    -- the panel is in.
    local edit = CreateFrame("EditBox", "APLAPrefixEdit", body, "InputBoxTemplate")
    edit:SetPoint("TOPLEFT", panel.slider, "TOPLEFT", 72, -36)
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

    local prefixLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixLabel:SetPoint("TOPLEFT", edit, "TOPLEFT", -72, -4)
    prefixLabel:SetText("Chat prefix")
    panel.prefixLabel = prefixLabel

    -- A cycle button rather than three radio buttons, for the same reason At
    -- login is one: three mutually exclusive settings on one row, and the
    -- panel has no height going spare.
    panel.sayMode = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    panel.sayMode:SetSize(190, 22)
    panel.sayMode:SetPoint("TOPLEFT", edit, "TOPLEFT", 0, -28)

    panel.sayLabel = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.sayLabel:SetPoint("TOPLEFT", panel.sayMode, "TOPLEFT", -72, -4)
    panel.sayLabel:SetText("Say it with")
    panel.sayMode:SetScript("OnClick", function()
        edit:ClearFocus()   -- so a prefix you just typed is committed, not lost
        db.sayMode = NextSayMode(db.sayMode)
        RefreshPanel()
    end)
    AttachTooltip(panel.sayMode, "Say it with", {
        "What goes in front of the item when a drop is announced. Click to cycle.",
        "|cffffd100Prefix|r - the text in the box above, and nothing else.",
        "|cffffd100Pepe|r - a random happy pepe instead of the prefix. It shows as a picture "
            .. "for anyone running Twitch Emotes 2.0; everyone else sees the emote name as "
            .. "plain text.",
        "|cffffd100Random|r - a random silly line from a list of fifty, plain text, so it reads "
            .. "the same for everyone. A different one each drop.",
        "One or the other, never two at once: only one thing can lead a line, and all three "
            .. "stacked up reads as noise.",
    })

    SizePanel()
end

function RefreshPanel()
    UIDropDownMenu_SetText(panel.presetDD, ActivePresetName())
    panel.pass:SetChecked(db.autopass)
    panel.announce:SetChecked(db.announce)
    panel.minimap:SetChecked(not db.minimapHide)
    panel.loginArm:SetText("At login: " .. (LOGIN_ARM_LABEL[db.loginArm] or "Off"))
    panel.hud:SetText("Loot window: " .. HudLabel(db.hud, db.grace))
    panel.popup:SetText("Drop popup: " .. pop.label(db.popup))
    panel.chSlider:SetValue(db.channel)
    panel.slider:SetValue(db.minQuality)
    panel.SelectQuality(panel.quality or 4)
    panel.edit:SetText(db.prefix)
    panel.sayMode:SetText(SAY_MODE_LABEL[db.sayMode] or SAY_MODE_LABEL.prefix)
    -- The prefix box is still yours to edit in the other two modes -- it is
    -- what you go back to -- but dimmed, because nothing is being announced
    -- with it right now.
    local usingPrefix = (db.sayMode == "prefix")
    panel.prefixLabel:SetAlpha(usingPrefix and 1 or 0.4)
    panel.edit:SetAlpha(usingPrefix and 1 or 0.4)
    UpdateButtonLook()
end

----------------------------------------------------------------
-- Reading the drop log
----------------------------------------------------------------
-- The three questions both windows ask of a logged row, and nothing that owns
-- a frame. There used to be a third window here -- a session log with tabs, a
-- slider and a Clear button -- and it went because it was a second place to
-- read the same list. The loot window already lists what dropped, is already
-- where the threshold is set, and is already where the log is cleared from.
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The quality a row was logged at. Rows written before the log recorded it
-- fall back to the item's own link, which carries the colour whether or not
-- the client still remembers the item, and the answer is kept on the row so
-- the lookup happens once rather than on every redraw.
local function EntryQuality(e)
    if not e.q then e.q = QualityOf(e.link) or 0 end
    return e.q
end

-- Whether the row's item stacks, kept on the row for the same reason. The
-- client only knows once it has seen the item, which after a fresh login it
-- may not have, so a row without the answer is asked again on every redraw
-- and its item is noted, so that the client saying "here it is" can redraw the
-- window -- GET_ITEM_INFO_RECEIVED, down in the events. Until then the row
-- reads as one that does not stack.
local stackWait = {}   -- [itemID] = true while a row waits on the client for it
local function EntryStacks(e)
    if e.s == nil then
        local s = IsStackable(e.link)
        if s == nil then
            stackWait[e.id] = true
            return false
        end
        e.s = s
    end
    return e.s
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
local ROLL_MIN_W, ROLL_MIN_H = 260, 120
local ROLL_MAX_W, ROLL_MAX_H = 600, 700
-- Row frames for the list of what dropped: as many as fit the window at its
-- tallest with nothing pending above them. That is how many are on screen at
-- once, and says nothing about how many there are -- the list has no cap, and
-- the scroll bar goes the rest of the way. It used to stop at thirty rows,
-- which three hours of trash went past without anybody being told.
local ROLL_RECENT_FRAMES =
    math.ceil((ROLL_MAX_H - ROLL_HEADER - 4 - ROLL_FOOTER) / ROLL_RECENT_H)

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
-- The drop log read whole rather than a second list of its own, so the
-- quality threshold on the right-click menu filters this too and there is only
-- ever one list to keep straight. The whole of it: this window is where a
-- night of farming is added up, and a total that quietly stops counting at
-- thirty rows is a wrong total. The rows scroll; nothing is left out.
--
-- One row per item per winner rather than one per drop: three Hearts of
-- Darkness that all went the same way read as an "x3" beside the name, which
-- is the question this window is being asked -- who ended up with what. The
-- log itself is still a drop a row, so the popup goes on showing only the ones
-- that landed while it was up.
--
-- Grouped rather than in the order they fell: epics first, then rares, then
-- uncommons, and within each quality the ones that stack ahead of the ones
-- that do not. A trash farm is settled up by its stackable epics and rares --
-- the gems, the hearts, the marks -- and those belong at the top rather than
-- wherever the last green pushed them. Within a group the same item's rows sit
-- together, biggest pile first, so "who has the hearts" is one glance rather
-- than a search. Newest-first is the popup's job, and the rolls pending above
-- this list are still the thing that just happened.
local function RecentEntries()
    local function Group(e)   -- higher sorts first
        return EntryQuality(e) * 2 + (EntryStacks(e) and 1 or 0)
    end

    local function Caption(g)
        return QualityLabel(math.floor(g / 2))
            .. (g % 2 == 1 and " |cff808080stackable|r" or " |cff808080not stackable|r")
    end

    local function Before(a, b)
        if a.g ~= b.g then return a.g > b.g end
        if a.name ~= b.name then return a.name < b.name end
        -- taken ahead of still lying there; the biggest share first among the
        -- taken, the newest first among the rest
        if (a.winner == nil) ~= (b.winner == nil) then return a.winner ~= nil end
        if a.count ~= b.count then return a.count > b.count end
        if a.winner ~= b.winner then return a.winner < b.winner end
        return a.t > b.t
    end

    -- START_LOOT_ROLL puts a winner-less row in the log for the same drop that
    -- is sitting in the pending list above, and one item on two lines of a
    -- small window is noise. Skipped until it has a winner, at which point it
    -- has stopped being the thing overhead and become the thing that happened.
    local waiting = {}
    for _, p in pairs(pendingRolls) do
        if p.itemID then waiting[p.itemID] = true end
    end

    -- [itemID][winner] = the row already standing for those drops. Only won
    -- rows fold: one still waiting for a name is a drop in the air, and how
    -- many of those are up is worth seeing rather than summing.
    local folded = {}

    local rows, all = {}, db.loot.entries
    for i = #all, 1, -1 do
        local e = all[i]
        local stillRolling = waiting[e.id] and not e.winner
        if not stillRolling and EntryQuality(e) >= (db.trackMin or 0) then
            local into = e.winner and folded[e.id] and folded[e.id][e.winner]
            if into then
                into.count = into.count + (e.count or 1)
            else
                -- A copy of the row, not the row: a total is this window's
                -- reading of the log, and nothing the log should be told.
                local row = { id = e.id, link = e.link, count = e.count or 1,
                              winner = e.winner, res = e.res, q = e.q, t = e.t or 0,
                              g = Group(e),
                              name = (e.link:match("%[(.-)%]") or e.link):lower() }
                rows[#rows + 1] = row
                if e.winner then
                    folded[e.id] = folded[e.id] or {}
                    folded[e.id][e.winner] = row
                end
            end
        end
    end
    table.sort(rows, Before)

    -- A caption where one group gives way to the next, so the split reads
    -- without knowing the rule. It is a row of the list like any other, which
    -- is what lets it scroll with the rest.
    local out, group = {}, nil
    for _, row in ipairs(rows) do
        if row.g ~= group then
            group = row.g
            out[#out + 1] = { header = Caption(group) }
        end
        out[#out + 1] = row
    end
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
            -- The same "x2" the log rows carry: how many are on offer is part
            -- of what you are answering, and the roll knows it.
            row.text:SetText(r.p.link
                and ((r.p.count or 1) > 1
                     and (r.p.link .. " |cffffffffx" .. r.p.count .. "|r") or r.p.link)
                or ("roll #" .. r.id))
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
        if e and e.header then
            -- a group caption: no item, so nothing to hover, link or click
            row.link, row.res = nil, nil
            row.icon:Hide()
            row.band:Show()
            row.text:SetText(e.header)
            row.who:SetText("")
            row:Show()
        elseif e then
            row.link, row.res = e.link, e.res
            row.icon:Show()
            row.band:Hide()
            row.icon:SetTexture(select(10, GetItemInfo(e.link)) or UNKNOWN_ICON)
            row.text:SetText(e.count > 1 and (e.link .. " |cffffffffx" .. e.count .. "|r")
                or e.link)
            if not e.winner and e.res then
                row.who:SetText("|cff9d7fd0" .. ShortReserve(e.res) .. "|r")
            else
                row.who:SetText(e.winner and ("|cff808080" .. e.winner .. "|r") or "")
            end
            row:Show()
        else
            row.link, row.res = nil, nil
            row:Hide()
        end
    end

    -- a divider only when there is something on both sides of it
    if npend > 0 and #recent > 0 then rollWin.rule:Show() else rollWin.rule:Hide() end

    -- Nothing rather than "0c": a window that has never seen a copper has
    -- nothing to say about it.
    local copper = db.loot.money or 0
    rollWin.money:SetText(copper > 0 and GetCoinTextureString(copper, 12) or "")

    if npend == 0 and #recent == 0 then
        -- The one dependency worth spelling out: the drops half of this window
        -- reads the drop log, and there is no log until tracking is on.
        rollWin.hint:SetText("Nothing yet.")
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
function AddPendingRoll(rollID, action, link, grace, count)
    pendingRolls[rollID] = {
        action = action, link = link, itemID = ItemID(link),
        count = count or 1,
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
    print("|cff66ccffAPLA|r loot window off, and the grace period with it")
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
local rollMenu

local function RollMenuInit(_, level)
    level = level or 1
    if level ~= 1 then return end

    local function Add(fields)
        local info = UIDropDownMenu_CreateInfo()
        for k, v in pairs(fields) do info[k] = v end
        UIDropDownMenu_AddButton(info, level)
    end

    Add({ text = "Show", isTitle = true, notCheckable = true })

    for q = MIN_TRACK, 5 do
        Add({
            -- MinLabel already colours the quality; it is written lower case
            -- for the middle of a slider caption, which is not this
            text = MinLabel(q),
            checked = (db.trackMin or 0) == q,
            func = function()
                db.trackMin = q
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

    -- Your share of the coin since the log was last cleared. A farm is measured
    -- in what it paid as well as in what it dropped, and the log was already
    -- keeping the figure with nowhere to show it. Stretched between the hint
    -- and the X and right-aligned, so it sits on neither however narrow the
    -- window is dragged.
    rollWin.money = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rollWin.money:SetPoint("LEFT", hintText, "RIGHT", 8, 0)
    rollWin.money:SetPoint("RIGHT", close, "LEFT", -2, 0)
    rollWin.money:SetJustifyH("RIGHT")

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
    for i = 1, ROLL_RECENT_FRAMES do
        local row = MakeRollRow(rollWin, ROLL_RECENT_H)

        -- Faint, and only under a group caption, so the captions read as the
        -- seams of the list rather than as rows of it.
        row.band = row:CreateTexture(nil, "BACKGROUND")
        row.band:SetAllPoints()
        Fill(row.band, 1, 1, 1, 0.06)
        row.band:Hide()

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
    if shown > ROLL_RECENT_FRAMES then shown = ROLL_RECENT_FRAMES end

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

----------------------------------------------------------------
-- The drop popup
----------------------------------------------------------------
-- A second window, and deliberately not a second mode of the first one.
--
-- The loot window is a fixture: you turn it on, it stays where you put it, it
-- is where a roll counts down and where you click to take one back. A window
-- you may have to answer is a window that has to stay.
--
-- This is the opposite of a fixture. It appears when something drops, says what
-- it was, and goes -- the thing you glance at in the quiet after a pull, while
-- the healer drinks and somebody is looting. So it has nothing to do with
-- rolls: no grace period, no countdown, nothing to answer. It is off screen in
-- combat for the same reason, and what drops while you are fighting is held
-- back for the moment you are not.
--
-- Each drop puts its clock back to the full time, so a pack arrives as one
-- window rather than as five. When the clock runs out it is wiped as well as
-- hidden, so the next pull opens on an empty popup rather than on the tail of
-- the last one. The drop log keeps all of it, which is what the drop log is
-- for.

-- What to draw: the burst, newest first.
function pop.list()
    local out = {}
    for i = #pop.burst, 1, -1 do
        out[#out + 1] = pop.burst[i]
        if #out >= pop.MAX_HELD then break end
    end
    return out
end

-- How many rows are on show, and how far down the list they start.
--
-- A height you have set is a height it keeps, whatever is on it: a window that
-- resizes itself under the cursor is one you cannot read, and the whole point
-- of setting one is that it stops moving. Everything past it scrolls, newest
-- first, so a full window is always showing the thing that just dropped.
--
-- No height set -- one row, which is as small as the grip goes -- and it grows
-- with the list instead, which is what it did before there was a choice.
function pop.shownRows(count)
    local fixed = tonumber(db.popupRows) or 0
    local shown
    if fixed > 1 then
        shown = math.min(fixed, pop.MAX_ROWS)
    else
        shown = math.max(1, math.min(count, pop.MAX_ROWS))
    end
    return shown, math.max(0, math.min(pop.offset or 0, count - shown))
end

function pop.build()
    -- The same dark panel and hairline as the loot window: they are the addon's
    -- two windows that sit over the game rather than over the UI.
    local f = CreateFrame("Frame", "AutoPassLootAnnouncerPopup", UIParent)
    f:SetSize(pop.W, pop.ROW_H + pop.PAD * 2)
    f:SetPoint("CENTER", 0, 260)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("LOW")   -- for the reason the loot window is there
    f:Hide()

    f:SetResizable(true)

    -- Nothing to do until there is more held than shown, which is either a
    -- height you have set or more than ten things off one pull.
    local function Wheel(_, delta)
        local count = #pop.list()
        local shown = pop.shownRows(count)
        if count <= shown then return end
        pop.offset = math.max(0, math.min(count - shown, (pop.offset or 0) - delta))
        pop.refresh()
        pop.at = GetTime() + (tonumber(db.popup) or 0)   -- reading it is wanting it
    end
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", Wheel)
    pop.wheel = Wheel

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() pop.held = true; f:StartMoving() end)
    f:SetScript("OnDragStop", function() pop.savePos() end)
    -- Right-click puts it away now rather than in a few seconds. There is no
    -- menu on it: it is not up long enough to be configured from, and what you
    -- would set is on the loot window's menu and the settings panel.
    f:SetScript("OnMouseUp", function(_, mouseButton)
        if mouseButton == "RightButton" then pop.gone() end
    end)

    if db.popupPos then
        f:ClearAllPoints()
        f:SetPoint(db.popupPos.point, UIParent, db.popupPos.rel,
            db.popupPos.x, db.popupPos.y)
    end

    local edge = f:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    Fill(edge, 1, 1, 1, 0.10)

    local bg = f:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    Fill(bg, 0, 0, 0, 0.60)   -- semi-transparent: it sits over the game

    for i = 1, pop.MAX_ROWS do
        local row = MakeRollRow(f, pop.ROW_H)
        row:SetPoint("TOPLEFT", pop.PAD, -(pop.PAD + (i - 1) * pop.ROW_H))

        -- The rows cover nearly all of it, and a button swallows what it is not
        -- told to pass on, so each one hands its drag to the window. Without
        -- this there is nowhere to grab: it has no header to spare the room for.
        row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function() pop.held = true; f:StartMoving() end)
        row:SetScript("OnDragStop", function() pop.savePos() end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", pop.wheel)

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
            if mouseButton == "RightButton" then pop.gone()
            elseif self.link then HandleModifiedItemClick(self.link) end
        end)

        pop.rows[i] = row
    end

    -- Drag it down and the height you leave it at is the height it keeps; drag
    -- it back up to a single row and it goes back to growing with the list.
    -- One row is the smallest the grip goes, so "as small as it will go" is
    -- also how you ask for no fixed size at all.
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    local minH = pop.ROW_H + pop.PAD * 2
    local maxH = pop.MAX_ROWS * pop.ROW_H + pop.PAD * 2
    grip:SetScript("OnMouseDown", function()
        if f.SetResizeBounds then
            f:SetResizeBounds(pop.MIN_W, minH, pop.MAX_W, maxH)
        else
            f:SetMinResize(pop.MIN_W, minH)
            f:SetMaxResize(pop.MAX_W, maxH)
        end
        pop.held = true
        f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        pop.held = false
        f:StopMovingOrSizing()
        db.popupW = math.floor(f:GetWidth() + 0.5)

        -- Snapped to whole rows: half a row of window is not a size anyone
        -- meant to ask for.
        local rows = math.floor((f:GetHeight() - pop.PAD * 2) / pop.ROW_H + 0.5)
        db.popupRows = rows > 1 and math.min(rows, pop.MAX_ROWS) or nil

        pop.offset = 0
        pop.layout()
        pop.refresh()
    end)

    pop.frame = f
    pop.layout()
end

function pop.savePos()
    local f = pop.frame
    if not f then return end
    pop.held = false
    f:StopMovingOrSizing()
    local point, _, rel, x, y = f:GetPoint()
    db.popupPos = { point = point, rel = rel, x = x, y = y }
end

-- Rows are as wide as the window, and the item name gets whatever the icon and
-- the winner column leave it.
function pop.layout()
    local f = pop.frame
    if not f then return end

    local w = math.max(pop.MIN_W, math.min(pop.MAX_W, tonumber(db.popupW) or pop.W))
    f:SetWidth(w)
    for _, row in ipairs(pop.rows) do
        row:SetWidth(w - pop.PAD * 2)
        row.text:SetWidth(w - pop.PAD * 2 - pop.ROW_H - 95)
    end
end

-- A row already on show has changed: the name has arrived on a drop the
-- window is still holding, or the reserves have. Redrawn in place and nothing
-- more -- the window is not opened for it, and its clock is not put back,
-- because neither the drop nor the wait for it started again.
--
-- Nothing to do if the popup has already been and gone: the drop was shown
-- when it dropped, which is what this window is for, and who ended up with it
-- is the loot window's business.
function pop.update(entry)
    if not entry then return end
    if not pop.frame or not pop.frame:IsShown() then return end
    for _, e in ipairs(pop.burst) do
        if e == entry then pop.refresh() return end
    end
end

function pop.refresh()
    if not pop.frame then return end

    local list = pop.list()
    local shown, offset = pop.shownRows(#list)
    pop.offset = offset

    for i, row in ipairs(pop.rows) do
        local e = (i <= shown) and list[offset + i] or nil
        if e then
            -- a made-up row has no item behind it, so it gets no link either,
            -- and brings its own icon since there is nothing to ask
            row.link, row.res = (not e.sample) and e.link or nil, e.res
            row.icon:SetTexture(e.icon
                or (not e.sample and select(10, GetItemInfo(e.link)))
                or UNKNOWN_ICON)
            row.text:SetText(e.count > 1 and (e.link .. " |cffffffffx" .. e.count .. "|r")
                or e.link)
            if not e.winner and e.res then
                row.who:SetText("|cff9d7fd0" .. ShortReserve(e.res) .. "|r")
            else
                row.who:SetText(e.winner and ("|cff808080" .. e.winner .. "|r") or "")
            end
            row:Show()
        else
            row.link, row.res = nil, nil
            row:Hide()
        end
    end

    pop.frame:SetHeight(shown * pop.ROW_H + pop.PAD * 2)
end

-- Gone means gone: hidden and wiped, so the next drop starts a fresh one.
function pop.gone()
    pop.at = nil
    pop.offset = 0
    pop.held = false
    for i = #pop.burst, 1, -1 do pop.burst[i] = nil end
    if pop.frame then
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(pop.frame) end
        pop.frame:SetAlpha(1)
        pop.frame:Hide()
    end
end

-- Combat takes it off screen without wiping it: what dropped is still owed to
-- you, and leaving combat is where that is paid.
function pop.duck()
    if pop.frame and pop.frame:IsShown() then
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(pop.frame) end
        pop.frame:SetAlpha(1)
        pop.frame:Hide()
    end
end

function pop.tick()
    pop.queued = false
    local f = pop.frame
    if not f or not f:IsShown() or not pop.at then return end

    if InCombatLockdown() then pop.duck(); return end

    -- Reading it counts as still wanting it, and so does having hold of it:
    -- the cursor wanders off the frame while you drag a corner, and a window
    -- that fades out from under a resize is a window you cannot resize.
    if pop.held or (MouseIsOver and MouseIsOver(f)) then
        pop.at = GetTime() + (tonumber(db.popup) or 0)
    end

    local left = pop.at - GetTime()
    if left > 0.05 then
        pop.queued = true
        -- capped, so letting go of the mouse is noticed within the second
        C_Timer.After(math.min(left, 1), pop.tick)
        return
    end

    pop.at = nil
    if UIFrameFadeOut then
        UIFrameFadeOut(f, pop.FADE, f:GetAlpha(), 0)
        -- a drop during the fade sets the clock again, and this leaves it be
        C_Timer.After(pop.FADE, function() if not pop.at then pop.gone() end end)
    else
        pop.gone()
    end
end

-- A pull's worth of drops, which is what the Test button does. Rows rather
-- than log entries: nothing here is written down, and nothing here is an item
-- you can click, because none of it happened.
--
-- It used to test the chat announcement instead, which was the wrong thing to
-- put behind that button. What you cannot picture from the settings is where
-- this window sits and how long it lasts, and that is what a test is for.
function pop.demo()
    if not pop.on() then
        print("|cff66ccffAPLA|r the drop popup is off -- it is the button beside Test")
        return
    end
    if InCombatLockdown() then
        print("|cff66ccffAPLA|r not while you are fighting: that is the point of it")
        return
    end

    pop.gone()

    local me = Me()
    local pull = {
        { link = "|cffa335ee[Crimson Spinel]|r", winner = me,
          icon = "Interface\\Icons\\INV_Misc_Gem_Ruby_02" },
        { link = "|cffa335ee[Pattern: Swiftheal Mantle]|r",
          icon = "Interface\\Icons\\INV_Scroll_03" },
        { link = "|cff0070dd[Living Ruby]|r", count = 2, winner = me,
          icon = "Interface\\Icons\\INV_Misc_Gem_Ruby_01" },
    }

    -- Spread out, so the clock going back to the full time on each one is the
    -- thing you actually see happen.
    for i, row in ipairs(pull) do
        row.sample, row.count, row.q = true, row.count or 1, 5
        C_Timer.After((i - 1) * 0.9, function()
            if pop.on() then pop.wake(row, true) end
        end)
    end
end

-- What the panel shows you while you are choosing where it lives. A real
-- showing in every respect, so what you are aiming at is the thing itself.
function pop.preview()
    if not pop.on() then return end
    if not pop.frame then pop.build() end
    -- Not a real item link: nothing should be able to open a tooltip on it or
    -- paste it into chat, so the row is marked and drawn as plain text.
    pop.sample = pop.sample or {
        link = "|cff1eff00[Drag me anywhere]|r", count = 1, q = 5,
        winner = "corner resizes", sample = true,
    }
    local held = false
    for _, e in ipairs(pop.burst) do if e == pop.sample then held = true end end
    if not held then pop.burst[#pop.burst + 1] = pop.sample end
    pop.wake(pop.sample, true)
end

-- `entry` is the log row that just changed; nil means "show what you are
-- holding", which is what leaving combat asks for.
-- `force` is the panel showing you where the window lives: it answers to
-- nothing, not the threshold and not whether the log is even on, because you
-- are aiming at it rather than reading it.
function pop.wake(entry, force)
    if not pop.on() then return end

    if entry then
        -- The same threshold the windows filter on, so a trash pull does not
        -- keep putting a popup on screen while the epics still do.
        local q = entry.q or QualityOf(entry.link) or 0
        if not force and q < (db.trackMin or 0) then return end

        local seen = false
        for _, e in ipairs(pop.burst) do
            if e == entry then seen = true break end
        end
        if not seen then
            pop.burst[#pop.burst + 1] = entry
            while #pop.burst > pop.MAX_HELD do table.remove(pop.burst, 1) end
            pop.offset = 0   -- something new: back to the top of the list
        end
    elseif #pop.burst == 0 then
        return
    end

    -- Collected either way; shown only once you are not busy.
    if InCombatLockdown() then return end

    if not pop.frame then pop.build() end
    if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(pop.frame) end
    pop.frame:SetAlpha(1)
    pop.refresh()
    pop.frame:Show()

    pop.at = GetTime() + (tonumber(db.popup) or 0)
    if not pop.queued then
        pop.queued = true
        C_Timer.After(math.min(tonumber(db.popup) or 1, 1), pop.tick)
    end
end

function RefreshAll()
    if panel and panel:IsShown() then
        RefreshPanel()   -- which ends by updating the minimap button too
    else
        UpdateButtonLook()
    end
    RefreshRollWindow()
    if not pop.on() then pop.gone() end
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
-- The client saying it now knows an item, which is when a logged row can find
-- out whether it stacks. Guarded, because a client without the event refuses
-- to register it, and the window gets by without.
pcall(f.RegisterEvent, f, "GET_ITEM_INFO_RECEIVED")
-- The popup is not on screen in a fight, and what dropped during one is shown
-- the moment it ends.
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
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

        -- The threshold used to go down to poor, from when the log took
        -- everything that said "receives loot". Nothing below uncommon is
        -- logged now, so a stored 0 or 1 is a setting with no row to tick.
        if (tonumber(db.trackMin) or 0) < MIN_TRACK then db.trackMin = MIN_TRACK end

        -- Pepe used to be a checkbox on top of the prefix. It is one of three
        -- things that can lead a line now, so a file that had it ticked comes
        -- across as pepe mode and one that did not keeps its prefix.
        db.sayMode = ValidSayMode(db.sayMode) or (db.pepe and "pepe") or "prefix"
        db.pepe = nil

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

        -- A stack used to be one row per item with a running total and a tally
        -- of who took how many, split back out per winner only when it was
        -- drawn. Stacks are logged a drop at a time now, so a file written
        -- before that is split once, here, and the tally is done with.
        local rows = {}
        for _, e in ipairs(db.loot.entries) do
            local by = e.stack and e.by
            if by then
                local names = {}
                for who in pairs(by) do names[#names + 1] = who end
                table.sort(names)
                for _, who in ipairs(names) do
                    rows[#rows + 1] = { id = e.id, link = e.link, count = by[who],
                                        winner = who, q = e.q, t = e.t }
                end
            else
                -- Older still: a total with nothing to say where it went, so
                -- it keeps the total and reads as a drop nobody took, which is
                -- as close to the truth as the row can get.
                e.stack, e.by = nil, nil
                rows[#rows + 1] = e
            end
        end
        db.loot.entries = rows

        -- Last, so the preset it makes on a first run under this version is a
        -- copy of the settings after every migration above has run, not of the
        -- half-converted ones on the way in.
        EnsurePresets()

        BuildButton()
        BuildPanel()
        BuildPresetCode()
        BuildArmPrompt()
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

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- only when a row on show was waiting on this item; the event fires
        -- for every tooltip and bag the client fills in
        if stackWait[arg1] then
            stackWait[arg1] = nil
            RefreshRollWindow()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        pop.duck()

    elseif event == "PLAYER_REGEN_ENABLED" then
        pop.wake()

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
    elseif cmd == "window" or cmd == "roll" then
        -- Turning the window off turns the grace off with it. A roll held back
        -- with nowhere to see it is worse than either setting on its own.
        db.hud = not db.hud
        if not db.hud then db.grace = 0 end
        print("|cff66ccffAPLA|r loot window: " .. HudLabel(db.hud, db.grace))
        RefreshRollWindow()
    elseif cmd == "popup" then
        -- Seconds, or nothing to turn it on and off. "popup" used to open the
        -- loot window, which is now "window": the popup is a window of its own
        -- and has the better claim on the name.
        local n = tonumber(val)
        if val and val ~= "" and not (n and n >= 0 and n <= 60) then
            print("|cff66ccffAPLA|r /apla popup <0-60>, seconds; 0 turns it off")
        else
            if n then
                db.popup = math.floor(n)
            else
                db.popup = pop.on() and 0 or 5
            end
            print("|cff66ccffAPLA|r drop popup: " .. pop.label(db.popup))
            if pop.on() then pop.preview() else pop.gone() end
            if panel and panel:IsShown() then RefreshPanel() end
        end
    elseif cmd == "grace" then
        local n = tonumber(val)
        if n and n >= 0 and n <= 60 then
            db.grace = math.floor(n)
            -- and the window on, for the same reason
            if db.grace > 0 then db.hud = true end
            print("|cff66ccffAPLA|r loot window: " .. HudLabel(db.hud, db.grace))
            RefreshRollWindow()
        else
            print("|cff66ccffAPLA|r /apla grace <0-60>, seconds; 0 answers straight away")
        end
    elseif cmd == "mode" or cmd == "say" then
        local m = ValidSayMode(val)
        if m then
            db.sayMode = m
            print("|cff66ccffAPLA|r say it with: " .. SAY_MODE_LABEL[m])
        else
            print("|cff66ccffAPLA|r /apla mode prefix|pepe|random (now: "
                .. (SAY_MODE_LABEL[db.sayMode] or "?") .. ")")
        end
    elseif cmd == "pepe" then
        -- Still here because it was a toggle for six versions: it flips
        -- between pepe and your prefix, and leaves random to /apla mode.
        db.sayMode = (db.sayMode == "pepe") and "prefix" or "pepe"
        print("|cff66ccffAPLA|r say it with: " .. SAY_MODE_LABEL[db.sayMode])
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
