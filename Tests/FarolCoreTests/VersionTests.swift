import Testing
@testable import FarolCore

@Test func laterReleasesAreNewer() {
    #expect(Version.isNewer("v0.5.0", than: "0.4.1"))
    #expect(Version.isNewer("0.4.2", than: "0.4.1"))
    #expect(Version.isNewer("1.0.0", than: "0.9.9"))
    #expect(Version.isNewer("0.10.0", than: "0.9.0"))
}

@Test func sameOrOlderIsNotNewer() {
    #expect(!Version.isNewer("v0.4.1", than: "0.4.1"))
    #expect(!Version.isNewer("0.4.0", than: "0.4.1"))
    #expect(!Version.isNewer("0.3.9", than: "1.0.0"))
}

@Test func developmentBuildsCountAsTheirBase() {
    #expect(!Version.isNewer("v0.4.1", than: "0.4.1-3-gabc1234-dirty"))
    #expect(Version.isNewer("v0.4.2", than: "0.4.1-3-gabc1234"))
}

@Test func unreadableVersionsNeverOfferAnUpdate() {
    #expect(!Version.isNewer("latest", than: "0.4.1"))
    #expect(!Version.isNewer("v0.5.0", than: "dev"))
    #expect(!Version.isNewer("v0.5", than: "0.4.1"))
}
