// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import AVFoundation
import MediaPlayer

/// Puts what's playing on the Lock Screen, in Control Center and in other apps' "now playing" cards, and answers their
/// play, pause and skip buttons, so playback can be resumed without the app on screen. The system player does this for
/// itself on tvOS.
///
/// Call `start()` once, `refresh()` when the stream changes, and `stop()` when playback ends.
@MainActor
final class NowPlayingPublisher {
    private let player: AVPlayer
    private let item: MediaItem

    private var observations: [NSKeyValueObservation] = []
    private var timeJumpTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    /// How far the skip buttons jump, in seconds.
    nonisolated private static let skipInterval: TimeInterval = 10

    init(player: AVPlayer, item: MediaItem) {
        self.player = player
        self.item = item
    }

    func start() {
        registerCommands()

        // The system extrapolates the position from the rate, so it's only sent when one of them changes.
        observations = [
            player.observe(\.timeControlStatus) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            player.observe(\.rate) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
        timeJumpTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.timeJumpedNotification) {
                self?.refresh()
            }
        }

        artworkTask = Task { [weak self] in
            guard let url = self?.item.posterURL ?? self?.item.backdropURL,
                  let image = await ImageCache.shared.image(for: url), !Task.isCancelled else { return }
            self?.artwork = Self.makeArtwork(image)
            self?.refresh()
        }
        refresh()
    }

    /// Sends the title, length, position and whether it's playing.
    func refresh() {
        let position = player.currentTime().seconds
        let length = player.currentItem?.duration.seconds ?? 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position.isFinite ? max(0, position) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .paused ? 0.0 : Double(player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let duration = length.isFinite && length > 0 ? length : item.runtime {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // An episode reads as "Pilot" under "How I Met Your Mother".
        if item.kind == .episode, let seriesTitle = item.seriesTitle {
            info[MPMediaItemPropertyArtist] = seriesTitle
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Takes the item off the cards and stops answering their buttons.
    func stop() {
        observations = []
        timeJumpTask?.cancel()
        artworkTask?.cancel()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let player = player

        func add(_ command: MPRemoteCommand, handler: @escaping @Sendable (MPRemoteCommandEvent) -> Void) {
            commandTargets.append((command, Self.addTarget(to: command, handler: handler)))
        }

        add(center.playCommand) { _ in player.play() }
        add(center.pauseCommand) { _ in player.pause() }
        add(center.togglePlayPauseCommand) { _ in
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand) { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Self.seek(player, by: interval)
        }
        add(center.skipBackwardCommand) { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Self.seek(player, by: -interval)
        }
        add(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
        }
    }

    /// Artwork for the card. Nonisolated for the same reason as `addTarget(to:handler:)`: the system asks for the image on a
    /// queue of its own.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Adds `handler` to a command. Nonisolated, because the system calls the closure on a queue of its own, and a closure
    /// made inside a main actor method would be main actor isolated and trap when called there.
    nonisolated private static func addTarget(
        to command: MPRemoteCommand,
        handler: @escaping @Sendable (MPRemoteCommandEvent) -> Void
    ) -> Any {
        command.isEnabled = true
        return command.addTarget { event in
            handler(event)
            return .success
        }
    }

    nonisolated private static func seek(_ player: AVPlayer, by seconds: TimeInterval) {
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
}
#endif
