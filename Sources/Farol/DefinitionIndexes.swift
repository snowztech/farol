import FarolCore
import Foundation

/// The declaration indexes, one per checkout and family of languages, kept so ⌘ over a name answers at once.
/// A changed file marks its index stale, and the next lookup rebuilds it behind the old answers.
/// So nothing runs while you aren't looking things up.
@MainActor
enum DefinitionIndexes {
    private final class Entry {
        var index: Definitions.Index?
        var stale = false
        var building = false
        var waiting: [@MainActor (Definitions.Index) -> Void] = []
        var watcher: FolderWatcher?
    }

    /// Most recent last. A few checkouts, since each holds every declaration of its project.
    private static var entries: [(key: String, entry: Entry)] = []
    private static let kept = 4
    /// The checkout a folder is in, asked of git once per folder. The checkout itself, so a worktree finds its own files.
    private static var tops: [String: String] = [:]

    static func index(for path: String, then done: @escaping @MainActor (Definitions.Index) -> Void) {
        guard let family = Definitions.family(of: path) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        if let top = tops[directory] { return index(for: path, in: top, family: family, then: done) }
        DispatchQueue.global(qos: .userInitiated).async {
            let top = Git.topLevel(of: directory) ?? directory
            DispatchQueue.main.async {
                tops[directory] = top
                index(for: path, in: top, family: family, then: done)
            }
        }
    }

    private static func index(for path: String, in folder: String, family: String, then done: @escaping @MainActor (Definitions.Index) -> Void) {
        let key = family + "\0" + folder
        let entry = entry(key, folder: folder, family: family)
        if let index = entry.index {
            done(index)
            if entry.stale { build(key, for: path, in: folder) }
        } else {
            entry.waiting.append(done)
            build(key, for: path, in: folder)
        }
    }

    /// The entry for `key`, moved to most recent, made and watched the first time.
    private static func entry(_ key: String, folder: String, family: String) -> Entry {
        if let at = entries.firstIndex(where: { $0.key == key }) {
            let found = entries.remove(at: at)
            entries.append(found)
            return found.entry
        }
        let entry = Entry()
        entry.watcher = FolderWatcher(folder, latency: 0.5) { [weak entry] paths in
            if paths.contains(where: { Definitions.family(of: $0) == family }) { entry?.stale = true }
        }
        entries.append((key, entry))
        // The oldest goes, and its watcher with it.
        if entries.count > kept { entries.removeFirst() }
        return entry
    }

    /// The entry is looked up again once the search is done, on the main thread, where entries live. It may have been dropped by then.
    private static func build(_ key: String, for path: String, in folder: String) {
        guard let entry = entries.first(where: { $0.key == key })?.entry, !entry.building else { return }
        entry.building = true
        // Cleared before the search starts, so a file changed while it runs makes the next lookup build again.
        entry.stale = false
        DispatchQueue.global(qos: .userInitiated).async {
            let index = Definitions.Index.build(for: path, in: folder)
            DispatchQueue.main.async {
                guard let entry = entries.first(where: { $0.key == key })?.entry else { return }
                entry.index = index
                entry.building = false
                let waiting = entry.waiting
                entry.waiting = []
                for done in waiting { done(index) }
            }
        }
    }
}
