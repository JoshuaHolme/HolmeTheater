// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// Everything on screen to do with downloads: the badge, the toolbar button, and the Downloads page.

// MARK: - Badge

/// The blue arrow in the corner of downloaded artwork, beside the watched checkmark. For a show or season, it means every
/// episode is downloaded.
struct DownloadedBadge: View {
    let item: MediaItem

    /// Nil in previews that don't provide one, which then show no badge.
    @Environment(DownloadManager.self) private var downloads: DownloadManager?

    var body: some View {
        if downloads?.isDownloaded(item) == true {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title)
                // It sits on artwork that doesn't grow with the text, like the watched badge.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white, .blue)
                .artworkOverlayEdge()
                .padding(6)
                .accessibilityLabel("Downloaded")
        }
    }
}

/// A small download mark for list rows, which have no artwork corner to put the badge in.
struct DownloadedRowIcon: View {
    let item: MediaItem

    @Environment(DownloadManager.self) private var downloads: DownloadManager?

    var body: some View {
        if downloads?.isDownloaded(item) == true {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel("Downloaded")
        }
    }
}

extension View {
    /// Deletes something from a list row: by swiping it on iPhone and iPad, or from its long-press menu on Apple TV, which
    /// has no swiping.
    @ViewBuilder
    fileprivate func deleteAction(_ title: LocalizedStringKey = "Delete", systemImage: String = "trash", perform: @escaping () -> Void) -> some View {
        #if os(tvOS)
        contextMenu {
            Button(title, systemImage: systemImage, role: .destructive, action: perform)
        }
        #else
        swipeActions {
            Button(role: .destructive, action: perform) {
                Label(title, systemImage: systemImage)
            }
        }
        #endif
    }
}

// MARK: - Toolbar button

/// A question about downloads, to be answered in an alert.
enum DownloadPrompt: Identifiable {
    /// Downloading a whole show or season, which can be a lot of space.
    case download(MediaItem)
    /// Deleting a download, or the downloads of a show or season.
    case remove(MediaItem)
    /// The first download on Apple TV, where downloads are experimental, to be accepted before going ahead with `item`.
    case experimental(MediaItem)

    var id: String {
        switch self {
        case .download(let item): "download-\(item.id)"
        case .remove(let item): "remove-\(item.id)"
        case .experimental(let item): "experimental-\(item.id)"
        }
    }

    /// Starts downloading `item`, unless there's a question to ask first, which it returns: the Apple TV notice, or
    /// whether to download a whole show or season, which can be a lot of space.
    static func start(_ item: MediaItem, downloads: DownloadManager) -> DownloadPrompt? {
        if ExperimentalDownloads.needsNotice { return .experimental(item) }
        if item.kind == .season || item.kind == .series { return .download(item) }
        Task { await downloads.download(item) }
        return nil
    }
}

/// Downloads on Apple TV are experimental: the system can delete them, and little of this has been proven on real
/// hardware yet. Everyone is told so before their first one, and the Downloads page keeps saying it.
enum ExperimentalDownloads {
    private static let key = "acknowledgedExperimentalDownloads"

    /// Whether to warn before downloading. Only on Apple TV, and only until the warning has been accepted.
    static var needsNotice: Bool {
        #if os(tvOS)
        !UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }

    static func acknowledge() { UserDefaults.standard.set(true, forKey: key) }

    /// What can go wrong, in plain words. Shown before the first download and on the Downloads page.
    static func limitations(isPermanent: Bool) -> [String] {
        var lines: [String] = []
        if isPermanent {
            lines.append(String(localized: "Downloads should stay until you delete them, but this hasn't been tested enough to promise it."))
        } else {
            lines.append(String(localized: "Apple TV can delete downloads on its own, without warning, when it's running low on storage."))
        }
        lines += [
            String(localized: "Before a trip, open Downloads and check that everything you want is still listed. If something says it was removed, download it again while you still have internet."),
            String(localized: "Leave Holme Theater open on this screen until a download finishes. Downloads can stop if the Apple TV goes to sleep or you leave the app."),
            String(localized: "Some videos have to be converted by your server first, which can take a long time."),
            String(localized: "Without internet you can watch your downloads, but you can't browse or search the rest of your library."),
            String(localized: "What you watch offline is added to your Jellyfin account the next time you're online.")
        ]
        return lines
    }
}

