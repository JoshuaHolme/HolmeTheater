// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

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
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresented = true
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $isPresented) {
                AccountSheet(isPresented: $isPresented)
            }
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
