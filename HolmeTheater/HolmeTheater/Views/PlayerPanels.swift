// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

// MARK: - Panels

/// The selected one of Info, Cast and Chapters, below the pills, as in the Apple TV app. Panels are switched with
/// their pills rather than by swiping, which would fight the horizontal scrolling of the cast row.
struct PanelPager: View {
    let item: MediaItem
    let people: [MediaPerson]
    let model: PlayerControlsModel
    let panels: [PlayerControlsView.Panel]
    @Binding var selection: PlayerControlsView.Panel?
    let height: CGFloat
    let isCompact: Bool
    let showMore: () -> Void
    let openPerson: (MediaPerson) -> Void
    let fromBeginning: () -> Void
    /// Nil when the item isn't an episode.
    let goToShow: (() -> Void)?

    var body: some View {
        Group {
            if let selection {
                content(for: selection)
                    .id(selection)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: height)
        // A scroll view's clip reaches into the safe area, which the controls ignore, so keep it to this frame.
        .clipShape(.rect)
    }

    @ViewBuilder
    private func content(for panel: PlayerControlsView.Panel) -> some View {
        switch panel {
        case .info: InfoPane(item: item, isCompact: isCompact, showMore: showMore, fromBeginning: fromBeginning, goToShow: goToShow)
        case .cast: CastPane(people: people, open: openPerson)
        case .chapters: ChaptersPane(model: model) { selection = nil }
        }
    }
}

private struct InfoPane: View {
    let item: MediaItem
    let isCompact: Bool
    let showMore: () -> Void
    let fromBeginning: () -> Void
    let goToShow: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Vertical, so it never fights the sideways swipe between panes.
        ScrollView {
            if dynamicTypeSize.isAccessibilitySize {
                // Side by side there'd be room for a few letters of text, so the buttons go under it.
                VStack(alignment: .leading, spacing: 16) {
                    text
                    VStack(spacing: 8) { buttons }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // Portrait has no room for the thumbnail, as in the Apple TV app.
                    if !isCompact { thumbnail(width: 190) }
                    text
                    Spacer(minLength: 0)
                    VStack(spacing: 8) { buttons }
                        .frame(width: isCompact ? 150 : 190)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func thumbnail(width: CGFloat) -> some View {
        CachedAsyncImage(url: item.thumbnailURL ?? item.backdropURL ?? item.posterURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.kind == .episode ? item.seriesTitle ?? item.title : item.title)
                .font(.headline)
            if item.kind == .episode, item.seriesTitle != nil {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else if let tagline = item.tagline {
                Text(tagline).font(.subheadline.weight(.semibold))
            }
            if let overview = item.overview {
                TruncatingOverview(text: overview, lineLimit: isCompact ? 5 : 3, onMore: showMore)
            }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .secondaryPlayerText()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var details: [String] {
        [
            item.genres.first,
            item.runtime.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) },
            item.technicalLine,
            item.officialRating
        ].compactMap { $0 }
    }

    @ViewBuilder
    private var buttons: some View {
        actionButton("From Beginning", systemImage: "play.fill", action: fromBeginning)
        if let goToShow {
            actionButton("Go to Show", systemImage: "tv", action: goToShow)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .capsule)
    }
}

/// The whole description, over the player. It's a system sheet, which is Liquid Glass, so the picture shows through.
struct FullInfoSheet: View {
    let item: MediaItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The title goes under the thumbnail when beside it there'd be too little room: at accessibility sizes,
                // or on a narrow sheet.
                if dynamicTypeSize.isAccessibilitySize {
                    stackedHeader
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            thumbnail
                            titleBlock
                                // The column's ideal width, which has to fit for the header to sit side by side.
                                .frame(maxWidth: 200, alignment: .leading)
                        }
                        // Leaves room for the close button, which sits over the top corner.
                        .padding(.trailing, 48)

                        stackedHeader
                    }
                }
                if let tagline = item.tagline {
                    Text(tagline).font(.headline)
                }
                if let overview = item.overview {
                    Text(overview).font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(16)
            .accessibilityLabel("Close")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            thumbnail
            titleBlock
        }
    }

    private var thumbnail: some View {
        CachedAsyncImage(url: item.thumbnailURL ?? item.backdropURL ?? item.posterURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 160, height: 90)
        .clipShape(.rect(cornerRadius: 10))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.kind == .episode ? item.seriesTitle ?? item.title : item.title)
                .font(.title3.weight(.bold))
            if item.kind == .episode, item.seriesTitle != nil {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
            }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: [String] {
        [
            item.genres.first,
            item.year.map(String.init),
            item.runtime.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) },
            item.officialRating,
            item.technicalLine
        ].compactMap { $0 }
    }
}

private struct CastPane: View {
    let people: [MediaPerson]
    let open: (MediaPerson) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A card's width, and its portrait's, which grow with the text (up to a point) so names aren't cut short.
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 124
    @ScaledMetric(relativeTo: .caption) private var portraitSize: CGFloat = 52

    var body: some View {
        let lines = dynamicTypeSize.isAccessibilitySize ? 3 : 1
        // Sideways, as in the Apple TV app. The panels aren't paged, so this has the swipe to itself.
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(people) { person in
                    Button { open(person) } label: {
                    VStack(spacing: 2) {
                        PersonPortrait(person: person, size: min(portraitSize, 52 * 1.5))
                            .padding(.bottom, 4)
                        Text(person.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(lines)
                        Text(person.subtitle ?? " ")
                            .font(.caption2)
                            .secondaryPlayerText()
                            .lineLimit(lines)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .frame(width: min(cardWidth, 124 * 1.6))
                    .contentShape(.rect(cornerRadius: 24))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 24))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

private struct ChaptersPane: View {
    let model: PlayerControlsModel
    let done: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A card's width, which grows with the text (up to a point) so chapter names aren't cut short.
    @ScaledMetric(relativeTo: .caption) private var baseWidth: CGFloat = 140

    var body: some View {
        let width = min(baseWidth, 140 * 1.6)
        // Sideways, like the cast row.
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.chapters) { chapter in
                    Button {
                        model.seek(to: chapter.start)
                        done()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if chapter.imageURL != nil {
                                CachedAsyncImage(url: chapter.imageURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.1)
                                    }
                                }
                                .frame(width: width, height: width * 79 / 140)
                                .clipShape(.rect(cornerRadius: 12))
                            }
                            Text(chapter.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            Text(PlayerControlsView.clock(chapter.start))
                                .font(.caption2.monospacedDigit())
                                .secondaryPlayerText()
                        }
                        .frame(width: width, alignment: .leading)
                        .padding(8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 20))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
#endif
