<p align="center">
  <img src="assets/icon.png" width="128" alt="Farol icon">
</p>

<h1 align="center">Farol</h1>

<p align="center">A fast macOS terminal for working with coding agents.</p>

Farol is Portuguese for lighthouse. You run several agents at once, each in its own session, and Farol tells you which one needs you.

The terminal itself is [libghostty](https://github.com/ghostty-org/ghostty), the engine behind Ghostty. Farol adds a native macOS shell around it: a session sidebar, settings and, later, the agent workflow.

Farol is early. It works as a daily terminal, but expect rough edges.

## What works today

- **Sessions in a sidebar.** Open as many as you like. Hidden sessions keep running but stop rendering, so twenty background agents cost no GPU time.
- **Attention light.** When a session rings the bell or sends a notification while you look elsewhere, its dot lights up. Coding agents do this when they wait for input.
- **Ghostty rendering and compatibility.** Same fonts, same speed, same escape sequence support. Your existing Ghostty config is loaded.
- **Themes.** Pick from Ghostty's 600+ themes with live previews. The window chrome follows the theme.
- **Settings in the window.** Theme, font, size and cursor, plus a config file for everything else.

## Planned

Worktree sessions, agent status, tickets from GitHub, GitLab and Jira, and a diff view. See [ROADMAP.md](ROADMAP.md).

## Build

You need macOS 14 or later, Xcode 26 and Zig 0.16.

```sh
brew install zig
xcodebuild -downloadComponent MetalToolchain   # once, Xcode 26 no longer ships it
make install                                   # builds from source into /Applications
```

The first build compiles libghostty and takes a few minutes. After that, `make run` gives you a quick debug build and `make help` lists everything else.

## Shortcuts

| Action | Keys |
| --- | --- |
| New session | ⌘T |
| Close session | ⌘W |
| Next or previous session | ⇧⌘] and ⇧⌘[ |
| Go to session 1 to 9 | ⌘1 to ⌘9 |
| Toggle sidebar | ⌘B |
| Settings | ⌘, |

Closing the last session quits Farol.

## Configuration

Farol reads your Ghostty config first, then `~/.config/farol/config`, so Farol's values win. Both use Ghostty's config syntax. The settings page edits a few keys in the Farol file and leaves every other line alone.

```
theme = Catppuccin Mocha
font-family = JetBrains Mono
font-size = 14
```

See the [Ghostty docs](https://ghostty.org/docs/config) for every option.

## How it's built

```
Sources/
  GhosttyTerminal/   the only code that touches Ghostty's C API
  Farol/             the app: sessions, sidebar, window, settings
scripts/
  build-ghostty.sh   builds libghostty from a pinned commit
  bundle.sh          assembles build/Farol.app
  make-icon.swift    turns assets/icon-source.png into the app icon
  check-style.py     keeps comments and docs plain
```

Farol embeds Ghostty through its internal API (`ghostty.h`). Ghostty makes no stability promise for it, so the commit is pinned in `scripts/build-ghostty.sh`. Keeping every call in `GhosttyTerminal` means an upgrade only touches that folder.

## Contributing

Issues and pull requests are welcome. Before you open a PR, run:

```sh
make check
```

It flags em dashes, semicolons in prose, comment blocks over three lines and filler words. Comments should explain why, not what. If you use Claude Code in this repo, the same check runs after every edit.

## License

MIT. Farol includes libghostty, which is also MIT licensed. See `THIRD_PARTY_NOTICES`.
