import XCTest

final class HermexWatchAppUITests: XCTestCase {
    func testFirstRunShowsSetupWithoutFabricatedActivity() {
        let app = XCUIApplication()
        app.launch()

        // The first launch after a simulator boot is slow.
        XCTAssertTrue(app.staticTexts["Hermex"].waitForExistence(timeout: 15))
        // With a paired but unreachable iPhone the watch may try to connect
        // first; it must settle on first-run copy, never a lasting spinner.
        XCTAssertTrue(app.staticTexts["Set up on iPhone"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Active session"].exists)
        XCTAssertFalse(app.staticTexts["1 activity"].exists)
    }

    func testReadyPathOpensSessionsAndChatWithoutCrashing() {
        let app = XCUIApplication()
        app.launchArguments = ["HERMEX_WATCH_SCREENSHOT_FIXTURE"]
        app.launch()

        XCTAssertTrue(app.buttons["openChat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Message"].exists)
        XCTAssertTrue(app.buttons["Speak to Hermex"].exists)
        XCTAssertTrue(app.buttons["Send a photo"].exists)
        let readAloud = app.buttons["Read reply aloud"]
        XCTAssertTrue(readAloud.exists)
        XCTAssertTrue(readAloud.isEnabled, "The fixture's Now session has a reply to read")
        add(attachment(named: "now", app: app))

        app.buttons["openChat"].tap()
        XCTAssertTrue(app.buttons["Message"].waitForExistence(timeout: 5))
        add(attachment(named: "chat", app: app))
        app.swipeDown()
        app.swipeDown()
        add(attachment(named: "chat-top", app: app))
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(app.buttons["openChat"].waitForExistence(timeout: 5))
        let sessions = app.buttons["nav.sessions"]
        scrollUntilHittable(sessions, in: app)
        add(attachment(named: "now-sections", app: app))
        sessions.tap()
        XCTAssertTrue(app.staticTexts["Stand-up notes"].waitForExistence(timeout: 5))
        let pinned = app.staticTexts["Weekend plan"]
        scrollUntilHittable(pinned, in: app)
        pinned.tap()
        XCTAssertTrue(app.buttons["Speak to Hermex"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Message"].exists)
    }

    /// A started voice note offers Cancel, and Cancel returns to the idle row
    /// without sending. Needs microphone access granted on the simulator.
    func testRecordingCanBeCancelledWithoutSending() {
        let app = XCUIApplication()
        app.launchArguments = ["HERMEX_WATCH_SCREENSHOT_FIXTURE"]
        app.launch()

        let speak = app.buttons["Speak to Hermex"]
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        speak.tap()
        allowMicrophoneIfAsked(app)

        let cancel = app.buttons["Cancel recording"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send recording"].exists)
        add(attachment(named: "recording", app: app))

        cancel.tap()
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send recording"].exists)

        app.swipeUp()
        add(attachment(named: "now-glances", app: app))
        app.swipeUp()
        add(attachment(named: "now-glances-2", app: app))
    }

    /// The first recording on a fresh simulator asks for the microphone. An
    /// unanswered prompt stays on screen and covers every later test.
    private func allowMicrophoneIfAsked(_ app: XCUIApplication) {
        let hosts = [app, XCUIApplication(bundleIdentifier: "com.apple.Carousel"), XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        for host in hosts {
            let allow = host.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) {
                allow.tap()
                return
            }
        }
    }

    /// Lists on the watch build rows lazily. A short drag reveals the next
    /// rows. The digital crown is avoided: a backward crown turn makes XCUI
    /// report the app as not running.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
            start.press(forDuration: 0.02, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, file: file, line: line)
    }

    private func attachment(named name: String, app: XCUIApplication) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    /// Memory used to print `**Name:**` and literal `§` lines. Entries are
    /// separate rows with the Markdown styled away.
    func testMemoryEntriesRenderWithoutRawMarkdownOrDelimiters() {
        let app = launch(page: "memorySection")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Name:'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '**'")).count, 0)
        XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label == '§'")).count, 0)
        add(attachment(named: "memory-section", app: app))
    }

    func testMemoryListShowsEntryCounts() {
        let app = launch(page: "memory")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'About you, 4 entries'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        add(attachment(named: "memory-list", app: app))
    }

    /// The fixture's first Card is Running: the wrist offers the iPhone's
    /// moves only, and leaving Running asks first.
    func testKanbanCardOffersIPhoneMovesAndConfirmsLeavingRunning() {
        let app = launch(page: "kanbanCard")
        XCTAssertTrue(app.staticTexts["Ship watch reply controls"].waitForExistence(timeout: 8))
        let triage = app.buttons["kanban.move.triage"]
        XCTAssertTrue(triage.waitForExistence(timeout: 5))
        add(attachment(named: "kanban-card", app: app))
        let ready = app.buttons["kanban.move.ready"]
        let done = app.buttons["kanban.move.done"]
        XCTAssertTrue(ready.waitForExistence(timeout: 3))
        XCTAssertTrue(done.exists)
        XCTAssertTrue(ready.isHittable)
        XCTAssertFalse(app.buttons["kanban.move.blocked"].exists)
        XCTAssertFalse(app.buttons["kanban.move.running"].exists)
        add(attachment(named: "kanban-card-moves", app: app))
        ready.tap()
        XCTAssertTrue(app.staticTexts["Leave Running?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].exists)
        add(attachment(named: "kanban-leave-running", app: app))
        dismissLeaveRunning(app)
        XCTAssertTrue(app.staticTexts["Leave Running?"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].exists)
        XCTAssertTrue(app.staticTexts["Ship watch reply controls"].exists)
        add(attachment(named: "kanban-card-after-cancel", app: app))
    }

    /// watchOS draws confirmationDialog's Cancel as a Close control. The
    /// navigation back button can share that label, so prefer an explicit
    /// Cancel and otherwise the Close that is not the only nav control.
    private func dismissLeaveRunning(_ app: XCUIApplication) {
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
            return
        }
        let closes = app.buttons.matching(NSPredicate(format: "label == 'Close'"))
        XCTAssertGreaterThan(closes.count, 0)
        closes.element(boundBy: closes.count - 1).tap()
    }

    func testKanbanListGroupsByStatusTitle() {
        let app = launch(page: "kanban")
        XCTAssertTrue(app.buttons["New Card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Dispatcher"].exists)
        XCTAssertTrue(app.buttons["More"].exists)
        let running = app.buttons["kanban.status.running"]
        XCTAssertTrue(running.waitForExistence(timeout: 5))
        scrollUntilHittable(running, in: app)
        running.tap()
        let card = app.staticTexts["Ship watch reply controls"]
        if !card.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 3))
    }

    func testTaskDetailLeadsWithRunNowAndShowsRecentRuns() {
        let app = launch(page: "taskDetail")
        XCTAssertTrue(app.buttons["Run now"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)
        add(attachment(named: "task-detail", app: app))
        let run = app.descendants(matching: .any).matching(identifier: "taskRun").firstMatch
        scrollUntilHittable(run, in: app)
        add(attachment(named: "task-detail-runs", app: app))
        run.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'PRs waiting on review'")).firstMatch.waitForExistence(timeout: 5))
        add(attachment(named: "task-run-output", app: app))
    }

    private func launch(page: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["HERMEX_WATCH_SCREENSHOT_FIXTURE", "HERMEX_WATCH_SCREENSHOT_PAGE=\(page)"]
        app.launch()
        return app
    }

    func testUsageShowsSpendAndModels() {
        let app = launch(page: "usage")
        XCTAssertTrue(app.staticTexts["estimated spend"].waitForExistence(timeout: 8))
        let model = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'gpt-5.6-sol'")).firstMatch
        if !(model.exists && model.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        add(attachment(named: "usage", app: app))
    }

    func testSkillDetailShowsTheSwitch() {
        let app = launch(page: "skillDetail")
        XCTAssertTrue(app.staticTexts["web-search"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.switches.firstMatch.exists)
        add(attachment(named: "skill-detail", app: app))
    }

    func testPlusCreatesAndOpensANewSession() {
        let app = XCUIApplication()
        app.launchArguments = ["HERMEX_WATCH_SCREENSHOT_FIXTURE", "HERMEX_WATCH_SCREENSHOT_PAGE=sessions"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5)
            || app.staticTexts["Weekend plan"].waitForExistence(timeout: 5))
        let create = app.buttons["createSession"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        XCTAssertTrue(
            app.navigationBars["New session"].waitForExistence(timeout: 5)
                || app.buttons["Speak to Hermex"].waitForExistence(timeout: 5)
                || app.buttons["Send"].waitForExistence(timeout: 5)
        )
    }
}
