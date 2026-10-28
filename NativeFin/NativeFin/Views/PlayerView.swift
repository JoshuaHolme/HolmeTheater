// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import SwiftUI

/// Full-screen AVPlayer for one item: custom controls on iOS, the system player on tvOS.
struct PlayerView: View {
    let item: MediaItem

    /// Called after the player closes, once the server has been told where playback stopped, so the presenter
    /// can refresh and show the latest progress.
    var onStop: () -> Void = {}

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// Created once the server has said how to play the item; nil while loading or after an error.
    @State private var session: PlaybackSession?
    @State private var errorMessage: String?
    /// The episode playing after "Up Next" moved on from the one this view was opened with. Nil until then.
    @State private var followingItem: MediaItem?

    /// What's playing: the item this view was opened with, or the episode that followed it.
    private var playing: MediaItem { followingItem ?? item }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                #if os(iOS)
                CustomPlayer(item: session.item, session: session, playNext: playNext, close: close)
                    // A new session is a new player: its own model, controls and clock.
                    .id(ObjectIdentifier(session))
                #else
                VideoPlayer(player: session.player)
                    .ignoresSafeArea()
                #endif
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can't Play", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Close") { dismiss() }
                }
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        // SwiftUI can rebuild this view, or run `task`, `onAppear` and `onDisappear` again, when the window
        // changes shape (rotation, a foldable opening or closing, split view). So the session lives in the app
        // model, a rebuilt player picks the same one up, and it only stops when the player closes for real.
        .task { await load() }
        .onAppear { session?.viewerAppeared() }
        .onDisappear { session?.viewerDisappeared() }
    }

    /// Picks up the item's playback if it's already going, or asks the server how to play it and starts.
    private func load() async {
        guard session == nil else { return }

        if let current = appModel.playback, !current.isStopped {
            // The session this view started, even if "Up Next" has since moved it on to the following episode.
            if current.originID == item.id {
                current.onStop = onStop
                session = current
                current.viewerAppeared()
                return
            }
            current.stop(then: current.onStop)
        }

        do {
            let info = try await appModel.service.playbackInfo(for: playing, options: PlaybackOptions())
            // Dismissed while the server was thinking.
            guard !Task.isCancelled else { return }
            let session = PlaybackSession(item: playing, info: info, service: appModel.service)
            session.originID = item.id
            session.onStop = onStop
            appModel.playback = session
            self.session = session
            session.viewerAppeared()
            await session.start()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Finishes this episode and starts the next one in the same player. Moving on means the episode was watched, so
    /// it's marked played, not left at the position where playback stopped.
    private func playNext(_ next: MediaItem) {
        guard let finished = session else { return }
        let (service, onStop) = (appModel.service, onStop)
        // After the server has the final position, so marking it played isn't undone by that report.
        finished.stop {
            Task {
                try? await service.markWatched(itemID: finished.item.id)
                onStop()
            }
        }
        session = nil
        errorMessage = nil
        followingItem = next
        Task { await load() }
    }

    private func close() {
        session?.stop(then: onStop)
        dismiss()
    }
}

/// A bitrate cap offered in the quality menu.
struct StreamQuality: Identifiable, Hashable {
    let maxBitrate: Int
    let height: Int

    var id: Int { maxBitrate }

    var title: String {
        let resolution = height >= 2160 ? "4K" : "\(height)p"
        let rate = maxBitrate >= 1_000_000
            ? "\((Double(maxBitrate) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))) Mbps"
            : "\(maxBitrate / 1000) kbps"
        return "\(resolution) · \(rate)"
    }

    private static let all = [
        StreamQuality(maxBitrate: 60_000_000, height: 2160),
        StreamQuality(maxBitrate: 40_000_000, height: 2160),
        StreamQuality(maxBitrate: 20_000_000, height: 1080),
        StreamQuality(maxBitrate: 10_000_000, height: 1080),
        StreamQuality(maxBitrate: 4_000_000, height: 720),
        StreamQuality(maxBitrate: 1_500_000, height: 480),
        StreamQuality(maxBitrate: 720_000, height: 360)
    ]

    /// The caps worth offering for a file: lower than its own bitrate, and no taller than its picture.
    static func choices(for info: PlaybackInfo) -> [StreamQuality] {
        all.filter { quality in
            (info.sourceBitrate.map { quality.maxBitrate < $0 } ?? true)
                && (info.sourceHeight.map { quality.height <= max($0, 360) } ?? true)
        }
    }
}

/// Owns the AVPlayer for one playback and keeps the server informed:
/// started, progress every 10 seconds, stopped.
///
/// Call `start()` once, and `stop()` when the player goes away. `stop()` may be called at any point,
/// even while `start()` is still running, and more than once.
///
/// Changing quality, or a track the current stream doesn't carry, asks the server for a new stream and
/// carries on from the same point in it.
@Observable
final class PlaybackSession {
    let player: AVPlayer
    let item: MediaItem

    /// How the current stream is being delivered, and the tracks and qualities on offer.
    private(set) var info: PlaybackInfo

    /// The audio track playing.
    private(set) var audioIndex: Int?

    /// The subtitle track on screen, or nil for none. Can be nil while the stream still carries one,
    /// when the player has just hidden it.
    private(set) var subtitleIndex: Int?

    /// Whether a new stream is being fetched for a change of quality or track.
    private(set) var isSwitching = false

    /// The ID of the item the player was opened with, which can differ from ``item`` once "Up Next" has moved on.
    @ObservationIgnored var originID: String?

    /// The episode that follows this one, for the "Up Next" card. Nil for anything else, or if there isn't one.
    private(set) var nextEpisode: MediaItem?

    /// Whether the viewer has cancelled the automatic start of the next episode.
    var autoPlayCancelled = false

    /// The intro, credits and so on the server has marked, which the player offers to skip.
    private(set) var segments: [MediaSegment] = []

    /// Whether the player's controls are showing. Kept here so a rebuilt player view picks up where the last left off.
    @ObservationIgnored var controlsAreShowing = true

    /// The lines of the subtitle track on screen, drawn by the app. Empty for none, or while they load.
    private(set) var subtitleCues: [SubtitleCue] = []
    @ObservationIgnored private var cueTask: Task<Void, Never>?

    /// How many seconds later than the file says the subtitles show, for a file whose subtitles don't line up.
    /// Negative shows them earlier. Remembered for the item.
    private(set) var subtitleOffset: TimeInterval = 0

    /// Why the last change of quality or track failed. The old stream carries on playing.
    var switchError: String?

    /// Called once the server has the final position after ``stop(then:)`` or when the session is released.
    @ObservationIgnored var onStop: () -> Void = {}

    @ObservationIgnored private(set) var isStopped = false
    @ObservationIgnored private let service: any MediaService
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    /// The "started" report, once sent. "Stopped" waits for it, so the server never sees them out of order
    /// (which would leave a phantom "now playing" session on the server).
    @ObservationIgnored private var startReport: Task<Void, Never>?

    /// How many player views are showing this session. See ``viewerDisappeared()``.
    @ObservationIgnored private var viewers = 0

    #if os(iOS)
    /// Keeps the screen from locking while the video plays, as the system player does.
    @ObservationIgnored private var keepAwake: NSKeyValueObservation?
    #endif

    init(item: MediaItem, info: PlaybackInfo, service: any MediaService) {
        self.item = item
        self.info = info
        self.service = service
        self.audioIndex = info.audioIndex
        self.subtitleIndex = info.subtitleIndex
        self.subtitleOffset = UserDefaults.standard.double(forKey: Self.offsetKey(for: item))
        self.player = AVPlayer(playerItem: Self.makePlayerItem(for: item, info: info))
        // A direct-play file starts as soon as the first bytes arrive; HLS needs the default buffering.
        player.automaticallyWaitsToMinimizeStalling = info.method != .directPlay

        #if os(iOS)
        // Paused, the screen may lock as usual.
        keepAwake = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let isPlaying = player.timeControlStatus != .paused
            Task { @MainActor in
                // A change still on its way when playback stopped mustn't keep the screen awake after it.
                guard let self, !self.isStopped else { return }
                UIApplication.shared.isIdleTimerDisabled = isPlaying
            }
        }
        #endif
    }

    /// Stops and reports if the session is released without being stopped.
    isolated deinit {
        stop(then: onStop)
    }

    private static func makePlayerItem(for item: MediaItem, info: PlaybackInfo) -> AVPlayerItem {
        let playerItem = AVPlayerItem(url: info.url)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = item.title as NSString
        title.extendedLanguageTag = "und"
        playerItem.externalMetadata = [title]
        return playerItem
    }

    /// Moves the subtitles later (or, if negative, earlier) by `seconds`, and remembers it for this item.
    func adjustSubtitleOffset(by seconds: TimeInterval) {
        setSubtitleOffset(subtitleOffset + seconds)
    }

    func resetSubtitleOffset() { setSubtitleOffset(0) }

    func setSubtitleOffset(_ offset: TimeInterval) {
        subtitleOffset = (offset * 100).rounded() / 100
        let key = Self.offsetKey(for: item)
        if subtitleOffset == 0 {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(subtitleOffset, forKey: key)
        }
    }

    private static func offsetKey(for item: MediaItem) -> String { "subtitleOffset.\(item.id)" }

    /// The episode after this one: the next in its season, else the first of the next season that has any.
    private func findNextEpisode() async -> MediaItem? {
        guard item.kind == .episode, let seriesID = item.seriesID,
              let series = try? await service.item(id: seriesID),
              let top = try? await service.children(of: series) else { return nil }

        // Some services list a show's episodes directly.
        if top.first?.kind == .episode { return Self.episode(after: item, in: top) }

        guard let seasonIndex = top.firstIndex(where: { $0.id == item.seasonID }) else { return nil }
        if let episodes = try? await service.children(of: top[seasonIndex]), let next = Self.episode(after: item, in: episodes) {
            return next
        }
        for season in top[(seasonIndex + 1)...] {
            if let first = try? await service.children(of: season).first(where: { $0.kind == .episode }) { return first }
        }
        return nil
    }

    private static func episode(after item: MediaItem, in episodes: [MediaItem]) -> MediaItem? {
        guard let index = episodes.firstIndex(where: { $0.id == item.id }) else { return nil }
        return episodes[(index + 1)...].first { $0.kind == .episode }
    }

    /// The marked stretch `time` is in, if any.
    func segment(at time: TimeInterval) -> MediaSegment? {
        segments.first { $0.start <= time && time < $0.end }
    }

    /// The subtitle to show at `time`, if any.
    func subtitleText(at time: TimeInterval) -> String? {
        let shifted = time - subtitleOffset
        let lines = subtitleCues.filter { $0.start <= shifted && shifted < $0.end }.map(\.text)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Fetches the lines of the selected subtitle track, or clears them if there's nothing for the app to draw.
    private func loadSubtitleCues() {
        cueTask?.cancel()
        subtitleCues = []
        guard !info.subtitlesBurnedIn, let subtitleIndex,
              let url = info.subtitleTracks.first(where: { $0.index == subtitleIndex })?.url else { return }
        cueTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            subtitleCues = WebVTT.parse(String(decoding: data, as: UTF8.self))
        }
    }

    /// Current playback position in seconds (0 until the player knows it).
    private var position: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    // MARK: Lifecycle

    /// Seeks to the resume position, begins playback, reports "started", and begins periodic progress reports.
    func start() async {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Active, so the volume slider hears about changes made with the hardware buttons.
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        if info.resumePosition > 1 {
            await player.seek(to: CMTime(seconds: info.resumePosition, preferredTimescale: 600))
        }
        // Closed while seeking: don't start playing with nothing on screen.
        guard !isStopped else { return }
        player.play()
        await applyTrackSelection()
        loadSubtitleCues()

        Task { segments = await service.segments(for: item) }
        Task { nextEpisode = await findNextEpisode() }

        let (service, item, info, position) = (service, item, info, position)
        startReport = Task { await service.report(.started, for: item, info: info, position: position, isPaused: false) }

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                await self.service.report(
                    .progress,
                    for: self.item,
                    info: self.info,
                    position: self.position,
                    isPaused: self.player.timeControlStatus == .paused
                )
            }
        }
    }

    /// Stops playback and the progress loop, releases the stream, and reports "stopped" with the final
    /// position (only if "started" was reported).
    ///
    /// - Parameter completion: Called once the server has the final position (or at once, if there's nothing
    ///   to report). Only the first call's runs.
    func stop(then completion: @escaping () -> Void = {}) {
        guard !isStopped else { return }
        isStopped = true
        progressTask?.cancel()
        #if os(iOS)
        keepAwake = nil
        UIApplication.shared.isIdleTimerDisabled = false
        #endif

        let (service, item, info, position) = (service, item, info, position)
        player.pause()
        // Drop the item so AVPlayer closes its network connection now rather than when it's deallocated.
        player.replaceCurrentItem(with: nil)

        guard let startReport else {
            completion()
            return
        }
        // Unstructured so the report still goes out after the view's task is cancelled.
        Task {
            await startReport.value
            await service.report(.stopped, for: item, info: info, position: position, isPaused: true)
            completion()
        }
    }

    /// A player view started showing this session.
    func viewerAppeared() {
        viewers += 1
    }

    /// A player view stopped showing this session. If no other view picks it up within a moment, the player
    /// has closed for real (rather than being rebuilt for a new window shape), so playback stops.
    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if viewers == 0 { stop(then: onStop) }
        }
    }

    // MARK: Quality and tracks

    /// Caps the stream's bitrate, or lifts the cap with nil.
    func selectMaxBitrate(_ bitrate: Int?) async {
        guard bitrate != info.maxBitrate else { return }
        await switchStream { $0.maxBitrate = bitrate }
    }

    func selectAudio(_ index: Int) async {
        guard index != audioIndex else { return }
        // A direct-played file carries all its audio tracks, so the player can switch on its own.
        if info.method == .directPlay, await select(index, among: info.audioTracks, characteristic: .audible) {
            audioIndex = index
            return
        }
        await switchStream { $0.audioIndex = index }
    }

    /// Shows a subtitle track, or hides subtitles with nil.
    func selectSubtitle(_ index: Int?) async {
        guard index != subtitleIndex else { return }
        // The app draws text subtitles itself, so switching needs no new stream. Burned-in subtitles, and tracks
        // made of pictures, are the server's to draw.
        let drawnByApp = !info.subtitlesBurnedIn
            && (index == nil || info.subtitleTracks.first { $0.index == index }?.url != nil)
        if drawnByApp {
            subtitleIndex = index
            loadSubtitleCues()
            return
        }
        await switchStream { $0.subtitleIndex = index ?? PlaybackOptions.noSubtitles }
    }

    /// Asks the server for a new stream with `change` applied, and carries on from the same point in it.
    private func switchStream(_ change: (inout PlaybackOptions) -> Void) async {
        guard !isStopped, !isSwitching else { return }
        var options = PlaybackOptions(
            mediaSourceID: info.mediaSourceID,
            maxBitrate: info.maxBitrate,
            audioIndex: audioIndex,
            subtitleIndex: subtitleIndex ?? PlaybackOptions.noSubtitles
        )
        change(&options)

        isSwitching = true
        defer { isSwitching = false }
        let resumeAt = position
        let wasPlaying = player.timeControlStatus != .paused

        let newInfo: PlaybackInfo
        do {
            newInfo = try await service.playbackInfo(for: item, options: options)
        } catch {
            switchError = error.localizedDescription
            return
        }
        guard !isStopped else { return }

        let oldInfo = info
        info = newInfo
        audioIndex = newInfo.audioIndex
        subtitleIndex = newInfo.subtitleIndex
        player.replaceCurrentItem(with: Self.makePlayerItem(for: item, info: newInfo))
        player.automaticallyWaitsToMinimizeStalling = newInfo.method != .directPlay
        await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        guard !isStopped else { return }
        if wasPlaying { player.play() }
        await applyTrackSelection()
        loadSubtitleCues()

        // Close the old stream on the server (which ends its transcode) before announcing the new one.
        let (service, item, previous) = (service, item, startReport)
        startReport = Task {
            await previous?.value
            await service.report(.stopped, for: item, info: oldInfo, position: resumeAt, isPaused: true)
            await service.report(.started, for: item, info: newInfo, position: resumeAt, isPaused: !wasPlaying)
        }
    }

    /// Makes the player show `subtitleIndex` (and, for a direct-played file, play `audioIndex`) from the tracks
    /// inside the current stream, rather than whatever it would pick by itself.
    private func applyTrackSelection() async {
        guard let playerItem = player.currentItem else { return }
        // The app draws the subtitles, so the player's own are always off, or they'd show twice.
        if let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible) {
            playerItem.select(nil, in: group)
        }

        if info.method == .directPlay, let audioIndex {
            _ = await select(audioIndex, among: info.audioTracks, characteristic: .audible)
        }
    }

    /// Selects the player's own option for a track of a direct-played file. Returns false if the file's tracks
    /// can't be matched up with the server's list.
    private func select(_ index: Int, among tracks: [MediaTrack], characteristic: AVMediaCharacteristic) async -> Bool {
        guard let playerItem = player.currentItem,
              let group = try? await playerItem.asset.loadMediaSelectionGroup(for: characteristic),
              let option = Self.option(for: index, among: tracks, in: group) else { return false }
        playerItem.select(option, in: group)
        return true
    }

    /// The player lists a file's own tracks in the order the server does; external ones aren't in the file.
    private static func option(for index: Int, among tracks: [MediaTrack], in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        let embedded = tracks.filter { !$0.isExternal }
        guard embedded.count == group.options.count,
              let position = embedded.firstIndex(where: { $0.index == index }) else { return nil }
        return group.options[position]
    }
}

