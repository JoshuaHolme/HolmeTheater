// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(tvOS)
import AVKit
import SwiftUI
import UIKit

/// The line of subtitle text on screen, which the player's coordinator updates as the picture plays.
@MainActor @Observable
final class TVSubtitleModel {
    var text: String?
}

/// Nudges the subtitles earlier or later, with the video still playing behind. Each press is 0.1 s, so the timing can be dialed
/// in over several presses.
struct TVSubtitleTimingPanel: View {
    let session: PlaybackSession
    let done: () -> Void

    var body: some View {
        // A slab across the top of the screen that the picture shows through, like the player's Info panel, rather than a
        // card floating in the middle.
        VStack(spacing: 0) {
            HStack(spacing: 48) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Subtitle Timing")
                        .font(.title3.weight(.semibold))
                    Text(Self.offsetText(session.subtitleOffset))
                        .font(.system(size: 64, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }

                Spacer()

                HStack(spacing: 24) {
                    Button { session.adjustSubtitleOffset(by: -0.1) } label: {
                        Label("Earlier", systemImage: "minus")
                    }
                    .accessibilityLabel("Show Earlier")

                    Button { session.adjustSubtitleOffset(by: 0.1) } label: {
                        Label("Later", systemImage: "plus")
                    }
                    .accessibilityLabel("Show Later")

                    Button("Reset") { session.resetSubtitleOffset() }
                        .disabled(session.subtitleOffset == 0)

                    Button("Done", action: done)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .focusSection()
            }
            .padding(.horizontal, 90)
            .padding(.top, 70)
            .padding(.bottom, 50)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: UnevenRoundedRectangle(bottomLeadingRadius: 48, bottomTrailingRadius: 48))
            .ignoresSafeArea()

            Spacer()
        }
        .animation(.smooth(duration: 0.2), value: session.subtitleOffset)
    }

    /// "+1.5 s", "−0.25 s" or "0 s".
    static func offsetText(_ offset: TimeInterval) -> String {
        let sign = offset > 0 ? "+" : offset < 0 ? "−" : ""
        return "\(sign)\(abs(offset).formatted(.number.precision(.fractionLength(0...1)))) s"
    }
}

/// The subtitles, drawn over the picture. The player's own subtitles are off, because the app follows the position
/// itself (see `PlaybackSession.subtitleText(at:)`), as it does on iOS.
private struct TVSubtitleView: View {
    let model: TVSubtitleModel

    var body: some View {
        Color.clear
            .overlay(alignment: .bottom) {
                if let text = model.text {
                    Text(text)
                        .font(.system(size: 52, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .shadow(color: .black, radius: 6)
                        .padding(.horizontal, 160)
                        // The bottom of the last line sits about 6% of the screen's height up from its bottom edge, the usual
                        // place for subtitles. The safe area would add another 60 points to that.
                        .padding(.bottom, 64)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The people shown in the player's Cast tab. They're fetched after playback starts, since the list rows that
/// usually start playback don't carry them.
@MainActor @Observable
final class TVCastModel {
    var people: [MediaPerson] = []
}

/// A row of the item's cast and crew, in the player's Cast tab. Selecting one opens a sheet about them.
private struct TVCastTab: View {
    let model: TVCastModel
    let service: any MediaService

    /// Closes the player and opens a movie or show a person is credited on.
    let open: (MediaItem) -> Void

    /// The person whose sheet is showing.
    @State private var selected: MediaPerson?

    /// The slab's height, which is also what the tab asks the player's panel for. About the Info tab's.
    static let slabHeight: CGFloat = 248

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 20) {
                ForEach(model.people) { person in
                    Button { selected = person } label: {
                        TVCastCard(person: person)
                    }
                    .buttonStyle(TVCastButtonStyle())
                }
            }
            .padding(.horizontal, 56)
            // The row is only as tall as its tallest card, with the portraits along its top so they line up, and that is
            // centered in the slab.
            .fixedSize(horizontal: false, vertical: true)
            // A fixed height, not one taken from the container: the container's own height comes from this tab's, so when the
            // player brings the tab back a second time it would be sized to nothing.
            .frame(height: Self.slabHeight, alignment: .center)
        }
        .scrollIndicators(.hidden)
        // The row fades out at the slab's ends, rather than being cut off in a straight line across its rounded corners.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 48)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 48)
            }
        }
        // The same slab as the Info tab's, which this tab sits in the place of.
        .glassEffect(.regular, in: .rect(cornerRadius: 56))
        .sheet(item: $selected) { TVPersonSheet(person: $0, service: service, open: open) }
    }
}

/// Hosts the Cast tab, and tells the player's panel how tall it is each time the tab comes on screen. The panel only asked
/// once, so the second time it came up at the wrong height, with the slab halfway up the screen.
private final class TVCastHostingController: UIHostingController<TVCastTab> {
    static var contentSize: CGSize { CGSize(width: 0, height: TVCastTab.slabHeight) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferredContentSize = Self.contentSize
    }
}

/// A person's portrait, name and role, sized to fit the Cast tab's slab.
private struct TVCastCard: View {
    let person: MediaPerson

