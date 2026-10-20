import Foundation
import Testing
@testable import FarolCore

private func project(_ files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farol-project-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    for (path, text) in files {
        let file = root + "/" + path
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }
    return URL(fileURLWithPath: root).standardizedFileURL.path
}

@Test func makefileTargetsAreTheOnesAPersonRuns() {
    let makefile = """
    APP := build/Farol.app
    X ::= y
    .PHONY: build test
    build: $(GHOSTTY)
    \t./scripts/bundle.sh debug
    test lint:
    $(GHOSTTY):
    %.o: %.c
    main.o: main.c
    build/out: src
    install:: build
    """
    #expect(ProjectCommands.targets(inMakefile: makefile) == ["build", "test", "lint", "install"])
}

@Test func justRecipesRunWithoutArguments() {
    let justfile = """
    set shell := ["bash", "-c"]
    alias t := test
    # Runs the tests
    test:
        cargo test
    @lint: test
    deploy env:
    _private:
    [group('dev')]
    serve:
    """
    #expect(ProjectCommands.recipes(inJustfile: justfile) == ["test", "lint", "serve"])
}

@Test func packageScriptsKeepTheirOrderAndRunner() throws {
    let root = try project([
        "package.json": #"{ "name": "app", "scripts": { "dev": "vite", "build": "vite build", "test": "vitest" } }"#,
        "pnpm-lock.yaml": "",
    ])
    #expect(ProjectCommands.find(in: root, top: root).map(\.command) == ["pnpm run dev", "pnpm run build", "pnpm run test"])
    #expect(ProjectCommands.packageManager(in: try project(["package.json": "{}"])) == "npm")
}

@Test func theClosestFolderComesFirstUpToTheCheckout() throws {
    let root = try project([
        "Makefile": "test:\nbuild:\n",
        "ui/package.json": #"{ "scripts": { "build": "vite build" } }"#,
        "ui/yarn.lock": "",
    ])
    let found = ProjectCommands.find(in: root + "/ui", top: root)
    #expect(found.map(\.command) == ["yarn run build", "make test", "make build"])
    #expect(found.map(\.source) == ["package.json", "Makefile", "Makefile"])
    // Outside a checkout, only the folder itself.
    #expect(ProjectCommands.find(in: root + "/ui", top: nil).map(\.command) == ["yarn run build"])
}

@Test func aCommandFromAnotherFolderRunsThereInASubshell() {
    let command = ProjectCommand(name: "test", command: "make test", folder: "/repo", source: "Makefile")
    #expect(command.line(from: "/repo") == "make test")
    #expect(command.line(from: "/repo/ui") == "(cd '/repo' && make test)")
}

@Test func savedCommandRunsFromItsProjectFolder() throws {
    let root = try project(["ui/package.json": #"{ "scripts": { "dev": "vite" } }"#])
    try ProjectCommands.save(name: "Preview site", script: "npm run dev", in: root)
    try FileManager.default.createDirectory(atPath: root + "/.farol/commands/not-a-command.sh", withIntermediateDirectories: true)
    let path = root + "/.farol/commands/Preview site.sh"
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "npm run dev\n")
    let found = ProjectCommands.find(in: root + "/ui", top: root)
    #expect(found.map(\.name) == ["dev", "Preview site"])
    #expect(found[1].line(from: root + "/ui") == "(cd '\(root)' && sh '.farol/commands/Preview site.sh')")
}

@Test func savedCommandNamesCannotEscapeTheirFolderOrOverwrite() throws {
    let root = try project([:])
    #expect(throws: ProjectCommands.SaveError.self) {
        try ProjectCommands.save(name: "../outside", script: "echo hi", in: root)
    }
    try ProjectCommands.save(name: "build", script: "echo hi", in: root)
    #expect(throws: ProjectCommands.SaveError.self) {
        try ProjectCommands.save(name: "build", script: "echo again", in: root)
    }
}
