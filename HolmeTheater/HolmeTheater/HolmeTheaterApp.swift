// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// App entry point. Creates the shared `AppModel` and restores any saved session at launch.
@main struct HolmeTheaterApp: App {
    @State private var appModel = AppModel(service: HolmeTheaterApp.makeService())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appModel.downloads)
                // The seasonal theme's color, or the usual one.
                .tint(appModel.themeSettings.activeTheme?.accent)
                // Once for the app, however many windows it has.
                .task {
                    await appModel.launch(watchingPurchases: !ProcessInfo.processInfo.arguments.contains("-UseMockService"))
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
            } else if scenePhase == .background {
                // Downloads' changes are written in the background, and the app may be suspended any moment now.
                appModel.downloads.store.flush()
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
