// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Root view: picks between launch, sign-in, and the main app based on session state.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Each screen fades in over the one before, so the launch spinner doesn't cut to the app.
        ZStack {
            switch appModel.state {
            case .launching:
                ProgressView()
                    .transition(.opacity)
            case .signedOut:
                SignInView()
                    .transition(.opacity)
            case .signedIn:
                MainView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: screen)
    }

    /// Which screen is showing, which is all the fade needs to tell apart (the signed-in state carries a session that
    /// isn't comparable).
    private var screen: Int {
        switch appModel.state {
        case .launching: 0
        case .signedOut: 1
        case .signedIn: 2
        }
    }
}

#Preview("Signed Out") {
    ContentView()
        .environment(AppModel.preview(signedIn: false))
}

#Preview("Signed In") {
    ContentView()
        .environment(AppModel.preview())
}

#Preview("Launching") {
    ContentView()
        .environment(AppModel(service: MockMediaService()))
}
