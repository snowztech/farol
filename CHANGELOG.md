# Changelog

Notable changes to Farol. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Sessions in worktrees have a quiet cue in the sidebar and session picker. Drag the sidebar edge to change its width.
- New Task can add Git repositories from anywhere on the Mac, alongside nearby repositories, without changing the current session.
- Save a Run command for all projects in `~/.farol/commands/`. Global commands run in the active pane's folder. Project commands take priority when names match.

## [0.46.0] - 2026-10-20

Run a project's own commands from a pane, or save your own commands in the checkout.

### Added

- ⌘P finds the commands your project defines, in its Makefile, package.json or justfile, as you type, like `make test` or `npm run dev`. Return runs one in the pane you are in, or in a new pane below when an agent is working there. Nothing to set up or save: it reads the project's own files, so it works in every worktree and stays current.
- ⌥⌘K opens the focused pane's Run menu for those project commands.
- The pane's Run menu can save a named shell command as an editable script in the checkout's `.farol/commands/` folder. Saved commands also appear in ⌘P.

### Fixed

- A pane keeps its Stop button while a command starts, finds Play when the shell reports its folder after you hover, and keeps checking for a running command's ports.

## [0.45.0] - 2026-10-19

Find text in the files under the pane you are in, with ⇧⌘F.

### Added

- Find in Files, in the Edit menu, with ⇧⌘F or with the magnifier at the top of the files panel: the files panel lists every line with the text you type, in the files under the folder of the pane you are in. A checkout skips what git ignores. Buttons in the field match case, whole words or a regular expression, and a second field keeps or leaves out files, like `*.swift, !*Tests*`. Below a repo's top, it can search the whole repo instead. Return or a click opens the file at that line with every match marked, and F4 and ⇧F4 go to the next and previous result from the file. The search stays when you go back to the tree, starts from the text you selected, and runs again when files change under it.
- Drag the files panel's edge to make it wider. Farol keeps the width.

### Changed

- A file opened at a line, from Find in Files, a path in the terminal or the review panel, lights that line until you move the cursor away.

## [0.44.0] - 2026-10-19

Answer Claude Code's questions from anywhere: the notification, the status panel or your phone.

### Added

- Claude Code's questions can be answered from the notification, with buttons for a question with a few options. In the session you are looking at, Claude asks in its terminal as usual. Choose Chat About This to turn a question down and talk it over with Claude, or Answer in Terminal to answer there as before. If you connected Claude Code before, Settings → Agents shows Needs update: click Update to add the hook for it.
- With the status panel on, hover it while an agent waits to see its question with the options as buttons, at the notch or on the screen edge, so you can answer from any app. It never opens by itself, and it takes the keyboard only once you click into it. Clicking away closes it, and the question waits for the next hover, in its notification and in its session.
- The notification for a waiting agent shows its question and the answers it offers, or the tool it asks to run and what for.
- Remote: a reply typed on the phone answers a question Farol holds for Claude Code, like tapping one of its answers.

### Changed

- Settings → Remote no longer has its own Connect buttons for agents. The phone shows the agents connected in Settings → Agents.

## [0.43.1] - 2026-10-19

A session shows only the ports you would open, and the Farol menu lines up on macOS 26.

### Changed

- On macOS 26, Check for Updates, Settings and Reload Configuration in the Farol menu have icons, like About and Quit.

### Fixed

- Sidebar: a session's ports leave out the ones agents like Codex and Claude Code open for their own use, so only servers you would open show, like `:3000`.

## [0.43.0] - 2026-10-18

Farol updates itself.

### Changed

- Farol installs its own updates. The Update button in the title bar, or Check for Updates in the Farol menu, downloads the new version, checks its signature and relaunches Farol on it, and your sessions and agents come back. This release still has to be installed the old way once.

### Fixed

- Agents: a Claude Code turn that ends on an API error, like a usage limit, shows as done instead of staying "Working". Settings → Agents asks to update Claude Code once, to add the hook for it.
- Remote: the phone shows the conversation of an interactive Codex session, found in Codex's logs, including one resumed when Farol opens.
- Remote: a message you send while Claude Code works shows in its conversation on the phone.