/// The toolbar button for downloading a movie, episode, season or show, and for seeing and managing what's been done.
///
/// Owns no alerts; set `prompt` and attach ``SwiftUICore/View/downloadPrompts(_:)`` to the screen, since an alert
/// attached to a toolbar button isn't reliably shown.
struct DownloadToolbarButton: View {
    let item: MediaItem
    @Binding var prompt: DownloadPrompt?

    @Environment(AppModel.self) private var appModel

    private var downloads: DownloadManager { appModel.downloads }
    private var isContainer: Bool { item.kind == .season || item.kind == .series }

    var body: some View {
        switch downloads.status(of: item) {
        case .none:
            Button(action: start) {
                Image(systemName: "arrow.down.circle")
            }
            .accessibilityLabel(isContainer ? "Download All Episodes" : "Download")

        case .downloading(let progress):
            Menu {
                Button("Pause", systemImage: "pause.circle") { downloads.pause(item) }
                // Only what's unfinished: a show's or season's finished episodes stay.
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) { downloads.cancel(item) }
            } label: {
                DownloadProgressRing(progress: progress)
            }
            .accessibilityLabel("Downloading")
            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))

        case .paused:
            Menu {
                Button("Resume Download", systemImage: "play.circle") { downloads.resume(item) }
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) { downloads.cancel(item) }
            } label: {
                Image(systemName: "pause.circle")
            }
            .accessibilityLabel("Download Paused")

        case .partial:
            Menu {
                Button("Download Remaining Episodes", systemImage: "arrow.down.circle", action: start)
                Button("Remove Downloads", systemImage: "trash", role: .destructive) { prompt = .remove(item) }
            } label: {
                Image(systemName: "arrow.down.circle.dotted")
            }
            .accessibilityLabel("Partly Downloaded")

        case .downloaded:
            Menu {
                Button(isContainer ? "Remove Downloads" : "Remove Download", systemImage: "trash", role: .destructive) {
                    prompt = .remove(item)
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .tint(.blue)
            .accessibilityLabel("Downloaded")
        }
    }

    private func start() {
        prompt = DownloadPrompt.start(item, downloads: downloads)
    }
}

/// A circle that fills as a download progresses, with an arrow inside.
private struct DownloadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.4), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .bold))
        }
        .frame(width: 22, height: 22)
    }
}

extension View {
    /// The alerts behind ``DownloadToolbarButton``'s questions. A download that couldn't be started is reported by
    /// ``downloadErrorAlert(_:)`` instead, once for the whole app.
    func downloadPrompts(_ prompt: Binding<DownloadPrompt?>) -> some View {
        modifier(DownloadPromptsModifier(prompt: prompt))
    }
}

