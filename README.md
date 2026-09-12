# Auto Pass Loot Announcer

Announces group loot drops **the moment they drop**, and rolls need, greed or pass for you based on item quality.

Built for raids where everyone is asked to pass on loot. Blizzard's "Pass on Loot" option is server side: with it on, the server never sends you the roll, so you never find out what dropped until people start looting. This addon replaces that option with automated passing you can actually see.

![Chat output](Media/screenshots/chat-output.png)

## Features

- **Presets** for whole sets of settings, so the night's raid rules and the way you loot a five-man are two clicks apart, with a one-line code to share either
- **Announces on the roll**, not on the corpse, so you see drops even when someone else loots the body
- **An optional loot window** that says what dropped as it drops — movable, resizable, scrollable — and can hold each roll a few seconds so you get one click to take any of it back
- **One line per item**, to your choice of channel
- **Roll actions per quality and per kind** — need, greed, pass, or leave the window up, set separately for BoP, BoE and stackable BoE drops, so the epic gems pass themselves while a BoE pattern off the same boss stops and waits for you
- **Single announcer election** — when several people in the group run the addon, they agree on one announcer so the drop is posted once, with nothing to configure
- **One switch for the lot** — armed, it does what the preset says; disarmed, it rolls nothing and says nothing, so putting it away for a night is one click
- **Never armed between sessions** — it starts each login off, on, or behind a prompt, whichever you pick
- **A drop popup** that appears when something drops, says what it was and goes again — the pack's haul read in the quiet after the pull, never on screen during one
- **Say it with** a prefix of your own, a random cheerful pepe, or a random silly line off a list of fifty

## Screenshots

![Options panel](Media/screenshots/options-panel.png)

![Loot window](Media/screenshots/loot-window.png)

## Usage

Left-click the minimap button to arm or disarm. Right-click opens the options, middle-click turns the loot window on and off.

**Armed is the master switch.** Disarmed, the addon rolls nothing and announces nothing, whatever the preset holds — the loot window, the popup and the drop log still show you what fell, because those are yours to read rather than something the group hears. Armed, it does what the preset says, which can be announcing and no rolling at all.

Armed is never carried between sessions. What happens at login is the **At login** button beside the "Arm this session" checkbox — click it to cycle:

| | |
| --- | --- |
| Off | Stays disarmed until you arm it yourself. The default |
| On | Armed straight away, on the preset you were last using |
| Ask | A prompt each login, so it is never armed without you saying so |

**At login is an account setting, not part of a preset** — it is a question about this session rather than about a role, and on **Ask** the prompt is where you pick the role anyway. That prompt carries a preset dropdown, already set to the one you were last using: pick a different one and it switches there and then, whether or not you go on to arm. **Leave it off** and Escape both mean disarmed.

![The prompt on Ask](Media/screenshots/login-prompt.png)

| | |
| --- | --- |
| <img src="Media/icon-idle.png" width="48"> | Disarmed, nothing rolled and nothing announced |
| <img src="Media/icon-armed.png" width="48"> | Armed, the arrows turn green |

For the addon to see rolls at all, Blizzard's own **Pass on Loot** option must be **off** (Interface → Combat). That option suppresses the roll server side and no addon can work around it.

### Presets

The addon's settings live in **presets**. The dropdown at the top of the options panel switches between them, and the entries under the list make, rename and delete them; what a preset does and does not carry is spelled out below. Like the rest of the addon, they are per account rather than per character.

You start with one, called **Preset 1**, holding whatever you already had — a first run of this version changes nothing and there is nothing to set up. Rename it to something you recognise, then fork the next one off it.

| Menu entry | Effect |
| --- | --- |
| A preset's name | Switch to it |
| New from current... | A copy of what you have now, under a new name |
| Rename... | Rename the one you are on |
| Delete *name* | Delete the one you are on. The last one cannot be deleted |
| Share code... | Open the code window |

There is no Save button, deliberately. The live settings **are** the active preset, so a change you make is already in it; switching away files the one you are leaving and brings the other one in.

