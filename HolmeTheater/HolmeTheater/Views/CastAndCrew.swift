// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A horizontally scrolling row of the show's cast and crew: a round portrait, the name, and the character or job.
/// Hidden if the server lists no one.
struct CastAndCrewShelf: View {
    let people: [MediaPerson]

    /// The width of one person's column. Larger on tvOS for the "ten-foot" UI.
    private static var cardWidth: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 130
        #endif
    }

    /// Space between portraits. On tvOS there's room for a focused portrait to lift without touching its neighbors.
    private static var cardSpacing: CGFloat {
        #if os(tvOS)
        Layout.cardSpacing
        #else
        16
        #endif
    }

    /// The width of one person's column as shown: wider at larger text sizes (up to 1.75 times) so names and
    /// roles aren't broken into a few letters a line.
    @ScaledMetric(relativeTo: .footnote) private var scaledWidth: CGFloat = CastAndCrewShelf.cardWidth
    private var cardWidth: CGFloat { min(scaledWidth, Self.cardWidth * 1.75) }

    /// The person a tap or peek is opening, and the one whose photo is showing full screen.
    @State private var openedPerson: MediaPerson?
    @State private var photoPerson: MediaPerson?

    /// Whether the list of everyone is open.
    @State private var showsFullCast = false

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
                ShelfHeadingLink(title: "Cast and Crew") { showsFullCast = true }
                    .padding(.horizontal, Layout.contentInset)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                        ForEach(people) { person in
                            #if os(tvOS)
                            TVPersonButton(person: person, size: cardWidth, open: { openedPerson = person }, viewPhoto: { photoPerson = person })
                            #else
                            PersonCard(person: person, size: cardWidth)
                                .frame(width: cardWidth)
                                .personPeek(person, open: { openedPerson = person }, viewPhoto: { photoPerson = person })
                            #endif
                        }
                    }
                    .padding(.horizontal, Layout.contentInset)
                }
                .scrollIndicators(.hidden)
                #if os(tvOS)
                // Lets a focused portrait lift and grow past the edge of the scroll view.
                .scrollClipDisabled()
                #endif
                // Presented from here rather than from a card, because cards sit in a lazy stack, where SwiftUI
                // ignores destinations.
                .navigationDestination(item: $openedPerson) { PersonDetailView(person: $0) }
                .fullScreenCover(item: $photoPerson) { PhotoViewer(person: $0) }
                .navigationDestination(isPresented: $showsFullCast) { CastListView(people: people) }
            }
        }
    }
}

/// Every cast and crew member as a list of rows.
struct CastListView: View {
    let people: [MediaPerson]

    /// The person a tap or peek is opening, and the one whose photo is showing full screen.
    @State private var openedPerson: MediaPerson?
    @State private var photoPerson: MediaPerson?

    /// The portrait's size, larger at larger text sizes (up to 1.5 times) so it keeps up with the name beside it.
    @ScaledMetric(relativeTo: .body) private var portraitSize: CGFloat = 56

    var body: some View {
        List(people) { person in
            row(for: person)
                .personPeek(person, open: { openedPerson = person }, viewPhoto: { photoPerson = person })
        }
        .listStyle(.plain)
        .navigationTitle("Cast and Crew")
        .navigationDestination(item: $openedPerson) { PersonDetailView(person: $0) }
        .fullScreenCover(item: $photoPerson) { PhotoViewer(person: $0) }
    }

    private func row(for person: MediaPerson) -> some View {
        HStack(spacing: 12) {
                PersonPortrait(person: person, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.body.weight(.semibold))
                    if let subtitle = person.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        .accessibilityElement(children: .combine)
    }
}

extension MediaPerson {
    /// The character for an actor, otherwise the job.
    var subtitle: String? {
        switch role {
        case .actor: character
        case .director: String(localized: "Director")
        case .writer: String(localized: "Writer")
        case .producer: String(localized: "Producer")
        case .creator: String(localized: "Creator")
        case .composer: String(localized: "Composer")
        }
    }
}

/// A round portrait, or a person icon if there's none.
struct PersonPortrait: View {
    let person: MediaPerson

    /// The portrait's width and height.
    let size: CGFloat

