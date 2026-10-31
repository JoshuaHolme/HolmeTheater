// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// How a collection of posters is ordered.
enum PosterSort: CaseIterable, Identifiable {
    case nameAscending, nameDescending
    case addedNewest, addedOldest
    case releasedNewest, releasedOldest
    case ratingHighest, ratingLowest

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .nameAscending: "Name (A to Z)"
        case .nameDescending: "Name (Z to A)"
        case .addedNewest: "Recently Added"
        case .addedOldest: "Oldest Added"
        case .releasedNewest: "Release Date (Newest)"
        case .releasedOldest: "Release Date (Oldest)"
        case .ratingHighest: "Rating (Highest)"
        case .ratingLowest: "Rating (Lowest)"
        }
    }

    /// Whether the order is alphabetical, which is when an A to Z index makes sense.
    var isByName: Bool { self == .nameAscending || self == .nameDescending }

    /// The items in this order. Items with no date or rating always go last, whichever way round it is.
    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .nameAscending: return items.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
        case .nameDescending: return items.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedDescending }
        case .addedNewest: return Self.sorted(items, by: \.dateAdded, newestFirst: true)
        case .addedOldest: return Self.sorted(items, by: \.dateAdded, newestFirst: false)
        case .releasedNewest: return Self.sorted(items, by: \.releaseDate, newestFirst: true)
        case .releasedOldest: return Self.sorted(items, by: \.releaseDate, newestFirst: false)
        case .ratingHighest: return Self.sorted(items, by: \.communityRating, newestFirst: true)
        case .ratingLowest: return Self.sorted(items, by: \.communityRating, newestFirst: false)
        }
    }

    private static func sorted<Value: Comparable>(_ items: [MediaItem], by key: KeyPath<MediaItem, Value?>, newestFirst: Bool) -> [MediaItem] {
        items.sorted { a, b in
            switch (a[keyPath: key], b[keyPath: key]) {
            case let (x?, y?): x == y ? a.sortKey.localizedStandardCompare(b.sortKey) == .orderedAscending : (newestFirst ? x > y : x < y)
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.sortKey.localizedStandardCompare(b.sortKey) == .orderedAscending
            }
        }
    }
}

/// Which items to leave out of a collection of posters.
struct PosterFilter: Equatable {
    enum Watched: CaseIterable, Identifiable {
        case all, unwatched, watched
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .unwatched: "Unwatched"
            case .watched: "Watched"
            }
        }
    }

    /// The only genre to show, or `nil` for all of them.
    var genre: String?

    var watched = Watched.all

    /// The lowest audience score (out of 10) to show, or `nil` for any. Items with no score are left out when set.
    var minimumRating: Double?

    /// How many of the filters are narrowing the list.
    var activeCount: Int {
        (genre != nil ? 1 : 0) + (watched != .all ? 1 : 0) + (minimumRating != nil ? 1 : 0)
    }

    var isActive: Bool { activeCount > 0 }

    func matches(_ item: MediaItem) -> Bool {
        if let genre, !item.genres.contains(genre) { return false }
        switch watched {
        case .all: break
        case .unwatched: if item.isPlayed { return false }
        case .watched: if !item.isPlayed { return false }
        }
        if let minimumRating, (item.communityRating ?? 0) < minimumRating { return false }
        return true
    }
}

