// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

/// Home settings saved by an earlier version, or by a later one, still load as much as they can.
@MainActor
struct HomeSettingsPersistenceTests {
    /// Defaults of their own, so the tests don't touch the app's or each other's.
    private func makeDefaults() -> UserDefaults {
        let name = "HomeSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func save(_ json: String, in defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: "homeSettings")
    }

    @Test func missingFieldsFallBackToTheirDefaultsAndTheRestLoad() {
        let defaults = makeDefaults()
        // Saved before most of today's settings existed.
        save(#"{"showsHero": false}"#, in: defaults)

        let settings = HomeSettings(defaults: defaults)

        #expect(!settings.showsHero)
        #expect(settings.heroOrder == .recentlyAdded)
        #expect(settings.sections == HomeSettings.Section.allCases)
    }

    @Test func unknownSectionsAreSkippedWithoutLosingTheOthers() {
        let defaults = makeDefaults()
        // "bogus" is a section some other version had.
        save(#"{"order": ["nextUp", "bogus", "continueWatching"], "hidden": ["bogus", "onThisDay"], "showsHero": false}"#, in: defaults)

        let settings = HomeSettings(defaults: defaults)

        // The order is kept, with the sections it left out added at the end.
        #expect(settings.sections == [.nextUp, .continueWatching, .onThisDay, .recentlyReleased, .recentlyAdded])
        #expect(!settings.isVisible(.onThisDay))
        #expect(settings.isVisible(.nextUp))
        #expect(!settings.showsHero)
    }

    @Test func anUnknownCarouselOrderFallsBackWithoutLosingTheOthers() {
        let defaults = makeDefaults()
        save(#"{"heroOrder": "mostWatched", "combinesUpNext": true, "heroHidesWatched": true}"#, in: defaults)

        let settings = HomeSettings(defaults: defaults)

        #expect(settings.heroOrder == .recentlyAdded)
        #expect(settings.combinesUpNext)
        #expect(settings.heroHidesWatched)
    }

    @Test func aWrongTypeCostsOnlyThatSetting() {
        let defaults = makeDefaults()
        save(#"{"showsHero": "yes", "combinesUpNext": true}"#, in: defaults)

        let settings = HomeSettings(defaults: defaults)

        #expect(settings.showsHero)
        #expect(settings.combinesUpNext)
    }

    @Test func settingsThatCantBeReadAreKeptApart() {
        let defaults = makeDefaults()
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "homeSettings")

        let settings = HomeSettings(defaults: defaults)

        #expect(settings.isDefault)
        #expect(defaults.data(forKey: "homeSettings.unreadable") == garbage)
    }

    @Test func changesSurviveBeingLoadedAgain() {
        let defaults = makeDefaults()
        let settings = HomeSettings(defaults: defaults)
        settings.setVisible(false, for: .recentlyAdded)
        settings.showsHero = false
        settings.heroOrder = .random
        settings.combinesUpNext = true
        settings.moveSection(.recentlyAdded, by: -1)
        let expectedSections = settings.sections

        let reloaded = HomeSettings(defaults: defaults)

        #expect(reloaded.sections == expectedSections)
        #expect(!reloaded.isVisible(.recentlyAdded))
        #expect(!reloaded.showsHero)
        #expect(reloaded.heroOrder == .random)
        #expect(reloaded.combinesUpNext)
    }
}
