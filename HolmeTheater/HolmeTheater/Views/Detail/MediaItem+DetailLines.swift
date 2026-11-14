// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// The lines of text a detail hero shows, worked out from the item alone so the view stays about layout and these can be
// tested on their own.

extension MediaItem {
    /// e.g. "Comedy · Drama · HBO": the genres, then the network the show aired on (or a movie's studio). Nil if neither
    /// is known.
    nonisolated var detailLine: String? {
        let parts = genres + [network].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "Jan 5, 2001 · 45m": the day an episode aired and how long it runs. Nil if neither is known.
    nonisolated var episodeInfoLine: String? {
        var parts: [String] = []
        if let aired = airDate {
            // A calendar date stored at midnight UTC, so it's read in UTC or it can land on the day before.
            let utc = TimeZone(identifier: "UTC") ?? .gmt
            parts.append(aired.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc)))
        }
        if let runtime {
            parts.append(Duration.seconds(runtime).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "Ended · 1999–2006" or "Continuing · 2019–Present": whether a show is still running, then the years it has
    /// run. Nil if the server says neither.
    nonisolated var showRunLine: String? {
        let status: String? = switch self.status?.lowercased() {
        case "ended": String(localized: "Ended")
        case "continuing": String(localized: "Continuing")
        default: self.status
        }

        var years: String?
        if let start = year {
            let first = start.formatted(.number.grouping(.never))
            if let end = endYear, end != start {
                years = "\(first)–\(end.formatted(.number.grouping(.never)))"
            } else if endYear == nil, self.status?.lowercased() == "continuing" {
                years = "\(first)–" + String(localized: "Present")
            } else {
                years = first
            }
        }

        let parts = [status, years].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The hero's status line, which depends on what kind of item it is: a season's episode count and year, an episode's
    /// air date and runtime, a movie's year and runtime, or a show's run.
    nonisolated var heroStatusLine: String? {
        switch kind {
        case .season: seasonDetailLine
        case .episode: episodeInfoLine
        case .movie: metadataLine
        default: showRunLine
        }
    }

    /// e.g. "★ 8.7 · 92% Critics": the audience score out of 10, then the critics' score, with the content rating first
    /// when `includingOfficialRating` is set (it's boxed separately on tvOS). Nil if none is known.
    nonisolated func ratingsLine(includingOfficialRating: Bool) -> String? {
        let score = communityRating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) }
        let critics = criticRating.map { String(localized: "\(Int($0.rounded()))% Critics") }
        let parts = [includingOfficialRating ? officialRating : nil, score, critics].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
