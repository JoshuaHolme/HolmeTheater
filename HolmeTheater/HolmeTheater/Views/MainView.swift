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

    private enum Section: Hashable { case home, libraries, downloads, search, account }

    /// With no network, the app opens on what can still be watched.
    @State private var selection = NetworkMonitor.shared.isOnline ? Section.home : Section.downloads
    @State private var homePath = NavigationPath()
    @State private var librariesPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var accountPath = NavigationPath()

    #if os(tvOS)
    /// Whether the "exit the app?" prompt is up.
    @State private var confirmsExit = false
    #endif

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

            #if os(tvOS)
            // Account lives in the sidebar on Apple TV, which has no navigation bar to hold a profile button.
            Tab("Account", systemImage: "person.crop.circle", value: Section.account) {
                NavigationStack(path: $accountPath) {
                    AccountView()
                        .mediaNavigationDestinations()
                }
            }
            #endif
        }
        #if os(tvOS)
        .tabViewStyle(.sidebarAdaptable)
        // Over the whole tab view rather than the Support page, which disables the sidebar too until it's closed.
        .supportCelebration()
        // The Menu button on the remote leaves the app once there's nothing left to go back to, which is easy to do by
        // accident while backing out of a page. Ask first.
        .onExitCommand { confirmsExit = true }
        .alert("Exit Holme Theater?", isPresented: $confirmsExit) {
            Button("Cancel", role: .cancel) {}
            Button("Exit", role: .destructive) { exit(0) }
        }
        #endif
        .overlay(alignment: .top) { toast }
        .animation(.easeInOut, value: appModel.toastMessage)
        .environment(\.openDownloads, OpenDownloadsAction { selection = .downloads })
        .downloadErrorAlert(appModel.downloads)
        // "Go to Show" in the player: once it has closed, open the show in the tab that's showing.
        .onChange(of: appModel.pendingShow) { _, show in
            guard let show else { return }
            appModel.pendingShow = nil
            switch selection {
            case .home: homePath.append(show)
            case .libraries: librariesPath.append(show)
            case .downloads: downloadsPath.append(show)
            case .search: searchPath.append(show)
            case .account: accountPath.append(show)
            }
        }
    }
}

extension MainView {
    /// The message in `appModel.toastMessage`, which goes by itself after a moment.
    @ViewBuilder
    fileprivate var toast: some View {
        if let message = appModel.toastMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .shadow(radius: 8, y: 2)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { appModel.toastMessage = nil }
                }
        }
    }
}

#Preview {
    MainView()
        .environment(AppModel.preview())
}
