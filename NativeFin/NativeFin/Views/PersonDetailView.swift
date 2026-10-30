// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
#if os(iOS)
import WebKit
#endif

/// A person's portrait and name over everything else on the server they're credited on, as posters that open
/// each movie or show.
struct PersonDetailView: View {
    let person: MediaPerson

    @Environment(AppModel.self) private var appModel

    /// Whether the photo is showing full screen.
    @State private var showsPhoto = false

    /// What the server knows about them. Nil until it arrives, or if it can't be fetched; it's only extra.
    @State private var details: PersonDetails?

    /// Whether the sheet with the whole biography is showing.
    @State private var showsBiography = false

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The narrowest a poster gets, wider at larger text sizes so captions stay readable.
    @ScaledMetric(relativeTo: .subheadline) private var posterMinimum: CGFloat = Layout.posterWidth

    /// A watch-state change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// Bumped to reload their movies and shows after a change on the server.
    @State private var reloadCount = 0

    /// The movie or show a tap, peek or "Go to …" is opening.
    @State private var openedItem: MediaItem?

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, destination: nil, state: $watchState) { _ in
            reloadCount += 1
        }
    }

    /// Movies and shows can't be played from here, so only "Go to …" and its peek use this: both open the item.
    private var navigation: ItemNavigation {
        ItemNavigation(open: { openedItem = $0 }, play: { _ in })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The name goes under the portrait at accessibility sizes, where beside it there'd be room for a word.
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 16))) {
                    // Tapping the photo opens it full screen, if there is one.
                    Button { showsPhoto = true } label: {
                        PersonPortrait(person: person, size: 120)
                    }
                    .buttonStyle(.plain)
                    .disabled(person.imageURL == nil)
                    .accessibilityLabel("View Photo of \(person.name)")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name)
                            .font(.title2.bold())
                        if let subtitle = person.subtitle {
                            Text(subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if let details, !details.isEmpty {
                    detailsSection(details)
                }

                AsyncContent(load: {
                    let found = try await appModel.service.items(featuring: person.personID)
                    // The first posters load before the grid shows, so they don't pop in.
                    await ImageCache.shared.preload(found.prefix(9).compactMap(\.item.posterURL))
                    return found
                }, reloadID: reloadCount) { found in
                    credits(found)
                }
            }
            .padding()
        }
        .navigationTitle(person.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fullScreenCover(isPresented: $showsPhoto) { PhotoViewer(person: person) }
        .sheet(isPresented: $showsBiography) {
            ShowOverviewSheet(title: person.name, subtitle: person.subtitle, overview: details?.biography)
        }
        .task { details = try? await appModel.service.details(ofPerson: person.personID) }
        .watchActionAlerts(watchActions)
        .navigationDestination(item: $openedItem) { ItemDetailView(item: $0) }
        #if !os(tvOS)
        .toolbar {
            if let webpage = details?.webpage {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: webpage)
                }
            }
        }
        #endif
    }

    /// When and where they were born (and died), their biography, and a link to read more.
    private func detailsSection(_ details: PersonDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.factLines(for: details).enumerated()), id: \.offset) { _, line in
                // Like the genre line on a show's page: callout size, in the bright primary color.
                Text(line)
                    .font(.callout)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }

            if let biography = details.biography {
                // The same as the description over a show's artwork: cut off, and if it doesn't fit, a MORE
                // button that opens the whole of it.
                TruncatingOverview(text: biography, lineLimit: 3, foreground: .primary) { showsBiography = true }
                    .padding(.top, 4)
            }

            #if os(iOS)
            if let webpage = details.webpage {
                let title = webpage.host()?.contains("imdb") == true ? String(localized: "View on IMDb") : String(localized: "View on TMDb")
                Link(destination: webpage) {
                    Label(title, systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                // Long-press previews the page, and tapping the preview opens it, like the posters.
                .peekAndPop(PeekAndPopSpec(
                    menu: [
                        ItemMenuEntry(id: .openLink, title: String(localized: "Open Link"), systemImage: "arrow.up.right.square") { openURL(webpage) },
                        ItemMenuEntry(id: .copyLink, title: String(localized: "Copy Link"), systemImage: "doc.on.doc") { UIPasteboard.general.url = webpage }
                    ],
                    accessibilityLabel: title,
                    onTap: { openURL(webpage) },
                    onOpen: { openURL(webpage) },
                    peek: WebPagePreview(url: webpage)
                ))
                .padding(.top, 4)
            }
            #endif
        }
    }

    /// e.g. "Born June 1, 1960 (age 65)", "Born in Los Angeles, USA", "Died March 3, 2020 (age 59)".
    private static func factLines(for details: PersonDetails) -> [String] {
        // Birth and death dates are calendar dates stored at midnight UTC, so they're read in UTC.
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let style = Date.FormatStyle(date: .long, time: .omitted, timeZone: utc)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        var lines: [String] = []
        if let born = details.birthDate {
            let end = details.deathDate ?? .now
            let age = calendar.dateComponents([.year], from: born, to: end).year
            // An age is only worth showing for the living; for the dead it's their age at death, shown on that line.
            let ageText = details.deathDate == nil ? age.map { String(localized: " (age \($0))") } ?? "" : ""
            lines.append(String(localized: "Born \(born.formatted(style))") + ageText)
        }
        if let died = details.deathDate {
            let age = details.birthDate.flatMap { calendar.dateComponents([.year], from: $0, to: died).year }
            let ageText = age.map { String(localized: " (age \($0))") } ?? ""
            lines.append(String(localized: "Died \(died.formatted(style))") + ageText)
        }
        if let place = details.birthplace {
            lines.append(String(localized: "Born in \(place)"))
        }
        return lines
    }

    /// The movies, then the shows, each under a heading.
    @ViewBuilder
    private func credits(_ credits: [PersonCredit]) -> some View {
        if credits.isEmpty {
            ContentUnavailableView("Nothing Else on This Server", systemImage: "film.stack")
        } else {
            VStack(alignment: .leading, spacing: 24) {
                posterGrid("Movies", credits.filter { $0.item.kind == .movie })
                posterGrid("Shows", credits.filter { $0.item.kind == .series })
            }
        }
    }

    @ViewBuilder
    private func posterGrid(_ title: LocalizedStringKey, _ credits: [PersonCredit]) -> some View {
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: min(posterMinimum, Layout.posterWidth * 2)), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(credits) { credit in
                        creditPeek(credit)
                    }
                }
            }
        }
    }

    /// A credit that opens its movie or show when tapped, and peeks and pops when long-pressed, with a menu to
    /// open it or change its watch state.
    @ViewBuilder
    private func creditPeek(_ credit: PersonCredit) -> some View {
        let item = credit.item
        let actions = watchActions.actions(for: item, navigation: navigation)
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the item. SwiftUI's preview can't.
        creditCard(credit)
            .peekAndPop(PeekAndPopSpec(
                menu: actions?.menuEntries(for: item) ?? [],
                accessibilityLabel: item.accessibilityDescription,
                onTap: { openedItem = item },
                onOpen: { openedItem = item },
                peek: ItemPeek(item: item)
            ))
        #else
        Button { openedItem = item } label: {
            creditCard(credit)
        }
        .cardLinkStyle()
        .contextMenu {
            ItemActionButtons(entries: actions?.menuEntries(for: item) ?? [])
        } preview: {
            ItemPeek(item: item)
        }
        #endif
    }

    /// A poster with the title and year, then what the person did on it.
    private func creditCard(_ credit: PersonCredit) -> some View {
        let role = credit.roles.compactMap(\.subtitle).joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: credit.item.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .topTrailing) {
                    if credit.item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }

            ItemCaption(item: credit.item)

            if !role.isEmpty {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
/// A web page, loaded for a link's peek.
struct WebPagePreview: View {
    let url: URL

    var body: some View {
        WebPageView(url: url)
            .frame(width: ItemPeek.width, height: 440)
    }
}

struct WebPageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
