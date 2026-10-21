import Foundation

/// A command found in a project or saved by the user, offered in Run and search.
public struct ProjectCommand: Equatable, Hashable, Sendable {
    /// What it is called where it is defined, like `test`.
    public let name: String
    /// What is typed to run it, like `make test` or `pnpm run test`.
    public let command: String
    /// The folder with the file that defines it.
    public let folder: String
    /// The file that defines it, like `Makefile`.
    public let source: String
    public let global: Bool

    public var displayCommand: String { global ? "sh \(source)" : command }

    public init(name: String, command: String, folder: String, source: String, global: Bool = false) {
        self.name = name
        self.command = command
        self.folder = folder
        self.source = source
        self.global = global
    }

    /// Project commands use their own folder. Global scripts use the pane's current folder.
    public func line(from directory: String?) -> String {
        if global { return command }
        return directory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == URL(fileURLWithPath: folder).standardizedFileURL.path
            ? command : "(cd \(NewTask.shellQuoted(folder)) && \(command))"
    }
}

public enum ProjectCommands {
    public enum SaveError: LocalizedError {
        case invalidName, emptyScript, alreadyExists, notSaved

        public var errorDescription: String? {
            switch self {
            case .invalidName: "Use a name with letters, numbers, spaces, hyphens or underscores."
            case .emptyScript: "Enter a command to run."
            case .alreadyExists: "A command with that name already exists."
            case .notSaved: "This saved command could not be found."
            }
        }
    }

    public static func commandsDirectory(in folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(".farol/commands", isDirectory: true)
    }

