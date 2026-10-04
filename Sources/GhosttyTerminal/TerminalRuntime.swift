import AppKit
import GhosttyKit

/// Process-wide libghostty state. Create one at launch and share it with every TerminalView.
public final class TerminalRuntime {
    private(set) var app: ghostty_app_t!
    private var config: ghostty_config_t!
    private let overrideFiles: [URL]

    /// Colors from the user's Ghostty config alone, before Farol's overrides. Nil when it sets none, which leaves Farol Beam.
    public private(set) var ghosttyConfigColors: (background: NSColor, foreground: NSColor)?

    /// App level requests from key bindings, like quitting. Surface level ones go to TerminalView.onRequest.
    public var onRequest: ((TerminalRequest) -> Void)?

    /// True while any terminal runs a program that quitting would kill.
    public var hasRunningProcesses: Bool { ghostty_app_needs_confirm_quit(app) }

    /// What libghostty could not read in the config files, one message per problem. Empty when all of it was read.
    public private(set) var configErrors: [String] = []

    /// Called on the main thread after reloadConfig() applied new settings.
    public var onConfigChange: (() -> Void)?

    /// `overrideFiles` load after the user's Ghostty config, so they win.
    public init(overrideFiles: [URL] = []) {
        // Opened from a Ghostty terminal, Farol is handed Ghostty's own resources folder, which has no Farol themes.
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
           FileManager.default.fileExists(atPath: resources) {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }
        self.overrideFiles = overrideFiles
        config = Self.loadConfig(overrideFiles)
        configErrors = Self.errors(in: config)

        let base = Self.loadConfig([])
        let plain = Self.loadConfig([], ghosttyFiles: false)
        let colors = [base, plain].map { [Self.color($0, "background") ?? .black, Self.color($0, "foreground") ?? .white] }
        if colors[0] != colors[1] { ghosttyConfigColors = (colors[0][0], colors[0][1]) }
        ghostty_config_free(base)
        ghostty_config_free(plain)

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        // Ghostty calls this from its IO and renderer threads, but ticking must happen on main.
        rt.wakeup_cb = { ud in
            let runtime = Unmanaged<TerminalRuntime>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { ghostty_app_tick(runtime.app) }
        }
        rt.action_cb = { app, target, action in
            if target.tag == GHOSTTY_TARGET_SURFACE, let ud = ghostty_surface_userdata(target.target.surface) {
                return TerminalView.from(ud).handle(action)
            }
            guard let app, let ud = ghostty_app_userdata(app), let request = TerminalRequest(action) else { return false }
            let runtime = Unmanaged<TerminalRuntime>.fromOpaque(ud).takeUnretainedValue()
            guard let onRequest = runtime.onRequest else { return false }
            DispatchQueue.main.async { onRequest(request) }
            return true
        }
        rt.close_surface_cb = { ud, _ in
            guard let ud else { return }
            let view = TerminalView.from(ud)
            DispatchQueue.main.async { view.onClose?() }
        }
        rt.read_clipboard_cb = { ud, location, state, mimes, count, list in
            guard let ud else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            return Clipboard.read(TerminalView.from(ud), location: location, state: state, mimes: mimes, count: count, list: list)
        }
        rt.confirm_read_clipboard_cb = { ud, request, state, kind in
            guard let ud else { return }
            Clipboard.confirmRead(TerminalView.from(ud), request: request, state: state, kind: kind)
        }
        rt.write_clipboard_cb = { ud, location, content, count, confirm in
            guard let ud else { return }
            Clipboard.write(TerminalView.from(ud), location: location, content: content, count: count, confirm: confirm)
        }

        app = ghostty_app_new(&rt, config)
    }

    /// Re-reads all config files and applies them to every open terminal.
    public func reloadConfig() {
        let old = config
        config = Self.loadConfig(overrideFiles)
        configErrors = Self.errors(in: config)
        ghostty_app_update_config(app, config)
        ghostty_config_free(old)
        onConfigChange?()
    }

    private static func errors(in config: ghostty_config_t) -> [String] {
        (0..<ghostty_config_diagnostics_count(config)).map {
            String(cString: ghostty_config_get_diagnostic(config, $0).message).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    /// Theme colors, so window chrome can match the terminal.
    public var backgroundColor: NSColor { Self.color(config, "background") ?? .black }
    public var foregroundColor: NSColor { Self.color(config, "foreground") ?? .white }

    /// The theme's 16 ANSI colors, the ones programs like `ls` use. Empty if Ghostty cannot report them.
    public var ansiColors: [NSColor] {
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return [] }
        return withUnsafeBytes(of: palette.colors) { Array($0.bindMemory(to: ghostty_config_color_s.self).prefix(16)) }
            .map(Self.nsColor)
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return nsColor(c)
    }

    private static func nsColor(_ c: ghostty_config_color_s) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// Names of the themes bundled with Ghostty (usable as `theme = <name>`).
    public static var bundledThemes: [String] {
        guard let dir = themesDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Each file in here is a theme in Ghostty config syntax.
    public static var themesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes")
    }

    /// Farol Beam is the theme until a config names another.
    /// Shell integration sets a bar cursor at every prompt, which hides the cursor-style setting.
    /// Loaded first, so the user's Ghostty config and the override files can still change both.
    private static let defaults = "theme = Farol Beam\nshell-integration-features = no-cursor\n"

    private static func loadConfig(_ overrides: [URL], ghosttyFiles: Bool = true) -> ghostty_config_t {
        let config = ghostty_config_new()!
        // libghostty only reads config from files.
        let defaultsFile = FileManager.default.temporaryDirectory.appendingPathComponent("farol-defaults")
        if (try? defaults.write(to: defaultsFile, atomically: true, encoding: .utf8)) != nil {
            ghostty_config_load_file(config, defaultsFile.path)
        }
        if ghosttyFiles { ghostty_config_load_default_files(config) }
        for url in overrides where FileManager.default.fileExists(atPath: url.path) {
            ghostty_config_load_file(config, url.path)
        }
        ghostty_config_finalize(config)
        return config
    }
}
