// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Root view: picks between launch, sign-in, and the main app based on session state.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        switch appModel.state {
        case .launching:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn:
            MainView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel(service: MockMediaService()))
}
