-- luacheck config for a World of Warcraft addon
std = "lua51"
exclude_files = { ".release/" }

-- The long lines here are tooltip prose, not dense code. luacheck types a
-- line by its last token, so a line ending in a closing quote and comma
-- counts as code however much of it is text, which makes the string-specific
-- limit useless. Longest real line is 192.
max_code_line_length = 200
max_string_line_length = false
max_comment_line_length = false

-- WoW hands every script handler the frame as self, and most handlers here
-- do not need it. 212 is "unused argument".
ignore = { "212/self" }

-- the addon's own globals
globals = {
    "AutoPassLootAnnouncerDB",
    "SLASH_AUTOPASSLOOTANNOUNCER1",
    "SLASH_AUTOPASSLOOTANNOUNCER2",
    "AutoPassLootAnnouncerMinimapButton",
    "AutoPassLootAnnouncerPanel",
    "SlashCmdList",   -- the addon writes its handler into this table
}

-- WoW API surface this addon touches (read-only)
read_globals = {
    "Ambiguate", "C_ChatInfo", "C_Timer", "ConfirmLootRoll", "CreateFrame",
    "GameTooltip", "GetCursorPosition", "GetItemInfo", "GetLootRollItemInfo",
    "GetLootRollItemLink", "GetLootRollTimeLeft", "GetLootSlotLink",
    "GetLootSourceInfo", "GetNumGroupMembers", "GetNumLootItems", "GetTime",
    "ITEM_QUALITY_COLORS", "IsInGroup", "IsInRaid", "Minimap",
    "RegisterAddonMessagePrefix", "RollOnLoot", "SendAddonMessage",
    "SendChatMessage", "UIParent", "UISpecialFrames",
    "UnitGUID", "UnitName", "tinsert", "time", "wipe",
}
