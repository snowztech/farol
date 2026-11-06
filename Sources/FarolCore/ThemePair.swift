import Foundation

/// A theme for each macOS appearance, written `light:A,dark:B` after `theme =`, as Ghostty reads it.
public struct ThemePair: Equatable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    /// Nil for a single theme, or a pair missing one side, which Ghostty would read as one theme.
    public init?(_ value: String) {
        var light: String?, dark: String?
        for part in value.split(separator: ",") {
            let part = part.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("light:") { light = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if part.hasPrefix("dark:") { dark = String(part.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        }
        guard let light, let dark, !light.isEmpty, !dark.isEmpty else { return nil }
        self.init(light: light, dark: dark)
    }

    public var value: String { "light:\(light),dark:\(dark)" }

    public func theme(dark isDark: Bool) -> String { isDark ? dark : light }
}
