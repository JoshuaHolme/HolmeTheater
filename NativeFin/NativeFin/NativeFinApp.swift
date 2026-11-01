// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// App entry point. Creates the shared `AppModel` and restores any saved session at launch.
@main struct NativeFinApp: App {
    @State private var appModel = AppModel(service: NativeFinApp.makeService())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appModel.downloads)
                .task {
                    await appModel.restoreSession()
                    await appModel.refreshProfile()
                }
        }
        // The system wakes the app when downloads finish while it's away. The session is already attached to the
        // download manager, so all that's left is to wait until it has been told what happened.
        .backgroundTask(.urlSession(DownloadManager.sessionIdentifier)) {
            await appModel.downloads.waitForBackgroundEvents()
        }
        // Pick up profile changes made elsewhere each time the app comes back to the foreground.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                appModel.themeSettings.refreshDate()
                Task { await appModel.refreshProfile() }
            }
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
