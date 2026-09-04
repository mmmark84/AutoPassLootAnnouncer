# Changelog

## [1.2.0] - 2026-09-04

### Removed
- The "Also announce when I open a corpse" option and the loot-window announce
  path behind it, along with `/apla corpse`. It only ever helped people who kept
  Blizzard's Pass on Loot option on, which the addon exists to replace, and it
  doubled up with the roll window whenever you were the one looting.
- The "Only one of us announces" option and `/apla coop`. The single-announcer
  election is now always on, which is what it was set to by default anyway.
  Hello messages still carry the old flag so peers on 1.1.1 keep working.

## [1.1.1] - 2026-09-04

### Fixed
- Login no longer throws `attempt to call a nil value`. The PLAYER_LOGIN handler
  seeded `math.random`, but Blizzard removed `math.randomseed` from the addon
  environment and the client seeds it already. The error aborted the rest of the
  handler, so the hello broadcast never went out and peer discovery had to wait
  for the next roster update.

## [1.1.0] - 2026-09-04

### Added
- Pepe mode: prefixes each announcement with a random cheerful pepe from
  Twitch Emotes 2.0, chosen from 24 hand-picked happy ones and never the same
  one twice in a row. Off by default. Toggle in the panel or with `/apla pepe`.

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
