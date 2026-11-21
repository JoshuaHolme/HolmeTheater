// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog

/// The subtitles the app draws itself for one playback: fetching and reading the track the viewer chose, and the one an
/// instant replay shows, and finding the lines due at a moment. ``PlaybackSession`` decides which tracks those are.
///
/// The player's own HLS subtitles drift out of step with the speech, so these are drawn from the player's clock instead,
/// the way the web client does.
@Observable
final class SubtitleController {
    /// How many seconds later than the file says the subtitles show, for a file whose subtitles don't line up. Negative
    /// shows them earlier.
    var offset: TimeInterval

    /// The lines of the track on screen. Empty for none, or while they load.
    private var lines = SubtitleCueIndex.empty

    /// The same for a track of pictures (PGS). Observable itself, so a view redraws when a picture is ready.
    @ObservationIgnored private let pictures = PictureCueRenderer()

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The lines of a track kept ready for an instant replay: a few seconds of subtitles after going back, while the
    /// viewer has none on. Empty until fetched, or if the file has no track the app can draw. Not observed: the Apple TV
    /// player, the only one with instant replay, asks for them on a timer.
    @ObservationIgnored private var replayLines = SubtitleCueIndex.empty
    @ObservationIgnored private let replayPictures = PictureCueRenderer()
    @ObservationIgnored private var replayTask: Task<Void, Never>?

    /// Whether the replay's track has been asked for since the tracks last changed.
    @ObservationIgnored private(set) var hasRequestedReplay = false

    /// The subtitle files fetched, or being fetched, by URL: the main track and an instant replay's share them, and so
    /// does a track picked again. The first time a picture track (PGS) is asked for, the server reads through the whole
    /// video to take it out, which can take minutes, and a second request or a cancelled one would have it start over.
    @ObservationIgnored private var fetches: [URL: Task<Data?, Never>] = [:]

    @ObservationIgnored private let service: any MediaService

    init(service: any MediaService, offset: TimeInterval = 0) {
        self.service = service
        self.offset = offset
    }

    // MARK: Lines due

    /// The subtitle to show along the bottom at `time`, if any.
    func text(at time: TimeInterval) -> String? {
        Self.text(of: lines.cues(at: time - offset).filter { $0.placement == nil })
    }

    /// The lines at `time` the track puts somewhere other than along the bottom.
    func placed(at time: TimeInterval) -> [SubtitleCue] {
        var seen = Set<SubtitleCue>()
        // A file may draw a line twice in one place, for an outline say, and it's shown once.
        return lines.cues(at: time - offset).filter {
            $0.placement != nil && seen.insert(SubtitleCue(start: 0, end: 0, text: $0.text, placement: $0.placement)).inserted
        }
    }

    /// The subtitle picture to show at `time`, if any, for a track of pictures.
    func picture(at time: TimeInterval) -> PictureSubtitle? {
        pictures.picture(at: time - offset)
    }

    /// The instant replay's subtitle at `time`, if any: every line, along the bottom, as it's only there to catch what
    /// was said.
    func replayText(at time: TimeInterval) -> String? {
        Self.text(of: replayLines.cues(at: time - offset))
    }

    /// The instant replay's subtitle picture at `time`, if any, for a track of pictures.
    func replayPicture(at time: TimeInterval) -> PictureSubtitle? {
        replayPictures.picture(at: time - offset)
    }

