import Foundation

/// A skill that tells the agent how Farol is configured. Claude Code, Codex, OpenCode and Pi read the same format.
/// The agent loads only its description until someone asks about Farol, so it costs almost no context.
public struct AgentSkill {
    public let file: URL

    public init(nextTo settings: URL) {
        file = settings.deletingLastPathComponent().appendingPathComponent("skills/farol/SKILL.md")
    }

    /// False when the file is missing or was written by another version of Farol.
    public var isCurrent: Bool {
        (try? String(contentsOf: file, encoding: .utf8)) == Self.text
    }

    public func install() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.text.write(to: file, atomically: true, encoding: .utf8)
    }

    public func remove() throws {
        let folder = file.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    static let text = """
    ---
    name: farol
    description: Farol terminal settings and sessions. Use when the user asks to change a terminal setting such as the theme, the font or a shortcut, to add a theme, where a Farol setting lives, or how Farol works, like tasks, worktrees, agent status, review or answering agents from the phone. Also use to see Farol's other sessions, to hand part of the work to another agent in its own worktree, to message another agent, or to wait for one.
    ---

    # Farol

    Farol is a macOS terminal for coding agents, built on libghostty. Its docs at https://farol.sh/docs and its README at https://github.com/snowztech/farol#readme cover what this file leaves out, like the phone app and running agents on a server. Read them when the user asks for that.

    ## Settings

    Terminal settings are lines of Ghostty config in `~/.config/farol/config`:

    ```
    theme = Farol Dark
    font-size = 14
    ```

    Every terminal option at https://ghostty.org/docs/config works: fonts, colors, cursor, padding, scrollback, keybinds. Options for Ghostty's own window, tabs and quick terminal do nothing, since Farol draws its own window.

    Farol watches the file, so a saved edit is live in every session, with no restart. Farol shows the user an error for a key or value it cannot read. You will not see that error, so take both from the docs. Deleting a line brings back the value from the user's Ghostty config, or the default.

    Keep one line per key: when the key is already in the file, edit that line. The settings page rewrites the first line it finds for a key, and the last one wins.

    The settings page shows `theme`, `font-family`, `font-size`, `cursor-style`, `cursor-style-blink`, `macos-option-as-alt` and `copy-on-select`. It reads `font-size` as a whole number, blinking as off only for `cursor-style-blink = false`, and copy on select as on only for `copy-on-select = clipboard`.

    `~/.config/ghostty/config` loads first when it exists and Farol's file wins, so make every change in Farol's file.

    When a saved change does not show, ⇧⌘, reloads the config by hand.

    Everything else is kept by the app, where only the user can change it, in Settings (⌘,). For these, tell the user where to click:

    - Appearance: the app icon, the panel style and grouping sessions by project.
    - Agents: connecting Claude Code, Codex, OpenCode and Pi, one row per account, notifications, the Dock badge, the menu bar lighthouse or the status panel at the notch or screen edge, what new sessions start with, and whether agent conversations resume when Farol opens.
    - Worktrees: copying ignored `.env` files into each new worktree.
    - Integrations: the `gh`, `glab` and jira-cli accounts, and which Jira tickets New Task lists.
    - Remote: letting a paired phone in, pairing a phone with Show code, removing one, keeping the Mac awake for agents, and the relay.

    ## Agent status

    Claude Code and Codex report working, waiting and done through the hooks that Settings → Agents adds, and OpenCode and Pi through a plugin it adds. Any other agent or script in a Farol session can report with `"$FAROL_CLI" status working`, `waiting`, `done` or `clear`, and add `--asking "<what it waits on>"`, `--tool <name>`, `--prompt "<what you asked>"` or `--session <id> --log <file>` for its conversation. `$FAROL_CLI` is unset outside Farol. A session that stays idle usually needs its agent connected in Settings → Agents, then restarted.

    ## Other sessions and agents

    The `farol` command, in every Farol pane, drives Farol. Where `farol` is not found, `"$FAROL_CLI"` is the same command.

    - `farol sessions` lists the sessions: id, status, name, agent and branch, and what one that waits asks. `(you)` marks your own. `--json` gives every field.
    - `farol task <what to do> [--agent claude|codex] [--repo <folder>]` starts an agent on the task in a new worktree of this repository, on a new branch, and prints its session. It opens beside the user's, without taking their window.
    - `farol wait <session>` returns once that session's agent is done or needs someone, after 9 minutes at most. Exit code 2 means it still works: run it again.
    - `farol read <session>` prints its agent's last message.
    - `farol send <session> <message>` types a message to its agent. Farol refuses one that waits for someone, since that answer is the user's.

    A session is its id, the start of it, or its name. `task` and `send` work once the user turns on Settings → Agents → Let agents start tasks and message sessions. Until then they say so: tell the user.

    Codex runs commands in a sandbox that cannot reach Farol. Run `farol` with escalated permissions, so Codex asks the user, who can allow every command that starts with `farol` at once.

    Split work this way only when the user asks for work to be split up, run in parallel or handed off. Start the tasks, wait for each, read what it did, then point the user to its branch to review.

    ## Shortcuts

    A `keybind` line adds or changes one, with Ghostty's key and action names: `keybind = cmd+shift+enter=toggle_split_zoom`.

    - Rebindable: everything inside the terminal, like copy, paste, clear, font size and scrolling, and these app actions: `new_tab` (a new session), `close_tab`, `goto_tab`, `next_tab`, `previous_tab`, `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`, `toggle_fullscreen`, `reload_config`, `open_config` (Settings) and `quit`.
    - Fixed: Farol's own menu shortcuts, like New Task (⇧⌘N), New Worktree Session (⇧⌘T), Switch Session (⌘P), Files (⇧⌘E), Review Changes (⌥⌘R), Commit (⌥⌘C), Push (⌥⌘P), Git Graph (⌥⌘G), Resolve Conflicts (⌥⌘M) and the Farol Inspector (⌥⌘I). Tell the user these stay as they are.

    Every shortcut is listed in Settings → Shortcuts and in the README.

    ## Themes

    `theme` takes the exact name of a bundled theme. Each one is a file in `/Applications/Farol.app/Contents/Resources/ghostty/themes`, so list that folder to find the name. When Farol is installed somewhere else, the folder is `Contents/Resources/ghostty/themes` inside that app. Farol's own are `Farol Beam` (the default), `Farol Dark`, `Farol Navy` and `Farol Light`.

    A custom theme is a file of Ghostty config in `~/.config/farol/themes`, with `background`, `foreground`, `cursor-color` and `palette = 0=#45475a` through 15. Set it by its full path, starting at `/`: `theme = /Users/name/.config/farol/themes/mine`.

    """
}
