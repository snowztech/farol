import Foundation
import Testing
@testable import FarolCore

// The queue file from the design: every kind of chunk in one place.
private let base = """
import { api } from "./api"

const DELAY = 500

export class Queue {
  push(change) {
    this.pending.push(change)
  }

  async flush() {
    await api.send(change)
    this.pending.shift()
    await sleep(DELAY)
  }

  get size() {
    return this.pending.length
  }

  clear() {
    this.pending = []
  }
}

"""

private let mine = """
import { api } from "./api"
import { log } from "./log"

const RETRY_MS = 500

export class Queue {
  push(change) {
    this.pending.push(change)
    log("queued")
  }

  async flush() {
    await api.post(change)
    this.pending.shift()
    await sleep(RETRY_MS)
  }

  get size() {
    return this.pending.length
  }

  clear() {
    this.pending.length = 0
  }
}

"""

private let other = """
import { api } from "./api"
import { backoff } from "./backoff"

const DELAY = 500

export class Queue {
  push(change) {
    this.pending.push(change)
  }

  async flush() {
    await api.post(change)
    this.pending.shift()
    attempt++
    await sleep(backoff(attempt))
  }

  get size() {
    return this.pending.length
  }
}

"""

@Test func cutsEveryKindOfChunk() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    #expect(merge.chunks.map(\.kind) == [.conflict, .mine, .mine, .same, .conflict, .conflict])

    let imports = merge.chunks[0]
    #expect(imports.base.isEmpty)
    #expect(merge.lines(imports, mine: true) == ["import { log } from \"./log\""])
    #expect(merge.lines(imports, mine: false) == ["import { backoff } from \"./backoff\""])

    #expect(merge.lines(merge.chunks[1], mine: true) == ["const RETRY_MS = 500"])
    #expect(merge.lines(merge.chunks[2], mine: true) == ["    log(\"queued\")"])
    #expect(merge.lines(merge.chunks[3], mine: false) == ["    await api.post(change)"])
    #expect(merge.lines(merge.chunks[4], mine: false) == ["    attempt++", "    await sleep(backoff(attempt))"])

    let clear = merge.chunks[5]
    #expect(merge.lines(clear, mine: false).isEmpty)
    #expect(merge.baseLines(clear).count == 4 || merge.baseLines(clear).count == 5)
}

@Test func startsFromWhatGitMergedAlone() {
    let merge = ThreeWay(base: base, mine: mine, other: other)
    let lines = merge.start().flatMap { piece -> [String] in
        switch piece {
        case .stable(let lines), .chunk(_, let lines): lines
        }
    }
    let text = merge.text(lines)
    #expect(text.contains("const RETRY_MS = 500"))
    #expect(text.contains("log(\"queued\")"))
    #expect(text.contains("await api.post(change)"))
    // Conflicts keep the ancestor until you decide.
    #expect(text.contains("await sleep(DELAY)"))
    #expect(!text.contains("backoff"))
    #expect(text.hasSuffix("}\n"))

    let untouched = merge.start(applying: false).flatMap { piece -> [String] in
        switch piece {
        case .stable(let lines), .chunk(_, let lines): lines
        }
    }
    #expect(merge.text(untouched) == base)
}

@Test func changesFarApartDontConflict() {
    let merge = ThreeWay(base: "a\nb\nc\nd\ne\n", mine: "A\nb\nc\nd\ne\n", other: "a\nb\nc\nd\nE\n")
    #expect(merge.chunks.map(\.kind) == [.mine, .other])
    #expect(merge.chunks[1].mine == 4..<5)
}

@Test func changesOnTouchingLinesConflict() {
    let merge = ThreeWay(base: "a\nb\nc\n", mine: "A\nb\nc\n", other: "a\nB\nc\n")
    #expect(merge.chunks.map(\.kind) == [.conflict])
    #expect(merge.chunks[0].base == 0..<2)
    #expect(merge.lines(merge.chunks[0], mine: true) == ["A", "b"])
    #expect(merge.lines(merge.chunks[0], mine: false) == ["a", "B"])
}

@Test func linesShiftAfterEarlierChunks() {
    let merge = ThreeWay(base: "a\nb\nc\nd\ne\nf\n", mine: "x\ny\na\nb\nc\nd\ne\nF\n", other: "a\nb\nc\nd\ne\nG\n")
    #expect(merge.chunks.map(\.kind) == [.mine, .conflict])
    #expect(merge.chunks[1].mine == 7..<8)
    #expect(merge.chunks[1].other == 5..<6)
}

