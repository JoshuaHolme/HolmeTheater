// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

struct SubtitleCueIndexTests {
    private func cue(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: text)
    }

    @Test func findsNothingInAnEmptyTrack() {
        #expect(SubtitleCueIndex.empty.cues(at: 5).isEmpty)
        #expect(SubtitleCueIndex.empty.isEmpty)
    }

    @Test func startIsInclusiveAndEndIsExclusive() {
        let index = SubtitleCueIndex([cue(1, 2, "a")])
        #expect(index.cues(at: 0.99).isEmpty)
        #expect(index.cues(at: 1).map(\.text) == ["a"])
        #expect(index.cues(at: 1.99).map(\.text) == ["a"])
        #expect(index.cues(at: 2).isEmpty)
    }

    @Test func findsOverlappingLinesAndALongOneThatStartedEarlier() {
        // A sign that stays up for a minute, with dialogue coming and going under it.
        let index = SubtitleCueIndex([cue(0, 60, "sign"), cue(10, 12, "one"), cue(11, 13, "two"), cue(20, 22, "three")])
        #expect(index.cues(at: 11.5).map(\.text) == ["sign", "one", "two"])
        #expect(index.cues(at: 21).map(\.text) == ["sign", "three"])
        #expect(index.cues(at: 61).isEmpty)
    }

    @Test func keepsTheFilesOrderNotTheStartOrder() {
        // Drawn in the order the file has them, so a later line in the file goes on top even if it started first.
        let index = SubtitleCueIndex([cue(5, 10, "outline"), cue(4, 10, "fill")])
        #expect(index.cues(at: 6).map(\.text) == ["outline", "fill"])
    }

    @Test func matchesALinearScanOverManyLines() {
        var generator = SeededGenerator(seed: 42)
        let cues = (0..<2000).map { number -> SubtitleCue in
            let start = Double.random(in: 0..<3600, using: &generator)
            return cue(start, start + Double.random(in: 0.1..<8, using: &generator), "\(number)")
        }
        let index = SubtitleCueIndex(cues)
        for _ in 0..<500 {
            let time = Double.random(in: 0..<3610, using: &generator)
            let expected = cues.filter { $0.start <= time && time < $0.end }.map(\.text)
            #expect(index.cues(at: time).map(\.text) == expected)
        }
    }
}

@MainActor
struct SubtitleControllerTests {
    private func track(_ contents: String, format: SubtitleFormat) throws -> MediaTrack {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).vtt")
        try Data(contents.utf8).write(to: file)
        return MediaTrack(index: 3, title: "English", isExternal: true, url: file, format: format)
    }

    /// Waits for the controller to have read the track, which it does in the background.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func showsATrackAndShiftsItByTheOffset() async throws {
        let controller = SubtitleController(service: MockMediaService(latency: .zero))
        controller.show(try track("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n", format: .webVTT))
        try await waitUntil { controller.text(at: 1.5) != nil }
        #expect(controller.text(at: 1.5) == "Hello")

        // Shown a second later.
        controller.offset = 1
        #expect(controller.text(at: 1.5) == nil)
        #expect(controller.text(at: 2.5) == "Hello")
    }

    @Test func clearsTheLinesWithNoTrack() async throws {
        let controller = SubtitleController(service: MockMediaService(latency: .zero))
        controller.show(try track("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n", format: .webVTT))
        try await waitUntil { controller.text(at: 1.5) != nil }
        controller.show(nil)
        #expect(controller.text(at: 1.5) == nil)
    }

    @Test func requestsTheReplayTrackOnlyOnceUntilTheTracksChange() throws {
        let controller = SubtitleController(service: MockMediaService(latency: .zero))
        let replay = try track("WEBVTT\n", format: .webVTT)
        controller.loadReplay(replay)
        #expect(controller.hasRequestedReplay)
        controller.show(nil)
        #expect(!controller.hasRequestedReplay)
    }
}

struct StreamQualityTests {
    private func info(url: URL, bitrate: Int?, height: Int?) -> PlaybackInfo {
        PlaybackInfo(url: url, resumePosition: 0, playSessionID: nil, mediaSourceID: nil, method: .transcode,
                     sourceBitrate: bitrate, sourceHeight: height)
    }

    @Test func offersOnlyCapsBelowTheFileAndNoTallerThanIt() throws {
        let url = try #require(URL(string: "https://jellyfin.example.com/stream"))
        let choices = StreamQuality.choices(for: info(url: url, bitrate: 25_000_000, height: 1080))
        #expect(choices.map(\.maxBitrate) == [20_000_000, 10_000_000, 4_000_000, 1_500_000, 720_000])
    }

    @Test func offersEveryCapWhenTheFileIsUnknown() throws {
        let url = try #require(URL(string: "https://jellyfin.example.com/stream"))
        #expect(StreamQuality.choices(for: info(url: url, bitrate: nil, height: nil)).count == 7)
    }

    @Test func offersNothingForADownloadedFile() {
        #expect(StreamQuality.choices(for: info(url: URL(filePath: "/tmp/video.mp4"), bitrate: 25_000_000, height: 1080)).isEmpty)
    }
}

/// A predictable source of random numbers, so a test that goes through many random cases fails the same way each time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