    /// The lines one under the other, each once.
    private static func text(of cues: [SubtitleCue]) -> String? {
        var seen = Set<String>()
        let lines = cues.map(\.text).filter { seen.insert($0).inserted }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Loading

    /// Fetches the lines of `track` to show, or clears them with nil. The tracks may have changed too, so the replay's
    /// are fetched again when they're next wanted.
    func show(_ track: MediaTrack?) {
        task?.cancel()
        lines = .empty
        pictures.replace(with: [])
        replayTask?.cancel()
        replayLines = .empty
        replayPictures.replace(with: [])
        hasRequestedReplay = false
        guard let track, let url = track.url else { return }
        task = Task {
            guard let parsed = await parse(track, from: url), !Task.isCancelled else { return }
            switch parsed {
            case .text(let index): lines = index
            case .pictures(let cues): pictures.replace(with: cues)
            }
        }
    }

    /// Fetches the lines for an instant replay from `track`, once until the tracks change.
    func loadReplay(_ track: MediaTrack) {
        guard !hasRequestedReplay, let url = track.url else { return }
        hasRequestedReplay = true
        replayTask = Task {
            guard let parsed = await parse(track, from: url), !Task.isCancelled else { return }
            switch parsed {
            case .text(let index): replayLines = index
            case .pictures(let cues): replayPictures.replace(with: cues)
            }
        }
    }

    /// Stops whatever is still loading.
    func cancel() {
        task?.cancel()
        replayTask?.cancel()
    }

    private enum Parsed {
        case text(SubtitleCueIndex)
        case pictures([PictureSubtitleCue])
    }

    /// The track at `url`, fetched and read. Nil if it couldn't be fetched.
    private func parse(_ track: MediaTrack, from url: URL) async -> Parsed? {
        guard let data = await data(from: url), !Task.isCancelled else { return nil }
        if track.format == .pgs { return .pictures(await PGS.parse(data)) }
        return .text(await textLines(data, from: url, format: track.format))
    }

    /// The lines of a text track, fetched from `url` as `data`. One fetched as SubStation Alpha that comes to nothing
    /// falls back to the server's WebVTT of it, which is how every text track was fetched before, so none stops showing.
    private func textLines(_ data: Data, from url: URL, format: SubtitleFormat?) async -> SubtitleCueIndex {
        let index = await Self.parseText(data, format: format)
        guard index.isEmpty, format == .ass, !url.isFileURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return index }
        components.path = (components.path as NSString).deletingLastPathComponent + "/Stream.vtt"
        guard let fallback = components.url,
              let data = await Self.fetch(service.authorizedRequest(for: fallback)) else { return .empty }
        return await Self.parseText(data, format: .webVTT)
    }

    /// The lines of a text subtitle file, ready to look up. Away from the main actor, as a file with a lot of typesetting
    /// can be big.
    @concurrent private static func parseText(_ data: Data, format: SubtitleFormat?) async -> SubtitleCueIndex {
        let source = String(decoding: data, as: UTF8.self)
        return SubtitleCueIndex(format == .ass ? SubStationAlpha.parse(source) : WebVTT.parse(source))
    }

    /// The file at `url`, from the one request made for it. Not cancelled with the caller, so the server finishes taking
    /// the track out even if the viewer turns it off in the meantime; a failed one is asked for again next time.
    private func data(from url: URL) async -> Data? {
        let fetch = fetches[url] ?? {
            let service = service
            let fetch = Task { await Self.fetch(service.authorizedRequest(for: url)) }
            fetches[url] = fetch
            return fetch
        }()
        let data = await fetch.value
        if data == nil, fetches[url] == fetch { fetches[url] = nil }
        return data
    }

    // MARK: Fetching

    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "Subtitles")

    /// Fetches a subtitle file, logging a failure by path only. Nil if it failed.
    @concurrent private static func fetch(_ request: URLRequest) async -> Data? {
        let path = request.url.map { $0.isFileURL ? $0.lastPathComponent : $0.path() } ?? "?"
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
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

    /// Fetches subtitle files. Ephemeral, so nothing fetched with the access token is cached on disk. Its requests carry
    /// the token in a header, which ``SameOriginAuthorization`` keeps from following a redirect to anywhere else.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The server reads through the whole video to take a track out of it the first time it's asked for, which can
        // take longer than the usual minute for a big file.
        configuration.timeoutIntervalForRequest = 300
        return URLSession(configuration: configuration, delegate: SameOriginAuthorization.shared, delegateQueue: nil)
    }()
}
