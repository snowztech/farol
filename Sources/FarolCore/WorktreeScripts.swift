import Foundation

/// Project scripts run only for worktrees Farol creates or removes.
public enum WorktreeScripts {
    /// A missing setup leaves the command alone. A present setup must finish before it runs.
    public static func starting(_ command: String?, in folder: String) -> String? {
        let folders = FileManager.default.fileExists(atPath: folder + "/.git") ? [folder] : TaskFolders.repos(in: folder)
        let setups = folders.filter { exists("setup", in: $0) }
        guard !setups.isEmpty else { return command }

        let steps = setups.map { repo in
            let name = URL(fileURLWithPath: repo).lastPathComponent
            let path = NewTask.shellQuoted(repo)
            return ["(cd \(path) &&",
                    "printf '%s\\n' \(NewTask.shellQuoted("Setting up \(name)...")) &&",
                    "if [ -x .farol/setup ]", "then", "./.farol/setup", "else",
                    "printf '%s\\n' '.farol/setup must be executable (chmod +x .farol/setup).' >&2",
                    "false", "fi)"].joined(separator: "\n")
        }.joined(separator: " &&\n")
        let body = ["if \(steps)", "then", command ?? ":", "else",
                    "printf '%s\\n' 'Setup failed. The agent was not started. Fix the script, then press Up and Return to retry.'",
                    "fi"].joined(separator: "\n")
        return "sh -c \(NewTask.shellQuoted(body))"
    }

    public static func hasSetup(in folder: String) -> Bool {
        exists("setup", in: folder)
    }

    public static func hasTeardown(in folder: String) -> Bool {
        exists("teardown", in: folder)
    }

    /// A failed teardown keeps the worktree so the user can fix it and try removal again.
    public static func tearDown(in folder: String) throws {
        guard exists("teardown", in: folder) else { return }
        let script = folder + "/.farol/teardown"
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw GitError(description: "\(script) must be executable (chmod +x .farol/teardown).")
        }
        do {
            try Git.run(script, [], in: folder, mergingErrors: true)
        } catch {
            throw GitError(description: "Teardown failed in \(folder): \(error)")
        }
    }

    private static func exists(_ name: String, in folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder + "/.farol/\(name)", isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
