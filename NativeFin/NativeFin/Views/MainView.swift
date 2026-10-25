// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The signed-in app: one tab per top-level area, each with its own navigation stack.
///
/// The account screen isn't a tab. Home puts a profile button in its own scrolling header;
/// Libraries and Search have one in the navigation bar. Both open the account screen in a sheet.
struct MainView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack {
                    HomeView()
                        .mediaNavigationDestinations()
                }
            }

            Tab("Libraries", systemImage: "rectangle.stack") {
                NavigationStack {
                    LibrariesView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }

            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                NavigationStack {
                    SearchView()
                        .mediaNavigationDestinations()
                        .accountButton()
                }
            }
        }
    }
}

#Preview {
    MainView()
        .environment(AppModel.preview())
}
