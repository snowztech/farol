import Testing
@testable import FarolCore

@Test func readsAndWritesAThemeForEachAppearance() {
    let pair = ThemePair("light:Farol Dawn,dark:Farol Dusk")
    #expect(pair == ThemePair(light: "Farol Dawn", dark: "Farol Dusk"))
    #expect(pair?.value == "light:Farol Dawn,dark:Farol Dusk")
    #expect(pair?.theme(dark: true) == "Farol Dusk")
    // Either order and spaces around the parts, as a hand-written config may have them.
    #expect(ThemePair(" dark: Nord , light: Nord Light ") == ThemePair(light: "Nord Light", dark: "Nord"))
}

@Test func aSingleThemeOrAHalfPairIsNoPair() {
    #expect(ThemePair("Farol Beam") == nil)
    #expect(ThemePair("") == nil)
    #expect(ThemePair("light:Farol Dawn") == nil)
    #expect(ThemePair("light:,dark:Farol Dusk") == nil)
}
