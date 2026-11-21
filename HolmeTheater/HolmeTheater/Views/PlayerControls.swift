// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import AVKit
import SwiftUI

// MARK: - Controls

/// The player's controls: close, Picture in Picture and AirPlay at the top; play, pause and skip in the middle;
/// title, quality and track menus, the progress bar, and Info, Cast and Chapters along the bottom. Volume is
/// left to the device's buttons and the system's own volume display.
/// Tap the video to show or hide them; they hide themselves a few seconds after playback starts.
struct PlayerControlsView: View {
    let item: MediaItem
    let session: PlaybackSession
    let model: PlayerControlsModel
    /// The screen the controls lay themselves out on, rather than sitting inside its safe area.
    let screen: PlayerScreen
    /// Whether the display is partially folded, with the picture in the other half. The controls then fill their
    /// half and stay on screen, since there's no picture under them to see.
    var isFolded = false
    let close: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverIsOn
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlIsOn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// How tall the panel under the pills is, growing with the text size so cards and rows aren't clipped.
    @ScaledMetric(relativeTo: .body) private var regularPanelHeight: CGFloat = 130
    @ScaledMetric(relativeTo: .body) private var compactPanelHeight: CGFloat = 220

    /// Side of the round and capsule controls, sized to match the Apple TV app.
    static let buttonSize: CGFloat = 48

    enum Panel: String, Identifiable, CaseIterable {
        case info, cast, chapters
        var id: String { rawValue }
    }

    /// Whether the controls are showing. Starts from the session's, not always `true`: SwiftUI can rebuild this view
    /// when the window changes shape (rotating, folding), and the controls mustn't pop open each time.
    @State private var showsControls: Bool

    /// Plays the episode that follows this one.
    let playNext: (MediaItem) -> Void

    init(
        item: MediaItem,
        session: PlaybackSession,
        model: PlayerControlsModel,
        screen: PlayerScreen,
        isFolded: Bool = false,
        initialPanel: Panel? = nil,
        playNext: @escaping (MediaItem) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.item = item
        self.playNext = playNext
        self.session = session
        self.model = model
        self.screen = screen
        self.isFolded = isFolded
        self.close = close
        _showsControls = State(initialValue: session.controlsAreShowing)
        _panel = State(initialValue: initialPanel)
    }
    /// Bumped on every interaction, restarting the hide timer.
    @State private var interactions = 0
    /// The panel open below the progress bar, if any.
    @State private var panel: Panel?
    @State private var people: [MediaPerson] = []
    @State private var scrubFraction: Double?
    /// Whether the full description is open in a sheet over the player.
    @State private var showsFullInfo = false
    /// The cast member whose page is open in a sheet over the player.
    @State private var openedPerson: MediaPerson?
    /// Portrait: the layout tightens to fit, as in the Apple TV app.
    @State private var isCompact = false

    /// How tall the bottom block (title, progress bar and pills) is, which the buttons floating over the picture
    /// stay above. It's taller at larger text sizes.
    @State private var bottomBlockHeight: CGFloat = 0

    /// How far above the bottom padding the skip and next-episode buttons sit: clear of the controls if they're
    /// showing, otherwise just above the edge.
    private var floatingButtonsLift: CGFloat {
        controlsAreShown ? max(150, bottomBlockHeight + 12) : 24
    }

    /// Whether the skip button goes under the top bar instead of above the bottom controls. At accessibility sizes
    /// the bottom controls are tall enough that, above them, it would sit on the playback buttons in the middle.
    private var skipSitsAtTop: Bool { controlsAreShown && dynamicTypeSize.isAccessibilitySize }

    /// Always with VoiceOver or Switch Control on: controls that hide themselves after a few seconds are gone before
    /// anyone using them has found their way around.
    private var controlsAreShown: Bool { showsControls || voiceOverIsOn || switchControlIsOn }

    private var statusBarIsHidden: Bool { isFolded || !controlsAreShown || model.showsTiming }

    private var showsExpandedPanelBar: Bool { !dynamicTypeSize.isAccessibilitySize }

