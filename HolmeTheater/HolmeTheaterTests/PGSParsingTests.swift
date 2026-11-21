// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import Testing
@testable import HolmeTheater

/// Builds `.sup` files, segment by segment, for the parser to read.
private struct SupFile {
    private(set) var bytes: [UInt8] = []

    private static func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    private mutating func segment(_ type: UInt8, at seconds: Double, _ body: [UInt8]) {
        let ticks = UInt32(seconds * 90_000)
        bytes += [0x50, 0x47]
        bytes += [UInt8(ticks >> 24), UInt8((ticks >> 16) & 0xFF), UInt8((ticks >> 8) & 0xFF), UInt8(ticks & 0xFF)]
        bytes += [0, 0, 0, 0]
        bytes += [type] + Self.u16(body.count) + body
    }

    /// A presentation composition: the canvas, and pictures placed on it, each with an optional crop.
    mutating func composition(
        at seconds: Double, canvas: (Int, Int) = (1920, 1080), paletteID: UInt8 = 0,
        objects: [(id: Int, x: Int, y: Int, crop: (Int, Int, Int, Int)?)]
    ) {
        var body = Self.u16(canvas.0) + Self.u16(canvas.1) + [0x10] + Self.u16(1) + [0x80, 0, paletteID, UInt8(objects.count)]
        for object in objects {
            body += Self.u16(object.id) + [0, object.crop == nil ? 0 : 0x80] + Self.u16(object.x) + Self.u16(object.y)
            if let crop = object.crop {
                body += Self.u16(crop.0) + Self.u16(crop.1) + Self.u16(crop.2) + Self.u16(crop.3)
            }
        }
        segment(0x16, at: seconds, body)
    }

    /// A palette with opaque white as colour 1.
    mutating func palette(at seconds: Double, id: UInt8 = 0) {
        segment(0x14, at: seconds, [id, 0, 1, 235, 128, 128, 255])
    }

    /// A picture in one segment.
    mutating func object(at seconds: Double, id: Int, width: Int, height: Int, rle: [UInt8]) {
        segment(0x15, at: seconds, Self.u16(id) + [0, 0xC0, 0, 0, 0] + Self.u16(width) + Self.u16(height) + rle)
    }

    mutating func end(at seconds: Double) {
        segment(0x80, at: seconds, [])
    }

    /// A solid square of colour 1, run-length encoded a line at a time.
    static func solid(width: Int, height: Int) -> [UInt8] {
        let line: [UInt8] = width < 64 ? [0, 0x80 | UInt8(width), 1] : [0, 0xC0 | UInt8(width >> 8), UInt8(width & 0xFF), 1]
        return Array(repeating: line + [0, 0], count: height).flatMap { $0 }
    }
}

struct PGSParsingTests {
    private func oneSquare(at seconds: Double = 2, x: Int = 100, y: Int = 900, crop: (Int, Int, Int, Int)? = nil) -> SupFile {
        var file = SupFile()
        file.composition(at: seconds, objects: [(1, x, y, crop)])
        file.palette(at: seconds)
        file.object(at: seconds, id: 1, width: 4, height: 2, rle: SupFile.solid(width: 4, height: 2))
        file.end(at: seconds)
        return file
    }

    @Test func readsAPictureAndWhereItGoes() throws {
        let cues = PGS.cues(in: oneSquare().bytes)
        let cue = try #require(cues.first)
        #expect(cues.count == 1)
        #expect(cue.start == 2)
        // Nothing clears the last one, so it shows for a while rather than for the rest of the video.
        #expect(cue.end == 7)
        #expect(cue.canvas == CGSize(width: 1920, height: 1080))

        let picture = try #require(cue.image())
        #expect(picture.rect == CGRect(x: 100, y: 900, width: 4, height: 2))
        #expect(picture.image.width == 4)
        #expect(picture.image.height == 2)
    }

    @Test func anEmptyDisplaySetClearsTheOneBefore() {
        var file = oneSquare(at: 2)
        file.composition(at: 4.5, objects: [])
        file.end(at: 4.5)
        let cues = PGS.cues(in: file.bytes)
        #expect(cues.count == 1)
        #expect(cues.first?.end == 4.5)
    }

    @Test func keepsACropWithinThePicture() throws {
        // The crop asks for far more than the 4 × 2 picture has.
        let cue = try #require(PGS.cues(in: oneSquare(crop: (1, 1, 500, 500)).bytes).first)
        let picture = try #require(cue.image())
        #expect(picture.rect.size == CGSize(width: 3, height: 1))
    }

    @Test func refusesAPictureTooBigToDraw() throws {
        var file = SupFile()
        file.composition(at: 1, canvas: (65_535, 65_535), objects: [(1, 0, 0, nil)])
        file.palette(at: 1)
        file.object(at: 1, id: 1, width: 65_535, height: 65_535, rle: SupFile.solid(width: 4, height: 1))
        file.end(at: 1)
        let cue = try #require(PGS.cues(in: file.bytes).first)
        #expect(cue.image() == nil)
    }

    @Test func survivesATruncatedFile() {
        let bytes = oneSquare().bytes
        for length in 0..<bytes.count {
            for cue in PGS.cues(in: Array(bytes.prefix(length))) { _ = cue.image() }
        }
    }

    @Test func survivesGarbage() {
        var generator = SeededGenerator(seed: 7)
        let valid = oneSquare().bytes
        for _ in 0..<300 {
            // A real file with some bytes changed at random, which keeps enough of its shape to get past the first checks.
            var bytes = valid
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            for cue in PGS.cues(in: bytes) { _ = cue.image() }
        }
    }

    @Test func isEmptyForSomethingElse() {
        #expect(PGS.cues(in: Array("WEBVTT\n\n00:00.000 --> 00:01.000\nHi".utf8)).isEmpty)
    }
}

@MainActor
struct PictureCueRendererTests {
    @Test func drawsThePictureOffTheMainThreadAndThenHasIt() async throws {
        var file = SupFile()
        file.composition(at: 1, objects: [(1, 0, 0, nil)])
        file.palette(at: 1)
        file.object(at: 1, id: 1, width: 4, height: 2, rle: SupFile.solid(width: 4, height: 2))
        file.end(at: 1)

        let renderer = PictureCueRenderer()
        renderer.replace(with: PGS.cues(in: file.bytes))
        #expect(renderer.picture(at: 0.5) == nil)

        var picture = renderer.picture(at: 1.5)
        for _ in 0..<200 where picture == nil {
            try await Task.sleep(for: .milliseconds(10))
            picture = renderer.picture(at: 1.5)
        }
        #expect(picture?.rect.size == CGSize(width: 4, height: 2))

        renderer.replace(with: [])
        #expect(renderer.picture(at: 1.5) == nil)
    }
}
