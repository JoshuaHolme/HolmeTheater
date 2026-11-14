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
    /// The lines the track puts somewhere other than along the bottom.
    var placed: [SubtitleCue] = []
    /// For a track of pictures.
    var picture: PictureSubtitle?
    /// The video's size as shown, for where it sits on the screen: zero until the player knows it.
    var videoSize: CGSize = .zero
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
    static func offsetText(_ offset: TimeInterval) -> String { SubtitleOffset.text(offset) }
}

/// The subtitles, drawn over the picture. The player's own subtitles are off, because the app follows the position
/// itself (see `PlaybackSession.subtitleText(at:)`), as it does on iOS.
struct TVSubtitleView: View {
    let model: TVSubtitleModel

    /// The overlay's size: the screen, which the picture fills (or fits in, with bars).
    @State private var size: CGSize = .zero

    /// Where the video is: fitted to the screen, as the player shows it.
    private var videoFrame: CGRect {
        let screen = CGRect(origin: .zero, size: size)
        guard model.videoSize.width > 0, model.videoSize.height > 0 else { return screen }
        return AVMakeRect(aspectRatio: model.videoSize, insideRect: screen)
    }

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay(alignment: .topLeading) {
                // A track of pictures is drawn where the picture says, scaled with the video.
                if let picture = model.picture {
                    let rect = picture.rect(onVideo: videoFrame, within: CGRect(origin: .zero, size: size))
                    Image(decorative: picture.image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            // An overlay of its own: sharing one with the picture, it stopped the picture being drawn.
            .overlay(alignment: .topLeading) {
                PlacedSubtitlesView(cues: model.placed, frame: videoFrame, fontSize: 52, shadowRadius: 6)
            }
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
struct TVCastTab: View {
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
final class TVCastHostingController: UIHostingController<TVCastTab> {
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
struct TVUpNextOverlay: View {
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

    /// Whether their photo is showing full screen.
    @State private var showsPhoto = false

    /// Whether the sheet with everything about them is showing.
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                HStack(alignment: .top, spacing: 60) {
                    // Selecting the portrait opens the photo full screen, as on a person's page. It's also the one thing up
                    // here focus can reach, which is what lets the sheet scroll back up from the posters.
                    Button { showsPhoto = true } label: {
                        PersonPortrait(person: person, size: 280)
                            .hoverEffect(.highlight)
                    }
                    .buttonStyle(.borderless)
                    .buttonBorderShape(.circle)
                    .disabled(person.imageURL == nil)
                    .accessibilityLabel("View Photo of \(person.name)")

                    VStack(alignment: .leading, spacing: 16) {
                        // The info button is beside the name, and opens everything the server knows about them.
                        HStack(spacing: 24) {
                            Text(person.name)
                                .font(.largeTitle.bold())
                            if let details, !details.isEmpty {
                                Button { showsDetails = true } label: {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 30, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel("Details")
                            }
                        }
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
                // As wide as the sheet, so moving up from any poster reaches the portrait.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()

                shelf("Movies", credits.filter { $0.item.kind == .movie })
                shelf("Shows", credits.filter { $0.item.kind == .series })
            }
            .padding(80)
        }
        .scrollClipDisabled()
        .fullScreenCover(isPresented: $showsPhoto) { PhotoViewer(person: person) }
        // The same glass sheet as on a person's page: name and role, the whole biography, then the facts.
        .sheet(isPresented: $showsDetails) {
            ShowDetailsSheet(title: person.name, tagline: person.subtitle, overview: details?.biography, facts: details.map(PersonDetailView.detailFacts(for:)) ?? [])
        }
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
#endif
