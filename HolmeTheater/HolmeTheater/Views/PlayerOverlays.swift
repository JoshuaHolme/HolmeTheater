// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

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
#endif
