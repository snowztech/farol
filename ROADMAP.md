# Roadmap

The goal: a terminal where you run several coding agents side by side, each on its own branch, started from a ticket and reviewed without leaving the window.

Three rules decide what gets in:

- **Speed first.** No feature may add input latency or slow down startup. Hidden sessions never render.
- **Terminal first.** Agents are command line tools. Farol hosts them and gives them context. It does not wrap them in a chat UI or become an agent itself.
- **Quiet UI.** Every control earns its place. When in doubt, it goes behind a shortcut.

## Done

- Terminal engine: libghostty embedded through `GhosttyTerminal`
- Session sidebar, shortcuts, closing the last session quits
- Attention light when a session rings the bell or sends a notification
- Themes with live previews, chrome that follows the theme
- In-window settings and `~/.config/farol/config`
- App icon, `make install`, style check in CI

## v0.1: daily driver

Farol can replace Ghostty or Warp for everyday work, and sessions start to be about branches.

- [x] Copy and paste
- [x] Dead keys and input methods (accents, CJK)
- [ ] Restore sessions on relaunch, same folders and titles
- [ ] Worktree sessions: "New session in repo" creates a branch and a git worktree, and opens the terminal there
- [ ] Sidebar shows the repo and branch of each session
- [ ] Closing a worktree session offers to remove the worktree
- [ ] Release: signed and notarized build on GitHub Releases, Homebrew cask

Worktree logic goes in a new `FarolCore` module with tests, since it is the first code that can lose work if it is wrong.

## v0.2: agents

Farol knows what each agent is doing, not just that it rang the bell.

- [ ] `farol` command line tool that talks to the app over a local socket, for example `farol status waiting`
- [ ] Ready-made hooks for Claude Code and Codex that report running, waiting and done
- [ ] Default agent in settings, so a new session can start `claude` or `codex` directly
- [ ] macOS notification and Dock badge when an agent waits while Farol is in the background
- [ ] Sessions grouped by repo in the sidebar

## v0.3: tickets

Start work from the ticket instead of copying it into a prompt.

- [ ] Ticket picker for GitHub issues, GitLab issues and Jira
- [ ] Branch named from the ticket, ticket text sent as the first prompt
- [ ] Tokens stored in the macOS Keychain
- [ ] MCP config written into the worktree, so the agent can read comments and update the ticket
- [ ] Session shows its ticket and links to it

## v0.4: review

Check what an agent did and ship it from the same window.

- [ ] Diff view of a session against its base branch
- [ ] Light editor for small fixes: open a file, syntax highlighting with tree-sitter, save
- [ ] Push the branch and open a pull or merge request from the session

## Later

- Command palette
- Split panes
- Search in the terminal scrollback
- Language server support in the editor

## Not planned

- A full IDE. The editor stays small, and big changes belong in your own editor.
- A chat interface or an agent built into Farol.
- Plugins, until the core is stable.
- Linux and Windows. Farol is a native macOS app.
