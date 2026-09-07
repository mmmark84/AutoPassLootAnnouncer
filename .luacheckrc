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
    "AutoPassLootAnnouncerTracker",
    "AutoPassLootAnnouncerPresetCode",
    "SlashCmdList",       -- the addon writes its handler into this table
    "StaticPopupDialogs", -- and its login prompt into this one
}

-- WoW API surface this addon touches (read-only)
read_globals = {
    "Ambiguate", "C_ChatInfo", "C_Timer", "ConfirmLootRoll", "CreateFrame",
    "FauxScrollFrame_GetOffset", "FauxScrollFrame_OnVerticalScroll",
    "FauxScrollFrame_Update", "GetCoinTextureString", "HandleModifiedItemClick",
    "COPPER_AMOUNT", "GOLD_AMOUNT", "SILVER_AMOUNT", "LOOT_ITEM", "LOOT_ITEM_MULTIPLE",
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "date",
    "GameTooltip", "GetCursorPosition", "GetItemInfo", "GetLootRollItemInfo",
    "GetLootRollItemLink", "GetLootRollTimeLeft", "GetNumGroupMembers", "GetTime",
    "ITEM_QUALITY_COLORS", "IsInGroup", "IsInRaid", "Minimap",
    "RegisterAddonMessagePrefix", "RollOnLoot", "SendAddonMessage",
    "SendChatMessage", "StaticPopup_Show", "UIParent", "UISpecialFrames",
    "UnitGUID", "UnitName", "tinsert", "time", "wipe",
    "ChatFontNormal", "CloseDropDownMenus", "UIDropDownMenu_AddButton",
    "UIDropDownMenu_CreateInfo", "UIDropDownMenu_Initialize",
    "UIDropDownMenu_JustifyText", "UIDropDownMenu_SetText",
    "UIDropDownMenu_SetWidth",
}