## [0.42.0] - 2026-10-18

Files an agent names open at their line, and each session shows its ports and what its agent waits for.

### Added

- Sidebar: a session shows the ports its programs listen on after its branch, like `:3000` for a dev server an agent started. Click one to open it in your browser. They are read at a prompt, when an agent finishes and when you switch sessions, never on a timer.
- Sidebar: while an agent waits, its row says what for, like the question it asks or the command it wants to run.

### Changed

- ⌘-clicking a file path in the terminal opens it next to the terminal, at the line when it says one, like `src/app.ts:42` from an agent. Paths with a line number used to open nothing, and the others opened in another app.

## [0.41.0] - 2026-10-18

Agents pick up where they left off when Farol opens.

### Added

- Agents: Claude Code and Codex conversations come back when Farol opens, each in the pane it ran in, on the same account. An agent you exited before quitting stays closed. Turn it off in Settings → Agents → When Farol opens.

### Changed

- Settings → Agents shows each agent's mark and where its command is installed. A connected agent shows as a pill, and clicking it asks to disconnect.
- Agents: the Farol skill for Claude Code and Codex knows the Worktrees and Remote settings, how other agents report their status, and the newer shortcuts. It updates itself at the next launch.

## [0.40.1] - 2026-10-17

Stopping an agent, or answering it from the phone, no longer leaves its session working or waiting.

### Fixed

- A session no longer stays "Working" after you stop Claude Code with Esc or Control-C, here or from the phone. Claude Code runs no hook when it is stopped, so Farol now reads the stop from its log.
- Remote: a phone that forgets this Mac is removed here too, and is no longer notified or sent Live Activity updates.
- Remote: a session no longer stays "Waiting for you" after you answer an agent from the phone. Claude Code and Codex ring when they wait or finish, and that ring counted until you looked at the session on the Mac.

## [0.40.0] - 2026-10-17

The phone knows this Mac by its name.

### Added

- Remote: the phone lists this Mac by its name, next to any other Mac or server paired with it, and knows everything this Mac can do.

## [0.39.1] - 2026-10-16

An agent's conversation on the phone from the moment it starts, and replies that are always sent.

### Fixed

- Remote: a Claude Code or Codex session shows as its conversation on the phone from the moment the agent starts, instead of staying on the terminal until its first turn. Update the agent's hooks in Settings to get this.
- Remote: a reply from the phone with several lines or pictures is sent, where it could stay in the agent's prompt unsent. Return now waits for the agent to take the paste in.

## [0.39.0] - 2026-10-16

Slash commands and pictures from the phone.

### Added

- Remote: typing `/` on the phone lists what the agent takes: its own commands, your skills and commands, the project's, and those of your plugins that are on. In Codex, `$` lists its skills. A command that opens a picker, like `/model`, shows the terminal once sent.
- Remote: attach photos and screenshots to a reply from the phone, for the agent to look at. The Mac takes only images, keeps them in a folder only you can read, and removes them after a week.

### Fixed

- Remote: a Codex session shows as its conversation on the phone as soon as Codex names its log, instead of staying on the terminal until the phone asked again.

## [0.38.0] - 2026-10-16

Answer your agents from the phone with a tap, and a terminal there that keeps up.

### Added

- Remote: a waiting agent's question or permission prompt shows on the phone as it was asked, with its answers as buttons. An answer goes to the pane that asked, and only while it still asks, so a late tap never lands in the next prompt.
- Remote: Settings → Remote asks to update or connect Claude Code and Codex when their hooks are missing or from an older Farol, since the phone needs them to show what an agent asks.
- Remote: the terminal on the phone updates several times a second while it is open, and takes Control letters like Control-D or Control-R.

### Removed

- Remote: scrolling a session's terminal from the phone. The phone reads the agent's conversation instead.

## [0.37.0] - 2026-10-16

Read an agent's whole conversation from the phone, from its first message.

### Added

