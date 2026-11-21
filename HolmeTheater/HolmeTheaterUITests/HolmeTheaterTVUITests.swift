// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

#if os(tvOS)
/// The main paths through the app on Apple TV, driven with the remote, against canned data (`-UseMockService`).
final class HolmeTheaterTVUITests: AppUITestCase {
    // MARK: Signing in and out

    func testSigningInWithAPasswordShowsTheLibraries() {
        signInWithPassword()
        XCTAssertTrue(tab("Home").exists)
    }

    func testQuickConnectSignsIn() {
        type("jellyfin.local", into: app.textFields["Server address"])
        select(button(containing: "Use Quick Connect"))
        // The mock shows a code, then approves it a few seconds later, as another device would.
        XCTAssertTrue(app.staticTexts["123456"].waitForExistence(timeout: timeout))
        XCTAssertTrue(tab("Libraries").waitForExistence(timeout: timeout))
    }

    func testSigningOutReturnsToSignIn() {
        signInWithPassword()
        select(tab("Account"))
        select(button(containing: "Sign Out"))
        // Asked first when there are downloads, which go too.
        let confirm = app.buttons["Sign Out and Delete Downloads"]
        if confirm.waitForExistence(timeout: 2) { select(confirm) }
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: timeout))
    }

    // MARK: Browsing

    func testBrowsingALibraryReachesAMoviesDetails() {
        signInWithPassword()
        select(tab("Libraries"))
        select(button(containing: "Movies"))
        select(button(containing: "Static Bloom"))
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: timeout))
    }

    func testANewAccountHasNoDownloads() {
        signInWithPassword()
        select(tab("Downloads"))
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: timeout))
    }

    // MARK: Steps

    private func signInWithPassword() {
        type("jellyfin.local", into: app.textFields["Server address"])
        select(app.buttons["Sign In with Password"])
        type("demo", into: app.textFields["Username"])
        type("password", into: app.secureTextFields["Password"])
        select(app.buttons["Sign In"])
        XCTAssertTrue(tab("Libraries").waitForExistence(timeout: timeout))
    }
}
#endif
