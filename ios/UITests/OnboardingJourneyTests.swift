import XCTest

@MainActor
final class OnboardingJourneyTests: XCTestCase {
    func testChooseLanguagesStartFreeAccessAndVisitAccount() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "SpeakDuet.UITests.needsDownload"]
        app.launch()
        tap("onboarding.continue", in: app)
        tap("onboarding.language.fr-FR", in: app)
        tap("onboarding.continue", in: app)
        tap("onboarding.language.ja-JP", in: app)
        tap("onboarding.continue", in: app)
        XCTAssertTrue(app.buttons["Download and start"].waitForExistence(timeout: 5))
        attach(app, named: "Offline preparation")
        tap("onboarding.continue", in: app)
        XCTAssertTrue(app.tabBars.buttons["Talk"].waitForExistence(timeout: 10))
        attach(app, named: "Speak Duet Talk")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Default language"].waitForExistence(timeout: 5))
        attach(app, named: "Default language in Settings")
        let account = app.buttons["Account"].firstMatch
        scrollTo(account, in: app)
        account.tap()
        XCTAssertTrue(app.staticTexts["Account sign-in isn’t available in this build yet. You can continue without an account."].waitForExistence(timeout: 5))
        attach(app, named: "Guest account")
    }

    func testManualOnlyPairOpensManualConversation() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "SpeakDuet.UITests.manualOnly"]
        app.launch()
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.es-ES", "onboarding.continue"] {
            tap(id, in: app)
        }
        XCTAssertTrue(app.staticTexts["This iPhone supports manual turns for this pair. Tap a speaker’s mic to record, then tap again to translate."].waitForExistence(timeout: 5))
        tap("onboarding.continue", in: app)
        XCTAssertTrue(app.navigationBars["Manual conversation"].waitForExistence(timeout: 10))
    }

    func testWelcomeAtLargestAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Speak two languages. Have one conversation"].waitForExistence(timeout: 10))
        attach(app, named: "Welcome accessibility XXXL")
        tap("onboarding.continue", in: app)
        tap("onboarding.language.en-US", in: app)
        tap("onboarding.continue", in: app)
        XCTAssertTrue(app.staticTexts["What language does the other person speak?"].waitForExistence(timeout: 5))
        attach(app, named: "Language selection accessibility XXXL")
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), identifier)
        scrollTo(button, in: app)
        button.tap()
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTFail("Could not reach \(element)")
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
