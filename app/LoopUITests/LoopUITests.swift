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
}
