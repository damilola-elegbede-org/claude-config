# Higgsfield Integration

Image, video, 3D and audio generation through the `higgsfield` CLI, driven by 8 vendored skills.

## What ships

| Piece             | Where                                        | Source                                                           |
| ----------------- | -------------------------------------------- | ---------------------------------------------------------------- |
| 8 skills          | `system-configs/.claude/skills/higgsfield-*` | `npx skills add higgsfield-ai/skills` (v0.13.0), copied verbatim |
| CLI               | `/opt/homebrew/bin/higgsfield` (npm global)  | `npm i -g @higgsfield/cli`                                       |
| Login + workspace | `~/.config/higgsfield/credentials.json`      | `higgsfield auth login`, `higgsfield workspace set <id>`         |

Skills: `higgsfield-generate` (image, video, 3D, audio, Marketing Studio), `higgsfield-brandkit`, `higgsfield-marketplace-cards`,
`higgsfield-product-photoshoot`, `higgsfield-soul-id`, `higgsfield-video-explainer`, `higgsfield-websites`, `higgsfield-youtube-thumbnail`.

The skills are third-party (MIT, notice in `HIGGSFIELD_LICENSE.txt`) and kept verbatim except for one added `license: MIT` frontmatter line,
which is the repo's marker for imported skills and exempts them from the `## Usage` / `## Expected Output` template checks.
A future `npx skills add` diff therefore stays reviewable. They run with full agent permissions; review
updates before merging. Four of them tell the agent to run `curl ... install.sh | sh` when the CLI is missing, which the Jev gate (G10)
holds for approval.

## Setup on a new machine

```bash
npm i -g @higgsfield/cli
higgsfield auth login          # browser sign-in
higgsfield workspace list
higgsfield workspace set <workspace_id>
scripts/sync.sh                # deploys the skills; checks the list below
```

## What `/sync` checks

`check_prerequisites` in `scripts/sync.sh` runs this block when the station syncs skills and the source tree ships `higgsfield-*` skills.

| Check                                                                    | Failure                                         |
| ------------------------------------------------------------------------ | ----------------------------------------------- |
| `higgsfield` on PATH                                                     | blocks the sync, prints the install command     |
| `python3`                                                                | blocks the sync (brandkit and websites scripts) |
| `higgsfield account status` (login and workspace, needs network)         | warning only                                    |
| `rsvg-convert`, `soffice`, `pdftoppm`, `fc-match`, `magick` or `convert` | warning only (brandkit export stages)           |

`HIGGSFIELD_SYNC_SKIP_CHECK=1` skips the block; tests that run a real sync into a temp HOME set it.
Coverage is in `tests/hooks/test_higgsfield_sync_check.sh`.

## Giving another machine or agent (Clara) access

The CLI authenticates with OAuth 2.0 PKCE through a browser (`higgsfield auth --help`). Its `auth` commands are `login`, `logout` and
`token`. No API-key or token environment variable appears in the CLI's help, its npm README, or the skills (inference: none is supported
yet). Two ways to give a station access:

1. Run `higgsfield auth login` on that station once and complete the browser step. The stored refresh token keeps it signed in.
2. Copy `~/.config/higgsfield/credentials.json`. It holds the access and refresh token for the signing-in account, so treat it as a
   password and never paste it into chat.

Either way the station spends the credits of the account that signed in. A fleet station also needs the CLI installed (`/sync` blocks
until it is).