private extension MediaItem {
    /// What the item sorts by when ordered by name: its title without a leading "The", "A" or "An", as Jellyfin does.
    var sortKey: String {
        for article in ["the ", "a ", "an "] where title.lowercased().hasPrefix(article) && title.count > article.count {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    /// The letter the item files under in the A to Z index, or "#" if its name doesn't start with one.
    var indexLetter: String {
        guard let first = sortKey.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased().first,
              first.isLetter else { return "#" }
        return String(first)
    }
}

/// A scrolling grid of posters that open their item, with sorting, filtering and an A to Z index down the side.
struct PosterBrowser: View {
    let items: [MediaItem]

    @State private var sort = PosterSort.nameAscending
    @State private var filter = PosterFilter()

    /// The narrowest a poster gets, wider at larger text sizes so captions stay readable.
    @ScaledMetric(relativeTo: .subheadline) private var posterMinimum: CGFloat = Layout.posterWidth

    private var visibleItems: [MediaItem] {
        sort.sorted(items.filter(filter.matches))
    }

    private static let ratingChoices = [5.0, 6.0, 7.0, 8.0, 9.0]

    private var genres: [String] {
        Set(items.flatMap(\.genres)).sorted()
    }

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Nothing Here", systemImage: "film.stack")
        } else {
            let visible = visibleItems
            ScrollViewReader { proxy in
                ScrollView {
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                        } actions: {
                            Button("Clear Filters") { filter = PosterFilter() }
                        }
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: min(posterMinimum, Layout.posterWidth * 2)), spacing: 12, alignment: .top)],
                            spacing: 16
                        ) {
                            ForEach(visible) { item in
                                NavigationLink(value: item) {
                                    PosterCard(item: item)
                                }
                                .cardLinkStyle()
                            }
                        }
                        .padding()
                        #if !os(tvOS)
                        // Room for the index.
                        .padding(.trailing, sort.isByName ? 16 : 0)
                        #endif
                    }
                }
                #if !os(tvOS)
                .overlay(alignment: .trailing) {
                    if sort.isByName && !visible.isEmpty {
                        AlphabetIndex(items: visible, isDescending: sort == .nameDescending) { id in
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
                #endif
            }
            .toolbar { toolbar }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            sortMenu
        }
        ToolbarItem(placement: .primaryAction) {
            filterMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(PosterSort.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            // Every option is its own submenu, so each row says what it changes and what's chosen. Pickers directly
            // in a menu would run together without any names.
            Menu {
                Picker("Watched", selection: $filter.watched) {
                    ForEach(PosterFilter.Watched.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Text("Watched: \(Text(filter.watched.title))")
            }

            Menu {
                Picker("Rating", selection: $filter.minimumRating) {
                    Text("Any").tag(Double?.none)
                    ForEach(Self.ratingChoices, id: \.self) { rating in
                        Text("\(rating.formatted(.number.precision(.fractionLength(0)))) and up").tag(Double?.some(rating))
                    }
                }
            } label: {
                if let rating = filter.minimumRating {
                    Text("Rating: \(rating.formatted(.number.precision(.fractionLength(0)))) and up")
                } else {
                    Text("Rating: Any")
                }
            }

            if !genres.isEmpty {
                Menu {
                    Picker("Genre", selection: $filter.genre) {
                        Text("All Genres").tag(String?.none)
                        ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    if let genre = filter.genre {
                        Text("Genre: \(genre)")
                    } else {
                        Text("Genre: All Genres")
                    }
                }
            }

            if filter.isActive {
                Button("Clear Filters", role: .destructive) { filter = PosterFilter() }
            }
        } label: {
            Image(systemName: filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .overlay(alignment: .topTrailing) {
                    if filter.isActive {
                        Text("\(filter.activeCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: .circle)
                            .offset(x: 8, y: -8)
                    }
                }
                .accessibilityLabel("Filter")
                .accessibilityValue(filter.isActive ? Text("\(filter.activeCount) filters applied") : Text(""))
        }
    }
}

#if !os(tvOS)
/// A column of letters down the screen's edge. Touch one, or drag along them, to jump to the first item under it.
private struct AlphabetIndex: View {
    let items: [MediaItem]

    /// Whether the list runs Z to A, in which case the index does too.
    let isDescending: Bool

    let jump: (MediaItem.ID) -> Void

    /// "#" comes first, because titles that start with a number sort before the letters.
    private var letters: [String] {
        let ascending = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
        return isDescending ? ascending.reversed() : ascending
    }

    /// The first item under each letter that has any, in the order shown.
    private var firstItems: [String: MediaItem.ID] {
        var result: [String: MediaItem.ID] = [:]
        for item in items where result[item.indexLetter] == nil {
            result[item.indexLetter] = item.id
        }
        return result
    }

    @State private var activeLetter: String?

    var body: some View {
        let firstItems = firstItems
        GeometryReader { geometry in
            let rowHeight = geometry.size.height / CGFloat(letters.count)
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: min(11, rowHeight * 0.8), weight: .semibold))
                        .foregroundStyle(firstItems[letter] == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = min(max(Int(value.location.y / rowHeight), 0), letters.count - 1)
                        // Dragging over a letter nothing is filed under goes to the nearest one after it.
                        let target = letters[index...].first { firstItems[$0] != nil }
                            ?? letters[..<index].last { firstItems[$0] != nil }
                        guard let target, target != activeLetter, let id = firstItems[target] else { return }
                        activeLetter = target
                        jump(id)
                    }
                    .onEnded { _ in activeLetter = nil }
            )
        }
        .frame(width: 20)
        .padding(.vertical, 8)
        // Read as a whole by VoiceOver; the grid itself is the accessible way to move through the items.
        .accessibilityHidden(true)
    }
}
#endif

#Preview {
    NavigationStack {
        PosterBrowser(items: MediaItem.previewMovies)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