    private var shouldStayVisible: Bool {
        !model.isPlaying || panel != nil || scrubFraction != nil || session.isSwitching || showsFullInfo || openedPerson != nil || model.showsTiming
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if model.isBuffering || session.isSwitching {
                ProgressView().controlSize(.large).tint(.white)
            }

            // Adjusting the subtitles' timing clears everything else away, leaving the picture and its subtitles.
            controls
                .opacity(controlsAreShown && !model.showsTiming ? 1 : 0)
                .allowsHitTesting(controlsAreShown && !model.showsTiming)
                // Invisible isn't unreachable: VoiceOver would still read out controls that are faded away.
                .accessibilityHidden(!controlsAreShown || model.showsTiming)

            // Offered while the picture is in a stretch the server has marked, whether or not the controls are
            // showing; above the bottom row when they are.
            // Folded, it goes over the picture in the other half instead (see `CustomPlayer`).
            if !isFolded {
                SkipSegmentButton(session: session, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipSitsAtTop ? .topTrailing : .bottomTrailing)
                    .padding(.trailing, screen.rowInsets(top: skipSitsAtTop).trailing)
                    .padding(.top, skipSitsAtTop ? screen.topPadding(isCompact: isCompact) + Self.buttonSize + 12 : 0)
                    .padding(.bottom, skipSitsAtTop ? 0 : screen.bottomPadding + floatingButtonsLift)
                    .opacity(model.showsTiming || panel != nil ? 0 : 1)
                    .allowsHitTesting(!model.showsTiming && panel == nil)
                    .accessibilityHidden(model.showsTiming || panel != nil)
                    .animation(.smooth(duration: 0.3), value: controlsAreShown)
            }

            // Near the end of an episode: the next one, with a countdown to starting it.
            // Folded, it goes over the picture in the other half instead (see `CustomPlayer`).
            if !isFolded {
                NextEpisodeOverlay(session: session, model: model, play: playNext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, screen.rowInsets(top: false).trailing)
                    .padding(.bottom, screen.bottomPadding + floatingButtonsLift)
                    .opacity(model.showsTiming || panel != nil ? 0 : 1)
                    .allowsHitTesting(!model.showsTiming && panel == nil)
                    .accessibilityHidden(model.showsTiming || panel != nil)
                    .animation(.smooth(duration: 0.3), value: controlsAreShown)
            }

            // Folded, the picture is in the other half, so the panel goes in this one, on its own.
            if model.showsTiming && isFolded {
                SubtitleTimingPanel(session: session, touch: {}) { model.showsTiming = false }
                    .frame(maxWidth: 440)
                    .padding(.horizontal, max(screen.rowInsets(top: false).leading, screen.rowInsets(top: false).trailing))
                    .transition(.opacity)
            }
        }
        // The whole screen, so taps anywhere toggle the controls and the spinner is centred; the rows keep
        // clear of the camera and home indicator by themselves. Folded, it stays in its half, clear of the fold.
        .ignoresSafeArea(edges: isFolded ? [] : .all)
        .foregroundStyle(.white)
        // Always dark, whatever the device is set to: the materials and glass then tint dark over the picture, as
        // in the Apple TV app, instead of turning pale in Light Mode.
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: Bool.self) { $0.size.width < $0.size.height } action: { isCompact = $0 }
        // As in the Apple TV app, the clock and battery show with the controls. Folded, the other half holds the
        // picture, and the status bar would sit over it.
        .statusBarHidden(statusBarIsHidden)
        .onChange(of: statusBarIsHidden, initial: true) { model.statusBarShown = !statusBarIsHidden }
        // A tap on the picture, in the other half when folded, does the same as one here.
        .onChange(of: model.pictureTaps) { toggleControls() }
        // Out of the way of the timing panel, which is over the picture beneath this view (unless folded).
        .allowsHitTesting(!model.showsTiming || isFolded)
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: showsControls)
        .onChange(of: showsControls) { session.controlsAreShowing = showsControls }
        .animation(.smooth(duration: 0.3), value: panel)
        .animation(.smooth(duration: 0.25), value: model.showsTiming)
        .onChange(of: model.showsTiming) { touch() }
        .task(id: interactions) {
            guard showsControls else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, !shouldStayVisible { showsControls = false }
        }
        .onChange(of: model.isPlaying) { _, isPlaying in
            if isPlaying { interactions += 1 } else { showsControls = true }
        }
        .onChange(of: session.info) { Task { await model.loadChapters() } }
        .onChange(of: availablePanels) { if let panel, !availablePanels.contains(panel) { self.panel = nil } }
        .task { await loadPeople() }
        .sheet(item: $openedPerson) { person in
            NavigationStack {
                PersonDetailView(person: person)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { openedPerson = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showsFullInfo) {
            FullInfoSheet(item: item)
                .preferredColorScheme(.dark)
        }
        .alert(
            "Couldn't Change Playback",
            isPresented: Binding(get: { session.switchError != nil }, set: { if !$0 { session.switchError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(session.switchError ?? "")
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.leading, screen.rowInsets(top: true).leading)
                    .padding(.trailing, screen.rowInsets(top: true).trailing)
                Spacer(minLength: 16)
                bottomBlock
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBlockHeight = $0 }
                    .padding(.leading, screen.rowInsets(top: false).leading)
                    .padding(.trailing, screen.rowInsets(top: false).trailing)
            }
            .padding(.top, screen.topPadding(isCompact: isCompact))
            .padding(.bottom, screen.bottomPadding)
            // Its own layer, so it's centred on the screen whatever the bars above and below take up.
            // Portrait has room to keep the transport beside the info panel.
            if panel == nil || (panel == .info && isCompact) {
                transport
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: isFolded ? [] : .all)
        .background {
            // As in the system player, the picture dims under the controls so they read against anything.
            ZStack {
                Color.black.opacity(0.25)
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(panel == nil ? 0.6 : 0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton("xmark", label: "Close", action: close)

            HStack(spacing: 4) {
                if model.supportsPictureInPicture {
                    Button { model.togglePictureInPicture(); touch() } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Picture in Picture")
                }
                AirPlayButton()
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
            }
            .padding(.horizontal, 4)
            .glassEffect(.clear.interactive(), in: .capsule)

            Spacer(minLength: 0)
        }
    }

    // MARK: Middle

    /// Symbols on glass circles, as in the Apple TV app.
    private var transport: some View {
        HStack(spacing: isCompact ? 36 : 56) {
            transportButton("gobackward.10", label: "Back 10 seconds", size: 32) { model.skip(by: -10) }
            transportButton(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play", size: 52) {
                model.togglePlayback()
            }
            transportButton("goforward.10", label: "Forward 10 seconds", size: 32) { model.skip(by: 10) }
        }
    }

    private func transportButton(_ systemImage: String, label: LocalizedStringKey, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action(); touch()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2, height: size * 2)
                .glassEffect(.clear.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Bottom

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The info panel takes the place of the title and progress bar, as in the Apple TV app.
            if panel != .info {
                // Side by side, the title would get a column a few letters wide at accessibility sizes, so the
                // stream controls go under it.
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))) {
                    titleBlock
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    streamControls
                }
                .transition(.opacity)
                progressRow
                    .transition(.opacity)
            }
            panelBar
            if panel != nil {
                PanelPager(
                    item: item,
                    people: people,
                    model: model,
                    panels: availablePanels,
                    selection: $panel,
                    height: isCompact ? compactPanelHeight : regularPanelHeight,
                    isCompact: isCompact,
                    showMore: { showsFullInfo = true; touch() },
                    openPerson: { openedPerson = $0; touch() },
                    fromBeginning: playFromBeginning,
                    goToShow: canGoToShow ? { goToShow() } : nil
                )
                // As in the Apple TV app, the picture blurs from just below the pills (see `CustomPlayer`).
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { model.blurTop = $0 - 10 }
                .onDisappear { model.blurTop = nil }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var titleBlock: some View {
        // One line each, until the text is so large that a one-line title would be a few letters.
        let lines = dynamicTypeSize.isAccessibilitySize ? 3 : 1
        return VStack(alignment: .leading, spacing: 2) {
            if let line = showLine {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .secondaryPlayerText()
                    .lineLimit(lines)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(item.title)
                        .lineLimit(lines)
                } else {
                    // Beside the stream controls on a narrow screen it's often too long for its line, so it scrolls
                    // to show the rest, while the controls are showing.
                    MarqueeText(text: item.title, isAnimating: controlsAreShown && !model.showsTiming)
                }
            }
            .font(.headline)
        }
    }

    private var showLine: String? {
        guard item.kind == .episode, let series = item.seriesTitle else { return item.extraLabel }
        guard let season = item.seasonNumber, let episode = item.episodeNumber else { return series }
        return "\(series) · S\(season), E\(episode)"
    }

    /// Speed, quality, audio and subtitles, as glyphs in one glass capsule.
    private var streamControls: some View {
        HStack(spacing: 0) {
            speedMenu
            qualityMenu
            if session.info.audioTracks.count > 1 { audioMenu }
            if !session.info.subtitleTracks.isEmpty { subtitlesMenu }
            autoPlayButton
        }
        .padding(.horizontal, 4)
        .glassEffect(.clear.interactive(), in: .capsule)
        .simultaneousGesture(TapGesture().onEnded { touch() })
        .disabled(session.isSwitching)
    }

    private func menuGlyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .frame(width: Self.buttonSize, height: Self.buttonSize)
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { session.info.maxBitrate },
                set: { bitrate in Task { await session.selectMaxBitrate(bitrate) } }
            )) {
                Text("Maximum").tag(Int?.none)
                ForEach(StreamQuality.choices(for: session.info)) { quality in
                    Text(quality.title).tag(Optional(quality.maxBitrate))
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph("sparkles.tv")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Quality")
        .accessibilityValue(qualityLabel)
    }

    private static let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                ForEach(Self.playbackRates, id: \.self) { rate in
                    Text(rate == 1 ? String(localized: "Normal") : "\(rate.formatted())×").tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph("gauge.with.dots.needle.67percent")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Playback Speed")
        .accessibilityValue("\(model.playbackRate.formatted())×")
    }

    private var audioMenu: some View {
        Menu {
            Picker("Audio", selection: Binding(
                get: { session.audioIndex },
                set: { index in if let index { Task { await session.selectAudio(index) } } }
            )) {
                ForEach(session.info.audioTracks) { Text($0.title).tag(Optional($0.index)) }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph("waveform")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Audio")
        .accessibilityValue(session.info.audioTracks.first { $0.index == session.audioIndex }?.title ?? "")
    }

    private var subtitlesMenu: some View {
        Menu {
            // For a file whose subtitles don't line up with the speech.
            if session.subtitleIndex != nil, !session.info.subtitlesBurnedIn {
                Button("Adjust Timing…", systemImage: "clock.arrow.2.circlepath") {
                    model.showsTiming = true
                }
            }

            Picker("Subtitles", selection: Binding(
                get: { session.subtitleIndex },
                set: { index in Task { await session.selectSubtitle(index) } }
            )) {
                Text("Off").tag(Int?.none)
                ForEach(session.info.subtitleTracks) { Text($0.title).tag(Optional($0.index)) }
            }
            .pickerStyle(.inline)
        } label: {
            menuGlyph(session.subtitleIndex == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(session.info.subtitleTracks.first { $0.index == session.subtitleIndex }?.title ?? String(localized: "Off"))
    }

    /// Turns the automatic start of the next episode on or off: the same setting as on the Account screen. Always there,
    /// whatever's playing: it's a preference, and one that appeared only once something had been looked up (the next episode
    /// comes from the server after playback starts) would pop in late. The filled glyph is on.
    private var autoPlayButton: some View {
        Button {
            session.autoPlaysNext.toggle()
        } label: {
            menuGlyph(session.autoPlaysNext ? "rectangle.stack.badge.play.fill" : "rectangle.stack.badge.play")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Autoplay Next Episode")
        .accessibilityValue(session.autoPlaysNext ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    /// The cap chosen, or the resolution actually playing when there's no cap.
    private var qualityLabel: String {
        if let cap = session.info.maxBitrate, let quality = StreamQuality.choices(for: session.info).first(where: { $0.maxBitrate == cap }) {
            return quality.height >= 2160 ? "4K" : "\(quality.height)p"
        }
        switch model.videoHeight {
        case 2000...: return "4K"
        case 1400..<2000: return "1440p"
        case 1000..<1400: return "1080p"
        case 700..<1000: return "720p"
        case 1..<700: return "SD"
        default: return String(localized: "Quality")
        }
    }

    // The position changes ten times a second. It's read only in these two small views, so the rest of the controls,
    // and the menus in them, aren't rebuilt every time it moves: a menu that's rebuilt while open drops taps.
    private var progressRow: some View {
        PlayerProgressRow(
            model: model,
            scrubFraction: $scrubFraction,
            onBegin: { model.beginScrubbing(); touch() },
            onChange: { fraction in
                // Showing frames while dragging is only cheap for the original file. On a server-made stream,
                // every jump can make the server restart its transcode, so that waits for the finger to lift.
                if session.info.method == .directPlay { model.scrub(to: fraction * model.duration) }
            },
            onEnd: { model.endScrubbing(at: $0 * model.duration); touch() }
        )
    }

    /// Info, Cast and Chapters (each only if there's something to show), and the end time.
    @ViewBuilder
    private var panelBar: some View {
        if showsExpandedPanelBar {
            // On a narrow screen, such as an iPhone in portrait with all three pills, the end time doesn't fit beside them,
            // and the row would push the controls past the screen's edges. It goes then: the progress row still shows the
            // time left.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pills
                    Spacer(minLength: 8)
                    if panel == nil {
                        PlayerEndTime(model: model, scrubFraction: scrubFraction)
                    }
                }
                HStack(spacing: 8) {
                    pills
                    Spacer(minLength: 0)
                }
            }
        } else {
            // At the largest text sizes the pills don't fit side by side, so they scroll, and the end time goes.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(availablePanels) { panel in
                        pill(panel)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var pills: some View {
        ForEach(availablePanels) { panel in
            pill(panel)
        }
    }

    private var availablePanels: [Panel] {
        Panel.allCases.filter { panel in
            switch panel {
            case .info: item.overview != nil || item.tagline != nil
            case .cast: !people.isEmpty
            case .chapters: !model.chapters.isEmpty
            }
        }
    }

    private func pill(_ panel: Panel) -> some View {
        let isSelected = self.panel == panel
        return Button {
            self.panel = isSelected ? nil : panel
            touch()
        } label: {
            Text(panel.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: .capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func circleButton(_ systemImage: String, label: LocalizedStringKey, size: CGFloat = PlayerControlsView.buttonSize, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: Behaviour

    private func toggleControls() {
        if model.showsTiming { return }
        if panel != nil { panel = nil; touch() } else { setControls(visible: !showsControls) }
    }

    private func setControls(visible: Bool) {
        showsControls = visible
        interactions += 1
    }

    private func touch() { interactions += 1 }

    private var canGoToShow: Bool { item.kind == .episode && item.seriesID != nil }

    private func playFromBeginning() {
        model.seek(to: 0)
        model.player.play()
        panel = nil
        touch()
    }

    /// Closes the player and opens the episode's show behind it.
    private func goToShow() {
        guard let seriesID = item.seriesID else { return }
        Task {
            guard let show = try? await appModel.service.item(id: seriesID) else { return }
            appModel.pendingShow = show
            close()
        }
    }

    /// The cast is only on a fully fetched item, not on the list rows that usually start playback.
    private func loadPeople() async {
        var full = item
        if item.people.isEmpty || item.chapters.isEmpty, let fetched = try? await appModel.service.item(id: item.id) {
            full = fetched
        }
        people = full.people
        model.setServerChapters(full.chapters.enumerated().map { index, chapter in
            PlayerChapter(
                id: index,
                title: chapter.name.isEmpty ? String(localized: "Chapter \(index + 1)") : chapter.name,
                start: chapter.start,
                imageURL: chapter.imageURL
            )
        })
    }

    static func clock(_ seconds: TimeInterval) -> String { TimeCode.clock(seconds) }
}

private extension PlayerControlsView.Panel {
    var title: LocalizedStringKey {
        switch self {
        case .info: "Info"
        case .cast: "Cast & Crew"
        case .chapters: "Chapters"
        }
    }
}

#endif
