// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JellyfinAPI

// Turning the SDK's items into the app's `MediaItem`s: their kinds, artwork URLs, cast, chapters and the line that
// describes their picture and sound.

extension JellyfinMediaService {
    /// Maps an SDK item DTO to a `MediaItem`, or nil if it lacks the ID or name every item needs.
    /// - Parameter isExtra: Whether the item came from a list of extras. Those are also recognized by their
    ///   `extraType`, but a server may leave that out.
    static func makeItem(from dto: BaseItemDto, client: JellyfinClient, isExtra: Bool = false) -> MediaItem? {
        guard let id = dto.id, let title = dto.name else { return nil }

        let kind: MediaItem.Kind
        if isExtra || dto.extraType != nil {
            kind = .extra
        } else {
            kind = switch dto.type {
            case .movie: .movie
            case .series: .series
            case .season: .season
            case .episode: .episode
            case .boxSet: .collection
            case .playlist: .playlist
            default: .other
            }
        }

        let runtime = dto.runTimeTicks.map { Double($0) / ticksPerSecond }

        // Only report progress for items actually started; the server also gives a percentage for finished ones.
        var playedFraction: Double?
        if let position = dto.userData?.playbackPositionTicks, position > 0,
           let percentage = dto.userData?.playedPercentage {
            playedFraction = min(max(percentage / 100, 0), 1)
        }

        return MediaItem(
            id: id,
            title: title,
            kind: kind,
            overview: dto.overview,
            year: dto.productionYear,
            runtime: runtime,
            posterURL: posterURL(for: dto, id: id, client: client),
            backdropURL: backdropURL(for: dto, id: id, client: client),
            thumbnailURL: thumbnailURL(for: dto, id: id, isExtra: kind == .extra, client: client),
            playedFraction: playedFraction,
            isPlayed: dto.userData?.isPlayed ?? false,
            seriesTitle: dto.seriesName,
            seasonNumber: dto.parentIndexNumber,
            episodeNumber: dto.indexNumber,
            extraLabel: kind == .extra ? extraLabel(for: dto.extraType) : nil,
            airDate: kind == .episode ? dto.premiereDate : nil,
            seriesID: dto.seriesID,
            seasonID: kind == .episode ? dto.seasonID : nil,
            seasonPosterURL: kind == .episode ? seasonPosterURL(for: dto, client: client) : nil,
            episodeCount: episodeCount(of: dto, kind: kind),
            seasonCount: kind == .series ? dto.childCount : nil,
            unwatchedEpisodeCount: kind == .series || kind == .season ? dto.userData?.unplayedItemCount : nil,
            logoURL: logoURL(for: dto, id: id, client: client),
            genres: dto.genres ?? [],
            // A show's first studio is its original network. A movie's is its first listed studio, which the app
            // shows in the same place, as the "network" line under the title.
            network: kind == .series || kind == .movie ? dto.studios?.first?.name : nil,
            officialRating: dto.officialRating,
            communityRating: dto.communityRating.map(Double.init),
            criticRating: dto.criticRating.map(Double.init),
            technicalLine: technicalLine(of: dto),
            status: dto.status,
            endYear: dto.endDate.map { Calendar.utc.component(.year, from: $0) },
            tagline: dto.taglines?.first(where: { !$0.isEmpty }),
            trailerURL: dto.remoteTrailers?.lazy.compactMap { $0.url.flatMap(webURL(from:)) }.first,
            isFavorite: dto.userData?.isFavorite ?? false,
            people: people(of: dto, client: client),
            chapters: chapters(of: dto, id: id, client: client),
            dateAdded: dto.dateCreated,
            releaseDate: dto.premiereDate,
            sortName: dto.sortName,
            lastPlayedDate: dto.userData?.lastPlayedDate,
            playlistEntryID: dto.playlistItemID
        )
    }

    /// The item's chapters, with a still for each that has one.
    private static func chapters(of dto: BaseItemDto, id: String, client: JellyfinClient) -> [MediaChapter] {
        (dto.chapters ?? []).enumerated().map { index, chapter in
            MediaChapter(
                name: chapter.name ?? "",
                start: Double(chapter.startPositionTicks ?? 0) / ticksPerSecond,
                imageURL: chapter.imageTag.flatMap {
                    client.url(path: "/Items/\(id)/Images/Chapter/\(index)?maxWidth=\(backdropWidth / 4)&tag=\($0)")
                }
            )
        }
    }

