# Changelog

## [1.7.3] - 2026-09-08

### Added
- A drop popup: a small window that appears when something drops, says what it
  was, and goes again. Off by default; the **Drop popup** button on the settings
  panel cycles off, 3, 5 and 10 seconds, and `/apla popup <0-60>` does the same.
- It is a second window rather than a second mode of the loot window, because
  the two want opposite manners. The loot window is a fixture: you turn it on,
  it stays where you put it, and it is where a roll counts down and where you
  click to take one back. A window you may have to answer is a window that has
  to stay. This one has nothing to answer, so it can leave.
- A pack arrives as one window: each drop puts the clock back to the full time,
  so five things off one pull are five lines rather than five popups.
- It is emptied when it goes, so the next pull opens on a clean window rather
  than on the tail of the last one. The drop log keeps all of it -- the wipe is
  what the popup is showing, not what was recorded.
- Never on screen in a fight. What drops while you are fighting is held back and
  shown the moment you are not, which is the point of it: you read it in the
  quiet after the pull while the healer drinks, not while you are being hit.
- No grace period and no countdown on it, deliberately. Taking a roll back is
  the loot window's job and that window stays up precisely because it might
  need you. Run both if you want both.
- Drag to move, right-click to put it away early, shift-click a row to link it.
  Its position is remembered per account, it only appears for drops the Show
  threshold lets through, and it needs Track drops on since it reads that log.
- It is part of a preset, so a raid preset can run it and a five-man preset
  leave it off.

### Changed
- `/apla window` opens and closes the loot window; `/apla roll` still does too.
  `/apla popup` now belongs to the popup, which has the better claim on the
  name.
- The settings panel calls the first button **Loot window** rather than Popup,
  now that there is a popup for it to be confused with.

## [1.7.2] - 2026-09-08

### Added
- Master-looted drops appear in the window when they drop, rather than when
  somebody is handed one. Under master loot there is no roll to hang a drop on,
  so until now the first the log heard of an item was "X receives loot", which
  is the end of the story rather than the start of it. What the raid does see
  is the loot master's addon announcing the drop, and that is what these rows
  are read from.
- Reserves are kept with the drop. A row nobody has won yet shows who is first
  in line and how many are behind -- "Zenoss +1" -- and the names in full are on
  the row's tooltip. The winner replaces them when the item is handed over, and
  the reserves stay on the row for reference.
- Only two shapes are read, and both of them are an addon talking rather than a
  person: Gargul, which stamps a raid marker and its own name in front of
  everything it says to the group, and LootReserve, which says "<item> is
  reserved by: ...". A raider linking an item to ask who needs it is not an
  announcement and is left alone.
- An announced item waits half an hour for its name instead of the three
  minutes a roll gets, because a master looter deliberating is not a
  ten-second roll. An item that is announced and rolled -- Gargul alongside
  group loot -- fills the row already waiting rather than listing it twice.

### Fixed
- The addon no longer makes the client say "You are not in a raid group" every
  few seconds in a battleground or arena. A battleground group is an *instance*
  group and its addon traffic has to go to INSTANCE_CHAT; sent to RAID, as it
  was, the client rejects it and says so. Battlegrounds churn their roster
  constantly and every roster change sends a hello, which is what made it a
  message every few seconds rather than an occasional one. Hellos are no longer
  sent in a battleground or arena at all -- there is no group loot there to
  elect an announcer for -- and everywhere else that is an instance group, a
  dungeon-finder party included, both the hellos and the announcements go to
  INSTANCE_CHAT.

## [1.7.1] - 2026-09-08

### Changed
- A stacked row says who took the stack rather than "stacked". The log already
  recorded who took how many, so a stack that went to one person now reads as
  that many with their name on it, and one split between people becomes a line
  each -- two to you, one to somebody else -- instead of a single total that
  says nothing about where it went. Rows logged before those per-winner counts
  existed have no answer to give and still read "stacked".
- Both windows split a stack the same way, so the drop log's Everything tab and
  the loot window agree about where a stack went. The Mine tab already answered
  per character and is unchanged.

### Fixed
- Five locals that shadowed an upvalue of the same name, which had no effect on
  what the addon did but made the lines around them read as though it might.

