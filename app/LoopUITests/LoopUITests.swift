import XCTest

final class LoopUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func app(_ extra: [String] = []) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchArguments = ["-LoopReplayRoute", "-LoopReplaySpeed", "30", "-LoopFreshStore"] + extra
        return a
    }

    /// Replay mode uses a recorded route, so no location prompt appears.
    func testRecordRunAndSave() throws {
        let a = app()
        a.launch()
        a.buttons["sport-run"].tap()
        let start = a.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        let distance = a.descendants(matching: .any)["liveDistance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(60)
        var km = 0.0
        while Date() < deadline {
            let label = distance.label
            km = Double(label.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            if km > 0.5 { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertGreaterThan(km, 0.5)

        let hold = a.descendants(matching: .any)["holdToStop"]
        XCTAssertTrue(hold.exists)
        hold.press(forDuration: 1.6)

        let saved = a.descendants(matching: .any)["savedPill"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        let name = a.staticTexts["workoutName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(name.label.isEmpty)
    }

    private func km(_ e: XCUIElement) -> Double {
        Double(e.label.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
    }

    /// A recording survives the app being killed and comes back on relaunch.
    func testRecordingSurvivesTermination() throws {
        let a = app(["-LoopDraftTest", "-LoopClearDraft"])
        a.launch()
        a.buttons["sport-run"].tap()
        let start = a.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        var distance = a.descendants(matching: .any)["liveDistance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        var before = 0.0
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            before = km(distance)
            if before > 0.3 { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertGreaterThan(before, 0.3)
        // The draft is written every 10 s, so after 11 s it holds at least what we read.
        Thread.sleep(forTimeInterval: 11)
        a.terminate()

        let b = app(["-LoopDraftTest"])
        b.launch()
        distance = b.descendants(matching: .any)["liveDistance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10), "recording screen should be back")
        XCTAssertFalse(b.buttons["startButton"].isHittable)
        XCTAssertGreaterThanOrEqual(km(distance), before)

        let hold = b.descendants(matching: .any)["holdToStop"]
        XCTAssertTrue(hold.exists)
        hold.press(forDuration: 1.6)
        XCTAssertTrue(b.descendants(matching: .any)["savedPill"].waitForExistence(timeout: 10))
    }

    func testSwimCheckIn() throws {
        let a = app()
        a.launch()
        a.buttons["sport-swim"].tap()
        XCTAssertTrue(a.descendants(matching: .any)["deviceNote"].label.contains("Apple Watch not connected"))
        let ci = a.buttons["checkInButton"]
        XCTAssertTrue(ci.waitForExistence(timeout: 3))
        ci.tap()
        let confirm = a.buttons["confirmCheckIn"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(a.staticTexts["weekCount"].waitForExistence(timeout: 3))
        XCTAssertEqual(a.staticTexts["weekCount"].label, "1 workout")
        a.tabBars.buttons["You"].tap()
        let row = a.buttons["workoutRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.label.contains("check-in"))
    }

    /// Writes four screenshots when LOOP_SHOTS is set (TEST_RUNNER_LOOP_SHOTS=<dir> xcodebuild test ...).
    func testCaptureScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOP_SHOTS"] else { throw XCTSkip("LOOP_SHOTS not set") }
        func shot(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let a = app()
        a.launch()
        a.buttons["sport-swim"].tap()
        sleep(1); shot("2-start-swim.png")
        a.buttons["sport-run"].tap()
        sleep(1); shot("1-start-run.png")
        a.buttons["startButton"].tap()
        // Replay at 30x: the mid-run walk stretch (2.6 to 3.0 km) is behind us after ~37 s.
        sleep(40); shot("3-recording.png")
        a.descendants(matching: .any)["holdToStop"].press(forDuration: 1.6)
        XCTAssertTrue(a.descendants(matching: .any)["savedPill"].waitForExistence(timeout: 10))
        sleep(2); shot("4-summary.png")
    }

    /// Records a short replay run and stops it, landing on the summary.
    private func recordAndStop(_ a: XCUIApplication, seconds: UInt32 = 12, shot: ((String) -> Void)? = nil) {
        a.buttons["sport-run"].tap()
        let start = a.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(a.descendants(matching: .any)["liveDistance"].waitForExistence(timeout: 10))
        sleep(seconds)
        shot?("recording-mono.png")
        a.descendants(matching: .any)["holdToStop"].press(forDuration: 1.6)
        XCTAssertTrue(a.descendants(matching: .any)["savedPill"].waitForExistence(timeout: 10))
    }

    func testShareCardAndSave() throws {
        let a = app()
        a.launch()
        recordAndStop(a)
        let share = a.buttons["shareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(a.descendants(matching: .any)["shareScreen"].waitForExistence(timeout: 5))
        XCTAssertTrue(a.buttons["style-city"].waitForExistence(timeout: 5))
        a.buttons["style-bib"].tap()
        XCTAssertTrue(a.descendants(matching: .any)["cardPreview-bib"].waitForExistence(timeout: 3))
        a.buttons["style-receipt"].tap()
        XCTAssertTrue(a.descendants(matching: .any)["cardPreview-receipt"].waitForExistence(timeout: 3))
        a.buttons["saveCardButton"].tap()
        // Either the Photos add-only alert shows (first time) or the toast does.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toast = a.descendants(matching: .any)["shareToast"]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !toast.exists {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let allow = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
                if allow.exists { allow.tap() }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(toast.exists, "no toast")
        XCTAssertTrue(a.staticTexts["Saved to Photos"].exists, "toast said: \(toast.label)")
    }

    /// Part 2 screenshots when LOOP_SHOTS2 is set (TEST_RUNNER_LOOP_SHOTS2=<dir>).
    func testCapturePart2Screenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOP_SHOTS2"] else { throw XCTSkip("LOOP_SHOTS2 not set") }
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let a = app()
        a.launch()
        recordAndStop(a, seconds: 40, shot: shot)
        sleep(3); shot("summary-mono.png")
        a.buttons["shareButton"].tap()
        XCTAssertTrue(a.descendants(matching: .any)["shareScreen"].waitForExistence(timeout: 5))
        a.buttons["style-city"].tap()
        sleep(4); shot("share-screen.png")
        a.buttons["style-receipt"].tap()
        sleep(2); shot("share-screen-receipt.png")
    }

    /// Walks picked up from (synthetic) motion history show in You; "Not a workout" removes one
    /// and a rescan on the next launch does not bring it back.
    func testDetectedWorkoutNotAWorkout() throws {
        let a = app(["-LoopFakeMotionHistory", "-LoopClearDismissed"])
        a.launch()
        a.tabBars.buttons["You"].tap()
        let rows = a.buttons.matching(identifier: "workoutRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let three = NSPredicate(format: "count == 3")
        wait(for: [expectation(for: three, evaluatedWith: rows)], timeout: 5)
        let walk = rows.firstMatch
        XCTAssertTrue(walk.label.contains("auto"), walk.label)
        let walkLabel = walk.label
        walk.tap()
        let notIt = a.buttons["notAWorkoutButton"]
        XCTAssertTrue(notIt.waitForExistence(timeout: 5))
        notIt.tap()
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)], timeout: 5)
        a.terminate()

        // Fresh in-memory store again, so only the dismissed list keeps the walk out.
        let b = app(["-LoopFakeMotionHistory"])
        b.launch()
        b.tabBars.buttons["You"].tap()
        let rows2 = b.buttons.matching(identifier: "workoutRow")
        XCTAssertTrue(rows2.firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertEqual(rows2.count, 2)
        XCTAssertFalse(rows2.allElementsBoundByIndex.contains { $0.label == walkLabel })
    }

    /// Battery and auto-log screenshots when LOOP_SHOTS3 is set (TEST_RUNNER_LOOP_SHOTS3=<dir>).
    func testCaptureAutoLogScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOOP_SHOTS3"] else { throw XCTSkip("LOOP_SHOTS3 not set") }
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let a = app(["-LoopFakeMotionHistory", "-LoopClearDismissed"])
        a.launch()
        recordAndStop(a)
        a.buttons["doneButton"].tap()
        a.tabBars.buttons["You"].tap()
        sleep(2); shot("you-list.png")
        a.buttons.matching(identifier: "workoutRow").element(boundBy: 1).tap()
        sleep(1); shot("summary-detected.png")
        a.navigationBars.buttons.firstMatch.tap()
        a.buttons["settingsButton"].tap()
        sleep(1); shot("settings.png")
        a.buttons["diagnosticsRow"].tap()
        sleep(1); shot("diagnostics.png")
    }

    // MARK: Home map

    private func mapShot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOOP_SHOTS_MAP"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// The map sits behind the Start screen and never takes a tap.
    func testHomeMapBehindStart() throws {
        let a = app(["-LoopFakeRoutes", "6"])
        a.launch()
        // The chosen sport persists between runs (a swim shows Check in), so pick Run first.
        a.buttons["sport-run"].tap()
        let start = a.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(a.staticTexts["weekCount"].label.isEmpty, false)
        sleep(4) // tiles
        mapShot("1-start-glow-several-routes.png")
        XCTAssertTrue(start.isHittable)
        a.buttons["sport-walk"].tap()
        XCTAssertTrue(a.buttons["sport-walk"].isSelected)
        a.buttons["sport-run"].tap()
        a.tabBars.buttons["You"].tap()
        a.tabBars.buttons["Start"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 3))
    }

    func testHomeMapOneRouteAndNoData() throws {
        guard ProcessInfo.processInfo.environment["LOOP_SHOTS_MAP"] != nil else { throw XCTSkip("LOOP_SHOTS_MAP not set") }
        let a = app(["-LoopFakeRoutes", "1"])
        a.launch()
        a.buttons["sport-run"].tap()
        XCTAssertTrue(a.buttons["startButton"].waitForExistence(timeout: 5))
        sleep(4); mapShot("2-start-one-route.png")
        a.terminate()
        let b = app()
        b.launch()
        b.buttons["sport-run"].tap()
        XCTAssertTrue(b.buttons["startButton"].waitForExistence(timeout: 5))
        sleep(2); mapShot("3-start-no-data.png")
    }

    /// The nudge question shows once there are a few workouts; "Not now" hides it for good.
    func testNudgeAskCard() throws {
        let a = app(["-LoopFakeRoutes", "6", "-LoopResetNudgeAsk"])
        a.launch()
        a.buttons["sport-run"].tap()
        XCTAssertTrue(a.buttons["startButton"].waitForExistence(timeout: 5))
        let notNow = a.buttons["nudgeNotNow"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        XCTAssertTrue(a.staticTexts["Want a nudge on quiet days?"].exists)
        if let dir = ProcessInfo.processInfo.environment["LOOP_SHOTS_NUDGE"] {
            sleep(4)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("1-start-ask-card.png"))
        }
        XCTAssertTrue(a.buttons["startButton"].isHittable)
        notNow.tap()
        XCTAssertFalse(notNow.waitForExistence(timeout: 1))
        a.terminate()

        let b = app(["-LoopFakeRoutes", "6"])
        b.launch()
        b.buttons["sport-run"].tap()
        XCTAssertTrue(b.buttons["startButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(b.buttons["nudgeNotNow"].waitForExistence(timeout: 2))

        b.tabBars.buttons["You"].tap()
        b.buttons["settingsButton"].tap()
        XCTAssertTrue(b.switches["nudgesToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(b.switches["recapToggle"].exists)
        if let dir = ProcessInfo.processInfo.environment["LOOP_SHOTS_NUDGE"] {
            sleep(1)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("2-settings.png"))
        }
    }

    /// With no workouts the question stays away.
    func testNudgeAskHiddenWithoutWorkouts() throws {
        let a = app(["-LoopResetNudgeAsk"])
        a.launch()
        a.buttons["sport-run"].tap()
        XCTAssertTrue(a.buttons["startButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(a.buttons["nudgeNotNow"].waitForExistence(timeout: 2))
    }
}
