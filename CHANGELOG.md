# Changelog

Notable changes to Farol. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The DMG opens as a small window with Farol next to Applications, ready to drag.

## [0.1.1] - 2026-09-27

The first signed release: download the DMG, drag Farol to Applications and open it.

### Added

- New sessions open in the focused pane's folder instead of the home folder.
- Double-clicking the top bar zooms the window, or does what you chose in System Settings.
- Rename a session by double-clicking it in the sidebar, or with right-click. An empty name goes back to the automatic one.
- Drag sessions to reorder them. ⌘1 to ⌘9 follow the new order.
- Session names and order are saved with the rest of the session.
- Agent status: the `farol status working|waiting|done|clear` command, available in every session as `$FAROL_CLI`, reports to the app over a private local socket. The sidebar dot shows working, waiting (pulsing) or done (a ring, cleared when you look), and the most urgent pane wins in a split session.
- Ready-made Claude Code hooks in the README.
- Agents settings page: connect or disconnect Claude Code in one click (only Farol's hooks change, with a backup of the file), switch notifications and the Dock badge, and choose what new sessions start with (shell, Claude Code, Codex or a custom command).
- A notification when an agent waits or finishes while Farol is in the background, and a Dock badge counting waiting sessions. Clicking the notification opens the session.

## [0.1.0] - 2026-09-27

The first tagged version. Build it from source with `make install`. Signed downloads come later.

### Added

- Session sidebar, themes with live previews, settings inside the window and the app icon.
- Copy and paste through the Edit menu. Pasting text that could run commands shows a confirmation first.
- Files copied in Finder paste as shell-escaped paths.
- A program asking to read or set the clipboard needs your approval.
- CI runs the style check on every push and pull request.
- Dead keys and input methods. Accents compose as you type, the pending accent shows at the cursor, and Japanese, Chinese and Korean input places its candidate window at the cursor.
- The emoji picker and dictation type into the terminal.
- Sessions come back after a relaunch, in the same folders and order, with the same one selected. Folders that no longer exist are skipped, and closing the last session starts the next launch fresh.

- Worktree sessions with ⇧⌘T. Farol asks for a branch name and opens a session in its own git worktree under `~/.farol/worktrees/<repo>/<branch>`. A new branch starts from the current one, and an existing branch opens as it is.
- Closing a worktree session offers to remove the worktree. The branch always stays, and a worktree with uncommitted changes is kept.
- The sidebar shows the git branch of every session and updates after a checkout.
- `FarolCore` module with tests for the git and worktree logic, run with `make test`.

- Ghostty's default window shortcuts: ⌘N opens a session, ⇧⌘W quits, ⌃⌘F toggles full screen and ⇧⌘, reloads the config. Rebinding them in your config works too.
- ⌘-click opens links, and the pointer changes shape over them.
- Closing a session or quitting asks first when a program is still running.

- Split panes with Ghostty's shortcuts: ⌘D and ⇧⌘D to split, ⌘[ ⌘] and ⌘⌥ arrows to move, ⌘⌃ arrows to resize, ⌘⌃= to equalize and ⇧⌘↩ to zoom. Dividers can be dragged. A new pane opens in the focused pane's folder, and unfocused panes dim.
- ⌘W closes the focused pane, and the session with its last one.
- Pane layouts are saved with the sessions and restored after a relaunch.
- Debug builds run as "Farol Dev" with their own saved sessions, so testing never touches the installed app.

- Find in scrollback: ⌘F opens a search bar on the focused pane with a match count, ↩ and ⇧↩ or ⌘G and ⇧⌘G move between matches, ⌘E searches the selected text, and esc closes it.

- Settings: cursor blink, Option key as Alt (off by default so Option still types accents) and copy on select.
- The Shortcuts page lists every shortcut, grouped by sessions, panes, find, terminal and window.
- The style check also reads interface text in Swift strings.

### Added

- `make dist` builds a signed and notarized DMG and zip, and pushing a version tag publishes them on GitHub Releases. Farol runs with the hardened runtime and asks macOS for camera, microphone, AppleScript and similar access on behalf of programs running in it.

### Changed

- The top bar has no rule under it, and each part takes the color of the column below, so the terminal reaches the top edge.

- New app icon, Beam: the lighthouse with a lit blue lamp. Settings → Appearance offers three more (Dark, Navy, Light) for the Dock icon, in a dropdown with previews.

- Farol is monochrome: selected marks and the agent dot use the theme's text color instead of an accent hue, and switches use a neutral gray.
- The Agents settings page shows Claude Code as connected or not, with a clear Connect button, and drops the "Other agents" note, which now lives only in the README.

### Fixed

- The Farol config file now ends with a newline, so settings appended by hand stay on their own line.
- The window's close button no longer closes the window when you cancel the quit.
- Choosing the Beam icon no longer shows an old cached icon in the Dock, and `make install` refreshes the icon macOS caches.
- A faint edge keeps dark app icons visible on a dark Dock.
- The search bar's field no longer collapses, and its buttons are centered.
- Settings controls line up on the same edge.

[Unreleased]: https://github.com/snowztech/farol/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/snowztech/farol/releases/tag/v0.1.1
[0.1.0]: https://github.com/snowztech/farol/releases/tag/v0.1.0
