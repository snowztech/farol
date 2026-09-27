import AppKit
import GhosttyKit

/// Process-wide libghostty state. Create one at launch and share it with every TerminalView.
public final class TerminalRuntime {
    private(set) var app: ghostty_app_t!
    private var config: ghostty_config_t!
    private let overrideFiles: [URL]

    /// Colors from the user's Ghostty config alone, before Farol's overrides.
    public private(set) var ghosttyConfigColors: (background: NSColor, foreground: NSColor) = (.black, .white)

    /// App level requests from key bindings, like quitting. Surface level ones go to TerminalView.onRequest.
    public var onRequest: ((TerminalRequest) -> Void)?

    /// True while any terminal runs a program that quitting would kill.
    public var hasRunningProcesses: Bool { ghostty_app_needs_confirm_quit(app) }

    /// Called on the main thread after reloadConfig() applied new settings.
    public var onConfigChange: (() -> Void)?

    /// `overrideFiles` load after the user's Ghostty config, so they win.
    public init(overrideFiles: [URL] = []) {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }
        self.overrideFiles = overrideFiles
        config = Self.loadConfig(overrideFiles)

        let base = Self.loadConfig([])
        ghosttyConfigColors = (Self.color(base, "background") ?? .black, Self.color(base, "foreground") ?? .white)
        ghostty_config_free(base)

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
        ghostty_app_update_config(app, config)
        ghostty_config_free(old)
        onConfigChange?()
    }

    /// Theme colors, so window chrome can match the terminal.
    public var backgroundColor: NSColor { Self.color(config, "background") ?? .black }
    public var foregroundColor: NSColor { Self.color(config, "foreground") ?? .white }

    /// The theme's ANSI blue. Nearly every theme defines it and treats it as its main accent.
    public var accentColor: NSColor {
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return .systemBlue }
        // Swift imports the C array as a 256-element tuple, so read it as a buffer.
        let blue = withUnsafeBytes(of: &palette.colors) { $0.bindMemory(to: ghostty_config_color_s.self)[4] }
        return Self.nsColor(blue)
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

    private static func loadConfig(_ overrides: [URL]) -> ghostty_config_t {
        let config = ghostty_config_new()!
        ghostty_config_load_default_files(config)
        for url in overrides where FileManager.default.fileExists(atPath: url.path) {
            ghostty_config_load_file(config, url.path)
        }
        ghostty_config_finalize(config)
        return config
    }
}