## [1.7.0] - 2026-09-07

### Added
- An optional loot window: what dropped, as it drops, and optionally a grace
  period in front of the automatic roll so there is a moment to take one back.
  Off by default, and off means nothing on screen, nothing held, and Blizzard's
  roll windows left alone -- exactly as before.
- One control rather than two. Showing what dropped and holding a roll long
  enough to react were asked for separately and are separable, but they are
  points on one line -- tell me nothing, tell me, tell me and wait for me -- so
  the Popup button at the bottom of the panel walks it: off, drops only, then
  3, 5, 8 and 12 seconds of grace.
- Once on, the window stays on screen rather than appearing and vanishing. A
  window that comes and goes cannot be found, aimed at or resized. Turning the
  setting off is how it goes away, and the X in its header does that.
- A header you can grab to move it, with the title and that X. It can also be
  dragged by the body, because a window you have to aim at is a window you
  swear at.
- Resizable from the grip in the bottom-right corner, between 260x120 and
  600x700: taller simply shows more lines. The list scrolls when there is more
  than fits, and rows are built once and drawn into as it moves, so resizing
  only decides how many are on show. Position and size are both remembered.
- Right-click anywhere on it -- header, body or a row -- for the quality
  threshold, offered as the qualities themselves rather than as a slider
  position: each entry is the name in its own colour with a tick on the one in
  force, so you pick the thing you want by looking at it. It is the same
  setting as the slider in the drop log, so the two follow each other.
- "Track drops" is in that menu too, because it is the one thing that can leave
  the window empty, and the empty window tells you to turn it on. So is
  "Clear the drop log", for starting a fresh session without going and finding
  the log window.
- Clearing now asks first, from either place. It is one button in the log
  window, which you opened deliberately, but it is also an entry in a menu you
  open to change a quality filter, and a slip there should not cost a night of
  drops. An already-empty log is cleared without the prompt, since there is
  nothing to lose.
- "Drops only" works with no grace period at all, and works solo, which is the
  half that answers "show me what I looted". The list is the drop log's newest
  rows rather than a second list, so the log's own threshold filters it and
  there is only ever one list to keep straight.
- With a grace period, each pending row says what the addon is about to do and
  counts down to it. The countdown is the row rather than a bar off to one side
  of it: a band the full width, draining away leftwards behind the item name
  and warming from green through amber to red, with the seconds beside it for
  when the exact figure is wanted. It reads from the corner of your eye, which
  is the only way it was ever going to be read in a fight, and it costs no
  width, so the item name gets the room the old bar was using. Kept faint,
  because an item link you cannot make out is worse than no bar at all.
- Clicking a pending row takes that roll back: the auto-roll is dropped and
  Blizzard's own window opens for that item with the full remaining timer on
  it, around 115 of the server's 120 seconds. Nothing here shortens a roll.
- There are deliberately no need, greed or pass buttons in it. With them people
  would click every row and the thing would have become Blizzard's roll window
  with a shorter timer, which is worse than either. One action, "not this one",
  and the UI built for the real decision is one click away.
- What keeps it from being that window is which way round the default sits:
  doing nothing here still rolls for you as configured, where doing nothing in
  Blizzard's window loses you the item.
- Blizzard's roll frames are held back only for rolls the addon has taken
  responsibility for. Anything set to Window in the grid, below uncommon, or
  that the addon could not identify keeps its normal frame.
- Rolls are timed by C_Timer rather than by the window, so one still fires on
  time with the window closed, the game on a loading screen, or the row
  scrolled out of sight. The window only draws the countdown bars, and stops
  even doing that once nothing is pending.
- CANCEL_LOOT_ROLL drops a pending row, so a roll that ends some other way --
  somebody else acting, the master looter stepping in, the group breaking up --
  does not leave a row counting down to nothing.
- `/apla grace <0-60>` sets the hold and turns the window on with it;
  `/apla popup`, or `/apla roll`, opens and closes it and takes the hold down
  with it. A roll held back with nowhere to see it is worse than either
  setting on its own, so the two are kept consistent whichever way you set
  them.
- Both are part of a preset, so a raid preset can run the window off and a
  five-man preset at 8 seconds.

