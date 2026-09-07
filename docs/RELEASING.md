# Releasing

Nothing here is needed to develop or share the addon by hand. It only matters
once you want CurseForge to distribute it and the CurseForge app to update it
for your guild automatically.

## One-time setup

1. **Create the project on CurseForge.** Sign in at
   <https://legacy.curseforge.com/wow/addons> and start a new project. You pick
   the name, summary, category and license, and upload a first file by hand.
   Approval by a moderator takes a day or two the first time.

2. **Copy the project ID.** It appears on the project page as a numeric ID.
   Put it in the `.toc`:

   ```
   ## X-Curse-Project-ID: 123456
   ```

   Without this line the packager builds a zip but has nowhere to upload it.

3. **Create an API token** at <https://legacy.curseforge.com/account/api-tokens>.

4. **Add the token to GitHub** under Settings → Secrets and variables → Actions,
   named `CF_API_KEY`. `GITHUB_TOKEN` is provided automatically, you do not
   create that one.

## Every release

```cmd
git tag v1.0.1
git push --tags
```

The `Release` workflow then:

- builds a zip containing only what `.pkgmeta` does not ignore
- replaces `@project-version@` in the `.toc` with the tag name
- generates a changelog from commits since the previous tag
- attaches the zip to a GitHub release
- uploads it to CurseForge if the project ID and API key are both present

Tag names become version numbers, so keep the `vMAJOR.MINOR.PATCH` form consistently.

## Game flavour

`release.yml` passes `-g bcc`, which is the flavour matching the client this
addon is developed against:

| Checked | Value |
| --- | --- |
| Client folder | `_anniversary_` |
| `.flavor.info` | `wow_anniversary` |
| `## Interface` in the toc | `20506` (2.5.6, Burning Crusade) |
| Toc suffix other addons ship for it | `_TBC.toc` |

So the Anniversary realms currently run a Burning Crusade build, and `bcc` is
the flavour that lines up with it. Re-check this if the realms advance to a
later expansion: the flavour tells CurseForge which client the file is for, and
it must stay in step with the `## Interface` number in the toc. If you ever want
one zip to serve several clients, the packager also reads `_Vanilla.toc`,
`_TBC.toc`, `_Wrath.toc` style companion files.

To test the packaging without uploading anything, set `args: -g bcc -d` in the
workflow and push a throwaway tag:

```cmd
git tag v0.0.1-test
git push --tags
```

`-d` skips all uploads.

## Version numbering

`## Version: @project-version@` in the `.toc` is a placeholder the packager
substitutes. In a working copy it shows literally as `@project-version@` in the
addon list, which is expected and only affects your own client.
