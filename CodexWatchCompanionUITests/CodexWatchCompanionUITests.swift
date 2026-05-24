import XCTest

final class CodexWatchCompanionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMarkdownCardOpensScrollableReader() {
        let app = launchApp(scenario: "markdown")
        let card = app.buttons.matching(identifier: "active-message-card").firstMatch

        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Markdown"].exists)

        app.staticTexts["Markdown"].tap()

        let readerBody = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "inlineCode")).firstMatch
        XCTAssertTrue(readerBody.waitForExistence(timeout: 5))
        XCTAssertTrue(readerBody.label.contains("inlineCode"))
        XCTAssertTrue(readerBody.label.contains("docs"))
        XCTAssertTrue(app.buttons["Reply"].exists)
    }

    func testPrimaryShortcutOpensCurrentTextWhenPresent() {
        let app = launchApp(scenario: "markdown")
        let shortcut = app.buttons.matching(identifier: "active-message-card").firstMatch

        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        shortcut.tap()

        let readerBody = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "inlineCode")).firstMatch
        XCTAssertTrue(readerBody.waitForExistence(timeout: 5))
    }

    func testLongMessagePromotesTitleToNavigationBar() {
        let app = launchApp(scenario: "long-message")
        let shortcut = app.buttons.matching(identifier: "active-message-card").firstMatch

        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        shortcut.tap()

        let readerBody = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "navigation bar")).firstMatch
        XCTAssertTrue(readerBody.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Codex replied"].exists)
        XCTAssertFalse(app.staticTexts["message-reader-title"].exists)
    }

    func testLongMessageReplyButtonLivesAtBottomOfScroll() {
        let app = launchApp(scenario: "long-message")
        let shortcut = app.buttons.matching(identifier: "active-message-card").firstMatch
        let replyButton = app.buttons["Reply"]

        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        shortcut.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "reply control")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(replyButton.isHittable)

        app.swipeUp()
        XCTAssertTrue(replyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(replyButton.isHittable)
    }

    func testActiveMessageBodyUsesMostOfCardWidth() {
        let app = launchApp(scenario: "long-message")
        let card = app.buttons.matching(identifier: "active-message-card").firstMatch
        let body = app.staticTexts.matching(identifier: "active-message-body").firstMatch

        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(body.frame.width, card.frame.width * 0.82)
    }

    func testErrorStateShowsFailedMessageCard() {
        let app = launchApp(scenario: "error")

        XCTAssertTrue(app.buttons["active-message-card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Bridge error"].exists)
        XCTAssertTrue(app.staticTexts["Reconnect failed"].exists)
    }

    func testThinkingStateShowsActivePetCard() {
        let app = launchApp(scenario: "thinking")

        XCTAssertTrue(app.buttons["active-message-card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Codex is thinking"].exists)
        XCTAssertTrue(app.staticTexts["Working on it"].exists)
    }

    func testTranscriptReviewShowsMarkdownAndSendAction() {
        let app = launchApp(scenario: "transcript")

        XCTAssertTrue(app.descendants(matching: .any)["transcript-review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["transcript-review-body"].label.contains("inlineCode"))
        XCTAssertTrue(app.buttons["Send"].exists)
    }

    func testVoiceScenarioShowsCenteredWaveformOnly() {
        let app = launchApp(scenario: "voice")

        XCTAssertTrue(app.descendants(matching: .any)["microphone-waveform"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["active-message-card"].exists)
    }

    func testPickerShowsMascotSection() {
        let app = launchApp(scenario: "picker")
        let codexMascot = app.buttons["mascot-picker-codex"]

        XCTAssertTrue(app.buttons["picker-new-chat-button"].waitForExistence(timeout: 5))

        for _ in 0..<6 where !codexMascot.exists {
            app.swipeUp()
        }

        XCTAssertTrue(codexMascot.waitForExistence(timeout: 5))
    }

    func testPickerLimitsProjectAndChatSectionsWithViewAll() {
        let app = launchApp(scenario: "picker-many")

        XCTAssertTrue(app.buttons["picker-new-chat-button"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.buttons["view-all-projects"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["view-all-projects"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["view-all-projects"].label.contains("2 more"))
    }

    func testFirstRunOnboardingShowsPetAndProjectChoice() {
        let app = launchApp(scenario: "onboarding")

        XCTAssertTrue(app.navigationBars["Set Up"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-mascot-codex"].exists || app.staticTexts["Codex"].exists)
        for _ in 0..<8 where !app.staticTexts["Project 1"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Project 1"].exists)
    }

    private func launchApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["CODEX_WATCH_UI_TEST_SCENARIO"] = scenario
        app.launch()
        return app
    }
}
