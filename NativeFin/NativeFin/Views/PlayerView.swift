// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import SwiftUI

/// Full-screen AVPlayer for one item.
///
/// Shows a small debug readout (play method, status, position) so it's easy to see what the
/// server decided and whether playback is healthy.
struct PlayerView: View {
    let item: MediaItem
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// Created once the server has said how to play the item; nil while loading or after an error.
    @State private var session: PlaybackSession?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                VideoPlayer(player: session.player)
                    .ignoresSafeArea()
                    .overlay(alignment: .topLeading) {
                        Text(session.debugText)
                            .font(.caption.monospaced())
                            .padding(6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                            .padding()
                            .allowsHitTesting(false)
                    }
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
        // tvOS dismisses with the remote's Menu button; iOS needs an explicit close button.
        #if os(iOS)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding()
        }
        #endif
        .task { await load() }
        .onDisappear { session?.stop() }
    }

    /// Asks the server how to play the item, then starts playback.
    private func load() async {
        do {
            let info = try await appModel.service.playbackInfo(for: item)
            // Dismissed while the server was thinking.
            guard !Task.isCancelled else { return }
            let session = PlaybackSession(item: item, info: info, service: appModel.service)
            self.session = session
            await session.start()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// Owns the AVPlayer for one playback and keeps the server informed:
/// started, progress every 10 seconds, stopped.
///
/// Call `start()` once, and `stop()` when the player goes away (calling `stop()` more than once is harmless).
@Observable
final class PlaybackSession {
    let player: AVPlayer

    /// A short status string for the on-screen debug overlay; refreshed every second while playing.
    private(set) var debugText = "Loading…"

    @ObservationIgnored private let item: MediaItem
    @ObservationIgnored private let info: PlaybackInfo
    @ObservationIgnored private let service: any MediaService
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isStopped = false

    init(item: MediaItem, info: PlaybackInfo, service: any MediaService) {
        self.item = item
        self.info = info
        self.service = service
        self.player = AVPlayer(url: info.url)
    }

    /// Current playback position in seconds (0 until the player knows it).
    private var position: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    /// Seeks to the resume position, begins playback, reports "started", and begins periodic progress reports.
    func start() async {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif

        if info.resumePosition > 1 {
            await player.seek(to: CMTime(seconds: info.resumePosition, preferredTimescale: 600))
        }
        player.play()

        hasStarted = true
        await service.report(.started, for: item, info: info, position: position, isPaused: false)

        progressTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshDebugText()
                ticks += 1
                // The loop ticks every second; report to the server every tenth tick.
                if ticks % 10 == 0 {
                    await self.service.report(
                        .progress,
                        for: self.item,
                        info: self.info,
                        position: self.position,
                        isPaused: self.player.timeControlStatus == .paused
                    )
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Pauses playback, stops the progress loop, and reports "stopped" with the final position
    /// (only if playback actually started).
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        progressTask?.cancel()
        player.pause()

        guard hasStarted else { return }
        let (service, item, info, position) = (service, item, info, position)
        // Unstructured so the report still goes out after the view's task is cancelled.
        Task { await service.report(.stopped, for: item, info: info, position: position, isPaused: true) }
    }

    private func refreshDebugText() {
        let method = switch info.method {
        case .directPlay: "Direct Play"
        case .directStream: "Direct Stream"
        case .transcode: "Transcode"
        }
        let status = switch player.currentItem?.status {
        case .readyToPlay: "ready"
        case .failed: "FAILED"
        default: "loading"
        }

        var text = "\(method) · \(status) · \(Int(position))s"
        if let error = player.currentItem?.error {
            text += "\n\(error.localizedDescription)"
        }
        debugText = text
    }
}

#Preview {
    PlayerView(item: .previewPartlyWatched)
        .environment(AppModel.preview())
}
