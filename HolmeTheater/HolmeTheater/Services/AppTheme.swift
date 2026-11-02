// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A seasonal or holiday look for the app: a tint, a symbol beside the Home heading, a faint wash of color, and the
/// animated effects that drift across the Home screen. See ``ThemeSettings`` for which one is showing.
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case spring
    case summer
    case fall
    case winter
    case newYears
    case stPatricksDay
    case easter
    case independenceDay
    case halloween
    case thanksgiving
    case christmas

    var id: String { rawValue }

    /// The holidays, in the order they come in a year.
    static let holidays: [AppTheme] = [.newYears, .stPatricksDay, .easter, .independenceDay, .halloween, .thanksgiving, .christmas]

    /// The seasons, in the order they come in a year.
    static let seasons: [AppTheme] = [.winter, .spring, .summer, .fall]

    var title: String {
        switch self {
        case .spring: String(localized: "Spring")
        case .summer: String(localized: "Summer")
        case .fall: String(localized: "Fall")
        case .winter: String(localized: "Winter")
        case .newYears: String(localized: "New Year's")
        case .stPatricksDay: String(localized: "St. Patrick's Day")
        case .easter: String(localized: "Easter")
        case .independenceDay: String(localized: "4th of July")
        case .halloween: String(localized: "Halloween")
        case .thanksgiving: String(localized: "Thanksgiving")
        case .christmas: String(localized: "Christmas")
        }
    }

    var symbolName: String {
        switch self {
        case .spring: "camera.macro"
        case .summer: "sun.max.fill"
        case .fall: "leaf.fill"
        case .winter: "snowflake"
        case .newYears: "party.popper.fill"
        case .stPatricksDay: "rainbow"
        case .easter: "hare.fill"
        case .independenceDay: "flag.fill"
        case .halloween: "moon.stars.fill"
        case .thanksgiving: "fork.knife"
        case .christmas: "gift.fill"
        }
    }

    /// The app's tint while the theme is showing.
    var accent: Color {
        switch self {
        case .spring: Color(red: 0.91, green: 0.45, blue: 0.62)
        case .summer: Color(red: 0.96, green: 0.62, blue: 0.10)
        case .fall: Color(red: 0.83, green: 0.40, blue: 0.13)
        case .winter: Color(red: 0.35, green: 0.62, blue: 0.88)
        case .newYears: Color(red: 0.80, green: 0.64, blue: 0.27)
        case .stPatricksDay: Color(red: 0.13, green: 0.62, blue: 0.33)
        case .easter: Color(red: 0.62, green: 0.50, blue: 0.86)
        case .independenceDay: Color(red: 0.80, green: 0.17, blue: 0.22)
        case .halloween: Color(red: 0.96, green: 0.48, blue: 0.08)
        case .thanksgiving: Color(red: 0.76, green: 0.50, blue: 0.16)
        case .christmas: Color(red: 0.78, green: 0.16, blue: 0.20)
        }
    }

    /// What the Home heading says instead of "Home" while the theme is showing, or nil to leave it. Only holidays have
    /// one; Halloween saves "Trick or Treat!" for the day itself.
    func greeting(on date: Date, calendar: Calendar = .themes) -> String? {
        switch self {
        case .newYears: String(localized: "Happy New Year")
        case .stPatricksDay: String(localized: "Happy St. Patrick's Day")
        case .easter: String(localized: "Happy Easter")
        case .independenceDay: String(localized: "Happy Birthday America")
        case .halloween:
            calendar.dateComponents([.month, .day], from: date) == DateComponents(month: 10, day: 31)
                ? String(localized: "Trick or Treat!")
                : String(localized: "Happy Halloween")
        case .thanksgiving: String(localized: "Happy Thanksgiving")
        case .christmas: String(localized: "Merry Christmas")
        case .spring, .summer, .fall, .winter: nil
        }
    }

    /// Whether the symbol keeps its own colors (the rainbow) rather than taking the theme's.
    var hasMulticolorSymbol: Bool { self == .stPatricksDay }

    /// What drifts across the Home screen: which pieces, in which colors, and how they move.
    var effect: ThemeEffect {
        typealias Piece = ThemeEffect.Piece
        switch self {
        case .spring:
            return ThemeEffect(motion: .fly, pieces: [
                Piece(art: .butterfly, color: Color(red: 0.95, green: 0.55, blue: 0.15)),
                Piece(art: .butterfly, color: Color(red: 0.40, green: 0.65, blue: 0.95)),
                Piece(art: .butterfly, color: Color(red: 1, green: 0.82, blue: 0.28)),
                Piece(art: .butterfly, color: Color(red: 0.95, green: 0.55, blue: 0.75))
            ])
        case .summer:
            return ThemeEffect(motion: .drift, pieces: [
                Piece(art: .firefly, color: Color(red: 1, green: 0.86, blue: 0.40)),
                Piece(art: .firefly, color: Color(red: 0.95, green: 1, blue: 0.55))
            ])
        case .fall, .thanksgiving:
            return ThemeEffect(motion: .flutter, pieces: [
                Piece(art: .symbol("leaf.fill"), color: Color(red: 0.85, green: 0.38, blue: 0.10)),
                Piece(art: .symbol("leaf.fill"), color: Color(red: 0.72, green: 0.22, blue: 0.12)),
                Piece(art: .symbol("leaf.fill"), color: Color(red: 0.90, green: 0.64, blue: 0.16)),
                Piece(art: .symbol("leaf.fill"), color: Color(red: 0.58, green: 0.36, blue: 0.16))
            ])
        case .winter:
            return ThemeEffect(motion: .fall, pieces: [Piece(art: .symbol("snowflake"), color: Self.snow)])
        case .christmas:
            return ThemeEffect(motion: .fall, pieces: [Piece(art: .symbol("snowflake"), color: Self.snow)], hasLights: true)
        case .newYears:
            return ThemeEffect(motion: .confetti, pieces: [
                Piece(art: .confetti, color: Color(red: 0.93, green: 0.78, blue: 0.38)),
                Piece(art: .confetti, color: Color(red: 0.85, green: 0.68, blue: 0.30)),
                Piece(art: .confetti, color: Color(red: 0.96, green: 0.90, blue: 0.70)),
                Piece(art: .confetti, color: Color(red: 0.80, green: 0.80, blue: 0.84))
            ])
        case .stPatricksDay:
            return ThemeEffect(motion: .flutter, pieces: [
                Piece(art: .clover, color: Color(red: 0.16, green: 0.62, blue: 0.30), weight: 2),
                Piece(art: .clover, color: Color(red: 0.30, green: 0.75, blue: 0.35), weight: 2),
                Piece(art: .clover, color: Color(red: 0.10, green: 0.48, blue: 0.24))
            ])
        case .easter:
            return ThemeEffect(motion: .flutter, pieces: [
                Piece(art: .egg(.stripes), color: Color(red: 0.76, green: 0.66, blue: 0.96)),
                Piece(art: .egg(.zigzag), color: Color(red: 1, green: 0.74, blue: 0.56)),
                Piece(art: .egg(.zigzag), color: Color(red: 0.56, green: 0.84, blue: 0.70)),
                Piece(art: .egg(.stripes), color: Color(red: 1, green: 0.68, blue: 0.78)),
                Piece(art: .egg(.zigzag), color: Color(red: 0.98, green: 0.86, blue: 0.48)),
                Piece(art: .egg(.stripes), color: Color(red: 0.56, green: 0.74, blue: 0.96))
            ])
        case .independenceDay:
            return ThemeEffect(motion: .drift, pieces: [
                Piece(art: .symbol("star.fill"), color: Color(red: 0.86, green: 0.20, blue: 0.24), weight: 2),
                Piece(art: .symbol("star.fill"), color: Self.snow),
                Piece(art: .symbol("star.fill"), color: Color(red: 0.22, green: 0.36, blue: 0.80), weight: 2),
                Piece(art: .symbol("sparkle"), color: Self.snow)
            ])
        case .halloween:
            return ThemeEffect(motion: .fly, pieces: [Piece(art: .bat, color: Self.bat)])
        }
    }

    /// White on a dark background; a pale icy blue on a light one, where white would disappear.
    private static let snow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : UIColor(red: 0.60, green: 0.74, blue: 0.90, alpha: 1)
    })

    /// Near black, or on a dark background a dusky purple, so the bats still show against it.
    private static let bat = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.46, green: 0.36, blue: 0.56, alpha: 1)
            : UIColor(red: 0.14, green: 0.10, blue: 0.18, alpha: 1)
    })

    /// The date of a holiday in `year`, or nil for a season.
    func holidayDate(in year: Int, calendar: Calendar) -> Date? {
        let components: DateComponents
        switch self {
        case .newYears: components = DateComponents(year: year, month: 1, day: 1)
        case .stPatricksDay: components = DateComponents(year: year, month: 3, day: 17)
        case .easter: components = Self.easter(in: year)
        case .independenceDay: components = DateComponents(year: year, month: 7, day: 4)
        case .halloween: components = DateComponents(year: year, month: 10, day: 31)
        // The fourth Thursday of November.
        case .thanksgiving: components = DateComponents(year: year, month: 11, weekday: 5, weekdayOrdinal: 4)
        case .christmas: components = DateComponents(year: year, month: 12, day: 25)
        case .spring, .summer, .fall, .winter: return nil
        }
        return calendar.date(from: components)
    }

    /// Easter Sunday in `year`, by the anonymous Gregorian algorithm.
    private static func easter(in year: Int) -> DateComponents {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return DateComponents(year: year, month: month, day: day)
    }

    /// The holiday a holiday's window can start right after, as Christmas can after Thanksgiving.
    var precedingHoliday: AppTheme? {
        self == .christmas ? .thanksgiving : nil
    }

    /// When the theme shows, unless the user has changed it.
    var defaultWindow: ThemeWindow {
        switch self {
        case .spring: .dates(start: MonthDay(month: 3, day: 20), end: MonthDay(month: 6, day: 20))
        case .summer: .dates(start: MonthDay(month: 6, day: 21), end: MonthDay(month: 9, day: 21))
        case .fall: .dates(start: MonthDay(month: 9, day: 22), end: MonthDay(month: 12, day: 20))
        case .winter: .dates(start: MonthDay(month: 12, day: 21), end: MonthDay(month: 3, day: 19))
        case .newYears: .around(start: .daysBefore(1), daysAfter: 0)
        case .stPatricksDay: .around(start: .daysBefore(3), daysAfter: 0)
        case .easter: .around(start: .daysBefore(7), daysAfter: 1)
        case .independenceDay: .around(start: .daysBefore(3), daysAfter: 1)
        case .halloween: .around(start: .daysBefore(30), daysAfter: 0)
        case .thanksgiving: .around(start: .daysBefore(7), daysAfter: 1)
        case .christmas: .around(start: .dayAfterEnd(of: .thanksgiving), daysAfter: 5)
        }
    }
}

