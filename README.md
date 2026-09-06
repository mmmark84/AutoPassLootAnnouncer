# Auto Pass Loot Announcer

Announces group loot drops **the moment they drop**, and rolls need, greed or pass for you based on item quality.

Built for raids where everyone is asked to pass on loot. Blizzard's "Pass on Loot" option is server side: with it on, the server never sends you the roll, so you never find out what dropped until people start looting. This addon replaces that option with automated passing you can actually see.

![Chat output](Media/screenshots/chat-output.png)

## Features

- **Announces on the roll**, not on the corpse, so you see drops even when someone else loots the body
- **One line per item**, to your choice of channel
- **Per-quality, per-bind roll actions** — need, greed, pass, or leave the window up, set separately for bind-on-pickup and bind-on-equip drops, so a BoE epic can be needed while the BoP one off the same boss waits for you
- **Single announcer election** — when several people in the group run the addon, they agree on one announcer so the drop is posted once, with nothing to configure
- **Disarmed at every login**, so automated rolling can never be left on by accident
- **Pepe mode**, which puts a random cheerful pepe in front of every announcement

## Screenshots

![Options panel](Media/screenshots/options-panel.png)

## Usage

Left-click the minimap button to arm or disarm automated rolling. Right-click opens the options.

| | |
| --- | --- |
| <img src="Media/icon-idle.png" width="48"> | Idle, automated rolling off |
| <img src="Media/icon-armed.png" width="48"> | Armed, the arrows turn green |

For the addon to see rolls at all, Blizzard's own **Pass on Loot** option must be **off** (Interface → Combat). That option suppresses the roll server side and no addon can work around it.

### Roll actions

Rare, epic and legendary each get two settings, one for bind-on-pickup and one for bind-on-equip:

| Action | Result |
| --- | --- |
| Window | Nothing happens, the roll window stays on screen for you |
| Pass | Passes immediately |
| Greed | Greeds, and auto-confirms the bind-on-pickup prompt |
| Need | Needs, auto-confirms, and prints a local notice |

Anything below rare is passed and has no setting of its own.

The split is there because bind type, not quality, is what usually decides whether a drop is worth stopping for. An epic gem or a BoE epic off a trash pull is gold to somebody in the raid; the BoP version off the same boss is not. Set BoE epic to Window and BoP epic to Pass and you only ever see the roll window for the ones you might actually want.

Bind type comes from the roll itself (`GetLootRollItemInfo`), falling back to the item's own bind type while the client is still fetching an item it has never seen. If neither has answered by the time the retries run out, the roll is left alone rather than guessed at.

Bind-on-pickup prompts are only auto-confirmed for rolls the addon made itself. A prompt raised by your own click still waits for you.

### Announcing

Two settings: **Announce** sets the minimum quality, **Announce up to** sets the widest channel. The channel is a cap that steps down to whatever is available:

| Cap | In raid | In party | Solo |
| --- | --- | --- | --- |
| Say | say | say | say |
| Party | your subgroup | party | own chat frame |
| Raid | raid | party | own chat frame |
| Yell | yell | yell | yell |

### Pepe mode

Pepe mode prepends a random happy pepe to each announcement, picked from 22 of
the cheerful ones in [Twitch Emotes 2.0](https://www.curseforge.com/wow/addons/twitch-emotes-v2).
It never repeats the emote it used last.

They are all still frames. Twitch Emotes animates an emote by rewriting the
whole chat line 30 times a second, which stops an item tooltip on that line
from settling, so the animated pepes are kept out of the pool.

What goes out on the wire is the emote's name, so it becomes a picture only for
readers who run Twitch Emotes themselves. Everyone else sees the word, e.g.
`PepePogO Drop: [Cursed Vision of Sargeras]`. That addon is not a dependency of
this one and nothing breaks without it.

### Slash commands

| Command | Effect |
| --- | --- |
| `/apla` | Open the options panel (`/lap` also works) |
| `/apla pass` | Arm or disarm automated rolling |
| `/apla set <bop\|boe\|both> <3-5> <window\|pass\|greed\|need>` | Set the action for one quality and bind type |
| `/apla channel <say\|party\|raid\|yell>` | Set the announce channel cap |
| `/apla quality <0-5>` | Minimum quality to announce |
| `/apla announce` | Toggle chat output (off prints locally) |
| `/apla pepe` | Toggle pepe mode |
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
