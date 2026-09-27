import AppKit

/// The icon variants in Resources/icons. The choice changes the Dock icon while Farol runs.
/// Finder keeps the default: changing the bundle's own icon would break its code signature.
enum AppIcon: String, CaseIterable {
    case beam, dark, navy, light

    static let key = "appearance.icon"
    static let `default` = AppIcon.beam

    var title: String { rawValue.capitalized }

    var image: NSImage? {
        Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("icons/\(rawValue).png")) }
    }

    static var current: AppIcon {
        UserDefaults.standard.string(forKey: key).flatMap(AppIcon.init) ?? .default
    }

    /// The default is the bundle's own icon, so it needs no override.
    static func apply(_ icon: AppIcon = current) {
        NSApp.applicationIconImage = icon == .default ? nil : icon.image
    }
}
