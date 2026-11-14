// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI
import Testing
@testable import HolmeTheater

struct HTMLEntitiesTests {
    @Test func decodesNamedAndNumericReferences() {
        #expect("Tom &amp; Jerry".decodingHTMLEntities() == "Tom & Jerry")
        #expect("a&nbsp;b".decodingHTMLEntities() == "a\u{00A0}b")
        #expect("&#39;quote&#39;".decodingHTMLEntities() == "'quote'")
        #expect("&#x2014;".decodingHTMLEntities() == "\u{2014}")
    }

    @Test func leavesUnknownAndBareAmpersandsAlone() {
        #expect("rock & roll".decodingHTMLEntities() == "rock & roll")
        #expect("&unknown;".decodingHTMLEntities() == "&unknown;")
        #expect("no entities here".decodingHTMLEntities() == "no entities here")
    }

    @Test func stripsTagsAndTurnsBreaksIntoNewlines() {
        #expect("<p>Hello<br>World</p>".strippingHTMLTags() == "Hello\nWorld")
        #expect("<b>Bold</b> &amp; plain".strippingHTMLTags() == "Bold & plain")
    }
}

struct ServerAddressTests {
    @Test func addsBothSchemesWhenNoneTyped() {
        let urls = ServerAddress.candidateURLs(from: "jellyfin.local:8096").map(\.absoluteString)
        #expect(urls == ["https://jellyfin.local:8096", "http://jellyfin.local:8096"])
    }

    @Test func keepsAnExplicitScheme() {
        #expect(ServerAddress.candidateURLs(from: "http://10.0.0.2").map(\.absoluteString) == ["http://10.0.0.2"])
    }

    @Test func rejectsEmptyAndNonWebSchemes() {
        #expect(ServerAddress.candidateURLs(from: "   ").isEmpty)
        #expect(ServerAddress.candidateURLs(from: "ftp://host").isEmpty)
    }

    @Test func sameOriginIgnoresDefaultPorts() {
        #expect(ServerAddress.isSameOrigin(URL(string: "https://h")!, URL(string: "https://h:443")!))
        #expect(!ServerAddress.isSameOrigin(URL(string: "https://h")!, URL(string: "http://h")!))
        #expect(!ServerAddress.isSameOrigin(URL(string: "https://a")!, URL(string: "https://b")!))
    }
}

struct AccessTokenURLTests {
    @Test func addsApiKeyWhenAbsent() {
        let url = URL(string: "https://h/stream?x=1")!.addingAccessToken("secret")
        #expect(url.absoluteString.contains("ApiKey=secret"))
        #expect(url.absoluteString.contains("x=1"))
    }

    @Test func doesNotDuplicateAnExistingKey() {
        let once = URL(string: "https://h/s?ApiKey=a")!.addingAccessToken("b")
        #expect(once.absoluteString == "https://h/s?ApiKey=a")
    }

    @Test func removesTokenInEitherCasing() {
        #expect(URL(string: "https://h/s?ApiKey=a&x=1")!.removingAccessToken().absoluteString == "https://h/s?x=1")
        #expect(URL(string: "https://h/s?api_key=a")!.removingAccessToken().absoluteString == "https://h/s")
        #expect(URL(string: "https://h/s?x=1")!.removingAccessToken().absoluteString == "https://h/s?x=1")
    }

    @Test func roundTripsThroughAddThenRemove() {
        let base = URL(string: "https://h/s?x=1")!
        #expect(base.addingAccessToken("tok").removingAccessToken() == base)
    }
}

struct TimeCodeTests {
    @Test func clockFormatsBelowAndAboveAnHour() {
        #expect(TimeCode.clock(0) == "00:00")
        #expect(TimeCode.clock(65) == "01:05")
        #expect(TimeCode.clock(3661) == "1:01:01")
    }

    @Test func clockTreatsNegativeAndNonFiniteAsZero() {
        #expect(TimeCode.clock(-5) == "00:00")
        #expect(TimeCode.clock(.infinity) == "00:00")
    }

    @Test func subtitleOffsetSignsAndTrims() {
        #expect(SubtitleOffset.text(0) == "0 s")
        #expect(SubtitleOffset.text(1.5) == "+1.5 s")
        #expect(SubtitleOffset.text(-0.25).hasPrefix("−0.2"))
    }

    @Test func skipTitleMatchesKind() {
        #expect(MediaSegment.Kind.intro.skipActionTitle == "Skip Intro")
        #expect(MediaSegment.Kind.outro.skipActionTitle == "Skip Outro")
        #expect(MediaSegment.Kind.unknown.skipActionTitle == "Skip")
    }
}

struct CarouselMathTests {
    @Test func wrapsVirtualIndexBothWays() {
        #expect(CarouselMath.index(forVirtual: 5, count: 3) == 2)
        #expect(CarouselMath.index(forVirtual: -1, count: 3) == 2)
        #expect(CarouselMath.index(forVirtual: 3, count: 3) == 0)
    }

    @Test func singleItemStaysAtZero() {
        #expect(CarouselMath.index(forVirtual: 7, count: 1) == 0)
    }

    @Test func stepsTakeTheShortWayRound() {
        #expect(CarouselMath.steps(from: 0, to: 1, count: 5) == 1)
        // From 0 to 4 of 5, back one step is shorter than forward four.
        #expect(CarouselMath.steps(from: 0, to: 4, count: 5) == -1)
    }

    @Test func dotWindowFollowsTheSelectionAndNeverGrows() {
        #expect(CarouselMath.visiblePositions(index: 0, count: 5, maxVisible: 8) == Array(0..<5))
        let window = CarouselMath.visiblePositions(index: 6, count: 12, maxVisible: 8)
        #expect(window.count == 8)
        #expect(window.contains(6))
        #expect(window.last! <= 11)
    }
}

struct UpNextTimingTests {
    @Test func usesTheOutroWhenItIsInTheSecondHalf() {
        #expect(UpNextTiming.appearance(duration: 1000, outroStart: 900) == 900)
    }

    @Test func ignoresAnOutroInTheFirstHalf() {
        // Falls back to 45s before the end.
        #expect(UpNextTiming.appearance(duration: 1000, outroStart: 100) == 955)
    }

    @Test func neverLaterThanTenSecondsBeforeTheEnd() {
        #expect(UpNextTiming.appearance(duration: 1000, outroStart: 999) == 990)
    }

    @Test func isShowingOnlyWithinTheWindow() {
        #expect(!UpNextTiming.isShowing(position: 100, duration: 1000, outroStart: 900))
        #expect(UpNextTiming.isShowing(position: 950, duration: 1000, outroStart: 900))
        #expect(!UpNextTiming.isShowing(position: 30, duration: 40, outroStart: nil)) // too short to offer
    }
}

struct HeroScrimTests {
    @Test func shortDetailsStartAtTheUsualPlace() {
        #expect(HeroScrim.start(heroHeight: 1000, detailsHeight: 100, bottomReserve: 0) == HeroScrim.usualStart)
    }

    @Test func tallDetailsPushTheFadeUp() {
        let start = HeroScrim.start(heroHeight: 1000, detailsHeight: 700, bottomReserve: 0)
        #expect(start < HeroScrim.usualStart)
        #expect(start >= 0)
    }

    @Test func stopsSpanFromTheStartToTheBottom() {
        let stops = HeroScrim.stops(start: 0.3, base: .black)
        #expect(stops.first?.location == 0.3)
        #expect(stops.last?.location == 1)
    }
}
