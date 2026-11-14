// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

@MainActor
struct DetailLinesTests {
    @Test func detailLineJoinsGenresAndNetwork() {
        let show = Sample.series(genres: ["Comedy", "Drama"], network: "HBO")
        #expect(show.detailLine == "Comedy · Drama · HBO")
        #expect(Sample.series().detailLine == nil)
    }

    @Test func endedShowShowsYearsRange() {
        let show = Sample.series(year: 1999, endYear: 2006, status: "Ended")
        #expect(show.showRunLine == "Ended · 1999–2006")
    }

    @Test func continuingShowRunsToPresent() {
        let show = Sample.series(year: 2019, endYear: nil, status: "Continuing")
        #expect(show.showRunLine?.contains("2019–") == true)
    }

    @Test func heroStatusLineDependsOnKind() {
        #expect(Sample.series(year: 2019, status: "Ended").heroStatusLine == "Ended · 2019")
        #expect(Sample.movie(year: 2020, runtime: 7200).heroStatusLine?.hasPrefix("2020") == true)
    }

    @Test func ratingsLineIncludesTheContentRatingOnlyWhenAsked() {
        let movie = Sample.movie(officialRating: "PG-13", communityRating: 8.7, criticRating: 92)
        #expect(movie.ratingsLine(includingOfficialRating: true)?.hasPrefix("PG-13") == true)
        let withoutRating = movie.ratingsLine(includingOfficialRating: false)
        #expect(withoutRating?.contains("PG-13") == false)
        #expect(withoutRating?.contains("★ 8.7") == true)
    }

    @Test func ratingsLineIsNilWithNothingToShow() {
        #expect(Sample.movie().ratingsLine(includingOfficialRating: true) == nil)
    }
}