@Test func readsUnmergedStatusFromYourSide() {
    let output = """
    1 .M N... 100644 100644 100644 abc abc src/ok.ts
    u UU N... 100644 100644 100644 100644 a b c src/queue.ts
    u UD N... 100644 100644 000000 100644 a b c src/old sync.ts
    """
    let merge = Merge.parseStatus(output, .merge)
    #expect(merge == [.init(path: "src/queue.ts", status: .bothModified, base: .file, mine: .file, other: .file),
                      .init(path: "src/old sync.ts", status: .deletedByOther, base: .file, mine: .file, other: nil)])
    // During a rebase git's "us" is the branch being rebased onto.
    #expect(Merge.parseStatus(output, .rebase)[1].status == .deletedByMine)
}

@Test func namesTheMergedBranch() {
    #expect(Merge.mergedName("Merge branch 'main' into feat/x\n\n# Conflicts:") == "main")
    #expect(Merge.mergedName("Merge remote-tracking branch 'origin/main'") == "origin/main")
    #expect(Merge.mergedName("Merge commit 'abc123'") == "abc123")
    #expect(Merge.mergedName(nil) == nil)
}

// MARK: A real rebase

private func commit(_ message: String, in repo: String) throws {
    try Git.run(["add", "--all"], in: repo)
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "-m", message], in: repo)
}

@Test func resolvesARebaseStoppedOnAConflict() throws {
    let box = try Sandbox()
    let file = box.repo + "/queue.ts"
    try base.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("retry with fixed delay", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("exponential backoff", in: box.repo)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)

    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }

    let operation = try #require(Merge.operation(in: box.repo))
    #expect(operation.kind == .rebase)
    #expect(operation.mine == "feat/retry")
    #expect(operation.other == "main")
    #expect(operation.subject == "retry with fixed delay")
    #expect(operation.step == 1 && operation.total == 1)

    #expect(Merge.conflicts(in: box.repo, .rebase).map(\.path) == ["queue.ts"])
    #expect(Merge.conflicts(in: box.repo, .rebase).map(\.status) == [.bothModified])
    let versions = Merge.versions(of: "queue.ts", in: box.repo, .rebase)
    #expect(versions.base == base)
    #expect(versions.mine == mine)
    #expect(versions.other == other)

    try Merge.resolve("queue.ts", with: mine, in: box.repo)
    #expect(Merge.conflicts(in: box.repo, .rebase).isEmpty)
    // During a rebase HEAD is the branch being rebased onto, so the preview shows what your commit changes there.
    let resolved = Merge.resolvedPreview("queue.ts", in: box.repo)
    #expect(resolved.added > 0 && resolved.removed > 0)
    #expect(resolved.hunks[0].lines.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n") + "\n" == mine)
    try Merge.proceed(.rebase, in: box.repo)
    #expect(Merge.operation(in: box.repo) == nil)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == mine)
}

@Test func abortsAMerge() throws {
    let box = try Sandbox()
    let file = box.repo + "/queue.ts"
    try base.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("retry", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("backoff", in: box.repo)

    #expect(throws: GitError.self) { try Git.run(["merge", "--no-edit", "feat/retry"], in: box.repo) }
    let operation = try #require(Merge.operation(in: box.repo))
    #expect(operation.kind == .merge)
    #expect(operation.mine == "main")
    #expect(operation.other == "feat/retry")
    #expect(Merge.versions(of: "queue.ts", in: box.repo, .merge).mine == other)

    try Merge.abort(.merge, in: box.repo)
    #expect(Merge.operation(in: box.repo) == nil)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == other)
}

@Test func previewsAWholeFileChoice() {
    let base = "export const store = new Map()\n"
    let kept = Merge.preview("store.ts", from: base, to: "export const store = new Map()\nexport const tags = new Map()\n")
    #expect(kept.status == .modified)
    #expect(kept.hunks[0].lines.map(\.kind) == [.context, .added])
    #expect(kept.hunks[0].lines[1].number == 2)

    let deleted = Merge.preview("store.ts", from: base, to: nil)
    #expect(deleted.status == .deleted)
    #expect(deleted.removed == 1 && deleted.added == 0)

    #expect(Merge.preview("config.json", from: nil, to: "{}\n").status == .added)
}

@Test func acceptsOneWholeSideDuringARebase() throws {
    for takeMine in [true, false] {
        let box = try Sandbox()
        let file = box.repo + "/queue.ts"
        try base.write(toFile: file, atomically: true, encoding: .utf8)
        try commit("queue", in: box.repo)
        try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
        try mine.write(toFile: file, atomically: true, encoding: .utf8)
        try commit("retry", in: box.repo)
        try Git.run(["switch", "--quiet", "main"], in: box.repo)
        try other.write(toFile: file, atomically: true, encoding: .utf8)
        try commit("backoff", in: box.repo)
        try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)
        #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }

        try Merge.take(mine: takeMine, "queue.ts", in: box.repo, .rebase)
        #expect(Merge.conflicts(in: box.repo, .rebase).isEmpty)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == (takeMine ? mine : other))
    }
}

