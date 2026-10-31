// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The signed-in app: one tab per top-level area, each with its own navigation stack.
///
/// The account screen isn't a tab. Every tab has a profile button in its navigation bar, which opens the account screen
/// in a sheet.
struct MainView: View {
    @Environment(AppModel.self) private var appModel

    private enum Section: Hashable { case home, libraries, downloads, search }

    /// With no network, the app opens on what can still be watched.
    @State private var selection = NetworkMonitor.shared.isOnline ? Section.home : Section.downloads
    @State private var homePath = NavigationPath()
    @State private var librariesPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: Section.home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }

            Tab("Libraries", systemImage: "rectangle.stack", value: Section.libraries) {
                NavigationStack(path: $librariesPath) {
                    LibrariesView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }

            Tab("Downloads", systemImage: "arrow.down.circle", value: Section.downloads) {
                NavigationStack(path: $downloadsPath) {
                    DownloadsView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }
            #if !os(tvOS)
            // How many downloads are on their way; nothing shows when there are none. (Apple TV's tab bar has no badges.)
            .badge(appModel.downloads.activeCount)
            #endif

            Tab("Search", systemImage: "magnifyingglass", value: Section.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }
        }
        .environment(\.openDownloads) { selection = .downloads }
        // "Go to Show" in the player: once it has closed, open the show in the tab that's showing.
        .onChange(of: appModel.pendingShow) { _, show in
            guard let show else { return }
            appModel.pendingShow = nil
            switch selection {
            case .home: homePath.append(show)
            case .libraries: librariesPath.append(show)
            case .downloads: downloadsPath.append(show)
            case .search: searchPath.append(show)
            }
        }
    }
}

#Preview {
    MainView()
        .environment(AppModel.preview())
}
