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
        WatchActions(service: appModel.service, downloads: appModel.downloads, canManageCollections: appModel.canManageCollections, destination: nil, state: $watchState) { _ in
            reloadCount += 1
        }
    }

    /// Movies and shows can't be played from here, so only "Go to …" and its peek use this: both open the item.
    private var navigation: ItemNavigation {
        ItemNavigation(open: { openedItem = $0 }, play: { _ in })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                #if os(tvOS)
                tvHeader
                #else
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
                #endif

                AsyncContent(load: {
                    let found = try await appModel.service.items(featuring: person.personID)
                    // The first posters load before the grid shows, so they don't pop in.
                    await ImageCache.shared.preload(found.prefix(9).compactMap(\.item.posterURL))
                    return found
                }, reloadID: reloadCount, loadingHeight: Self.creditsLoadingHeight) { found in
                    credits(found)
                }
            }
            .padding()
        }
        #if os(tvOS)
        // tvOS draws the title over the content, doubling the name the header already shows.
        .navigationTitle("")
        #else
        .navigationTitle(person.name)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fullScreenCover(isPresented: $showsPhoto) { PhotoViewer(person: person) }
        .sheet(isPresented: $showsBiography) {
            #if os(tvOS)
            // The glass sheet the show pages use: name and role, the whole biography, then the facts.
            ShowDetailsSheet(title: person.name, tagline: person.subtitle, overview: details?.biography, facts: details.map(Self.detailFacts(for:)) ?? [])
            #else
            ShowOverviewSheet(title: person.name, subtitle: person.subtitle, overview: details?.biography)
            #endif
        }
        .task { details = try? await appModel.service.details(ofPerson: person.personID) }
        .pullToRefresh {
            reloadCount += 1
            if let fresh = try? await appModel.service.details(ofPerson: person.personID) { details = fresh }
        }
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

    /// The height of the spinner while their credits load. On tvOS it's fixed: filling the scroll view's visible area
    /// (the default) makes the layout loop forever there. Nil elsewhere, where filling it works.
    private static var creditsLoadingHeight: CGFloat? {
        #if os(tvOS)
        300
        #else
        nil
        #endif
    }

    /// Space between a credit's caption and the role under it: the caption's own line spacing on tvOS, where the
    /// artwork's gap is much larger.
    private static var captionToRoleSpacing: CGFloat {
        #if os(tvOS)
        2
        #else
        6
        #endif
    }

    /// Space between the header and each row of posters.
    private static var sectionSpacing: CGFloat {
        #if os(tvOS)
        56
        #else
        24
        #endif
    }

    #if os(tvOS)
    /// The same as the player's sheet about a person: a large portrait, and beside it their name, role, where and when
    /// they were born, and a biography that opens in full when selected. The portrait isn't a button here: "View Photo"
    /// is in the cast row's menu, and a focusable portrait is the first thing focus lands on, ahead of the posters.
    private var tvHeader: some View {
        HStack(alignment: .top, spacing: 60) {
            // Built as the cast row's portraits are: a borderless button with a round shape, so the portrait lifts on its own.
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
                        Button { showsBiography = true } label: {
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
                    ForEach(Array(Self.factLines(for: details).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                    }
                    if let biography = details.biography {
                        // Plain text, cut off; the info button has all of it.
                        Text(biography)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .frame(maxWidth: 1100, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // As wide as the screen, so moving up from any poster reaches the portrait or the info button, not only from the
        // posters directly beneath them.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// What the details sheet lists under the biography, as label and value, leaving out what isn't known: when they were
    /// born (with their age, if they're alive), when they died (with their age then), and where they were born.
    static func detailFacts(for details: PersonDetails) -> [(label: String, value: String)] {
        // Birth and death dates are calendar dates stored at midnight UTC, so they're read in UTC.
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let style = Date.FormatStyle(date: .long, time: .omitted, timeZone: utc)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        var facts: [(String, String)] = []
        if let born = details.birthDate {
            var value = born.formatted(style)
            if details.deathDate == nil, let age = calendar.dateComponents([.year], from: born, to: .now).year {
                value += String(localized: " (age \(age))")
            }
            facts.append((String(localized: "Born"), value))
        }
        if let died = details.deathDate {
            var value = died.formatted(style)
            if let born = details.birthDate, let age = calendar.dateComponents([.year], from: born, to: died).year {
                value += String(localized: " (age \(age))")
            }
            facts.append((String(localized: "Died"), value))
        }
        if let place = details.birthplace {
            facts.append((String(localized: "Birthplace"), place))
        }
        return facts
    }
    #endif

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
    static func factLines(for details: PersonDetails) -> [String] {
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
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
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

                #if os(tvOS)
                // A row that scrolls sideways, as in the player's sheet and the show page's shelves.
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                        ForEach(credits) { credit in
                            creditPeek(credit)
                                .cardWidth(Layout.posterWidth)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                #else
                LazyVGrid(columns: [GridItem(.adaptive(minimum: min(posterMinimum, Layout.posterWidth * 2)), spacing: Layout.cardSpacing, alignment: .top)], spacing: Layout.cardSpacing) {
                    ForEach(credits) { credit in
                        creditPeek(credit)
                    }
                }
                #endif
            }
            #if os(tvOS)
            .focusSection()
            #endif
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
        }
        #endif
    }

    /// A poster with the title and year, then what the person did on it.
    private func creditCard(_ credit: PersonCredit) -> some View {
        let role = credit.roles.compactMap(\.subtitle).joined(separator: ", ")

        return VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: credit.item.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .topTrailing) {
                    if credit.item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                // On tvOS the artwork alone lifts when focused, as in the shelves; the caption stays put.
                .focusHighlight()

            // The caption and role are one block, so the gap under the artwork doesn't also open between them.
            VStack(alignment: .leading, spacing: Self.captionToRoleSpacing) {
                ItemCaption(item: credit.item)

                if !role.isEmpty {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
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