| | |
| --- | --- |
| **In a preset** | Announce on or off, the quality threshold, the channel cap, the chat prefix, what it says the drop with, the loot window and its grace period, the drop popup, the Show threshold, and all three roll grids |
| **Not in a preset** | **At login**, where the windows sit, whether the minimap button is shown, the drop log and its sessions, the debug flag |

The second list is the things that belong to the account rather than to a role you switch into — a preset that moved your minimap button would be moving the control you switch presets with. Armed is not in a preset either; it is never remembered between sessions at all.

**Announce is in a preset and armed is not**, and the two read together: arming says whether the addon is doing anything tonight, the preset says what. So one preset can announce and leave every roll alone — an announcer and nothing else — while another passes on the lot in silence, and disarming stops either of them dead.

#### Share codes

**Share code...** in the preset menu opens a window holding the active preset as one line. Ctrl+A then Ctrl+C copies it. Paste someone else's in instead and **Import as new preset** adds it alongside the ones you have and switches to it — it never writes over a preset you already had.

Two to start from, if you want somewhere to begin. Paste either into the code window, or after `/apla preset import`:

**Raider** — pass on everything, but stop on a bind-on-equip that does not stack, because somebody may have been waiting weeks for it. Announce rare and better, up to raid.

```
APLA1:n=Raider,a=1,c=3,q=3,sm=prefix,pe=0,tq=2,bop=pppp,boe=pwww,bes=pppp,p=Drop%3A
```

**Looter** — greed everything, decide epics and legendaries yourself. Announce uncommon and better, up to party, and log what dropped.

```
APLA1:n=Looter,a=1,c=2,q=2,sm=prefix,pe=0,tq=2,h=1,bop=ggww,boe=gggg,bes=gggg,p=Drop%3A
```

A code pasted straight after `/apla preset`, with no keyword, is recognised as one.

**The format** is labelled fields rather than a positional CSV, so a code written by a different version still imports as much of itself as this one understands: unknown fields are ignored and missing ones fall back to the default. A code written before **At login** left the presets carries an `la` field, which is one of the fields now ignored.

| Field | |
| --- | --- |
| `APLA1` | The format version |
| `n` | Name |
| `a` | Announce to chat, 0 or 1. Only ever speaks while armed |
| `c` | Channel cap, 1 say to 4 yell |
| `q` | Announce threshold, 0 to 5 |
| `sm` | What it says a drop with: `prefix`, `pepe` or `random` |
| `pe` | Pepe on or off, written for 1.8 and earlier only. A code from one of those versions is read through it when there is no `sm` |
| `tq` | The Show threshold |
| `h` | Loot window on or off |
| `g` | Grace period in seconds, 0 for none |
| `f` | Drop popup time in seconds, 0 for no popup |
| `bop`, `boe`, `bes` | The three roll grids, one letter per quality from uncommon up: `w`indow, `p`ass, `g`reed, `n`eed |
| `p` | Chat prefix |

Anything but a letter, digit or `-_.` in a name or a prefix is percent-escaped, so a code is always one whitespace-free token that survives any copy and paste. That is why `Drop:` reads as `Drop%3A` above.

### Roll actions

Pick a quality with the tabs, then set what happens to each **kind** of drop at that quality:

| Kind | What lands here |
| --- | --- |
| BoP | Bind-on-pickup — tier tokens, boss gear, BoP reagents |
| BoE | Bind-on-equip and does **not** stack — patterns, recipes, BoE weapons and armour |
| BoE stack | Bind-on-equip and stacks — epic gems, motes and primals, void crystals, nether vortexes |

Hovering a row name in the panel shows the same thing with examples.

Each kind gets one action:

| Action | Result |
| --- | --- |
| Window | Nothing happens, the roll window stays on screen for you |
| Pass | Passes immediately |
| Greed | Greeds, and auto-confirms the bind-on-pickup prompt |
| Need | Needs, auto-confirms, and prints a local notice |

**Poor and common are left alone entirely** — no auto-roll, the window stays up exactly as it would without the addon running. Uncommon, rare, epic and legendary each get the same three rows.

