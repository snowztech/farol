# Changelog

Notable changes to Farol. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Codex sessions now show working, waiting and done dots like Claude Code. Settings → Agents → Update replaces Farol's terminal-notification workaround with lifecycle hooks. Restart open Codex sessions and trust the new hooks with `/hooks`.

## [0.13.1] - 2026-09-30

Long review lines stay inside their background.

### Fixed

- Long lines in the review panel no longer spill a few pixels past their green or red background.

## [0.13.0] - 2026-09-30

A status panel on the screen edge, out of the notch's way.

### Added

- The status panel can sit on the screen edge instead of the notch: a slim tab on the right side, which doesn't get in the way of other apps that use the notch and works on any Mac. Pick it in Settings → Agents → Outside Farol → Status panel. Drag the tab up or down, or to the left edge, and it stays where you leave it.

### Fixed

- The status panel opens as soon as you hover it, instead of flickering open and closed.

## [0.12.0] - 2026-09-30

See your agents from any app, in the menu bar or around the notch.

### Added

- Agent status in the menu bar. Farol's lighthouse sits in the menu bar, and its beams light up in the sidebar's colors for the most urgent state across sessions. Its menu lists the sessions and opens the one you pick.
- Agent status around the notch, on Macs with one. While agents are active the notch grows a little, with Farol's icon on one side and the number of active sessions on the other, in the state's color. Hover it to see the sessions and open one. Idle, the notch stays as it is.
- Both are in Settings → Agents → Outside Farol, off by default.

## [0.11.2] - 2026-09-30

Background agents no longer end a session early.

### Fixed

- Claude Code sessions stay working while a background agent runs, instead of showing done and notifying as soon as Claude's turn ends. You're notified once, when everything has finished. Settings → Agents asks to update Claude Code's hooks once to get this.

### Changed

- The "done" notification reads "Check the result or send the next prompt."

## [0.11.1] - 2026-09-29

Tooltips that show, and small fixes.

### Fixed

- Tooltips show again. Farol draws its own under each button, in the theme's colors, with the shortcut muted after the name: the title bar buttons, the change count, close buttons, the find bar and the review's compare menu.

### Changed

- The links and buttons in Settings → About, and Open config file, show the pointing hand like the rest of the app. Open config file also gets the same hover as New task.
- Reload Configuration is set up as ⇧⌘, in the menu, the same as in Settings → Shortcuts and the README.
- For contributors: a short CONTRIBUTING.md, issue and pull request templates, and notes that AI coding tools read.

## [0.11.0] - 2026-09-29

Select and copy code in the review, and a calmer title bar.

### Added

- Select text across lines in the review panel and copy it, with the same selection color as the file pane. Each file's diff is now one text view that shares its setup with the file pane, so both show code the same way.

### Changed

- The sidebar and the files panel run up into the title bar in their own color, like other Mac apps with a sidebar. The window title is centered over the content between the open panels, so it no longer sits on a divider. The new session button stays next to the sidebar and files buttons instead of moving with the sidebar.
- Hovering a session or a file is lighter than selecting it, so the two don't look alike, and session rows no longer pop up their path.
- The sidebar button looks switched on while the sidebar is open, like the files and settings buttons.

## [0.10.0] - 2026-09-29

Syntax colors, and a calmer file pane.

### Added

- Syntax colors in the file pane and the review panel: comments, strings, numbers and keywords for Swift, Go, JavaScript and TypeScript, Python, Rust, Ruby, shell, the C family, JSON, YAML, TOML, CSS, HTML, XML, SVG and Markdown. The colors come from your terminal theme, so they always match it.

### Changed

- Images, PDFs, video and audio open in their Mac app when you click them in the files panel or the review. Other files Farol can't show as text are revealed in Finder instead of opening a pane that only says so.
- The file pane's header takes the pane's own background, so it lines up with the terminal and the files panel instead of sitting on top as a separate bar.
- Unsaved edits show as a small muted dot after the file name, the same size as the sidebar's status dots.
- The pointer turns into a hand over everything you can click: buttons, the file tree, sessions, review files and the settings sections.
- For contributors: the style check is now `make lint`, and the workflow is called CI.

## [0.9.1] - 2026-09-28

Clearer agent settings and a few fixes.

### Fixed

- Update in Settings → Agents now also removes Farol hooks from events it no longer uses. A leftover SessionStart hook from an early build made Claude report a hook error at every start.
- Long lines in the review panel stop at the edge of their file instead of running past it.