private struct DownloadPromptsModifier: ViewModifier {
    @Binding var prompt: DownloadPrompt?
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        let downloads = appModel.downloads
        content
            .alert(
                title,
                isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                presenting: prompt
            ) { pending in
                switch pending {
                case .download(let item):
                    Button("Download") { Task { await downloads.download(item) } }
                    Button("Cancel", role: .cancel) {}
                case .remove(let item):
                    Button("Remove", role: .destructive) { downloads.remove(item) }
                    Button("Cancel", role: .cancel) {}
                case .experimental(let item):
                    Button("I Understand, Continue") {
                        ExperimentalDownloads.acknowledge()
                        // On to what was asked for: the download itself, or the question about a whole show or season.
                        if item.kind == .season || item.kind == .series {
                            prompt = .download(item)
                        } else {
                            Task { await downloads.download(item) }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { pending in
                switch pending {
                case .experimental:
                    Text(ExperimentalDownloads.limitations(isPermanent: downloads.store.isPermanent).map { "• \($0)" }.joined(separator: "\n\n"))
                case .download(let item):
                    if let count = item.episodeCount {
                        Text("\(count) episodes of \(item.kind == .season ? item.seasonTitle : item.title) will be saved to this device.")
                    } else {
                        Text("Every episode of \(item.title) will be saved to this device.")
                    }
                case .remove(let item):
                    Text("The saved video and details of \(item.kind == .episode || item.kind == .movie ? item.title : "these episodes") will be deleted from this device. They stay on your server.")
                }
            }
    }

    private var title: String {
        switch prompt {
        case .download(let item): item.kind == .season ? String(localized: "Download Season?") : String(localized: "Download Show?")
        case .remove: String(localized: "Remove Download?")
        case .experimental: String(localized: "Downloads on Apple TV Are Experimental")
        case nil: ""
        }
    }
}

// MARK: - Downloads page

/// A show's page within Downloads: the seasons that have downloaded episodes.
private struct DownloadedShowRoute: Hashable { let seriesID: String }

/// A season's page within Downloads: its downloaded episodes.
private struct DownloadedSeasonRoute: Hashable { let seasonID: String }

/// The Downloads tab: what's downloading, then what's saved, organized like the library, with movies, and shows with
/// their seasons and episodes.
struct DownloadsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var playingItem: MediaItem?
    @State private var confirmsDeleteAll = false

    private var downloads: DownloadManager { appModel.downloads }

    private var unfinished: [DownloadRecord] { downloads.records.filter { !$0.isComplete } }
    private var finished: [DownloadRecord] { downloads.records.filter(\.isComplete) }

    private var movies: [DownloadRecord] {
        finished.filter { $0.item.kind == .movie }.sorted { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
    }

    /// The shows with downloaded episodes, in name order.
    private var shows: [(id: String, title: String, episodes: [DownloadRecord])] {
        let episodes = finished.filter { $0.item.kind == .episode }
        return Dictionary(grouping: episodes) { $0.item.seriesID ?? $0.item.seriesTitle ?? $0.id }
            .map { id, records in
                let title = downloads.store.container(id: id)?.title ?? records.first?.item.seriesTitle ?? ""
                return (id, title, records.sorted(by: DownloadRecord.episodeOrder))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static var isAppleTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        List {
            #if os(tvOS)
            Section {
                ExperimentalNotice(isPermanent: downloads.store.isPermanent)
            }

            if downloads.records.isEmpty {
                Section {
                    Text("No downloads yet. Movies and episodes you download appear here.")
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            if !unfinished.isEmpty {
                Section("Downloading") {
                    ForEach(unfinished) { record in
                        UnfinishedDownloadRow(record: record)
                    }
                }
            }

            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { record in
                        SavedDownloadRow(record: record, play: { playingItem = $0 })
                    }
                }
            }

            if !shows.isEmpty {
                Section("TV Shows") {
                    ForEach(shows, id: \.id) { show in
                        NavigationLink(value: DownloadedShowRoute(seriesID: show.id)) {
                            ShowDownloadRow(seriesID: show.id, title: show.title, episodes: show.episodes)
                        }
                        .deleteAction { downloads.remove(ids: show.episodes.map(\.id)) }
                    }
                }
            }

            if !downloads.records.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("Downloads use \(downloads.totalBytes.formatted(.byteCount(style: .file))) on this device.")
                }
            }
        }
        .overlay {
            // On Apple TV the notice has to stay visible, so the empty list says so in the list itself, below it.
            if downloads.records.isEmpty, !Self.isAppleTV {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Movies and episodes you download appear here, and can be watched without a connection.")
                }
            }
        }
        .navigationTitle(Self.isAppleTV ? "Downloads (Experimental)" : "Downloads")
        // The system may have removed files since this was last open.
        .onAppear { downloads.verifyFiles() }
        .toolbar {
            if !downloads.records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !unfinished.isEmpty {
                            Button("Pause All", systemImage: "pause.circle") { downloads.pause() }
                            Button("Resume All", systemImage: "play.circle") { downloads.resume() }
                        }
                        Button("Delete All Downloads", systemImage: "trash", role: .destructive) { confirmsDeleteAll = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Manage Downloads")
                }
            }
        }
        .navigationDestination(for: DownloadedShowRoute.self) { DownloadedShowView(seriesID: $0.seriesID, play: { playingItem = $0 }) }
        .navigationDestination(for: DownloadedSeasonRoute.self) { DownloadedSeasonView(seasonID: $0.seasonID, play: { playingItem = $0 }) }
        .alert("Delete All Downloads?", isPresented: $confirmsDeleteAll) {
            Button("Delete", role: .destructive) { downloads.remove(ids: downloads.records.map(\.id)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything saved on this device is deleted. It all stays on your server.")
        }
        .fullScreenCover(item: $playingItem) { PlayerView(item: $0) }
    }
}

extension View {
    /// The alert for a download that couldn't be started. Attach once, at the root: every screen can start a download,
    /// and the tabs keep their screens alive, so an alert on each would all try to show the one error at once.
    func downloadErrorAlert(_ downloads: DownloadManager) -> some View {
        @Bindable var downloads = downloads
        return alert("Couldn't Download", isPresented: $downloads.errorMessage.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloads.errorMessage ?? "")
        }
    }
}

#if os(tvOS)
/// The warning at the top of the Downloads page on Apple TV: what can go wrong, in plain words.
private struct ExperimentalNotice: View {
    let isPermanent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Downloads on Apple TV are still being tested. Please read this before you rely on them, especially before a trip.")
                .font(.callout.weight(.semibold))

