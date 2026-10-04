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
- [x] Agent status in the menu bar: a lamp with the most urgent state across sessions, and a menu to jump to any of them, so you see agents working from any app
- [x] Agent status around the notch, as another option next to the menu bar
- [x] Farol themes in the colors of the app icons, with Farol Beam as the default
- [ ] Install updates in place (Sparkle), behind the same button
- [ ] Homebrew cask

## Next: review

Most of the time with parallel agents goes into checking what they did. That work belongs in Farol.

- [x] Files panel: the session's folder as a tree, next to the terminal
- [x] A light editor for the files you open there, with save and a reload when an agent changes the file
- [x] Syntax colors in the file pane and the review, from the terminal theme
- [x] Review panel: the session's changes as one scrolling diff, per file, with the count in the title bar. Uncommitted work or everything since the branch left main
- [x] Push the branch and open a merge request or pull request from the session
- [ ] Pipeline status and open review comments in the sidebar, with a notification when a pipeline fails
- [ ] Send review comments or a failed job's log back to the agent in one action

## Then: integrations

Work comes from a ticket and goes out as a merge request, on the services teams already use, hosted or self-hosted.

- [x] Settings → Integrations shows whether `gh`, `glab` and jira-cli are set up, and for which account
- [x] Reuse the `gh`, `glab` and jira-cli logins when they exist
- [x] Start a New task from a Jira ticket or a GitHub issue: branch named after the ticket, ticket text as the first prompt
- [ ] Start a New task from a GitLab issue
- [ ] A server field for self-hosted instances, and a token stored in the macOS Keychain for when the tools aren't installed
- [ ] A board's tickets on Jira Data Center, which only Jira Cloud answers today
- [ ] The Jira ticket moved to In Progress when its task starts
- [ ] The session shows its ticket and links to it
- [ ] MCP config written into the worktree, so the agent can read and update the ticket and the merge request

Everything talks to your servers directly. Nothing goes through a Farol service.

## After that: agents that know Farol

An agent running in Farol can change Farol when you ask, so you stay in the conversation.

- [x] A skill for Claude Code and Codex, installed with Connect, that tells the agent where the config is and what it can change
- [x] Config errors shown in Farol, when the file is saved and in Settings
- [ ] A `settings` file for Farol's own preferences and shortcuts, next to `config`, which stays libghostty's. One table in `FarolCore` defines every setting, and the settings page, the menu, the errors and the skill all read from it. Worth doing once the preferences outgrow a handful, or someone asks to rebind Farol's shortcuts
- [ ] `farol sessions`: the sessions with their branch, folder and status, so an agent can tell which one is waiting
- [ ] `farol task`: a task started in a new worktree session from the command line, so one agent can hand work to another
- [ ] The `farol` command working from Codex, which runs its commands without Farol's environment

## Speed and upkeep

Speed is the first rule, and every git feature adds calls. These keep the window quick as they pile up, and make changes safer to make.

- [ ] One git call for a session's state. `git status --porcelain=v2 --branch` gives the branch, what is left to push, and the changed and untracked files together. Today a refresh runs about a dozen git commands one after another, and each session runs a few more at every prompt
- [ ] One refresh per event. Opening a commit with the review panel closed starts two
- [ ] The review panel's state in `FarolCore`, where it has tests. It lives in the window code today, so its scope and refresh order are checked by hand
- [ ] Timing for git refreshes: each one logs how long it took, so a slow one can be found and measured

## Hardening

- [ ] Checksum for the prebuilt libghostty, checked before every release
- [ ] Signing secrets in a GitHub environment that only release tags can use
- [ ] A checksum published next to the DMG

## Later

- Linear as a ticket source
- Command palette

## Not planned

- A full IDE. Big changes belong in your own editor.
- A chat interface or an agent built into Farol.
- Plugins, until the core is stable.
- Linux and Windows. Farol is a native macOS app.
