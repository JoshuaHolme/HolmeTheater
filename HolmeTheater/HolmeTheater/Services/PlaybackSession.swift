// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

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
        // A downloaded file is only ever the quality it was saved in.
        if info.url.isFileURL { return [] }
        return all.filter { quality in
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

    /// Whether the next episode is off the table: the viewer cancelled its automatic start for this episode, or turned
    /// autoplay off altogether (see ``PlaybackSettings``). Everything that offers or starts the next episode goes by this, so
    /// the setting turns off the "Up Next" card with it. Setting it only cancels it for this episode.
    var autoPlayCancelled: Bool {
        get { cancelledForThisEpisode || !settings.autoPlaysNext }
        set { cancelledForThisEpisode = newValue }
    }
    private var cancelledForThisEpisode = false

    /// Whether the next episode starts by itself, as set on the Account screen or from the player's controls.
    var autoPlaysNext: Bool {
        get { settings.autoPlaysNext }
        set { settings.autoPlaysNext = newValue }
    }

    /// The setting behind ``autoPlaysNext``, shared with the rest of the app.
    @ObservationIgnored private let settings: PlaybackSettings

    /// The intro, credits and so on the server has marked, which the player offers to skip.
    private(set) var segments: [MediaSegment] = []

    /// Whether the player's controls are showing. Kept here so a rebuilt player view picks up where the last left off.
    @ObservationIgnored var controlsAreShowing = true

    /// The lines of the subtitle track on screen, drawn by the app. Empty for none, or while they load.
    private(set) var subtitleCues: [SubtitleCue] = []
    /// The same for a track of pictures (PGS).
    private(set) var pictureCues: [PictureSubtitleCue] = []
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    /// The picture last drawn, by its index in ``pictureCues``, so it's decoded once rather than on every frame.
    @ObservationIgnored private var shownPicture: (index: Int, picture: PictureSubtitle?)?

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

    /// The skip markers' and next episode's lookups, started with playback.
    @ObservationIgnored private var lookups: [Task<Void, Never>] = []

    /// The "started" report, once sent. "Stopped" waits for it, so the server never sees them out of order
    /// (which would leave a phantom "now playing" session on the server).
    @ObservationIgnored private var startReport: Task<Void, Never>?

    /// How many player views are showing this session. See ``viewerDisappeared()``.
    @ObservationIgnored private var viewers = 0

    #if os(iOS)
    /// Keeps the screen from locking while the video plays, as the system player does.
    @ObservationIgnored private var keepAwake: NSKeyValueObservation?
    #endif

    /// Where playback goes next when it's part of a list, such as a playlist, rather than one show's episodes.
    struct Queue {
        /// What plays after this item, or nil if it's the last.
        let next: MediaItem?
    }

    /// The list this playback is part of, or nil if it's on its own and followed by its show's next episode.
    @ObservationIgnored private let queue: Queue?

    /// - Parameters:
    ///   - settings: How playback behaves. The default is one for previews, which doesn't touch the real settings.
    ///   - queue: The list this is playing from, which decides what follows it.
    init(
        item: MediaItem,
        info: PlaybackInfo,
        service: any MediaService,
        settings: PlaybackSettings = PlaybackSettings(defaults: UserDefaults(suiteName: "PlaybackSettingsPreviews") ?? .standard),
        queue: Queue? = nil
    ) {
        self.queue = queue
        self.item = item
        self.info = info
        self.service = service
        self.settings = settings
        self.audioIndex = info.audioIndex
        self.subtitleIndex = info.subtitleIndex
        self.subtitleOffset = settings.subtitleOffset(for: item.id)
        self.player = AVPlayer(playerItem: Self.makePlayerItem(for: item, info: info))
        // Waiting lets the player hold back to build a buffer and carry on by itself after a stall. Without it, a
        // dip in the network pauses a direct-play file for good (4K files at high bitrates stall often on Wi-Fi).
        player.automaticallyWaitsToMinimizeStalling = true

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
        // Buffer well ahead so a dip in the network doesn't run the buffer dry. (The default is a few seconds.) This
        // is only a hint: the system still caps it by memory, and a transcode can only be buffered as far as the
        // server has produced.
        playerItem.preferredForwardBufferDuration = 300
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = item.title as NSString
        title.extendedLanguageTag = "und"
        var metadata = [title]
        #if os(tvOS)
        // What the Apple TV player's title view and Info panel show.
        func add(_ identifier: AVMetadataIdentifier, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            let entry = AVMutableMetadataItem()
            entry.identifier = identifier
            entry.value = text as NSString
            entry.extendedLanguageTag = "und"
            metadata.append(entry)
        }
        add(.iTunesMetadataTrackSubTitle, item.subtitle)
        add(.commonIdentifierDescription, item.overview)
        add(.quickTimeMetadataGenre, item.genres.first)
        #endif
        playerItem.externalMetadata = metadata
        return playerItem
    }

    /// Moves the subtitles later (or, if negative, earlier) by `seconds`, and remembers it for this item.
    func adjustSubtitleOffset(by seconds: TimeInterval) {
        setSubtitleOffset(subtitleOffset + seconds)
    }

    func resetSubtitleOffset() { setSubtitleOffset(0) }

    func setSubtitleOffset(_ offset: TimeInterval) {
        subtitleOffset = (offset * 100).rounded() / 100
        settings.setSubtitleOffset(subtitleOffset, for: item.id)
    }

    /// The episode after this one: the next in its season, else the first of the next season that has any.
    private func findNextEpisode() async -> MediaItem? {
        // In a list, what follows is the next entry, whatever it is, not the next episode of this one's show.
        if let queue { return queue.next }
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

    /// Sets what a preview shows, which has no server to ask. Not wrapped in `#if DEBUG` because
    /// `#Preview` bodies are compiled in Release builds too.
    func setPreview(nextEpisode: MediaItem?, segments: [MediaSegment]) {
        self.nextEpisode = nextEpisode
        self.segments = segments
    }

    /// The marked stretch `time` is in, if any.
    func segment(at time: TimeInterval) -> MediaSegment? {
        segments.first { $0.start <= time && time < $0.end }
    }

    /// The subtitle to show along the bottom at `time`, if any.
    func subtitleText(at time: TimeInterval) -> String? {
        Self.text(of: Self.cues(in: subtitleCues, at: time - subtitleOffset).filter { $0.placement == nil })
    }

    /// The lines at `time` the track puts somewhere other than along the bottom.
    func placedSubtitles(at time: TimeInterval) -> [SubtitleCue] {
        var seen = Set<SubtitleCue>()
        // A file may draw a line twice in one place, for an outline say, and it's shown once.
        return Self.cues(in: subtitleCues, at: time - subtitleOffset).filter {
            $0.placement != nil && seen.insert(SubtitleCue(start: 0, end: 0, text: $0.text, placement: $0.placement)).inserted
        }
    }

    /// The subtitle picture to show at `time`, if any, for a track of pictures.
    func subtitlePicture(at time: TimeInterval) -> PictureSubtitle? {
        Self.picture(in: pictureCues, at: time - subtitleOffset, shown: &shownPicture)
    }

    /// The picture showing at `shifted` among `cues`, decoded only if it isn't the one in `shown` already.
    private static func picture(
        in cues: [PictureSubtitleCue], at shifted: TimeInterval, shown: inout (index: Int, picture: PictureSubtitle?)?
    ) -> PictureSubtitle? {
        guard let index = cues.index(at: shifted) else { return nil }
        if let shown, shown.index == index { return shown.picture }
        let picture = cues[index].image()
        shown = (index, picture)
        return picture
    }

    private static func cues(in cues: [SubtitleCue], at shifted: TimeInterval) -> [SubtitleCue] {
        cues.filter { $0.start <= shifted && shifted < $0.end }
    }

    /// The lines one under the other, each once.
    private static func text(of cues: [SubtitleCue]) -> String? {
        var seen = Set<String>()
        let lines = cues.map(\.text).filter { seen.insert($0).inserted }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The lines of a track kept ready for an instant replay: a few seconds of subtitles after going back, while the
    /// viewer has none on. Empty until fetched, or if the file has no track the app can draw.
    @ObservationIgnored private var replayCues: [SubtitleCue] = []
    /// The same for a track of pictures, and the one last drawn.
    @ObservationIgnored private var replayPictureCues: [PictureSubtitleCue] = []
    @ObservationIgnored private var shownReplayPicture: (index: Int, picture: PictureSubtitle?)?
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private var didRequestReplayCues = false

    /// The track an instant replay shows: one the app can draw, in the language being spoken if that can be told from the
    /// audio track's name, else the first. Text rather than pictures where a language has both, as it's quicker to fetch;
    /// but pictures where they're all there is, as on most Blu-ray rips.
    private var replayTrack: MediaTrack? {
        guard !info.subtitlesBurnedIn else { return nil }
        // Not a forced one: it's the very track that lacks the lines a replay is for.
        let drawable = info.subtitleTracks.filter { $0.url != nil && !$0.looksForced }
        let tracks = drawable.filter { $0.format != .pgs } + drawable.filter { $0.format == .pgs }
        if let language = info.audioTracks.first(where: { $0.index == audioIndex })?.title.components(separatedBy: " - ").first,
           let match = tracks.first(where: { $0.title.hasPrefix(language) }) {
            return match
        }
        return tracks.first
    }

    /// Whether an instant replay should show its own subtitles: when the viewer has none on, or only a forced track,
    /// which leaves out most of what's said. A full track they chose is left to show itself.
    var allowsReplaySubtitles: Bool {
        guard let subtitleIndex else { return true }
        return info.subtitleTracks.first { $0.index == subtitleIndex }?.looksForced == true
    }

    /// Fetches the lines for an instant replay, once, unless full subtitles are on already.
    func loadReplayCues() {
        guard allowsReplaySubtitles, !didRequestReplayCues, let track = replayTrack, let url = track.url else { return }
        didRequestReplayCues = true
        replayTask = Task {
            guard let data = await subtitleData(from: url), !Task.isCancelled else { return }
            if track.format == .pgs {
                let cues = await PGS.parse(data)
                guard !Task.isCancelled else { return }
                replayPictureCues = cues
            } else {
                let cues = await self.textCues(data, from: url, format: track.format)
                guard !Task.isCancelled else { return }
                replayCues = cues
            }
        }
    }

    /// The instant replay's subtitle at `time`, if any: every line, along the bottom, as it's only there to catch what
    /// was said.
    func replaySubtitleText(at time: TimeInterval) -> String? {
        Self.text(of: Self.cues(in: replayCues, at: time - subtitleOffset))
    }

    /// The instant replay's subtitle picture at `time`, if any, for a track of pictures.
    func replaySubtitlePicture(at time: TimeInterval) -> PictureSubtitle? {
        Self.picture(in: replayPictureCues, at: time - subtitleOffset, shown: &shownReplayPicture)
    }

    /// The lines of a text track, fetched from `url` as `data`. One fetched as SubStation Alpha that comes to nothing
    /// falls back to the server's WebVTT of it, which is how every text track was fetched before, so none stops showing.
    private func textCues(_ data: Data, from url: URL, format: SubtitleFormat?) async -> [SubtitleCue] {
        let cues = await Self.parseText(data, format: format)
        guard cues.isEmpty, format == .ass, !url.isFileURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return cues }
        components.path = (components.path as NSString).deletingLastPathComponent + "/Stream.vtt"
        guard let fallback = components.url,
              let data = await Self.fetchSubtitles(service.authorizedRequest(for: fallback)) else { return [] }
        return await Self.parseText(data, format: .webVTT)
    }

    /// The lines of a text subtitle file. Away from the main actor, as a file with a lot of typesetting can be big.
    @concurrent private static func parseText(_ data: Data, format: SubtitleFormat?) async -> [SubtitleCue] {
        let source = String(decoding: data, as: UTF8.self)
        return format == .ass ? SubStationAlpha.parse(source) : WebVTT.parse(source)
    }

    /// The subtitle files fetched, or being fetched, by URL: the main track and an instant replay's share them, and so
    /// does a track picked again. The first time a picture track (PGS) is asked for, the server reads through the whole
    /// video to take it out, which can take minutes, and a second request or a cancelled one would have it start over.
    @ObservationIgnored private var subtitleFetches: [URL: Task<Data?, Never>] = [:]

    /// The file at `url`, from the one request made for it. Not cancelled with the caller, so the server finishes taking
    /// the track out even if the viewer turns it off in the meantime; a failed one is asked for again next time.
    private func subtitleData(from url: URL) async -> Data? {
        let fetch = subtitleFetches[url] ?? {
            let service = service
            let fetch = Task { await Self.fetchSubtitles(service.authorizedRequest(for: url)) }
            subtitleFetches[url] = fetch
            return fetch
        }()
        let data = await fetch.value
        if data == nil, subtitleFetches[url] == fetch { subtitleFetches[url] = nil }
        return data
    }

    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "Subtitles")

    /// Fetches a subtitle file, logging a failure by path only. Nil if it failed.
    @concurrent private static func fetchSubtitles(_ request: URLRequest) async -> Data? {
        let path = request.url.map { $0.isFileURL ? $0.lastPathComponent : $0.path() } ?? "?"
        let start = ContinuousClock.now
        do {
            let (data, response) = try await subtitleSession.data(for: request)
            let elapsed = ContinuousClock.now - start
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                logger.error("Subtitles \(path, privacy: .public) failed with status \(status) after \(elapsed)")
                return nil
            }
            return data
        } catch {
            logger.error("Subtitles \(path, privacy: .public) failed after \(ContinuousClock.now - start): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fetches subtitle files. Ephemeral, so nothing fetched with the access token is cached on disk.
    nonisolated private static let subtitleSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The server reads through the whole video to take a track out of it the first time it's asked for, which can
        // take longer than the usual minute for a big file.
        configuration.timeoutIntervalForRequest = 300
        return URLSession(configuration: configuration)
    }()

    /// Fetches the lines of the selected subtitle track, or clears them if there's nothing for the app to draw.
    private func loadSubtitleCues() {
        cueTask?.cancel()
        subtitleCues = []
        pictureCues = []
        shownPicture = nil
        // The tracks may have changed too, so the replay's are fetched again when they're next wanted.
        replayTask?.cancel()
        replayCues = []
        replayPictureCues = []
        shownReplayPicture = nil
        didRequestReplayCues = false
        guard !info.subtitlesBurnedIn, let subtitleIndex,
              let track = info.subtitleTracks.first(where: { $0.index == subtitleIndex }), let url = track.url else { return }
        cueTask = Task {
            guard let data = await subtitleData(from: url), !Task.isCancelled else { return }
            if track.format == .pgs {
                let cues = await PGS.parse(data)
                guard !Task.isCancelled else { return }
                pictureCues = cues
            } else {
                let cues = await self.textCues(data, from: url, format: track.format)
                guard !Task.isCancelled else { return }
                subtitleCues = cues
            }
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
        // Active, so the volume slider hears about changes made with the hardware buttons. Asynchronously, as
        // activating can block the calling thread for a noticeable time.
        if #available(iOS 27.0, tvOS 27.0, *) {
            AVAudioSession.sharedInstance().activate { _, _ in }
        } else {
            Task.detached { try? AVAudioSession.sharedInstance().setActive(true) }
        }
        #endif

        if info.resumePosition > 1 {
            await player.seek(to: CMTime(seconds: info.resumePosition, preferredTimescale: 600))
        }
        // Closed while seeking: don't start playing with nothing on screen.
        guard !isStopped else { return }
        player.play()
        await applyTrackSelection()
        // Closed while the tracks were being chosen: `stop()` has already run and found nothing to cancel, so
        // starting the reports now would leave them running with no one to stop them.
        guard !isStopped else { return }
        loadSubtitleCues()

        // Kept, so closing the player stops them asking the server for what it no longer needs.
        lookups = [
            Task { segments = await service.segments(for: item) },
            Task { nextEpisode = await findNextEpisode() },
            Task { await fallBackIfNoPicture() }
        ]

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

    /// Whether the server may send the file as it is. Turned off once a direct-played file turns out not to show a picture,
    /// and kept off for any stream asked for after, so a change of quality or track doesn't bring the black screen back.
    @ObservationIgnored private var allowsDirectPlay = true

    /// How many half seconds a ready player may go without a picture before it's given up on: long enough for a working
    /// file's picture to appear, which it does as soon as the player is ready.
    private static let pictureGraceTicks = 4

    /// Direct play can leave a black screen. A file the device can't decode (HEVC tagged `hev1` rather than `hvc1`, say)
    /// plays its sound and keeps time with nothing on screen, and the player reports no error, only a picture size of zero.
    /// So when the player is ready, the file has video, and no picture has shown within a moment, or the file fails outright,
    /// this asks the server for a stream the device can show instead, carrying on from the same point. Whatever the file's
    /// library, it only acts on what the player itself can't show.
    private func fallBackIfNoPicture() async {
        guard info.method == .directPlay, !info.url.isFileURL, let playerItem = player.currentItem else { return }
        // Sound only is no failure.
        guard let video = try? await playerItem.asset.loadTracks(withMediaType: .video), !video.isEmpty else { return }

        var readyTicks = 0
        // Up to half a minute, for a slow connection to get the player ready.
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            // Closed, or moved on to another stream by a change of quality or track, which asks for its own.
            guard !Task.isCancelled, !isStopped, player.currentItem === playerItem else { return }
            switch playerItem.status {
            case .readyToPlay:
                // A picture that's showing has a size.
                if playerItem.presentationSize != .zero { return }
                readyTicks += 1
                guard readyTicks >= Self.pictureGraceTicks else { continue }
            case .failed:
                break
            default:
                continue
            }
            allowsDirectPlay = false
            DirectPlayFailures.record(item)
            await switchStream { $0.allowsDirectPlay = false }
            return
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
        for lookup in lookups { lookup.cancel() }
        cueTask?.cancel()
        replayTask?.cancel()
        #if os(iOS)
        keepAwake = nil
        UIApplication.shared.isIdleTimerDisabled = false
        #endif

        let (service, item, info, position) = (service, item, info, position)
        player.pause()
        // Drop the item so AVPlayer closes its network connection now rather than when it's deallocated.
        player.replaceCurrentItem(with: nil)
        #if os(iOS) || os(tvOS)
        // Let whatever was playing before (music, a podcast) carry on.
        if #available(iOS 27.0, tvOS 27.0, *) {
            AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
        } else {
            Task.detached { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
        #endif

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
        #if os(tvOS)
        // The window never changes shape here, so there's no rebuild to wait out: stop at once, or the sound carries on
        // for a moment after the player has gone.
        if viewers == 0 { stop(then: onStop) }
        #else
        Task {
            try? await Task.sleep(for: .seconds(1))
            if viewers == 0 { stop(then: onStop) }
        }
        #endif
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
        // A downloaded file can't be asked to come in another form.
        guard !isStopped, !isSwitching, !info.url.isFileURL else { return }
        var options = PlaybackOptions(
            mediaSourceID: info.mediaSourceID,
            maxBitrate: info.maxBitrate,
            audioIndex: audioIndex,
            subtitleIndex: subtitleIndex ?? PlaybackOptions.noSubtitles,
            allowsDirectPlay: allowsDirectPlay
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

        // Close the old stream on the server (which ends its transcode) before announcing the new one. Queued
        // now, before the waits below, so closing the player during them still ends the old play session:
        // `stop()` reports the new one only after this has gone out.
        let (service, item, previous) = (service, item, startReport)
        startReport = Task {
            await previous?.value
            await service.report(.stopped, for: item, info: oldInfo, position: resumeAt, isPaused: true)
            await service.report(.started, for: item, info: newInfo, position: resumeAt, isPaused: !wasPlaying)
        }

        player.replaceCurrentItem(with: Self.makePlayerItem(for: item, info: newInfo))
        player.automaticallyWaitsToMinimizeStalling = true
        await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        guard !isStopped else { return }
        if wasPlaying { player.play() }
        await applyTrackSelection()
        loadSubtitleCues()
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
