import Foundation
import Testing
@testable import FarolCore

private func commands() -> SavedCommands {
    SavedCommands(defaults: UserDefaults(suiteName: "farol-tests-\(UUID().uuidString)")!)
}

@Test func aCommandShowsInItsFolderAndBelowIt() {
    let saved = commands()
    saved.save(SavedCommand(name: "Tests", command: "make test", folder: "/code/farol"))
    #expect(saved.available(in: "/code/farol").map(\.name) == ["Tests"])
    #expect(saved.available(in: "/code/farol/Sources").map(\.name) == ["Tests"])
    #expect(saved.available(in: "/code/farolette").isEmpty)
    #expect(saved.available(in: "/code").isEmpty)
}

@Test func theClosestFolderComesFirst() {
    let saved = commands()
    saved.save(SavedCommand(name: "b", command: "ls", folder: "/code"))
    saved.save(SavedCommand(name: "z", command: "ls", folder: "/code/farol"))
    saved.save(SavedCommand(name: "a", command: "ls", folder: "/code/farol"))
    #expect(saved.available(in: "/code/farol/").map(\.name) == ["a", "z", "b"])
}

@Test func editingReplacesAndRemovingForgets() {
    let saved = commands()
    let first = SavedCommand(name: "Run", command: "make run", folder: "/code")
    saved.save(first)
    saved.save(SavedCommand(name: " Build ", command: "make build\n", folder: "/code"), replacing: first)
    #expect(saved.all == [SavedCommand(name: "Build", command: "make build", folder: "/code")])
    saved.remove(saved.all[0])
    #expect(saved.all.isEmpty)
}

@Test func aCommandNeedsANameAndSomethingToRun() {
    let saved = commands()
    saved.save(SavedCommand(name: " ", command: "ls", folder: "/code"))
    saved.save(SavedCommand(name: "List", command: "", folder: "/code"))
    #expect(saved.all.isEmpty)
}
