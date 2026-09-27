<p align="center">
  <img src="assets/icon.png" width="128" alt="Farol icon">
</p>

<h1 align="center">Farol</h1>

<p align="center">A fast macOS terminal for working with coding agents.</p>

Run several coding agents side by side, each in its own session, and Farol shows you which one is working, which one is done and which one needs you. Farol is Portuguese for lighthouse.

Underneath is [libghostty](https://github.com/ghostty-org/ghostty), the engine behind Ghostty, so it is as fast as Ghostty and reads your Ghostty config.

Farol is early. It works as a daily terminal, but expect rough edges.

## Install

1. Download [Farol.dmg](https://github.com/snowztech/farol/releases/latest/download/Farol.dmg), the latest release.
2. Open it and drag Farol to Applications.
3. Open Farol from Applications or Spotlight.

It needs a Mac with Apple Silicon and macOS 14 or later. Releases are signed and notarized, so macOS opens Farol without warnings. To build from source instead, see [Build from source](#build-from-source).

## Features

- **Agent status.** Each session shows whether its agent is working, waiting for you or done, with a notification when it waits in the background. See [Agent status](#agent-status).
- **Worktree sessions.** ⇧⌘T asks for a branch and opens a session in its own git worktree, so parallel agents never touch each other's files. Closing it offers to remove the worktree and always keeps the branch.
- **Sessions in a sidebar.** Open as many as you like. Hidden sessions keep running but stop rendering, so twenty background agents cost no GPU time. Each row shows its git branch. Double-click to rename, drag to reorder.
- **Split panes.** ⌘D splits a session, and the new pane opens in the same folder. Layouts come back after a relaunch.
- **Find in scrollback.** ⌘F searches the focused pane and shows the match count.
- **Ghostty inside.** Same rendering, speed and escape sequence support, and your Ghostty config is loaded.
- **Themes and settings.** Ghostty's 600+ themes with live previews, and settings inside the window.
- **Copy and paste, accents and input methods.** Pasting text that could run commands asks first, dead keys compose as you type, and input methods for other languages work at the cursor.

Coming next: tickets from GitHub, GitLab and Jira, and a diff view. See [ROADMAP.md](ROADMAP.md).

## Agent status

Each session's dot in the sidebar shows what its agent is doing:

- **Working:** a steady dot.
- **Waiting for you:** the dot pulses, for a permission prompt or a question.
- **Done:** a ring, cleared when you open the session.

When an agent waits or finishes while Farol is in the background, you get a notification, and the Dock icon counts the sessions that are waiting.

**Claude Code:** open Settings → Agents and click **Connect**. Farol adds its hooks to `~/.claude/settings.json`, leaves everything else in the file alone and keeps a backup. **Disconnect** removes only Farol's hooks.

**Other agents** can report with `"$FAROL_CLI" status working|waiting|done|clear`, which Farol makes available in every session. Agents that ring the terminal bell light the dot without any setup.

<details>
<summary>The Claude Code hooks, if you prefer to add them by hand</summary>

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status working" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status working" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status waiting" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status done" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status clear" }] }]
  }
}
```

Outside Farol `$FAROL_CLI` is unset, so the hooks do nothing.

</details>

## Shortcuts

| Action | Keys |
| --- | --- |
| New session | ⌘T or ⌘N |
| New worktree session | ⇧⌘T |
| Close pane or session | ⌘W |
| Next or previous session | ⇧⌘] and ⇧⌘[ |
| Go to session 1 to 9 | ⌘1 to ⌘9 |
| Split right or down | ⌘D and ⇧⌘D |
| Move between panes | ⌘[ and ⌘], or ⌘⌥ with arrows |
| Resize the focused pane | ⌘⌃ with arrows |
| Equal pane sizes | ⌘⌃= |
| Zoom the focused pane | ⇧⌘↩ |
| Find, next, previous | ⌘F, ⌘G, ⇧⌘G |
| Find the selected text | ⌘E |
| Toggle sidebar | ⌘B |
| Full screen | ⌃⌘F |
| Settings | ⌘, |
| Reload configuration | ⇧⌘, |

Closing the last session quits Farol. Closing a session or quitting asks first when a program is still running. Ghostty's other default shortcuts, such as ⌘K to clear and ⌘+ to zoom, work as in Ghostty.

## Configuration

Farol reads your Ghostty config first, then `~/.config/farol/config`, so Farol's values win. Both use Ghostty's config syntax. The settings page edits a few keys in the Farol file and leaves every other line alone.

```
theme = Catppuccin Mocha
font-family = JetBrains Mono
font-size = 14
```

See the [Ghostty docs](https://ghostty.org/docs/config) for every option.

## Build from source

You need macOS 14 or later, Xcode 26 and Zig 0.16.

```sh
brew install zig
xcodebuild -downloadComponent MetalToolchain   # once, Xcode 26 no longer ships it
make install                                   # builds from source into /Applications
```

The first build compiles libghostty and takes a few minutes. After that, `make run` gives you a quick debug build and `make help` lists everything else.

## How it's built

```
Sources/
  GhosttyTerminal/   the only code that touches Ghostty's C API
  FarolCore/         git and worktree logic, no UI, tested
  Farol/             the app: sessions, sidebar, window, settings
Tests/               FarolCore tests, run with `make test`
scripts/
  build-ghostty.sh   builds libghostty from a pinned commit
  bundle.sh          assembles build/Farol.app
  make-icon.swift    builds the app icons from assets/icons/source
  check-style.py     keeps comments and docs plain
```

Farol embeds Ghostty through its internal API (`ghostty.h`). Ghostty makes no stability promise for it, so the commit is pinned in `scripts/build-ghostty.sh`. Keeping every call in `GhosttyTerminal` means an upgrade only touches that folder.

## Contributing

Issues and pull requests are welcome. Before you open a PR, run the tests and the style check:

```sh
make test
make check
```

`make check` flags em dashes, semicolons in prose, comment blocks over three lines and filler words. Comments should explain why, not what. CI runs the same check on every pull request.

## License

MIT. Farol includes libghostty, which is also MIT licensed. See `THIRD_PARTY_NOTICES`.