    var body: some View {
        VStack(spacing: 6) {
            PersonPortrait(person: person, size: 116)

            Text(person.name)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(2)
            if let subtitle = person.subtitle {
                Text(subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: 250)
    }
}

/// Lifts a Cast card's portrait when it has focus, circle and photo together. (The system's highlight effect draws a square
/// plate behind a photo, and a borderless button only enlarges the photo inside its circle.)
private struct TVCastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusLift(configuration: configuration)
    }

    private struct FocusLift: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(.smooth(duration: 0.2), value: isFocused)
        }
    }
}

/// The card offering the next episode as this one ends: its still, number and title, a countdown to starting it, and
/// buttons to play it at once or stay.
private struct TVUpNextCard: View {
    let next: MediaItem
    /// When the system starts the episode by itself, if the viewer does nothing.
    let acceptanceDate: Date?
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                CachedAsyncImage(url: next.thumbnailURL ?? next.backdropURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 200, height: 112)
                .clipShape(.rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Up Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let line = Self.numberLine(for: next) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(next.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Button(action: accept) {
                    Label("Play", systemImage: "play.fill")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.glassProminent)

                Button {
                    reject()
                } label: {
                    Text("Cancel")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.glass)

                Spacer(minLength: 0)

                if let acceptanceDate {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let seconds = max(0, Int(acceptanceDate.timeIntervalSince(context.date).rounded(.up)))
                        Text("Playing in \(seconds)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .font(.callout.weight(.medium))
            .buttonBorderShape(.capsule)
        }
        .padding(24)
        .frame(width: 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
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

/// The Up Next card in the bottom corner of the screen, over a clear background. Presented over the player, which plays on
/// behind it. Menu puts the card away, like Cancel.
private struct TVUpNextOverlay: View {
    let next: MediaItem
    let acceptanceDate: Date
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        TVUpNextCard(next: next, acceptanceDate: acceptanceDate, accept: accept, reject: reject)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(20)
            .onExitCommand(perform: reject)
    }
}

/// What the server knows about a person: their portrait, name and role, when and where they were born, and their
/// biography, then the movies and shows they're credited on. Selecting one of those closes the player and opens it.
private struct TVPersonSheet: View {
    let person: MediaPerson
    let service: any MediaService
    let open: (MediaItem) -> Void

    /// Nil until it arrives, or if it can't be fetched; it's only extra.
    @State private var details: PersonDetails?

    /// What else on the server they're credited on. Empty until it arrives, or if there's nothing.
    @State private var credits: [PersonCredit] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                HStack(alignment: .top, spacing: 60) {
                    PersonPortrait(person: person, size: 280)

                    VStack(alignment: .leading, spacing: 16) {
                        Text(person.name)
                            .font(.largeTitle.bold())
                        if let subtitle = person.subtitle {
                            Text(subtitle)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }

                        if let details {
                            ForEach(Array(PersonDetailView.factLines(for: details).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.callout)
                            }
                            if let biography = details.biography {
                                Text(biography)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                shelf("Movies", credits.filter { $0.item.kind == .movie })
                shelf("Shows", credits.filter { $0.item.kind == .series })
            }
            .padding(80)
        }
        .scrollClipDisabled()
        .task { details = try? await service.details(ofPerson: person.personID) }
        .task { credits = (try? await service.items(featuring: person.personID)) ?? [] }
    }

    /// A row of posters under a heading, or nothing if they're not in any.
    @ViewBuilder
    private func shelf(_ title: LocalizedStringKey, _ credits: [PersonCredit]) -> some View {
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
                Text(title)
                    .font(.title2.bold())

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                        ForEach(credits) { credit in
                            Button { open(credit.item) } label: {
                                PosterCard(item: credit.item)
                                    .cardWidth(Layout.posterWidth)
                            }
                            .cardLinkStyle()
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

/// The system's tvOS player for a playback session, with the app's own additions:
/// - subtitles drawn by the app, over the picture
/// - a Cast tab beside the system's Info tab, where selecting someone opens a sheet about them
/// - Subtitles, Audio, Quality and Subtitle Timing menus in the transport bar
/// - a Skip button while the picture is in an intro, recap or the like the server has marked
/// - an Up Next card for the next episode, over the picture from the credits on
struct TVPlayerController: UIViewControllerRepresentable {
    let session: PlaybackSession

    /// Fetches the full item for its cast.
    let service: any MediaService

    /// Called to move on to the following episode, which the Up Next card or the end of the episode asks for.
    let playNext: (MediaItem) -> Void

    /// Closes the player and opens an item's page, for a movie or show picked from a person's credits.
    let openItem: (MediaItem) -> Void

    /// Closes the player, for Menu pressed on one of the transport bar's buttons.
    let close: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, service: service, playNext: playNext, openItem: openItem, close: close)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = session.player
        controller.delegate = context.coordinator
        // Matches the screen's frame rate and dynamic range to the video's.
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.playNext = playNext
        context.coordinator.openItem = openItem
        context.coordinator.close = close
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        let session: PlaybackSession
        let service: any MediaService
        var playNext: (MediaItem) -> Void
        var openItem: (MediaItem) -> Void
        var close: () -> Void

        private let subtitles = TVSubtitleModel()
        private let cast = TVCastModel()
        private var castTask: Task<Void, Never>?
        private weak var controller: AVPlayerViewController?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var artworkTask: Task<Void, Never>?
        private var upNextTask: Task<Void, Never>?

        /// The marked stretch the Skip button is showing for, if any.
        private var shownSegment: MediaSegment?

        /// What the transport bar's menus were last built from; they're built again when it changes.
        private var menuSignature: MenuSignature?

        /// The Up Next card, while it's on screen, and when it came up.
        private weak var upNextHost: UIViewController?
        private var upNextShownAt: Date?
        private var isShowingUpNext = false

        /// How long the card counts down before it plays the next episode.
        private static let upNextCountdown: TimeInterval = 15

        private struct MenuSignature: Hashable {
            var subtitleIndex: Int?
            var audioIndex: Int?
            var maxBitrate: Int?
            var offset: TimeInterval
            var subtitleCount: Int
            var audioCount: Int
            var isSwitching: Bool
            var autoPlaysNext: Bool
        }

        init(session: PlaybackSession, service: any MediaService, playNext: @escaping (MediaItem) -> Void, openItem: @escaping (MediaItem) -> Void, close: @escaping () -> Void) {
            self.session = session
            self.service = service
            self.playNext = playNext
            self.openItem = openItem
            self.close = close
        }

        isolated deinit {
            if let timeObserver { session.player.removeTimeObserver(timeObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            artworkTask?.cancel()
            upNextTask?.cancel()
            castTask?.cancel()
        }

        func attach(to controller: AVPlayerViewController) {
            self.controller = controller

            // Menu on one of the transport bar's buttons would only move focus back to the progress bar, and take more presses
            // to leave. Close the player at once instead.
            let menuPress = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
            menuPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            menuPress.delegate = self
            controller.view.addGestureRecognizer(menuPress)

            // The app has its own Subtitles menu in the transport bar. Allowing no languages empties the player's own, which
            // would otherwise sit beside it as a second subtitle button.
            controller.allowedSubtitleOptionLanguages = []

            // The subtitles go in the player's overlay, between the picture and its controls.
            if let overlay = controller.contentOverlayView {
                let host = UIHostingController(rootView: TVSubtitleView(model: subtitles))
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = false
                host.view.translatesAutoresizingMaskIntoConstraints = false
                controller.addChild(host)
                overlay.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                    host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
                ])
                host.didMove(toParent: controller)
            }

            timeObserver = session.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time) }
            }

            // Without anyone choosing, the next episode follows when this one ends.
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                let finished = note.object as? AVPlayerItem
                MainActor.assumeIsolated { self?.itemFinished(finished) }
            }

            updateMenus()
            loadArtwork()
            loadCast()
        }

        // MARK: Cast

        /// Fetches the item's people and chapters, which the list rows that usually start playback don't carry, then
        /// adds a Cast tab to the player's panel and the chapters to its own Chapters browser. Each is left out for an
        /// item the server has none of.
        private func loadCast() {
            castTask = Task { [weak self] in
                guard let self else { return }
                var people = self.session.item.people
                var chapters = self.session.item.chapters
                if people.isEmpty || chapters.isEmpty, let full = try? await self.service.item(id: self.session.item.id) {
                    people = full.people
                    chapters = full.chapters
                }
                guard !Task.isCancelled else { return }

                if !people.isEmpty, let controller = self.controller {
                    self.cast.people = people
                    let host = TVCastHostingController(rootView: TVCastTab(
                        model: self.cast,
                        service: self.service,
                        open: { [weak self] item in self?.openItem(item) }
                    ))
                    host.title = String(localized: "Cast")
                    // As tall as the Info tab's slab. The panel is as tall as its tallest tab and keeps each tab at the top, so
                    // a taller one would leave a gap under the Info tab's.
                    host.preferredContentSize = TVCastHostingController.contentSize
                    host.sizingOptions = [.intrinsicContentSize]
                    // The panel takes its height from the tab's own size, which would otherwise include however much of the
                    // screen's safe area the tab overlaps. Measured while the panel is closed and off the bottom of the
                    // screen, that's a lot, and the panel came back that much taller, with the slab halfway up the screen.
                    host.safeAreaRegions = []
                    controller.customInfoViewControllers = [host]
                }

                if !chapters.isEmpty {
                    self.chapterGroup = await Self.makeChapterGroup(chapters)
                    self.applyChapters()
                }
            }
        }

        // MARK: Chapters

        /// The chapters as the player's own navigation markers, which it shows as a Chapters browser with each
        /// chapter's still and seeks when one is chosen. Set again on a new player item (see ``applyChapters()``).
        private var chapterGroup: AVNavigationMarkersGroup?
        private weak var chaptersItem: AVPlayerItem?

        private func applyChapters() {
            guard let chapterGroup, let item = session.player.currentItem, item !== chaptersItem else { return }
            item.navigationMarkerGroups = [chapterGroup]
            chaptersItem = item
        }

        private static func makeChapterGroup(_ chapters: [MediaChapter]) async -> AVNavigationMarkersGroup {
            // The stills, fetched together.
            let images: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, chapter) in chapters.enumerated() {
                    guard let url = chapter.imageURL else { continue }
                    group.addTask { (index, (try? await URLSession.shared.data(from: url))?.0) }
                }
                var found: [Int: Data] = [:]
                for await (index, data) in group {
                    if let data { found[index] = data }
                }
                return found
            }

            let markers = chapters.enumerated().map { index, chapter -> AVTimedMetadataGroup in
                let title = AVMutableMetadataItem()
                title.identifier = .commonIdentifierTitle
                title.value = (chapter.name.isEmpty ? String(localized: "Chapter \(index + 1)") : chapter.name) as NSString
                title.extendedLanguageTag = "und"
                var items: [AVMetadataItem] = [title]

                if let data = images[index] {
                    let artwork = AVMutableMetadataItem()
                    artwork.identifier = .commonIdentifierArtwork
                    artwork.value = data as NSData
                    artwork.dataType = kCMMetadataBaseDataType_JPEG as String
                    artwork.extendedLanguageTag = "und"
                    items.append(artwork)
                }

                // Each runs to the next one's start; the last has no end to go to, so it's given a second.
                let start = CMTime(seconds: chapter.start, preferredTimescale: 600)
                let end = index + 1 < chapters.count ? chapters[index + 1].start : chapter.start + 1
                return AVTimedMetadataGroup(items: items, timeRange: CMTimeRange(start: start, end: CMTime(seconds: end, preferredTimescale: 600)))
            }
            return AVNavigationMarkersGroup(title: String(localized: "Chapters"), timedNavigationMarkers: markers)
        }

        // MARK: Ticks

        private func tick(_ time: CMTime) {
            let seconds = time.seconds.isFinite ? time.seconds : 0
            session.loadReplayCues()
            // A replay's full subtitles take over from a forced track's, going back to it afterwards.
            subtitles.text = replaySubtitleText(at: seconds) ?? session.subtitleText(at: seconds)
            updateSkipAction(at: seconds)
            if menuSignature != currentSignature { updateMenus() }
            updateUpNext(at: seconds)
            // A new stream (another quality or track) is a new player item, which starts with none.
            applyChapters()
        }

        // MARK: Instant replay

        /// Until when the subtitles are showing for a replay, with the viewer's own off.
        private var replayUntil: TimeInterval?

        /// Going back 10 seconds with the remote's left button, as the Apple TV app does, shows subtitles for the stretch that
        /// plays again, so a line that was missed can be read. A fresh skip back during one carries it on.
        func playerViewController(_ playerViewController: AVPlayerViewController, willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) {
            let (old, target) = (oldTime.seconds, targetTime.seconds)
            guard session.allowsReplaySubtitles, old.isFinite, target.isFinite, (5...15).contains(old - target) else { return }
            replayUntil = old + 1
            session.loadReplayCues()
        }

        private func replaySubtitleText(at seconds: TimeInterval) -> String? {
            guard let until = replayUntil else { return nil }
            guard seconds < until, session.allowsReplaySubtitles else {
                replayUntil = nil
                return nil
            }
            return session.replaySubtitleText(at: seconds)
        }

        // MARK: Skip

        private func updateSkipAction(at seconds: TimeInterval) {
            // Not under the Up Next card, as on iOS.
            let segment = isShowingUpNext ? nil : session.segment(at: seconds)
            guard segment != shownSegment else { return }
            shownSegment = segment
            controller?.contextualActions = segment.map { [skipAction(for: $0)] } ?? []
        }

        private func skipAction(for segment: MediaSegment) -> UIAction {
            let title: String = switch segment.kind {
            case .intro: String(localized: "Skip Intro")
            case .outro: String(localized: "Skip Outro")
            case .recap: String(localized: "Skip Recap")
            case .preview: String(localized: "Skip Preview")
            case .commercial: String(localized: "Skip Commercial")
            case .unknown: String(localized: "Skip")
            }
            return UIAction(title: title, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                self?.session.player.seek(to: CMTime(seconds: segment.end, preferredTimescale: 600))
            }
        }

        // MARK: Menu button

        @objc private func menuPressed() {
            close()
        }

        /// Only for Menu pressed on a button in the transport bar, at the bottom of the screen. Anywhere else, such as the Info
        /// panel at the top, or with another screen or menu in front, Menu does what the player does.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let controller, controller.presentedViewController == nil,
                  let focused = UIFocusSystem.focusSystem(for: controller.view)?.focusedItem as? UIView,
                  focused is UIControl,
                  let window = controller.view.window else { return false }
            let frame = focused.convert(focused.bounds, to: window)
            return frame.midY > window.bounds.height * 0.6
        }