@Test func findsNamesNoLongerDeclared() {
    let base = "const DELAY = 500\nawait sleep(DELAY)\n"
    let mine = "const RETRY_MS = 500\nawait sleep(RETRY_MS)\n"
    let other = "const DELAY = 500\nget delay() { return DELAY }\nawait sleep(DELAY)\n"
    // Git took the rename from one side and the new use from the other.
    let result = "const RETRY_MS = 500\nget delay() { return DELAY }\nawait sleep(RETRY_MS)\n"
    #expect(Merge.undeclared(in: result, versions: [base, mine, other]) == [.init(name: "DELAY", line: 2)])
    #expect(Merge.undeclared(in: mine, versions: [base, mine, other]).isEmpty)
    // A name nothing uses anymore is fine.
    #expect(Merge.undeclared(in: "const RETRY_MS = 500\n", versions: [base]).isEmpty)
}

@Test func guessesTheTestCommand() throws {
    let box = try Sandbox()
    #expect(Merge.testCommand(in: box.repo) == nil)
    try "{\"scripts\": {\"test\": \"vitest\"}}".write(toFile: box.repo + "/package.json", atomically: true, encoding: .utf8)
    #expect(Merge.testCommand(in: box.repo) == "npm test")
    try "".write(toFile: box.repo + "/pnpm-lock.yaml", atomically: true, encoding: .utf8)
    #expect(Merge.testCommand(in: box.repo) == "pnpm test")
    try "build:\n\tswift build\ntest:\n\tswift test\n".write(toFile: box.repo + "/Makefile", atomically: true, encoding: .utf8)
    #expect(Merge.testCommand(in: box.repo) == "make test")
}

@Test func reopensAResolvedFile() throws {
    let box = try Sandbox()
    let file = box.repo + "/queue.ts"
    try base.write(toFile: file, atomically: true, encoding: .utf8)
    try "export const store = new Map()\n".write(toFile: box.repo + "/store.ts", atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: file, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(atPath: box.repo + "/store.ts")
    try commit("retry", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: file, atomically: true, encoding: .utf8)
    try "export const store = new Map()\nexport const tags = new Map()\n".write(toFile: box.repo + "/store.ts", atomically: true, encoding: .utf8)
    try commit("backoff", in: box.repo)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)
    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }

    try Merge.resolve("queue.ts", with: mine, in: box.repo)
    try Merge.delete("store.ts", in: box.repo)
    #expect(Merge.conflicts(in: box.repo, .rebase).isEmpty)

    try Merge.reopen("queue.ts", in: box.repo)
    try Merge.reopen("store.ts", in: box.repo)
    let conflicts = Merge.conflicts(in: box.repo, .rebase)
    #expect(conflicts.contains { $0.path == "queue.ts" && $0.status == .bothModified })
    #expect(conflicts.contains { $0.path == "store.ts" && $0.status == .deletedByMine })
    #expect(Merge.versions(of: "queue.ts", in: box.repo, .rebase).mine == mine)
    #expect(try String(contentsOfFile: file, encoding: .utf8).contains("<<<<<<<"))
}

