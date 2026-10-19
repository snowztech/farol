import Foundation

/// A command you named and keep for a folder, offered again in any pane opened in it or under it.
public struct SavedCommand: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    /// The folder it was saved for.
    public var folder: String

    public init(name: String, command: String, folder: String) {
        self.name = name
        self.command = command
        self.folder = folder
    }
}

/// Commands kept between launches in the user's defaults.
public struct SavedCommands {
    private let defaults: UserDefaults
    static let key = "savedCommands"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var all: [SavedCommand] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SavedCommand].self, from: $0) } ?? []
    }

    /// The ones saved for `directory` or a folder above it, so a command saved at a repo's root still shows in its subfolders.
    /// The closest folder comes first, then by name.
    public func available(in directory: String) -> [SavedCommand] {
        let path = Self.normalized(directory)
        return all.filter { path == $0.folder || path.hasPrefix($0.folder == "/" ? "/" : $0.folder + "/") }
            .sorted { ($1.folder.count, $0.name.localizedLowercase) < ($0.folder.count, $1.name.localizedLowercase) }
    }

    /// Adds `command`, or replaces `old` with it when editing. Nothing changes without a name and a command.
    public func save(_ command: SavedCommand, replacing old: SavedCommand? = nil) {
        var command = command
        command.name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        command.command = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        command.folder = Self.normalized(command.folder)
        guard !command.name.isEmpty, !command.command.isEmpty else { return }
        var list = all
        if let old, let index = list.firstIndex(of: old) {
            list[index] = command
        } else {
            list.append(command)
        }
        store(list)
    }

    public func remove(_ command: SavedCommand) {
        store(all.filter { $0 != command })
    }

    private func store(_ list: [SavedCommand]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }

    static func normalized(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.isEmpty ? "/" : standard
    }
}