        // MARK: Subtitle timing

        /// Hides the player's controls behind a small panel at the top of the screen, for nudging the subtitles earlier or
        /// later while the picture plays on. Menu (or Done) closes it and brings the controls back.
        private func showTimingPanel() {
            let host = UIHostingController(rootView: TVSubtitleTimingPanel(session: session) { [weak self] in
                self?.controller?.dismiss(animated: true)
            })
            host.view.backgroundColor = .clear
            host.modalPresentationStyle = .overFullScreen
            host.modalTransitionStyle = .crossDissolve
            present(host, triesLeft: 10)
        }

        /// Presents `host` once the menu that was tapped has finished closing; presenting while it's still going is ignored.
        private func present(_ host: UIViewController, triesLeft: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let controller = self.controller else { return }
                if controller.presentedViewController == nil {
                    controller.present(host, animated: true)
                } else if triesLeft > 0 {
                    self.present(host, triesLeft: triesLeft - 1)
                }
            }
        }

        // MARK: Transport bar menus

        private var currentSignature: MenuSignature {
            MenuSignature(
                subtitleIndex: session.subtitleIndex,
                audioIndex: session.audioIndex,
                maxBitrate: session.info.maxBitrate,
                offset: session.subtitleOffset,
                subtitleCount: session.info.subtitleTracks.count,
                audioCount: session.info.audioTracks.count,
                isSwitching: session.isSwitching,
                autoPlaysNext: session.autoPlaysNext
            )
        }

        private func updateMenus() {
            menuSignature = currentSignature
            controller?.transportBarCustomMenuItems = buildMenus()
        }

        private func buildMenus() -> [UIMenuElement] {
            var menus: [UIMenuElement] = []

            let subtitleTracks = session.info.subtitleTracks
            if !subtitleTracks.isEmpty {
                let off = UIAction(title: String(localized: "Off"), state: session.subtitleIndex == nil ? .on : .off) { [weak self] _ in
                    Task {
                        await self?.session.selectSubtitle(nil)
                        self?.updateMenus()
                    }
                }
                let tracks = subtitleTracks.map { track in
                    UIAction(title: track.title, state: session.subtitleIndex == track.index ? .on : .off) { [weak self] _ in
                        Task {
                            await self?.session.selectSubtitle(track.index)
                            self?.updateMenus()
                        }
                    }
                }
                let languages = UIMenu(options: .displayInline, children: [off] + tracks)

                // For a file whose subtitles don't line up with the speech. Always listed, so it can be found; it's only
                // usable with a subtitle on, and not when they're burned into the picture.
                let canAdjust = session.subtitleIndex != nil && !session.info.subtitlesBurnedIn
                let offset = session.subtitleOffset
                let timingTitle = offset == 0
                    ? String(localized: "Adjust Timing…")
                    : String(localized: "Adjust Timing… (\(TVSubtitleTimingPanel.offsetText(offset)))")
                let timing = UIAction(title: timingTitle, image: UIImage(systemName: "clock.arrow.2.circlepath"), attributes: canAdjust ? [] : .disabled) { [weak self] _ in
                    self?.showTimingPanel()
                }

                menus.append(UIMenu(title: String(localized: "Subtitles"), image: UIImage(systemName: "captions.bubble"), children: [languages, timing]))
            }

            // The system's own menu offers the file's tracks too, but only this one switches the stream when it has to.
            let audioTracks = session.info.audioTracks
            if audioTracks.count > 1 {
                let tracks = audioTracks.map { track in
                    UIAction(title: track.title, state: session.audioIndex == track.index ? .on : .off) { [weak self] _ in
                        Task { await self?.session.selectAudio(track.index) }
                    }
                }
                menus.append(UIMenu(title: String(localized: "Audio"), image: UIImage(systemName: "speaker.wave.2"), children: tracks))
            }

            let qualities = StreamQuality.choices(for: session.info)
            if !qualities.isEmpty {
                let auto = UIAction(title: String(localized: "Auto"), state: session.info.maxBitrate == nil ? .on : .off) { [weak self] _ in
                    Task { await self?.session.selectMaxBitrate(nil) }
                }
                let choices = qualities.map { quality in
                    UIAction(title: quality.title, state: session.info.maxBitrate == quality.maxBitrate ? .on : .off) { [weak self] _ in
                        Task { await self?.session.selectMaxBitrate(quality.maxBitrate) }
                    }
                }
                menus.append(UIMenu(title: String(localized: "Quality"), image: UIImage(systemName: "slider.horizontal.3"), children: [auto] + choices))
            }

            // Autoplay: On or Off, which is the setting on the Account screen too. Always there, whatever's playing: it's a
            // preference, and a button that appears only once something has been looked up (the next episode comes from the
            // server after playback starts, and isn't found for some shows) would pop in late, or seem not to exist. A menu
            // like the others (a bare button isn't something this bar is known to handle here), with the filled glyph for on.
            // It's rebuilt when the setting changes (see the signature), so it also follows a change made on the Account screen.
            let isOn = session.autoPlaysNext
            func choice(_ title: String, _ value: Bool) -> UIAction {
                UIAction(title: title, state: isOn == value ? .on : .off) { [weak self] _ in
                    self?.session.autoPlaysNext = value
                    self?.updateMenus()
                }
            }
            menus.append(UIMenu(
                title: String(localized: "Autoplay Next Episode"),
                image: UIImage(systemName: isOn ? "play.square.stack.fill" : "play.square.stack"),
                children: [choice(String(localized: "On"), true), choice(String(localized: "Off"), false)]
            ))

            return menus
        }

        // MARK: Up Next

        /// Puts the Up Next card over the picture from the credits on (where the server says they start, if it does, else 45
        /// seconds before the end, so the countdown has time to run; never later than 10 seconds from the end), and takes it
        /// away if the position moves back before them. It's the app's own card, shown over a player that keeps playing, since
        /// the system's proposal fades the picture out and pauses it when it's turned down.
        private func updateUpNext(at seconds: TimeInterval) {
            guard let controller, let next = session.nextEpisode,
                  let duration = session.player.currentItem?.duration.seconds, duration.isFinite, duration > 60 else { return }

            let latest = duration - 10
            let start = session.segments.last { $0.kind == .outro && $0.start > duration / 2 }.map { min($0.start, latest) }
                ?? min(duration - 45, latest)
            let isDue = !session.autoPlayCancelled && seconds >= start && seconds < duration + 1

            if isDue, !isShowingUpNext, controller.presentedViewController == nil {
                showUpNext(next, over: controller)
            } else if isShowingUpNext {
                // Not presented, because something else was in the way when it was asked to: ask again.
                let failed = upNextHost?.presentingViewController == nil && Date.now.timeIntervalSince(upNextShownAt ?? .now) > 1
                if !isDue || failed { hideUpNext(animated: !failed) }
            }
        }

        private func showUpNext(_ next: MediaItem, over controller: AVPlayerViewController) {
            let host = UIHostingController(rootView: TVUpNextOverlay(
                next: next,
                acceptanceDate: .now.addingTimeInterval(Self.upNextCountdown),
                accept: { [weak self] in self?.acceptUpNext(next) },
                reject: { [weak self] in self?.rejectUpNext() }
            ))
            host.view.backgroundColor = .clear
            host.modalPresentationStyle = .overFullScreen
            host.modalTransitionStyle = .crossDissolve
            upNextHost = host
            upNextShownAt = .now
            isShowingUpNext = true
            controller.present(host, animated: true)

            upNextTask?.cancel()
            upNextTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.upNextCountdown))
                guard !Task.isCancelled else { return }
                self?.acceptUpNext(next)
            }
        }

        /// Takes the card away and leaves the picture as it is.
        private func hideUpNext(animated: Bool = true) {
            upNextTask?.cancel()
            isShowingUpNext = false
            upNextHost?.dismiss(animated: animated)
            upNextHost = nil
        }

        private func acceptUpNext(_ next: MediaItem) {
            hideUpNext(animated: false)
            playNext(next)
        }

        /// Cancel: the card goes, and this episode doesn't move on by itself at the end.
        private func rejectUpNext() {
            session.autoPlayCancelled = true
            hideUpNext()
        }

        private func itemFinished(_ finished: AVPlayerItem?) {
            guard let finished, finished === session.player.currentItem else { return }
            if let next = session.nextEpisode, !session.autoPlayCancelled {
                acceptUpNext(next)
            } else {
                // A movie, the last episode, or one whose autoplay was cancelled: back to the page it was started from.
                hideUpNext(animated: false)
                close()
            }
        }

        // MARK: Artwork

        /// Adds the poster to the player's Info panel. It's fetched after playback starts, so it never holds it up.
        private func loadArtwork() {
            guard let url = session.item.posterURL ?? session.item.thumbnailURL else { return }
            artworkTask = Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled,
                      let self, let playerItem = self.session.player.currentItem else { return }
                let artwork = AVMutableMetadataItem()
                artwork.identifier = .commonIdentifierArtwork
                artwork.value = data as NSData
                artwork.dataType = kCMMetadataBaseDataType_JPEG as String
                artwork.extendedLanguageTag = "und"
                playerItem.externalMetadata += [artwork]
            }
        }
    }
}
#endif
