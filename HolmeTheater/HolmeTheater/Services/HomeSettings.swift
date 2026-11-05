// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import SwiftUI

/// How the user has set up the home screen: which sections it has and in what order, which libraries each one draws
/// from, and whether it has a carousel at the top.
///
/// The choices are kept on the device and apply to whoever is signed in. They're stored as what's been left *out*,
/// so a library added on the server later shows up everywhere until it's switched off.
@Observable
final class HomeSettings {
    /// A section of the home screen. A section may be several shelves, one for each library it includes.
    enum Section: String, Codable, CaseIterable, Identifiable {
        case continueWatching
        case nextUp
        case onThisDay
        case recentlyReleased
        case recentlyAdded

        var id: String { rawValue }

        var title: String {
            switch self {
            case .continueWatching: String(localized: "Continue Watching")
            case .nextUp: String(localized: "Up Next")
            case .onThisDay: String(localized: "On This Day")
            case .recentlyReleased: String(localized: "Recently Released")
            case .recentlyAdded: String(localized: "Recently Added")
            }
        }
    }

    /// What the carousel shows.
    enum HeroOrder: String, Codable, CaseIterable, Identifiable {
        case recentlyAdded
        case recentlyReleased
        case random

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recentlyAdded: String(localized: "Recently Added")
            case .recentlyReleased: String(localized: "Recently Released")
            case .random: String(localized: "Random")
            }
        }
    }

    /// Everything that's saved.
    private struct Stored: Codable, Hashable {
        /// The sections, top to bottom.
        var order: [Section] = Section.allCases
        var hidden: Set<Section> = []
        /// Whether Up Next is part of the Continue Watching shelf instead of a shelf of its own.
        var combinesUpNext = false
        /// The IDs of the libraries each section leaves out, by the section's raw value.
        var excludedLibraries: [String: Set<String>] = [:]
        /// The order of each section's libraries, as IDs, by the section's raw value. Optional so settings saved before
        /// this existed still load. A library missing from it goes after the ones in it.
        var libraryOrder: [String: [String]]?
        var showsHero = true
        /// Optional so settings saved before this existed still load; nil is ``HeroOrder/recentlyAdded``.
        var heroOrder: HeroOrder?
        var heroExcludedLibraries: Set<String> = []
        /// Optional so settings saved before this existed still load; nil is off.
        var heroHidesWatched: Bool?
    }

    private var stored: Stored {
        didSet {
            guard stored != oldValue else { return }
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "homeSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        // A section added by a later version goes at the end rather than being missing, and a repeat is dropped.
        var seen = Set<Section>()
        loaded.order = loaded.order.filter { seen.insert($0).inserted }
        loaded.order += Section.allCases.filter { !seen.contains($0) }
        stored = loaded
    }

    /// Changes whenever any setting does.
    var revision: Int { stored.hashValue }

    // MARK: Sections

    /// Whether Up Next is shown as part of Continue Watching.
    var combinesUpNext: Bool {
        get { stored.combinesUpNext }
        set { stored.combinesUpNext = newValue }
    }

    /// Every section, in the user's order, including hidden ones. With Up Next combined, it isn't a section of its own.
    var sections: [Section] {
        stored.order.filter { !($0 == .nextUp && stored.combinesUpNext) }
    }

    /// The sections that are shown, in order.
    var visibleSections: [Section] {
        sections.filter { !stored.hidden.contains($0) }
    }

    func isVisible(_ section: Section) -> Bool {
        !stored.hidden.contains(section)
    }

    func setVisible(_ isVisible: Bool, for section: Section) {
        if isVisible { stored.hidden.remove(section) } else { stored.hidden.insert(section) }
    }

    /// Moves sections within ``sections``, as a list's drag to reorder does.
    func moveSections(from source: IndexSet, to destination: Int) {
        var shown = sections
        shown.move(fromOffsets: source, toOffset: destination)
        // Combined away, Up Next isn't in the list being moved. It goes back in right after the section it followed,
        // so it's where it was if combining is turned off again.
        if stored.combinesUpNext {
            let order = stored.order
            let before = order.firstIndex(of: .nextUp).flatMap { $0 > 0 ? order[$0 - 1] : nil }
            let index = before.flatMap { shown.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            shown.insert(.nextUp, at: index)
        }
        stored.order = shown
    }

    /// Moves `section` one place up (`-1`) or down (`1`) among ``sections``, for screens without drag to reorder.
    func moveSection(_ section: Section, by step: Int) {
        guard let index = sections.firstIndex(of: section), sections.indices.contains(index + step) else { return }
        // A move's destination is the gap it lands in, so moving down skips over the neighbor.
        moveSections(from: IndexSet(integer: index), to: step > 0 ? index + 2 : index - 1)
    }

    // MARK: Libraries

    /// Whether `section` takes items from `library`.
    func includes(_ library: Library, in section: Section) -> Bool {
        !(stored.excludedLibraries[section.rawValue]?.contains(library.id) ?? false)
    }

    func setIncluded(_ isIncluded: Bool, library: Library, in section: Section) {
        var excluded = stored.excludedLibraries[section.rawValue] ?? []
        if isIncluded { excluded.remove(library.id) } else { excluded.insert(library.id) }
        stored.excludedLibraries[section.rawValue] = excluded.isEmpty ? nil : excluded
    }

    /// `libraries` in the order the user chose for `section`. Libraries they haven't placed (new ones) keep the server's
    /// order, after the others.
    func ordered(_ libraries: [Library], for section: Section) -> [Library] {
        guard let order = stored.libraryOrder?[section.rawValue] else { return libraries }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // `sorted` isn't stable, so the server's position breaks ties.
        return libraries.enumerated()
            .sorted { a, b in
                let (x, y) = (position[a.element.id] ?? Int.max, position[b.element.id] ?? Int.max)
                return x != y ? x < y : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Moves libraries within `shown`, which is how `section`'s libraries are listed now, as a list's drag to reorder does.
    func moveLibraries(_ shown: [Library], from source: IndexSet, to destination: Int, in section: Section) {
        var libraries = shown
        libraries.move(fromOffsets: source, toOffset: destination)
        var order = stored.libraryOrder ?? [:]
        order[section.rawValue] = libraries.map(\.id)
        stored.libraryOrder = order
    }

    /// Whether the user has turned off any library for `section`. If not, it takes from every library, so there's no need
    /// to look them up.
    func excludesLibraries(in section: Section) -> Bool {
        !(stored.excludedLibraries[section.rawValue] ?? []).isEmpty
    }

    /// The IDs of the libraries, out of `libraries`, that `section` takes items from. Nil means all of them, which lets
    /// the server skip filtering. Pass every library, not only the ones the settings list: one that isn't listed
    /// can't have been turned off, so it's always included.
    func libraryIDs(for section: Section, among libraries: [Library]) -> [String]? {
        let excluded = stored.excludedLibraries[section.rawValue] ?? []
        guard libraries.contains(where: { excluded.contains($0.id) }) else { return nil }
        return libraries.filter { !excluded.contains($0.id) }.map(\.id)
    }

    /// The libraries, out of `libraries`, that `section` takes items from.
    func libraries(for section: Section, among libraries: [Library]) -> [Library] {
        libraries.filter { includes($0, in: section) }
    }

    // MARK: Carousel

    var showsHero: Bool {
        get { stored.showsHero }
        set { stored.showsHero = newValue }
    }

    /// Which items the carousel shows.
    var heroOrder: HeroOrder {
        get { stored.heroOrder ?? .recentlyAdded }
        set { stored.heroOrder = newValue }
    }

    /// Whether the carousel leaves out movies and shows that have been watched.
    var heroHidesWatched: Bool {
        get { stored.heroHidesWatched ?? false }
        set { stored.heroHidesWatched = newValue ? true : nil }
    }

    func heroIncludes(_ library: Library) -> Bool {
        !stored.heroExcludedLibraries.contains(library.id)
    }

    func setHeroIncluded(_ isIncluded: Bool, library: Library) {
        if isIncluded { stored.heroExcludedLibraries.remove(library.id) } else { stored.heroExcludedLibraries.insert(library.id) }
    }

    // MARK: Reset

    /// Puts the home screen back the way it was before any of this was changed.
    func reset() {
        stored = Stored()
    }

    var isDefault: Bool { stored == Stored() }
}