@Test func continuesWithAMessageOfYours() throws {
    for kind in [Merge.Kind.merge, .rebase] {
        let box = try Sandbox()
        let file = box.repo + "/queue.ts"
        try base.write(toFile: file, atomically: true, encoding: .utf8)
        try commit("queue", in: box.repo)
        try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
        try mine.write(toFile: file, atomically: true, encoding: .utf8)
        try commit("retry with fixed delay", in: box.repo)
        try Git.run(["switch", "--quiet", "main"], in: box.repo)
        try other.write(toFile: file, atomically: true, encoding: .utf8)
        try commit("exponential backoff", in: box.repo)
        if kind == .merge {
            #expect(throws: GitError.self) { try Git.run(["merge", "--no-edit", "feat/retry"], in: box.repo) }
            #expect(Merge.message(in: box.repo) == "Merge branch 'feat/retry'")
        } else {
            try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)
            #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
            #expect(Merge.message(in: box.repo) == "retry with fixed delay")
        }

        try Merge.resolve("queue.ts", with: mine, in: box.repo)
        try Merge.proceed(kind, message: "Keep the fixed delay\n\nIt's what the server expects.", in: box.repo)
        #expect(Merge.operation(in: box.repo) == nil)
        #expect(try Git.run(["log", "-1", "--format=%B"], in: box.repo).trimmingCharacters(in: .whitespacesAndNewlines)
            == "Keep the fixed delay\n\nIt's what the server expects.")
    }
}

@Test func listsTheStepsOfARebase() throws {
    let box = try Sandbox()
    let file = box.repo + "/queue.ts"
    try base.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("retry with fixed delay", in: box.repo)
    try "notes\n".write(toFile: box.repo + "/notes.md", atomically: true, encoding: .utf8)
    try commit("add notes", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("exponential backoff", in: box.repo)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)

    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
    let steps = Merge.rebaseSteps(in: box.repo)
    #expect(steps.map(\.subject) == ["retry with fixed delay", "add notes"])
    #expect(steps.map(\.state) == [.current, .todo])
    #expect(steps.allSatisfy { $0.hash.count == 7 })
}

@Test func spotsAFileResolvedLikeLastTime() throws {
    let box = try Sandbox()
    let file = box.repo + "/queue.ts"
    try Git.run(["config", "rerere.enabled", "true"], in: box.repo)
    try base.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("retry with fixed delay", in: box.repo)
    let original = try Git.run(["rev-parse", "HEAD"], in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: file, atomically: true, encoding: .utf8)
    try commit("exponential backoff", in: box.repo)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)

    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
    #expect(Merge.reused(Merge.conflicts(in: box.repo, .rebase), in: box.repo).isEmpty)
    try Merge.resolve("queue.ts", with: mine, in: box.repo)
    try Merge.proceed(.rebase, in: box.repo)

    // The same rebase again: rerere puts back what you chose, and the file is still listed until you look.
    try Git.run(["reset", "--quiet", "--hard", original], in: box.repo)
    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
    let conflicts = Merge.conflicts(in: box.repo, .rebase)
    #expect(conflicts.map(\.path) == ["queue.ts"])
    #expect(Merge.reused(conflicts, in: box.repo) == ["queue.ts"])
    #expect(try String(contentsOfFile: file, encoding: .utf8) == mine)
}

// MARK: Other kinds of conflicts

/// Two branches off "main" that each change `name` their own way, then a merge of `side` into main that stops.
private func conflicted(_ box: Sandbox, _ name: String, base: (String) throws -> Void, mine: (String) throws -> Void,
                        other: (String) throws -> Void) throws {
    let path = box.repo + "/" + name
    try base(path)
    try commit("base", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "side"], in: box.repo)
    try other(path)
    try commit("other", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try mine(path)
    try commit("mine", in: box.repo)
    #expect(throws: GitError.self) { try Git.run(["merge", "--no-edit", "side"], in: box.repo) }
}

private func write(_ text: String) -> (String) throws -> Void {
    { try text.write(toFile: $0, atomically: true, encoding: .utf8) }
}

private func link(to target: String) -> (String) throws -> Void {
    { path in
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
}

private func executable(_ text: String, _ on: Bool) -> (String) throws -> Void {
    { path in
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: on ? 0o755 : 0o644], ofItemAtPath: path)
    }
}

@Test func readsEntriesFromTheModes() {
    // As git status --porcelain=v2 prints them for a link, a submodule and a file only one side made executable.
    let output = """
    u UU N... 120000 120000 120000 120000 2e65efe 3410062 63d8dbd link
    u UU S... 160000 160000 160000 160000 e675818 7a12427 04c98ec vendor/lib
    u AA N... 000000 100644 100755 100644 0000000 587be6b 587be6b run.sh
    u UA N... 000000 000000 120000 120000 0000000 0000000 63d8dbd p
    """
    let conflicts = Merge.parseStatus(output, .merge)
    #expect(conflicts.map(\.path) == ["link", "vendor/lib", "run.sh", "p"])
    #expect(conflicts.allSatisfy { !$0.isTextual })
    #expect(conflicts[0].mine == .symlink && conflicts[1].other == .submodule)
    #expect(conflicts[2].sameContent && conflicts[2].modeConflict && conflicts[2].other == .executable)
    #expect(conflicts[3].status == .addedByOther && conflicts[3].mine == nil)
    // During a rebase the incoming side is git's ours.
    #expect(Merge.parseStatus(output, .rebase)[2].mine == .executable)
}