- Remote: the phone shows a Claude Code or Codex session as a conversation, read from the agent's own log: your messages, its answers and the tools it ran, from the very first message. The terminal is still one tap away.

## [0.36.1] - 2026-10-16

### Fixed

- Remote: scrolling back from the phone no longer types arrow keys into a full-screen program that does not read the mouse, which in Claude Code walked through the prompt history. Such a program now says it does not scroll from the phone.

## [0.36.0] - 2026-10-16

Read more from the phone: an agent's earlier output, and what it changed.

### Added

- Remote: scroll a session back from the phone, so the earlier output of a full-screen agent like Claude Code or Codex can be read there.
- Remote: see what changed in a session's repository from the phone, file by file with each diff, compared as the review panel does.

## [0.35.0] - 2026-10-16

More of the Mac from the phone: close a session, and switch Claude Code's mode.

### Added

- Remote: close a session from the phone. Farol keeps its last session open, since closing it would quit Farol and cut the phone off.
- Remote: press Shift-Tab from the phone, to switch Claude Code between its normal, auto-accept and plan modes.

## [0.34.0] - 2026-10-16

Your agents in your pocket: Remote, in beta, with Farol for iPhone.

### Added

- Remote, in beta: answer your agents from your phone. Turn it on in Settings → Remote, scan the code with Farol for iPhone (on TestFlight for now), and the phone lists your sessions, shows a session's screen, types your replies and tells you when an agent waits or finishes. Everything between the Mac and the phone is encrypted end to end.
- Remote: a Live Activity on the iPhone's lock screen and in the Dynamic Island: how many agents wait and work, and which. The Mac starts it when an agent gets busy and keeps it up to date while the app is closed. Apple and the relay see only the two counts.
- Remote: open a new session from the phone, in a project that already has one open or in the home folder, as a plain shell or with Claude Code or Codex running.
- Remote: an option to keep the Mac awake while an agent works or waits for you, so the phone can still reach it. Closing the lid still puts the Mac to sleep.

## [0.33.0] - 2026-10-15

A snappier window, fewer calls to GitHub, and an inspector to keep it that way.

### Added

- The Farol Inspector, in the View menu or with ⌥⌘I: the programs Farol starts, freezes, memory and CPU, with a report to copy into a bug report.

### Fixed

- The window no longer waits on git when the graph follows a repo or New Task opens.
- The review panel asks GitHub about a branch's pull request once where it asked up to four times.

## [0.32.1] - 2026-10-15

GitLab catches up with GitHub: comments on a merge request's lines, approvals, issues in New Task, and forges on a company's own domain.

### Added

- A GitHub or GitLab on your company's own domain is recognized once gh or glab is logged in there, so its requests, reviews and checks show.
- New Task lists a GitLab repo's open issues, as it does GitHub's.
- On GitLab too, the "+" next to a line of a merge request's diff writes a comment on it.
- A GitLab merge request's conversation shows who approved it or requested changes.

### Fixed

- A comment on an older version of a GitLab merge request's diff stays in the conversation instead of showing under a line that moved.

## [0.32.0] - 2026-10-15

A task can now span several repos, each with its own worktree on one branch, reviewed repo by repo.

### Added

- New Task works across several repos. Start it from a folder of repos, tick the ones the task touches, and each gets a worktree on the same branch in one folder, where the agent starts. Closing the session offers to remove them all and keeps every branch.
- Started from inside a repo, New Task offers Add repos to pick the repos beside it.
- The repo list gets a search past 8 repos, and shows the branch a repo is on when it isn't main or master, since the task branch starts from it.
- In a task across repos, the review and graph panels show a tab per repo with its changes, and the title bar counts the changes of all of them.

## [0.31.0] - 2026-10-15

Pull requests open in the review panel, comments and all, and Markdown files preview in the file pane.

### Added

- A preview for Markdown files in the file pane: headings, lists, tasks, code, quotes, tables and links. The eye in its header switches between the source and the preview, Farol keeps your choice, and the preview follows an agent's edits. A link to another file opens it in the pane.
- A pull request's button in the git graph shows its changes in the review panel, anyone's request, without checking it out. Right click it for its page in the browser.
- Above a pull request's changes, its description and comments, reviews and comments on lines included, each folded to its first line. A comment on a line takes you to its file.
- A pull request's comments on lines show under those lines in its diff. On GitHub, the "+" next to a line number writes a new one.

