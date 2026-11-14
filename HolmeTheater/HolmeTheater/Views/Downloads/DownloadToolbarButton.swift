// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// The download button that appears on detail screens and in toolbars, its progress ring, and the questions it raises.

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
        if item.isDownloadGroup { return .download(item) }
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

extension MediaItem {
    /// Whether downloading it means downloading several movies or episodes, so it's asked about first: a show, a season, a
    /// collection or a playlist.
    var isDownloadGroup: Bool { kind == .season || kind == .series || kind == .collection || kind == .playlist }
}

/// The toolbar button for downloading a movie, episode, season or show, and for seeing and managing what's been done.
///
/// Owns no alerts; set `prompt` and attach ``SwiftUICore/View/downloadPrompts(_:)`` to the screen, since an alert
/// attached to a toolbar button isn't reliably shown.
struct DownloadToolbarButton: View {
    let item: MediaItem
    @Binding var prompt: DownloadPrompt?
    /// Whether the button grows into a pill with its name while it has focus, like the hero's other round buttons. tvOS only.
    var expandsOnFocus = false

    @Environment(AppModel.self) private var appModel
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    private var downloads: DownloadManager { appModel.downloads }
    private var isContainer: Bool { item.isDownloadGroup }

    /// What the button says before anything is downloaded.
    private var noneTitle: LocalizedStringKey {
        if item.kind == .collection || item.kind == .playlist { return "Download All" }
        return isContainer ? "Download All Episodes" : "Download"
    }

    var body: some View {
        #if os(tvOS)
        if expandsOnFocus {
            content
                .focused($isFocused)
                // A circle at rest, a pill once there's a name beside the icon.
                .buttonBorderShape(isFocused ? .capsule : .circle)
                .animation(.easeOut(duration: 0.2), value: isFocused)
        } else {
            content
        }
        #else
        content
        #endif
    }

    /// A button's icon, with its name beside it while the button is focused and expands.
    @ViewBuilder
    private func label<Icon: View>(_ title: LocalizedStringKey, @ViewBuilder icon: () -> Icon) -> some View {
        #if os(tvOS)
        HStack(spacing: 12) {
            icon()
            if expandsOnFocus && isFocused {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        #else
        icon()
        #endif
    }

    @ViewBuilder
    private var content: some View {
        // Where the download is, not how far along, so the menus below aren't rebuilt with every tick of progress (which
        // makes an open one flash). Only the ring, in its own view, follows the progress.
        switch downloads.stage(of: item) {
        case .none:
            Button(action: start) {
                label(noneTitle) {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .accessibilityLabel(noneTitle)

        case .downloading:
            Menu {
                Button("Pause", systemImage: "pause.circle") { downloads.pause(item) }
                // A show with one season on its way can still have the rest downloaded.
                if downloads.hasEpisodesToDownload(item) {
                    Button("Download Remaining Episodes", systemImage: "arrow.down.circle", action: start)
                }
                // Only what's unfinished: a show's or season's finished episodes stay.
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) { downloads.cancel(item) }
            } label: {
                label("Downloading") {
                    DownloadProgressLabel(item: item)
                }
            }
            .accessibilityLabel("Downloading")

        case .paused:
            Menu {
                Button("Resume Download", systemImage: "play.circle") { downloads.resume(item) }
                if downloads.hasEpisodesToDownload(item) {
                    Button("Download Remaining Episodes", systemImage: "arrow.down.circle", action: start)
                }
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) { downloads.cancel(item) }
            } label: {
                label("Download Paused") {
                    Image(systemName: "pause.circle")
                }
            }
            .accessibilityLabel("Download Paused")

        case .partial:
            Menu {
                Button("Download Remaining Episodes", systemImage: "arrow.down.circle", action: start)
                Button("Remove Downloads", systemImage: "trash", role: .destructive) { prompt = .remove(item) }
            } label: {
                label("Partly Downloaded") {
                    Image(systemName: "arrow.down.circle.dotted")
                }
            }
            .accessibilityLabel("Partly Downloaded")

        case .downloaded:
            Menu {
                Button(isContainer ? "Remove Downloads" : "Remove Download", systemImage: "trash", role: .destructive) {
                    prompt = .remove(item)
                }
            } label: {
                label("Downloaded") {
                    Image(systemName: "arrow.down.circle.fill")
                }
            }
            .tint(.blue)
            .accessibilityLabel("Downloaded")
        }
    }

    private func start() {
        prompt = DownloadPrompt.start(item, downloads: downloads)
    }
}

/// The download button's ring for an item, redrawn as its progress changes. Separate from the button, so only this follows
/// the progress, and the button's menu isn't rebuilt with every tick.
private struct DownloadProgressLabel: View {
    let item: MediaItem

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let progress: Double = if case .downloading(let value) = appModel.downloads.status(of: item) { value } else { 0 }
        DownloadProgressRing(progress: progress)
            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// A circle that fills as a download progresses, with an arrow inside. The size of the symbol it stands in for: a button's
/// other states show an SF Symbol, which is bigger on Apple TV than in a toolbar, and a ring that stayed small there left
/// the button smaller than its neighbors.
private struct DownloadProgressRing: View {
    let progress: Double

    #if os(tvOS)
    private static let diameter: CGFloat = 36
    private static let lineWidth: CGFloat = 3.5
    private static let arrowSize: CGFloat = 15
    #else
    private static let diameter: CGFloat = 22
    private static let lineWidth: CGFloat = 2.5
    private static let arrowSize: CGFloat = 9
    #endif

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.4), lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(.tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down")
                .font(.system(size: Self.arrowSize, weight: .bold))
        }
        .frame(width: Self.diameter, height: Self.diameter)
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
                        if item.isDownloadGroup {
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
                    if item.kind == .collection || item.kind == .playlist {
                        Text("Every movie and episode in \(item.title) will be saved to this device.")
                    } else if let count = item.episodeCount {
                        Text("\(count) episodes of \(item.kind == .season ? item.seasonTitle : item.title) will be saved to this device.")
                    } else {
                        Text("Every episode of \(item.title) will be saved to this device.")
                    }
                case .remove(let item) where item.kind == .collection || item.kind == .playlist:
                    Text("The saved videos and details of everything in \(item.title) will be deleted from this device, including any you downloaded separately. They stay on your server.")
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