### Changed

- Settings → Agents says **Connect** and **Disconnect** again, with Connected and Not connected. "Turn off Claude Code" read as if it stopped Claude Code itself. Disconnecting now says first what you lose, and that the agent keeps working as before.
- New screenshots in the README and on the landing page, which now shows the review panel.

## [0.9.0] - 2026-09-28

Review what your agents changed without leaving Farol.

### Added

- Review panel (⌥⌘R, or the change count in the title bar): every file the session changed as one scrolling diff, with added and removed lines, folded unchanged runs and the counts per file. Untracked files show as new, and big diffs like lockfiles start folded. It updates as the agent works.
- Compare with uncommitted changes, or with everything since the branch left main or any other local branch. Branches start on "since main", and the choice is kept per project.
- The title bar shows the session's change count, like `± +821 −61`, only while there are changes.
- Open a file from the review to land on its first change, ready to edit.
- The file pane's header shows the file's folder, muted, before its name.

### Changed

- One quiet close button across panes, panels, sidebar rows and the find bar.

## [0.8.0] - 2026-09-28

Your project's files next to the terminal, with a light editor for quick fixes while agents work.

### Added

- Files panel (⇧⌘E, or the folder button in the title bar): the session's project as a tree, next to the sidebar. Folders load when you open them, hidden and git-ignored files are dimmed, and new files show up as agents create them. Nothing is watched while the panel is closed.
- Click a file to open it in a pane beside the terminal, with line numbers and ⌘F. Opening another file reuses the pane, ⌘W closes it, and it comes back after a relaunch.
- Edit the open file and save with ⌘S. A dot next to the name marks unsaved edits, and Farol asks before closing the file, the session or the app with unsaved edits. Saving keeps the file's permissions.
- When an agent changes the open file, the pane reloads and keeps your place. With unsaved edits, it asks whether to reload or keep yours.
- A new line starts at the same indent as the one above.
- Undo, Redo and Cut in the Edit menu.
- ⌘[ and ⌘] move to the file pane too, like any other pane.

### Changed

- The new session button sits at the right edge of the sidebar, above the sessions it creates.

## [0.7.0] - 2026-09-28

Codex notifications that actually reach you, and an option to group sessions by project.

### Added

- Settings → Appearance → Group sessions by project sorts the sidebar into one section per project once you work in more than one. A project is a git repository, worktrees included. It is off by default, and ⌘1 to ⌘9 follow the order shown.

### Changed

- Codex works again. The hooks from 0.6 never reached Farol, because Codex 0.158 runs them in a background process that loses track of the terminal. Settings → Agents → Enable now turns on Codex's terminal notifications in `~/.codex/config.toml` and removes the old hooks. You get notified when Codex needs your approval or finishes, and the session keeps a yellow dot until you open it. Codex can't report while it works, so there is no working dot. If you connected Codex in 0.6, Settings shows **Needs update**.
- Farol changes only the lines it marks in `config.toml`, never a value you set yourself, and **Turn off** removes just those lines.
- Settings → Agents says **Enable** and **Turn off** instead of Connect and Disconnect.
- A notification from an agent without hooks no longer claims it needs your approval, since it may just have finished.

### Fixed

- Session names drop the extra parts agents add after a separator, so a Codex session shows "Design codebase" instead of "Design codebase | farol", and "farol" instead of "| farol" before the conversation has a name.

## [0.6.0] - 2026-09-28

Codex joins Claude Code in the sidebar, and notifications say plainly what the agent needs from you.

### Added

- Codex support: Settings → Agents → Connect adds Farol's hooks to `~/.codex/hooks.json`, so the sidebar shows when Codex is working, waiting for your approval or done. Codex asks you to approve the hooks the first time.

### Changed

- Clearer notifications. "Done" now says it's your turn to check the result or send the next prompt, and "waiting" says the agent needs your approval or an answer.
- Farol asks for permission to notify when you connect an agent, instead of at the first notification, which was easy to miss.
- Settings → Agents says when macOS blocks Farol's notifications, with a button to open System Settings.

## [0.5.0] - 2026-09-28

Start an agent on a task in one step, and know when a new Farol is out.

### Added

- New Task (⇧⌘N, or New task at the bottom of the sidebar): describe a task, pick Claude Code or Codex, and Farol creates a worktree and starts the agent on it. The branch name comes from the task and can be edited.
- A small Update button appears in the top bar when a newer Farol is out, with the same note in Settings → About. Clicking it downloads the new version.

