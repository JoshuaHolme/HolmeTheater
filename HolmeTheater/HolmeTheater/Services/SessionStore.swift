// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Synchronization

/// Where the signed-in session is kept between launches. The app uses the Keychain; tests use an in-memory store so
/// they never touch the real device's saved session.
nonisolated protocol SessionStore: Sendable {
    /// The saved session, or nil if there isn't one. Throws if the store exists but can't be read (e.g. data from an
    /// incompatible older build).
    func load() throws -> UserSession?

    /// Saves the session, replacing any already saved.
    func save(_ session: UserSession) throws

    /// Forgets the saved session, if there is one.
    func delete()
}

/// A ``SessionStore`` backed by the Keychain, under one account in a ``KeychainStore``'s namespace.
nonisolated struct KeychainSessionStore: SessionStore {
    private let keychain: KeychainStore
    private let account: String

    init(keychain: KeychainStore, account: String = "session") {
        self.keychain = keychain
        self.account = account
    }

    func load() throws -> UserSession? { try keychain.load(UserSession.self, account: account) }
    func save(_ session: UserSession) throws { try keychain.save(session, account: account) }
    func delete() { keychain.delete(account: account) }
}

/// A ``SessionStore`` that keeps the session in memory only, for previews and tests. Safe to use from any thread.
nonisolated final class InMemorySessionStore: SessionStore {
    private let saved = Mutex<UserSession?>(nil)

    /// - Parameter session: The session to start with, as if it had been saved on a previous launch.
    init(session: UserSession? = nil) {
        saved.withLock { $0 = session }
    }

    func load() throws -> UserSession? { saved.withLock { $0 } }
    func save(_ session: UserSession) throws { saved.withLock { $0 = session } }
    func delete() { saved.withLock { $0 = nil } }
}
