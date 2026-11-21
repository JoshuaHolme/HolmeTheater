// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

struct SupportStoreTests {
    private typealias Record = SupportStore.TipRecord

    @Test func noPurchasesIsNotASupporter() {
        #expect(!SupportStore.isSupporter(from: []))
    }

    @Test func oneTipMakesASupporter() {
        #expect(SupportStore.isSupporter(from: [Record(productID: SupportStore.Tip.medium.productID, isRevoked: false)]))
    }

    @Test func aRefundedTipDoesNotCountButAnotherStillDoes() {
        let refunded = Record(productID: SupportStore.Tip.small.productID, isRevoked: true)
        let kept = Record(productID: SupportStore.Tip.large.productID, isRevoked: false)
        #expect(SupportStore.isSupporter(from: [refunded, kept]))
        #expect(!SupportStore.isSupporter(from: [refunded]))
    }

    @Test func otherProductsAreIgnored() {
        #expect(!SupportStore.isSupporter(from: [Record(productID: "tech.holme.theater.something.else", isRevoked: false)]))
    }

    @Test func everyTipHasItsOwnProductID() {
        let ids = SupportStore.Tip.allCases.map(\.productID)
        #expect(Set(ids).count == ids.count)
        for tip in SupportStore.Tip.allCases {
            #expect(SupportStore.Tip(productID: tip.productID) == tip)
        }
    }

    @Test func badgePreferenceSurvivesAReload() throws {
        let defaults = try #require(UserDefaults(suiteName: "SupportStoreTests-\(UUID().uuidString)"))
        let first = SupportStore(defaults: defaults)
        #expect(first.showsBadge)
        first.showsBadge = false
        #expect(!SupportStore(defaults: defaults).showsBadge)
    }
}