### Fixed
- The loot window updates a row the moment it gains a winner, instead of
  sitting on "nobody" until some later drop happened to redraw it. A row is
  created winner-less when the roll starts and filled in when the loot message
  arrives, and that fill left `LogDrop` through an early return that only
  redrew the log window -- which had been the only window there was when it was
  written. A stack growing left through the other early return with the same
  result. There is one way to say the log changed now, and all three exits use
  it.
- Turning on "Track drops" from the options panel redraws the loot window too,
  so its "turn on Track drops" line goes away rather than waiting for the next
  drop.
- The loot window no longer covers your bags. It was on the HIGH frame strata,
  which is where the bag frames live, and it is a window that is always up, so
  it must never be the thing in front. It sits on LOW now: everything in the
  default UI you can open is MEDIUM or above, so from there it covers none of
  it. It has no toplevel flag either, so clicking or dragging it cannot promote
  it past whatever it is behind.
- The options panel no longer draws the bottom row of buttons on top of the
  "Track drops" checkbox. The panel ended flush with its last checkbox, so
  anything anchored to the bottom edge landed on it.

## [1.6.0] - 2026-09-07

### Added
- Presets. The dropdown at the top of the options panel switches between whole
  sets of settings, so the night's raid rules and the way you loot a five-man
  are two clicks apart instead of a dozen. Everything that decides what gets
  announced and what gets rolled is in a preset: announce on or off, the
  quality threshold, the channel cap, the chat prefix, pepe mode, drop tracking
  and the log's quality filter, and all three roll grids.
- A first run under this version makes one preset called "Preset 1" out of
  whatever you already had and changes nothing else, so there is nothing to set
  up and nothing to lose. Rename it and fork the next one off it with
  "New from current" when you want a second.
- There is no Save button, and deliberately so: the live settings *are* the
  active preset, so a change you make is already in it. Switching away files
  the one you are leaving and brings the other one in.
- "At login", where the windows sit, whether the minimap button is shown, the
  drop log and the debug flag are all outside presets. They belong to the
  account rather than to a role you switch into, and a preset that moved your
  minimap button would be moving the control you switch presets with.
- Share codes. "Share code..." in the preset menu puts the whole active preset
  on one line you can paste into chat, and pastes one back in as a new preset
  alongside the ones you already have rather than over them. Labelled fields
  rather than a positional CSV, so a code from another version still imports as
  much of itself as this one understands: unknown fields are ignored and missing
  ones fall back to the default. The README carries a Raider and a Looter code
  to start from.
- `/apla preset` lists them, `/apla preset <name or number>` switches,
  and new, rename, delete, code and import do what they say. A code pasted
  straight after `/apla preset` is recognised as one.
- The minimap tooltip names the preset you are on.

### Changed
- "At login" is an account setting rather than part of a preset. It is a
  question about this session, not about a role, and having it inside a preset
  made the two questions fight: switching to your five-man preset quietly
  changed whether tomorrow's login would prompt you. The value each preset was
  carrying is dropped on upgrade; the live one, from whichever preset you were
  last on, becomes the account setting.
- On "Ask", the login prompt now picks the preset too, which is the question
  you actually have at login: not whether to arm in the abstract but how
  tonight is going to go. The dropdown opens on the preset you were last using.
  Choosing one switches there and then, whether or not you go on to arm, so the
  prompt is also a way to change preset and leave rolling off.
- That prompt is a window of its own instead of a StaticPopup, which is a
  shared recycled frame with a fixed set of widgets and no room for a dropdown.
  "Leave it off" and Escape both still mean disarmed.
- Share codes no longer carry an "At login" field, since it is no longer part
  of a preset. Codes written by 1.6.0 before this change have an `la` field,
  and it is ignored the same way any unknown field is -- which is what that
  part of the format was for.
- The slider at the bottom of the drop log now filters what is on screen
  instead of setting what gets logged, on both tabs. It sits under a list and
  reads as a filter, so it had better be one. With tracking on, everything that
  drops is kept — greys and quest items included — and the slider decides how
  far down the list you want to see. Drag it up to pull the night's epics out
  of a wall of vendor trash, drag it back down and they are all still there.
  A threshold on the way in threw away rows you could never ask for again,
  where a filter on the way out can always be widened.
