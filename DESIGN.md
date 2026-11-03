# Design

How Farol looks and why. Read this before changing any view, color, icon or animation.

Farol is a quiet Mac app that gets loud only when an agent needs you. Every rule below serves that.

## Color

- **In the work area, color means agent status.** The sidebar, top bar and panels are the theme's grays. The lamps are the only color there.
- **Outside it, color means identity, and only on a tile.** Settings sections and tools (agents, forges, Jira) sit on a `Tile` or `ToolTile`. A tool takes its maker's color, a section takes a theme hue at full saturation.
- **Every color comes from the Ghostty theme**, through `Palette`. A view has to read well in any of the 600+ themes, light and dark.

## The lamps

The status dot beside each session is what Farol is for. Its states are fixed: a hollow ring for idle, breathing for working, a ripple for waiting, solid for done. A lamp stays a plain 7pt dot, crisp on its own, with nothing drawn around it.

## Scale

Font sizes and corner radii come from one scale, kept in `FONT_SIZES` and `RADII` in `scripts/check-style.py`. `make lint` fails on anything off it, so pick the nearest step.

## Shared views

Build from what exists, so a change to one shape reaches every screen:

- `Tile`, `ToolTile` (`ForgeIcon.swift`): an icon on a colored tile.
- `Badge` (`Chrome.swift`): a state like Connected, or a tag like worktree.
- `EmptyState` (`Chrome.swift`): a panel with nothing to show.
- `Card`, `Row` (`SettingsPage.swift`): grouped settings.
- `IconButton`, `CloseButton`, `QuietPress` (`Chrome.swift`), `SheetButton` (`Sheet.swift`).

## Restraint

- Headers are sentence case and muted. Controls reveal more on hover.
- The terminal and code stay solid. Glass goes on side panels only, as in Apple's own apps.
- Native macOS controls, given a hover where macOS leaves them without one.

## Motion

Motion is short and says what changed: a selection slides, a panel opens, a tip fades in. It goes through `Motion.enabled`, so the Animations setting and Reduce Motion turn it off. The lamps keep moving either way, since their motion is how a waiting agent asks for you. A terminal takes its new size once a panel stops, so a program redraws once.

## Decided

Tried and settled, so they stay settled unless a person asks:

- Sidebar rows show the lamp, without an agent icon beside it. An icon competed with the lamp.
- Styles are Classic, Boxed and Glass. A tinted style broke the color rule.
- The terminal background is solid by default.