### Fixed

- A working agent no longer makes Farol run git after each of its steps, only when its turn ends or it stops to ask you something.

## [0.30.10] - 2026-10-15

New Task shows the ticket before you start.

### Changed

- New Task shows the picked ticket's text before you start, and sends its link along so the agent can read the comments.
- A task no longer fills the terminal and your shell history. The agent gets it from `$FAROL_TASK`.

## [0.30.9] - 2026-10-14

Closing a session stops what runs in it.

### Fixed

- Closing a session or a pane ends its shell and frees its memory. Closed sessions used to keep running in the background, with their programs, until Farol quit.

## [0.30.8] - 2026-10-14

Farol uses much less memory with many sessions open.

### Fixed

- Sessions in the background no longer hold a full window of graphics memory each, so Farol uses much less memory with many sessions open.

## [0.30.7] - 2026-10-13

Open a folder in Farol from Finder or another app.

### Fixed

- Opening a folder from Finder or `open -a Farol <folder>` starts a session in that folder.

## [0.30.6] - 2026-10-08

Over ssh, Farol keeps showing the host and stops showing the repo on your Mac.

### Added

- About Farol in the Farol menu, which opens the About page in settings.

### Changed

- Over ssh, the files, review and git graph panels are empty, where they used to show the repo on your Mac.

### Fixed

- Over ssh, a session still shows the host when a program like vim or an agent sets its own title, under the program's name.

## [0.30.5] - 2026-10-08

A session over ssh says which machine you are on.

### Changed

- Over ssh, a session is named after the host and shows the remote folder, not the local folder and branch.

## [0.30.4] - 2026-10-07

Searching with ⌘P finds the right file sooner, and Return always takes you somewhere.

### Changed

- Searching with ⌘P lists the files and folders whose name starts with what you typed first.
- Searching with ⌘P starts on the first match that is not the session you are in, so Return always takes you somewhere.
- The ⌘P list is wider, and a folder's "New session" hint shows the Return key.
- Outside a git repo, ⌘P no longer lists what is inside `node_modules`, `Pods`, `DerivedData` and `__pycache__`.

### Fixed

- In the ⌘P list, a session with a long name no longer shows its branch and its shortcut as "…".

## [0.30.3] - 2026-10-07

Commits and pushes work in repos whose git hooks need pnpm or npx.

### Fixed

- Committing and pushing work in a repo whose git hooks call tools like pnpm or npx, when Farol was opened from the Dock or the Finder. Before, the hook could not find the tool and the commit failed.

## [0.30.2] - 2026-10-07

Install with Homebrew, and git can no longer hang a panel or freeze the new task sheet.

### Added

- Farol installs with Homebrew: `brew install --cask snowztech/tap/farol`.

### Fixed

- A git command that prints a lot of warnings or progress no longer hangs the panel waiting on it, like the review panel or the git graph.
- New Task and New Worktree Session no longer freeze the window on a slow repository. Pressing the shortcut again while one is open no longer queues a second sheet behind it.
- A session's branch in the sidebar stays right when prompts come faster than git answers.

## [0.30.1] - 2026-10-06

Reach the pane menu in Claude Code and vim, and the settings page works with a repeated key.

### Fixed

- Shift-right-click opens the pane's menu even when the program in the terminal uses the mouse, like Claude Code or vim. Before, the click went to the program and there was no way to name or close the pane from the menu.
- A setting changed on the settings page applies when `~/.config/farol/config` has the same key on more than one line. Before, the page changed the first line while the terminal read the last, so nothing happened. The page now keeps one line per key it writes, except `font-family`, where later lines are fallback fonts and stay.

## [0.30.0] - 2026-10-04

Find files and folders from the session switcher, and ask your agent to change Farol's settings.

### Added

