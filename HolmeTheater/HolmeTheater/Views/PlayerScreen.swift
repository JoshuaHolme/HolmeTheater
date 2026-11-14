// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

// MARK: - Screen

/// The screen the player fills: its full size, its safe area, and what reaches into its corners. Works out where
/// the picture and the rows of controls go so they keep clear of the camera and the status bar.
///
/// The safe area alone doesn't do: on iPhone Duo it's a strip down one whole side, or a band across the top,
/// beside a camera or status bar that only fills a corner. So, as in the Apple TV app, only what would sit in
/// that corner moves aside. On other iPhones nothing is in a corner, and the safe area (around the Dynamic
/// Island) applies as usual.
struct PlayerScreen: Equatable {
    /// The whole screen, measured with the safe area ignored.
    private(set) var size: CGSize = .zero
    var safeArea = EdgeInsets()

    /// The most each corner has covered: its rounding, or a camera, or the status bar when it sits in a corner
    /// (as on both of iPhone Duo's displays). The controls keep out of this.
    private(set) var corners = RectangleCornerInsets()

    /// The least each corner has covered. The status bar only claims its corner while it shows, so whatever is
    /// still there with it hidden is a camera cutout, as on iPhone Duo's outer display (the inner one has none).
    /// The picture keeps out of this.
    private(set) var cutouts = RectangleCornerInsets()

    /// The screen's size and corners, measured together.
    nonisolated struct Shape: Equatable, Sendable {
        var size: CGSize
        var corners: RectangleCornerInsets
    }

    /// Margin between the controls and the screen's edges.
    static let margin: CGFloat = 20

    /// How much of a camera's corner the picture keeps clear of. The reported corner is bigger than the camera, which
    /// sits in the middle of it, not in the screen's corner (measured on iPhone Duo's outer display).
    static let cameraShare: CGFloat = 0.62

    /// Wider than any screen's rounding, so a corner reaching this far in holds a camera or the status bar.
    private static let obstructionWidth: CGFloat = 70

    /// Takes a new measurement of the screen.
    ///
    /// The status bar comes and goes with the controls, so one measurement can't tell it from a camera. Over
    /// several, ``corners`` keeps the most each corner has covered and ``cutouts`` the least. Folding, or
    /// rotating so something turns up in a corner that was clear (turning the phone over leaves the size the
    /// same), starts afresh.
    ///
    /// - Parameter statusBarShown: Whether the status bar is showing. Something turning up in a corner then is
    ///   most likely the status bar itself (as on iPhone Duo's inner display, which has no camera), not a camera,
    ///   so it doesn't start afresh: it would move the picture aside for the status bar, until the status bar
    ///   next hid. (Turning the phone over with it showing is read the same way, and sorts itself out when it hides.)
    mutating func update(_ shape: Shape, statusBarShown: Bool = false) {
        let isNewCorner = !statusBarShown
            && zip(Self.obstructed(shape.corners), Self.obstructed(corners)).contains { $0 && !$1 }
        guard shape.size == size, !isNewCorner else {
            size = shape.size
            corners = shape.corners
            cutouts = shape.corners
            return
        }
        corners = Self.combine(corners, shape.corners, by: max)
        cutouts = Self.combine(cutouts, shape.corners, by: min)
    }

    private static func obstructed(_ corners: RectangleCornerInsets) -> [Bool] {
        [corners.topLeading, corners.topTrailing, corners.bottomLeading, corners.bottomTrailing]
            .map { $0.width >= obstructionWidth }
    }

    private static func combine(
        _ a: RectangleCornerInsets,
        _ b: RectangleCornerInsets,
        by pick: (CGFloat, CGFloat) -> CGFloat
    ) -> RectangleCornerInsets {
        func each(_ a: CGSize, _ b: CGSize) -> CGSize { CGSize(width: pick(a.width, b.width), height: pick(a.height, b.height)) }
        return RectangleCornerInsets(
            topLeading: each(a.topLeading, b.topLeading),
            topTrailing: each(a.topTrailing, b.topTrailing),
            bottomLeading: each(a.bottomLeading, b.bottomLeading),
            bottomTrailing: each(a.bottomTrailing, b.bottomTrailing)
        )
    }