            ForEach(ExperimentalDownloads.limitations(isPermanent: isPermanent), id: \.self) { line in
                Label {
                    Text(line)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 8)
        // So the remote can land here and scroll the list, instead of skipping past text that can't be focused.
        .focusable()
        .accessibilityElement(children: .combine)
    }
}
#endif

/// A download that isn't finished: what it is, how far along, and a button to pause or resume it.
private struct UnfinishedDownloadRow: View {
    let record: DownloadRecord
    @Environment(AppModel.self) private var appModel

    private var downloads: DownloadManager { appModel.downloads }

    var body: some View {
        let item = downloads.localized(record.item)
        HStack(spacing: 12) {
            ArtworkView(url: item.rowArtworkURL, aspectRatio: item.hasWidescreenRowArtwork ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: item.hasWidescreenRowArtwork ? 86 : 43)
                .frame(width: 86)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if record.state == .downloading || record.state == .paused {
                    ProgressView(value: record.progress)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : .secondary)
                    .lineLimit(2)
            }

            Spacer()

            switch record.state {
            case .paused, .failed:
                Button {
                    downloads.resume(item)
                } label: {
                    Image(systemName: record.state == .failed ? "arrow.clockwise.circle" : "play.circle")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(record.state == .failed ? "Retry" : "Resume")
            default:
                Button {
                    downloads.pause(item)
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pause")
            }
        }
        .deleteAction("Cancel", systemImage: "xmark") { downloads.remove(ids: [record.id]) }
    }

    private var statusText: String {
        switch record.state {
        case .queued: String(localized: "Waiting…")
        case .preparing: String(localized: "Preparing…")
        case .downloading:
            if record.bytesExpected > 0 {
                String(localized: "\(record.bytesWritten.formatted(.byteCount(style: .file))) of \(record.isSizeEstimated ? "about " : "")\(record.bytesExpected.formatted(.byteCount(style: .file)))")
            } else {
                record.bytesWritten.formatted(.byteCount(style: .file))
            }
        case .paused: String(localized: "Paused")
        case .failed: record.errorMessage ?? String(localized: "Failed")
        case .completed: ""
        }
    }
}

/// A finished movie or episode: tap to play it, or open its details.
private struct SavedDownloadRow: View {
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
                        .frame(width: item.hasWidescreenRowArtwork ? 86 : 43)
                        .frame(width: 86)
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

/// A show in the Downloads list: its poster, and how much of it is saved.
private struct ShowDownloadRow: View {
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
                .frame(width: 43)
                .frame(width: 86)
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
private struct DownloadedShowView: View {
    let seriesID: String
    let play: (MediaItem) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let downloads = appModel.downloads
        let store = downloads.store
        let episodes = downloads.records.filter { $0.isComplete && $0.item.seriesID == seriesID }
        let seasons = Dictionary(grouping: episodes) { $0.item.seasonID ?? "" }
            .map { (id: $0.key, episodes: $0.value.sorted(by: DownloadRecord.episodeOrder)) }
            .sorted { ($0.episodes.first?.item.seasonNumber ?? 0) < ($1.episodes.first?.item.seasonNumber ?? 0) }
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
                            .frame(width: 43)
                            .frame(width: 86)
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
private struct DownloadedSeasonView: View {
    let seasonID: String
    let play: (MediaItem) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let downloads = appModel.downloads
        let episodes = downloads.records
            .filter { $0.isComplete && $0.item.seasonID == seasonID }
            .sorted(by: DownloadRecord.episodeOrder)
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
