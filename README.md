# Auto Pass Loot Announcer

Announces group loot drops **the moment they drop**, and rolls need, greed or pass for you based on item quality.

Built for raids where everyone is asked to pass on loot. Blizzard's "Pass on Loot" option is server side: with it on, the server never sends you the roll, so you never find out what dropped until people start looting. This addon replaces that option with automated passing you can actually see.

![Chat output](Media/screenshots/chat-output.png)

## Features

- **Announces on the roll**, not on the corpse, so you see drops even when someone else loots the body
- **One line per item**, to your choice of channel
- **Per-quality roll actions** — need, greed, pass, or leave the window up, set independently for each item quality
- **Single announcer election** — when several people in the group run the addon, they agree on one announcer so the drop is posted once
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

Each quality gets one action:

| Action | Result |
| --- | --- |
| Window | Nothing happens, the roll window stays on screen for you |
| Pass | Passes immediately |
| Greed | Greeds, and auto-confirms the bind-on-pickup prompt |
| Need | Needs, auto-confirms, and prints a local notice |

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

Pepe mode prepends a random happy pepe to each announcement, picked from 24 of
the cheerful ones in [Twitch Emotes 2.0](https://www.curseforge.com/wow/addons/twitch-emotes-v2).
It never repeats the emote it used last.

What goes out on the wire is the emote's name, so it becomes a picture only for
readers who run Twitch Emotes themselves. Everyone else sees the word, e.g.
`PepePogO Drop: [Cursed Vision of Sargeras]`. That addon is not a dependency of
this one and nothing breaks without it.

### Slash commands

| Command | Effect |
| --- | --- |
| `/apla` | Open the options panel (`/lap` also works) |
| `/apla pass` | Arm or disarm automated rolling |
| `/apla set <0-5> <window\|pass\|greed\|need>` | Set the action for one quality |
| `/apla channel <say\|party\|raid\|yell>` | Set the announce channel cap |
| `/apla quality <0-5>` | Minimum quality to announce |
| `/apla announce` | Toggle chat output (off prints locally) |
| `/apla corpse` | Toggle announcing from the loot window |
| `/apla pepe` | Toggle pepe mode |
| `/apla coop` | Toggle single-announcer coordination |
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