The point of the split is that quality on its own is a poor guide to whether a drop is worth stopping for. At epic, all three kinds want different answers:

| Drop | Kind | Typical setting |
| --- | --- | --- |
| Tier token, boss gear | BoP | Pass |
| Pattern, BoE weapon | BoE | Window — somebody has been waiting for it |
| Epic gem, nether vortex | BoE stack | Pass — it is a commodity |

**Where the answers come from.** Bind type is the roll's own `bindOnPickUp` from `GetLootRollItemInfo`, which is the server's answer for that exact roll. Stackability is `itemStackCount` from `GetItemInfo` — the item's maximum stack size, not the number that dropped, so a single epic gem still reads as stackable.

`GetItemInfo` returns nothing until the client has cached the item, and unlike bind type there is no roll-level fallback for stack size. The addon retries for a few seconds against a two-minute roll, and only waits on an answer it will actually use — a BoP drop never waits on its stack size. If something still has not resolved, the roll is left alone rather than guessed at.

Bind-on-pickup prompts are only auto-confirmed for rolls the addon made itself. A prompt raised by your own click still waits for you.

### Loot window

Off by default. **Loot window** at the bottom of the options panel cycles through the settings; it is one control because the two things people asked for are points on one line, from "tell me nothing" through "tell me" to "tell me and wait for me".

| Loot window | What happens |
| --- | --- |
| Off | No window. Rolls are answered the moment they drop and Blizzard's roll windows are left alone — exactly as without this setting |
| Drops only | A window lists what dropped and who took it, as it happens. Rolls are still answered straight away |
| 3s / 5s / 8s / 12s | Also holds each roll the addon is going to answer for that long, counting down, so you can take one back |

![A roll held with its grace period running](Media/screenshots/loot-window.png)

**Once it is on, it stays on screen.** It does not appear and vanish — a window that comes and goes is one you cannot find, aim at, or resize. Turning it off is how you get rid of it, and the **X** in its header does exactly that.

```
┌ Loot ─ right-click for options ── 41g 12s ─ X ┐
│▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░│
│▓[Pattern: Swiftheal Mantle]▓▓▓▓▓▓▓▓ Pass   3s░│   ← green, draining left
│▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
│▓[Heart of Darkness]░░░░░░░░░░░ x2   Pass   1s░│   ← red, nearly out
├───────────────────────────────────────────────┤
│ Heart of Darkness ............. x3    Aereora │
│ Heart of Darkness ............. x2            │
│ Mark of the Illidari .......... x12   Perhorn │
│ Bloodfist Helmet .................... Isaari  │
└──────────────────────────────────────────────◢┘

**A row is always one line.** Drag the window narrower than a name and the name
is cut rather than wrapped — a second line is a line the row has no height for,
and it lands on top of the drop below it. The whole name is on the tooltip. The
same goes for the drop popup and the session details list.

How many dropped sits in a column of its own, out of the cut's way, because it
is the one thing on a row you cannot get back by hovering it. That column and
the winner column are each only as wide as the widest thing on show, so a night
where nothing stacked has no count column at all and the name gets the room
instead.
```

Above the line are pending rolls. **The countdown is the row itself**: a band the full width of it, draining away leftwards behind the item name, so how long is left reads from the corner of your eye without the number being read. It warms from green through amber to red as it goes. The seconds are there beside it for when you want the exact figure.

Below the line, what already happened, **totalled per person** and **sorted by what it is**: epics first, then rares, then uncommons, and within each quality the ones that stack ahead of the ones that do not. Silently, with no caption where one group gives way to the next — the colour of the link already says which quality a run of rows is, and every line spent saying it again is a line of a small window not spent on loot. A trash farm is settled up by its stackable epics and rares — the gems, the hearts, the marks — so those sit at the top rather than wherever the last green pushed them. Within a group the same item's rows sit together, biggest pile first: three Hearts of Darkness that all went to Aereora are one row reading `x3` rather than three lines, because what this window is being asked is who ended up with what. A drop still waiting for a name keeps a row of its own — how many are in the air is worth seeing rather than summing — and a drop still pending above is not repeated below.

