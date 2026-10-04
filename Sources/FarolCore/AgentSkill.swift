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
    description: Farol terminal settings. Use when the user asks to change a terminal setting such as the theme or font, to add a theme, or how Farol works.
    ---

    # Farol

    Farol is a macOS terminal for coding agents, built on libghostty.

    ## Settings

    Terminal settings are lines of Ghostty config in `~/.config/farol/config`:

    ```
    theme = Farol Dark
    font-size = 14
    ```

    Every option at https://ghostty.org/docs/config works. Farol watches the file, so a saved edit is live in every session, with no restart. Deleting a line brings back its default.

    Keep one line per key: when the key is already in the file, edit that line. The settings page rewrites the first line it finds for a key, and the last one wins.

    The settings page shows `theme`, `font-family`, `font-size`, `cursor-style`, `cursor-style-blink`, `macos-option-as-alt` and `copy-on-select`. It reads `font-size` as a whole number, blinking as off only for `cursor-style-blink = false`, and copy on select as on only for `copy-on-select = clipboard`.

    `~/.config/ghostty/config` loads first when it exists and Farol's file wins, so make every change in Farol's file.

    Everything else is kept by the app, where only the user can change it, in Settings (⌘,): the app icon, panel style and grouping by project under Appearance, the agent connections and the menu bar or notch panel under Agents, and the `gh`, `glab` and jira-cli accounts under Integrations. For these, tell the user where to click.

    ## Themes

    `theme` takes the exact name of a bundled theme. Each one is a file in `/Applications/Farol.app/Contents/Resources/ghostty/themes`, so list that folder to find the name. When Farol is installed somewhere else, the folder is `Contents/Resources/ghostty/themes` inside that app. Farol's own are `Farol Beam` (the default), `Farol Dark`, `Farol Navy` and `Farol Light`.

    A custom theme is a file of Ghostty config in `~/.config/farol/themes`, with `background`, `foreground`, `cursor-color` and `palette = 0=#45475a` through 15. Set it by its full path, starting at `/`: `theme = /Users/name/.config/farol/themes/mine`.

    The README at https://github.com/snowztech/farol#readme covers how the rest of Farol works. Read it when the user asks for something this file leaves out.

    """
}
