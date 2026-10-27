import AppKit
import SwiftUI

/// Farol shows files but you write them elsewhere, so a file or a session's folder can go to your editor in one click.
enum Editors {
    struct App {
        let id: String
        let url: URL
        var name: String { FileManager.default.displayName(atPath: url.path) }

        var icon: NSImage {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    }

    // Only the ones installed show, so an id that's wrong or missing costs a row, never an error.
    private static let bundleIDs = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.rustrover",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        "com.google.android.studio",
    ]

    // ponytail: looked up once per launch, so an editor installed while Farol runs shows after a restart.
    static let installed: [App] = bundleIDs.compactMap { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { App(id: id, url: $0) }
    }

    private static let lastKey = "openInEditor"

    /// The editor you picked last, so ⌘O goes where you went before.
    static var preferred: App? {
        installed.first { $0.id == UserDefaults.standard.string(forKey: lastKey) } ?? installed.first
    }

    static func open(_ path: String, in app: App) {
        UserDefaults.standard.set(app.id, forKey: lastKey)
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// In your editor if you have one, in Finder otherwise.
    static func open(_ path: String) {
        if let app = preferred { open(path, in: app) } else { reveal(path) }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The same items as a right-click, behind a button you can see.
struct OpenInButton: View {
    let path: String
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Menu {
            OpenInItems(path: path)
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 20)
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : .clear))
                .contentShape(Rectangle())
        }
        // Plain keeps the label as drawn here. The bordered styles put AppKit's own, larger arrow in.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onClickableHover { hovering = $0 }
        .hoverTip("Open in… (⌘O)")
    }
}

/// Finder first, as every Mac app has it, then each editor you have.
struct OpenInItems: View {
    let path: String

    var body: some View {
        Button("Show in Finder") { Editors.reveal(path) }
        if !Editors.installed.isEmpty {
            Divider()
            ForEach(Editors.installed, id: \.id) { app in
                Button { Editors.open(path, in: app) } label: {
                    Label { Text("Open in \(app.name)") } icon: { Image(nsImage: app.icon) }
                }
            }
        }
    }
}
