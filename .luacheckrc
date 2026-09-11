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
    "AutoPassLootAnnouncerPopup",
    "AutoPassLootAnnouncerPresetCode",
    "AutoPassLootAnnouncerArmPrompt",
    "AutoPassLootAnnouncerRollWindow",
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
    -- the class a group member is, and the colour for it, so a name can be
    -- written in the participant list the way the game writes names
    "UnitClass", "RAID_CLASS_COLORS",
    "InCombatLockdown", "IsInInstance", "MouseIsOver",
    -- An instance group -- a battleground, an arena, a dungeon-finder party --
    -- takes INSTANCE_CHAT rather than RAID, and the constant that names one is
    -- missing on clients old enough not to have them, so its use is guarded.
    "LE_PARTY_CATEGORY_INSTANCE",
    -- The popup fades rather than blinking out, where the client can.
    "UIFrameFadeOut", "UIFrameFadeRemoveFrame",
    "RegisterAddonMessagePrefix", "RollOnLoot", "SendAddonMessage",
    "SendChatMessage", "StaticPopup_Show", "UIParent", "UISpecialFrames",
    "UnitGUID", "UnitName", "tinsert", "time", "wipe",
    "ChatFontNormal", "CloseDropDownMenus", "UIDropDownMenu_AddButton",
    -- Blizzard's own group-loot frames, held back while a grace period runs.
    -- The container is only in the newer UI, so its use is guarded.
    "GroupLootContainer", "GroupLootContainer_RemoveFrame",
    "GroupLootFrame_OpenNewFrame",
    "UIDropDownMenu_CreateInfo", "UIDropDownMenu_Initialize",
    -- which parent row a dropdown's second level was opened from
    "UIDROPDOWNMENU_MENU_VALUE",
    "UIDropDownMenu_JustifyText", "UIDropDownMenu_SetText",
    "UIDropDownMenu_SetWidth", "ToggleDropDownMenu",
}
