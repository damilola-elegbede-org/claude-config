# Higgsfield Integration

Image, video, 3D and audio generation through the `higgsfield` CLI, driven by Higgsfield's official Claude plugin.

## What ships

| Piece             | Where                                   | Source                                                                       |
| ----------------- | --------------------------------------- | ---------------------------------------------------------------------------- |
| 9 skills          | the `higgsfield@higgsfield` plugin      | marketplace `higgsfield` = GitHub `higgsfield-ai/skills` (MIT), plugin `higgsfield` |
| CLI               | `/opt/homebrew/bin/higgsfield` (npm global) | `npm i -g @higgsfield/cli`                                               |
| Login + workspace | `~/.config/higgsfield/credentials.json` | `higgsfield auth login`, `higgsfield workspace set <id>`                     |

This repo no longer vendors the skills. `system-configs/.claude/settings.json` enables `higgsfield@higgsfield` and declares the
marketplace in `extraKnownMarketplaces` with `autoUpdate: true`. `/sync` installs the plugin at user scope (`sync_plugins` in
`scripts/sync.sh`). The Mac mini has no `enabledPlugins` of its own, so `sync-manifests/damilola-mbm.json` lists it under
`sync.plugins`, which installs exactly that list on the node.

The plugin runs with full agent permissions, some of its skills carry `allowed-tools: Bash`, and several tell the agent to run
`curl ... install.sh | sh` when the CLI is missing (the Jev gate, G10, holds that for approval). With `autoUpdate` on, upstream
changes load without a review in this repo. Turn `autoUpdate` off in `extraKnownMarketplaces` to review updates instead.

## Setup on a new machine

```bash
npm i -g @higgsfield/cli
higgsfield auth login          # browser sign-in
higgsfield workspace list
higgsfield workspace set <workspace_id>
scripts/sync.sh                # installs the plugin; checks the list below
```

## What `/sync` checks

`check_prerequisites` in `scripts/sync.sh` runs this block when the station syncs skills and the plugin is enabled: on a laptop,
`enabledPlugins["higgsfield@higgsfield"]` in the repo `settings.json`; on a manifest station, `higgsfield@higgsfield` in the
manifest's `sync.plugins`.

| Check                                                                                            | Failure                                                                           |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| `higgsfield` on PATH                                                                             | blocks laptop syncs (no manifest); warns on manifest stations like the fleet node |
| `python3` >= 3.9 (the brandkit scripts use `str.removeprefix`)                                   | same as above (brandkit and websites scripts)                                     |
| `higgsfield account status` (login and workspace, needs network)                                 | warning only                                                                      |
| `rsvg-convert`, `soffice`, `pdftoppm`, `pdffonts`, `fc-match`, `fc-cache`, `magick` or `convert` | warning only (brandkit export stages)                                             |

`HIGGSFIELD_SYNC_SKIP_CHECK=1` skips the block; tests that run a real sync into a temp HOME set it.
Coverage is in `tests/hooks/test_higgsfield_sync_check.sh`.

## Giving another machine or agent (Clara) access

The CLI authenticates with OAuth 2.0 PKCE through a browser (`higgsfield auth --help`). Its `auth` commands are `login`, `logout` and
`token`. Higgsfield's help center says the CLI needs "No API key needed" and that "API keys belong to the
Higgsfield API, a separate developer product"
([source](https://higgsfield.ai/creator-hub/help-center/mcp-cli/how-do-i-access-higgsfield-via-cli)),
so the CLI is OAuth-only and API keys would mean different tooling. Two ways to give a station access:

1. Run `higgsfield auth login` on that station once and complete the browser step. The stored refresh token keeps it signed in.
2. Copy `~/.config/higgsfield/credentials.json`. It holds the access and refresh token for the signing-in account, so treat it as a
   password and never paste it into chat.

Either way the station spends the credits of the account that signed in. The Mac mini receives the plugin through `/sync` but also
needs the CLI installed and signed in to run the skills (`/sync` only warns there, so a merge never blocks it).
