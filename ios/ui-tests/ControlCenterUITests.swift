import XCTest

/// Runs only on a disposable CI simulator. BLE is a Debug-only fixture;
/// Control Center, WidgetKit, App Intents, process routing and storage are real.
final class ControlCenterUITests: XCTestCase {
    private let receiver = XCUIApplication(bundleIdentifier: "local.codex.phone.notifier")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        receiver.launchEnvironment["CODEX_CONTROL_UI_TEST"] = "1"
        receiver.launch()
        XCTAssertTrue(receiver.buttons["开始提醒"].waitForExistence(timeout: 20))
        receiver.buttons["设置"].tap()
        let sharedStatus = receiver.staticTexts["控制中心状态已同步"]
        // Form materializes rows lazily. Accessory setup adds a section before
        // Controls; reveal the row instead of treating off-screen content as absent.
        for _ in 0..<4 {
            if sharedStatus.waitForExistence(timeout: 1) { break }
            receiver.swipeUp()
        }
        if !sharedStatus.waitForExistence(timeout: 5) {
            print("APP_SETUP_STATE\n\(receiver.debugDescription)")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "app-shared-state-setup"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(sharedStatus.exists)
        receiver.buttons["完成"].tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("UI_EVIDENCE \(name)\n\(springboard.debugDescription)")
    }

    private func openControlCenter() {
        XCUIDevice.shared.press(.home)
        let background = NSPredicate { _, _ in self.receiver.state != .runningForeground }
        // Home can first dismiss an existing Control Center overlay back to the
        // host. Reach the actual Home screen before dragging another overlay.
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: background, object: nil)], timeout: 3) != .completed {
            XCUIDevice.shared.press(.home)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: background, object: nil)], timeout: 10), .completed,
                           "Test setup could not leave the host for Home")
        }
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func modeControl() -> XCUIElement {
        let filter = NSPredicate(format: "label CONTAINS[c] %@", "Codex")
        let toggle = springboard.switches.matching(filter).firstMatch
        if toggle.exists { return toggle }
        return springboard.buttons.matching(filter).firstMatch
    }

    private func openReceiver() {
        // activate() can leave SpringBoard's Control Center overlay in place.
        // Dismiss it first so taps actually land in the host's visible window.
        XCUIDevice.shared.press(.home)
        receiver.activate()
        XCTAssertTrue(receiver.buttons["设置"].waitForExistence(timeout: 10))
    }

    private func setHostMode(_ enabled: Bool) {
        openReceiver()
        let before = receiver.buttons[enabled ? "开始提醒" : "暂停提醒"]
        XCTAssertTrue(before.waitForExistence(timeout: 5))
        before.tap()
        if !receiver.buttons[enabled ? "暂停提醒" : "开始提醒"].waitForExistence(timeout: 5) {
            print("HOST_MODE_CHANGE_FAILED\n\(receiver.debugDescription)")
            capture("host-mode-change-failed")
        }
        XCTAssertTrue(receiver.buttons[enabled ? "暂停提醒" : "开始提醒"].exists)
    }

    private func assertMode(_ enabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            let control = self.modeControl()
            guard control.exists else { return false }
            let value = String(describing: control.value ?? "").lowercased()
            if value.contains("已开启") { return enabled }
            if value.contains("已关闭") { return !enabled }
            if ["1", "on", "true"].contains(value) { return enabled }
            if ["0", "off", "false"].contains(value) { return !enabled }
            if control.label.contains("已开启") { return enabled }
            if control.label.contains("已关闭") { return !enabled }
            return control.isSelected == enabled
        }
        let wait = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 45)
        if wait != .completed { capture("unexpected-mode-\(enabled)") }
        XCTAssertEqual(wait, .completed, "Expected persistent control state \(enabled)", file: file, line: line)
        XCTAssertNotEqual(receiver.state, .runningForeground, "The control must not open the App", file: file, line: line)
    }

    func testPersistentControlAndHostSynchronization() throws {
        openControlCenter()
        capture("control-center-before-add")
        let edit = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add'")).firstMatch
        if edit.waitForExistence(timeout: 5) { edit.tap() }
        else { springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 1.5) }
        let addControl = springboard.buttons["Add a Control"]
        if !addControl.waitForExistence(timeout: 5) { capture("control-edit-elements") }
        XCTAssertTrue(addControl.exists)
        addControl.tap()
        let search = springboard.searchFields.firstMatch
        if !search.waitForExistence(timeout: 5) { capture("control-gallery-elements") }
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("Codex")
        capture("control-gallery-search")
        let item = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Codex'")).firstMatch
        // The gallery's first index is asynchronous after a fresh installation.
        // Refresh the search within a bounded window; never skip the add-control check.
        for _ in 0..<3 {
            if item.waitForExistence(timeout: 10) { break }
            let clear = search.buttons["Clear text"]
            if clear.exists { clear.tap(); search.typeText("Codex") }
        }
        if item.exists { item.tap() }
        else {
            let text = springboard.staticTexts["Codex 模式"].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            text.tap()
        }
        openControlCenter()
        assertMode(false)
        capture("01-mode-off")

        // A newly added control may still display its OFF preview while chronod
        // starts the live renderer. Observe a real host state change before tapping:
        // a static placeholder cannot satisfy ON, so we never tap an inert preview.
        setHostMode(true)
        openControlCenter()
        assertMode(true)
        setHostMode(false)
        openControlCenter()
        assertMode(false)

        modeControl().tap()
        assertMode(true)
        capture("02-mode-on")
        openControlCenter()
        assertMode(true) // Remains on after closing and reopening Control Center.
        openReceiver()
        XCTAssertTrue(receiver.buttons["暂停提醒"].waitForExistence(timeout: 10))
        receiver.buttons["暂停提醒"].tap()
        openControlCenter()
        assertMode(false) // App -> Control sync, independent of the control action.
        capture("03-off-from-app")

        modeControl().tap()
        assertMode(true)
        modeControl().tap()
        assertMode(false)
        openReceiver()
        XCTAssertTrue(receiver.buttons["开始提醒"].waitForExistence(timeout: 10))
        receiver.terminate()
        openControlCenter()
        assertMode(false)
        modeControl().tap()
        assertMode(true) // Explicit control action relaunches the host in the background.
        capture("04-cold-start-on")
        openReceiver()
        XCTAssertTrue(receiver.buttons["暂停提醒"].waitForExistence(timeout: 10))
    }
}
