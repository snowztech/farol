import Testing
@testable import FarolCore

/// Each item is (name, repo).
private func grouped(_ items: [(String, String?)]) -> [[String]] {
    Grouping.group(items, by: \.1).map { [$0.key ?? "-"] + $0.items.map(\.0) }
}

@Test func oneRepoStaysFlat() {
    #expect(grouped([("a", "farol"), ("b", nil), ("c", "farol")]) == [["-", "a", "b", "c"]])
}

@Test func severalReposGetSections() {
    let result = grouped([("a", "farol"), ("b", "vikusha"), ("c", "farol"), ("d", nil)])
    #expect(result == [["-", "d"], ["farol", "a", "c"], ["vikusha", "b"]])
}

@Test func sectionsFollowFirstAppearance() {
    #expect(grouped([("a", "vikusha"), ("b", "farol")]).map(\.first) == ["vikusha", "farol"])
}

@Test func noSessionsGiveOneEmptyGroup() {
    #expect(grouped([]) == [["-"]])
}
