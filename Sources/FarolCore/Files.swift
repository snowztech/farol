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

    /// The paths that have every word typed, with a match in the file's name before one in its folders, then the shorter path.
    /// Nothing typed finds nothing.
    public static func search(_ paths: [String], _ query: String, limit: Int = 30) -> [String] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        // Every path is lowercased again on each key, which is quick enough until a repo has hundreds of thousands of files.
        let found = paths.compactMap { path -> (path: String, inName: Bool)? in
            let lower = path.lowercased()
            guard words.allSatisfy(lower.contains) else { return nil }
            let name = lower[(lower.lastIndex(of: "/").map(lower.index(after:)) ?? lower.startIndex)...]
            return (path, words.allSatisfy(name.contains))
        }
        return found
            .sorted { a, b in
                a.inName != b.inName ? a.inName : a.path.count != b.path.count ? a.path.count < b.path.count : a.path < b.path
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
