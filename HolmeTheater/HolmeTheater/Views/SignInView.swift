// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Server address, then a username and password or Quick Connect. Either way it connects to the address itself.
///
/// Signing in updates `AppModel.state`, which makes `ContentView` swap this screen out,
/// so nothing here navigates on success.
struct SignInView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var address = ""

    /// The server the address was last checked against; cleared when the address changes. Connecting is part of
    /// signing in, so the user never has to do it as a step of its own.
    @State private var server: ServerInfo?
    @State private var username = ""
    @State private var password = ""

    /// The code to show while waiting for Quick Connect approval.
    @State private var quickConnectCode: String?

    /// The running Quick Connect flow; non-nil from tapping the button until it finishes or is cancelled.
    @State private var quickConnectTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// The server's own look for this screen, if it has set one up. Cleared when the address changes.
    @State private var branding: ServerBranding?

    /// How the user is signing in.
    private enum Method { case password, quickConnect }

    /// What's waiting on the user's answer to "this connection isn't encrypted", or nil when it isn't asking.
    @State private var pendingMethod: Method?

    /// Whether the user accepted an unencrypted connection to the address as it is now.
    @State private var allowsUnencrypted = false

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the user typed `http://` or `https://` themselves, in which case that's what's used as it is.
    private var typedScheme: Bool { trimmedAddress.contains("://") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $address)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitLabel(.next)
                        // Looks the server up now, so its branding shows before anything is typed into the form.
                        .onSubmit {
                            Task {
                                isWorking = true
                                errorMessage = nil
                                _ = await connectIfNeeded()
                                isWorking = false
                            }
                        }
                } header: {
                    Text("Server")
                } footer: {
                    if let server, server.url.scheme?.lowercased() == "http" {
                        // Plain HTTP is common for home servers, but the user should know it's not encrypted.
                        // Only the icon is orange: orange text is about 2:1 on the form's background in Light Mode.
                        Label {
                            Text("This connection isn't encrypted. Your password and what you watch can be seen by others on the same network.")
                        } icon: {
                            Image(systemName: "lock.open")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Type it however you like, with or without https://. Without it, a secure connection is tried first.")
                    }
                }

                Section("Quick Connect") {
                    if let code = quickConnectCode {
                        Text(code)
                            .font(.largeTitle.monospaced().bold())
                        Text("In another signed-in Jellyfin app, open Quick Connect and enter this code.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { cancelQuickConnect() }
                    } else if quickConnectTask != nil || isWorking {
                        ProgressView()
                    } else {
                        Button("Use Quick Connect") { Task { await signIn(using: .quickConnect) } }
                            .disabled(trimmedAddress.isEmpty)
                    }
                }

                Section {
                    // Content types let password managers and iCloud Keychain offer AutoFill.
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await signIn(using: .password) } }

                    Button("Sign In") { Task { await signIn(using: .password) } }
                        .disabled(trimmedAddress.isEmpty || username.isEmpty || isWorking)
                } header: {
                    if let server {
                        Text("Sign in to \(server.name)")
                    } else {
                        Text("Account")
                    }
                }

                if let disclaimer = branding?.loginDisclaimer {
                    Section {
                        Text(disclaimer)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
            // The server's splash screen behind the form, dimmed so the form stays readable.
            #if os(iOS)
            .scrollContentBackground(branding?.splashscreenURL == nil ? .automatic : .hidden)
            #endif
            .background {
                if let url = branding?.splashscreenURL {
                    CachedAsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                    .overlay(.black.opacity(0.45))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            // Over a picture the form's text needs the light-on-dark look to stay readable.
            .environment(\.colorScheme, branding?.splashscreenURL == nil ? colorScheme : .dark)
            .animation(.easeInOut, value: branding)
            // Once typing stops, looks the server up, so its branding is there without pressing anything. A failure
            // isn't shown: the address may only be half typed, and signing in will report it.
            .task(id: address) {
                guard !trimmedAddress.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                _ = await connectIfNeeded(reportsErrors: false)
            }
            .onChange(of: address) {
                // A different address means a different server; start over.
                server = nil
                branding = nil
                allowsUnencrypted = false
                cancelQuickConnect()
            }
            .alert("This Connection Isn't Encrypted", isPresented: Binding(
                get: { pendingMethod != nil },
                set: { if !$0 { pendingMethod = nil } }
            )) {
                Button("Continue") {
                    allowsUnencrypted = true
                    if let method = pendingMethod {
                        Task { await signIn(using: method) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Couldn't connect to \(server?.url.host() ?? trimmedAddress) securely, so this would use plain HTTP. Your password and what you watch can be seen by others on the same network.")
            }
        }
    }

    /// Connects to the typed address if that hasn't been done, then signs in with `method`. If the only connection that
    /// worked is unencrypted and the user didn't ask for that by typing `http://`, asks first, before anything is sent.
    private func signIn(using method: Method) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        guard await connectIfNeeded() else { return }

        if let server, server.url.scheme?.lowercased() == "http", !typedScheme, !allowsUnencrypted {
            pendingMethod = method
            return
        }

        switch method {
        case .password: await signInWithPassword()
        case .quickConnect: startQuickConnect()
        }
    }

    /// Connects to the typed address, if it hasn't been, and looks up the server's branding. Returns whether there's a
    /// server to sign in to; if not, `errorMessage` says why.
    private func connectIfNeeded(reportsErrors: Bool = true) async -> Bool {
        guard server == nil else { return true }
        let submitted = address
        do {
            let connected = try await appModel.connect(to: submitted)
            // The address was edited while connecting, so this result belongs to the old one.
            guard address == submitted else { return false }
            server = connected
            let fetched = await appModel.service.serverBranding()
            if address == submitted { branding = fetched }
            return address == submitted
        } catch {
            guard address == submitted else { return false }
            if reportsErrors { errorMessage = error.localizedDescription }
            return false
        }
    }

    private func signInWithPassword() async {
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
            // A cancelled attempt was already cleaned up by `cancelQuickConnect()`, and a newer attempt
            // may be running now; clearing state here would hide its code.
            guard !Task.isCancelled else { return }
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