- The log header says `4 of 63 lines` while the slider is holding rows back, so
  a filtered list never looks like a session that did not happen. The count is
  per tab, so Mine counts only what this character took.
- Each row records the quality it was logged at, which is what the filter reads
  rather than asking the client about an item it may since have forgotten. Rows
  in a log written by an earlier version have their quality read back off the
  item link's own colour the first time they are drawn.
- The log holds 1000 rows rather than 500. With greys landing in it too, 500
  was a couple of hours of trash before the epics started falling off the far
  end.

## [1.5.1] - 2026-09-06

### Fixed
- A drop is no longer announced twice when several people in the raid run the
  addon. Copies only counted each other in the single-announcer election for
  15 minutes after last hearing from one another, but hellos went out at login,
  on roster changes and nowhere else. A settled raid can go longer than that
  without anyone joining or leaving, at which point every copy has timed every
  other one out, each decides it is the announcer, and the drop goes out once
  per copy. There is now a heartbeat every four minutes while grouped, which is
  three heartbeats inside the timeout and one addon message per copy per four
  minutes on the wire.
- Roster pruning no longer throws away peers it is still grouped with.
  `GROUP_ROSTER_UPDATE` can arrive before the client has filled in the unit
  table, and pruning against a roster that is not there yet dropped live peers.
  It now leaves them alone when the roster reads as empty, and asks for a
  recount when it does drop someone, rather than announcing over them until the
  next hello.
- `/apla who` reports how long ago each peer was last heard from and flags the
  ones that have timed out, which is what this would have looked like.

## [1.5.0] - 2026-09-06

### Added
- An optional drop tracker. Middle-click the minimap button for a movable,
  resizable log of what dropped this session and who won it, saved between
  logins and emptied only by the Clear button, so a night of trash runs with a
  logout in the middle is still one list. Off until you turn it on with
  "Track drops" in the options, or `/apla track`.
- Stackables collapse to one row with a running total; everything else gets a
  row per drop with the winner behind it. A row reading `nobody` is a drop
  that was rolled and never picked up.
- Two tabs in the log: Everything, and Mine for what this character took. Mine
  is per character rather than per account, because a winner's name is the only
  thing that says whose a drop was and the log is shared between characters.
  Stacked rows record who took how many, so a stack splits back out correctly.
- Stacked rows sort to the top of both lists. They are the part of the log that
  stays the same length however long the night runs, so they belong where they
  can be read at a glance instead of scrolled past. Everything else follows,
  newest first.
- A running coin total for the session, from your share of the loot.
- The log window resizes from the grip in its bottom-right corner, between
  360x286 and 900x800, and remembers the size. Rows are built once and drawn
  into as the list scrolls, so resizing only changes how many are on show.
- Rows show the item tooltip on hover and link into chat on shift-click, and
  the log has its own quality threshold so it does not fill with vendor junk.
- `/apla loot` opens the log, `/apla track` toggles tracking.
- Automated rolling has an "At login" setting: Off, On, or Ask. Ask puts a
  prompt in front of you each login so it is never armed without you saying so,
  and never left armed by accident either. Off keeps the old behaviour and is
  still the default. The button sits beside the "Roll automatically" checkbox
  and cycles on click; `/apla login off|on|ask` does the same.

### Fixed
- The two windows no longer draw through each other. Both were left on the
  default frame strata, which handed them levels in creation order, so
  overlapping them interleaved their children: the settings panel's checkboxes
  and sliders drew straight over the loot log's background. They now share one
  strata and whichever you click comes to the front.
- The panel summary says Window, Pass, Greed and Need rather than spelling out
  "roll window stays up". Three of the long form per row wrapped the summary
  down into the chat prefix field, and the short names match the column
  headings they describe.

### Notes
- The log is built from `CHAT_MSG_LOOT`, so it only ever contains what you
  were present for, and it keeps working whether or not Blizzard's Pass on
  Loot option is on. Matching a winner to a drop is a heuristic: the oldest
  row for that item still waiting on a winner, within three minutes.
- Capped at 500 rows, oldest dropped first. Shared across your characters,
  like the rest of the addon's settings.

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