**All of it, not the latest thirty.** The list is the whole session above the **Show** threshold, however long it ran, and the rows scroll. This window is where a session of farming is added up, and a total that quietly stopped counting would be a wrong total — which is what it used to do, at thirty rows. That session's share of the coin sits in the header.

#### Moving, sizing, closing

| | |
| --- | --- |
| Move | Drag the header, or anywhere on the body |
| Resize | The grip in the bottom-right corner. Taller shows more lines |
| Scroll | The list scrolls when there is more than fits |
| Close | The **X**, or `/apla window` |

Position and size are remembered between sessions, per account. It sits on a low frame strata on purpose: it is always up, so anything you open — bags, the character sheet, a merchant — comes over the top of it rather than the other way round.

#### Right-click for options

Right-clicking anywhere on it — header, body or a row — opens a short menu:

| | |
| --- | --- |
| Show | The quality threshold, as the qualities themselves: **Uncommon and better** up to **Legendary only**, each in its own colour with a tick on the one in force |
| Showing | Which session the list is reading — **current**, or one of the filed ones, with a tick on the one you are on. Greyed until there is something filed to switch to |
| Details of this session... | Opens the [session details](#session-details) window on whichever session is being read |
| Start a new session | Files what is on screen and starts counting from empty. Never asks, because nothing is lost |
| Ask when the group changes | Whether somebody joining or leaving puts the offer of a new session in this window. On by default |
| Clear the drop log | Empties every session, this one and the filed ones with it. Asks first, unless there is nothing to lose |
| Close this window | Same as the X |

The threshold is one setting shared by this window and the popup, and it starts at **uncommon**: nothing below that is ever logged, because the server only rolls for items at the group's loot threshold and up. Offering the qualities by name and colour rather than as a slider position means you pick the thing you want by looking at it instead of translating a position into a quality.

#### Sessions

**Start a new session** files what the window is showing and starts counting from empty — the same move a damage meter makes when it splits a fight off into its own segment. The last **ten** filed sessions are kept, and **Showing** on the right-click menu switches between them and the current one, each row saying when it ran and how many drops are in it.

```
  Sessions
  Showing: current            ▸   ✓ Current          12 drops
  Start a new session               22:47-23:15      41 drops
  Clear the drop log                21:03-22:40      88 drops
                                    11/09 19:12-20:40  57 drops
```

That exists because **what did that boss drop** and **what has tonight dropped** are different questions, and the only way to ask the first one used to be to clear the log — which lost the answer to the second. Clearing is now only for when you want the lot gone.

While a filed session is on show the header says which, where the right-click hint usually sits:

```
┌ Loot ─ session 22:47-23:15 ── 41g 12s ─ X ┐
```

A window quietly showing last pull's drops during this one is the only thing sessions could get wrong, so it says so, right where you are already looking for the total. Rolls pending above the list are always the live ones whichever session is being read, and **new drops always go into the current session** — looking back never stops anything being recorded.

Which session you are reading is not remembered between logins — it is where you scrolled back to, not a setting — but the sessions themselves are.

#### When the group changes

Somebody joining or leaving is usually what the end of a session looks like: the pull is over, half the group has gone, and the next hour of drops wants counting apart from the last one. So the loot window offers it, as a line rather than as a dialog:

```
┌ Loot ─ right-click for options ── 41g 12s ─ X ┐
│ Grendl left -- new session? [New session] [x] │
├───────────────────────────────────────────────┤
```

**New session** does exactly what the menu entry does. **x** leaves it as one session and the line goes; it comes back the next time the group changes, not before. Doing nothing is the third answer, and the safe one — the addon never files a session on your behalf, because filing is cheap to do late and impossible to undo.

It waits about five seconds for the roster to settle first. A raid re-forming, a group walking through an instance portal and one person's disconnect all arrive as a burst of roster changes, and asking on the first of them would be asking about a group that no longer existed a moment later. It also stays quiet when the session has nothing in it yet — an empty session is already a new one — and while you are reading a filed session, which is not the moment to be asked to file this one. Turn it off with **Ask when the group changes** on the right-click menu.

### Session details

`/apla details`, or **Details of this session...** on the loot window's right-click menu. It opens on whichever session that window is reading, and has its own picker for the rest.

```
┌ Session details - 22:47-23:15                                 X ┐
│ [Current ▾]  [Rare and better ▾]                                │
│ [heart____________]  ☑ Group by quality                         │
│ Item                        Qty   Winner   When │ Participants  │
├─────────────────────────────────────────────────┼───────────────┤
│ - Epic stackable  2                             │ Aereora     5 │
│   [Heart of Darkness]        x3  Aereora   22:51│ Perhorn     3 │
│   [Heart of Darkness]        x2  Aereora   23:04│ Isaari      1 │
│ + Epic  4                                       │ Grendl      - │
│ - Rare                                          │               │
│   [Skettis Belt of the Bandit]   Isaari    22:58│               │
├─────────────────────────────────────────────────┴───────────────┤
│ 41 drops   11/09 22:47 - 23:15   41g 12s   5 in the group      ◢│
└─────────────────────────────────────────────────────────────────┘
```

Everything the loot window's rows have no room for:

| | |
| --- | --- |
| Search | Filters as you type, on the item, the winner, a reserve, **or a participant** — a name finds the drops somebody was standing there for as well as the ones they won |
| Show | Its own quality threshold, not the log's. A question you ask of a session and then put back; moving it does not change what the loot window has been showing all night |
| Group by quality | Epics first, then rares, then uncommons, stackables ahead of the rest, each group foldable by clicking its own line. Off, the session is one flat list |
| Sort | Click a column head: **Item**, **Qty**, **Winner** or **When**. Click it again to turn it round. Grouped, it orders what is inside each group rather than overruling the grouping |
| Participants | Everyone the session saw, the ones who were there for most of it first, with what they won beside them. Hover for how many of the session's drops they were present for |
| A row | Hover for the item, its reserves, and **who was in the group when it dropped**. Shift-click links it to chat, as in the loot window |

Drops fold exactly the way they do in the loot window — one row per item per winner — so the two windows never disagree about how many of something dropped. Where a row's drops fell either side of a group change, the tooltip names the group most of them fell under and says the group changed; splitting the row instead read as a fault, which is what it looked like beside a loot window counting the same five hearts as five. It is the whole session either way: the footer counts what the threshold lets through, and says when the session ran and what it paid.

Position, size, threshold, sort order and which groups you folded away are remembered between logins. What you typed in the search box is not: coming back tomorrow to a window showing four of the night's rows would read as a window that had lost the rest.

#### Who was in the group

Every drop records the group it fell in front of. Not a copy of the roster per row — that would be the same ten names written out a few hundred times a night — but an index into the rosters the session has seen, so people coming and going costs a handful of name lists and each row costs one integer.

It is read at the moment the drop is logged, because who was there when it fell is the only instant the answer matters. It has to be the whole group or none of it: if the client has not finished filling its roster in — which happens for a moment after a group changes — the row keeps no roster at all rather than a short one, because a half-filled roster is a group nobody was ever in and the next drop would be filed under it. A drop recorded as having happened to you alone is worse than a drop with no group on it, since only one of the two is obviously missing. Rows logged before this release have none, and read as such.

Names the log only ever saw as a winner are in the participant list too, and say so on their tooltip. Under master loot an item can be handed to somebody the roster walk never saw, and a participant list the winner column contradicts is worse than one with a stranger in it.

#### Taking a roll back

**Click a pending row.** The auto-roll is dropped and Blizzard's own window opens for that item with the **full remaining roll timer** on it — around 115 of the server's 120 seconds. Nothing here shortens a roll.

There are deliberately no need/greed/pass buttons. The UI built for that decision is one click away and is better at it; with them in here, people would click every row and this would have become Blizzard's roll window with a shorter timer, which is worse than either.

**Doing nothing still rolls for you.** That is what keeps this from being that window:

| | Blizzard's roll window | This |
| --- | --- | --- |
| Doing nothing | loses you the item | rolls as configured |
| Frames on screen | one per item, up to four | one, a row per item |
| Clicks in a normal night | one per item | none |

Blizzard's window is only held back for rolls the addon has taken responsibility for. Anything set to **Window** in the grid, or below uncommon, or that the addon could not identify, gets its normal frame exactly as before.

Both settings are part of a preset, so a raid preset can run the window off and a five-man preset at 8 seconds. `/apla grace <0-60>` sets the hold and turns the window on with it; `/apla window` toggles the window and takes the hold down with it, because a roll held back with nowhere to see it is worse than either setting alone.

#### Trying it out

Group loot rolls only happen in a group, on Group Loot or Need Before Greed — solo, nothing is ever rolled for, so none of this can be tested alone. What **can** be tested alone is the popup: the **Test** button fakes a pull's worth of drops so you can see it appear, fill up and go, and drag it somewhere while it is there. Nothing about it is real — nothing announced, nothing rolled for, nothing logged.

#### What counts as a drop

**Only what the group was actually offered:** an item the server rolled for — the window you would have answered without this addon — and, under master loot, one a loot addon announced. Nothing else.

That rule exists because `CHAT_MSG_LOOT` cannot tell a drop from anything else that arrives through the loot system, and it is not a small difference:

| Reads as loot | Is it a drop? |
| --- | --- |
| Soul Dust, Lesser Astral Essence | No — someone disenchanted the green they just won |
| Tainted Core, Vashj's Vial Remnant | No — fight mechanics that happen to be items |
| Greys and commons in a group | No — those are handed out round-robin, no roll, no window |
| Quest pickups, herbs, anything you loot solo | No |
| The green the party rolled on | **Yes** |
| A stack of Nether Vortex someone won | **Yes** |
| A tier token the master looter handed out | **Yes**, if a loot addon announced it |

So `START_LOOT_ROLL` is what makes an item loggable and the loot message only says who ended up with it. An item stays loggable for ten minutes after it is offered, which covers the roll's two minutes and the wait for someone to loot the corpse.

The roll says how many dropped as well as what did, so a stack is a drop like any other: logged when it drops with no name beside it, carrying the number that dropped, and a name once somebody loots it. Ten hearts off a night of trash are ten entries rather than one running total — which is what lets the popup say `x2` for the two that just dropped while the loot window adds them up per winner.

**One consequence worth knowing:** solo, nothing is ever rolled for, so nothing is logged. The log is a record of what the group was offered, not of what you picked up.

**Show filters what you are looking at, not what gets kept.** Everything that qualifies goes into the log; the threshold on the right-click menu decides how far down the list you want to see. Set it to Rare for a raid night and the greens are still there when you set it back.

A threshold on the way in would throw away rows you could never ask for again; a filter on the way out can always be widened.

Two more things follow:

- **You only log what you were there for.** Loot taken while you are offline, or before you joined the group, never happened as far as the addon is concerned.
- **Pairing a winner to a drop is a heuristic.** A loot message is matched to the oldest row for that item still waiting on a winner, within three minutes — thirty for an announced one, since a loot master takes longer than a roll. A row waiting on the same number as the message wins over an older one, which is what tells two stacks of the same item apart. If the same item drops off two mobs seconds apart, two winners could in principle still land on the wrong rows. It is cosmetic when it happens.

Each session holds 10,000 rows and drops the oldest beyond that — weeks of farming, and a stop on the saved file rather than anything you should meet: the loot window adds up what it shows from the whole session, so a row that fell off the front would be a drop gone from somebody's total. Ten filed sessions are kept behind the current one, oldest off the end. All of it is shared across your characters, kept between logins, and emptied only by **Clear the drop log** on the right-click menu.

### Drop popup

Off by default. **Drop popup** at the bottom of the options panel cycles: off, 3, 5 or 10 seconds.

A second window, and deliberately not the loot window in another guise. The loot window is a fixture — you turn it on, it stays where you put it, and it is where a roll counts down and where you click to take one back. A window you may have to *answer* is a window that has to stay.

This is the opposite. It appears when something drops, says what it was, and goes. It is the thing you glance at in the quiet after a pull, while the healer drinks and somebody is looting.

```
┌───────────────────────────────────────────────┐
│ [Helm of the Vanquished Hero] ..... Stinkaapje│
│ [Nether Vortex] x2 ..................... Hikø │
│ [Belt of One-Hundred Deaths] ....... Kasplant │
└───────────────────────────────────────────────┘
        appears on a drop, gone a few seconds later
```

| | |
| --- | --- |
| Appears | When something drops that the **Show** threshold lets through |
| Once per drop | A winner's name landing on a drop already shown does not bring it back — it is redrawn in place if the window is still up, and nothing more |
| A whole pack | Each drop puts the clock back to the full time, so a pull arrives as one window rather than as five |
| Goes | When the drops stop and the time runs out |
| Emptied | On the way out, so the next pull opens on a clean window rather than the tail of the last one |
| In combat | Never |
| Rolls | Nothing to do with them: no grace period, no countdown, nothing to answer |

**It is never on screen in a fight.** What drops while you are fighting is held back and shown the moment you are not — the pack's haul in one go, once there is time to read it. That is the point of it rather than a limitation: the window is for the recovery period, not for the pull.

It has no grace period and no countdown because it has nothing you must answer. Taking a roll back is the loot window's job, and that window stays up precisely because it might need you. Run both if you want both.

**Moving and sizing it.** It has no header — a window this brief cannot spare the room — so it is dragged by its body *and by its rows*, which would otherwise swallow the drag. The grip in its bottom-right corner sizes it. Both are remembered per account.

The height works two ways, and which one you get depends on where you leave that grip:

| | |
| --- | --- |
| **Squashed to one row** | It grows and shrinks with the pack — one drop is one line, five is five |
| **Pulled down past one row** | It is that height every time, full or not, and anything past it scrolls on the mouse wheel |

One row is the smallest the grip goes, so "as small as it will go" is also how you ask for no fixed height at all. Either way the newest is at the top, so a full window is always showing the thing that just dropped; the wheel goes back through the rest. It holds twenty rows and shows at most ten at once.

Having hold of it — dragging it, or sizing it — keeps it on screen, the same as resting the mouse on it does. A window that faded out from under a resize would be one you could not resize.

Because it only appears when something drops, there would otherwise be no way to find it to put it anywhere: so **cycling the Drop popup button shows it**, with a placeholder row to aim at, and **Test** fakes a whole pull so there is something to size it against. It fades on its own like any other showing.

Right-click to put it away early, shift-click a row to link it in chat. It fades rather than blinking out. The drop log keeps everything either way — the wipe is what the popup is showing, not what was recorded.

It shares the **Show** threshold with the loot window: one answer to "what is worth showing me", set in one place.

`/apla popup <0-60>` sets the time, `/apla popup` on its own toggles it. It is part of a preset, so a raid preset can run it and a five-man preset leave it off.

### Announcing

**Nothing is announced while disarmed.** Announce is part of a preset, the way the roll grid is, and both wait on the same switch — so the settings panel dims the announce block when you are not armed: still yours to set, because it is the preset you are building, but not saying anything right now.

Three settings: **Announce to chat** turns it on, **Announce** sets the minimum quality, **Announce up to** sets the widest channel. With **Announce to chat** off, a drop still prints to your own chat frame and nothing goes to the group. The channel is a cap that steps down to whatever is available:

| Cap | In raid | In party | Solo |
| --- | --- | --- | --- |
| Say | say | say | say |
| Party | your subgroup | party | own chat frame |
| Raid | raid | party | own chat frame |
| Yell | yell | yell | yell |

### Say it with

What goes in front of the item link is one setting with three choices, cycled
by the button under the prefix box. One or the other, never two at once: only
one thing can lead a line.

| Mode | What an announce reads as |
| --- | --- |
| **Prefix** | `Drop: [Cursed Vision of Sargeras]` |
| **Pepe** | `PepePogO [Cursed Vision of Sargeras]` |
| **Random** | `Ooh, a piece of candy! [Cursed Vision of Sargeras]` |

The prefix box stays yours to edit in the other two modes — it is what you go
back to — but it is dimmed, because nothing is being announced with it.

**Pepe** picks from 22 of the cheerful pepes in
[Twitch Emotes 2.0](https://www.curseforge.com/wow/addons/twitch-emotes-v2).

![A pepe on an announcement](Media/screenshots/loot-pepe.png)

They are all still frames. Twitch Emotes animates an emote by rewriting the
whole chat line 30 times a second, which stops an item tooltip on that line
from settling, so the animated pepes are kept out of the pool.

What goes out on the wire is the emote's name, so it becomes a picture only for
readers who run Twitch Emotes themselves. Everyone else sees the word, e.g.
`PepePogO Drop: [Cursed Vision of Sargeras]`. That addon is not a dependency of
this one and nothing breaks without it.

**Random** picks a line from a list of fifty — `Another one.`, `Ooh, shiny!`,
`Mine! Mine! Mine!`, `The boss dropped its wallet:`, `One does not simply pass
on this:` and so on. Plain text, so unlike a pepe it reads the same for
everyone whatever they have installed, and a different one each drop.

Both random modes re-roll once when the pick repeats the last one, so the same
line rarely lands twice in a row.

### Slash commands

| Command | Effect |
| --- | --- |
| `/apla` | Open the options panel (`/lap` also works) |
| `/apla arm` | Arm or disarm the addon (`/apla pass` is the old name and still works) |
| `/apla preset` | List the presets |
| `/apla preset <name or number>` | Switch to one |
| `/apla preset new <name>` | New preset, copied from the current settings |
| `/apla preset rename <name>` | Rename the one you are on |
| `/apla preset delete <name or number>` | Delete one |
| `/apla preset code` | Open the share-code window |
| `/apla preset import <code>` | Import a code as a new preset |
| `/apla set <bop\|boe\|stack\|all> <2-5> <window\|pass\|greed\|need>` | Set the action for one quality and kind |
| `/apla channel <say\|party\|raid\|yell>` | Set the announce channel cap |
| `/apla quality <0-5>` | Minimum quality to announce |
| `/apla announce` | Toggle chat output (off prints locally; either way it waits on armed) |
| `/apla login <off\|on\|ask>` | What automated rolling does at login |
| `/apla grace <0-60>` | Seconds to hold a roll before answering it; 0 answers straight away |
| `/apla window` | Open or close the loot window (`/apla roll` also works) |
| `/apla details` | Open or close the session details window (`/apla session` also works) |
| `/apla popup [0-60]` | Seconds the drop popup shows for; no number toggles it, 0 turns it off |
| `/apla mode <prefix\|pepe\|random>` | What it says a drop with (`/apla say` also works) |
| `/apla pepe` | Flip between pepe and your prefix |
| `/apla who` | Show the elected announcer and all peers |
| `/apla debug` | Log every roll decision |
| `/apla minimap` | Show or hide the minimap button |

## Development

The repository root **is** the addon folder. Point the game at it with a directory junction instead of copying files:

```cmd
mklink /J "<your WoW folder>\_anniversary_\Interface\AddOns\AutoPassLootAnnouncer" "<your clone>"
```

Edit in VS Code, then `/reload` in game. Recommended extensions are in `.vscode/extensions.json`; the WoW API one gives you completion for the Blizzard functions.

Before committing:

```cmd
luac5.1 -p AutoPassLootAnnouncer.lua
luacheck .
```

CI runs both on every push. See `docs/RELEASING.md` for how the CurseForge side works.

## Layout

```
AutoPassLootAnnouncer.toc    metadata, load order
AutoPassLootAnnouncer.lua    the addon
Textures/                    minimap icons (32-bit uncompressed TGA, 64x64)
Media/                       screenshots and icon art, excluded from the package
docs/                        release notes for maintainers
.pkgmeta                     tells the CurseForge packager what to ship
```

## License

MIT, see [LICENSE](LICENSE).
