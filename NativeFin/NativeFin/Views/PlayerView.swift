// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import SwiftUI

/// Full-screen AVPlayer for one item.
///
/// Debug builds show a small readout (play method, status, position) so it's easy to see what the
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
                    #if DEBUG
                    .overlay(alignment: .topLeading) {
                        Text(session.debugText)
                            .font(.caption.monospaced())
                            .padding(6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                            .padding()
                            .allowsHitTesting(false)
                    }
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
            .accessibilityLabel("Close")
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
/// Call `start()` once, and `stop()` when the player goes away. `stop()` may be called at any point,
/// even while `start()` is still running, and more than once.
@Observable
final class PlaybackSession {
    let player: AVPlayer

    /// A short status string for the debug overlay; refreshed every second while playing (debug builds only).
    private(set) var debugText = "Loading…"

    @ObservationIgnored private let item: MediaItem
    @ObservationIgnored private let info: PlaybackInfo
    @ObservationIgnored private let service: any MediaService
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    /// The "started" report, once sent. "Stopped" waits for it, so the server never sees them out of order
    /// (which would leave a phantom "now playing" session on the server).
    @ObservationIgnored private var startReport: Task<Void, Never>?
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
        // Closed while seeking: don't start playing with nothing on screen.
        guard !isStopped else { return }
        player.play()

        let (service, item, info, position) = (service, item, info, position)
        startReport = Task { await service.report(.started, for: item, info: info, position: position, isPaused: false) }

        progressTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                #if DEBUG
                self.refreshDebugText()
                #endif
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

    /// Stops playback and the progress loop, releases the stream, and reports "stopped" with the final
    /// position (only if "started" was reported).
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        progressTask?.cancel()

        let (service, item, info, position) = (service, item, info, position)
        player.pause()
        // Drop the item so AVPlayer closes its network connection now rather than when it's deallocated.
        player.replaceCurrentItem(with: nil)

        guard let startReport else { return }
        // Unstructured so the report still goes out after the view's task is cancelled.
        Task {
            await startReport.value
            await service.report(.stopped, for: item, info: info, position: position, isPaused: true)
        }
    }

    #if DEBUG
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
    #endif
}

#Preview {
    PlayerView(item: .previewPartlyWatched)
        .environment(AppModel.preview())
}
