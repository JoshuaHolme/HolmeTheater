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
        content
            .themeWash()
            #if os(tvOS)
            // The page lays itself out, like the Settings app's account pages, with no title of its own.
            .navigationTitle("")
            #else
            .navigationTitle("Account")
            #endif
            .confirmationDialog("Sign Out?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out and Delete Downloads", role: .destructive) {
                    Task { await appModel.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signing out will delete all of your downloads from this device. You'll have to download them again.")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvContent
        #else
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

            settingsSections
        }
        #endif
    }

    #if os(tvOS)
    /// Like the Settings app's account pages: who's signed in on the left, large, and what can be changed in a list beside it.
    private var tvContent: some View {
        HStack(spacing: 100) {
            if let session = appModel.session {
                VStack(spacing: 20) {
                    AvatarView(url: session.avatarURL, size: 300)
                        .padding(.bottom, 16)

                    Text(session.username)
                        .font(.largeTitle.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    VStack(spacing: 6) {
                        Text(session.server.name)
                            .font(.title3.weight(.medium))
                        Text(session.server.url.absoluteString)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }

            ScrollView {
                tvSettings
                    // Room for a focused row to lift and grow without touching the edge.
                    .padding(.horizontal, 40)
                    .padding(.vertical, 40)
            }
            // The scroll view would otherwise clip a focused row at its edges.
            .scrollClipDisabled()
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 60)
    }

    /// The settings as rows of their own, each a card button, with its explanation small and dim beneath. (A plain list draws
    /// its explanations the same as its rows, and clips a focused row.)
    private var tvSettings: some View {
        VStack(alignment: .leading, spacing: 44) {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink { QuickConnectAuthorizeView() } label: {
                    TVSettingsRow(title: "Quick Connect", showsChevron: true)
                }
                .buttonStyle(.card)
                caption("Sign in on another device without typing a password, using the code it shows.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    appModel.playbackSettings.autoPlaysNext.toggle()
                } label: {
                    // The same setting as the player's Autoplay button, so each shows what the other has set.
                    TVSettingsRow(title: "Autoplay Next Episode", value: appModel.playbackSettings.autoPlaysNext ? "On" : "Off")
                }
                .buttonStyle(.card)
                caption("When an episode ends, the next one starts by itself after a short countdown. Turn this off to stop at the end instead, with no \"Up Next\" card.")
            }

            VStack(alignment: .leading, spacing: 16) {
                NavigationLink { HomeSettingsView() } label: {
                    TVSettingsRow(title: "Home Screen", showsChevron: true)
                }
                .buttonStyle(.card)
                NavigationLink { ThemeSettingsView() } label: {
                    TVSettingsRow(title: "Themes", showsChevron: true)
                }
                .buttonStyle(.card)
            }

            Button(action: signOut) {
                TVSettingsRow(title: "Sign Out", isDestructive: true)
            }
            .buttonStyle(.card)
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
    }
    #endif

    /// Signs out. Downloads are deleted on sign out, so with any, make sure that's what the user wants.
    private func signOut() {
        if appModel.downloads.records.isEmpty {
            Task { await appModel.signOut() }
        } else {
            confirmsSignOut = true
        }
    }

    /// What the account's owner can change, and Sign Out.
    @ViewBuilder
    private var settingsSections: some View {
        Section {
            NavigationLink("Quick Connect") { QuickConnectAuthorizeView() }
        } footer: {
            Text("Sign in on another device without typing a password, using the code it shows.")
        }

        Section {
            // The same setting as the player's Autoplay button, so each shows what the other has set.
            Toggle("Autoplay Next Episode", isOn: Binding(
                get: { appModel.playbackSettings.autoPlaysNext },
                set: { appModel.playbackSettings.autoPlaysNext = $0 }
            ))
        } footer: {
            Text("When an episode ends, the next one starts by itself after a short countdown. Turn this off to stop at the end instead, with no \"Up Next\" card.")
        }

        Section {
            NavigationLink("Home Screen") { HomeSettingsView() }
            NavigationLink("Themes") { ThemeSettingsView() }
        }

        Section {
            Button("Sign Out", role: .destructive, action: signOut)
        }
    }
}

#if os(tvOS)
/// The inside of a settings row on Apple TV: its name, and then what it's set to or a chevron if it opens something.
struct TVSettingsRow: View {
    let title: LocalizedStringKey
    var value: LocalizedStringKey?
    var showsChevron = false
    var isDestructive = false

    /// A checkmark at the end, for the one chosen in a list of choices.
    var showsCheckmark = false

    /// An SF Symbol before the name.
    var systemImage: String?

    /// Whether the value is in the tint (an "On"), rather than the dim color.
    var highlightsValue = false

    var body: some View {
        HStack(spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 44)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Spacer(minLength: 16)
            if let value {
                Text(value)
                    .foregroundStyle(highlightsValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One choice in a page of choices.
struct TVChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String?

    var id: String { title }
}

/// A page of choices, as the Settings app has them: a row for each, the one chosen ticked. Choosing one saves it and goes
/// back.
struct TVChoicePage<Value: Hashable>: View {
    let title: String
    let options: [TVChoiceOption<Value>]
    @Binding var selection: Value

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                    dismiss()
                } label: {
                    TVSettingsRow(
                        title: LocalizedStringKey(option.title),
                        showsCheckmark: option.value == selection,
                        systemImage: option.systemImage
                    )
                }
                .buttonStyle(.card)
            }
        }
        .tvSettingsPage(title: title)
    }
}

/// A settings row that switches something on or off, showing which it is, like the Settings app's.
struct TVToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            TVSettingsRow(title: title, value: isOn ? "On" : "Off", highlightsValue: isOn)
        }
        .buttonStyle(.card)
    }
}

/// The small heading over a group of settings rows.
struct TVSettingsHeading: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Layout.shelfHeadingFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a group of settings rows does, small and dim beneath them.
struct TVSettingsCaption: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
    }
}

extension View {
    /// A page of settings rows on Apple TV: a heading, then one centered column, with room around the rows for a focused one to
    /// lift without being clipped.
    func tvSettingsPage(title: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                self
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
        .scrollClipDisabled()
        .navigationTitle("")
        .themeWash()
    }
}
#endif

#Preview {
    NavigationStack {
        AccountView()
    }
    .environment(AppModel.preview())
}