- A key or a value Farol cannot read in the config file is reported when you save, and listed in Settings → Terminal until it is fixed. Before, it was ignored in silence.
- Connecting Claude Code or Codex also adds a skill that tells the agent how Farol is configured, so you can ask it to change the theme, the font or any other terminal setting. Already connected? Farol adds it the next time it opens.
- The session switcher (⌘P) also finds files and folders. Type part of a name or a path and what matches is listed under the sessions. Return opens a file in the file pane, and a folder as a new session. In a git repo the whole checkout is searched, without what git ignores. Anywhere else it is the folder you are in, three levels deep.
- The session switcher (⌘P) also matches the folder a session is in, so a session outside a git repo can be found by its path.

### Fixed

- A session keeps its folder or project name while a command runs. Before, it took the name of the command, so running `make test` renamed the session "make test". Programs that set a title of their own, like Claude Code or vim, still name the session until they exit.
- A change written into `~/.config/farol/config` in place, as `cp`, `>>` and some agents do, applies right away. Before, only a save that replaced the file did.
- Closing the terminal next to an open file no longer crashes Farol. A click on the file pane's header or line numbers also selects it, so ⌘W closes the file.

## [0.29.0] - 2026-10-04

Walk the git graph with the arrow keys, and each branch keeps its own color.

### Added

- With a commit selected in the history, the up and down arrows move to the next one and Return opens its changes.

### Fixed

- In a narrow git graph the commit subject stays readable: the author goes first, then the hash, and the row is no longer cut at both ends.
- A branch started from another one's last commit gets its own color in the history, instead of taking the color of the branch it started from. main is always blue.

## [0.28.0] - 2026-10-03

Let Claude Code or Codex write the commit message.

### Added

- The commit sheet can have Claude Code or Codex write the message from the files you ticked. The arrow next to the button picks the agent or account, and Restore puts back what you had typed.

### Changed

- Branches, change counts and shortcuts are set in a monospaced font, so what comes from git or the keyboard reads apart from names.
- Buttons dim while pressed and hovers ease in. The selected settings section is filled like a selected session.
- Switches that are on are brighter, and the "Connected" dots in settings take your theme's green and yellow.
- New task and Open config file are real buttons, so VoiceOver can reach them.
- In the title bar's git pill, the half whose panel is open is brighter than a hovered one, and the graph icon is the size of the gear.

### Fixed

- The change counts in the title bar no longer wait for what only the review panel needs, so they show sooner after you switch sessions.
- A commit opened from the git graph shows its diff sooner. The panel used to read your own counts and push state first.

## [0.27.0] - 2026-10-02

Merge branches, and see pull requests and their checks.

### Added

- Right-click a branch to merge it into the checked out one, with a fast-forward when git can or always with a merge commit.
- A branch with an open pull request, or merge request, shows its number next to it in the branch list. Click it to open the request in the browser. Needs gh or glab.
- A pull request's checks show before its button in the review panel, or a merge request's pipeline jobs: green, red, or a clock while they run. Click for the list, and a step to open its log. Needs gh or glab.

### Fixed

- "Review changes" in the title bar, while the panel shows a commit, brings your changes back. It used to close the panel. The counts next to it stay those of your changes.

## [0.26.1] - 2026-10-02

Push from the review panel after a commit.

### Added

- After a commit that wasn't pushed, the Commit button in the review panel becomes Push, until there is something new to commit. ⌥⌘P pushes too, and both buttons show their shortcut.

## [0.26.0] - 2026-10-02

Choose which files go in a commit.

### Added

- Each file with uncommitted changes has a tick in the review panel and in the commit sheet. Untick one and it stays out of the next commit, uncommitted in your working tree. ⌥⌘C opens the commit sheet from anywhere in the session.

## [0.25.0] - 2026-10-02

Resolve merge conflicts in Farol, in three columns.

### Added

