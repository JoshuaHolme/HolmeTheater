// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import StoreKit
import SwiftUI

/// The Concession Stand: optional tips, each a snack bought for the projectionist. Nothing in the app is locked behind
/// them; leaving one only earns a few cosmetic thank-yous.
struct SupportView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.purchase) private var purchase

    /// The tip being bought, so its row can show it and the others can't be started meanwhile.
    @State private var buying: String?

    private var support: SupportStore { appModel.support }

    private static let pitch: LocalizedStringKey = "Holme Theater is free and open source, with no ads, no tracking, and nothing locked. If it has become part of your movie nights, you can buy the projectionist a snack. Tip as often as you like, or never."

    var body: some View {
        content
            .themeWash()
            #if os(tvOS)
            .navigationTitle("")
            #else
            .navigationTitle("Concession Stand")
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await support.loadProducts() }
            #if !os(tvOS)
            // On Apple TV, MainView shows it, so it can also hold back the sidebar.
            .supportCelebration()
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                Text("Concession Stand")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    TVSettingsCaption(text: "Buy the projectionist a snack")
                    TVSettingsCaption(text: Self.pitch)
                }
                VStack(alignment: .leading, spacing: 16) {
                    if support.products.isEmpty {
                        TVSettingsCaption(text: support.isLoadingProducts ? "Loading…" : "The snack bar is closed right now. Try again later.")
                    }
                    ForEach(support.products) { product in
                        Button { buy(product) } label: {
                            TVSettingsRow(title: LocalizedStringKey(title(for: product)), value: LocalizedStringKey(product.displayPrice))
                        }
                        .buttonStyle(.card)
                        .disabled(buying != nil)
                    }
                }
                if support.isSupporter {
                    VStack(alignment: .leading, spacing: 14) {
                        TVToggleRow(title: "Show Supporter Badge", isOn: Bindable(support).showsBadge)
                        TVSettingsCaption(text: "A little popcorn bucket on your profile picture. Thank you for supporting Holme Theater.")
                    }
                }
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
        .scrollClipDisabled()
        #else
        List {
            Section {
                Text(Self.pitch)
                    // Plain text under its heading, not a row in a box.
                    .listRowBackground(Color.clear)
            } header: {
                Text("Buy the projectionist a snack")
            }

            Section {
                if support.products.isEmpty {
                    Text(support.isLoadingProducts ? "Loading…" : "The snack bar is closed right now. Try again later.")
                        .foregroundStyle(.secondary)
                }
                ForEach(support.products) { product in
                    Button { buy(product) } label: {
                        LabeledContent(title(for: product), value: product.displayPrice)
                            .contentShape(Rectangle())
                    }
                    // The default button style tints the title with the theme's color, so use the plain one.
                    .buttonStyle(.plain)
                    .disabled(buying != nil)
                }
            } footer: {
                Text("Tips are optional and never unlock anything you need.")
            }

            if support.isSupporter {
                Section {
                    Toggle("Show Supporter Badge", isOn: Bindable(support).showsBadge)
                } header: {
                    Text("Thank You")
                } footer: {
                    Text("A little popcorn bucket on your profile picture. Thank you for supporting Holme Theater.")
                }
            }
        }
        #endif
    }

    /// A product's emoji and its name, e.g. "🍿 Popcorn".
    private func title(for product: Product) -> String {
        guard let tip = SupportStore.Tip(productID: product.id) else { return product.displayName }
        return "\(tip.emoji) \(product.displayName)"
    }

    private func buy(_ product: Product) {
        guard buying == nil else { return }
        buying = product.id
        Task {
            defer { buying = nil }
            guard let result = try? await purchase(product) else { return }
            await support.complete(result)
        }
    }
}

#Preview {
    NavigationStack {
        SupportView()
    }
    .environment(AppModel.preview())
}