#if os(iOS)
/// The video with NativeFin's own controls on top.
private struct CustomPlayer: View {
    let item: MediaItem
    let session: PlaybackSession
    let playNext: (MediaItem) -> Void
    let close: () -> Void

    @State private var model: PlayerControlsModel
    /// What the picture is laid out against, and what the controls are. The same screen, except when iPhone Duo is
    /// partially folded and the two sit in separate halves.
    @State private var videoScreen = PlayerScreen()
    @State private var controlsScreen = PlayerScreen()
    /// Whether the display is partially folded, as iPhone Duo is in laptop view: the picture and subtitles are
    /// above the fold and every control below it.
    @State private var isFolded = false

    init(item: MediaItem, session: PlaybackSession, playNext: @escaping (MediaItem) -> Void, close: @escaping () -> Void) {
        self.item = item
        self.session = session
        self.playNext = playNext
        self.close = close
        _model = State(initialValue: PlayerControlsModel(player: session.player, runtime: item.runtime))
    }

    var body: some View {
        layout
            // Pinch out to fill the screen, pinch in to fit the video back inside it.
            .simultaneousGesture(
                MagnifyGesture().onEnded { value in
                    if value.magnification > 1.1 {
                        model.setFillsScreen(true)
                    } else if value.magnification < 0.9 {
                        model.setFillsScreen(false)
                    }
                }
            )
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var layout: some View {
        if #available(iOS 27.1, *) {
            // Flat, the controls are layered over the video. Partially folded, the system puts the video in one half
            // and the controls in the other: above and below the fold in laptop view, side by side like a book.
            ArrangementView {
                controlsLayer
            } secondary: {
                videoLayer
            }
            .arrangementViewStyle(.overlay)
            .onGeometryChange(for: Bool.self) { !$0.reservedRegions(kind: .division).isEmpty } action: { isFolded = $0 }
        } else {
            ZStack {
                videoLayer
                controlsLayer
            }
        }
    }