- When a merge, rebase, cherry-pick or revert stops on conflicts, the title bar says how many, and ⌥⌘M opens them in three columns: your version, the result and the incoming one. Each change has an arrow to take it and a cross to leave it out. Changes only one side made are taken from the start and folded away, and the result can be edited by hand. Mark each file resolved, then continue, skip or abort from the same place.
- A session stopped on conflicts is marked in the sidebar, the menu bar and the notch, and sends a notification. While resolving, a row shows the rebase's commits, files git's rerere already resolved like last time can be used as they are, and a resolved file can be reopened until you continue. Continuing a merge, cherry-pick or revert asks for the commit message, and a rebase can edit the message of the commit it replays.
- In the conflict view, the words that changed inside a line are highlighted, switching files keeps your decisions and undo history, and Ignore Whitespace settles conflicts that differ only in spacing. A file already edited in the terminal or by an agent is flagged, with a choice to use it as it is or start from git's versions. Symlinks, submodules, file modes, renames and `git am` are handled too.
- Conflicts can be resolved from the keyboard: ⌥↓ and ⌥↑ move between the changes left to decide, ⌃⌘← and ⌃⌘→ take your side or the incoming one for the whole file, ⌘S marks the file resolved and ⌘↩ continues. Settings → Shortcuts lists them. Run Tests runs the checkout's test command in a pane under the terminal before you continue.

### Changed

- The website now includes a short video tour of Farol.
- The website now has documentation for setup, everyday workflows and shortcuts.

## [0.24.1] - 2026-10-01

No more panels that grow or jump a moment after they open.

### Fixed

- The session list under the window title no longer leaves an empty gap at its end when sessions are grouped by project.
- New Task no longer grows a few seconds after it opens. The ticket select is there from the start, grayed out while your tickets load the first time, and with last time's list after that.
- Settings → Integrations no longer drops the Jira board row in a few seconds after the page opens. It is there from the start, grayed out until jira-cli answers.

## [0.24.0] - 2026-10-01

Use more than one Claude Code or Codex account.

### Added

- Connect and start more than one Claude Code or Codex account. Farol finds `~/.claude-*` and `~/.codex-*` folders, lists each one in Settings → Agents, and offers each one in New task and Start with.

## [0.23.0] - 2026-10-01

Switch sessions from the window title, and put the panels in rounded cards.

### Added

- Click the window title or press ⌘P to switch sessions, with a search, even with the sidebar closed. Each session shows its status and branch. The arrow keys move through the list and Return opens the session, and each row shows its ⌘1 to ⌘9 shortcut.
- Settings → Appearance → Style. Boxed puts each panel in a rounded card with a gap around it. Boxed with color also tints the panels with your theme's blue and lights what is selected in it. Classic is how Farol looked before, and stays the default.

## [0.22.0] - 2026-10-01

Farol gets its own themes, one for each app icon.

### Added

- Farol Beam, Farol Dark, Farol Navy and Farol Light, four themes in the colors of the four app icons. They come first in Settings → Appearance.

### Changed

- Farol Beam is the theme until you pick one, and its card says so. When your Ghostty config sets its own colors, those stay the default, under a card named Ghostty config.

### Fixed

- Opened from a Ghostty terminal, Farol used Ghostty's own themes and shell integration rather than the ones it ships with.

## [0.21.1] - 2026-10-01

Keep your chosen cursor style at the shell prompt.

### Fixed

- The cursor style setting now applies at the shell prompt. Shell integration used to force a bar there, whatever you picked. If you use zsh vi mode and want the cursor to follow the mode, add `shell-integration-features = cursor` to the config file.

## [0.21.0] - 2026-10-01

Start tasks from Jira tickets and GitHub issues.

### Added

- Start a task from a ticket. New Task lists your open Jira tickets, through jira-cli, and the open issues of a repo on GitHub, with a search. Picking one names the branch after it and hands the agent the ticket in full, with anything you add.
- Settings → Integrations shows whether jira-cli is set up, and for which account. Each tool there links to its documentation. Choose there between your own tickets and everything open on a team's board.

### Changed

- The agent in New Task is a select, like the ticket above it.

## [0.20.2] - 2026-10-01

A clearer Settings: your connected account at a glance, and buttons that look like buttons.

### Changed