### Fixed

- A finished Claude Code session no longer turns into "waiting" and notifies again a minute later. Farol now only counts permission prompts and questions as waiting, not Claude's idle reminder. If you connected Claude Code before, Settings → Agents shows Needs update: click Update.
- Closing a worktree session no longer offers to remove the worktree when another session still uses it, or when it has uncommitted changes. Those worktrees are kept without asking.
- When a worktree can't be removed, the message says so plainly instead of showing git's error.

## [0.4.1] - 2026-09-28

### Fixed

- A session whose shell titles it with a shortened path, like "dev/oss/farol", shows the folder name instead.

## [0.4.0] - 2026-09-28

### Added

- Right-click a terminal for Copy, Paste, Split Right, Split Down, Name Pane and Close. Programs that use the mouse, like vim or htop, still get the click.

## [0.3.0] - 2026-09-28

### Added

- Name a pane with ⇧⌘R or Session → Name Pane. The name shows in the pane's corner, double-click it to rename, and it comes back after a relaunch.

### Fixed

- Text keeps its size when you move the window between a Retina screen and an external monitor.

## [0.2.1] - 2026-09-27

### Changed

- Agent status dots use color from your theme: cyan while working, yellow when waiting for you, green when done. The rest of the window stays monochrome.

## [0.2.0] - 2026-09-27

Settings and the config file now work together, you can add your own themes, and the sidebar shows agent status more clearly.

### Added

- Custom themes: files in `~/.config/farol/themes` show up first in the theme gallery.
- Editing `~/.config/farol/config` applies as soon as you save, and the settings page follows.

### Changed

- Every sidebar row shows a second line with the branch or the folder, so rows line up.
- Agent status is clearer: the dot is hollow when idle, breathes while the agent works, ripples when it waits for you and fills when it is done.
- Agent status glyphs such as Claude Code's ✳ no longer show in session names.
- Settings name the fallback theme Default and explain where the config file lives.

### Fixed

- Changing a setting in the app no longer undoes edits you made to the config file while Farol was open.
- Sessions running Claude Code no longer start a `git` lookup several times a second while its title animates.

## [0.1.2] - 2026-09-27

### Changed

- The DMG opens as a small window with Farol next to Applications, ready to drag.
- Building from source downloads a prebuilt libghostty, so it no longer needs Zig or the Metal toolchain.

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

[Unreleased]: https://github.com/snowztech/farol/compare/v0.13.1...HEAD
[0.13.1]: https://github.com/snowztech/farol/releases/tag/v0.13.1
[0.13.0]: https://github.com/snowztech/farol/releases/tag/v0.13.0
[0.12.0]: https://github.com/snowztech/farol/releases/tag/v0.12.0
[0.11.2]: https://github.com/snowztech/farol/releases/tag/v0.11.2
[0.11.1]: https://github.com/snowztech/farol/releases/tag/v0.11.1
[0.11.0]: https://github.com/snowztech/farol/releases/tag/v0.11.0
[0.10.0]: https://github.com/snowztech/farol/releases/tag/v0.10.0
[0.9.1]: https://github.com/snowztech/farol/releases/tag/v0.9.1
[0.9.0]: https://github.com/snowztech/farol/releases/tag/v0.9.0
[0.8.0]: https://github.com/snowztech/farol/releases/tag/v0.8.0
[0.7.0]: https://github.com/snowztech/farol/releases/tag/v0.7.0
[0.6.0]: https://github.com/snowztech/farol/releases/tag/v0.6.0
[0.5.0]: https://github.com/snowztech/farol/releases/tag/v0.5.0
[0.4.1]: https://github.com/snowztech/farol/releases/tag/v0.4.1
[0.4.0]: https://github.com/snowztech/farol/releases/tag/v0.4.0
[0.3.0]: https://github.com/snowztech/farol/releases/tag/v0.3.0
[0.2.1]: https://github.com/snowztech/farol/releases/tag/v0.2.1
[0.2.0]: https://github.com/snowztech/farol/releases/tag/v0.2.0
[0.1.2]: https://github.com/snowztech/farol/releases/tag/v0.1.2
[0.1.1]: https://github.com/snowztech/farol/releases/tag/v0.1.1
[0.1.0]: https://github.com/snowztech/farol/releases/tag/v0.1.0