    private var controlsLayer: some View {
        ZStack {
            // Measured the same way as the picture's screen, so the controls lay out against their own region.
            Color.clear
                .onGeometryChange(for: PlayerScreen.Shape.self) { proxy in
                    PlayerScreen.Shape(size: proxy.size, corners: proxy.containerCornerInsets)
                } action: { controlsScreen.update($0) }
                .ignoresSafeArea(edges: isFolded ? [] : .all)
            PlayerControlsView(item: item, session: session, model: model, screen: controlsScreen, isFolded: isFolded, playNext: playNext, close: close)
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { controlsScreen.safeArea = $0 }
    }

    private var videoLayer: some View {
        ZStack {
            video
            SubtitleOverlay(session: session, model: model, frame: pictureFrame)
            timingPanel
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { videoScreen.safeArea = $0 }
    }

    /// The panel for adjusting the subtitles' timing, in the middle of the picture. The controls are cleared away
    /// while it's open, so this has the picture to itself.
    private var timingPanel: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if model.showsTiming && !isFolded {
                    SubtitleTimingPanel(session: session, touch: {}) { model.showsTiming = false }
                        .frame(maxWidth: min(440, max(0, pictureFrame.width - 32)))
                        .position(x: pictureFrame.midX, y: pictureFrame.midY)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.showsTiming)
            .ignoresSafeArea()
    }

    /// The picture, centred on the whole of its region. Fitted, it's as big as it can be while keeping clear of the
    /// camera; zoomed to fill, it runs edge to edge.
    private var video: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                PlayerSurface(model: model)
                    .frame(width: pictureFrame.width, height: pictureFrame.height)
                    .offset(x: pictureFrame.minX, y: pictureFrame.minY)
            }
            // With a panel open, the lower part of the picture blurs: a second copy of the video, blurred and
            // masked to start just below the panel buttons.
            .overlay(alignment: .topLeading) {
                if let top = model.blurTop {
                    let frame = pictureFrame
                    PlayerSurface(model: model)
                        .frame(width: frame.width, height: frame.height)
                        .blur(radius: 14, opaque: true)
                        .mask {
                            // A long, soft fade into the blur rather than a hard edge.
                            VStack(spacing: 0) {
                                Color.clear.frame(height: max(0, top - frame.minY - 40))
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 80)
                                Color.black
                            }
                        }
                        .offset(x: frame.minX, y: frame.minY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.blurTop == nil)
            // Measured and laid out inside `ignoresSafeArea`, so against the whole region. (Outside it, the
            // view still reports the safe area's frame.)
            .onGeometryChange(for: PlayerScreen.Shape.self) { proxy in
                PlayerScreen.Shape(size: proxy.size, corners: proxy.containerCornerInsets)
            } action: { videoScreen.update($0) }
            .ignoresSafeArea()
    }

    /// Where the picture is on the screen: all of it when zoomed to fill, otherwise as big as it fits.
    private var pictureFrame: CGRect {
        if model.fillsScreen { return CGRect(origin: .zero, size: videoScreen.size) }
        // Folded, the picture has a half to itself with nothing in it to keep clear of: no safe area applies.
        return isFolded
            ? videoScreen.unobstructedPictureFrame(aspectRatio: aspectRatio)
            : videoScreen.pictureFrame(aspectRatio: aspectRatio)
    }

    /// The picture's width over its height; widescreen until the stream reports its size.
    private var aspectRatio: CGFloat {
        let size = model.videoSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }
}
#endif

#Preview {
    PlayerView(item: .previewPartlyWatched)
        .environment(AppModel.preview())
}
