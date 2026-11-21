// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
import StoreKit

/// The Concession Stand: optional tips that thank the developer, and whether the user has left one.
///
/// Tips are consumable in-app purchases, so they can be bought again. Having tipped even once makes someone a
/// supporter, which unlocks only cosmetic thank-yous. Nothing in the app depends on it.
///
/// Supporter status is worked out from the Apple Account's purchase history (the app asks StoreKit to keep consumables
/// in it, with `SKIncludeConsumableInAppPurchaseHistory`), so it follows the user to a new device or a reinstall. It's
/// also kept on the device so the badge shows straight away, and offline.
@Observable
final class SupportStore {
    /// A snack, which is a tip.
    enum Tip: String, CaseIterable, Identifiable {
        case small, medium, large, generous

        var id: String { productID }

        /// The App Store product. These can never be renamed; the display names can, in App Store Connect.
        var productID: String { "tech.holme.theater.tip.\(rawValue)" }

        init?(productID: String) {
            guard let tip = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
            self = tip
        }

        var emoji: String {
            switch self {
            case .small: "🍬"
            case .medium: "🍿"
            case .large: "🥤"
            case .generous: "🎬"
            }
        }

        var snackName: String {
            switch self {
            case .small: String(localized: "Candy")
            case .medium: String(localized: "Popcorn")
            case .large: String(localized: "Combo")
            case .generous: String(localized: "Snack Bar Tab")
            }
        }
    }

    /// What supporter status needs to know about one purchase.
    struct TipRecord: Equatable {
        let productID: String
        let isRevoked: Bool
    }

    /// Whether any of `records` is a tip that stands: not refunded, and not some other product.
    static func isSupporter(from records: [TipRecord]) -> Bool {
        records.contains { !$0.isRevoked && Tip(productID: $0.productID) != nil }
    }

    /// The tips on offer, cheapest first. Empty until they've loaded from the App Store, or if they couldn't.
    private(set) var products: [Product] = []

    /// Whether the tips are still loading, so the screen can tell "loading" from "unavailable".
    private(set) var isLoadingProducts = false

    /// Whether the user has tipped, and not had every tip refunded.
    private(set) var isSupporter: Bool {
        didSet {
            guard isSupporter != oldValue else { return }
            defaults.set(isSupporter, forKey: Self.supporterKey)
        }
    }

    /// Whether the supporter badge shows on the profile picture. On unless it's been turned off.
    var showsBadge: Bool {
        didSet {
            guard showsBadge != oldValue else { return }
            defaults.set(showsBadge, forKey: Self.badgeKey)
        }
    }

    /// The snack just bought, while its thank-you is showing. The celebration clears it.
    var celebratedTip: Tip?

    /// Whether the supporter badge should show now.
    var displaysBadge: Bool { isSupporter && showsBadge }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    private static let supporterKey = "isSupporter"
    private static let badgeKey = "showsSupporterBadge"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "Support")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSupporter = defaults.bool(forKey: Self.supporterKey)
        showsBadge = defaults.object(forKey: Self.badgeKey) as? Bool ?? true
    }

    /// Call once at launch: finishes purchases left unfinished, checks the purchase history, and then keeps watching for
    /// purchases made elsewhere (e.g. on the user's other device, or approved later).
    func start() async {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refreshStatus()
            }
        }
        for await unfinished in Transaction.unfinished {
            if case .verified(let transaction) = unfinished { await transaction.finish() }
        }
        await refreshStatus()
    }

    /// Reads the purchase history and updates ``isSupporter`` from it.
    func refreshStatus() async {
        var records: [TipRecord] = []
        for await result in Transaction.all {
            // Unverified ones don't count.
            guard case .verified(let transaction) = result else { continue }
            records.append(TipRecord(productID: transaction.productID, isRevoked: transaction.revocationDate != nil))
        }
        isSupporter = Self.isSupporter(from: records)
    }

    /// Loads the tips from the App Store, if they haven't been.
    func loadProducts() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Tip.allCases.map(\.productID))
            products = loaded.sorted { lhs, rhs in
                (Tip(productID: lhs.id).flatMap(Tip.allCases.firstIndex(of:)) ?? 0)
                    < (Tip(productID: rhs.id).flatMap(Tip.allCases.firstIndex(of:)) ?? 0)
            }
        } catch {
            Self.logger.error("Couldn't load the tips: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Finishes a purchase the user made on the stand. A cancelled or pending one does nothing.
    func complete(_ result: Product.PurchaseResult) async {
        guard case .success(.verified(let transaction)) = result else { return }
        await transaction.finish()
        isSupporter = true
        celebratedTip = Tip(productID: transaction.productID)
    }
}
