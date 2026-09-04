# Changelog

## [Unreleased]

### Fixed
- Chat prefix is kept when you click away from the field, not only when you
  press Enter. Clicking Test committed nothing, so a freshly typed prefix was
  discarded while still showing in the box. Escape now discards it instead.
- The Test button asks the client for the item link rather than using a
  hand-written one. The old link was short of the fields this client emits and
  the server drops a chat message carrying a malformed link, so Test did
  nothing at all in a party or raid while printing fine when solo.
- Test now says when it can only print locally, either because announcing to
  chat is off or because the channel cap is unreachable while solo.

## [1.0.0] - 2026-09-04

First public release. The addon has been in use in-game before this point,
but this is the first version distributed as a package.

### Added
- Per-quality roll actions: window, pass, greed or need for each item quality
- Single-announcer election between group members running the addon
- Announce channel cap that steps down to whatever channel is available
- Minimap button with armed/idle artwork, options panel, `/apla` commands
- Debug logging via `/apla debug`

### Notes
- Automated rolling and corpse announcing reset to off at every login
- Bind-on-pickup prompts are auto-confirmed only for rolls the addon made itself
