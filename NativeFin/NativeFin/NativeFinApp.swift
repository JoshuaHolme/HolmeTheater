// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// App entry point. Creates the shared `AppModel` and restores any saved session at launch.
@main struct NativeFinApp: App {
    @State private var appModel = AppModel(service: NativeFinApp.makeService())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .task { await appModel.restoreSession() }
        }
    }

    /// Pass `-UseMockService` as a launch argument to run against canned data instead of a real server.
    private static func makeService() -> any MediaService {
        if ProcessInfo.processInfo.arguments.contains("-UseMockService") {
            return MockMediaService()
        }
        return JellyfinMediaService(identity: .current())
    }
}
