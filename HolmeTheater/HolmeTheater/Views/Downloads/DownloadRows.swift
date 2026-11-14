// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// The rows and cards the Downloads page is built from, and the show and season pages it drills into.

/// A download that isn't finished: what it is, how far along, and a button to pause or resume it.
struct UnfinishedDownloadRow: View {
    let record: DownloadRecord
    @Environment(AppModel.self) private var appModel

    private var downloads: DownloadManager { appModel.downloads }

    /// The icon in the pause, resume and retry button. The round button grows with it, so on Apple TV, where the system's
    /// title sizes are large, it's set smaller to keep the button in proportion to its row.
    private static var buttonIconFont: Font {
        #if os(tvOS)
        .system(size: 26, weight: .semibold)
        #else
        .title2
        #endif
    }

    var body: some View {
        let item = downloads.localized(record.item)
        HStack(spacing: 12) {
            ArtworkView(url: item.rowArtworkURL, aspectRatio: item.hasWidescreenRowArtwork ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: item.hasWidescreenRowArtwork ? DownloadRowArt.still : DownloadRowArt.poster)
                .frame(width: DownloadRowArt.still)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                // Every row has all four lines, empty where there's nothing to say, so the rows are the same height whether
                // a download is waiting or moving, or a movie with no show's name.
                Text(item.subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(item.subtitle == nil)
                ProgressView(value: record.state == .downloading || record.state == .paused ? record.progress : 0)
                Text(record.statusDescription)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : .secondary)
                    .lineLimit(2)
            }
            // Takes all the room that's left, so the progress bar runs right up to the buttons. A Spacer here would keep
            // the system's own gap on Apple TV, which is wide, between the two.
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                switch record.state {
                case .paused, .failed:
                    Button {
                        downloads.resume(item)
                    } label: {
                        Image(systemName: record.state == .failed ? "arrow.clockwise.circle" : "play.circle")
                            .font(Self.buttonIconFont)
                    }
                    .roundRowButton()
                    .accessibilityLabel(record.state == .failed ? "Retry" : "Resume")
                default:
                    Button {
                        downloads.pause(item)
                    } label: {
                        Image(systemName: "pause.circle")
                            .font(Self.buttonIconFont)
                    }
                    .roundRowButton()
                    .accessibilityLabel("Pause")
                }

                #if os(tvOS)
                // Apple TV has no swiping, so cancelling has a button here as well as in the long-press menu.
                Button {
                    downloads.remove(ids: [record.id])
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(Self.buttonIconFont)
                }
                .roundRowButton()
                .accessibilityLabel("Cancel Download")
                #endif
            }
        }
        .deleteAction("Cancel", systemImage: "xmark") { downloads.remove(ids: [record.id]) }
    }
}

/// A finished movie or episode: tap to play it, or open its details.
struct SavedDownloadRow: View {
    let record: DownloadRecord
    let play: (MediaItem) -> Void

    /// Whether to name the show above the episode, for rows outside a show's own page.
    var showsEpisodeNumberOnly = false

    @Environment(AppModel.self) private var appModel

    private var downloads: DownloadManager { appModel.downloads }

