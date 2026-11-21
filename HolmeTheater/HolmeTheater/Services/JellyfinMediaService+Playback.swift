// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JellyfinAPI

// Playback: asking the server how to play an item, reporting progress, and the user's watch state.

extension JellyfinMediaService {
    // MARK: - Playback info

    func playbackInfo(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackInfo {
        let (client, session) = try signedIn()

        // Describe what this device can play (`deviceProfile`) and let the server pick the cheapest
        // way to deliver it: direct play, then remux, then transcode. A bitrate cap below the file's own
        // rules out the first two, and the server scales the picture down to fit.
        let body = PlaybackInfoDto(
            audioStreamIndex: options.audioIndex,
            deviceProfile: Self.deviceProfile,
            // Direct play must stay on: with it off, the server doesn't remux a file AVPlayer can already play, but
            // re-encodes its video, and a 4K re-encode can't keep up with playback, so the buffer drains and the
            // picture freezes. (The player waiting to minimise stalling, set in `PlaybackSession`, is what keeps a
            // direct-play file from freezing the picture while the audio carries on.)
            // Off only for a file this device has been found unable to show a picture from as it is (see
            // `DirectPlayFailures`), which the server then remuxes or converts instead.
            enableDirectPlay: options.allowsDirectPlay && !DirectPlayFailures.contains(item),
            enableDirectStream: true,
            enableTranscoding: true,
            maxStreamingBitrate: options.maxBitrate ?? Self.deviceProfile.maxStreamingBitrate,
            mediaSourceID: options.mediaSourceID,
            subtitleStreamIndex: options.subtitleIndex,
            userID: session.userID
        )
        let response = try await send(Paths.getPostedPlaybackInfo(itemID: item.id, parameters: nil, body), with: client)

        guard let source = response.mediaSources?.first, let sourceID = source.id else {
            throw MediaServiceError.itemNotPlayable
        }

        let method: PlaybackMethod
        let streamURL: URL?
        if source.isSupportsDirectPlay == true {
            // Static stream of the original file.
            method = .directPlay
            streamURL = Self.serverURL(client, path: ["Videos", item.id, "stream"], query: [
                "static": "true",
                "mediaSourceId": sourceID,
                "deviceId": identity.deviceID,
                "tag": source.eTag
            ])
        } else if let transcodingURL = source.transcodingURL {
            // The server hands back a ready-made HLS URL (remux or transcode). The SDK puts its path on the server's
            // address, whatever host it names.
            method = source.isSupportsDirectStream == true ? .directStream : .transcode
            streamURL = client.url(path: transcodingURL)
        } else {
            throw MediaServiceError.itemNotPlayable
        }

        guard let url = streamURL else { throw MediaServiceError.itemNotPlayable }

        let streams = source.mediaStreams ?? []
        func tracks(of type: MediaStreamType) -> [MediaTrack] {
            streams.compactMap { stream in
                guard stream.type == type, let index = stream.index else { return nil }
                let title = stream.displayTitle ?? stream.title ?? stream.language ?? String(localized: "Track \(index)")
                let subtitle = type == .subtitle ? Self.subtitleSource(for: stream, index: index, itemID: item.id, sourceID: sourceID, client: client) : nil
                return MediaTrack(index: index, title: title, isExternal: stream.isExternal == true, url: subtitle?.url,
                                  format: subtitle?.format, isForced: type == .subtitle ? stream.isForced : nil)
            }
        }

        // The server echoes the tracks it picked as the source's defaults; -1 means none.
        let audioIndex = options.audioIndex ?? source.defaultAudioStreamIndex
        let subtitleIndex = (options.subtitleIndex ?? source.defaultSubtitleStreamIndex)
            .flatMap { $0 == PlaybackOptions.noSubtitles ? nil : $0 }
        let subtitleStream = streams.first { $0.type == .subtitle && $0.index == subtitleIndex }

        return PlaybackInfo(
            url: url.addingAccessToken(client.accessToken),
            resumePosition: (item.playedFraction ?? 0) * (item.runtime ?? 0),
            playSessionID: response.playSessionID,
            mediaSourceID: sourceID,
            method: method,
            audioTracks: tracks(of: .audio),
            subtitleTracks: tracks(of: .subtitle),
            audioIndex: audioIndex,
            subtitleIndex: subtitleIndex,
            subtitlesBurnedIn: subtitleStream?.deliveryMethod == .encode,
            sourceBitrate: source.bitrate,
            sourceHeight: streams.first { $0.type == .video }?.height,
            maxBitrate: options.maxBitrate,
            expectedBytes: source.size.map { Int64($0) }
        )
    }

    /// Where the app fetches a subtitle track from, and in what format, for the tracks it draws itself. Nil for one only
    /// the server can draw (by burning it into the picture).
    ///
    /// Text subtitles are fetched as WebVTT and drawn by the app (see `SubtitleOverlay`): the player's own HLS subtitles
    /// drift out of step with the speech. PGS pictures are fetched as they are, which the server (10.9 and later) only
    /// offers for a track it's sending separately; an older one burns them in. SubStation Alpha is fetched as it is too
    /// (as the web client does), since its WebVTT leaves out the picture size its positions are measured on and the
    /// alignment its styles give.
    ///
    /// No token in the URL: the app fetches these itself, with it in a header (see `authorizedRequest(for:)`).
    private static func subtitleSource(
        for stream: MediaStream, index: Int, itemID: String, sourceID: String, client: JellyfinClient
    ) -> (url: URL?, format: SubtitleFormat)? {
        func subtitleStream(_ fileName: String) -> URL? {
            serverURL(client, path: ["Videos", itemID, sourceID, "Subtitles", String(index), "0", fileName])
        }
        let codec = stream.codec?.lowercased()
        if stream.isTextSubtitleStream == true, let codec, codec == "ass" || codec == "ssa" {
            return (subtitleStream("Stream.\(codec)"), .ass)
        }
        if stream.isTextSubtitleStream == true {
            return (subtitleStream("Stream.vtt"), .webVTT)
        }
        if codec == "pgssub", stream.deliveryMethod == .external {
            return (stream.deliveryURL.flatMap { client.url(path: $0) } ?? subtitleStream("Stream.pgssub"), .pgs)
        }
        return nil
    }

    func downloadInfo(for item: MediaItem) async throws -> PlaybackInfo {
        var info = try await playbackInfo(for: item, options: PlaybackOptions())
        // A download is fetched by the app's own session, which sends the token in a header (see
        // `authorizedRequest(for:)`), so it stays out of the URL and the server's logs.
        info.url = info.url.removingAccessToken()
        // The original file, as it is on the server.
        if info.method == .directPlay { return info }

        // A file this device can't play as it is (an MKV, say) has no plain URL, only an HLS playlist, which
        // URLSession can't save as one file. Ask for the same thing as a progressive MP4 instead.
        let (client, _) = try signedIn()
        guard let sourceID = info.mediaSourceID else { throw MediaServiceError.itemNotPlayable }
        guard let url = Self.serverURL(client, path: ["Videos", item.id, "stream.mp4"], query: [
            "mediaSourceId": sourceID,
            "deviceId": identity.deviceID,
            "videoCodec": "h264",
            "audioCodec": "aac",
            "maxAudioChannels": "6",
            "audioStreamIndex": info.audioIndex.map(String.init)
        ]) else { throw MediaServiceError.itemNotPlayable }

        var result = info
        result.url = url
        result.expectedBytes = Self.estimatedConvertedSize(runtime: item.runtime, sourceBitrate: info.sourceBitrate)
        // Subtitles come as separate files, so none are drawn into the picture.
        result.subtitlesBurnedIn = false
        return result
    }

    /// A ceiling on how big a file the server converts as it sends will be: its length at the original's bitrate, which
    /// the conversion usually stays under. Enough to show roughly how far along a download is. Nil if either is unknown.
    static func estimatedConvertedSize(runtime: TimeInterval?, sourceBitrate: Int?) -> Int64? {
        guard let runtime, let sourceBitrate else { return nil }
        return Int64(runtime * Double(sourceBitrate) / 8)
    }

    func segments(for item: MediaItem) async -> [MediaSegment] {
        guard let client, let result = try? await send(Paths.getItemSegments(itemID: item.id), with: client) else { return [] }
        return (result.items ?? []).compactMap { segment in
            guard let start = segment.startTicks, let end = segment.endTicks, end > start else { return nil }
            let kind: MediaSegment.Kind = switch segment.type {
            case .intro: .intro
            case .outro: .outro
            case .recap: .recap
            case .preview: .preview
            case .commercial: .commercial
            case .unknown, nil: .unknown
            }
            return MediaSegment(kind: kind, start: Double(start) / Self.ticksPerSecond, end: Double(end) / Self.ticksPerSecond)
        }
        .sorted { $0.start < $1.start }
    }

    // MARK: - Progress reports

    func report(_ event: PlaybackEvent, for item: MediaItem, info: PlaybackInfo, position: TimeInterval, isPaused: Bool) async {
        // Each playback reports with the client it started with, so its token and user stay the same throughout: a stop
        // reported after sign-out still goes out (before the token is revoked), and one reported after switching accounts
        // never lands on the new account.
        let key = Self.reportKey(item: item, info: info)
        let client: JellyfinClient
        switch event {
        case .started:
            guard let current = self.client, session != nil else { return }
            reportingClients[key] = current
            client = current
        case .progress:
            guard let started = reportingClients[key] else { return }
            client = started
        case .stopped:
            guard let started = reportingClients.removeValue(forKey: key) else { return }
            client = started
        }
        let ticks = Int(position * Self.ticksPerSecond)

        // Progress reporting is best-effort; a failed report shouldn't interrupt playback.
        switch event {
        case .started, .progress:
            let state = PlaybackStateInfo(
                canSeek: true,
                isPaused: isPaused,
                itemID: item.id,
                mediaSourceID: info.mediaSourceID,
                playMethod: Self.playMethod(for: info.method),
                playSessionID: info.playSessionID,
                positionTicks: ticks
            )
            let request = event == .started ? Paths.reportPlaybackStart(state) : Paths.reportPlaybackProgress(state)
            _ = try? await client.send(request)
        case .stopped:
            let stop = PlaybackStopInfo(
                itemID: item.id,
                mediaSourceID: info.mediaSourceID,
                playSessionID: info.playSessionID,
                positionTicks: ticks
            )
            stopsInFlight += 1
            _ = try? await client.send(Paths.reportPlaybackStopped(stop))
            stopsInFlight -= 1
        }
    }

    /// Identifies one playback among those reporting: the server's play session, or the item if it gave none.
    private static func reportKey(item: MediaItem, info: PlaybackInfo) -> String {
        info.playSessionID ?? item.id
    }

    /// Waits, up to `timeout`, for playback started with `token` to report its stop. Sign-out stops the player just
    /// before it signs out, and the stop report would fail if the token were revoked first.
    func waitForStopReports(using token: String?, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline,
              stopsInFlight > 0 || reportingClients.values.contains(where: { $0.accessToken == token }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Whatever never reported its stop won't be able to once the token is revoked.
        reportingClients = reportingClients.filter { $0.value.accessToken != token }
    }

    private static func playMethod(for method: PlaybackMethod) -> PlayMethod {
        switch method {
        case .directPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcode
        }
    }

    // MARK: - Watch state

    // The server applies a series' or season's watched state to every episode in it, so one call covers it all.

    func markWatched(itemID: String) async throws {
        let (client, session) = try signedIn()
        _ = try await send(Paths.markPlayedItem(itemID: itemID, userID: session.userID), with: client)
    }

    func markUnwatched(itemID: String) async throws {
        let (client, session) = try signedIn()
        _ = try await send(Paths.markUnplayedItem(itemID: itemID, userID: session.userID), with: client)
    }

    func removeFromContinueWatching(_ item: MediaItem) async throws {
        let (client, session) = try signedIn()
        // The resume list is every item with a saved position, so zeroing it is what removes the item.
        let request = Paths.updateItemUserData(
            itemID: item.id,
            userID: session.userID,
            UpdateUserItemDataDto(playbackPositionTicks: 0)
        )
        _ = try await send(request, with: client)
    }

    func syncProgress(itemID: String, position: TimeInterval, isPlayed: Bool, date: Date) async throws {
        let (client, session) = try signedIn()

        // Another device may have watched it since; the later watch wins.
        let current = try await send(Paths.getItem(itemID: itemID, userID: session.userID), with: client)
        if let serverDate = current.userData?.lastPlayedDate, serverDate > date { return }

        let data = UpdateUserItemDataDto(
            isPlayed: isPlayed,
            lastPlayedDate: date,
            playCount: isPlayed ? max(1, current.userData?.playCount ?? 0) : nil,
            playbackPositionTicks: isPlayed ? 0 : Int(position * Self.ticksPerSecond)
        )
        _ = try await send(Paths.updateItemUserData(itemID: itemID, userID: session.userID, data), with: client)
    }

    // MARK: - Device profile

    /// Tells the server what AVPlayer can play natively so it only transcodes when it has to.
    static let deviceProfile = DeviceProfile(
        directPlayProfiles: [
            DirectPlayProfile(
                audioCodec: "aac,ac3,eac3,mp3,alac,flac",
                container: "mp4,m4v,mov",
                type: .video,
                videoCodec: "h264,hevc"
            )
        ],
        maxStreamingBitrate: 120_000_000,
        name: "Native AVPlayer",
        // Without these the server assumes we can't show subtitles itself and burns them into the video.
        // Text subtitles are delivered separately, and the app draws them from the player's clock, the way the
        // web client does. Inside the HLS stream they drift out of step with the speech.
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: .external),
            SubtitleProfile(format: "webvtt", method: .external),
            SubtitleProfile(format: "srt", method: .external),
            SubtitleProfile(format: "subrip", method: .external),
            SubtitleProfile(format: "ass", method: .external),
            SubtitleProfile(format: "ssa", method: .external),
            SubtitleProfile(format: "mov_text", method: .external),
            // Pictures, which the server can't make text of. Burning them in instead means re-encoding the video, which
            // is slow to start and leaves the app nothing to adjust the timing of. The app draws them (see `PGS`).
            SubtitleProfile(format: "pgssub", method: .external)
        ],
        transcodingProfiles: [
            TranscodingProfile(
                protocol: .hls,
                audioCodec: "aac,ac3,eac3",
                container: "mp4",
                context: .streaming,
                maxAudioChannels: "6",
                minSegments: 2,
                type: .video,
                videoCodec: "h264,hevc"
            )
        ]
    )
}