@Test func takesAWholeLink() throws {
    let box = try Sandbox()
    try conflicted(box, "current", base: link(to: "v1"), mine: link(to: "v2"), other: link(to: "v3"))
    let conflict = try #require(Merge.conflicts(in: box.repo, .merge).first)
    #expect(conflict.mine == .symlink && !conflict.isTextual)
    #expect(Merge.versions(of: "current", in: box.repo, .merge).other == "v3")

    try Merge.take(mine: false, "current", in: box.repo, .merge)
    #expect(Merge.conflicts(in: box.repo, .merge).isEmpty)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.repo + "/current") == "v3")
}

@Test func takesAWholeSubmodule() throws {
    let box = try Sandbox()
    let library = box.repo + "-lib"
    try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
    try Git.run(["init", "--quiet", "--initial-branch=main"], in: library)
    try write("1\n")(library + "/a")
    try commit("one", in: library)
    var commits: [String] = []
    for n in 2...3 {
        try Git.run(["switch", "--quiet", "--create", "b\(n)", "main"], in: library)
        try write("\(n)\n")(library + "/a")
        try commit("\(n)", in: library)
        commits.append(try Git.run(["rev-parse", "HEAD"], in: library))
    }
    try Git.run(["switch", "--quiet", "main"], in: library)
    try Git.run(["-c", "protocol.file.allow=always", "submodule", "add", "--quiet", library, "lib"], in: box.repo)
    func move(to commit: String) -> (String) throws -> Void {
        { _ in try Git.run(["checkout", "--quiet", commit], in: box.repo + "/lib") }
    }
    try conflicted(box, "lib", base: { _ in }, mine: move(to: commits[0]), other: move(to: commits[1]))

    let conflict = try #require(Merge.conflicts(in: box.repo, .merge).first)
    #expect(conflict.path == "lib" && conflict.mine == .submodule && !conflict.isTextual)
    #expect(Merge.versions(of: "lib", in: box.repo, .merge).other == "Subproject commit \(commits[1])\n")

    try Merge.take(mine: false, "lib", in: box.repo, .merge)
    #expect(Merge.conflicts(in: box.repo, .merge).isEmpty)
    #expect(try Git.run(["ls-files", "--stage", "lib"], in: box.repo).hasPrefix("160000 \(commits[1]) 0"))
}

@Test func settlesTheFileMode() throws {
    // Same content, each side its own mode: only the mode is left to pick.
    let box = try Sandbox()
    let readme: (String) throws -> Void = { _ in try write("notes\n")(box.repo + "/readme") }
    try conflicted(box, "run.sh", base: readme, mine: executable("echo hi\n", false), other: executable("echo hi\n", true))
    let modeOnly = try #require(Merge.conflicts(in: box.repo, .merge).first)
    #expect(modeOnly.modeConflict && modeOnly.sameContent && !modeOnly.isTextual)
    try Merge.take(mine: false, "run.sh", in: box.repo, .merge)
    #expect(try Git.run(["ls-files", "--stage", "run.sh"], in: box.repo).hasPrefix("100755"))

    // Different content too: the text is merged in the columns and the mode is picked apart.
    let other = try Sandbox()
    try conflicted(other, "run.sh", base: { _ in try write("notes\n")(other.repo + "/readme") },
                   mine: executable("echo mine\n", false), other: executable("echo theirs\n", true))
    let both = try #require(Merge.conflicts(in: other.repo, .merge).first)
    #expect(both.modeConflict && both.isTextual)
    try Merge.resolve("run.sh", with: "echo both\n", executable: true, in: other.repo)
    #expect(try Git.run(["ls-files", "--stage", "run.sh"], in: other.repo).hasPrefix("100755"))
}