- Settings → Integrations shows the connected account as one pill: its picture with a green dot, and its name. The rows name the tools in full, like the GitHub CLI (gh).
- Buttons in Settings use Farol's own quiet style. The system ones looked switched off in dark themes.

## [0.20.1] - 2026-10-01

Drop files or text straight onto the terminal.

### Added

- Drop files or text on the terminal. Files go in as their paths, so an image dropped on Claude Code's prompt is attached.

## [0.20.0] - 2026-10-01

Fetch, update and push branches from the git graph.

### Added

- A refresh button in the git graph fetches from every remote and drops branches deleted on the server.
- Branches that are behind or ahead of their remote show the count in blue or green. Click it to update or push the branch. Update is also in the branch's right-click menu, grayed out when there is nothing to pull.
- In the history, the line between a branch and its remote is dashed, and the branch's commit shows how far apart they are.
- Hovering a branch highlights the commit it points to. Hovering an author shows their email.

### Changed

- The git graph uses many more colors, so two branches rarely share one.
- The rebase items in the git graph's menus name both branches, like Rebase "feat/x" onto "main", so it is clear which one moves.

## [0.19.0] - 2026-10-01

See in Settings whether GitHub and GitLab are connected.

### Added

- Settings → Integrations shows whether GitHub's `gh` and GitLab's `glab` are installed and which account they are logged in as. Install and Log In open a terminal with the command typed in.
- GitHub's and GitLab's marks on the pull request buttons in the review panel.

### Changed

- In Settings → Agents, the group that connects Claude Code and Codex is now called Status, since Integrations is its own section.

## [0.18.0] - 2026-10-01

Pull requests from the review panel, on GitHub and GitLab.

### Added

- Pull requests on GitHub, and merge requests on GitLab, from the review panel. Once the branch has commits of its own and nothing is left to commit, a button pushes it and opens the forge's new request form in your browser, with the branch filled in. The commit sheet offers the same as a third choice.
- With GitHub's `gh` or GitLab's `glab` installed and logged in, Farol creates the request itself, titled from the commits. The button reads Create PR, and once the branch has an open request it shows as "PR #5", which opens it on click.

### Changed

- Committing from the review panel opens a sheet in Farol's own style. It lists the files that go in, takes a message with a body, and remembers whether you commit, commit and push, or go on to a pull request.
- The New Task sheet matches the commit sheet, in the theme's colors. Start stays off until there is a task and a branch name git accepts.

## [0.17.0] - 2026-10-01

Commit and push straight from the review panel.

### Added

- Commit button in the review panel. When the checkout has uncommitted changes, it asks for a message and commits all of them, staged or not. Commit and Push also pushes the branch, to origin when it has no remote yet.

### Changed

- The git graph icon in the title bar sits bare like the other icons when there are no changes. The pill comes back around it and the counts when there are.

## [0.16.1] - 2026-10-01

The unsaved dot only stays when something is left to save.

### Fixed

- The file editor's unsaved dot goes away when you undo or delete your edits back to what's saved.

## [0.16.0] - 2026-10-01

See what each commit changed, right from the git graph.

### Added

- Click a commit in the git graph to see its files under the history, by folder with their counts. Double-click it, or use the open button in that pane, to see its full diff in the review panel, which gets a "Commit" entry in its compare menu. Clicking a file scrolls the review to it.

### Changed

- Double-clicking a commit in the git graph opens its changes in the review panel instead of checking it out. Check Out stays in its right-click menu.

### Fixed

- Settings → Shortcuts and the README list ⌥⌘G for the git graph.
- Long lines in the review panel scroll sideways instead of being cut at the panel's edge.

## [0.15.0] - 2026-10-01

A git graph for every session.

### Added

- Git graph panel. ⌥⌘G, or the icon next to the review counts, shows the session's commits as a colored graph with the branches listed above it. Click a branch to check it out, or double-click a commit. Right-click to create, rebase or delete a branch, to cherry-pick or revert a commit, or to copy a branch name, commit hash or commit title.
- Rebase the current branch onto any commit or branch from the graph, or start an interactive rebase from there. If git stops on a conflict, the terminal shows how to go on.