    var body: some View {
        let item = downloads.localized(record.item)
        HStack(spacing: 12) {
            Button {
                play(item)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: item.rowArtworkURL, aspectRatio: item.hasWidescreenRowArtwork ? 16.0 / 9.0 : 2.0 / 3.0)
                        .frame(width: item.hasWidescreenRowArtwork ? DownloadRowArt.still : DownloadRowArt.poster)
                        .frame(width: DownloadRowArt.still)
                        .overlay(alignment: .bottom) {
                            if let fraction = item.playedFraction {
                                ProgressView(value: fraction)
                                    .artworkOverlayEdge()
                                    .padding(4)
                            }
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.kind == .episode ? episodeTitle(item) : item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(detail(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.showsWatchedBadge {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Watched")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays the download")

            NavigationLink(value: item) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Details")
        }
        .deleteAction { downloads.remove(ids: [record.id]) }
    }

    private func episodeTitle(_ item: MediaItem) -> String {
        if let number = item.episodeNumber { "\(number). \(item.title)" } else { item.title }
    }

    private func detail(_ item: MediaItem) -> String {
        var parts: [String] = []
        if item.kind == .movie, let year = item.year { parts.append(year.formatted(.number.grouping(.never))) }
        if let runtime = item.runtime {
            parts.append(Duration.seconds(runtime).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        parts.append(record.fileSize.formatted(.byteCount(style: .file)))
        return parts.joined(separator: " · ")
    }
}

#if os(tvOS)
/// A show in the Downloads page on Apple TV: its poster, with its name and how much of it is saved beneath, like the rest of
/// the app's posters.
struct ShowDownloadCard: View {
    let seriesID: String
    let title: String
    let episodes: [DownloadRecord]

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let store = appModel.downloads.store
        let poster = (store.container(id: seriesID) ?? episodes.first?.item).map(store.localized)?.posterURL
        let bytes = episodes.reduce(Int64(0)) { $0 + $1.fileSize }
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: poster, aspectRatio: 2.0 / 3.0)
                .focusHighlight()
            VStack(alignment: .leading, spacing: 2) {
                // Two lines for the name, and the count and size each on a line of their own, so none is cut off.
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(episodes.count == 1 ? String(localized: "1 Episode") : String(localized: "\(episodes.count) Episodes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(bytes.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif

/// A show in the Downloads list: its poster, and how much of it is saved.
struct ShowDownloadRow: View {
    let seriesID: String
    let title: String
    let episodes: [DownloadRecord]

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let store = appModel.downloads.store
        let poster = (store.container(id: seriesID) ?? episodes.first?.item).map(store.localized)?.posterURL
        let bytes = episodes.reduce(Int64(0)) { $0 + $1.fileSize }
        HStack(spacing: 12) {
            ArtworkView(url: poster, aspectRatio: 2.0 / 3.0)
                .frame(width: DownloadRowArt.poster)
                .frame(width: DownloadRowArt.still)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text("\(episodes.count) episodes · \(bytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A show within Downloads: its seasons that have downloaded episodes.
struct DownloadedShowView: View {
    let seriesID: String
    let play: (MediaItem) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let downloads = appModel.downloads
        let store = downloads.store
        let seasons = DownloadLibrary.seasons(ofSeries: seriesID, from: downloads.records)
        let episodes = downloads.records.filter { $0.isComplete && $0.item.seriesID == seriesID }
        let show = store.container(id: seriesID).map(store.localized)

        List {
            ForEach(seasons, id: \.id) { season in
                let title = store.container(id: season.id).map { $0.seasonTitle }
                    ?? season.episodes.first?.item.seasonNumber.map { String(localized: "Season \(String($0))") }
                    ?? String(localized: "Episodes")
                let bytes = season.episodes.reduce(Int64(0)) { $0 + $1.fileSize }
                // The season's own poster, else the show's, which every episode carries.
                let poster = (store.container(id: season.id).map(store.localized)?.posterURL)
                    ?? season.episodes.first.map { store.localized($0.item).posterURL } ?? nil
                NavigationLink(value: DownloadedSeasonRoute(seasonID: season.id)) {
                    HStack(spacing: 12) {
                        ArtworkView(url: poster, aspectRatio: 2.0 / 3.0)
                            .frame(width: DownloadRowArt.poster)
                            .frame(width: DownloadRowArt.still)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline.weight(.medium))
                            Text("\(season.episodes.count) episodes · \(bytes.formatted(.byteCount(style: .file)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .deleteAction { downloads.remove(ids: season.episodes.map(\.id)) }
            }
        }
        .overlay {
            if seasons.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(show?.title ?? episodes.first?.item.seriesTitle ?? "")
        .toolbar {
            if let show {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: show) {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Show Details")
                }
            }
        }
    }
}

/// A season within Downloads: its downloaded episodes.
struct DownloadedSeasonView: View {
    let seasonID: String
    let play: (MediaItem) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let downloads = appModel.downloads
        let episodes = DownloadLibrary.episodes(ofSeason: seasonID, from: downloads.records)
        let season = downloads.store.container(id: seasonID).map(downloads.store.localized)

        List {
            ForEach(episodes) { record in
                SavedDownloadRow(record: record, play: play)
            }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(season?.seasonTitle ?? episodes.first?.item.seasonNumber.map { String(localized: "Season \(String($0))") } ?? "")
        .toolbar {
            if let season {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: season) {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Season Details")
                }
            }
        }
    }
}
