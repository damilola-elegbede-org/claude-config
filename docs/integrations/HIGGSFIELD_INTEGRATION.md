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
| `higgsfield` on PATH                                                     | blocks laptop syncs (no manifest); warns on manifest stations like the fleet node     |
| `python3` >= 3.9 (the brandkit scripts use `str.removeprefix`)           | same as above (brandkit and websites scripts) |
| `higgsfield account status` (login and workspace, needs network)         | warning only                                    |
| `rsvg-convert`, `soffice`, `pdftoppm`, `fc-match`, `magick` or `convert` | warning only (brandkit export stages)           |

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

Either way the station spends the credits of the account that signed in. A fleet station also needs the CLI installed and signed in to run the
skills (`/sync` only warns there, so a merge never blocks it).

## Local edits to the vendored skills

Beyond the `license: MIT` line, six review fixes are local (PR #282). Re-apply them, or confirm upstream fixed them, when re-vendoring.

| File | Fix |
| ---- | --- |
| `higgsfield-websites/references/game-*.md` (6 files) | stale filenames: bare `meshy-input-rules.md`, `procedural-animation.md`, `meshy-api.md` and `stylization.md` now use their shipped `game-` names (17 refs) |
| `higgsfield-brandkit/references/state-payloads.md` | `geometry_fingerprint` applies to SVG logos only; non-SVG official logos are locked without it |
| `higgsfield-websites/references/app-cover.md` | the Higgsfield-branded lockup is for marketplace covers; standalone-site OG covers carry only the user's brand |
| `higgsfield-websites/references/app-quickstart.md` | one confirm-enabled adapter shared by every SDK client |
| `higgsfield-websites/references/fnf-sdk.md` | the example returns a flat DTO, not the raw SDK result |
| `higgsfield-websites/SKILL.md` | the ban covers user-facing generation features, not the build's own asset generation |

## Known upstream issues (acknowledged, not fixed here)

Reported by CodeRabbit on #282; left verbatim because the fixes are untested edits to third-party code. Worth raising with
`higgsfield-ai/skills`.

- `higgsfield-brandkit/scripts/brandkit.py` `recolor_svg` does not rewrite colors inside `<style>` elements,
  so monochrome logo exports keep class-based colors.
- `higgsfield-brandkit/scripts/brandkit.py` approves a logo that has only an `id`, but `brandbook-build` later needs a
  public URL or readable path, so an apparently valid state can fail to build (Codex).
- `higgsfield-brandkit/scripts/brandkit.py` ignores `style: "italic"` in typography previews, so the user may approve a
  regular or synthesized face instead of the chosen italic (Codex).
- `higgsfield-brandkit/scripts/brandkit.py` emits no `@font-face` for a missing or unreadable local font path, so the preview
  silently shows a fallback font that can be approved as the chosen typeface (Codex).
- `higgsfield-brandkit/scripts/build_brandbook.py` palette limits differ from what `palette.md` and `normalize_slot` accept.
- `higgsfield-brandkit/scripts/render_brandbook_pdf.py` sets `FONTCONFIG_FILE`, which LibreOffice's native macOS build does not read for font discovery.
- `higgsfield-websites/references/game-design-system.md` requires `build-game.md` (before any game build) and `multiplayer.md`
  (co-op, versus and massive games), but neither this repo nor upstream `main` ships either file, so the promised
  skeletons, numeric defaults and multiplayer rules are missing.
- 9 vendored files tell the agent to run `curl ... install.sh | sh` from the `main` branch with no checksum. The Jev G10 gate holds that command for approval.
