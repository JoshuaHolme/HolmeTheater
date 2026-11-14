// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Lets the user set up the home screen: the carousel, which sections show and in what order, and which libraries
/// each one takes from.
struct HomeSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        #if os(tvOS)
        tvBody(appModel.homeSettings)
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    /// Rows of their own, as on the account page: a name and what it's set to, with what a group does beneath it.
    private func tvBody(_ homeSettings: HomeSettings) -> some View {
        @Bindable var settings = homeSettings

        return VStack(alignment: .leading, spacing: 44) {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsHeading(title: "Carousel")
                TVToggleRow(title: "Show Carousel", isOn: $settings.showsHero)
                if settings.showsHero {
                    // Opens the choices, with the one made ticked, as the Settings app's pages of choices do.
                    NavigationLink {
                        HeroOrderChoiceView()
                    } label: {
                        TVSettingsRow(title: "Show", value: LocalizedStringKey(settings.heroOrder.title), showsChevron: true)
                    }
                    .buttonStyle(.card)
                    TVToggleRow(title: "Hide Watched", isOn: $settings.heroHidesWatched)
                    NavigationLink {
                        HomeLibraryChoiceView(
                            title: String(localized: "Carousel"),
                            footer: String(localized: "The carousel takes its items from these libraries.")
                        ) { library in
                            Binding(
                                get: { settings.heroIncludes(library) },
                                set: { settings.setHeroIncluded($0, library: library) }
                            )
                        }
                    } label: {
                        TVSettingsRow(title: "Libraries", showsChevron: true)
                    }
                    .buttonStyle(.card)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                TVToggleRow(title: "Combine Up Next with Continue Watching", isOn: $settings.combinesUpNext)
                TVSettingsCaption(text: "Shows the next episode of each show you're watching right after what you've started.")
            }

            VStack(alignment: .leading, spacing: 16) {
                TVSettingsHeading(title: "Sections")
                ForEach(Array(settings.sections.enumerated()), id: \.element) { index, section in
                    let isVisible = settings.isVisible(section)
                    HStack(spacing: Self.rowButtonGap) {
                        // Opens the section's own settings, such as which libraries it takes from.
                        NavigationLink {
                            HomeSectionSettingsView(section: section)
                        } label: {
                            TVSettingsRow(
                                title: LocalizedStringKey(section == .continueWatching && settings.combinesUpNext
                                    ? String(localized: "Continue Watching and Up Next")
                                    : section.title),
                                showsChevron: true
                            )
                            // A hidden section is dimmed, as well as showing a crossed-out eye.
                            .opacity(isVisible ? 1 : 0.5)
                        }
                        .buttonStyle(.card)

                        // Reordering and hiding don't need the section opened.
                        sectionButton("chevron.up", label: "Move Up") { settings.moveSection(section, by: -1) }
                            .disabled(index == 0)
                        sectionButton("chevron.down", label: "Move Down") { settings.moveSection(section, by: 1) }
                            .disabled(index == settings.sections.count - 1)
                        sectionButton(isVisible ? "eye" : "eye.slash", label: isVisible ? "Hide" : "Show") {
                            settings.setVisible(!isVisible, for: section)
                        }
                    }
                }
                TVSettingsCaption(text: "Use the arrows to move a section, and the eye to show or hide it. Open one to choose which libraries it takes from.")
            }

            Button { settings.reset() } label: {
                TVSettingsRow(title: "Reset Home Screen", isDestructive: true)
            }
            .buttonStyle(.card)
            .disabled(settings.isDefault)
        }
        .tvSettingsPage(title: String(localized: "Home Screen"))
    }

    /// The space between a row and the round buttons beside it. A focused row grows, and a smaller gap has it touch them.
    private static let rowButtonGap: CGFloat = 40

    /// A round button beside a section's row.
    private func sectionButton(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
    #endif

    private var listBody: some View {
        @Bindable var settings = appModel.homeSettings

        return List {
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

#if os(tvOS)
/// The choices for what the carousel shows, as a list with the one chosen ticked. Choosing one goes back.
private struct HeroOrderChoiceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = appModel.homeSettings
        VStack(alignment: .leading, spacing: 16) {
            ForEach(HomeSettings.HeroOrder.allCases) { order in
                Button {
                    settings.heroOrder = order
                    dismiss()
                } label: {
                    TVSettingsRow(title: LocalizedStringKey(order.title), showsCheckmark: settings.heroOrder == order)
                }
                .buttonStyle(.card)
            }
        }
        .tvSettingsPage(title: String(localized: "Carousel"))
    }
}
#endif

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
                : nil
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
        isIncluded: @escaping (Library) -> Binding<Bool>
    ) {
        self.title = title
        self.footer = footer
        self.visibility = visibility
        self.reordering = reordering
        self.isIncluded = isIncluded
    }

    var body: some View {
        content
            .task {
                do {
                    libraries = try await appModel.service.libraries().filter { $0.kind == .movies || $0.kind == .tvShows }
                } catch {
                    failed = true
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvContent
        #else
        listContent
        #endif
    }

    #if os(tvOS)
    /// The libraries as rows of their own, each a switch that shows whether it's on. (Their order is a touch-screen setting.)
    private var tvContent: some View {
        VStack(alignment: .leading, spacing: 44) {
            if let visibility {
                TVToggleRow(title: "Show on Home Screen", isOn: visibility)
            }

            VStack(alignment: .leading, spacing: 16) {
                TVSettingsHeading(title: "Libraries")
                if let libraries {
                    let shown = reordering?.ordered(libraries) ?? libraries
                    ForEach(shown) { library in
                        TVToggleRow(title: LocalizedStringKey(library.name), isOn: isIncluded(library))
                    }
                    if libraries.isEmpty {
                        TVSettingsCaption(text: "No movie or TV libraries")
                    }
                } else if failed {
                    TVSettingsCaption(text: "Couldn't load your libraries.")
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let footer { Text(footer).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24) }
            }
            .disabled(visibility?.wrappedValue == false)
        }
        .tvSettingsPage(title: title)
    }
    #endif

    #if !os(tvOS)
    private var listContent: some View {
        List {
            if let visibility {
                Section {
                    Toggle("Show on Home Screen", isOn: visibility)
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
    }
    #endif
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
    .environment(AppModel.preview())
}
