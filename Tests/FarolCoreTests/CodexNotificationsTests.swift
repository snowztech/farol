import Testing
@testable import FarolCore

private let config = """
    model = "gpt-5.5"

    [projects."/Users/me/app"]
    trust_level = "trusted"

    [tui]
    screen_reader_detection_done = true

    [tui.model_availability_nux]
    "gpt-5.5" = 4

    """

@Test func addsKeysAtTheEndOfTUI() throws {
    let enabled = try CodexNotifications.enable(in: config)
    #expect(CodexNotifications.isEnabled(in: enabled))
    #expect(enabled.contains("""
        screen_reader_detection_done = true
        notifications = true # added by Farol
        notification_method = "osc9" # added by Farol
        notification_condition = "always" # added by Farol

        [tui.model_availability_nux]
        """))
}

@Test func turningOffGivesBackTheSameFile() throws {
    #expect(CodexNotifications.disable(in: try CodexNotifications.enable(in: config)) == config)
    #expect(CodexNotifications.disable(in: try CodexNotifications.enable(in: "")) == "")
    let noTUI = "model = \"gpt-5.5\"\n"
    #expect(CodexNotifications.disable(in: try CodexNotifications.enable(in: noTUI)) == noTUI)
}

@Test func createsTUIWhenMissing() throws {
    let enabled = try CodexNotifications.enable(in: "model = \"gpt-5.5\"\n")
    #expect(enabled.hasPrefix("model = \"gpt-5.5\"\n\n[tui] # added by Farol\nnotifications = true"))
    #expect(CodexNotifications.isEnabled(in: enabled))
}

@Test func enablingTwiceChangesNothing() throws {
    let once = try CodexNotifications.enable(in: config)
    #expect(try CodexNotifications.enable(in: once) == once)
}

@Test func keepsKeysYouSetYourself() throws {
    let mine = "[tui]\nnotification_method = 'osc9'\n"
    let enabled = try CodexNotifications.enable(in: mine)
    #expect(CodexNotifications.isEnabled(in: enabled))
    #expect(CodexNotifications.disable(in: enabled) == mine)
}

@Test func keepsYourKeysUnderAHeaderFarolAdded() throws {
    let edited = try CodexNotifications.enable(in: "") + "animations = false\n"
    #expect(CodexNotifications.disable(in: edited) == "[tui] # added by Farol\nanimations = false\n")
}

@Test func refusesToOverwriteYourValue() {
    #expect(throws: CodexNotifications.Problem.self) {
        try CodexNotifications.enable(in: "[tui]\nnotifications = false\n")
    }
    #expect(!CodexNotifications.isEnabled(in: "[tui]\nnotifications = false\n"))
}

@Test func refusesDottedTUIKeys() {
    #expect(throws: CodexNotifications.Problem.self) {
        try CodexNotifications.enable(in: "tui.animations = false\n")
    }
}
