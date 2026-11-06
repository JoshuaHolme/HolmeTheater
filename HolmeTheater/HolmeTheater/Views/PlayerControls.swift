// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import AVKit
import SwiftUI

// MARK: - Model

/// A chapter of the video being played.
struct PlayerChapter: Identifiable, Hashable {
    /// Its place in the list. Chapters can share a start time, so that can't identify them.
    let id: Int
    let title: String
    let start: TimeInterval
    /// A still from the chapter, when the server has one.
    var imageURL: URL?
}

/// What the on-screen controls need from the player: position, state, chapters and Picture in Picture.
@MainActor @Observable
final class PlayerControlsModel {
    let player: AVPlayer

    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// The speed chosen for playback. 1 is normal.
    private(set) var playbackRate: Float = 1
    /// How far into the video what's been loaded reaches, counting on from the current position.
    private(set) var bufferedTime: TimeInterval = 0
    /// The picture's size in pixels, or zero until the stream reports it.
    private(set) var videoSize: CGSize = .zero
    var videoHeight: CGFloat { videoSize.height }
    private(set) var chapters: [PlayerChapter] = []

    /// Moves the position for a preview, which has no video to play. Not wrapped in `#if DEBUG`
    /// because `#Preview` bodies are compiled in Release builds too.
    func setPreviewPosition(_ seconds: TimeInterval) { currentTime = seconds }

    /// Whether the panel for adjusting the subtitles' timing is open over the picture. Everything else is cleared
    /// away while it is, so the player's views both read it.
    var showsTiming = false

    /// While a panel is open: the screen height where the picture starts to blur, down to the bottom edge.
    var blurTop: CGFloat?

    /// Whether the video is zoomed to fill the screen (cropping its edges) rather than fitting inside it.
    private(set) var fillsScreen = false

    /// Bumped when the picture is tapped while the display is folded, so the controls, which sit in the other half,
    /// show or hide as if they had been tapped themselves.
    private(set) var pictureTaps = 0

    /// Whether the status bar is showing, which it does with the controls. The picture's screen reads this when
    /// it measures its corners, to tell the status bar from a camera.
    @ObservationIgnored var statusBarShown = false

    func tapPicture() { pictureTaps += 1 }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var hasServerChapters = false
    @ObservationIgnored private var pip: AVPictureInPictureController?

    /// While scrubbing: whether to resume playing afterwards.
    @ObservationIgnored private var resumesAfterScrub = false
    /// While scrubbing: the latest position asked for, and whether a seek is under way.
    @ObservationIgnored private var pendingScrub: TimeInterval?
    @ObservationIgnored private var isScrubSeeking = false

    /// - Parameters:
    ///   - runtime: The server's runtime, used until the stream reports its own duration.
    init(player: AVPlayer, runtime: TimeInterval?) {
        self.player = player
        self.duration = runtime ?? 0
    }

    /// Starts watching the player. Pair with ``stop()``.
    func start() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The periodic observer goes quiet once time stops moving, so on its own it would miss a stall starting
        // (or ending) and leave the controls showing "playing" with no spinner.
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await loadChapters() }
    }

    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    private func tick() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, pendingScrub == nil, !isScrubSeeking { currentTime = max(0, seconds) }
        if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 { duration = length }
        isPlaying = player.timeControlStatus != .paused || resumesAfterScrub
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        videoSize = player.currentItem?.presentationSize ?? .zero
        bufferedTime = loadedEnd(around: seconds)
    }

    /// The end of the loaded stretch holding `seconds`, or `seconds` itself if nothing around it is loaded.
    private func loadedEnd(around seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, let ranges = player.currentItem?.loadedTimeRanges else { return 0 }
        let range = ranges.map(\.timeRangeValue).first { $0.start.seconds <= seconds + 0.5 && seconds <= $0.end.seconds }
        return max(seconds, range?.end.seconds ?? seconds)
    }

    // MARK: Transport

    func togglePlayback() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
    }

    func seek(to seconds: TimeInterval) {
        let target = clamped(seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Plays at `rate` from now on. `defaultRate` makes it stick after a pause, a seek or a new stream.
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    func skip(by seconds: TimeInterval) { seek(to: currentTime + seconds) }

    private func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(0, seconds), duration > 0 ? duration : seconds)
    }

    // MARK: Scrubbing

    /// Pauses while the progress bar is dragged, as the system player does.
    func beginScrubbing() {
        resumesAfterScrub = player.timeControlStatus != .paused
        player.pause()
    }

    /// Shows the frame at `seconds` while dragging. Seeks one at a time, always to the latest position, so a
    /// fast drag doesn't queue up a backlog of seeks.
    func scrub(to seconds: TimeInterval) {
        pendingScrub = clamped(seconds)
        guard !isScrubSeeking else { return }
        chaseScrub()
    }

    private func chaseScrub() {
        guard let target = pendingScrub else { return }
        pendingScrub = nil
        isScrubSeeking = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                self?.isScrubSeeking = false
                self?.chaseScrub()
            }
        }
    }

    /// Seeks exactly to where the drag ended and resumes playing if it was before.
    func endScrubbing(at seconds: TimeInterval) {
        pendingScrub = nil
        seek(to: seconds)
        if resumesAfterScrub { player.play() }
        resumesAfterScrub = false
    }

    // MARK: Chapters

    /// Reads the chapters from the current stream. Call again when the stream changes.
    func loadChapters() async {
        // The server's list has names and stills, so the stream's own is only a fallback.
        guard !hasServerChapters else { return }
        guard let asset = player.currentItem?.asset,
              let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        else {
            if !hasServerChapters { chapters = [] }
            return
        }
        var found: [PlayerChapter] = []
        for group in groups {
            let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = (try? await titleItem?.load(.stringValue)) ?? nil
            found.append(PlayerChapter(
                id: found.count,
                title: title ?? String(localized: "Chapter \(found.count + 1)"),
                start: group.timeRange.start.seconds
            ))
        }
        // The server's list may have arrived while the stream's was loading, and it's the better of the two.
        guard !hasServerChapters else { return }
        chapters = found
    }

    /// Uses the server's chapters, which come with stills, in place of the stream's own.
    func setServerChapters(_ found: [PlayerChapter]) {
        guard !found.isEmpty else { return }
        hasServerChapters = true
        chapters = found
    }

    func setFillsScreen(_ fills: Bool) {
        guard fills != fillsScreen else { return }
        fillsScreen = fills
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Picture in Picture

    /// Binds Picture in Picture to the layer showing the video. A controller belongs to one layer, so it's made
    /// again if SwiftUI replaces the layer, as it can when the window changes shape.
    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pip?.playerLayer !== layer else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
    }

    /// Whether the device does Picture in Picture, which is known from the start. Not whether the controller exists yet:
    /// that's made once the video's layer is on screen, and isn't observed, so the button waited for something else to
    /// redraw the controls and then appeared in the middle of playback.
    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}

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

