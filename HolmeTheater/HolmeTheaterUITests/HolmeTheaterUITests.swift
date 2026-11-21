// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

#if os(iOS)
/// The main paths through the app on iPhone and iPad, against canned data (`-UseMockService`), so no server is needed.
/// Each runs in the orientation the test plan's configuration names (see ``AppUITestCase``).
final class HolmeTheaterUITests: AppUITestCase {
    // MARK: Signing in and out

    func testSigningInShowsTheHomeScreenAndSigningOutReturns() {
        signIn()
        XCTAssertTrue(tab("Home").waitForExistence(timeout: timeout))

        signOut()
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: timeout))
    }

    func testSignInNeedsAServerAndAUsername() {
        let signInButton = app.buttons["Sign In"]
        scrollDown(to: signInButton)
        XCTAssertFalse(signInButton.isEnabled)

        let address = app.textFields["Server address"]
        address.tap()
        address.typeText("jellyfin.local")
        scrollDown(to: signInButton)
        XCTAssertFalse(signInButton.isEnabled, "A username is needed too")
    }

    // MARK: Browsing

    func testBrowsingALibraryReachesAMoviesDetails() {
        signIn()
        openStaticBloom()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: timeout))
    }

    func testSearchFindsAMovie() {
        signIn()
        tapTab("Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Static")
        XCTAssertTrue(button(containing: "Static Bloom").waitForExistence(timeout: timeout))
    }

    func testANewAccountHasNoDownloads() {
        signIn()
        tapTab("Downloads")
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: timeout))
    }

    // MARK: Rotating

    /// Turns the device to every orientation it supports on each main screen, and checks the screen is still there and
    /// can still be used: the tabs, a library's posters and a movie's details.
    func testEveryScreenSurvivesRotating() {
        signIn()
        checkThroughRotation("Home screen") { self.tab("Libraries").exists }

        tapTab("Libraries")
        let movies = button(containing: "Movies")
        XCTAssertTrue(movies.waitForExistence(timeout: timeout))
        checkThroughRotation("Libraries") { movies.exists }

        openStaticBloom()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: timeout))
        checkThroughRotation("Movie details") { play.exists }

        tapTab("Downloads")
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: timeout))
        checkThroughRotation("Downloads") { self.app.staticTexts["No Downloads"].exists }
    }

    // MARK: Steps

    private func signIn() {
        let address = app.textFields["Server address"]
        XCTAssertTrue(address.waitForExistence(timeout: timeout))
        address.tap()
        address.typeText("jellyfin.local")

        // Further down the form, which on a short screen only makes them once they're scrolled to. Tapping then scrolls
        // each into view, from under the keyboard if need be.
        let username = app.textFields["Username"]
        scrollDown(to: username)
        username.tap()
        username.typeText("demo")

        let password = app.secureTextFields["Password"]
        scrollDown(to: password)
        password.tap()
        password.typeText("password")

        let signIn = app.buttons["Sign In"]
        scrollDown(to: signIn)
        signIn.tap()
        XCTAssertTrue(tab("Libraries").waitForExistence(timeout: timeout))
        // The sign-in screen fades out over the main one, and takes any tap until it's gone.
        XCTAssertTrue(address.waitForNonExistence(timeout: timeout))
        dismissSavePasswordPrompt()
    }

    /// Answers the system's "Save Password?" prompt, which iOS offers after a sign-in with a password field, on a device that
    /// hasn't been asked yet. It's drawn by the system rather than the app, and takes every tap until it's answered.
    private func dismissSavePasswordPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 3) {
                notNow.tap()
                // It takes taps until it has finished going.
                _ = notNow.waitForNonExistence(timeout: timeout)
                return
            }
        }
    }

    private func signOut() {
        tapTab("Account")
        // At the bottom of a list, which only makes its rows as they scroll into view.
        let settings = app.switches["Autoplay Next Episode"]
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        let signOut = app.buttons["Sign Out"]
        scrollDown(to: signOut)
        signOut.tap()
        // Asked first when there are downloads, which go too.
        let confirm = app.buttons["Sign Out and Delete Downloads"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() }
    }

    /// Libraries, then Movies, then the movie Static Bloom.
    private func openStaticBloom() {
        tapTab("Libraries")
        let movies = button(containing: "Movies")
        XCTAssertTrue(movies.waitForExistence(timeout: timeout))
        movies.tap()

        // Further down a grid that only makes its posters as they scroll into view.
        let movie = button(containing: "Static Bloom")
        scrollDown(to: movie)
        movie.tap()
    }

    /// Turns the device to each orientation it supports, checking `isUsable` in each, then back to the one the test
    /// started in.
    private func checkThroughRotation(_ screen: String, _ isUsable: () -> Bool) {
        for orientation in Self.supportedOrientations + [Self.orientation] {
            XCUIDevice.shared.orientation = orientation
            // Let the rotation finish.
            _ = app.wait(for: .runningForeground, timeout: 1)
            XCTAssertTrue(isUsable(), "\(screen) after turning to \(orientation.rawValue)")
            XCTAssertTrue(tab("Libraries").exists, "The tabs after turning \(screen) to \(orientation.rawValue)")
        }
    }
}
#endif
