// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Who is signed in to which server, with a Sign Out button.
struct AccountView: View {
    @Environment(AppModel.self) private var appModel

    /// Whether the warning that sign out deletes the downloads is showing.
    @State private var confirmsSignOut = false

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
                NavigationLink("Quick Connect") { QuickConnectAuthorizeView() }
            } footer: {
                Text("Sign in on another device without typing a password, using the code it shows.")
            }

            Section {
                NavigationLink("Home Screen") { HomeSettingsView() }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    // Downloads are deleted on sign out, so with any, make sure that's what the user wants.
                    if appModel.downloads.records.isEmpty {
                        Task { await appModel.signOut() }
                    } else {
                        confirmsSignOut = true
                    }
                }
            }
        }
        .navigationTitle("Account")
        .confirmationDialog("Sign Out?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out and Delete Downloads", role: .destructive) {
                Task { await appModel.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out will delete all of your downloads from this device. You'll have to download them again.")
        }
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
    .environment(AppModel.preview())
}