// MARK: - Surfaces

/// The video itself, with no controls.
struct PlayerSurface: UIViewRepresentable {
    let model: PlayerControlsModel
    /// Whether Picture in Picture follows this layer. Only the main picture's, not the blurred copy under a panel.
    let bindsPictureInPicture: Bool

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = .resizeAspect
        if bindsPictureInPicture { model.attach(view.playerLayer) }
        return view
    }

    /// Zooming to fill scales this view (see `CustomPlayer`), so the layer always just fits the video to its bounds.
    func updateUIView(_ view: SurfaceView, context: Context) {}

    final class SurfaceView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast
    }
}

/// The system AirPlay button.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// The subtitles, drawn over the picture from the player's clock. The player's own HLS subtitles drift out of step
/// with the speech; these follow the position, as in the web client.
///
/// Laid out in the picture's own frame, on the whole screen, so they sit where the video does and don't move
/// when the status bar and controls come and go.
struct SubtitleOverlay: View {
    let session: PlaybackSession
    let model: PlayerControlsModel
    /// Where the picture is on the screen.
    let frame: CGRect

    /// The text size setting, as a factor on the usual size: the subtitles follow it, up to a point.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if let text = session.subtitleText(at: model.currentTime) {
                    Text(text)
                        .font(.system(size: max(14, frame.height * 0.055) * min(textScale, 1.6), weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .shadow(color: .black, radius: 4)
                        .padding(.horizontal, frame.width * 0.08)
                        .padding(.bottom, frame.height * 0.06)
                        .frame(width: frame.width, height: frame.height, alignment: .bottom)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Dimmed white for secondary text over the picture, and fully white with Increase Contrast on.
private struct SecondaryPlayerText: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.8))
    }
}

private extension View {
    func secondaryPlayerText() -> some View { modifier(SecondaryPlayerText()) }
}

// MARK: - Controls

/// The player's controls: close, Picture in Picture and AirPlay at the top; play, pause and skip in the middle;
/// title, quality and track menus, the progress bar, and Info, Cast and Chapters along the bottom. Volume is
/// left to the device's buttons and the system's own volume display.
/// Tap the video to show or hide them; they hide themselves a few seconds after playback starts.
struct PlayerControlsView: View {
    let item: MediaItem
    let session: PlaybackSession
    let model: PlayerControlsModel
    /// The screen the controls lay themselves out on, rather than sitting inside its safe area.
    let screen: PlayerScreen
    /// Whether the display is partially folded, with the picture in the other half. The controls then fill their
    /// half and stay on screen, since there's no picture under them to see.
    var isFolded = false
    let close: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverIsOn
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlIsOn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// How tall the panel under the pills is, growing with the text size so cards and rows aren't clipped.
    @ScaledMetric(relativeTo: .body) private var regularPanelHeight: CGFloat = 130
    @ScaledMetric(relativeTo: .body) private var compactPanelHeight: CGFloat = 220

    /// Side of the round and capsule controls, sized to match the Apple TV app.
    static let buttonSize: CGFloat = 48

    enum Panel: String, Identifiable, CaseIterable {
        case info, cast, chapters
        var id: String { rawValue }
    }

    /// Whether the controls are showing. Starts from the session's, not always `true`: SwiftUI can rebuild this view
    /// when the window changes shape (rotating, folding), and the controls mustn't pop open each time.
    @State private var showsControls: Bool

    /// Plays the episode that follows this one.
    let playNext: (MediaItem) -> Void

    init(
        item: MediaItem,
        session: PlaybackSession,
        model: PlayerControlsModel,
        screen: PlayerScreen,
        isFolded: Bool = false,
        initialPanel: Panel? = nil,
        playNext: @escaping (MediaItem) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.item = item
        self.playNext = playNext
        self.session = session
        self.model = model
        self.screen = screen
        self.isFolded = isFolded
        self.close = close
        _showsControls = State(initialValue: session.controlsAreShowing)
        _panel = State(initialValue: initialPanel)
    }
    /// Bumped on every interaction, restarting the hide timer.
    @State private var interactions = 0
    /// The panel open below the progress bar, if any.
    @State private var panel: Panel?
    @State private var people: [MediaPerson] = []
    @State private var scrubFraction: Double?
    /// Whether the full description is open in a sheet over the player.
    @State private var showsFullInfo = false
    /// The cast member whose page is open in a sheet over the player.
    @State private var openedPerson: MediaPerson?
    /// Portrait: the layout tightens to fit, as in the Apple TV app.
    @State private var isCompact = false

    /// How tall the bottom block (title, progress bar and pills) is, which the buttons floating over the picture
    /// stay above. It's taller at larger text sizes.
    @State private var bottomBlockHeight: CGFloat = 0

    /// How far above the bottom padding the skip and next-episode buttons sit: clear of the controls if they're
    /// showing, otherwise just above the edge.
    private var floatingButtonsLift: CGFloat {
        controlsAreShown ? max(150, bottomBlockHeight + 12) : 24
    }

    /// Whether the skip button goes under the top bar instead of above the bottom controls. At accessibility sizes
    /// the bottom controls are tall enough that, above them, it would sit on the playback buttons in the middle.
    private var skipSitsAtTop: Bool { controlsAreShown && dynamicTypeSize.isAccessibilitySize }

    /// Always with VoiceOver or Switch Control on: controls that hide themselves after a few seconds are gone before
    /// anyone using them has found their way around.
    private var controlsAreShown: Bool { showsControls || voiceOverIsOn || switchControlIsOn }

    private var statusBarIsHidden: Bool { isFolded || !controlsAreShown || model.showsTiming }

