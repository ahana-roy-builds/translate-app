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
        let appearance = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(appearance.buttons["Automatic"].isSelected)
        appearance.buttons["Dark"].tap()
        XCTAssertTrue(appearance.buttons["Dark"].isSelected)
        attach(app, named: "Relay dark settings")
        app.tabBars.buttons["Talk"].tap()
        tap("talk.partner-language", in: app)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        attach(app, named: "Relay dark language picker")
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(appearance.buttons["Dark"].isSelected)
        appearance.buttons["Light"].tap()
        XCTAssertTrue(appearance.buttons["Light"].isSelected)
        appearance.buttons["Automatic"].tap()
        attach(app, named: "Default language in Settings")
        let account = app.buttons["Account"].firstMatch
        scrollTo(account, in: app)
        account.tap()
        XCTAssertTrue(app.staticTexts["Account sign-in isn’t available in this build yet. You can continue without an account."].waitForExistence(timeout: 5))
        attach(app, named: "Guest account")
    }

    func testSplitLayoutCanSwitchAndExpiredAccessStillShowsPaywall() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "SpeakDuet.UITests.expired"]
        app.launch()
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.es-ES", "onboarding.continue", "onboarding.continue"] {
            tap(id, in: app)
        }
        let partner = app.buttons["talk.partner-language"]
        let owner = app.buttons["talk.traveler-language"]
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        let swap = app.buttons["talk.swap-languages"]
        let mic = app.buttons["talk.primary-microphone"]
        let bottom = app.staticTexts["talk.seat-language.traveler"]
        let top = app.staticTexts["talk.seat-language.local"]
        XCTAssertEqual(partner.frame.midY, owner.frame.midY, accuracy: 4)
        XCTAssertLessThan(owner.frame.midX, swap.frame.midX)
        XCTAssertLessThan(swap.frame.midX, partner.frame.midX)
        XCTAssertEqual(swap.frame.midX, mic.frame.midX, accuracy: 4)
        XCTAssertLessThan(swap.frame.maxY, top.frame.midY)
        XCTAssertLessThan(top.frame.midY, mic.frame.midY)
        XCTAssertLessThan(mic.frame.midY, bottom.frame.midY)
        XCTAssertEqual(bottom.label, "English")
        XCTAssertEqual(top.label, "Español")
        tap("talk.swap-languages", in: app)
        XCTAssertEqual(bottom.label, "Español")
        XCTAssertEqual(top.label, "English")
        XCTAssertTrue(owner.label.contains("Spanish"))
        XCTAssertTrue(partner.label.contains("English"))
        tap("talk.swap-languages", in: app)
        XCTAssertFalse(app.buttons["Subscription"].exists)
        attach(app, named: "Wave ribbon ready")
        tap("talk.switch-layout", in: app)
        XCTAssertEqual(partner.frame.midY, owner.frame.midY, accuracy: 4)
        tap("talk.switch-layout", in: app)
        XCTAssertTrue(top.exists)
        tap("talk.primary-microphone", in: app)
        XCTAssertTrue(app.staticTexts["Keep the conversation going"].waitForExistence(timeout: 5))
    }

    func testRelayControlsDuringLiveConversation() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEAK_DUET_LIVE_MIC"] == "1",
                          "Requires an English–Hindi iPhone with live microphone testing enabled and a quiet interval.")
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests"]
        app.launch()
        defer { app.terminate() }
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.hi-IN", "onboarding.continue", "onboarding.continue"] {
            tap(id, in: app)
        }
        let playback = app.buttons["talk.spoken-translations"]
        if playback.value as? String == "On" { playback.tap() }
        let mic = app.buttons["talk.primary-microphone"]
        tap("talk.primary-microphone", in: app)
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Pause listening", timeout: 30))
        attach(app, named: "Relay listening in English and Hindi")
        tap("talk.swap-languages", in: app)
        XCTAssertEqual(mic.label, "Pause listening")
        XCTAssertTrue(app.buttons["talk.traveler-language"].label.contains("Hindi"))
        let hindi = app.staticTexts["talk.seat-language.local"]
        XCTAssertGreaterThan(hindi.frame.midY, mic.frame.midY)
        mic.tap()
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Resume listening", timeout: 10))
        mic.tap()
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Pause listening", timeout: 15))
        app.tabBars.buttons["History"].tap()
        app.tabBars.buttons["Talk"].tap()
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Resume listening", timeout: 10))
        mic.tap()
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Pause listening", timeout: 15))
        let status = app.staticTexts["talk.session-status"]
        XCTAssertTrue(status.wait(for: \.label, toEqual: "Paused after 20 seconds of silence", timeout: 60))
        XCTAssertEqual(mic.label, "Resume listening")
        mic.tap()
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Pause listening", timeout: 15))
        tap("talk.more", in: app)
        tap("End conversation", in: app)
        XCTAssertTrue(mic.wait(for: \.label, toEqual: "Start continuous conversation", timeout: 10))
    }

    func testMissingLanguagesKeepTalkVisibleUntilSetupIsRequested() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "SpeakDuet.UITests.needsDownload"]
        app.launch()
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.es-ES", "onboarding.continue", "onboarding.continue"] {
            tap(id, in: app)
        }
        tap("talk.partner-language", in: app)
        tap("talk.local-language.fr-FR", in: app)
        let setup = app.buttons["talk.language-setup"].firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let owner = app.buttons["talk.traveler-language"], partner = app.buttons["talk.partner-language"]
        XCTAssertEqual(partner.frame.midY, owner.frame.midY, accuracy: 4)
        XCTAssertFalse(app.buttons["Download and Verify"].exists)
        tap("talk.switch-layout", in: app)
        XCTAssertEqual(partner.frame.midY, owner.frame.midY, accuracy: 4)
        XCTAssertFalse(app.buttons["Download and Verify"].exists)
        XCTAssertFalse(app.navigationBars["Language Packs"].exists)
        setup.tap()
        XCTAssertTrue(app.navigationBars["Language Packs"].waitForExistence(timeout: 5))
    }

    func testTranslationOnlyWarningIsRecheckedWhenTheMicIsTapped() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "SpeakDuet.UITests.missingFrenchTranslation"]
        app.launch()
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.es-ES", "onboarding.continue", "onboarding.continue"] {
            tap(id, in: app)
        }
        tap("talk.partner-language", in: app)
        tap("talk.local-language.fr-FR", in: app)
        let mic = app.buttons["talk.primary-microphone"], setup = app.buttons["talk.language-setup"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: mic)], timeout: 5), .completed)
        XCTAssertFalse(setup.exists)
        mic.tap()
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Language Packs"].exists)
        XCTAssertFalse(app.buttons["Download and Verify"].exists)
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

    func testReopenLanguagePacksAndSpanishDetailsFromSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests"]
        app.launch()
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.es-ES", "onboarding.continue", "onboarding.continue"] {
            tap(id, in: app)
        }
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<2 {
            tap("settings.languagePacks", in: app)
            let spanish = app.buttons["languagePacks.es-ES"].firstMatch
            scrollTo(spanish, in: app)
            spanish.tap()
            let detail = app.navigationBars["Spanish"]
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            detail.buttons.element(boundBy: 0).tap()
            let list = app.navigationBars["Language Packs"]
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            list.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        }
    }

    func testDownloadAndReleaseHindiFromDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["SpeakDuet.UITests", "SpeakDuet.UITests.needsDownload"]
        app.launch()
        for id in ["onboarding.continue", "onboarding.language.en-US", "onboarding.continue",
                   "onboarding.language.es-ES", "onboarding.continue", "onboarding.continue"] {
            tap(id, in: app)
        }
        app.tabBars.buttons["Settings"].tap()
        tap("settings.languagePacks", in: app)
        let hindi = app.buttons["languagePacks.hi-IN"].firstMatch
        scrollTo(hindi, in: app)
        hindi.tap()
        tap("languagePacks.downloadListen", in: app)
        let release = app.buttons["Release Listen reservation"]
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["languagePacks.downloadListen"].exists)
        release.tap()
        XCTAssertTrue(app.buttons["languagePacks.downloadListen"].waitForExistence(timeout: 5))
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
