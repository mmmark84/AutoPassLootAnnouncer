-- luacheck config for a World of Warcraft addon
std = "lua51"
exclude_files = { ".release/" }

-- 120 for code, but tooltip and comment prose reads better unwrapped than
-- folded at an arbitrary column.
max_line_length = 130
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
    "UnitGUID", "UnitName", "tinsert", "wipe",
}
