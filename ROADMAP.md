# Roadmap

The goal: an agentic terminal that is easy to use. You start a task, an agent works on it in its own branch, and you review and ship the result without leaving the window.

Three rules decide what gets in:

- **Speed first.** No feature may add input latency or slow down startup. Hidden sessions never render.
- **Terminal first.** Agents are command line tools. Farol hosts them and gives them context. It does not wrap them in a chat UI or become an agent itself.
- **Quiet UI.** Every control earns its place. A feature you have not set up stays out of sight.

Milestones are themes, not version numbers. Releases ship whatever is ready.

## Done

- Terminal engine: libghostty embedded through `GhosttyTerminal`
- Session sidebar with branches, rename and drag to reorder, restored after a relaunch
- Split panes with names, find in scrollback, copy and paste, dead keys and input methods
- Right-click menu: copy, paste, split, name and close a pane
- Worktree sessions, and closing one offers to remove the worktree when that is safe
- Agent status: `farol status`, one-click Claude Code and Codex setup, colored dots, notifications and a Dock badge
- New sessions can start Claude Code, Codex or any command
- Settings page and `~/.config/farol/config` kept in sync, custom themes
- Signed and notarized DMG on GitHub Releases, landing page, CI and a prebuilt libghostty

## Now: easy to start

Someone who downloads Farol understands what it is for in the first minute.

- [x] **New task**: one flow that picks the repo, takes a task description, creates the worktree and starts the agent with the task as its first prompt
- [x] Codex notifications through its terminal notifications, since its hooks lose track of the terminal
- [ ] A working dot for Codex, once its hooks know which terminal they belong to
- [x] Sessions grouped by project in the sidebar, as a setting
- [x] Update check: a quiet Update button when a new version is out
- [ ] Agent status in the menu bar: a lamp with the most urgent state across sessions, and a menu to jump to any of them, so you see agents working from any app
- [ ] Install updates in place (Sparkle), behind the same button
- [ ] Homebrew cask

## Next: review

Most of the time with parallel agents goes into checking what they did. That work belongs in Farol.

- [x] Files panel: the session's folder as a tree, next to the terminal
- [x] A light editor for the files you open there, with save and a reload when an agent changes the file
- [x] Syntax colors in the file pane and the review, from the terminal theme
- [x] Review panel: the session's changes as one scrolling diff, per file, with the count in the title bar. Uncommitted work or everything since the branch left main
- [ ] Push the branch and open a merge request or pull request from the session
- [ ] Pipeline status and open review comments in the sidebar, with a notification when a pipeline fails
- [ ] Send review comments or a failed job's log back to the agent in one action

## Then: integrations

Work comes from a ticket and goes out as a merge request, on the services teams already use, hosted or self-hosted.

- [ ] Settings → Integrations for GitLab, GitHub and Jira, with a server field for self-hosted instances
- [ ] Reuse `glab` and `gh` logins when they exist, otherwise a token stored in the macOS Keychain
- [ ] Jira Cloud and Jira Data Center, detected from the URL
- [ ] Start a New task from a Jira ticket: branch named after the ticket, ticket text as the first prompt, ticket moved to In Progress
- [ ] The session shows its ticket and links to it
- [ ] MCP config written into the worktree, so the agent can read and update the ticket and the merge request

Everything talks to your servers directly. Nothing goes through a Farol service.

## Hardening

- [ ] Checksum for the prebuilt libghostty, checked before every release
- [ ] Signing secrets in a GitHub environment that only release tags can use
- [ ] A checksum published next to the DMG

## Later

- Linear and GitHub Issues as ticket sources
- Command palette
- Agent status in the notch, as another style of the menu bar item

## Not planned

- A full IDE. Big changes belong in your own editor.
- A chat interface or an agent built into Farol.
- Plugins, until the core is stable.
- Linux and Windows. Farol is a native macOS app.
