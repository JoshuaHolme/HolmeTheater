// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The signed-in app: one tab per top-level area, each with its own navigation stack.
///
/// The account screen isn't a tab. Home puts a profile button in its own scrolling header;
/// Libraries and Search have one in the navigation bar. Both open the account screen in a sheet.
struct MainView: View {
    @Environment(AppModel.self) private var appModel

    private enum Section: Hashable { case home, libraries, search }

    @State private var selection = Section.home
    @State private var homePath = NavigationPath()
    @State private var librariesPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: Section.home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .mediaNavigationDestinations()
                }
            }

            Tab("Libraries", systemImage: "rectangle.stack", value: Section.libraries) {
                NavigationStack(path: $librariesPath) {
                    LibrariesView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: Section.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }
        }
        // "Go to Show" in the player: once it has closed, open the show in the tab that's showing.
        .onChange(of: appModel.pendingShow) { _, show in
            guard let show else { return }
            appModel.pendingShow = nil
            switch selection {
            case .home: homePath.append(show)
            case .libraries: librariesPath.append(show)
            case .search: searchPath.append(show)
            }
        }
    }
}

#Preview {
    MainView()
        .environment(AppModel.preview())
}
