<p align="center">
  <img src="assets/icon.png" width="128" alt="Farol icon">
</p>

<h1 align="center">Farol</h1>

<p align="center">A fast macOS terminal for working with coding agents.</p>

Farol is Portuguese for lighthouse. You run several agents at once, each in its own session, and Farol tells you which one needs you.

The terminal itself is [libghostty](https://github.com/ghostty-org/ghostty), the engine behind Ghostty. Farol adds a native macOS shell around it: a session sidebar, settings and, later, the agent workflow.

Farol is early. It works as a daily terminal, but expect rough edges.

## What works today

- **Sessions in a sidebar.** Open as many as you like. Hidden sessions keep running but stop rendering, so twenty background agents cost no GPU time. Each row shows the session's git branch. Double-click to rename, drag to reorder.
- **Find in scrollback.** ⌘F searches the focused pane and shows the match count.
- **Split panes.** ⌘D splits a session, and the new pane opens in the same folder. Layouts come back after a relaunch.
- **Worktree sessions.** ⇧⌘T asks for a branch and opens a session in its own git worktree, so parallel agents never touch each other's files. Closing it offers to remove the worktree and always keeps the branch.
- **Agent status.** Each session shows whether its agent is working, waiting for you or done, with a notification when it waits in the background. See [Agent status](#agent-status).
- **Ghostty rendering and compatibility.** Same fonts, same speed, same escape sequence support. Your existing Ghostty config is loaded.
- **Themes.** Pick from Ghostty's 600+ themes with live previews. The window chrome follows the theme.
- **Settings in the window.** Theme, font, size and cursor, plus a config file for everything else.
- **Copy and paste.** Pasting text that could run commands asks first. Files copied in Finder paste as their paths.
- **Accents and input methods.** Dead keys compose as you type, and input methods for other languages work at the cursor.

## Planned

Tickets from GitHub, GitLab and Jira, and a diff view. See [ROADMAP.md](ROADMAP.md).

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

## Build

You need macOS 14 or later, Xcode 26 and Zig 0.16.

```sh
brew install zig
xcodebuild -downloadComponent MetalToolchain   # once, Xcode 26 no longer ships it
make install                                   # builds from source into /Applications
```

The first build compiles libghostty and takes a few minutes. After that, `make run` gives you a quick debug build and `make help` lists everything else.

### Signed builds

`make dist` builds a zip that opens on any Mac without warnings: signed with a Developer ID, notarized by Apple and stapled. It needs a Developer ID Application certificate in your keychain and a notarization key stored once:

```sh
xcrun notarytool store-credentials farol --key AuthKey_XXXX.p8 --key-id <Key ID> --issuer <Issuer ID>
```

The key comes from App Store Connect, under Users and Access, Integrations, App Store Connect API.

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

Issues and pull requests are welcome. Before you open a PR, run:

```sh
make test
make check
```

It flags em dashes, semicolons in prose, comment blocks over three lines and filler words. Comments should explain why, not what. CI runs the same check on every pull request.

## License

MIT. Farol includes libghostty, which is also MIT licensed. See `THIRD_PARTY_NOTICES`.
