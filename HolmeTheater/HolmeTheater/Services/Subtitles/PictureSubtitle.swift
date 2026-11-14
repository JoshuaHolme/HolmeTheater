// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// One picture of an image-based subtitle track, and when it shows. Its pixels stay compressed until it's on screen
/// (see ``image()``): an episode has hundreds, which decoded would take hundreds of megabytes.
nonisolated struct PictureSubtitleCue: Sendable {
    /// When it appears and disappears, in seconds from the start of the video.
    let start: TimeInterval
    var end: TimeInterval

    /// The picture the positions are measured on, usually the video's own size (1920 × 1080 on a Blu-ray).
    let canvas: CGSize

    let placements: [PGS.Placement]

    /// Colours by number, as premultiplied RGBA packed big-endian. All 256, the ones the track doesn't set transparent.
    let palette: [UInt32]

    /// The most pixels a picture may have: a 4096 × 4096 square, 64 MB decoded. Every size and position in a track is the
    /// file's to say, up to 65,535, so without a limit a damaged or hostile one could ask for gigabytes.
    private static let maxPixels = 4096 * 4096

    /// Draws the picture: everything in it, cut down to the part of the canvas it covers.
    func image() -> PictureSubtitle? {
        let rects = placements.map(\.rect)
        guard let union = rects.first.map({ rects.dropFirst().reduce($0) { $0.union($1) } }) else { return nil }
        // Anything off the canvas wouldn't be seen anyway.
        let bounds = union.intersection(CGRect(origin: .zero, size: canvas))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width * height <= Self.maxPixels else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for placement in placements {
            placement.draw(into: &pixels, size: (width, height), origin: (Int(bounds.minX), Int(bounds.minY)), palette: palette)
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return PictureSubtitle(image: image, rect: bounds, canvas: canvas)
    }
}

/// A subtitle picture ready to draw, and where it goes.
nonisolated struct PictureSubtitle {
    let image: CGImage
    /// Where it goes on ``canvas``, in its pixels.
    let rect: CGRect
    let canvas: CGSize

    /// Where it goes on the screen, given where the video is on it (`video`) and the screen's own bounds.
    func rect(onVideo video: CGRect, within screen: CGRect) -> CGRect {
        Self.place(rect, canvas: canvas, onVideo: video, within: screen)
    }

    /// Where a picture at `rect` on `canvas` goes on the screen, given where the video is on it and the screen's bounds.
    static func place(_ rect: CGRect, canvas: CGSize, onVideo video: CGRect, within screen: CGRect) -> CGRect {
        let canvasFrame = canvasFrame(canvas, onVideo: video)
        let scaleX = canvasFrame.width / canvas.width, scaleY = canvasFrame.height / canvas.height
        var placed = CGRect(x: canvasFrame.minX + rect.minX * scaleX, y: canvasFrame.minY + rect.minY * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY)
        // On a screen narrower than the canvas, a cropped video's lines along the bottom of the canvas (its black bars,
        // once) could be off the bottom: they're moved up just enough to show. A picture inside the video never moves.
        if placed.width <= screen.width { placed.origin.x = min(max(placed.minX, screen.minX), screen.maxX - placed.width) }
        if placed.height <= screen.height { placed.origin.y = min(max(placed.minY, screen.minY), screen.maxY - placed.height) }
        return placed
    }

    /// Where the canvas goes, given where the video is.
    ///
    /// Usually just the video's frame: the canvas is the video's size (or the shape it's shown at, for one stored
    /// squeezed, as DVD-sized pictures often are). But a Blu-ray's video is a 16:9 frame with the film in it, black bars
    /// and all, which a rip may crop down to the film; its subtitles still measure positions on the whole frame. So a
    /// 16:9 high-definition canvas on a video of another shape is drawn at the video's scale and centered on it, as the
    /// frame was, rather than stretched to the video's shape.
    static func canvasFrame(_ canvas: CGSize, onVideo video: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, video.width > 0, video.height > 0 else { return video }
        let canvasAspect = canvas.width / canvas.height, videoAspect = video.width / video.height
        let isHDFrame = abs(canvasAspect - 16.0 / 9) < 0.01 && canvas.height >= 720
        guard isHDFrame, abs(canvasAspect - videoAspect) / videoAspect > 0.02 else { return video }
        // Cropped top and bottom (wider than the frame), the widths match; cropped at the sides, the heights do.
        let scale = max(video.width / canvas.width, video.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: video.midX - size.width / 2, y: video.midY - size.height / 2, width: size.width, height: size.height)
    }
}

extension [PictureSubtitleCue] {
    /// The index of the cue showing at `time`, if any. The cues are in order and never overlap.
    func index(at time: TimeInterval) -> Int? {
        var low = 0, high = count
        // The first cue starting after `time`; the one before it is the only one that can be showing.
        while low < high {
            let middle = (low + high) / 2
            if self[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, time < self[low - 1].end else { return nil }
        return low - 1
    }
}
