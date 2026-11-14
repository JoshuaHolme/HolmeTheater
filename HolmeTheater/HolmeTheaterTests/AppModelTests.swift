// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

@MainActor
struct AppModelTests {
    private func model(sessionStore: any SessionStore = InMemorySessionStore()) -> AppModel {
        AppModel(service: MockMediaService(latency: .zero), state: .signedOut, sessionStore: sessionStore)
    }

    @Test func startsSignedOut() {
        let app = model()
        #expect(app.session == nil)
        if case .signedOut = app.state {} else { Issue.record("expected signed out") }
    }

    @Test func signInStoresAndExposesTheSession() async throws {
        let store = InMemorySessionStore()
        let app = model(sessionStore: store)
        try await app.signIn(username: "demo", password: "pw")
        #expect(app.session?.username == "demo")
        // It was persisted, so the next launch restores it.
        #expect(try store.load() != nil)
    }

    @Test func signOutClearsTheSessionAndStore() async throws {
        let store = InMemorySessionStore()
        let app = model(sessionStore: store)
        try await app.signIn(username: "demo", password: "pw")
        await app.signOut()
        #expect(app.session == nil)
        #expect(try store.load() == nil)
    }

    @Test func restoreSignsInFromASavedSession() async {
        let app = model(sessionStore: InMemorySessionStore(session: .preview))
        await app.restoreSession()
        #expect(app.session == .preview)
    }

    @Test func restoreWithNothingSavedStaysSignedOut() async {
        let app = model()
        await app.restoreSession()
        #expect(app.session == nil)
    }

    @Test func cacheScopeIdentifiesTheAccountAndServer() async throws {
        let app = model()
        #expect(app.cacheScope.isEmpty)
        try await app.signIn(username: "demo", password: "pw")
        #expect(app.cacheScope.contains("mock-user"))
    }
}
