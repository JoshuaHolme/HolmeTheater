// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

struct DirectPlayFailuresTests {
    /// Defaults of their own, so the tests don't touch the app's or each other's.
    private func makeDefaults() -> UserDefaults {
        let name = "DirectPlayFailuresTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nothingIsNotedAtFirst() {
        #expect(!DirectPlayFailures.contains(Sample.movie(id: "m"), defaults: makeDefaults()))
    }

    @Test func aNotedMovieIsFound() {
        let defaults = makeDefaults()
        let movie = Sample.movie(id: "m")
        DirectPlayFailures.record(movie, defaults: defaults)
        #expect(DirectPlayFailures.contains(movie, defaults: defaults))
        #expect(!DirectPlayFailures.contains(Sample.movie(id: "other"), defaults: defaults))
    }

    @Test func aNoteExpiresAfterItsLifetime() {
        let defaults = makeDefaults()
        let movie = Sample.movie(id: "m")
        let start = Date(timeIntervalSince1970: 1_000_000)
        DirectPlayFailures.record(movie, defaults: defaults, now: start)

        #expect(DirectPlayFailures.contains(movie, defaults: defaults, now: start.addingTimeInterval(DirectPlayFailures.lifetime - 1)))
        #expect(!DirectPlayFailures.contains(movie, defaults: defaults, now: start.addingTimeInterval(DirectPlayFailures.lifetime + 1)))
    }

    @Test func recordingDropsNotesThatHaveExpired() {
        let defaults = makeDefaults()
        let old = Sample.movie(id: "old")
        let start = Date(timeIntervalSince1970: 1_000_000)
        DirectPlayFailures.record(old, defaults: defaults, now: start)

        let later = start.addingTimeInterval(DirectPlayFailures.lifetime + 10)
        DirectPlayFailures.record(Sample.movie(id: "new"), defaults: defaults, now: later)

        // Even asked about as of the old note's own time, it's gone.
        #expect(!DirectPlayFailures.contains(old, defaults: defaults, now: start))
        #expect(DirectPlayFailures.contains(Sample.movie(id: "new"), defaults: defaults, now: later))
    }

    @Test func directPlayStaysOnByDefault() {
        #expect(PlaybackOptions().allowsDirectPlay)
        // So an item with no options set still counts as the plain request (see `OfflineFallbackMediaService`).
        var options = PlaybackOptions()
        options.allowsDirectPlay = false
        #expect(options != PlaybackOptions())
    }
}
