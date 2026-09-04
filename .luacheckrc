-- luacheck config for a World of Warcraft addon
std = "lua51"
max_line_length = 120
exclude_files = { ".release/" }

-- the addon's own globals
globals = {
    "AutoPassLootAnnouncerDB",
    "SLASH_AUTOPASSLOOTANNOUNCER1",
    "SLASH_AUTOPASSLOOTANNOUNCER2",
    "AutoPassLootAnnouncerMinimapButton",
    "AutoPassLootAnnouncerPanel",
}

-- WoW API surface this addon touches (read-only)
read_globals = {
    "Ambiguate", "C_ChatInfo", "C_Timer", "ConfirmLootRoll", "CreateFrame",
    "GameTooltip", "GetCursorPosition", "GetItemInfo", "GetLootRollItemInfo",
    "GetLootRollItemLink", "GetLootRollTimeLeft", "GetLootSlotLink",
    "GetLootSourceInfo", "GetNumGroupMembers", "GetNumLootItems", "GetTime",
    "ITEM_QUALITY_COLORS", "IsInGroup", "IsInRaid", "Minimap",
    "RegisterAddonMessagePrefix", "RollOnLoot", "SendAddonMessage",
    "SendChatMessage", "SlashCmdList", "UIParent", "UISpecialFrames",
    "UnitGUID", "UnitName", "tinsert", "wipe",
}
