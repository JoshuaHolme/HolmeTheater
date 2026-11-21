// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import AVKit
import Observation

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

/// Tells whether Picture in Picture is starting or running. The controller's own `isPictureInPictureActive` stays false
/// for a moment after the window has started to appear.
@MainActor
private final class PictureInPictureWatcher: NSObject, AVPictureInPictureControllerDelegate {
    // AVKit calls a Picture in Picture controller's delegate on the main thread, so these check that rather than hop to it.
    private(set) var isEngaged = false

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isEngaged = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isEngaged = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated { isEngaged = false }
    }
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

    /// Passes a tap on the picture on to the controls. See ``pictureTaps``.
    func tapPicture() { pictureTaps += 1 }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var hasServerChapters = false
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private let pipWatcher = PictureInPictureWatcher()
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

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
        // On the main queue, so the observer runs on the main actor, which `assumeIsolated` checks rather than hops to.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The periodic observer goes quiet once time stops moving, so on its own it would miss a stall starting
        // (or ending) and leave the controls showing "playing" with no spinner.
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await loadChapters() }

        // Locking the device, or leaving for another app, pauses the video unless Picture in Picture carries it on.
        // It's left for the Lock Screen's or Control Center's "now playing" card to resume.
        backgroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                // Picture in Picture starts a moment after the app goes to the background.
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, !pipWatcher.isEngaged, pip?.isPictureInPictureActive != true,
                      player.timeControlStatus != .paused else { continue }
                player.pause()
            }
        }
    }

    /// Stops watching the player. Call when the controls go away; the player itself is left as it is.
    func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    /// Runs ten times a second. Each property is only written when it changes, so views that read one that hasn't (the
    /// play button, say, while the clock runs) aren't drawn again.
    private func tick() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, pendingScrub == nil, !isScrubSeeking { update(\.currentTime, to: max(0, seconds)) }
        if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 { update(\.duration, to: length) }
        update(\.isPlaying, to: player.timeControlStatus != .paused || resumesAfterScrub)
        update(\.isBuffering, to: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        update(\.videoSize, to: player.currentItem?.presentationSize ?? .zero)
        update(\.bufferedTime, to: loadedEnd(around: seconds))
    }

    private func update<Value: Equatable>(_ property: ReferenceWritableKeyPath<PlayerControlsModel, Value>, to value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
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

    /// Jumps to `seconds`, kept within the video. The position shown moves at once, without waiting for the seek.
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

    /// Zooms the video to fill the screen, or back to fitting it, with a tap of haptic feedback when it changes.
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
        controller?.delegate = pipWatcher
        pip = controller
    }

    /// Whether the device does Picture in Picture, which is known from the start. Not whether the controller exists yet:
    /// that's made once the video's layer is on screen, and isn't observed, so the button waited for something else to
    /// redraw the controls and then appeared in the middle of playback.
    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Starts or stops Picture in Picture. Does nothing until the video's layer has been attached.
    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}
#endif
