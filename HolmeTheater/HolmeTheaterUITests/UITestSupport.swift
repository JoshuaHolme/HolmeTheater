// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// What every UI test shares: launching the app against canned data, signed out, in the orientation the test plan's
/// configuration names.
///
/// `ReleaseUITests.xctestplan` runs every test once per orientation, setting `UI_TEST_ORIENTATION`; the default plan
/// leaves it unset, which is portrait. `Tools/run-ui-tests.sh` runs that plan on each kind of device the app supports.
@MainActor
class AppUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// The app under test.
    nonisolated static let bundleIdentifier = "tech.holme.theater"

    /// How long to wait for a screen, with the mock's simulated network delay.
    let timeout: TimeInterval = 10

    /// The orientation this run of the test is for, as the test plan names it.
    static var orientationName: String {
        ProcessInfo.processInfo.environment["UI_TEST_ORIENTATION"] ?? "portrait"
    }

    #if os(iOS)
    /// The orientation this run of the test is for.
    static var orientation: UIDeviceOrientation {
        switch orientationName {
        case "landscapeLeft": .landscapeLeft
        case "landscapeRight": .landscapeRight
        case "portraitUpsideDown": .portraitUpsideDown
        default: .portrait
        }
    }

    /// The orientations the app supports on this device, as its Info.plist lists them: all four on iPad, and all but
    /// upside down on iPhone.
    static var supportedOrientations: [UIDeviceOrientation] {
        UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]
            : [.portrait, .landscapeLeft, .landscapeRight]
    }
    #endif

    override func setUp() async throws {
        continueAfterFailure = false
        #if os(iOS)
        guard Self.supportedOrientations.contains(Self.orientation) else {
            throw XCTSkip("The app doesn't support this orientation on this device.")
        }
        XCUIDevice.shared.orientation = Self.orientation
        #else
        // A TV has no orientation: run once, in the plan's portrait configuration.
        guard Self.orientationName == "portrait" else { throw XCTSkip("Apple TV has no orientation.") }
        #endif

        app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        // Signed out, whatever an earlier run left saved.
        app.launchArguments = ["-UseMockService", "-SignedOutAtLaunch", "-MockLatencyMilliseconds", "50"]
        app.launch()
    }

    /// Keeps a screenshot of the screen as it was when a check failed, in the result bundle, so a failure on a device
    /// that isn't to hand can be seen.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        // A failed check is recorded on the thread the test runs on, which is the main one for these tests; a screenshot
        // can only be taken there.
        if Thread.isMainThread, let png = MainActor.assumeIsolated({ AppUITestCase.screenshotOfApp() }) {
            let screenshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            screenshot.name = "Screen at failure"
            screenshot.lifetime = .keepAlways
            issue.add(screenshot)
        }
        super.record(issue)
    }

    /// The app's screen as a PNG, if it's showing. Found by its bundle identifier, the same app as ``app``.
    private static func screenshotOfApp() -> Data? {
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        guard app.state == .runningForeground else { return nil }
        return app.screenshot().pngRepresentation
    }

    override func tearDown() async throws {
        app?.terminate()
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    /// A tab, by its name. Tabs are found as buttons, wherever they are: a tab bar along the bottom, along the top on
    /// iPad, a sidebar, or Apple TV's tab bar.
    func tab(_ name: String) -> XCUIElement {
        app.buttons[name].firstMatch
    }

    #if os(iOS)
    /// Scrolls down until `element` exists, for lists and forms that only make their rows as they come into view. Drags in
    /// the top part of the screen, clear of a keyboard.
    func scrollDown(to element: XCUIElement) {
        let deadline = Date.now.addingTimeInterval(timeout * 2)
        while Date.now < deadline, !element.waitForExistence(timeout: 1) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        }
    }
    #endif

    #if os(iOS)
    /// Switches to a tab. Taps where it is if XCUITest can't work out a point to tap, which happens with the floating
    /// tab bar while something above it is still animating away.
    func tapTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = tab(name)
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "No \(name) tab", file: file, line: line)
        if tab.isHittable {
            tab.tap()
        } else {
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
    #endif

    /// The first button whose label contains `text`.
    func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}

#if os(tvOS)
extension AppUITestCase {
    /// What has focus now, if anything.
    var focused: XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    /// Moves focus to `element` with the remote's arrows, heading towards it from whatever has focus.
    func moveFocus(to element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never appeared", file: file, line: line)
        for _ in 0..<30 {
            if element.hasFocus { return }
            let from = focused.frame, to = element.frame
            let (dx, dy) = (to.midX - from.midX, to.midY - from.midY)
            let button: XCUIRemote.Button = abs(dy) >= abs(dx)
                ? (dy > 0 ? .down : .up)
                : (dx > 0 ? .right : .left)
            XCUIRemote.shared.press(button)
        }
        XCTAssertTrue(element.hasFocus, "Couldn't move focus to \(element)", file: file, line: line)
    }

    /// Focuses `element` and presses Select on it.
    func select(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        moveFocus(to: element, file: file, line: line)
        XCUIRemote.shared.press(.select)
    }

    /// Focuses a text field, types into it with the on-screen keyboard, and closes the keyboard.
    func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        select(field, file: file, line: line)
        // The full-screen keyboard: type, then leave it with Menu, which keeps what was typed.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: timeout), "No keyboard for \(field)", file: file, line: line)
        app.typeText(text)
        XCUIRemote.shared.press(.menu)
        _ = keyboard.waitForNonExistence(timeout: timeout)
    }
}
#endif