    var body: some View {
        // A fixed square, so a long name or character beside it can't squeeze the portrait smaller.
        Color.secondary.opacity(0.2)
            .frame(width: size, height: size)
            .overlay {
                CachedAsyncImage(url: person.imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .font(size > 80 ? .title : .body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(Circle())
    }
}

extension View {
    /// Makes a person's card or row open their page when tapped, and peek and pop when long-pressed, with a menu
    /// to open the page or view their photo. The same way an item's card works on the home screen.
    @ViewBuilder
    func personPeek(_ person: MediaPerson, open: @escaping () -> Void, viewPhoto: @escaping () -> Void) -> some View {
        let menu = person.menuEntries(open: open, viewPhoto: viewPhoto)
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the page. SwiftUI's preview can't.
        peekAndPop(PeekAndPopSpec(
            menu: menu,
            accessibilityLabel: [person.name, person.subtitle].compactMap { $0 }.joined(separator: ", "),
            onTap: open,
            onOpen: open,
            peek: PersonPeek(person: person)
        ))
        #else
        Button(action: open) { self }
            .cardLinkStyle()
            .contextMenu {
                ItemActionButtons(entries: menu)
            }
        #endif
    }
}

extension MediaPerson {
    /// The long-press menu: open their page, and view their photo if they have one.
    func menuEntries(open: @escaping () -> Void, viewPhoto: @escaping () -> Void) -> [ItemMenuEntry] {
        var entries = [ItemMenuEntry(id: .goTo, title: String(localized: "Go to Person"), systemImage: "person.crop.circle", perform: open)]
        if imageURL != nil {
            entries.append(ItemMenuEntry(id: .viewPhoto, title: String(localized: "View Photo"), systemImage: "photo", perform: viewPhoto))
        }
        return entries
    }
}

/// What a long-press on a person previews: their photo, name, and what they did.
struct PersonPeek: View {
    let person: MediaPerson

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: person.largeImageURL ?? person.imageURL, aspectRatio: 1)

            Text(person.name)
                .font(.subheadline.weight(.medium))

            if let subtitle = person.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: ItemPeek.width)
    }
}

/// A person's photo filling the screen. Tap it, or the close button, to dismiss.
struct PhotoViewer: View {
    let person: MediaPerson

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedAsyncImage(url: person.largeImageURL ?? person.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .empty:
                    ProgressView().tint(.white)
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityLabel(person.name)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding()
            .accessibilityLabel("Close")
        }
        .environment(\.colorScheme, .dark)
    }
}

/// One person: a round portrait, their name, and what they did.
struct PersonCard: View {
    let person: MediaPerson

    /// The portrait's width and height.
    let size: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Two lines each, or three at accessibility sizes, where a name takes more of them.
        let lines = dynamicTypeSize.isAccessibilitySize ? 3 : 2

        VStack(spacing: 6) {
            PersonPortrait(person: person, size: size)

            Text(person.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = person.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(lines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

#if os(tvOS)
/// A person in the Cast and Crew row on tvOS, built the way the system's own lockups are: a borderless button whose label is
/// the portrait and then the name and role as separate views, not wrapped in a stack. The style lifts and tilts the portrait
/// and moves the text out of its way as it grows, and `buttonBorderShape(.circle)` gives that effect a round shape in place
/// of the square platter.
struct TVPersonButton: View {
    let person: MediaPerson

    /// The portrait's width and height, which is also the width of the text under it.
    let size: CGFloat

    let open: () -> Void
    let viewPhoto: () -> Void

    var body: some View {
        Button(action: open) {
            PersonPortrait(person: person, size: size)
                .hoverEffect(.highlight)

            // The same height for every card, room for a two-line name and a one-line role, whatever this one has. Cards of
            // different heights make the page scroll to a different place for each, so it overscrolls on the first and snaps
            // back on the next.
            ZStack(alignment: .top) {
                VStack(spacing: 2) {
                    Text(verbatim: "1\n2").font(.subheadline.weight(.medium))
                    Text(verbatim: "1").font(.caption)
                }
                .hidden()
                .accessibilityHidden(true)

                VStack(spacing: 2) {
                    Text(person.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = person.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: size)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .multilineTextAlignment(.center)
        .contextMenu {
            ItemActionButtons(entries: person.menuEntries(open: open, viewPhoto: viewPhoto))
        }
    }
}
#endif