@Test func listsRenameConflicts() throws {
    let box = try Sandbox()
    try conflicted(box, "f.txt", base: write("a\nb\nc\n"),
                   mine: { try Git.run(["mv", $0, box.repo + "/mine.txt"], in: box.repo) },
                   other: { try Git.run(["mv", $0, box.repo + "/theirs.txt"], in: box.repo) })
    // Git reports a rename on both sides as the old path deleted by both, and each new path added by one side.
    let conflicts = Dictionary(uniqueKeysWithValues: Merge.conflicts(in: box.repo, .merge).map { ($0.path, $0.status) })
    #expect(conflicts == ["f.txt": .bothDeleted, "mine.txt": .addedByMine, "theirs.txt": .addedByOther])

    let deleted = try Sandbox()
    try conflicted(deleted, "f.txt", base: write("a\nb\nc\n"), mine: { try FileManager.default.removeItem(atPath: $0) },
                   other: { try Git.run(["mv", $0, deleted.repo + "/g.txt"], in: deleted.repo) })
    #expect(Merge.conflicts(in: deleted.repo, .merge).map(\.status) == [.deletedByMine])
    #expect(Merge.conflicts(in: deleted.repo, .merge).map(\.path) == ["g.txt"])
}

// MARK: Patches

/// A branch "feat/retry" with two commits, the first of which conflicts with main.
private func twoCommits(_ box: Sandbox) throws {
    try base.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("retry with fixed delay", in: box.repo)
    try "notes\n".write(toFile: box.repo + "/notes.md", atomically: true, encoding: .utf8)
    try commit("add notes", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("exponential backoff", in: box.repo)
}

@Test func followsARebaseWithTheApplyBackend() throws {
    let box = try Sandbox()
    try twoCommits(box)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)
    #expect(throws: GitError.self) { try Git.run(["rebase", "--apply", "main"], in: box.repo) }

    let operation = try #require(Merge.operation(in: box.repo))
    #expect(operation.kind == .rebase && operation.step == 1 && operation.total == 2)
    #expect(operation.subject == "retry with fixed delay")
    let steps = Merge.rebaseSteps(in: box.repo)
    #expect(steps.map(\.subject) == ["retry with fixed delay", "add notes"])
    #expect(steps.map(\.state) == [.current, .todo])
    #expect(steps.allSatisfy { $0.hash.count == 7 })
    #expect(Merge.versions(of: "queue.ts", in: box.repo, .rebase).mine == mine)
    #expect(Merge.message(in: box.repo) == "retry with fixed delay")

    try Merge.resolve("queue.ts", with: mine, in: box.repo)
    try Merge.proceed(.rebase, message: "Keep the fixed delay", in: box.repo)
    #expect(Merge.operation(in: box.repo) == nil)
    #expect(try Git.run(["log", "--format=%s", "-2"], in: box.repo) == "add notes\nKeep the fixed delay")
}

@Test func followsGitAm() throws {
    let box = try Sandbox()
    try twoCommits(box)
    let patches = box.repo + "-patches"
    try Git.run(["format-patch", "--quiet", "-o", patches, "main..feat/retry"], in: box.repo)
    let files = try FileManager.default.contentsOfDirectory(atPath: patches).sorted().map { patches + "/" + $0 }
    #expect(throws: GitError.self) { try Git.run(["am", "-3"] + files, in: box.repo) }

    let operation = try #require(Merge.operation(in: box.repo))
    #expect(operation.kind == .am && operation.step == 1 && operation.total == 2)
    #expect(operation.subject == "retry with fixed delay")
    #expect(operation.mine == "main" && operation.other.count == 7)
    #expect(Merge.rebaseSteps(in: box.repo).map(\.subject) == ["retry with fixed delay", "add notes"])
    // Your branch is git's ours here, like a cherry-pick.
    #expect(Merge.versions(of: "queue.ts", in: box.repo, .am).mine == other)
    #expect(Merge.edited(Merge.conflicts(in: box.repo, .am), in: box.repo, .am).isEmpty)

    try Merge.resolve("queue.ts", with: mine, in: box.repo)
    try Merge.proceed(.am, message: "Take the fixed delay", in: box.repo)
    #expect(Merge.operation(in: box.repo) == nil)
    #expect(try Git.run(["log", "--format=%s", "-2"], in: box.repo) == "add notes\nTake the fixed delay")
}

@Test func readsAMailedPatch() {
    let mail = "From 58d05e8f2a8ea7f624988d9776a4874117d6c9e9 Mon Sep 17 00:00:00 2001\nFrom: a <a@a>\n"
        + "Subject: [PATCH 1/2] retry with a fixed delay\n and a longer subject\n\nBody\nSubject: not this\n"
    let patch = Merge.patch(mail)
    #expect(patch.hash == "58d05e8")
    #expect(patch.subject == "retry with a fixed delay and a longer subject")
}

