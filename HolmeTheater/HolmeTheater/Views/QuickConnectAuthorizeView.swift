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
        content
            #if os(tvOS)
            // The page lays itself out, with its heading in the column, as the sign-in screen does.
            .navigationTitle("")
            #else
            .navigationTitle("Quick Connect")
            #endif
            .onChange(of: code) { failure = nil }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvLayout
        #else
        form
        #endif
    }

    #if os(tvOS)
    /// One centered column with large controls, like the sign-in screen's, instead of a form stretched across the screen.
    private var tvLayout: some View {
        ScrollView {
            VStack(spacing: 44) {
                VStack(spacing: 12) {
                    Text("Quick Connect")
                        .font(.title2.weight(.semibold))
                    Text("On the device you want to sign in, choose Quick Connect, then enter the code it shows here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                CodeBoxes(code: $code, length: Self.codeLength)
                    .disabled(isWorking)

                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await authorize() }
                } label: {
                    Group {
                        if isWorking { ProgressView() } else { Text("Authorize") }
                    }
                    .frame(minWidth: 240)
                }
                // The same bordered pill as the other buttons that act on the page.
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(digits.count < Self.codeLength || isWorking)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
        .scrollClipDisabled()
    }
    #endif

    private var form: some View {
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

/// A code shown as a row of boxes, one per digit, like a PIN screen (on tvOS, only the field, which is all the remote can use). A text field with no visible text sits over them and
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

    #if !os(tvOS)
    /// The row of boxes, one per digit.
    private var boxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<length, id: \.self) { index in
                let characters = Array(code)
                let isCurrent = isFocused && index == min(characters.count, length - 1)
                Text(index < characters.count ? String(characters[index]) : "")
                    .font(.title.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: Self.boxWidth, minHeight: Self.boxHeight)
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
    }

    private static let boxWidth: CGFloat = 52
    private static let boxHeight: CGFloat = 64
    #endif

    var body: some View {
        #if os(tvOS)
        // A text field you can't see can't be focused with the remote, and the remote's keyboard shows what's typed in
        // the field itself, so on tvOS there are no boxes: just the field, with the code centered in it.
        TextField("Enter Code", text: digits)
            .focused($isFocused)
            .autocorrectionDisabled()
            .multilineTextAlignment(.center)
        #else
        boxes
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
        #endif
    }
}

#Preview {
    NavigationStack {
        QuickConnectAuthorizeView()
    }
    .environment(AppModel.preview())
}
