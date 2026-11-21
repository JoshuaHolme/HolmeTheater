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

    /// Whether the signed-in user may create collections and change what's in them. False until the server has said, so
    /// the controls appear once the profile loads rather than failing when used.
    var canManageCollections: Bool { session?.canManageCollections == true }

    /// Identifies the signed-in account and its server, for caches that must not show one account's data to another.
    /// Empty when signed out.
    var cacheScope: String {
        session.map { "\($0.server.url.absoluteString)|\($0.userID)" } ?? ""
    }

    /// The backend the UI talks to. Swap in `MockMediaService` for previews and demos.
    let service: any MediaService

    /// Movies and episodes saved for offline viewing. ``service`` answers from them when the server can't.
    let downloads: DownloadManager

    /// How the user has set up the home screen.
    let homeSettings: HomeSettings

    /// Which seasonal or holiday theme the app wears, if any.
    let themeSettings: ThemeSettings

    /// How playback behaves, e.g. whether the next episode starts by itself. Shared by the settings and the player.
    let playbackSettings: PlaybackSettings

    /// The optional tips, and whether the user has left one.
    let support: SupportStore

    /// A short message to show over the tabs for a moment, e.g. that something worked. The main view clears it.
    var toastMessage: String?

    /// The playback the player is showing, or the last one. Kept here rather than in the player, because SwiftUI
    /// can rebuild the player when the window changes shape (rotating, folding), and playback must carry on
    /// through that instead of starting again.
    @ObservationIgnored var playback: PlaybackSession?

    /// A show the player asked to open ("Go to Show"). The main view pushes it onto the current tab and clears it.
    var pendingShow: MediaItem?

    @ObservationIgnored private let sessionStore: any SessionStore
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "Session")

    /// The Keychain namespace a service's saved session goes under. Mock runs (`-UseMockService`) get their own;
    /// otherwise the canned session they save would be restored against the real server on the next normal launch,
    /// which can never sign it in.
    private static func keychainNamespace(for service: any MediaService) -> String {
        let base = Bundle.main.bundleIdentifier ?? "JellyfinClient"
        return service is MockMediaService ? base + ".mock" : base
    }

    init(service: any MediaService) {
        let store = DownloadStore()
        self.homeSettings = HomeSettings()
        self.themeSettings = ThemeSettings()
        self.playbackSettings = PlaybackSettings()
        self.support = SupportStore()
        self.service = OfflineFallbackMediaService(base: service, store: store)
        self.downloads = DownloadManager(service: service, store: store)
        self.sessionStore = KeychainSessionStore(keychain: KeychainStore(service: Self.keychainNamespace(for: service)))
    }

    /// Creates a model already in `state`, for SwiftUI previews and tests.
    ///
    /// - Parameter sessionStore: Where the session is kept. The default is an in-memory store, so signing in inside a
    ///   preview or test never touches the session the real app restores at launch.
    init(service: any MediaService, state: SessionState, sessionStore: any SessionStore = InMemorySessionStore()) {
        // Downloads go in a throwaway folder, with no background session, so a preview never touches real ones.
        let store = DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "PreviewDownloads", directoryHint: .isDirectory))
        self.service = OfflineFallbackMediaService(base: service, store: store)
        self.downloads = DownloadManager(service: service, store: store, background: false)
        self.state = state
        // A preview's changes stay out of the real settings.
        self.homeSettings = HomeSettings(defaults: UserDefaults(suiteName: "HomeSettingsPreviews") ?? .standard)
        self.themeSettings = ThemeSettings(defaults: UserDefaults(suiteName: "ThemeSettingsPreviews") ?? .standard)
        self.playbackSettings = PlaybackSettings(defaults: UserDefaults(suiteName: "PlaybackSettingsPreviews") ?? .standard)
        self.support = SupportStore(defaults: UserDefaults(suiteName: "SupportPreviews") ?? .standard)
        self.sessionStore = sessionStore
        playbackSettings.scope = cacheScope
    }

    /// Call once at launch to pick up a saved session.
    ///
    /// Moves `state` to `.signedIn` if the keychain holds a session, otherwise `.signedOut`.
    /// The saved token isn't validated here; `refreshProfile()` notices if the server has rejected it.
    func restoreSession() async {
        let saved: UserSession?
        do {
            saved = try sessionStore.load()
        } catch {
            // Unreadable (e.g. from an incompatible older build). Treat as signed out rather than failing.
            Self.logger.error("Couldn't read the saved session: \(error.localizedDescription, privacy: .public)")
            saved = nil
        }

        guard let saved else {
            transition(to: .signedOut)
            return
        }
        await service.restore(saved)
        transition(to: .signedIn(saved))
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
            // The downloads stay, for when the same account signs back in.
            await signOut(removingDownloads: false)
            return
        } catch {
            return
        }

        // The user may have signed out, or switched accounts, while the request was in flight.
        guard updated != current, session?.userID == updated.userID else { return }
        persist(updated)
        transition(to: .signedIn(updated))
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
    ///
    /// - Parameter removingDownloads: Whether to delete downloads too. They're another person's data on a shared device,
    ///   but not worth losing because a session simply expired.
    func signOut(removingDownloads: Bool = true) async {
        playback?.stop()
        playback = nil
        // The saved token goes first, so it's gone even if the app is closed before the rest finishes. The service forgets
        // the session at once and revokes it on the server without waiting.
        sessionStore.delete()
        await service.signOut()
        // Counts learned for this account's shows.
        SeasonCountCache.shared.removeAll()
        // So the next person on a shared device doesn't see the previous user's artwork or profile picture.
        ImageCache.shared.removeAll()
        // Responses kept by the shared session, which earlier versions fetched subtitles with: their URLs carry the
        // access token.
        URLCache.shared.removeAllCachedResponses()
        // Likewise their downloaded videos and details. Other accounts' downloads on the device stay.
        if removingDownloads {
            downloads.removeAllForAccount()
            playbackSettings.removeSubtitleOffsets()
        } else {
            // The downloads stay, but not the access token that paused ones keep to carry on with.
            downloads.discardResumeData()
        }
        transition(to: .signedOut)
    }

    private func finishSignIn(_ session: UserSession) {
        persist(session)
        transition(to: .signedIn(session))
    }

    /// Moves to a new state, and shows the downloads of whoever that leaves signed in.
    private func transition(to newState: SessionState) {
        state = newState
        downloads.accountChanged(scope: cacheScope, accessToken: session?.accessToken)
        playbackSettings.scope = cacheScope
    }

    /// Saves the session so the next launch is already signed in. A failure only costs that convenience,
    /// so it's logged rather than surfaced.
    private func persist(_ session: UserSession) {
        do {
            try sessionStore.save(session)
        } catch {
            Self.logger.error("Couldn't save the session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