/// A day of the year, such as March 20.
struct MonthDay: Codable, Hashable, Comparable {
    var month: Int
    var day: Int

    init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.month, .day], from: date)
        self.init(month: components.month ?? 1, day: components.day ?? 1)
    }

    static func < (lhs: MonthDay, rhs: MonthDay) -> Bool {
        (lhs.month, lhs.day) < (rhs.month, rhs.day)
    }

    /// The day in `year`. February 29 becomes the 28th in a year without one, rather than rolling over into March.
    func date(in year: Int, calendar: Calendar) -> Date? {
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: min(day, days)))
    }
}

extension Calendar {
    /// The calendar themes are worked out in: Gregorian, whichever calendar the user has chosen, since that's the one
    /// the holidays and seasons follow. In the user's time zone and locale.
    static var themes: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = .current
        return calendar
    }
}

/// When a holiday's theme starts.
enum HolidayStart: Codable, Hashable {
    /// This many days before the holiday.
    case daysBefore(Int)
    /// The day after another holiday's theme ends that year, as Christmas can start once Thanksgiving is over.
    case dayAfterEnd(of: AppTheme)
}

/// When a theme shows each year.
enum ThemeWindow: Codable, Hashable {
    /// From one day of the year to another, both included. It may run over New Year, as winter does.
    case dates(start: MonthDay, end: MonthDay)
    /// Around the holiday's date: from `start` to `daysAfter` days after it, both included.
    case around(start: HolidayStart, daysAfter: Int)
}