    /// Something filling a corner, and how much of the screen it covers.
    private struct Obstruction {
        let isTop: Bool
        let isLeading: Bool
        let size: CGSize

        /// A camera is as tall as its corner is wide, or as wide as it's tall: the status bar beside it is what
        /// stretches the corner the other way.
        ///
        /// The corner also holds room for the Dynamic Island to grow into, which the picture can pass under, so
        /// this is only the part of it the camera needs: ``PlayerScreen/cameraShare`` of the corner, centred in it.
        var camera: CGSize {
            let side = min(size.width, size.height) * PlayerScreen.cameraShare
            return CGSize(width: side, height: side)
        }
    }

    private static func obstructions(in corners: RectangleCornerInsets) -> [Obstruction] {
        [
            Obstruction(isTop: true, isLeading: true, size: corners.topLeading),
            Obstruction(isTop: true, isLeading: false, size: corners.topTrailing),
            Obstruction(isTop: false, isLeading: true, size: corners.bottomLeading),
            Obstruction(isTop: false, isLeading: false, size: corners.bottomTrailing)
        ]
        .filter { $0.size.width >= obstructionWidth }
    }

    /// The safe area's inset on one side, unless it's only there for something in that side's corner, which
    /// the rows and the picture go around by themselves.
    private func sideInset(leading: Bool) -> CGFloat {
        Self.obstructions(in: corners).contains { $0.isLeading == leading } ? 0 : (leading ? safeArea.leading : safeArea.trailing)
    }

    /// Side margins for a row of controls along the top or bottom of the screen: the usual margin, or more to
    /// step around a camera or the status bar in one of the row's corners.
    func rowInsets(top: Bool) -> (leading: CGFloat, trailing: CGFloat) {
        var leading = max(Self.margin, sideInset(leading: true))
        var trailing = max(Self.margin, sideInset(leading: false))
        for obstruction in Self.obstructions(in: corners) where obstruction.isTop == top {
            if obstruction.isLeading {
                leading = max(leading, obstruction.size.width)
            } else {
                trailing = max(trailing, obstruction.size.width)
            }
        }
        return (leading, trailing)
    }

    /// Space above the top row. With the status bar or a camera in a top corner, the row sits right at the top
    /// beside it, as in the Apple TV app; otherwise it goes below the status bar.
    func topPadding(isCompact: Bool) -> CGFloat {
        if Self.obstructions(in: corners).contains(where: \.isTop) { return 16 }
        return isCompact ? safeArea.top + 12 : max(safeArea.top, 16)
    }

    var bottomPadding: CGFloat { max(safeArea.bottom, 12) }

