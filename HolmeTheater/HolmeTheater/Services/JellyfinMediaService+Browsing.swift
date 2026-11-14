// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Get
import JellyfinAPI

// Browsing: libraries, the home screen's lists, single items, people, genres and search.

extension JellyfinMediaService {
    /// How many similar titles to ask for.
    private static let similarLimit = 20

    func libraries() async throws -> [Library] {
        let (client, session) = try signedIn()
        let request = Paths.getUserViews(parameters: .init(userID: session.userID))
        let result = try await send(request, with: client)
        return (result.items ?? []).compactMap { dto in
            guard let id = dto.id, let name = dto.name else { return nil }
            let kind: Library.Kind = switch dto.collectionType {
            case .movies: .movies
            case .tvshows: .tvShows
            case .music: .music
            default: .other
            }
            let role: Library.Role = switch dto.collectionType {
            case .boxsets: .collections
            case .playlists: .playlists
            default: .library
            }
            return Library(id: id, name: name, kind: kind, role: role)
        }
    }

    func items(in library: Library) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        // Movie and TV libraries are flattened to their top-level items (movies, or series without
        // their episodes). Other kinds list only their immediate children.
        let includeTypes: [BaseItemKind]? = switch library.kind {
        case .movies: [.movie]
        case .tvShows: [.series]
        case .music, .other: nil
        }
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: includeTypes != nil,
            sortOrder: [.ascending],
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: includeTypes,
            sortBy: [.sortName],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    // MARK: Merged pages

    /// Fetches a page that may come from several libraries, which the server can only filter one at a time. With more
    /// than one, each is asked for enough to cover the page, and the results are merged (see ``MergedPaging``).
    ///
    /// What each library sent is kept (see `mergedPrefixes`), so a later page asks each only for what it hasn't sent
    /// yet, rather than everything up to that page again. A first page starts over, which is also how a refresh asks.
    private func page(
        _ list: String,
        from libraryIDs: [String]?,
        offset: Int,
        limit: Int,
        byLastPlayed: Bool = false,
        _ fetch: @escaping @Sendable (_ parentID: String?, _ offset: Int, _ limit: Int) async throws -> [MediaItem]
    ) async throws -> [MediaItem] {
        guard let libraryIDs else { return try await fetch(nil, offset, limit) }
        if libraryIDs.count == 1 { return try await fetch(libraryIDs[0], offset, limit) }

        func key(_ id: String) -> String { "\(list)|\(id)" }
        if offset == 0 {
            for id in libraryIDs { mergedPrefixes[key(id)] = nil }
        }
        let needed = offset + limit
        let starts = libraryIDs.map { ($0, mergedPrefixes[key($0)] ?? MergedPrefix()) }
        let prefixes = try await Self.fetchEach(starts) { start in
            let (id, prefix) = start
            guard prefix.items.count < needed, !prefix.isComplete else { return prefix }
            let wanted = needed - prefix.items.count
            let more = try await fetch(id, prefix.items.count, wanted)
            return MergedPrefix(items: prefix.items + more, isComplete: more.count < wanted)
        }
        for (id, prefix) in zip(libraryIDs, prefixes) { mergedPrefixes[key(id)] = prefix }
        let lists = prefixes.map { Array($0.items.prefix(needed)) }
        return MergedPaging.page(of: lists, offset: offset, limit: limit, byLastPlayed: byLastPlayed)
    }

