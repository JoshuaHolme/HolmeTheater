// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog

/// App-wide state: which service is in use and whether anyone is signed in.
///
/// Views read `state` to decide between the sign-in flow and the main UI,
/// and call `service` directly for browsing and playback. Sign-in and sign-out go through
/// this type so the session is kept in the keychain in step with `state`.
@Observable
final class AppModel {
    /// Where the app is in its sign-in lifecycle.
    enum SessionState {
        /// Checking the keychain for a saved session.
        case launching
        case signedOut
        case signedIn(UserSession)
    }

    private(set) var state: SessionState = .launching

    /// The signed-in session, or nil if there isn't one.
    var session: UserSession? {
        if case .signedIn(let session) = state { session } else { nil }
    }

    /// The backend the UI talks to. Swap in `MockMediaService` for previews and demos.
    let service: any MediaService

    /// The playback the player is showing, or the last one. Kept here rather than in the player, because SwiftUI
    /// can rebuild the player when the window changes shape (rotating, folding), and playback must carry on
    /// through that instead of starting again.
    @ObservationIgnored var playback: PlaybackSession?

    /// A show the player asked to open ("Go to Show"). The main view pushes it onto the current tab and clears it.
    var pendingShow: MediaItem?

    @ObservationIgnored private let keychain: KeychainStore
    private static let sessionAccount = "session"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NativeFin", category: "Session")

    init(service: any MediaService) {
        self.service = service
        self.keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "JellyfinClient")
    }

    /// Creates a model already in `state`, for SwiftUI previews and tests.
    ///
    /// It uses a separate Keychain namespace, so signing in inside a preview can never overwrite
    /// the session the real app restores at launch.
    init(service: any MediaService, state: SessionState) {
        self.service = service
        self.state = state
        self.keychain = KeychainStore(service: (Bundle.main.bundleIdentifier ?? "JellyfinClient") + ".previews")
    }

    /// Call once at launch to pick up a saved session.
    ///
    /// Moves `state` to `.signedIn` if the keychain holds a session, otherwise `.signedOut`.
    /// The saved token isn't validated here; `refreshProfile()` notices if the server has rejected it.
    func restoreSession() async {
        let saved: UserSession?
        do {
            saved = try keychain.load(UserSession.self, account: Self.sessionAccount)
        } catch {
            // Unreadable (e.g. from an incompatible older build). Treat as signed out rather than failing.
            Self.logger.error("Couldn't read the saved session: \(error.localizedDescription, privacy: .public)")
            saved = nil
        }

        guard let saved else {
            state = .signedOut
            return
        }
        await service.restore(saved)
        state = .signedIn(saved)
    }

    /// Re-reads the signed-in user's name and profile picture from the server, so changes made
    /// elsewhere show up without signing out and in again.
    ///
    /// If the request fails for a transient reason (offline, server down), the saved profile is kept and the
    /// user stays signed in. If the server rejects the token (it expired, or the device was removed on the
    /// server), the useless saved session is discarded and the user is returned to sign-in.
    /// Does nothing unless someone is signed in.
    func refreshProfile() async {
        guard let current = session else { return }

        let updated: UserSession
        do {
            updated = try await service.refreshProfile()
        } catch MediaServiceError.sessionExpired {
            // Only act if the same user is still signed in; they may have signed out while this was in flight.
            guard session?.userID == current.userID else { return }
            Self.logger.notice("The server rejected the saved session; signing out.")
            await signOut()
            return
        } catch {
            return
        }

        // The user may have signed out, or switched accounts, while the request was in flight.
        guard updated != current, session?.userID == updated.userID else { return }
        persist(updated)
        state = .signedIn(updated)
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

    /// Signs out on the server, deletes the saved session and cached artwork, and returns to the sign-in screen.
    func signOut() async {
        playback?.stop()
        playback = nil
        await service.signOut()
        keychain.delete(account: Self.sessionAccount)
        // So the next person on a shared device doesn't see the previous user's artwork or profile picture.
        ImageCache.shared.removeAll()
        state = .signedOut
    }

    private func finishSignIn(_ session: UserSession) {
        persist(session)
        state = .signedIn(session)
    }

    /// Saves the session so the next launch is already signed in. A failure only costs that convenience,
    /// so it's logged rather than surfaced.
    private func persist(_ session: UserSession) {
        do {
            try keychain.save(session, account: Self.sessionAccount)
        } catch {
            Self.logger.error("Couldn't save the session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
