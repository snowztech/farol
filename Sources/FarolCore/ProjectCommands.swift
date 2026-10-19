import Foundation

/// A command the project already defines, like a Makefile target or a script in package.json, offered to run without saving anything.
public struct ProjectCommand: Equatable, Hashable, Sendable {
    /// What it is called where it is defined, like `test`.
    public let name: String
    /// What is typed to run it, like `make test` or `pnpm run test`.
    public let command: String
    /// The folder it runs in, the one with the file that defines it.
    public let folder: String
    /// The file that defines it, like `Makefile`.
    public let source: String

    /// Typed in a shell that is in `directory`. From elsewhere it runs in a subshell in its own folder, so the shell stays where it was.
    public func line(from directory: String?) -> String {
        directory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == URL(fileURLWithPath: folder).standardizedFileURL.path
            ? command : "(cd \(NewTask.shellQuoted(folder)) && \(command))"
    }
}

public enum ProjectCommands {
    /// The commands defined in `folder` and the folders above it up to `top`, the checkout's, closest first.
    /// A name defined in a closer folder hides the same name further up. Reads a few small files, so call it off the main thread.
    public static func find(in folder: String, top: String?) -> [ProjectCommand] {
        var found: [ProjectCommand] = []
        var seen = Set<String>()
        for directory in folders(from: folder, to: top) {
            for command in commands(in: directory) where seen.insert(command.command).inserted {
                found.append(command)
            }
        }
        return found
    }

    /// `folder` and the folders above it, stopping at `top`. Without a top, only `folder`, since a home folder's parents define nothing to run.
    static func folders(from folder: String, to top: String?) -> [String] {
        let start = URL(fileURLWithPath: folder).standardizedFileURL.path
        guard let top = top.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }), start.hasPrefix(top) else { return [start] }
        var folders = [start]
        var current = start
        while current != top, current != "/" {
            current = (current as NSString).deletingLastPathComponent
            folders.append(current)
        }
        return folders
    }

    /// What one folder defines, in the order of its files: package.json, then the Makefile, then the justfile.
    // ponytail: these three cover most projects. Taskfile, deno.json or pyproject scripts can be added the same way when asked for.
    static func commands(in folder: String) -> [ProjectCommand] {
        // The names as they are on disk: the Mac's file system ignores case, so asking for makefile would find Makefile under the wrong name.
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
        func first(_ candidates: [String]) -> (name: String, text: String)? {
            candidates.lazy.filter(names.contains).compactMap { name in read(folder, name).map { (name, $0) } }.first
        }
        var found: [ProjectCommand] = []
        if names.contains("package.json"), let text = read(folder, "package.json") {
            let runner = packageManager(in: folder)
            found += scripts(inPackage: text).map {
                ProjectCommand(name: $0, command: "\(runner) run \($0)", folder: folder, source: "package.json")
            }
        }
        // In the order make and just look for them.
        if let (name, text) = first(["GNUmakefile", "makefile", "Makefile"]) {
            found += targets(inMakefile: text).map { ProjectCommand(name: $0, command: "make \($0)", folder: folder, source: name) }
        }
        if let (name, text) = first(["justfile", "Justfile", ".justfile"]) {
            found += recipes(inJustfile: text).map { ProjectCommand(name: $0, command: "just \($0)", folder: folder, source: name) }
        }
        return found
    }

    /// The scripts of a package.json, in the order they are written.
    static func scripts(inPackage text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any], !scripts.isEmpty else { return [] }
        // JSONSerialization forgets the order, so the names are found again in the text to keep the file's.
        let names = Set(scripts.keys)
        let ordered = text.matches(of: #/"((?:[^"\\]|\\.)*)"\s*:/#).map { String($0.1) }.filter(names.contains)
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// The lock file says which package manager the project uses. The nearest one, since a workspace keeps it at its top.
    static func packageManager(in folder: String) -> String {
        var current = folder
        while true {
            for (lock, runner) in [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun"), ("package-lock.json", "npm")]
            where FileManager.default.fileExists(atPath: current + "/" + lock) {
                return runner
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !FileManager.default.fileExists(atPath: current + "/.git") else { return "npm" }
            current = parent
        }
    }

    /// The targets a person would run: named at the start of a line, before a colon that isn't an assignment.
    /// Not special targets like .PHONY, pattern rules with %, ones built from variables, or files like main.o and build/out.
    static func targets(inMakefile text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "\n").flatMap { line -> [String] in
            guard let match = line.wholeMatch(of: #/([A-Za-z0-9_][A-Za-z0-9_./ -]*?)\s*::?(?![:=])(.*)/#) else { return [] }
            return match.1.split(separator: " ").map(String.init)
        }
        .filter { !$0.contains(where: "%$/.".contains) && seen.insert($0).inserted }
    }

    /// The recipes that run without arguments. One with a parameter would stop and complain, and one starting with _ is private.
    static func recipes(inJustfile text: String) -> [String] {
        let keywords: Set<String> = ["set", "alias", "export", "import", "mod"]
        var seen = Set<String>()
        return text.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.wholeMatch(of: #/@?([A-Za-z][A-Za-z0-9_-]*)\s*:(?!=).*/#) else { return nil }
            let name = String(match.1)
            return keywords.contains(name) ? nil : name
        }
        .filter { seen.insert($0).inserted }
    }

    private static func read(_ folder: String, _ name: String) -> String? {
        // A build file is small. One that isn't is not worth reading at every ⌘P.
        let path = folder + "/" + name
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size < 512 * 1024 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
