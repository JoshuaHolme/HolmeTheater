// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// App-wide state: which service is in use and whether anyone is signed in.
///
/// Views read `state` to decide between the sign-in flow and the main UI,
/// and call `service` directly for browsing and playback. Sign-in and sign-out go through
/// this type so the session is kept in the keychain in step with `state`.
@Observable
final class AppModel {
    /// Where the app is in its sign-in lifecycle.
    enum State {
        /// Checking the keychain for a saved session.
        case launching
        case signedOut
        case signedIn(UserSession)
    }

    private(set) var state: State = .launching

    /// The backend the UI talks to. Swap in `MockMediaService` for previews and demos.
    let service: any MediaService

    private let keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "JellyfinClient")
    private let sessionAccount = "session"

    init(service: any MediaService) {
        self.service = service
    }

    /// Call once at launch to pick up a saved session.
    ///
    /// Moves `state` to `.signedIn` if the keychain holds a session, otherwise `.signedOut`.
    /// The saved token isn't validated here; an expired one surfaces as an error on first use.
    func restoreSession() async {
        guard let session = try? keychain.load(UserSession.self, account: sessionAccount) else {
            state = .signedOut
            return
        }
        await service.restore(session)
        state = .signedIn(session)
    }

    /// Checks that `address` is a reachable Jellyfin server. Call before signing in.
    func connect(to address: String) async throws -> ServerInfo {
        try await service.connect(to: address)
    }

    /// Signs in with a username and password, then persists the session.
    func signIn(username: String, password: String) async throws {
        let session = try await service.signIn(username: username, password: password)
        finishSignIn(session)
    }

    /// Runs the Quick Connect flow. `showCode` is called with the code the user must approve
    /// from another signed-in client; returns once sign-in completes. Cancel the calling task to abort.
    func signInWithQuickConnect(showCode: (String) -> Void) async throws {
        for try await event in service.quickConnect() {
            switch event {
            case .code(let code):
                showCode(code)
            case .signedIn(let session):
                finishSignIn(session)
                return
            }
        }
    }

    /// Signs out on the server, deletes the saved session, and returns to the sign-in screen.
    func signOut() async {
        await service.signOut()
        keychain.delete(account: sessionAccount)
        state = .signedOut
    }

    private func finishSignIn(_ session: UserSession) {
        try? keychain.save(session, account: sessionAccount)
        state = .signedIn(session)
    }
}
