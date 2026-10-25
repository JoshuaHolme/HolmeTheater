// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Server address → username/password or Quick Connect.
///
/// Signing in updates `AppModel.state`, which makes `ContentView` swap this screen out,
/// so nothing here navigates on success.
struct SignInView: View {
    @Environment(AppModel.self) private var appModel

    @State private var address = ""

    /// The server from the last successful Connect; reveals the sign-in sections once set.
    @State private var server: ServerInfo?
    @State private var username = ""
    @State private var password = ""

    /// The code to show while waiting for Quick Connect approval.
    @State private var quickConnectCode: String?

    /// The running Quick Connect flow; non-nil from tapping the button until it finishes or is cancelled.
    @State private var quickConnectTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server address", text: $address)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { Task { await connect() } }

                    Button("Connect") { Task { await connect() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }

                if let server {
                    Section("Sign in to \(server.name)") {
                        TextField("Username", text: $username)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .onSubmit { Task { await signIn() } }

                        Button("Sign In") { Task { await signIn() } }
                            .disabled(username.isEmpty || isWorking)
                    }

                    Section("Quick Connect") {
                        if let code = quickConnectCode {
                            Text(code)
                                .font(.largeTitle.monospaced().bold())
                            Text("In another signed-in Jellyfin app, open Quick Connect and enter this code.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Cancel", role: .cancel) { cancelQuickConnect() }
                        } else if quickConnectTask != nil {
                            ProgressView()
                        } else {
                            Button("Use Quick Connect") { startQuickConnect() }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sign In")
            .onChange(of: address) {
                // A different address means a different server; start over.
                server = nil
                cancelQuickConnect()
            }
        }
    }

    /// Checks the typed address and, on success, reveals the sign-in options.
    private func connect() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            server = try await appModel.connect(to: address)
        } catch {
            server = nil
            errorMessage = error.localizedDescription
        }
    }

    private func signIn() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await appModel.signIn(username: username, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startQuickConnect() {
        errorMessage = nil
        quickConnectTask = Task {
            do {
                try await appModel.signInWithQuickConnect { quickConnectCode = $0 }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            quickConnectCode = nil
            quickConnectTask = nil
        }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnectCode = nil
    }
}

#Preview {
    SignInView()
        .environment(AppModel.preview(signedIn: false))
}