    /// Where a picture of `aspectRatio` goes when nothing reaches into the screen: as big as it fits, centred, with
    /// no regard for the safe area. For the half of a folded iPhone Duo that holds the picture, which has no camera
    /// or status bar in it.
    func unobstructedPictureFrame(aspectRatio: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, size.height * aspectRatio)
        let height = width / aspectRatio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Where a picture of `aspectRatio` (width over height) goes.
    ///
    /// Without a camera cutout in a corner, it's as big as it fits, centred, and inside the safe area's sides, clear
    /// of a Dynamic Island. With one, as on iPhone Duo's outer display, the whole picture shows: it's the biggest
    /// that keeps its corners out of the camera and out of the screen's rounded corners, as near the centre as
    /// that allows.
    ///
    /// Depends only on the screen's size and its cutouts, not the status bar or the controls, so the picture
    /// holds still while they come and go.
    func pictureFrame(aspectRatio: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else { return CGRect(origin: .zero, size: size) }
        let (width, height) = (size.width, size.height)
        let sides = min(sideInset(leading: true), sideInset(leading: false))
        let cameras = Self.obstructions(in: cutouts)

        guard !cameras.isEmpty else {
            let pictureWidth = min(width - 2 * sides, height * aspectRatio)
            let pictureHeight = pictureWidth / aspectRatio
            return CGRect(x: (width - pictureWidth) / 2, y: (height - pictureHeight) / 2, width: pictureWidth, height: pictureHeight)
        }

        // Each camera's rectangle in its corner, and the rounding of every corner without one.
        let cameraRects = cameras.map { camera in
            // The camera sits in the middle of its corner region, which reaches the screen's edges.
            let corner = CGRect(
                x: camera.isLeading ? 0 : width - camera.size.width,
                y: camera.isTop ? 0 : height - camera.size.height,
                width: camera.size.width,
                height: camera.size.height
            )
            return CGRect(
                x: corner.midX - camera.camera.width / 2,
                y: corner.midY - camera.camera.height / 2,
                width: camera.camera.width,
                height: camera.camera.height
            )
        }
        func isCameraCorner(top: Bool, leading: Bool) -> Bool {
            cameras.contains { $0.isTop == top && $0.isLeading == leading }
        }
        func rounding(_ corner: CGSize, top: Bool, leading: Bool) -> CGSize? {
            isCameraCorner(top: top, leading: leading) ? nil : corner
        }
        let rounded = (
            topLeading: rounding(cutouts.topLeading, top: true, leading: true),
            topTrailing: rounding(cutouts.topTrailing, top: true, leading: false),
            bottomLeading: rounding(cutouts.bottomLeading, top: false, leading: true),
            bottomTrailing: rounding(cutouts.bottomTrailing, top: false, leading: false)
        )

        /// How far in from the screen's edge a point `distance` along the other edge must be to stay inside a
        /// corner rounded by `corner`. Zero once past the rounding.
        func inset(_ corner: CGSize?, along distance: CGFloat) -> CGFloat {
            guard let corner, corner.width > 0, corner.height > 0, distance < corner.height else { return 0 }
            let rise = (corner.height - distance) / corner.height
            return corner.width - corner.width * (1 - rise * rise).squareRoot()
        }

        /// The best place for a picture `pictureWidth` wide, or nil if there's none.
        func place(_ pictureWidth: CGFloat) -> CGRect? {
            let pictureHeight = pictureWidth / aspectRatio
            guard pictureWidth <= width - 2 * sides + 0.001, pictureHeight <= height + 0.001 else { return nil }
            let centre = CGPoint(x: (width - pictureWidth) / 2, y: (height - pictureHeight) / 2)
            var best: CGRect?
            var bestDistance = CGFloat.infinity

            for y in stride(from: 0, through: height - pictureHeight, by: 0.5) {
                // How far in each side must be so the picture's corners stay inside the rounded corners.
                var low = max(sides, inset(rounded.topLeading, along: y), inset(rounded.bottomLeading, along: height - y - pictureHeight))
                var high = min(
                    width - sides - pictureWidth,
                    width - pictureWidth - inset(rounded.topTrailing, along: y),
                    width - pictureWidth - inset(rounded.bottomTrailing, along: height - y - pictureHeight)
                )
                guard low <= high else { continue }

                // Beside each camera the picture overlaps in height: wholly to one side of it.
                var spans = [(low, high)]
                for camera in cameraRects where y < camera.maxY && y + pictureHeight > camera.minY {
                    spans = spans.flatMap { span in
                        [(span.0, min(span.1, camera.minX - pictureWidth)), (max(span.0, camera.maxX), span.1)]
                    }
                    .filter { $0.0 <= $0.1 }
                }
                for span in spans {
                    low = span.0
                    high = span.1
                    let x = min(max(centre.x, low), high)
                    let distance = hypot(x - centre.x, y - centre.y)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = CGRect(x: x, y: y, width: pictureWidth, height: pictureHeight)
                    }
                }
            }
            return best
        }

        // The biggest that has a place, found by halving: a smaller picture always has room if a bigger one does.
        let largest = min(width - 2 * sides, height * aspectRatio)
        if let frame = place(largest) { return frame }
        var (fits, tooBig) = (CGFloat(0), largest)
        for _ in 0..<14 {
            let middle = (fits + tooBig) / 2
            if place(middle) != nil { fits = middle } else { tooBig = middle }
        }
        return place(fits) ?? CGRect(origin: .zero, size: size)
    }
}
#endif