// MARK: Work done outside Farol

private func mergeStopped(_ box: Sandbox) throws {
    try base.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("retry", in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("backoff", in: box.repo)
    #expect(throws: GitError.self) { try Git.run(["merge", "--no-edit", "feat/retry"], in: box.repo) }
}

@Test func spotsAFileEditedOnDisk() throws {
    for style in ["merge", "zdiff3"] {
        let box = try Sandbox()
        try Git.run(["config", "merge.conflictStyle", style], in: box.repo)
        try mergeStopped(box)
        let file = box.repo + "/queue.ts"
        let conflicts = Merge.conflicts(in: box.repo, .merge)
        #expect(Merge.edited(conflicts, in: box.repo, .merge).isEmpty)

        // An agent settles the first conflict by hand and leaves the others.
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("<<<<<<<") })
        let end = try #require(lines.firstIndex { $0.hasPrefix(">>>>>>>") })
        let settled = lines[..<start] + ["import { log } from \"./log\""] + lines[(end + 1)...]
        try settled.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        let markers = text.components(separatedBy: "\n").filter { $0.hasPrefix("<<<<<<<") }.count
        #expect(Merge.edited(conflicts, in: box.repo, .merge) == ["queue.ts": markers - 1])

        // Resolved by hand, not staged.
        try mine.write(toFile: file, atomically: true, encoding: .utf8)
        #expect(Merge.edited(conflicts, in: box.repo, .merge) == ["queue.ts": 0])
        #expect(Merge.edited(conflicts, skipping: ["queue.ts"], in: box.repo, .merge).isEmpty)

        // Git writing the markers again with its own labels is not an edit.
        try Git.run(["checkout", "--merge", "--", "queue.ts"], in: box.repo)
        #expect(Merge.edited(conflicts, in: box.repo, .merge).isEmpty)
    }
}

@Test func editsDuringARebaseCompareWithTheRebase() throws {
    let box = try Sandbox()
    try twoCommits(box)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)
    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
    let conflicts = Merge.conflicts(in: box.repo, .rebase)
    #expect(Merge.edited(conflicts, in: box.repo, .rebase).isEmpty)
    try (try String(contentsOfFile: box.repo + "/queue.ts", encoding: .utf8) + "// note\n")
        .write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    #expect(Merge.edited(conflicts, in: box.repo, .rebase).keys.sorted() == ["queue.ts"])
}

@Test func listsFilesRerereStagedItself() throws {
    let box = try Sandbox()
    try Git.run(["config", "rerere.enabled", "true"], in: box.repo)
    try Git.run(["config", "rerere.autoUpdate", "true"], in: box.repo)
    try base.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try "a\nb\nc\n".write(toFile: box.repo + "/fresh.txt", atomically: true, encoding: .utf8)
    try commit("queue", in: box.repo)
    try Git.run(["switch", "--quiet", "--create", "feat/retry"], in: box.repo)
    try mine.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("retry with fixed delay", in: box.repo)
    let original = try Git.run(["rev-parse", "HEAD"], in: box.repo)
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try other.write(toFile: box.repo + "/queue.ts", atomically: true, encoding: .utf8)
    try commit("exponential backoff", in: box.repo)
    try Git.run(["switch", "--quiet", "feat/retry"], in: box.repo)

    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
    #expect(Merge.restagedByRerere(Merge.conflicts(in: box.repo, .rebase), in: box.repo, .rebase).isEmpty)
    try Merge.resolve("queue.ts", with: mine, in: box.repo)
    // Resolved here and staged, but rerere hasn't reused anything for it.
    #expect(Merge.restagedByRerere([], in: box.repo, .rebase).isEmpty)
    try Merge.proceed(.rebase, in: box.repo)

    try Git.run(["reset", "--quiet", "--hard", original], in: box.repo)
    // The commit and the branch now meet only in git's rerere: git stages the file and lists nothing as unmerged.
    #expect(throws: GitError.self) { try History.rebase(onto: "main", in: box.repo) }
    let conflicts = Merge.conflicts(in: box.repo, .rebase)
    #expect(conflicts.isEmpty)
    #expect(Merge.restagedByRerere(conflicts, in: box.repo, .rebase) == ["queue.ts"])
}

