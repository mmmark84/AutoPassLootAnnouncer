# Changelog

## [1.4.0] - 2026-09-06

### Added
- Bind-on-equip drops are split by whether they stack. Stack size is a decent
  stand-in for "is this a commodity": gems, primals and mats stack, gear and
  recipes do not. So an epic gem can pass itself while a BoE pattern off the
  same boss stops and waits for you, which the single BoE row could not
  express. It comes from `GetItemInfo`'s `itemStackCount`, the item's maximum
  stack size rather than the number that dropped.
- `/apla set` takes `stack` for that row, and `all` for every kind at once.
  `both` still works and now means all three.

- Hovering a row name explains what lands in it, with examples.

### Changed
- Poor and common are left alone entirely: no auto-roll, the window stays up
  exactly as it would without the addon running. 1.3.x passed them outright,
  which was never a call the addon should have been making on its own.
- Uncommon gets the same three rows as every other quality, rather than the
  single combined row it had in 1.3.x. That row existed because the qualities
  were stacked flat and each one cost height; behind a tab it costs nothing,
  and green mats split from green gear exactly the way epic ones do.
- The options panel puts each quality behind a tab instead of listing every
  row at once. Three kinds across four qualities is twelve rows of radio
  buttons laid out flat, which made the panel taller than some people's
  screens. The summary underneath still spells out every quality, so nothing
  is hidden, only folded.
- Nothing waits on an answer it will not use: a BoP drop never holds up the
  roll waiting for its stack size, and nothing below rare waits on either.
- The stackable row is seeded from your existing BoE setting on first login,
  so the upgrade changes nothing until you split them. Settings stored for
  qualities below rare are dropped, since they would never be read again.

## [1.3.1] - 2026-09-06

### Fixed
- Uncommon has a row again. 1.3.0 dropped it along with poor and common and
  passed all three outright, which is not a call that setting was there to
  make. It is a single row rather than a BoP/BoE pair, because nobody sorts
  greens by whether they bind, and the addon no longer waits on an item's bind
  type before acting on one. Poor and common stay passed.
- `/apla set` takes quality 2 again. The bind argument is still required but is
  ignored for 2, which writes the one row.

## [1.3.0] - 2026-09-06

### Added
- Roll actions are set per bind type as well as per quality. Rare, epic and
  legendary each have a BoP row and a BoE row, so the BoE epic that is worth
  gold to someone can be left on screen while the BoP one off the same boss is
  passed without a word. Bind type comes from the roll's own `bindOnPickUp`,
  falling back to the item's `bindType` while an unseen item is still being
  fetched; a roll whose bind type never resolves is left alone rather than
  guessed at.
- `/apla set` takes a bind type: `/apla set boe 4 need`. `both` sets the pair.

### Changed
- Poor, common and uncommon no longer have a row each. They are passed, which
  is what they were set to by everyone who ever looked at that grid.
- Existing settings are carried across to both bind types on first login, so
  the upgrade changes nothing until you split them yourself.

## [1.2.1] - 2026-09-04

### Fixed
- Pepe mode no longer picks an animated pepe. Twitch Emotes animates one by
  rewriting the whole chat line and calling `SetText` on it 30 times a second,
  which tears down the links in that line while you point at one, so item
  tooltips on a line carrying `PepeD` or `PepeJAM` would not stay up. Both are
  out of the pool, leaving 22 still frames.

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
