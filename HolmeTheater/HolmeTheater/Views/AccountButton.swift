// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Closes the account sheet. Call it like a function.
struct DismissAccountAction: Equatable {
    let action: () -> Void

    func callAsFunction() { action() }

    /// Any two are equal: there's only ever one account sheet open, and every action closes it the same way, through the
    /// same binding. Without this, the environment couldn't tell a new action from the old one, and would update every
    /// view reading it each time.
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Closes the account sheet, from any screen pushed inside it. Does nothing outside one.
    @Entry var dismissAccount = DismissAccountAction {}
}

/// The account screen wrapped for presentation in a sheet, with a Done button.
private struct AccountSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            AccountView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
        }
        // On the stack itself, so the screens it pushes get it too; set on the root view, they may not.
        .environment(\.dismissAccount, DismissAccountAction { isPresented = false })
    }
}

/// A round Liquid Glass profile button that presents `AccountView` in a sheet.
/// It shows the signed-in user's profile picture, or a generic person icon if they don't have one.
///
/// It draws its own glass circle, so it works over any content (e.g. hero artwork) without extra
/// styling. Use it directly to place the button inside your own layout, or use `.accountButton()`
/// to put a system-styled one in a navigation bar.
struct AccountButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            // The picture sits inside a thin rim of glass.
            AvatarView(url: appModel.session?.avatarURL, size: 38)
                .supporterBadge(size: 38)
                // A 44pt circle is the minimum comfortable touch target.
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .sheet(isPresented: $isPresented) {
            AccountSheet(isPresented: $isPresented)
        }
    }
}

/// Adds a profile button to the navigation bar that presents `AccountView` in a sheet.
private struct AccountToolbarModifier: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Account is its own tab in the sidebar on tvOS, so there's no toolbar button.
        content
        #else
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresented = true
                    } label: {
                        // The user's profile picture, or a generic person icon if they have none. The bar draws the
                        // glass around it, and the picture nearly fills it, as in the App Store.
                        AvatarView(url: appModel.session?.avatarURL, size: 40)
                            .supporterBadge(size: 40)
                    }
                    .accessibilityLabel("Account")
                }
            }
            .sheet(isPresented: $isPresented) {
                AccountSheet(isPresented: $isPresented)
            }
        #endif
    }
}

extension View {
    /// Adds a profile button to the navigation bar that opens the account screen in a sheet.
    /// Apply to the root view of a `NavigationStack`.
    func accountButton() -> some View {
        modifier(AccountToolbarModifier())
    }
}

#Preview("Button") {
    // Colorful content behind the button, so the glass has something to refract.
    ZStack {
        LinearGradient(colors: [.purple, .orange, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        AccountButton()
    }
    .environment(AppModel.preview())
}

#Preview("Toolbar") {
    NavigationStack {
        Text("Content")
            .navigationTitle("Title")
            .accountButton()
    }
    .environment(AppModel.preview())
}