    /// The item's own logo, falling back to its parent's (a series' logo, for its seasons and episodes).
    private static func logoURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        if let tag = dto.imageTags?[ImageType.logo.rawValue] {
            return imageURL(itemID: id, type: .logo, tag: tag, width: logoWidth, client: client)
        }
        if let parentID = dto.parentLogoItemID, let tag = dto.parentLogoImageTag {
            return imageURL(itemID: parentID, type: .logo, tag: tag, width: logoWidth, client: client)
        }
        return nil
    }

    /// The item's cast and crew, leaving out kinds of credit the app doesn't show (e.g. music credits) and repeats.
    private static func people(of dto: BaseItemDto, client: JellyfinClient) -> [MediaPerson] {
        var seen = Set<String>()
        return (dto.people ?? []).compactMap { person in
            guard let personID = person.id, let name = person.name else { return nil }
            let role: MediaPerson.Role
            switch person.type {
            case .actor, .guestStar: role = .actor
            case .director: role = .director
            case .writer: role = .writer
            case .producer: role = .producer
            case .creator: role = .creator
            case .composer: role = .composer
            default: return nil
            }
            let image = person.primaryImageTag.flatMap {
                imageURL(itemID: personID, type: .primary, tag: $0, width: posterWidth, client: client)
            }
            let largeImage = person.primaryImageTag.flatMap {
                imageURL(itemID: personID, type: .primary, tag: $0, width: largePortraitWidth, client: client)
            }
            let result = MediaPerson(
                personID: personID,
                role: role,
                name: name,
                character: role == .actor ? person.role.flatMap { $0.isEmpty ? nil : $0 } : nil,
                imageURL: image,
                largeImageURL: largeImage
            )
            return seen.insert(result.id).inserted ? result : nil
        }
    }

    /// The URL for a link the server supplied, only if it's a web page. The server is trusted to describe media, not
    /// to choose what the app opens, so a `tel:`, custom-scheme or `file:` link is dropped.
    private static func webURL(from string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else { return nil }
        return url
    }

    /// Whether a provider ID is only letters and digits, as IMDb's (`tt0903747`) and TMDb's are, so it can't change
    /// the path or host of the link it's put into.
    static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// e.g. "Behind the Scenes" for an extra's type, or nil if the server doesn't say.
    private static func extraLabel(for type: ExtraType?) -> String? {
        switch type {
        case .behindTheScenes: String(localized: "Behind the Scenes")
        case .deletedScene: String(localized: "Deleted Scene")
        case .interview: String(localized: "Interview")
        case .featurette: String(localized: "Featurette")
        case .trailer: String(localized: "Trailer")
        case .clip: String(localized: "Clip")
        case .scene: String(localized: "Scene")
        case .short: String(localized: "Short")
        case .sample: String(localized: "Sample")
        case .themeVideo: String(localized: "Theme Video")
        case .themeSong, .unknown, nil: nil
        }
    }

    /// e.g. "4K · Dolby Vision · Dolby Atmos 7.1": the resolution, dynamic range (if not plain SDR) and main audio
    /// of the item's video file. Nil if the item has no streams listed.
    private static func technicalLine(of dto: BaseItemDto) -> String? {
        let streams = dto.mediaStreams ?? dto.mediaSources?.first?.mediaStreams ?? []
        let video = streams.first { $0.type == .video }
        // The default audio track, else the first.
        let audio = streams.first { $0.type == .audio && $0.isDefault == true } ?? streams.first { $0.type == .audio }

        let parts = [video.flatMap(resolutionLabel(of:)), video.flatMap(dynamicRangeLabel(of:)), audio.flatMap(audioLabel(of:))]
        let line = parts.compactMap { $0 }
        return line.isEmpty ? nil : line.joined(separator: " · ")
    }

    /// "4K", "1080p" and so on. It goes by width, because a widescreen film's picture is shorter than its format.
    private static func resolutionLabel(of video: MediaStream) -> String? {
        guard let width = video.width else { return nil }
        switch width {
        case 3500...: return "4K"
        case 2400...: return "1440p"
        case 1800...: return "1080p"
        case 1200...: return "720p"
        default: return String(localized: "SD")
        }
    }

    /// "Dolby Vision", "HDR10+", "HDR10" or "HLG"; nil for ordinary (SDR) video.
    private static func dynamicRangeLabel(of video: MediaStream) -> String? {
        switch video.videoRangeType {
        case .dovi, .doviWithHDR10, .doviWithHLG, .doviWithEL, .doviWithHDR10Plus, .doviWithELHDR10Plus: "Dolby Vision"
        case .hdr10Plus: "HDR10+"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        default: nil
        }
    }

    /// e.g. "Dolby Atmos 7.1", "Dolby Digital Plus 5.1" or "AAC 2.0".
    private static func audioLabel(of audio: MediaStream) -> String? {
        let profile = audio.profile?.lowercased() ?? ""
        let format: String? = switch audio.codec?.lowercased() {
        case "truehd": "Dolby TrueHD"
        case "eac3": "Dolby Digital Plus"
        case "ac3": "Dolby Digital"
        case "dts": profile.contains("ma") ? "DTS-HD MA" : profile.contains("hra") ? "DTS-HD HRA" : "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le": "PCM"
        case .some(let other): other.uppercased()
        case nil: nil
        }

        // An object-based mix is named for what it is, whatever the file's codec.
        let name: String? = switch audio.audioSpatialFormat {
        case .dolbyAtmos: "Dolby Atmos"
        case .dtsx: "DTS:X"
        default: format
        }

        let layout: String? = audio.channels.map { channels in
            switch channels {
            case 1: "1.0"
            case 2: "2.0"
            case 6: "5.1"
            case 8: "7.1"
            default: "\(channels)ch"
            }
        }

        let parts = [name, layout].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// How many episodes a series or season has, or nil for anything else.
    private static func episodeCount(of dto: BaseItemDto, kind: MediaItem.Kind) -> Int? {
        switch kind {
        // A series' child count is its seasons, so only its recursive count is its episodes.
        case .series: dto.recursiveItemCount
        case .season: dto.recursiveItemCount ?? dto.childCount
        default: nil
        }
    }

    /// An image URL on the server. The `tag` makes the URL change when the image does, so caches stay correct.
    static func imageURL(itemID: String, type: ImageType, tag: String, width: Int, client: JellyfinClient) -> URL? {
        client.url(path: "/Items/\(itemID)/Images/\(type.rawValue)?maxWidth=\(width)&tag=\(tag)")
    }

    /// The portrait poster.
    ///
    /// An episode uses its show's poster, because its own image is a widescreen still that looks wrong in a
    /// poster slot (see `thumbnailURL(for:id:client:)`). Everything else uses its own poster, falling back to
    /// its series' poster if it has none.
    private static func posterURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        var ownPoster: URL?
        if let tag = dto.imageTags?[ImageType.primary.rawValue] {
            ownPoster = imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
        }

        var seriesPoster: URL?
        if let seriesID = dto.seriesID, let tag = dto.seriesPrimaryImageTag {
            seriesPoster = imageURL(itemID: seriesID, type: .primary, tag: tag, width: posterWidth, client: client)
        }

        return dto.type == .episode ? (seriesPoster ?? ownPoster) : (ownPoster ?? seriesPoster)
    }

    /// An episode's season's poster. The episode doesn't say whether its season has one (it carries only the show's
    /// image tag), so this asks for it without a tag; if the season has none the request fails, and the page falls back
    /// to the show's poster.
    private static func seasonPosterURL(for dto: BaseItemDto, client: JellyfinClient) -> URL? {
        guard let seasonID = dto.seasonID else { return nil }
        return client.url(path: "/Items/\(seasonID)/Images/\(ImageType.primary.rawValue)?maxWidth=\(posterWidth)")
    }

    /// Widescreen artwork for list rows.
    ///
    /// An episode uses its own still (its primary image). A movie uses its thumb image, falling back to its
    /// backdrop. Everything else has none.
    private static func thumbnailURL(for dto: BaseItemDto, id: String, isExtra: Bool, client: JellyfinClient) -> URL? {
        // An extra's own image is a widescreen frame, so it's used as it is, falling back to a thumb or backdrop.
        if isExtra {
            if let tag = dto.imageTags?[ImageType.primary.rawValue] {
                return imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
            }
            if let tag = dto.imageTags?[ImageType.thumb.rawValue] {
                return imageURL(itemID: id, type: .thumb, tag: tag, width: posterWidth, client: client)
            }
            return backdropURL(for: dto, id: id, client: client)
        }
        switch dto.type {
        case .episode:
            guard let tag = dto.imageTags?[ImageType.primary.rawValue] else { return nil }
            return imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
        case .movie:
            if let tag = dto.imageTags?[ImageType.thumb.rawValue] {
                return imageURL(itemID: id, type: .thumb, tag: tag, width: posterWidth, client: client)
            }
            return backdropURL(for: dto, id: id, client: client)
        default:
            return nil
        }
    }

    /// The item's own backdrop, falling back to its parent's.
    private static func backdropURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        if let tag = dto.backdropImageTags?.first {
            return imageURL(itemID: id, type: .backdrop, tag: tag, width: backdropWidth, client: client)
        }
        if let parentID = dto.parentBackdropItemID, let tag = dto.parentBackdropImageTags?.first {
            return imageURL(itemID: parentID, type: .backdrop, tag: tag, width: backdropWidth, client: client)
        }
        return nil
    }
}

extension Calendar {
    /// A Gregorian calendar in UTC, for dates the server stores as plain calendar dates. Made once: it's read for every
    /// item in a list, and On This Day reads it for every movie and episode on the server.
    nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
}
