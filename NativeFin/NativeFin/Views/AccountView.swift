// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Who is signed in to which server, with a Sign Out button.
struct AccountView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        List {
            if let session = appModel.session {
                Section {
                    AvatarView(url: session.avatarURL, size: 96)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section("Account") {
                    LabeledContent("User", value: session.username)
                    LabeledContent("Server", value: session.server.name)
                    LabeledContent("Address", value: session.server.url.absoluteString)
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    Task { await appModel.signOut() }
                }
            }
        }
        .navigationTitle("Account")
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
    .environment(AppModel.preview())
}