    func resumeItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        return try await page("resume", from: libraryIDs, offset: offset, limit: limit, byLastPlayed: true) { parentID, offset, limit in
            let request = Paths.getResumeItems(parameters: .init(
                userID: session.userID,
                startIndex: offset,
                limit: limit,
                parentID: parentID,
                fields: Self.itemFields,
                mediaTypes: [.video],
                enableUserData: true
            ))
            return try await self.mapItems(self.send(request, with: client), client: client)
        }
    }

    func nextUpItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        return try await page("nextUp", from: libraryIDs, offset: offset, limit: limit) { parentID, offset, limit in
            let request = Paths.getNextUp(parameters: .init(
                userID: session.userID,
                startIndex: offset,
                limit: limit,
                fields: Self.itemFields,
                parentID: parentID,
                enableUserData: true,
                // Partly watched episodes already show under Continue Watching, and a show you've finished
                // shouldn't come back around.
                enableResumable: false,
                enableRewatching: false
            ))
            return try await self.mapItems(self.send(request, with: client), client: client)
        }
    }

    // MARK: Library lists

    func recentlyAddedItems(in library: Library) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getLatestMedia(parameters: .init(
            userID: session.userID,
            parentID: library.id,
            fields: Self.itemFields,
            enableUserData: true,
            limit: 16
        ))
        // Jellyfin calls this endpoint "latest media" but it returns what was added most recently, not what was
        // released most recently. Unlike the other endpoints, it returns a bare array rather than a query result.
        let dtos = try await send(request, with: client)
        return dtos.compactMap { Self.makeItem(from: $0, client: client) }
    }

    /// The playable kinds a library's flattened lists hold: episodes for a TV library, movies for a movie library,
    /// and whatever's there for anything else.
    private static func playableKinds(of library: Library) -> [BaseItemKind]? {
        switch library.kind {
        case .movies: [.movie]
        case .tvShows: [.episode]
        case .music, .other: nil
        }
    }

    func recentlyAddedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        // Flatten to the individual playable items (episodes or movies) rather than series.
        let includeTypes = Self.playableKinds(of: library)
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            startIndex: offset,
            limit: limit,
            isRecursive: includeTypes != nil,
            sortOrder: [.descending],
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: includeTypes,
            sortBy: [.dateCreated],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func randomItems(in library: Library, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            limit: limit,
            isRecursive: true,
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: library.kind == .tvShows ? [.series] : [.movie],
            sortBy: [.random],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func recentlyReleasedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        let includeTypes = Self.playableKinds(of: library)
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            // Not past today, so what's still to come isn't first in the list.
            maxPremiereDate: .now,
            startIndex: offset,
            limit: limit,
            isRecursive: includeTypes != nil,
            sortOrder: [.descending],
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: includeTypes,
            // Sorted by release date.
            sortBy: [.premiereDate],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func itemsOnThisDay(libraryIDs: [String]?) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        let today = Calendar.current.dateComponents([.month, .day], from: .now)
        guard let month = today.month, let day = today.day else { return [] }
        if let cache = onThisDayCache, cache.month == month, cache.day == day, cache.libraryIDs == libraryIDs {
            return cache.items
        }

        // The server can't filter by month and day, only by date range, so it's asked for every movie and episode and
        // they're filtered here. Shows and seasons are left out; only the episodes released on the day count. Only the
        // little that cards need is requested, since there can be thousands.
        let parentIDs: [String?] = libraryIDs ?? [nil]
        let items = try await Self.fetchEach(parentIDs) { parentID in
            let request = Paths.getItems(parameters: .init(
                userID: session.userID,
                isRecursive: true,
                parentID: parentID,
                fields: [.primaryImageAspectRatio, .childCount, .recursiveItemCount],
                includeItemTypes: [.movie, .episode],
                enableUserData: true
            ))
            return try await self.mapItems(self.send(request, with: client), client: client)
        }.flatMap { $0 }

        let matches = Self.itemsReleased(onMonth: month, day: day, among: items)
        onThisDayCache = (month, day, libraryIDs, matches)
        return matches
    }

    /// The items whose release date falls on a month and day in any year, newest first.
    ///
    /// Premiere dates are calendar dates stored at midnight UTC, so they're read as UTC, not in the user's zone.
    static func itemsReleased(onMonth month: Int, day: Int, among items: [MediaItem]) -> [MediaItem] {
        let calendar = Calendar.utc
        return items
            .filter { item in
                guard let date = item.releaseDate else { return false }
                let components = calendar.dateComponents([.month, .day], from: date)
                return components.month == month && components.day == day
            }
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
    }

    // MARK: Single items

    func items(withIDs ids: [String]) async throws -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            fields: Self.itemFields,
            enableUserData: true,
            ids: ids
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func item(id: String) async throws -> MediaItem {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            // The cast, and the streams that say what the picture and sound are, are big, so only a single item
            // asks for them, not every list.
            fields: Self.itemFields + [.people, .chapters, .mediaSources, .mediaStreams],
            enableUserData: true,
            ids: [id]
        ))
        guard let item = try await mapItems(send(request, with: client), client: client).first else {
            throw MediaServiceError.itemNotFound
        }
        return item
    }

    func similarItems(to item: MediaItem) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request: Request<BaseItemDtoQueryResult>
        switch item.kind {
        case .series:
            request = Paths.getSimilarShows(itemID: item.id, parameters: .init(userID: session.userID, limit: Self.similarLimit, fields: Self.itemFields))
        case .movie:
            request = Paths.getSimilarMovies(itemID: item.id, parameters: .init(userID: session.userID, limit: Self.similarLimit, fields: Self.itemFields))
        default:
            return []
        }
        return try await mapItems(send(request, with: client), client: client).filter { $0.id != item.id }
    }

    func specialFeatures(of item: MediaItem) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let features = try await send(Paths.getSpecialFeatures(itemID: item.id, userID: session.userID), with: client)
        return features.compactMap { Self.makeItem(from: $0, client: client, isExtra: true) }
    }

    func seasonCount(ofSeries id: String) async throws -> Int? {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            fields: [.childCount],
            enableUserData: false,
            ids: [id]
        ))
        return try await send(request, with: client).items?.first?.childCount
    }

    func setFavorite(_ isFavorite: Bool, itemID: String) async throws {
        let (client, session) = try signedIn()
        if isFavorite {
            _ = try await send(Paths.markFavoriteItem(itemID: itemID, userID: session.userID), with: client)
        } else {
            _ = try await send(Paths.unmarkFavoriteItem(itemID: itemID, userID: session.userID), with: client)
        }
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        switch item.kind {
        case .series:
            let request = Paths.getSeasons(
                seriesID: item.id,
                parameters: .init(userID: session.userID, fields: Self.itemFields, enableUserData: true)
            )
            return try await mapItems(send(request, with: client), client: client)
        case .season:
            // A season is just a folder of episodes, so list its children in episode order.
            let request = Paths.getItems(parameters: .init(
                userID: session.userID,
                sortOrder: [.ascending],
                parentID: item.id,
                fields: Self.itemFields,
                sortBy: [.indexNumber],
                enableUserData: true
            ))
            return try await mapItems(send(request, with: client), client: client)
        case .collection:
            // A collection's members, which can be movies or shows. Sorted by release, as a film series is watched.
            let request = Paths.getItems(parameters: .init(
                userID: session.userID,
                sortOrder: [.ascending],
                parentID: item.id,
                fields: Self.itemFields,
                sortBy: [.premiereDate, .sortName],
                enableUserData: true
            ))
            return try await mapItems(send(request, with: client), client: client)
        case .playlist:
            // In the playlist's own order. Each entry carries the ID that removing or moving it needs.
            let request = Paths.getPlaylistItems(
                playlistID: item.id,
                parameters: .init(userID: session.userID, fields: Self.itemFields, enableUserData: true)
            )
            return try await mapItems(send(request, with: client), client: client)
        case .movie, .episode, .extra, .other:
            return []
        }
    }

    func nextEpisode(in series: MediaItem) async throws -> MediaItem? {
        let (client, session) = try signedIn()

        // The server's Next Up for this one show: the episode after the last one watched, or a partly watched
        // one. For a show not yet started it's the first episode. It's empty once the show is finished,
        // because rewatching is off.
        let nextUp = Paths.getNextUp(parameters: .init(
            userID: session.userID,
            limit: 1,
            fields: Self.itemFields,
            seriesID: series.id,
            enableUserData: true,
            enableResumable: true,
            enableRewatching: false
        ))
        if let next = try await mapItems(send(nextUp, with: client), client: client).first {
            return next
        }

        // Finished (or nothing for Next Up to go on): start again from the top. Episodes come in season and
        // episode order; specials (season 0) are skipped unless they're all there is.
        let all = Paths.getEpisodes(seriesID: series.id, parameters: .init(
            userID: session.userID,
            fields: Self.itemFields,
            isMissing: false,
            enableUserData: true
        ))
        let episodes = try await mapItems(send(all, with: client), client: client)
        return Self.firstEpisodeToPlay(among: episodes)
    }

    /// The first episode of a show that's being started over: the first regular one, or the first special if those
    /// are all there is.
    static func firstEpisodeToPlay(among episodes: [MediaItem]) -> MediaItem? {
        episodes.first { ($0.seasonNumber ?? 1) > 0 } ?? episodes.first
    }

    func search(_ query: String) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            limit: 50,
            isRecursive: true,
            searchTerm: query,
            fields: Self.itemFields,
            includeItemTypes: [.movie, .series, .episode],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    // MARK: People and genres

    func details(ofPerson personID: String) async throws -> PersonDetails {
        let (client, session) = try signedIn()
        let dto = try await send(Paths.getItem(itemID: personID, userID: session.userID), with: client)

        func nonEmpty(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }

        return PersonDetails(
            biography: nonEmpty(dto.overview),
            birthDate: dto.premiereDate,
            deathDate: dto.endDate,
            birthplace: nonEmpty(dto.productionLocations?.first),
            webpage: Self.personWebpage(imdbID: nonEmpty(dto.providerIDs?["Imdb"]), tmdbID: nonEmpty(dto.providerIDs?["Tmdb"]))
        )
    }

    /// A person's page on the web: IMDb if the server knows it, otherwise TMDb. Only IDs that are plain letters and
    /// digits are used, so an ID can't change the link's host or path.
    static func personWebpage(imdbID: String?, tmdbID: String?) -> URL? {
        if let imdbID, isPlainID(imdbID) {
            return URL(string: "https://www.imdb.com/name/\(imdbID)")
        }
        if let tmdbID, isPlainID(tmdbID) {
            return URL(string: "https://www.themoviedb.org/person/\(tmdbID)")
        }
        return nil
    }

    func items(featuring personID: String) async throws -> [PersonCredit] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            // Each item's cast tells what the person did on it. The list is small, so it's fine to ask for it.
            fields: Self.itemFields + [.people],
            includeItemTypes: [.movie, .series],
            sortBy: [.sortName],
            enableUserData: true,
            personIDs: [personID]
        ))
        return try await mapItems(send(request, with: client), client: client).map { item in
            var item = item
            let roles = item.people.filter { $0.personID == personID }
            // The cast isn't needed past this point.
            item.people = []
            return PersonCredit(item: item, roles: roles)
        }
    }

    func genres() async throws -> [Genre] {
        let (client, session) = try signedIn()
        let request = Paths.getGenres(parameters: .init(
            includeItemTypes: [.movie, .series],
            userID: session.userID,
            sortBy: [.sortName],
            sortOrder: [.ascending]
        ))
        return try await send(request, with: client).items?.compactMap { dto in
            guard let id = dto.id, let name = dto.name else { return nil }
            let image = dto.imageTags?[ImageType.primary.rawValue].flatMap {
                Self.imageURL(itemID: id, type: .primary, tag: $0, width: Self.posterWidth, client: client)
            }
            return Genre(id: id, name: name, imageURL: image)
        } ?? []
    }

    func items(in genre: Genre) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            fields: Self.itemFields,
            includeItemTypes: [.movie, .series],
            sortBy: [.sortName],
            enableUserData: true,
            genreIDs: [genre.id]
        ))
        return try await mapItems(send(request, with: client), client: client)
    }
}