## [0.14.0] - 2026-09-30

Worktrees that run like the project they came from, and reliable status for Codex sessions.

### Changed

- The menu bar lighthouse keeps subtle beams while idle, then lights them in the agent status color when activity starts.

### Added

- New worktrees copy ignored `.env` files by default, so tasks can build and run with the project's local environment. This can be turned off in Settings → Worktrees.

### Fixed

- Codex sessions now show working, waiting and done dots like Claude Code. Farol follows the interactive TUI's terminal titles live, while lifecycle hooks cover non-interactive runs and background agents. Settings → Agents → Update replaces the old terminal-notification workaround. Restart open Codex sessions and trust the new hooks with `/hooks`.

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

[Unreleased]: https://github.com/snowztech/farol/compare/v0.33.0...HEAD
[0.33.0]: https://github.com/snowztech/farol/releases/tag/v0.33.0
[0.32.1]: https://github.com/snowztech/farol/releases/tag/v0.32.1
[0.32.0]: https://github.com/snowztech/farol/releases/tag/v0.32.0
[0.31.0]: https://github.com/snowztech/farol/releases/tag/v0.31.0
[0.30.10]: https://github.com/snowztech/farol/releases/tag/v0.30.10
[0.30.9]: https://github.com/snowztech/farol/releases/tag/v0.30.9
[0.30.8]: https://github.com/snowztech/farol/releases/tag/v0.30.8
[0.30.7]: https://github.com/snowztech/farol/releases/tag/v0.30.7
[0.30.6]: https://github.com/snowztech/farol/releases/tag/v0.30.6
[0.30.5]: https://github.com/snowztech/farol/releases/tag/v0.30.5
[0.30.4]: https://github.com/snowztech/farol/releases/tag/v0.30.4
[0.30.3]: https://github.com/snowztech/farol/releases/tag/v0.30.3
[0.30.2]: https://github.com/snowztech/farol/releases/tag/v0.30.2
[0.30.1]: https://github.com/snowztech/farol/releases/tag/v0.30.1
[0.30.0]: https://github.com/snowztech/farol/releases/tag/v0.30.0
[0.29.0]: https://github.com/snowztech/farol/releases/tag/v0.29.0
[0.28.0]: https://github.com/snowztech/farol/releases/tag/v0.28.0
[0.27.0]: https://github.com/snowztech/farol/releases/tag/v0.27.0
[0.26.1]: https://github.com/snowztech/farol/releases/tag/v0.26.1
[0.26.0]: https://github.com/snowztech/farol/releases/tag/v0.26.0
[0.25.0]: https://github.com/snowztech/farol/releases/tag/v0.25.0
[0.24.1]: https://github.com/snowztech/farol/releases/tag/v0.24.1
[0.24.0]: https://github.com/snowztech/farol/releases/tag/v0.24.0
[0.23.0]: https://github.com/snowztech/farol/releases/tag/v0.23.0
[0.22.0]: https://github.com/snowztech/farol/releases/tag/v0.22.0
[0.21.1]: https://github.com/snowztech/farol/releases/tag/v0.21.1
[0.21.0]: https://github.com/snowztech/farol/releases/tag/v0.21.0
[0.20.2]: https://github.com/snowztech/farol/releases/tag/v0.20.2
[0.20.1]: https://github.com/snowztech/farol/releases/tag/v0.20.1
[0.20.0]: https://github.com/snowztech/farol/releases/tag/v0.20.0
[0.19.0]: https://github.com/snowztech/farol/releases/tag/v0.19.0
[0.18.0]: https://github.com/snowztech/farol/releases/tag/v0.18.0
[0.17.0]: https://github.com/snowztech/farol/releases/tag/v0.17.0
[0.16.1]: https://github.com/snowztech/farol/releases/tag/v0.16.1
[0.16.0]: https://github.com/snowztech/farol/releases/tag/v0.16.0
[0.15.0]: https://github.com/snowztech/farol/releases/tag/v0.15.0
[0.14.0]: https://github.com/snowztech/farol/releases/tag/v0.14.0
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