/// Works out which theme the calendar calls for, and when each one shows.
struct ThemeSchedule {
    /// Every theme's window, including ones left out of the schedule, since one holiday can start after another ends.
    let windows: [AppTheme: ThemeWindow]
    var calendar: Calendar = .themes

    func window(for theme: AppTheme) -> ThemeWindow {
        windows[theme] ?? theme.defaultWindow
    }

    /// The first and last days of a holiday's theme around its date in `year`.
    func interval(for theme: AppTheme, year: Int) -> (start: Date, end: Date, holiday: Date)? {
        interval(for: theme, year: year, depth: 0)
    }

    private func interval(for theme: AppTheme, year: Int, depth: Int) -> (start: Date, end: Date, holiday: Date)? {
        guard let holiday = theme.holidayDate(in: year, calendar: calendar),
              case .around(let start, let daysAfter) = window(for: theme),
              let end = calendar.date(byAdding: .day, value: daysAfter, to: holiday)
        else { return nil }
        let first: Date?
        switch start {
        case .daysBefore(let days):
            first = calendar.date(byAdding: .day, value: -days, to: holiday)
        case .dayAfterEnd(let other):
            // One level only, so two holidays can never wait on each other. However long the other runs, this one
            // still starts by its own day, so it can't be pushed out of the year altogether.
            let afterOther = depth == 0
                ? interval(for: other, year: year, depth: depth + 1).flatMap { calendar.date(byAdding: .day, value: 1, to: $0.end) }
                : nil
            first = afterOther.map { min($0, holiday) }
        }
        guard let first, first <= end else { return nil }
        return (first, end, holiday)
    }

