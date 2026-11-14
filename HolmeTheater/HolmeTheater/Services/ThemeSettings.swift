// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// Whether the app wears a seasonal or holiday theme, and which: picked by the user, or by the calendar from the themes
/// they've left in the schedule.
///
/// Kept on the device. Like ``HomeSettings``, it stores only what's been changed from the defaults: the themes taken
/// out of the schedule and the dates the user moved, so a theme added later is scheduled from the start.
@Observable
final class ThemeSettings {
    /// Everything that's saved. File-private so its saving and loading can sit in an extension below.
    fileprivate struct Stored: Hashable {
        var isEnabled = true
        var isAutomatic = true
        var showsEffects = true
        var showsHolidays = true
        var showsSeasons = true
        var manualTheme: AppTheme = .fall
        var unscheduled: Set<AppTheme> = []
        var customWindows: [AppTheme: ThemeWindow] = [:]
    }

    private var stored: Stored {
        didSet {
            guard stored != oldValue else { return }
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: Self.key)
            }
            updateActiveTheme()
        }
    }

    /// The day the theme is chosen for. Moved on by ``refreshDate()``, so the theme changes at midnight.
    private(set) var today = Date.now {
        didSet { updateActiveTheme() }
    }

    /// The theme the calendar calls for today, whether or not themes are on. Kept up to date rather than worked out on
    /// each read, since views read it often and the schedule takes some date arithmetic.
    private(set) var scheduledTheme: AppTheme?

    /// The theme the settings call for, or nil for the app's usual look.
    private(set) var appliedTheme: AppTheme?

    /// A theme being tried out, which shows in place of the applied one until the preview ends. Nothing is saved.
    var previewTheme: AppTheme?

    /// The theme showing now, or nil for the app's usual look: the one being previewed, if any.
    var activeTheme: AppTheme? { previewTheme ?? appliedTheme }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar = Calendar.themes
    private static let key = "themeSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        updateActiveTheme()
    }

    /// Catches up with the clock. Call when the app comes back, and when the day or time zone changes.
    func refreshDate() {
        let now = Date.now
        if !calendar.isDate(now, inSameDayAs: today) { today = now }
    }

    private func updateActiveTheme() {
        var allowed = Set(AppTheme.allCases).subtracting(stored.unscheduled)
        if !stored.showsHolidays { allowed.subtract(AppTheme.holidays) }
        if !stored.showsSeasons { allowed.subtract(AppTheme.seasons) }
        let scheduled = schedule.theme(on: today, among: allowed)
        let active = stored.isEnabled ? (stored.isAutomatic ? scheduled : stored.manualTheme) : nil
        // Only on a change, so views that read them aren't redrawn for nothing.
        if scheduled != scheduledTheme { scheduledTheme = scheduled }
        if active != appliedTheme { appliedTheme = active }
    }

    // MARK: Switches

    /// Whether any theme shows at all.
    var isEnabled: Bool {
        get { stored.isEnabled }
        set { stored.isEnabled = newValue }
    }

    /// Whether the calendar picks the theme, rather than the user.
    var isAutomatic: Bool {
        get { stored.isAutomatic }
        set { stored.isAutomatic = newValue }
    }

    /// Whether the theme's animated effects (snow, leaves, confetti and so on) drift across the Home screen.
    var showsEffects: Bool {
        get { stored.showsEffects }
        set { stored.showsEffects = newValue }
    }

    /// Whether the calendar can pick a holiday's theme, or a season's. Either can be off, so only the other kind shows.
    var showsHolidays: Bool {
        get { stored.showsHolidays }
        set { stored.showsHolidays = newValue }
    }

    var showsSeasons: Bool {
        get { stored.showsSeasons }
        set { stored.showsSeasons = newValue }
    }

    /// The theme shown when the calendar isn't picking.
    var manualTheme: AppTheme {
        get { stored.manualTheme }
        set { stored.manualTheme = newValue }
    }

    // MARK: Schedule

    func isScheduled(_ theme: AppTheme) -> Bool {
        !stored.unscheduled.contains(theme)
    }

    func setScheduled(_ isScheduled: Bool, for theme: AppTheme) {
        if isScheduled { stored.unscheduled.remove(theme) } else { stored.unscheduled.insert(theme) }
    }

    func window(for theme: AppTheme) -> ThemeWindow {
        schedule.window(for: theme)
    }

    func setWindow(_ window: ThemeWindow, for theme: AppTheme) {
        stored.customWindows[theme] = window == theme.defaultWindow ? nil : window
    }

    func resetWindow(for theme: AppTheme) {
        stored.customWindows[theme] = nil
    }

    func hasCustomWindow(_ theme: AppTheme) -> Bool {
        stored.customWindows[theme] != nil
    }

    /// Every theme's dates as the user has them.
    var schedule: ThemeSchedule {
        ThemeSchedule(windows: stored.customWindows, calendar: calendar)
    }

    // MARK: Reset

    /// Puts every theme setting back the way it started.
    func reset() {
        stored = Stored()
    }

    var isDefault: Bool { stored == Stored() }
}

/// Saved settings load field by field, each falling back to its default. A field added by a later version, or a theme
/// that's since been renamed or removed, then costs only that one setting rather than all of them.
extension ThemeSettings.Stored: Codable {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, isAutomatic, showsEffects, showsHolidays, showsSeasons, manualTheme, unscheduled, customWindows
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        isAutomatic = (try? container.decodeIfPresent(Bool.self, forKey: .isAutomatic)) ?? defaults.isAutomatic
        showsEffects = (try? container.decodeIfPresent(Bool.self, forKey: .showsEffects)) ?? defaults.showsEffects
        showsHolidays = (try? container.decodeIfPresent(Bool.self, forKey: .showsHolidays)) ?? defaults.showsHolidays
        showsSeasons = (try? container.decodeIfPresent(Bool.self, forKey: .showsSeasons)) ?? defaults.showsSeasons
        manualTheme = (try? container.decodeIfPresent(String.self, forKey: .manualTheme)).flatMap { $0 }
            .flatMap(AppTheme.init(rawValue:)) ?? defaults.manualTheme
        // Themes by name, so one this version doesn't know is skipped rather than failing the lot.
        let unscheduledNames = (try? container.decodeIfPresent([String].self, forKey: .unscheduled)) ?? nil
        unscheduled = Set((unscheduledNames ?? []).compactMap(AppTheme.init(rawValue:)))
        let windows = (try? container.decodeIfPresent([String: ThemeWindow].self, forKey: .customWindows)) ?? nil
        customWindows = Dictionary(uniqueKeysWithValues: (windows ?? [:]).compactMap { name, window in
            AppTheme(rawValue: name).map { ($0, window) }
        })
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isAutomatic, forKey: .isAutomatic)
        try container.encode(showsEffects, forKey: .showsEffects)
        try container.encode(showsHolidays, forKey: .showsHolidays)
        try container.encode(showsSeasons, forKey: .showsSeasons)
        try container.encode(manualTheme.rawValue, forKey: .manualTheme)
        try container.encode(unscheduled.map(\.rawValue).sorted(), forKey: .unscheduled)
        // Keyed by name, which JSON keeps as an object, rather than a list of alternating keys and values.
        try container.encode(Dictionary(uniqueKeysWithValues: customWindows.map { ($0.rawValue, $1) }), forKey: .customWindows)
    }
}