    public static var globalDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".farol/commands", isDirectory: true)
    }

    /// One editable shell script per command, in the folder shared with the project.
    public static func save(name: String, script: String, in folder: String) throws {
        try save(name: name, script: script, to: commandsDirectory(in: folder))
    }

    public static func saveGlobal(name: String, script: String) throws {
        try save(name: name, script: script, to: globalDirectory)
    }

    /// Saved scripts in the folders visible to a project, including global scripts even when a project shadows one.
    public static func saved(in folder: String, top: String?, globalDirectory: URL? = nil) -> [ProjectCommand] {
        var found = folders(from: folder, to: top).flatMap { directory in
            savedCommands(in: commandsDirectory(in: directory), folder: directory)
        }
        if let globalDirectory {
            found += savedCommands(in: globalDirectory, folder: globalDirectory.path, global: true)
        }
        return found
    }

    /// Updates a saved script, renaming its file when its name changes.
    public static func update(_ command: ProjectCommand, name: String, script: String,
                              globalDirectory: URL? = nil) throws {
        let (name, script) = try validated(name: name, script: script)
        let oldFile = try savedFile(for: command, globalDirectory: globalDirectory)
        let directory = oldFile.deletingLastPathComponent()
        let newFile = directory.appendingPathComponent(name + ".sh")
        let isSameFile = areSameFile(oldFile, newFile)
        guard isSameFile || !FileManager.default.fileExists(atPath: newFile.path) else { throw SaveError.alreadyExists }
        let text = script.trimmingCharacters(in: .newlines) + "\n"
        if oldFile.standardizedFileURL.path == newFile.standardizedFileURL.path {
            try text.write(to: newFile, atomically: true, encoding: .utf8)
        } else if isSameFile {
            let fileManager = FileManager.default
            let staged = directory.appendingPathComponent(".farol-command-\(UUID().uuidString)")
            let backup = directory.appendingPathComponent(".farol-command-backup-\(UUID().uuidString)")
            try text.write(to: staged, atomically: true, encoding: .utf8)
            try fileManager.moveItem(at: oldFile, to: backup)
            do {
                try fileManager.moveItem(at: staged, to: newFile)
                try fileManager.removeItem(at: backup)
            } catch {
                try? fileManager.removeItem(at: newFile)
                try? fileManager.moveItem(at: backup, to: oldFile)
                try? fileManager.removeItem(at: staged)
                throw error
            }
        } else {
            try text.write(to: newFile, atomically: true, encoding: .utf8)
            do {
                try FileManager.default.removeItem(at: oldFile)
            } catch {
                try? FileManager.default.removeItem(at: newFile)
                throw error
            }
        }
    }

    public static func script(for command: ProjectCommand, globalDirectory: URL? = nil) throws -> String {
        let file = try savedFile(for: command, globalDirectory: globalDirectory)
        guard let script = try? String(contentsOf: file, encoding: .utf8) else {
            throw SaveError.notSaved
        }
        return script
    }

    /// Removes only the saved script represented by this command.
    public static func delete(_ command: ProjectCommand, globalDirectory: URL? = nil) throws {
        let file = try savedFile(for: command, globalDirectory: globalDirectory)
        try FileManager.default.removeItem(at: file)
    }

    private static func save(name: String, script: String, to directory: URL) throws {
        let (name, script) = try validated(name: name, script: script)
        let file = directory.appendingPathComponent(name + ".sh")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw SaveError.alreadyExists }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (script.trimmingCharacters(in: .newlines) + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func validated(name: String, script: String) throws -> (name: String, script: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name) else { throw SaveError.invalidName }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SaveError.emptyScript }
        return (name, script)
    }

    private static func validName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || " _-".contains($0) }
    }

    private static func isSavedFile(_ file: URL) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    private static func areSameFile(_ first: URL, _ second: URL) -> Bool {
        guard let firstAttributes = try? FileManager.default.attributesOfItem(atPath: first.path),
              let secondAttributes = try? FileManager.default.attributesOfItem(atPath: second.path),
              let firstDevice = firstAttributes[.systemNumber] as? NSNumber,
              let secondDevice = secondAttributes[.systemNumber] as? NSNumber,
              let firstNumber = firstAttributes[.systemFileNumber] as? NSNumber,
              let secondNumber = secondAttributes[.systemFileNumber] as? NSNumber else {
            return first.standardizedFileURL.path == second.standardizedFileURL.path
        }
        return firstDevice == secondDevice && firstNumber == secondNumber
    }

    private static func savedFile(for command: ProjectCommand, globalDirectory: URL?) throws -> URL {
        guard validName(command.name) else { throw SaveError.notSaved }
        let directory = command.global ? (globalDirectory ?? self.globalDirectory)
            : commandsDirectory(in: command.folder)
        let file = directory.appendingPathComponent(command.name + ".sh")
        guard isSavedFile(file) else { throw SaveError.notSaved }
        return file
    }

    /// The commands defined from `folder` up to `top`, then global scripts, closest first.
    /// Project names hide matching global names. Reads files, so call it off the main thread.
    public static func find(in folder: String, top: String?, globalDirectory: URL? = nil) -> [ProjectCommand] {
        var found: [ProjectCommand] = []
        var seen = Set<String>()
        for directory in folders(from: folder, to: top) {
            for command in commands(in: directory) where seen.insert(command.command).inserted {
                found.append(command)
            }
        }
        if let globalDirectory {
            let names = Set(found.map(\.name))
            found += savedCommands(in: globalDirectory, folder: globalDirectory.path, global: true)
                .filter { !names.contains($0.name) }
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
        var found = savedCommands(in: commandsDirectory(in: folder), folder: folder)
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

    private static func savedCommands(in directory: URL, folder: String, global: Bool = false) -> [ProjectCommand] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in
            guard name.hasSuffix(".sh"), !name.hasPrefix("."),
                  let type = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.type]
                    as? FileAttributeType else { return false }
            return type == .typeRegular
        }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { filename in
                let source = global ? directory.appendingPathComponent(filename).path : ".farol/commands/" + filename
                return ProjectCommand(name: String(filename.dropLast(3)), command: "sh \(NewTask.shellQuoted(source))",
                                      folder: folder,
                                      source: global ? "~/.farol/commands/" + filename : source, global: global)
            }
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
