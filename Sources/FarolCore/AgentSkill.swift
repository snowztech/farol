import Foundation

/// A skill that tells the agent how Farol is configured. Claude Code and Codex read the same format.
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
    description: How Farol, the macOS terminal this session may be running in, is configured. Use when the user asks to change a Farol or terminal setting (theme, font, cursor, keybinding, any Ghostty option), to add a theme, or how something in Farol works.
    ---

    # Farol

    Farol is a macOS terminal for coding agents, built on libghostty. This session runs inside Farol when `$FAROL_PANE` is set.

    ## Settings file

    Terminal settings live in `~/.config/farol/config`. Edit that file directly. Farol watches it, so a saved change applies to every session right away, with no restart or reload.

    The file uses Ghostty's format, one `key = value` per line, and `#` starts a comment:

    ```
    theme = Farol Dark
    font-family = JetBrains Mono
    font-size = 14
    cursor-style = bar
    ```

    - Every option at https://ghostty.org/docs/config works.
    - Change the existing line for a key when there is one, and leave the user's other lines and comments alone.
    - To go back to a default, delete the line.
    - `~/.config/ghostty/config` loads first when it exists, and Farol's file wins. Do not edit the Ghostty file to change Farol.

    The settings page writes these keys: `theme`, `font-family`, `font-size`, `cursor-style` (`block`, `bar` or `underline`), `cursor-style-blink` (`false` to stop blinking), `macos-option-as-alt` (`true`, `left` or `right`) and `copy-on-select` (`clipboard`).

    ## Themes

    - Farol's own: `Farol Beam` (the default), `Farol Dark`, `Farol Navy`, `Farol Light`.
    - Any Ghostty theme, by name: `theme = Catppuccin Mocha`.
    - A custom theme is a file in `~/.config/farol/themes`, with a few lines of Ghostty config (`background`, `foreground`, `cursor-color`, `palette = 0=#45475a` and so on). Set it by full path, without `~`: `theme = /Users/name/.config/farol/themes/mine`.

    ## Not in the file

    These are kept by the app, and only the user can change them, in Settings (⌘,):

    - Appearance: app icon, panel style, sessions grouped by project.
    - Agents: connecting Claude Code or Codex, the menu bar item and the status panel at the notch or screen edge.
    - Integrations: `gh`, `glab` and jira-cli accounts.

    Tell the user where the setting is instead of trying to change it.

    ## Agent status

    `"$FAROL_CLI" status working|waiting|done|clear` sets the dot next to this session in the sidebar. Farol's hooks already call it, so do not run it yourself unless the user asks.

    ## Shortcuts the user may ask about

    ⇧⌘N new task, ⇧⌘T worktree session, ⌘P switch session, ⌘D split pane, ⇧⌘E files, ⌥⌘R review changes, ⌥⌘G git graph, ⌥⌘M resolve conflicts, ⌘, settings.

    """
}