@Test func makesTheImageRerereStores() {
    let text = "a\n<<<<<<< HEAD\nzeta\n||||||| base\nold\n=======\nalpha\n>>>>>>> side\nc\n"
    #expect(Merge.rerereImage(text) == "a\n<<<<<<<\nalpha\n=======\nzeta\n>>>>>>>\nc\n")
    #expect(Merge.unlabeled("<<<<<<< ours\nx\n=======\ny\n>>>>>>> 1234 (fix)\n") == "<<<<<<<\nx\n=======\ny\n>>>>>>>\n")
}

// MARK: Names

@Test func leavesOutNamesDeclaredSomeOtherWay() {
    func check(_ base: String, _ result: String) -> [String] {
        Merge.undeclared(in: result, versions: [base]).map(\.name)
    }
    // Now imported from another file.
    #expect(check("const DELAY = 500\nsleep(DELAY)\n", "import { DELAY } from \"./config\"\nsleep(DELAY)\n").isEmpty)
    #expect(check("DELAY = 500\ndef f(): pass\n", "from config import DELAY as DELAY\nsleep(DELAY)\n").isEmpty)
    #expect(check("const DELAY = 500\n", "use crate::config::{DELAY, RETRY};\nsleep(DELAY);\n").isEmpty)
    // Only in a string, a comment or after a dot.
    #expect(check("const DELAY = 500\n", "const RETRY = 1\nlog(\"DELAY changed\")\n// DELAY was here\nthis.DELAY = 2\n").isEmpty)
    #expect(check("let count = 0\n", "/* count\n is gone */\nconfig.count += 1\n").isEmpty)
    // A parameter, a destructured name or a loop variable now.
    #expect(check("const change = 1\n", "function push(change) {\n  queue.add(change)\n}\n").isEmpty)
    #expect(check("const change = 1\n", "func push(_ change: Change) {\n    queue.add(change)\n}\n").isEmpty)
    #expect(check("const size = 1\n", "const { size, tail } = queue\nlog(size)\n").isEmpty)
    #expect(check("let item = 1\n", "for item in items {\n    print(item)\n}\n").isEmpty)
    #expect(check("const total = 0\n", "items.map((total) => total + 1)\n").isEmpty)
    // An argument label or an object key isn't a use.
    #expect(check("let delay = 1\n", "retry(delay: 2)\nconst options = { delay: 3 }\n").isEmpty)
    // Keywords a declaration pattern could take for a name.
    #expect(check("class func make() {}\n", "func other() {}\n").isEmpty)

    // Still found: a use in code, and one inside a string's interpolation.
    #expect(check("const DELAY = 500\n", "await sleep(DELAY)\n") == ["DELAY"])
    #expect(check("let delay = 1\n", "print(\"waiting \\(delay)\")\n") == ["delay"])
    #expect(check("const delay = 1\n", "log(`waiting ${delay}`)\n") == ["delay"])
    #expect(check("import { log } from \"./log\"\n", "log(\"queued\")\n") == ["log"])
}

// MARK: Whitespace

@Test func ignoresWhitespaceWhenAsked() {
    let base = "if ready {\n  run()\n}\n"
    // Both sides only reindented, each its own way: yours is taken.
    let reindented = ThreeWay(base: base, mine: "if ready {\n    run()\n}\n", other: "if ready {\n\trun()\n}\n", ignoringWhitespace: true)
    #expect(reindented.chunks.map(\.kind) == [.mine])
    #expect(ThreeWay(base: base, mine: "if ready {\n    run()\n}\n", other: "if ready {\n\trun()\n}\n").chunks.map(\.kind) == [.conflict])

    // One side reindented and the other changed the code: the real change wins.
    let changed = ThreeWay(base: base, mine: "if ready {\n    run()\n}\n", other: "if ready {\n  run(now: true)\n}\n", ignoringWhitespace: true)
    #expect(changed.chunks.map(\.kind) == [.other])
    #expect(changed.lines(changed.chunks[0], mine: false) == ["  run(now: true)"])

    // The same change, formatted differently, also across a line break, counts as made alike.
    let alike = ThreeWay(base: base, mine: "if ready {\n  run(a,\n      b)\n}\n", other: "if ready {\n  run(a, b)\n}\n", ignoringWhitespace: true)
    #expect(alike.chunks.map(\.kind) == [.same])

    // Real changes on both sides stay a conflict.
    let both = ThreeWay(base: base, mine: "if ready {\n  run(1)\n}\n", other: "if ready {\n  run(2)\n}\n", ignoringWhitespace: true)
    #expect(both.chunks.map(\.kind) == [.conflict])
}
