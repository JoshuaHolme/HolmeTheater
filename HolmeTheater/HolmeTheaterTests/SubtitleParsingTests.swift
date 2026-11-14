// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import Testing
@testable import HolmeTheater

struct WebVTTTests {
    @Test func parsesTimingAndText() {
        let cues = WebVTT.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello world")
        #expect(cues.count == 1)
        #expect(cues.first?.start == 1)
        #expect(cues.first?.end == 2.5)
        #expect(cues.first?.text == "Hello world")
        #expect(cues.first?.placement == nil)
    }

    @Test func stripsTagsAndDecodesEntities() {
        let cues = WebVTT.parse("WEBVTT\n\n00:00.000 --> 00:01.000\n<i>Yes</i> &amp; no")
        #expect(cues.first?.text == "Yes & no")
    }

    @Test func readsAnEmbeddedTopAlignmentTag() {
        // A track converted from SubStation Alpha keeps its "{\an8}" (top center) tag in the text.
        let cues = WebVTT.parse("WEBVTT\n\n00:00.000 --> 00:01.000\n{\\an8}Up top")
        #expect(cues.first?.text == "Up top")
        #expect(cues.first?.placement?.vertical == .start)
    }

    @Test func cueSettingsMoveThePlacement() {
        let cues = WebVTT.parse("WEBVTT\n\n00:00.000 --> 00:01.000 line:0%\nTop")
        #expect(cues.first?.placement != nil)
    }

    @Test func sortsCuesByStart() {
        let cues = WebVTT.parse("WEBVTT\n\n00:05.000 --> 00:06.000\nLater\n\n00:01.000 --> 00:02.000\nEarlier")
        #expect(cues.map(\.text) == ["Earlier", "Later"])
    }
}

struct SubStationAlphaTests {
    private static let script = """
    [Script Info]
    PlayResX: 1920
    PlayResY: 1080
    [V4+ Styles]
    Format: Name, Alignment, MarginL, MarginR, MarginV
    Style: Default,2,0,0,0
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello
    Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\an8}Up top
    """

    @Test func parsesDialogueLines() {
        let cues = SubStationAlpha.parse(Self.script)
        #expect(cues.count == 2)
        #expect(cues.first?.text == "Hello")
        #expect(cues.first?.start == 1)
    }

    @Test func honoursAnOverrideAlignment() {
        let cues = SubStationAlpha.parse(Self.script)
        #expect(cues.last?.text == "Up top")
        #expect(cues.last?.placement?.vertical == .start)
    }

    @Test func joinsHardLineBreaks() {
        let script = Self.script + "\nDialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,First\\NSecond"
        #expect(SubStationAlpha.parse(script).last?.text == "First\nSecond")
    }

    @Test func fallsBackToTheDefaultResolution() {
        #expect(SubStationAlpha.playResolution(width: nil, height: nil) == (384, 288))
        // One side given means a 4:3 picture.
        #expect(SubStationAlpha.playResolution(width: 1280, height: nil).height == 1024)
    }

    @Test func mapsLegacyAlignmentsToTheKeypad() {
        #expect(SubStationAlpha.keypad(fromLegacy: 5) == 7) // legacy top-left
        #expect(SubStationAlpha.keypad(fromLegacy: 2) == 2) // bottom center unchanged
    }
}

struct PictureSubtitleTests {
    private func cue(start: TimeInterval, end: TimeInterval) -> PictureSubtitleCue {
        PictureSubtitleCue(start: start, end: end, canvas: .zero, placements: [], palette: [])
    }

    @Test func findsTheCueShowingAtATime() {
        let cues = [cue(start: 0, end: 2), cue(start: 5, end: 7)]
        #expect(cues.index(at: 1) == 0)
        #expect(cues.index(at: 6) == 1)
        #expect(cues.index(at: 3) == nil) // in the gap
        #expect(cues.index(at: 2) == nil) // end is exclusive
    }

    @Test func canvasMatchesTheVideoWhenShapesAgree() {
        let video = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(PictureSubtitle.canvasFrame(CGSize(width: 1920, height: 1080), onVideo: video) == video)
    }

    @Test func anHDCanvasIsCenteredOnACroppedVideo() {
        // A 1920×1080 subtitle canvas over a cropped 1920×800 video keeps the canvas's scale and centers it.
        let video = CGRect(x: 0, y: 0, width: 1920, height: 800)
        let frame = PictureSubtitle.canvasFrame(CGSize(width: 1920, height: 1080), onVideo: video)
        #expect(frame.width == 1920)
        #expect(frame.height == 1080)
        #expect(frame.midY == video.midY)
    }
}
