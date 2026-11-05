// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Lets the user set up the home screen: the carousel, which sections show and in what order, and which libraries
/// each one takes from.
struct HomeSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.homeSettings

        List {
            Section {
                Toggle("Show Carousel", isOn: $settings.showsHero)
                if settings.showsHero {
                    Picker("Show", selection: $settings.heroOrder) {
                        ForEach(HomeSettings.HeroOrder.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Hide Watched", isOn: $settings.heroHidesWatched)
                    NavigationLink("Libraries") {
                        HomeLibraryChoiceView(
                            title: String(localized: "Carousel"),
                            footer: String(localized: "The carousel takes its items from these libraries.")
                        ) { library in
                            Binding(
                                get: { settings.heroIncludes(library) },
                                set: { settings.setHeroIncluded($0, library: library) }
                            )
                        }
                    }
                }
            } header: {
                Text("Carousel")
            }

            Section {
                Toggle("Combine Up Next with Continue Watching", isOn: $settings.combinesUpNext)
            } footer: {
                Text("Shows the next episode of each show you're watching right after what you've started.")
            }

            Section {
                ForEach(settings.sections) { section in
                    NavigationLink {
                        HomeSectionSettingsView(section: section)
                    } label: {
                        HStack {
                            Text(section == .continueWatching && settings.combinesUpNext
                                 ? String(localized: "Continue Watching and Up Next")
                                 : section.title)
                            Spacer()
                            if !settings.isVisible(section) {
                                Text("Hidden").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                #if os(iOS)
                .onMove { settings.moveSections(from: $0, to: $1) }
                #endif
            } header: {
                Text("Sections")
            } footer: {
                #if os(iOS)
                Text("Tap Edit to change the order of the sections.")
                #else
                Text("Open a section to move it up or down.")
                #endif
            }

            Section {
                Button("Reset Home Screen", role: .destructive) { settings.reset() }
                    .disabled(settings.isDefault)
            }
        }
        .navigationTitle("Home Screen")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

/// One section's settings: whether it shows, and for most, which libraries it takes from.
private struct HomeSectionSettingsView: View {
    let section: HomeSettings.Section
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.homeSettings

        HomeLibraryChoiceView(
            title: section.title,
            footer: section == .onThisDay
                ? String(localized: "Looks for movies and shows with a premiere on today's date in these libraries.")
                : nil,
            visibility: Binding(
                get: { settings.isVisible(section) },
                set: { settings.setVisible($0, for: section) }
            ),
            reordering: (section == .recentlyAdded || section == .recentlyReleased)
                ? LibraryReordering(
                    ordered: { settings.ordered($0, for: section) },
                    move: { settings.moveLibraries($0, from: $1, to: $2, in: section) }
                )
                : nil,
            // Drag to reorder isn't on tvOS, so the section moves from here instead.
            move: {
                #if os(tvOS)
                { settings.moveSection(section, by: $0) }
                #else
                nil
                #endif
            }(),
            canMove: {
                let index = settings.sections.firstIndex(of: section) ?? 0
                return (up: index > 0, down: index < settings.sections.count - 1)
            }()
        ) { library in
            Binding(
                get: { settings.includes(library, in: section) },
                set: { settings.setIncluded($0, library: library, in: section) }
            )
        }
    }
}

/// How a list of libraries is put in the user's order and moved.
private struct LibraryReordering {
    /// The libraries in the order the user chose.
    let ordered: ([Library]) -> [Library]
    /// Moves libraries within the list as it's shown.
    let move: (_ shown: [Library], _ source: IndexSet, _ destination: Int) -> Void
}

/// A list of the movie and TV libraries with a switch on each, and optionally a switch above them for showing the
/// whole thing at all.
private struct HomeLibraryChoiceView: View {
    let title: String
    var footer: String?

    /// Shown as a switch above the libraries, which are dimmed while it's off. Nil leaves the switch out.
    var visibility: Binding<Bool>?

    /// Lets the libraries be moved. Nil keeps them in the server's order.
    var reordering: LibraryReordering?

    /// Moves the section up (`-1`) or down (`1`) the home screen. Nil leaves the buttons out.
    var move: ((Int) -> Void)?

    /// Whether the section has room to move up and down.
    var canMove: (up: Bool, down: Bool) = (false, false)

    /// Makes the switch for a library.
    let isIncluded: (Library) -> Binding<Bool>

    @Environment(AppModel.self) private var appModel
    @State private var libraries: [Library]?
    @State private var failed = false

    init(
        title: String,
        footer: String? = nil,
        visibility: Binding<Bool>? = nil,
        reordering: LibraryReordering? = nil,
        move: ((Int) -> Void)? = nil,
        canMove: (up: Bool, down: Bool) = (false, false),
        isIncluded: @escaping (Library) -> Binding<Bool>
    ) {
        self.title = title
        self.footer = footer
        self.visibility = visibility
        self.reordering = reordering
        self.move = move
        self.canMove = canMove
        self.isIncluded = isIncluded
    }

    var body: some View {
        List {
            if let visibility {
                Section {
                    Toggle("Show on Home Screen", isOn: visibility)
                }
            }

            if let move {
                Section("Order") {
                    Button("Move Up") { move(-1) }
                        .disabled(!canMove.up)
                    Button("Move Down") { move(1) }
                        .disabled(!canMove.down)
                }
            }

            Section {
                if let libraries {
                    let shown = reordering?.ordered(libraries) ?? libraries
                    ForEach(shown) { library in
                        #if os(tvOS)
                        if let reordering {
                            // No drag to reorder on tvOS, so each library has buttons to move it.
                            let index = shown.firstIndex(of: library) ?? 0
                            HStack {
                                Toggle(library.name, isOn: isIncluded(library))
                                Button("Move Up", systemImage: "chevron.up") {
                                    reordering.move(shown, IndexSet(integer: index), index - 1)
                                }
                                .disabled(index == 0)
                                Button("Move Down", systemImage: "chevron.down") {
                                    reordering.move(shown, IndexSet(integer: index), index + 2)
                                }
                                .disabled(index == shown.count - 1)
                            }
                            .labelStyle(.iconOnly)
                        } else {
                            Toggle(library.name, isOn: isIncluded(library))
                        }
                        #else
                        Toggle(library.name, isOn: isIncluded(library))
                        #endif
                    }
                    #if os(iOS)
                    .onMove { source, destination in reordering?.move(shown, source, destination) }
                    #endif
                    if libraries.isEmpty {
                        Text("No movie or TV libraries").foregroundStyle(.secondary)
                    }
                } else if failed {
                    Text("Couldn't load your libraries.").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Libraries")
            } footer: {
                VStack(alignment: .leading) {
                    if let footer { Text(footer) }
                    #if os(iOS)
                    if reordering != nil { Text("Tap Edit to change the order of the libraries.") }
                    #endif
                }
            }
            .disabled(visibility?.wrappedValue == false)
        }
        .navigationTitle(title)
        #if os(iOS)
        .toolbar {
            if reordering != nil { EditButton() }
        }
        #endif
        .task {
            do {
                libraries = try await appModel.service.libraries().filter { $0.kind == .movies || $0.kind == .tvShows }
            } catch {
                failed = true
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
    .environment(AppModel.preview())
}
