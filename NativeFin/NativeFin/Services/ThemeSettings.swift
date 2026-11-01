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
    /// Everything that's saved.
    private struct Stored: Codable, Hashable {
        var isEnabled = true
        var isAutomatic = true
        var showsEffects = true
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
        }
    }

    /// The day the theme is chosen for. Moved on by ``refreshDate()``, so the theme changes at midnight.
    private(set) var today = Date.now

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "themeSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// Catches up with the clock. Call when the app comes back, and when the day or time zone changes.
    func refreshDate() {
        let now = Date.now
        if !Calendar.current.isDate(now, inSameDayAs: today) { today = now }
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
        stored.customWindows[theme] ?? theme.defaultWindow
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
        ThemeSchedule(windows: stored.customWindows)
    }

    // MARK: Active theme

    /// The theme the calendar calls for today, whether or not themes are on.
    var scheduledTheme: AppTheme? {
        schedule.theme(on: today, among: Set(AppTheme.allCases).subtracting(stored.unscheduled))
    }

    /// The theme showing now, or nil for the app's usual look.
    var activeTheme: AppTheme? {
        guard stored.isEnabled else { return nil }
        return stored.isAutomatic ? scheduledTheme : stored.manualTheme
    }

    // MARK: Reset

    /// Puts every theme setting back the way it started.
    func reset() {
        stored = Stored()
    }

    var isDefault: Bool { stored == Stored() }
}
