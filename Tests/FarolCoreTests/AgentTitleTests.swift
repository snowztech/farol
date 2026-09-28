import Testing
@testable import FarolCore

@Test func dropsAgentStatusGlyphs() {
    #expect(AgentTitle.withoutStatus("✳ Claude Code") == "Claude Code")
    #expect(AgentTitle.withoutStatus("⠋ Fixing the login bug") == "Fixing the login bug")
}

/// Codex titles are "<conversation> | <project>", and the first part is empty until the conversation has a name.
@Test func keepsOnlyTheFirstPart() {
    #expect(AgentTitle.withoutStatus("Design codebase | farol") == "Design codebase")
    #expect(AgentTitle.withoutStatus(" | farol") == "farol")
    #expect(AgentTitle.withoutStatus("⠋ | farol") == "farol")
    #expect(AgentTitle.withoutStatus("Fix login · api") == "Fix login")
}

@Test func leavesOrdinaryTitlesAlone() {
    #expect(AgentTitle.withoutStatus("vim src/main.swift") == "vim src/main.swift")
    #expect(AgentTitle.withoutStatus("npm run dev") == "npm run dev")
    #expect(AgentTitle.withoutStatus("git log a|b") == "git log a|b")
}
