// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Approves another device's Quick Connect sign-in: you enter the code that device shows, and it's signed in as you.
struct QuickConnectAuthorizeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissAccount) private var dismissAccount

    @State private var code = ""
    @State private var isWorking = false

    /// Why the last attempt failed, until the code is changed.
    @State private var failure: String?

    /// How many digits the server's codes have.
    private static let codeLength = 6

    private var digits: String { code }

    var body: some View {
        Form {
            Section {
                CodeBoxes(code: $code, length: Self.codeLength)
                    .disabled(isWorking)
                    .listRowBackground(Color.clear)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    }
                    Text("On the device you want to sign in, choose Quick Connect, then enter the code it shows here.")
                }
            }

            Section {
                Button {
                    Task { await authorize() }
                } label: {
                    if isWorking { ProgressView() } else { Text("Authorize") }
                }
                .disabled(digits.count < Self.codeLength || isWorking)
            }
        }
        .navigationTitle("Quick Connect")
        .onChange(of: code) { failure = nil }
    }

    private func authorize() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await appModel.service.authorizeQuickConnect(code: digits)
            // Back to the tab the user was on, where the message shows.
            dismissAccount()
            appModel.toastMessage = String(localized: "Quick Connect approved")
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A code shown as a row of boxes, one per digit, like a PIN screen. A text field with no visible text sits over them and
/// takes the typing, so the keyboard, paste and the one-time-code suggestion all work.
private struct CodeBoxes: View {
    @Binding var code: String
    let length: Int

    @FocusState private var isFocused: Bool

    /// The binding the field edits, which keeps only digits (also dropping the space in a pasted "123 456") and cuts
    /// it off at `length`.
    private var digits: Binding<String> {
        Binding(
            get: { code },
            set: { code = String($0.filter(\.isNumber).prefix(length)) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<length, id: \.self) { index in
                let characters = Array(code)
                let isCurrent = isFocused && index == min(characters.count, length - 1)
                Text(index < characters.count ? String(characters[index]) : "")
                    .font(.title.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 52, minHeight: 64)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2 : 0)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        // Hidden from VoiceOver, which reads the field instead.
        .accessibilityHidden(true)
        .overlay {
            TextField("", text: digits)
                .focused($isFocused)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                // Nothing of the field shows: the boxes draw the digits.
                .foregroundStyle(.clear)
                .tint(.clear)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                // No placeholder, which would show in the first box, so VoiceOver gets its name here.
                .accessibilityLabel("Code")
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .task { isFocused = true }
    }
}

#Preview {
    NavigationStack {
        QuickConnectAuthorizeView()
    }
    .environment(AppModel.preview())
}