    /// How many days `date` is from the holiday whose theme it falls in, or nil if it isn't in the theme's window.
    private func distance(from date: Date, toHoliday theme: AppTheme) -> Int? {
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        // A window can run over New Year (New Year's Eve, or a long Christmas), so look at the years either side.
        for candidate in [year - 1, year, year + 1] {
            guard let range = interval(for: theme, year: candidate), range.start <= day, day <= range.end else { continue }
            return abs(calendar.dateComponents([.day], from: range.holiday, to: day).day ?? 0)
        }
        return nil
    }

    /// Whether a season's window includes `date`.
    private func seasonContains(_ theme: AppTheme, _ date: Date) -> Bool {
        guard case .dates(let start, let end) = window(for: theme) else { return false }
        let day = MonthDay(date, calendar: calendar)
        return start <= end ? (start <= day && day <= end) : (day >= start || day <= end)
    }

    /// The theme for `date` out of `included`. A holiday beats a season, and of two holidays the one whose date is
    /// closer wins. Nil if nothing covers the date.
    func theme(on date: Date, among included: Set<AppTheme>) -> AppTheme? {
        let holiday = AppTheme.holidays
            .filter(included.contains)
            .compactMap { theme in distance(from: date, toHoliday: theme).map { (theme, $0) } }
            .min { $0.1 < $1.1 }?.0
        if let holiday { return holiday }
        return AppTheme.seasons.filter(included.contains).first { seasonContains($0, date) }
    }

    /// The first and last days of the theme's window that's on now or next, for showing.
    func upcomingDates(for theme: AppTheme, from date: Date) -> (start: Date, end: Date)? {
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        switch window(for: theme) {
        case .dates(let start, let end):
            // Starting this year, unless it runs over New Year and today is in the part after it.
            let today = MonthDay(day, calendar: calendar)
            let startYear = (start > end && today <= end) ? year - 1 : (end < today && start <= end ? year + 1 : year)
            let endYear = start <= end ? startYear : startYear + 1
            guard let first = start.date(in: startYear, calendar: calendar),
                  let last = end.date(in: endYear, calendar: calendar)
            else { return nil }
            return (first, last)
        case .around:
            for candidate in [year - 1, year, year + 1] {
                if let range = interval(for: theme, year: candidate), range.end >= day { return (range.start, range.end) }
            }
            return nil
        }
    }
}
