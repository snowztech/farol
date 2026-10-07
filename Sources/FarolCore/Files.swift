import Foundation

/// What the files panel lists and what a file pane shows.
public enum Files {
    public struct Entry: Equatable, Hashable {
        public let path: String
        public let isDirectory: Bool

        public var name: String { (path as NSString).lastPathComponent }
        public var isHidden: Bool { name.hasPrefix(".") }
    }

    /// Git's own folder and Finder's metadata are never what you are looking for.
    static let skipped: Set<String> = [".git", ".DS_Store"]

    /// Installed dependencies, which a search outside git would otherwise fill up with. Names a source folder never has.
    static let dependencies: Set<String> = ["node_modules", "Pods", "DerivedData", "__pycache__"]

    /// A folder's entries, folders first, then by name the way Finder sorts them.
    public static func list(_ directory: String) -> [Entry] {
        let url = URL(fileURLWithPath: directory)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { !skipped.contains($0.lastPathComponent) }
            .map { Entry(path: $0.path, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Paths git ignores in the checkout at `root`. An ignored folder is listed once, not file by file.
    public static func ignored(in root: String) -> Set<String> {
        guard let output = try? Git.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], in: root)
        else { return [] }
        let base = URL(fileURLWithPath: root)
        return Set(output.split(separator: "\n").map {
            base.appendingPathComponent(String($0)).standardizedFileURL.path
        })
    }

    /// Every file in the checkout at `root` that git tracks or would add, relative to it. Empty outside a repo.
    public static func tracked(in root: String) -> [String] {
        // -z, since git quotes a name with an accent or a space otherwise.
        guard let output = try? Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        else { return [] }
        return output.split(separator: "\0").map(String.init)
    }

    /// What can be searched under `root`, relative to it, with a slash after each folder.
    /// In a git checkout that is what git tracks or would add. Anywhere else it is what a short walk finds.
    public static func searchable(in root: String) -> [String] {
        let tracked = tracked(in: root)
        guard !tracked.isEmpty else { return walk(root) }
        var folders = Set<String>()
        for path in tracked {
            var rest = Substring(path)
            // Stops at the first folder already seen, since its parents were added with it.
            while let slash = rest.lastIndex(of: "/"), folders.insert(String(rest[...slash])).inserted { rest = rest[..<slash] }
        }
        return folders.sorted() + tracked
    }

    /// The files and folders under `root`, nearest first and without the hidden ones.
    /// There is no .gitignore to say what to skip, so the depth and the count are capped to keep a session in your home folder quick.
    static func walk(_ root: String, depth: Int = 3, limit: Int = 5000) -> [String] {
        var found: [String] = []
        var level = [""]
        for _ in 0..<depth {
            var next: [String] = []
            for folder in level {
                for entry in list(root + "/" + folder) where !entry.isHidden && !dependencies.contains(entry.name) {
                    guard found.count < limit else { return found }
                    let path = folder + entry.name + (entry.isDirectory ? "/" : "")
                    found.append(path)
                    if entry.isDirectory { next.append(path) }
                }
            }
            level = next
        }
        return found
    }

    /// The paths that have every word typed, best first, and the shorter path first among equals.
    /// A name that starts with a word beats a match elsewhere in the name, which beats one in the folders above.
    /// Nothing typed finds nothing.
    public static func search(_ paths: [String], _ query: String, limit: Int = 30) -> [String] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        // Every path is lowercased again on each key, which is quick enough until a repo has hundreds of thousands of files.
        let found = paths.compactMap { path -> (path: String, rank: Int)? in
            let lower = path.lowercased()
            guard words.allSatisfy(lower.contains) else { return nil }
            // A folder ends in a slash, which is not part of its name.
            let trimmed = lower.hasSuffix("/") ? lower.dropLast() : Substring(lower)
            let name = trimmed[(trimmed.lastIndex(of: "/").map(trimmed.index(after:)) ?? trimmed.startIndex)...]
            return (path, !words.allSatisfy(name.contains) ? 2 : words.contains(where: name.hasPrefix) ? 0 : 1)
        }
        return found
            .sorted { a, b in
                a.rank != b.rank ? a.rank < b.rank : a.path.count != b.path.count ? a.path.count < b.path.count : a.path < b.path
            }
            .prefix(limit).map(\.path)
    }

    public enum Content: Equatable {
        case text(String)
        case binary
        case tooLarge
    }

    /// Big enough for any source file, small enough that opening a log by mistake stays quick.
    public static let sizeLimit = 2_000_000

    public static func read(_ path: String) throws -> Content {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        if (attributes[.size] as? Int ?? 0) > sizeLimit { return .tooLarge }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }
}