    private var showsExpandedPanelBar: Bool { !dynamicTypeSize.isAccessibilitySize }

    private var shouldStayVisible: Bool {
        !model.isPlaying || panel != nil || scrubFraction != nil || session.isSwitching || showsFullInfo || openedPerson != nil || model.showsTiming
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if model.isBuffering || session.isSwitching {
                ProgressView().controlSize(.large).tint(.white)
            }

            // Adjusting the subtitles' timing clears everything else away, leaving the picture and its subtitles.
            controls
                .opacity(controlsAreShown && !model.showsTiming ? 1 : 0)
                .allowsHitTesting(controlsAreShown && !model.showsTiming)
                // Invisible isn't unreachable: VoiceOver would still read out controls that are faded away.
                .accessibilityHidden(!controlsAreShown || model.showsTiming)

            // Offered while the picture is in a stretch the server has marked, whether or not the controls are
            // showing; above the bottom row when they are.
            // Folded, it goes over the picture in the other half instead (see `CustomPlayer`).
            if !isFolded {
                SkipSegmentButton(session: session, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipSitsAtTop ? .topTrailing : .bottomTrailing)
                    .padding(.trailing, screen.rowInsets(top: skipSitsAtTop).trailing)
                    .padding(.top, skipSitsAtTop ? screen.topPadding(isCompact: isCompact) + Self.buttonSize + 12 : 0)
                    .padding(.bottom, skipSitsAtTop ? 0 : screen.bottomPadding + floatingButtonsLift)
                    .opacity(model.showsTiming || panel != nil ? 0 : 1)
                    .allowsHitTesting(!model.showsTiming && panel == nil)
                    .accessibilityHidden(model.showsTiming || panel != nil)
                    .animation(.smooth(duration: 0.3), value: controlsAreShown)
            }

            // Near the end of an episode: the next one, with a countdown to starting it.
            // Folded, it goes over the picture in the other half instead (see `CustomPlayer`).
            if !isFolded {
                NextEpisodeOverlay(session: session, model: model, play: playNext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, screen.rowInsets(top: false).trailing)
                    .padding(.bottom, screen.bottomPadding + floatingButtonsLift)
                    .opacity(model.showsTiming || panel != nil ? 0 : 1)
                    .allowsHitTesting(!model.showsTiming && panel == nil)
                    .accessibilityHidden(model.showsTiming || panel != nil)
                    .animation(.smooth(duration: 0.3), value: controlsAreShown)
            }

            // Folded, the picture is in the other half, so the panel goes in this one, on its own.
            if model.showsTiming && isFolded {
                SubtitleTimingPanel(session: session, touch: {}) { model.showsTiming = false }
                    .frame(maxWidth: 440)
                    .padding(.horizontal, max(screen.rowInsets(top: false).leading, screen.rowInsets(top: false).trailing))
                    .transition(.opacity)
            }
        }
        // The whole screen, so taps anywhere toggle the controls and the spinner is centred; the rows keep
        // clear of the camera and home indicator by themselves. Folded, it stays in its half, clear of the fold.
        .ignoresSafeArea(edges: isFolded ? [] : .all)
        .foregroundStyle(.white)
        // Always dark, whatever the device is set to: the materials and glass then tint dark over the picture, as
        // in the Apple TV app, instead of turning pale in Light Mode.
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: Bool.self) { $0.size.width < $0.size.height } action: { isCompact = $0 }
        // As in the Apple TV app, the clock and battery show with the controls. Folded, the other half holds the
        // picture, and the status bar would sit over it.
        .statusBarHidden(statusBarIsHidden)
        .onChange(of: statusBarIsHidden, initial: true) { model.statusBarShown = !statusBarIsHidden }
        // A tap on the picture, in the other half when folded, does the same as one here.
        .onChange(of: model.pictureTaps) { toggleControls() }
        // Out of the way of the timing panel, which is over the picture beneath this view (unless folded).
        .allowsHitTesting(!model.showsTiming || isFolded)
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: showsControls)
        .onChange(of: showsControls) { session.controlsAreShowing = showsControls }
        .animation(.smooth(duration: 0.3), value: panel)
        .animation(.smooth(duration: 0.25), value: model.showsTiming)
        .onChange(of: model.showsTiming) { touch() }
        .task(id: interactions) {
            guard showsControls else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, !shouldStayVisible { showsControls = false }
        }
        .onChange(of: model.isPlaying) { _, isPlaying in
            if isPlaying { interactions += 1 } else { showsControls = true }
        }
        .onChange(of: session.info) { Task { await model.loadChapters() } }
        .onChange(of: availablePanels) { if let panel, !availablePanels.contains(panel) { self.panel = nil } }
        .task { await loadPeople() }
        .sheet(item: $openedPerson) { person in
            NavigationStack {
                PersonDetailView(person: person)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { openedPerson = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showsFullInfo) {
            FullInfoSheet(item: item)
                .preferredColorScheme(.dark)
        }
        .alert(
            "Couldn't Change Playback",
            isPresented: Binding(get: { session.switchError != nil }, set: { if !$0 { session.switchError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(session.switchError ?? "")
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.leading, screen.rowInsets(top: true).leading)
                    .padding(.trailing, screen.rowInsets(top: true).trailing)
                Spacer(minLength: 16)
                bottomBlock
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBlockHeight = $0 }
                    .padding(.leading, screen.rowInsets(top: false).leading)
                    .padding(.trailing, screen.rowInsets(top: false).trailing)
            }
            .padding(.top, screen.topPadding(isCompact: isCompact))
            .padding(.bottom, screen.bottomPadding)
            // Its own layer, so it's centred on the screen whatever the bars above and below take up.
            // Portrait has room to keep the transport beside the info panel.
            if panel == nil || (panel == .info && isCompact) {
                transport
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: isFolded ? [] : .all)
        .background {
            // As in the system player, the picture dims under the controls so they read against anything.
            ZStack {
                Color.black.opacity(0.25)
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(panel == nil ? 0.6 : 0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton("xmark", label: "Close", action: close)

            HStack(spacing: 4) {
                if model.supportsPictureInPicture {
                    Button { model.togglePictureInPicture(); touch() } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Picture in Picture")
                }
                AirPlayButton()
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
            }
            .padding(.horizontal, 4)
            .glassEffect(.clear.interactive(), in: .capsule)

            Spacer(minLength: 0)
        }
    }

    // MARK: Middle

    /// Symbols on glass circles, as in the Apple TV app.
    private var transport: some View {
        HStack(spacing: isCompact ? 36 : 56) {
            transportButton("gobackward.10", label: "Back 10 seconds", size: 32) { model.skip(by: -10) }
            transportButton(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play", size: 52) {
                model.togglePlayback()
            }
            transportButton("goforward.10", label: "Forward 10 seconds", size: 32) { model.skip(by: 10) }
        }
    }

    private func transportButton(_ systemImage: String, label: LocalizedStringKey, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action(); touch()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2, height: size * 2)
                .glassEffect(.clear.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Bottom

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The info panel takes the place of the title and progress bar, as in the Apple TV app.
            if panel != .info {
                // Side by side, the title would get a column a few letters wide at accessibility sizes, so the
                // stream controls go under it.
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))) {
                    titleBlock
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    streamControls
                }
                .transition(.opacity)
                progressRow
                    .transition(.opacity)
            }
            panelBar
            if panel != nil {
                PanelPager(
                    item: item,
                    people: people,
                    model: model,
                    panels: availablePanels,
                    selection: $panel,
                    height: isCompact ? compactPanelHeight : regularPanelHeight,
                    isCompact: isCompact,
                    showMore: { showsFullInfo = true; touch() },
                    openPerson: { openedPerson = $0; touch() },
                    fromBeginning: playFromBeginning,
                    goToShow: canGoToShow ? { goToShow() } : nil
                )
                // As in the Apple TV app, the picture blurs from just below the pills (see `CustomPlayer`).
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { model.blurTop = $0 - 10 }
                .onDisappear { model.blurTop = nil }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var titleBlock: some View {
        // One line each, until the text is so large that a one-line title would be a few letters.
        let lines = dynamicTypeSize.isAccessibilitySize ? 3 : 1
        return VStack(alignment: .leading, spacing: 2) {
            if let line = showLine {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .secondaryPlayerText()
                    .lineLimit(lines)
            }
            Text(item.title)
                .font(.headline)
                .lineLimit(lines)
        }
    }

    private var showLine: String? {
        guard item.kind == .episode, let series = item.seriesTitle else { return item.extraLabel }
        guard let season = item.seasonNumber, let episode = item.episodeNumber else { return series }
        return "\(series) · S\(season), E\(episode)"
    }

    /// Speed, quality, audio and subtitles, as glyphs in one glass capsule.
    private var streamControls: some View {
        HStack(spacing: 0) {
            speedMenu
            qualityMenu
            if session.info.audioTracks.count > 1 { audioMenu }
            if !session.info.subtitleTracks.isEmpty { subtitlesMenu }
            autoPlayButton
        }
        .padding(.horizontal, 4)
        .glassEffect(.clear.interactive(), in: .capsule)
        .simultaneousGesture(TapGesture().onEnded { touch() })
        .disabled(session.isSwitching)
    }

    private func menuGlyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .frame(width: Self.buttonSize, height: Self.buttonSize)
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { session.info.maxBitrate },
                set: { bitrate in Task { await session.selectMaxBitrate(bitrate) } }
            )) {
                Text("Maximum").tag(Int?.none)
                ForEach(StreamQuality.choices(for: session.info)) { quality in
                    Text(quality.title).tag(Optional(quality.maxBitrate))
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph("sparkles.tv")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Quality")
        .accessibilityValue(qualityLabel)
    }

    private static let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                ForEach(Self.playbackRates, id: \.self) { rate in
                    Text(rate == 1 ? String(localized: "Normal") : "\(rate.formatted())×").tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph("gauge.with.dots.needle.67percent")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Playback Speed")
        .accessibilityValue("\(model.playbackRate.formatted())×")
    }

    private var audioMenu: some View {
        Menu {
            Picker("Audio", selection: Binding(
                get: { session.audioIndex },
                set: { index in if let index { Task { await session.selectAudio(index) } } }
            )) {
                ForEach(session.info.audioTracks) { Text($0.title).tag(Optional($0.index)) }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph("waveform")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Audio")
        .accessibilityValue(session.info.audioTracks.first { $0.index == session.audioIndex }?.title ?? "")
    }

    private var subtitlesMenu: some View {
        Menu {
            Picker("Subtitles", selection: Binding(
                get: { session.subtitleIndex },
                set: { index in Task { await session.selectSubtitle(index) } }
            )) {
                Text("Off").tag(Int?.none)
                ForEach(session.info.subtitleTracks) { Text($0.title).tag(Optional($0.index)) }
            }
            .pickerStyle(.inline)

            // For a file whose subtitles don't line up with the speech.
            if session.subtitleIndex != nil, !session.info.subtitlesBurnedIn {
                Button("Adjust Timing…", systemImage: "clock.arrow.2.circlepath") {
                    model.showsTiming = true
                }
            }
        } label: {
            menuGlyph("captions.bubble")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(session.info.subtitleTracks.first { $0.index == session.subtitleIndex }?.title ?? String(localized: "Off"))
    }

    /// Turns the automatic start of the next episode on or off: the same setting as on the Account screen. Always there,
    /// whatever's playing: it's a preference, and one that appeared only once something had been looked up (the next episode
    /// comes from the server after playback starts) would pop in late. The filled glyph is on.
    private var autoPlayButton: some View {
        Button {
            session.autoPlaysNext.toggle()
        } label: {
            menuGlyph(session.autoPlaysNext ? "play.square.stack.fill" : "play.square.stack")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Autoplay Next Episode")
        .accessibilityValue(session.autoPlaysNext ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    /// The cap chosen, or the resolution actually playing when there's no cap.
    private var qualityLabel: String {
        if let cap = session.info.maxBitrate, let quality = StreamQuality.choices(for: session.info).first(where: { $0.maxBitrate == cap }) {
            return quality.height >= 2160 ? "4K" : "\(quality.height)p"
        }
        switch model.videoHeight {
        case 2000...: return "4K"
        case 1400..<2000: return "1440p"
        case 1000..<1400: return "1080p"
        case 700..<1000: return "720p"
        case 1..<700: return "SD"
        default: return String(localized: "Quality")
        }
    }

    // The position changes ten times a second. It's read only in these two small views, so the rest of the controls,
    // and the menus in them, aren't rebuilt every time it moves: a menu that's rebuilt while open drops taps.
    private var progressRow: some View {
        PlayerProgressRow(
            model: model,
            scrubFraction: $scrubFraction,
            onBegin: { model.beginScrubbing(); touch() },
            onChange: { fraction in
                // Showing frames while dragging is only cheap for the original file. On a server-made stream,
                // every jump can make the server restart its transcode, so that waits for the finger to lift.
                if session.info.method == .directPlay { model.scrub(to: fraction * model.duration) }
            },
            onEnd: { model.endScrubbing(at: $0 * model.duration); touch() }
        )
    }

    /// Info, Cast and Chapters (each only if there's something to show), and the end time.
    @ViewBuilder
    private var panelBar: some View {
        if showsExpandedPanelBar {
            HStack(spacing: 8) {
                ForEach(availablePanels) { panel in
                    pill(panel)
                }
                Spacer(minLength: 8)
                if panel == nil {
                    PlayerEndTime(model: model, scrubFraction: scrubFraction)
                }
            }
        } else {
            // At the largest text sizes the pills don't fit side by side, so they scroll, and the end time goes.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(availablePanels) { panel in
                        pill(panel)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var availablePanels: [Panel] {
        Panel.allCases.filter { panel in
            switch panel {
            case .info: item.overview != nil || item.tagline != nil
            case .cast: !people.isEmpty
            case .chapters: !model.chapters.isEmpty
            }
        }
    }

    private func pill(_ panel: Panel) -> some View {
        let isSelected = self.panel == panel
        return Button {
            self.panel = isSelected ? nil : panel
            touch()
        } label: {
            Text(panel.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: .capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func circleButton(_ systemImage: String, label: LocalizedStringKey, size: CGFloat = PlayerControlsView.buttonSize, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: Behaviour

    private func toggleControls() {
        if model.showsTiming { return }
        if panel != nil { panel = nil; touch() } else { setControls(visible: !showsControls) }
    }

    private func setControls(visible: Bool) {
        showsControls = visible
        interactions += 1
    }

    private func touch() { interactions += 1 }

    private var canGoToShow: Bool { item.kind == .episode && item.seriesID != nil }

    private func playFromBeginning() {
        model.seek(to: 0)
        model.player.play()
        panel = nil
        touch()
    }

    /// Closes the player and opens the episode's show behind it.
    private func goToShow() {
        guard let seriesID = item.seriesID else { return }
        Task {
            guard let show = try? await appModel.service.item(id: seriesID) else { return }
            appModel.pendingShow = show
            close()
        }
    }

    /// The cast is only on a fully fetched item, not on the list rows that usually start playback.
    private func loadPeople() async {
        var full = item
        if item.people.isEmpty || item.chapters.isEmpty, let fetched = try? await appModel.service.item(id: item.id) {
            full = fetched
        }
        people = full.people
        model.setServerChapters(full.chapters.enumerated().map { index, chapter in
            PlayerChapter(
                id: index,
                title: chapter.name.isEmpty ? String(localized: "Chapter \(index + 1)") : chapter.name,
                start: chapter.start,
                imageURL: chapter.imageURL
            )
        })
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

private extension PlayerControlsView.Panel {
    var title: LocalizedStringKey {
        switch self {
        case .info: "Info"
        case .cast: "Cast & Crew"
        case .chapters: "Chapters"
        }
    }
}

/// A button that shrinks and dims while pressed.
private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Moves the subtitles earlier or later, for a file whose subtitles don't line up with the speech. The picture and
/// subtitles stay visible behind it, so the change can be judged as it's made.
struct SubtitleTimingPanel: View {
    let session: PlaybackSession
    let touch: () -> Void
    let done: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Subtitle Timing")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.offsetText(session.subtitleOffset))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }

            HStack(spacing: 12) {
                nudge("minus", label: "Show Earlier", by: -0.1)
                Slider(
                    value: Binding(get: { session.subtitleOffset }, set: { session.setSubtitleOffset($0); touch() }),
                    in: -10...10,
                    step: 0.1
                )
                .tint(.white)
                .accessibilityLabel("Subtitle timing")
                .accessibilityValue(Self.offsetText(session.subtitleOffset))
                nudge("plus", label: "Show Later", by: 0.1)
            }

            HStack {
                Button("Reset") { session.resetSubtitleOffset(); touch() }
                    .foregroundStyle(.red)
                    .disabled(session.subtitleOffset == 0)
                    .frame(minHeight: 44)
                Spacer()
                Button("Done", action: done)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
            }
            .font(.subheadline)
        }
        .padding(16)
        .background(.black.opacity(contrast == .increased ? 0.6 : 0.3), in: .rect(cornerRadius: 24))
        .glassEffect(.clear, in: .rect(cornerRadius: 24))
    }

    private func nudge(_ systemImage: String, label: LocalizedStringKey, by seconds: TimeInterval) -> some View {
        Button {
            session.adjustSubtitleOffset(by: seconds)
            touch()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// "+1.5 s", "−0.25 s" or "0 s".
    private static func offsetText(_ offset: TimeInterval) -> String {
        let sign = offset > 0 ? "+" : offset < 0 ? "−" : ""
        return "\(sign)\(abs(offset).formatted(.number.precision(.fractionLength(0...1)))) s"
    }
}

/// The episode that follows, offered near the end of one: its still, number, title and description, and a countdown
/// to starting it, which can be cancelled. Tapping it plays the episode at once. Reads the position itself, so the
/// rest of the controls aren't rebuilt as it moves.
struct NextEpisodeOverlay: View {
    let session: PlaybackSession
    let model: PlayerControlsModel
    let play: (MediaItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the countdown runs from when the card appears, unless the episode ends first.
    fileprivate static let countdown: TimeInterval = 15

    /// With no credits marked by the server, the card appears this long before the end: longer than the countdown,
    /// so the countdown has time to run, with a little to spare.
    private static let fallbackLead: TimeInterval = 45

    /// When the card appears: where the server says the credits start, if it does, else a share of the runtime
    /// before the end.
    static func appearance(session: PlaybackSession, duration: TimeInterval) -> TimeInterval {
        let latest = duration - 10
        if let credits = session.segments.last(where: { $0.kind == .outro && $0.start > duration / 2 }) {
            return min(credits.start, latest)
        }
        return min(duration - fallbackLead, latest)
    }

    /// Whether the card is on screen: an episode with a successor, from the credits to the end.
    static func isShowing(session: PlaybackSession, model: PlayerControlsModel) -> Bool {
        guard session.nextEpisode != nil, !session.autoPlayCancelled, model.duration > 60 else { return false }
        return model.currentTime >= appearance(session: session, duration: model.duration) && model.currentTime < model.duration + 1
    }

    var body: some View {
        if let next = session.nextEpisode, Self.isShowing(session: session, model: model) {
            NextEpisodeCard(session: session, model: model, next: next, play: play)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
        }
    }
}

/// The card itself. It lives only while the card is on screen, so each time it appears its countdown starts afresh,
/// from wherever the position is then: landing in the credits by seeking or resuming doesn't start the next episode
/// at once.
private struct NextEpisodeCard: View {
    let session: PlaybackSession
    let model: PlayerControlsModel
    let next: MediaItem
    let play: (MediaItem) -> Void

    /// The position when the card appeared, which the countdown runs from.
    @State private var shownAt: TimeInterval

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 320

    init(session: PlaybackSession, model: PlayerControlsModel, next: MediaItem, play: @escaping (MediaItem) -> Void) {
        self.session = session
        self.model = model
        self.next = next
        self.play = play
        _shownAt = State(initialValue: model.currentTime)
    }

    var body: some View {
        // Never past the end of the episode, and never more than the countdown, if the position is moved back.
        let due = min(shownAt + NextEpisodeOverlay.countdown, model.duration)
        let remaining = min(max(0, due - model.currentTime), NextEpisodeOverlay.countdown)
        card(remaining: remaining, total: max(1, due - shownAt))
            .onAppear {
                AccessibilityNotification.Announcement(String(localized: "Up next: \(next.title)")).post()
            }
            // Due: the countdown ran out, or the episode ended.
            .onChange(of: remaining < 0.5 && !session.autoPlayCancelled, initial: true) { _, isDue in
                if isDue { play(next) }
            }
    }

    private func card(remaining: TimeInterval, total: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { play(next) } label: {
                // The title goes under the picture at accessibility sizes, where beside it there'd be a few letters.
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))) {
                    CachedAsyncImage(url: next.thumbnailURL ?? next.backdropURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.1)
                        }
                    }
                    .frame(width: 128, height: 72)
                    .clipShape(.rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Up Next")
                            .font(.caption.weight(.semibold))
                            .secondaryPlayerText()
                        if let line = Self.numberLine(for: next) {
                            Text(line)
                                .font(.caption)
                                .secondaryPlayerText()
                        }
                        Text(next.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    .multilineTextAlignment(.leading)
                    // Room for the close button in the corner.
                    .padding(.trailing, 24)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Up next: \(Self.numberLine(for: next) ?? ""), \(next.title)")
            .accessibilityHint("Plays the episode")
            .accessibilityAddTraits(.isButton)

            // Side by side, or stacked when the text is too big for them to fit.
            ViewThatFits {
                HStack {
                    playButton
                    Spacer()
                    countdownText(remaining)
                }
                VStack(alignment: .leading, spacing: 8) {
                    playButton
                    countdownText(remaining)
                }
            }

            // The countdown, running out left to right the way the video does. The text above says it for
            // VoiceOver.
            ProgressView(value: total - min(remaining, total), total: total)
                .tint(.white)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: cardWidth)
        // A light scrim, since the glass is clear and the text is white over whatever the picture is showing.
        .background(.black.opacity(contrast == .increased ? 0.6 : 0.3), in: .rect(cornerRadius: 24))
        .glassEffect(.clear, in: .rect(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            // Turns autoplay off and puts the card away. A 44-point target around the 28-point circle.
            Button {
                session.autoPlayCancelled = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding([.top, .trailing], 2)
            .accessibilityLabel("Cancel Autoplay")
        }
        .accessibilityElement(children: .contain)
    }

    private var playButton: some View {
        Button { play(next) } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                // Dark on white, like the Skip button and the show page's Play button.
                .foregroundStyle(.black)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
        .controlSize(.regular)
    }

    private func countdownText(_ remaining: TimeInterval) -> some View {
        Text("Playing in \(Int(remaining.rounded(.up)))")
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .contentTransition(.numericText())
            // The number changes every second; VoiceOver reads it when asked, not on each change.
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// "Season 2, Episode 4", or what's known of it.
    private static func numberLine(for item: MediaItem) -> String? {
        switch (item.seasonNumber, item.episodeNumber) {
        case let (season?, episode?): String(localized: "Season \(season), Episode \(episode)")
        case let (nil, episode?): String(localized: "Episode \(episode)")
        default: nil
        }
    }
}

/// "Skip Intro", "Skip Credits" and so on, while the picture is in a stretch the server has marked. Reads the
/// position itself, so the rest of the controls aren't rebuilt as it moves.
struct SkipSegmentButton: View {
    let session: PlaybackSession
    let model: PlayerControlsModel

    var body: some View {
        if let segment = session.segment(at: model.currentTime), !NextEpisodeOverlay.isShowing(session: session, model: model) {
            Button {
                model.seek(to: segment.end)
            } label: {
                Label(Self.title(for: segment.kind), systemImage: "forward.end.fill")
                    .font(.headline)
                    // It floats over the picture and controls, so it stops growing before it covers them.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    // Dark on white, like the show page's Play button.
                    .foregroundStyle(.black)
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
            .transition(.opacity)
        }
    }

    private static func title(for kind: MediaSegment.Kind) -> LocalizedStringKey {
        switch kind {
        case .intro: "Skip Intro"
        case .outro: "Skip Outro"
        case .recap: "Skip Recap"
        case .preview: "Skip Preview"
        case .commercial: "Skip Commercial"
        case .unknown: "Skip"
        }
    }
}

/// The elapsed and remaining times either side of the progress bar.
private struct PlayerProgressRow: View {
    let model: PlayerControlsModel
    @Binding var scrubFraction: Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        let shown = scrubFraction.map { $0 * model.duration } ?? model.currentTime
        let remaining = max(0, model.duration - shown)

        HStack(spacing: 10) {
            Text(PlayerControlsView.clock(shown))
            ScrubBar(
                fraction: model.duration > 0 ? model.currentTime / model.duration : 0,
                buffered: model.duration > 0 ? model.bufferedTime / model.duration : 0,
                scrubFraction: $scrubFraction,
                onBegin: onBegin,
                onChange: onChange,
                onEnd: onEnd
            )
            Text("−\(PlayerControlsView.clock(remaining))")
        }
        .font(.footnote.monospacedDigit().weight(.medium))
        // The bar needs room between the times, and they're one line, so they stop growing before they'd be cut.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
    }
}

/// When the video finishes if it plays on from here.
private struct PlayerEndTime: View {
    let model: PlayerControlsModel
    let scrubFraction: Double?

    var body: some View {
        let end = Date.now + max(0, model.duration - (scrubFraction.map { $0 * model.duration } ?? model.currentTime))
        Text("Ends \(end.formatted(date: .omitted, time: .shortened))")
            .font(.footnote.monospacedDigit().weight(.medium))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .secondaryPlayerText()
            .lineLimit(1)
            .fixedSize()
    }
}

/// A draggable progress bar. Like the system one, dragging moves the position by how far the finger travels
/// rather than jumping to where it lands, and the further the finger strays above or below the bar, the finer
/// the control.
private struct ScrubBar: View {
    let fraction: Double
    /// How much has loaded, from 0 to 1. Shaded between the empty track and the played part.
    let buffered: Double
    @Binding var scrubFraction: Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    /// The finger's last horizontal position, while dragging.
    @State private var lastX: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let value = min(max(scrubFraction ?? fraction, 0), 1)

            let barHeight: CGFloat = scrubFraction == nil ? 6 : 12

            ZStack(alignment: .leading) {
                Color.white.opacity(contrast == .increased ? 0.5 : 0.3)
                Color.white.opacity(contrast == .increased ? 0.7 : 0.35).frame(width: proxy.size.width * min(max(buffered, 0), 1))
                // Square-ended and clipped to the track, like the home carousel's page pill, so it sweeps across the
                // rounded ends instead of squashing into a shape of its own.
                Color.white.frame(width: proxy.size.width * value)
            }
            .clipShape(.capsule)
            .frame(height: barHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let current = scrubFraction ?? fraction
                        if scrubFraction == nil {
                            lastX = drag.startLocation.x
                            onBegin()
                        }
                        let distance = drag.location.x - (lastX ?? drag.location.x)
                        lastX = drag.location.x

                        let drift = abs(drag.location.y - proxy.size.height / 2)
                        let rate: Double = switch drift {
                        case ..<60: 1
                        case ..<120: 0.5
                        case ..<180: 0.25
                        default: 0.1
                        }
                        let next = min(max(current + distance / max(proxy.size.width, 1) * rate, 0), 1)
                        scrubFraction = next
                        onChange(next)
                    }
                    .onEnded { _ in
                        onEnd(scrubFraction ?? fraction)
                        scrubFraction = nil
                        lastX = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrubFraction == nil)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            onEnd(min(max(fraction + (direction == .increment ? 0.02 : -0.02), 0), 1))
        }
    }
}

// MARK: - Panels

/// The selected one of Info, Cast and Chapters, below the pills, as in the Apple TV app. Panels are switched with
/// their pills rather than by swiping, which would fight the horizontal scrolling of the cast row.
private struct PanelPager: View {
    let item: MediaItem
    let people: [MediaPerson]
    let model: PlayerControlsModel
    let panels: [PlayerControlsView.Panel]
    @Binding var selection: PlayerControlsView.Panel?
    let height: CGFloat
    let isCompact: Bool
    let showMore: () -> Void
    let openPerson: (MediaPerson) -> Void
    let fromBeginning: () -> Void
    /// Nil when the item isn't an episode.
    let goToShow: (() -> Void)?

    var body: some View {
        Group {
            if let selection {
                content(for: selection)
                    .id(selection)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: height)
        // A scroll view's clip reaches into the safe area, which the controls ignore, so keep it to this frame.
        .clipShape(.rect)
    }

    @ViewBuilder
    private func content(for panel: PlayerControlsView.Panel) -> some View {
        switch panel {
        case .info: InfoPane(item: item, isCompact: isCompact, showMore: showMore, fromBeginning: fromBeginning, goToShow: goToShow)
        case .cast: CastPane(people: people, open: openPerson)
        case .chapters: ChaptersPane(model: model) { selection = nil }
        }
    }
}

private struct InfoPane: View {
    let item: MediaItem
    let isCompact: Bool
    let showMore: () -> Void
    let fromBeginning: () -> Void
    let goToShow: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Vertical, so it never fights the sideways swipe between panes.
        ScrollView {
            if dynamicTypeSize.isAccessibilitySize {
                // Side by side there'd be room for a few letters of text, so the buttons go under it.
                VStack(alignment: .leading, spacing: 16) {
                    text
                    VStack(spacing: 8) { buttons }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // Portrait has no room for the thumbnail, as in the Apple TV app.
                    if !isCompact { thumbnail(width: 190) }
                    text
                    Spacer(minLength: 0)
                    VStack(spacing: 8) { buttons }
                        .frame(width: isCompact ? 150 : 190)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func thumbnail(width: CGFloat) -> some View {
        CachedAsyncImage(url: item.thumbnailURL ?? item.backdropURL ?? item.posterURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.kind == .episode ? item.seriesTitle ?? item.title : item.title)
                .font(.headline)
            if item.kind == .episode, item.seriesTitle != nil {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else if let tagline = item.tagline {
                Text(tagline).font(.subheadline.weight(.semibold))
            }
            if let overview = item.overview {
                TruncatingOverview(text: overview, lineLimit: isCompact ? 5 : 3, onMore: showMore)
            }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .secondaryPlayerText()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var details: [String] {
        [
            item.genres.first,
            item.runtime.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) },
            item.technicalLine,
            item.officialRating
        ].compactMap { $0 }
    }

    @ViewBuilder
    private var buttons: some View {
        actionButton("From Beginning", systemImage: "play.fill", action: fromBeginning)
        if let goToShow {
            actionButton("Go to Show", systemImage: "info.circle", action: goToShow)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .capsule)
    }
}

/// The whole description, over the player. It's a system sheet, which is Liquid Glass, so the picture shows through.
private struct FullInfoSheet: View {
    let item: MediaItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The title goes under the thumbnail when beside it there'd be too little room: at accessibility sizes,
                // or on a narrow sheet.
                if dynamicTypeSize.isAccessibilitySize {
                    stackedHeader
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            thumbnail
                            titleBlock
                                // The column's ideal width, which has to fit for the header to sit side by side.
                                .frame(maxWidth: 200, alignment: .leading)
                        }
                        // Leaves room for the close button, which sits over the top corner.
                        .padding(.trailing, 48)

                        stackedHeader
                    }
                }
                if let tagline = item.tagline {
                    Text(tagline).font(.headline)
                }
                if let overview = item.overview {
                    Text(overview).font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(16)
            .accessibilityLabel("Close")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            thumbnail
            titleBlock
        }
    }

    private var thumbnail: some View {
        CachedAsyncImage(url: item.thumbnailURL ?? item.backdropURL ?? item.posterURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 160, height: 90)
        .clipShape(.rect(cornerRadius: 10))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.kind == .episode ? item.seriesTitle ?? item.title : item.title)
                .font(.title3.weight(.bold))
            if item.kind == .episode, item.seriesTitle != nil {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
            }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: [String] {
        [
            item.genres.first,
            item.year.map(String.init),
            item.runtime.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) },
            item.officialRating,
            item.technicalLine
        ].compactMap { $0 }
    }
}

private struct CastPane: View {
    let people: [MediaPerson]
    let open: (MediaPerson) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A card's width, and its portrait's, which grow with the text (up to a point) so names aren't cut short.
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 124
    @ScaledMetric(relativeTo: .caption) private var portraitSize: CGFloat = 52

    var body: some View {
        let lines = dynamicTypeSize.isAccessibilitySize ? 3 : 1
        // Sideways, as in the Apple TV app. The panels aren't paged, so this has the swipe to itself.
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(people) { person in
                    Button { open(person) } label: {
                    VStack(spacing: 2) {
                        PersonPortrait(person: person, size: min(portraitSize, 52 * 1.5))
                            .padding(.bottom, 4)
                        Text(person.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(lines)
                        Text(person.subtitle ?? " ")
                            .font(.caption2)
                            .secondaryPlayerText()
                            .lineLimit(lines)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .frame(width: min(cardWidth, 124 * 1.6))
                    .contentShape(.rect(cornerRadius: 24))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 24))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

private struct ChaptersPane: View {
    let model: PlayerControlsModel
    let done: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A card's width, which grows with the text (up to a point) so chapter names aren't cut short.
    @ScaledMetric(relativeTo: .caption) private var baseWidth: CGFloat = 140

    var body: some View {
        let width = min(baseWidth, 140 * 1.6)
        // Sideways, like the cast row.
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.chapters) { chapter in
                    Button {
                        model.seek(to: chapter.start)
                        done()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if chapter.imageURL != nil {
                                CachedAsyncImage(url: chapter.imageURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.1)
                                    }
                                }
                                .frame(width: width, height: width * 79 / 140)
                                .clipShape(.rect(cornerRadius: 12))
                            }
                            Text(chapter.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            Text(PlayerControlsView.clock(chapter.start))
                                .font(.caption2.monospacedDigit())
                                .secondaryPlayerText()
                        }
                        .frame(width: width, alignment: .leading)
                        .padding(8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 20))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// Lays the controls out against the device the preview runs on, measured the way the player does, over a bright
/// backdrop, so the white text is judged against the worst case. Used by the previews below.
private struct ControlsPreviewHost: View {
    let item: MediaItem
    let session: PlaybackSession
    let model: PlayerControlsModel
    var initialPanel: PlayerControlsView.Panel?

    @State private var screen = PlayerScreen()

    var body: some View {
        ZStack {
            LinearGradient(colors: [.white, .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Color.clear
                .onGeometryChange(for: PlayerScreen.Shape.self) { proxy in
                    PlayerScreen.Shape(size: proxy.size, corners: proxy.containerCornerInsets)
                } action: { screen.update($0) }
                .ignoresSafeArea()
            PlayerControlsView(item: item, session: session, model: model, screen: screen, initialPanel: initialPanel) {}
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { screen.safeArea = $0 }
        .environment(AppModel.preview())
    }

    static func make(
        item: MediaItem = .previewEpisode,
        position: TimeInterval = 600,
        nextEpisode: MediaItem? = nil,
        segments: [MediaSegment] = [],
        panel: PlayerControlsView.Panel? = nil
    ) -> some View {
        let session = PlaybackSession(
            item: item,
            info: PlaybackInfo(
                url: URL(filePath: "/dev/null"),
                resumePosition: 0,
                playSessionID: nil,
                mediaSourceID: nil,
                method: .transcode,
                audioTracks: [
                    MediaTrack(index: 1, title: "English - AAC - Stereo", isExternal: false),
                    MediaTrack(index: 2, title: "English - Commentary", isExternal: false)
                ],
                subtitleTracks: [MediaTrack(index: 3, title: "English - SRT", isExternal: true)],
                audioIndex: 1,
                sourceBitrate: 20_000_000,
                sourceHeight: 1080
            ),
            service: MockMediaService()
        )
        session.setPreview(nextEpisode: nextEpisode, segments: segments)
        let model = PlayerControlsModel(player: AVPlayer(), runtime: 1500)
        model.setPreviewPosition(position)
        return ControlsPreviewHost(item: item, session: session, model: model, initialPanel: panel)
    }
}

#Preview("Controls") {
    ControlsPreviewHost.make()
}

#Preview("Info panel") {
    ControlsPreviewHost.make(panel: .info)
}

#Preview("Cast panel") {
    ControlsPreviewHost.make(panel: .cast)
}

#Preview("Up Next") {
    ControlsPreviewHost.make(position: 1470, nextEpisode: .previewEpisode)
}

#Preview("Skip Intro") {
    ControlsPreviewHost.make(position: 30, segments: [MediaSegment(kind: .intro, start: 10, end: 80)])
}
#endif
