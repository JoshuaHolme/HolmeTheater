// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Lets the user turn seasonal themes and their animated effects on and off, choose between the calendar picking the
/// theme and picking one themselves, and set which themes the calendar uses and when.
struct ThemeSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the full-screen preview of the Home screen in each theme is showing.
    @State private var showsPreview = false

    var body: some View {
        Group {
            #if os(tvOS)
            tvBody(appModel.themeSettings)
            #else
            listBody
            #endif
        }
        .fullScreenCover(isPresented: $showsPreview) { ThemePreviewView() }
    }

    #if os(tvOS)
    /// Rows of their own, as on the other settings pages, with what each group does beneath it.
    private func tvBody(_ themeSettings: ThemeSettings) -> some View {
        @Bindable var settings = themeSettings

        return VStack(alignment: .leading, spacing: 44) {
            VStack(alignment: .leading, spacing: 14) {
                TVToggleRow(title: "Seasonal Themes", isOn: $settings.isEnabled)
                TVSettingsCaption(text: "Gives the app a touch of the season or holiday: its color, a symbol on the Home screen, and more.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Button { showsPreview = true } label: {
                    TVSettingsRow(title: "Preview Themes", showsChevron: true, systemImage: "sparkles.tv")
                }
                .buttonStyle(.card)
                TVSettingsCaption(text: "See the Home screen in each theme, and pick one to use.")
            }

            if settings.isEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    TVToggleRow(title: "Animated Effects", isOn: $settings.showsEffects)
                        .disabled(reduceMotion)
                    TVSettingsCaption(text: "Snow, falling leaves, confetti and more drifting across the Home screen.")
                    if reduceMotion { TVSettingsCaption(text: "Off while Reduce Motion is on.") }
                }

                VStack(alignment: .leading, spacing: 14) {
                    TVToggleRow(title: "Change Automatically", isOn: $settings.isAutomatic)
                    if settings.isAutomatic {
                        TVSettingsCaption(text: "Follows the calendar. Holidays show instead of the season around them.")
                        TVSettingsCaption(text: "Now showing: \(settings.scheduledTheme?.title ?? String(localized: "None"))")
                    } else {
                        NavigationLink {
                            TVChoicePage(
                                title: String(localized: "Theme"),
                                options: (AppTheme.holidays + AppTheme.seasons).map {
                                    TVChoiceOption(value: $0, title: $0.title, systemImage: $0.symbolName)
                                },
                                selection: $settings.manualTheme
                            )
                        } label: {
                            TVSettingsRow(
                                title: "Theme",
                                value: LocalizedStringKey(settings.manualTheme.title),
                                showsChevron: true,
                                systemImage: settings.manualTheme.symbolName
                            )
                        }
                        .buttonStyle(.card)
                    }
                }

                if settings.isAutomatic {
                    VStack(alignment: .leading, spacing: 16) {
                        TVSettingsHeading(title: "Holidays")
                        ForEach(AppTheme.holidays) { ThemeScheduleRow(theme: $0) }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        TVSettingsHeading(title: "Seasons")
                        ForEach(AppTheme.seasons) { ThemeScheduleRow(theme: $0) }
                    }
                }
            }

            Button { settings.reset() } label: {
                TVSettingsRow(title: "Reset Themes", isDestructive: true)
            }
            .buttonStyle(.card)
            .disabled(settings.isDefault)
        }
        .tvSettingsPage(title: String(localized: "Themes"))
    }
    #endif

    private var listBody: some View {
        @Bindable var settings = appModel.themeSettings

        return List {
            Section {
                Toggle("Seasonal Themes", isOn: $settings.isEnabled)
            } footer: {
                Text("Gives the app a touch of the season or holiday: its color, a symbol on the Home screen, and more.")
            }

            Section {
                Button("Preview Themes", systemImage: "sparkles") { showsPreview = true }
            } footer: {
                Text("See the Home screen in each theme, and pick one to use.")
            }

            if settings.isEnabled {
                Section {
                    Toggle("Animated Effects", isOn: $settings.showsEffects)
                        .disabled(reduceMotion)
                } footer: {
                    VStack(alignment: .leading) {
                        Text("Snow, falling leaves, confetti and more drifting across the Home screen.")
                        if reduceMotion { Text("Off while Reduce Motion is on.") }
                    }
                }

                Section {
                    Toggle("Change Automatically", isOn: $settings.isAutomatic)
                    if settings.isAutomatic {
                        LabeledContent("Now Showing", value: settings.scheduledTheme?.title ?? String(localized: "None"))
                    } else {
                        Picker("Theme", selection: $settings.manualTheme) {
                            ForEach(AppTheme.holidays + AppTheme.seasons) { theme in
                                Label(theme.title, systemImage: theme.symbolName).tag(theme)
                            }
                        }
                    }
                } footer: {
                    if settings.isAutomatic {
                        Text("Follows the calendar. Holidays show instead of the season around them.")
                    }
                }

                if settings.isAutomatic {
                    Section("Holidays") {
                        ForEach(AppTheme.holidays) { ThemeScheduleRow(theme: $0) }
                    }
                    Section("Seasons") {
                        ForEach(AppTheme.seasons) { ThemeScheduleRow(theme: $0) }
                    }
                }
            }

            Section {
                Button("Reset Themes", role: .destructive) { settings.reset() }
                    .disabled(settings.isDefault)
            }
        }
        .navigationTitle("Themes")
    }
}

/// The Home screen as it looks in each theme, to flip between and choose from. The real Home screen runs behind a strip of
/// the themes; moving along the strip (or tapping, off Apple TV) shows the screen in that theme, and choosing one uses it.
private struct ThemePreviewView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// The theme on show, which the strip follows.
    @FocusState private var focusedTheme: AppTheme?

    private static let themes = AppTheme.holidays + AppTheme.seasons

    var body: some View {
        let settings = appModel.themeSettings

        ZStack(alignment: .bottom) {
            // The screen itself, as the example. Nothing on it can be used; it's only there to look at.
            NavigationStack {
                HomeView()
            }
            .disabled(true)
            .accessibilityHidden(true)

            strip(settings)
        }
        // Not past the safe areas: the Home screen lays itself out by them, so it shows as it does in the app.
        .task {
            // Starts on the theme in use, or the first.
            let start = settings.activeTheme ?? Self.themes[0]
            settings.previewTheme = start
            focusedTheme = start
        }
        .onChange(of: focusedTheme) { _, theme in
            if let theme { settings.previewTheme = theme }
        }
        // However it closes, the real theme comes back.
        .onDisappear { settings.previewTheme = nil }
    }

    private func strip(_ settings: ThemeSettings) -> some View {
        VStack(spacing: 14) {
            Text(settings.previewTheme?.title ?? "")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(Self.themes) { theme in
                        Button {
                            #if os(tvOS)
                            use(theme, settings)
                            #else
                            settings.previewTheme = theme
                            #endif
                        } label: {
                            Label(theme.title, systemImage: theme.symbolName)
                        }
                        .buttonBorderShape(.capsule)
                        .focused($focusedTheme, equals: theme)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            #if os(tvOS)
            Text("Select a theme to use it. Press Menu to go back without changing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            #else
            HStack(spacing: 16) {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Use This Theme") {
                    if let theme = settings.previewTheme { use(theme, settings) }
                }
                .buttonStyle(.borderedProminent)
            }
            #endif
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
    }

    /// Makes `theme` the app's theme, and closes the preview.
    private func use(_ theme: AppTheme, _ settings: ThemeSettings) {
        settings.isEnabled = true
        settings.isAutomatic = false
        settings.manualTheme = theme
        dismiss()
    }
}

/// A theme in the schedule, with its dates (or that it's off), opening its settings.
private struct ThemeScheduleRow: View {
    let theme: AppTheme
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let settings = appModel.themeSettings
        #if os(tvOS)
        NavigationLink {
            ThemeScheduleDetailView(theme: theme)
        } label: {
            TVSettingsRow(
                title: LocalizedStringKey(theme.title),
                value: settings.isScheduled(theme) ? LocalizedStringKey(ThemeDates.text(for: theme, settings: settings)) : "Off",
                showsChevron: true,
                systemImage: theme.symbolName
            )
        }
        .buttonStyle(.card)
        #else
        NavigationLink {
            ThemeScheduleDetailView(theme: theme)
        } label: {
            HStack {
                Label(theme.title, systemImage: theme.symbolName)
                Spacer()
                if settings.isScheduled(theme) {
                    Text(ThemeDates.text(for: theme, settings: settings)).foregroundStyle(.secondary)
                } else {
                    Text("Off").foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }
}

/// One theme's place in the schedule: whether it's in it, and when it shows.
private struct ThemeScheduleDetailView: View {
    let theme: AppTheme
    @Environment(AppModel.self) private var appModel

    /// The most days before or after a holiday its theme can start or end.
    private static let maxDays = 60

    var body: some View {
        #if os(tvOS)
        tvBody(appModel.themeSettings)
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    private func tvBody(_ settings: ThemeSettings) -> some View {
        VStack(alignment: .leading, spacing: 44) {
            TVToggleRow(title: "Include in Schedule", isOn: Binding(
                get: { settings.isScheduled(theme) },
                set: { settings.setScheduled($0, for: theme) }
            ))

            Group {
                switch settings.window(for: theme) {
                case .dates(let start, let end):
                    tvSeasonDates(start: start, end: end, settings: settings)
                case .around(let start, let daysAfter):
                    tvHolidayDates(start: start, daysAfter: daysAfter, settings: settings)
                }

                if settings.hasCustomWindow(theme) {
                    Button { settings.resetWindow(for: theme) } label: {
                        TVSettingsRow(title: "Use Default Dates")
                    }
                    .buttonStyle(.card)
                }
            }
            .disabled(!settings.isScheduled(theme))
        }
        .tvSettingsPage(title: theme.title)
    }

    /// A row that opens a page of choices, showing the one made.
    private func choiceRow<Value: Hashable>(
        _ title: LocalizedStringKey,
        pageTitle: String,
        valueText: String,
        options: [TVChoiceOption<Value>],
        selection: Binding<Value>
    ) -> some View {
        NavigationLink {
            TVChoicePage(title: pageTitle, options: options, selection: selection)
        } label: {
            TVSettingsRow(title: title, value: LocalizedStringKey(valueText), showsChevron: true)
        }
        .buttonStyle(.card)
    }

    private func tvSeasonDates(start: MonthDay, end: MonthDay, settings: ThemeSettings) -> some View {
        VStack(alignment: .leading, spacing: 44) {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsHeading(title: "Starts")
                tvMonthDay(start, pageTitle: String(localized: "Starts")) { settings.setWindow(.dates(start: $0, end: end), for: theme) }
            }
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsHeading(title: "Ends")
                tvMonthDay(end, pageTitle: String(localized: "Ends")) { settings.setWindow(.dates(start: start, end: $0), for: theme) }
                TVSettingsCaption(text: LocalizedStringKey(ThemeDates.text(for: theme, settings: settings)))
            }
        }
    }

    /// A month row and a day row for `value`, which open their lists of choices.
    @ViewBuilder
    private func tvMonthDay(_ value: MonthDay, pageTitle: String, set: @escaping (MonthDay) -> Void) -> some View {
        choiceRow(
            "Month",
            pageTitle: pageTitle,
            valueText: Calendar.themes.monthSymbols[value.month - 1],
            options: (1...12).map { TVChoiceOption(value: $0, title: Calendar.themes.monthSymbols[$0 - 1]) },
            selection: Binding(
                get: { value.month },
                set: { month in set(MonthDay(month: month, day: min(value.day, Self.days(in: month)))) }
            )
        )
        choiceRow(
            "Day",
            pageTitle: pageTitle,
            valueText: value.day.formatted(.number),
            options: (1...Self.days(in: value.month)).map { TVChoiceOption(value: $0, title: $0.formatted(.number)) },
            selection: Binding(
                get: { value.day },
                set: { set(MonthDay(month: value.month, day: $0)) }
            )
        )
    }

    private func tvHolidayDates(start: HolidayStart, daysAfter: Int, settings: ThemeSettings) -> some View {
        var startOptions: [TVChoiceOption<HolidayStart>] = []
        if let preceding = theme.precedingHoliday {
            startOptions.append(TVChoiceOption(value: .dayAfterEnd(of: preceding), title: String(localized: "Day After \(preceding.title)")))
        }
        startOptions += (0...Self.maxDays).map {
            TVChoiceOption(value: .daysBefore($0), title: $0 == 0 ? String(localized: "On \(theme.title)") : Self.dayCount($0, before: true))
        }
        let endOptions = (0...Self.maxDays).map {
            TVChoiceOption(value: $0, title: $0 == 0 ? String(localized: "On \(theme.title)") : Self.dayCount($0, before: false))
        }

        return VStack(alignment: .leading, spacing: 14) {
            choiceRow(
                "Starts",
                pageTitle: String(localized: "Starts"),
                valueText: startOptions.first { $0.value == start }?.title ?? "",
                options: startOptions,
                selection: Binding(
                    get: { start },
                    set: { settings.setWindow(.around(start: $0, daysAfter: daysAfter), for: theme) }
                )
            )
            choiceRow(
                "Ends",
                pageTitle: String(localized: "Ends"),
                valueText: endOptions.first { $0.value == daysAfter }?.title ?? "",
                options: endOptions,
                selection: Binding(
                    get: { daysAfter },
                    set: { settings.setWindow(.around(start: start, daysAfter: $0), for: theme) }
                )
            )
            TVSettingsCaption(text: LocalizedStringKey(ThemeDates.text(for: theme, settings: settings)))
            if case .dayAfterEnd(let preceding) = start {
                TVSettingsCaption(text: "Starts once the \(preceding.title) theme ends, even if \(preceding.title) isn't in the schedule.")
            }
        }
    }

    /// "3 days before" or "1 day after", with the day counted in the right form for the language.
    private static func dayCount(_ days: Int, before: Bool) -> String {
        let text = before
            ? AttributedString(localized: "^[\(days) day](inflect: true) before")
            : AttributedString(localized: "^[\(days) day](inflect: true) after")
        return String(text.characters)
    }
    #endif

    private var listBody: some View {
        let settings = appModel.themeSettings

        return List {
            Section {
                Toggle("Include in Schedule", isOn: Binding(
                    get: { settings.isScheduled(theme) },
                    set: { settings.setScheduled($0, for: theme) }
                ))
            }

            Group {
                switch settings.window(for: theme) {
                case .dates(let start, let end):
                    seasonDates(start: start, end: end, settings: settings)
                case .around(let start, let daysAfter):
                    holidayDates(start: start, daysAfter: daysAfter, settings: settings)
                }

                if settings.hasCustomWindow(theme) {
                    Section {
                        Button("Use Default Dates") { settings.resetWindow(for: theme) }
                    }
                }
            }
            .disabled(!settings.isScheduled(theme))
        }
        .navigationTitle(theme.title)
        #if os(tvOS)
        // A long list of days opens as its own screen, rather than as a menu too tall for a TV.
        .pickerStyle(.navigationLink)
        #endif
    }

    // MARK: Seasons

    @ViewBuilder
    private func seasonDates(start: MonthDay, end: MonthDay, settings: ThemeSettings) -> some View {
        Section("Starts") {
            monthDayPickers(start) { settings.setWindow(.dates(start: $0, end: end), for: theme) }
        }
        Section {
            monthDayPickers(end) { settings.setWindow(.dates(start: start, end: $0), for: theme) }
        } header: {
            Text("Ends")
        } footer: {
            Text(ThemeDates.text(for: theme, settings: settings))
        }
    }

    /// A month picker and a day picker for `value`. The days go as far as the month does, and a day past the end of a
    /// newly picked month moves back to its last day.
    @ViewBuilder
    private func monthDayPickers(_ value: MonthDay, set: @escaping (MonthDay) -> Void) -> some View {
        Picker("Month", selection: Binding(
            get: { value.month },
            set: { month in set(MonthDay(month: month, day: min(value.day, Self.days(in: month)))) }
        )) {
            ForEach(1...12, id: \.self) { month in
                // Gregorian month names, in the user's language: the schedule's months are Gregorian ones.
                Text(Calendar.themes.monthSymbols[month - 1]).tag(month)
            }
        }
        Picker("Day", selection: Binding(
            get: { value.day },
            set: { set(MonthDay(month: value.month, day: $0)) }
        )) {
            ForEach(1...Self.days(in: value.month), id: \.self) { day in
                Text(day, format: .number).tag(day)
            }
        }
    }

    /// The days in `month`, counting February 29.
    private static func days(in month: Int) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2000, month: month)) ?? .now
        return calendar.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    // MARK: Holidays

    @ViewBuilder
    private func holidayDates(start: HolidayStart, daysAfter: Int, settings: ThemeSettings) -> some View {
        Section {
            Picker("Starts", selection: Binding(
                get: { start },
                set: { settings.setWindow(.around(start: $0, daysAfter: daysAfter), for: theme) }
            )) {
                if let preceding = theme.precedingHoliday {
                    Text("Day After \(preceding.title)").tag(HolidayStart.dayAfterEnd(of: preceding))
                }
                ForEach(0...Self.maxDays, id: \.self) { days in
                    Group {
                        if days == 0 {
                            Text("On \(theme.title)")
                        } else {
                            Text("^[\(days) day](inflect: true) before")
                        }
                    }
                    .tag(HolidayStart.daysBefore(days))
                }
            }
            Picker("Ends", selection: Binding(
                get: { daysAfter },
                set: { settings.setWindow(.around(start: start, daysAfter: $0), for: theme) }
            )) {
                ForEach(0...Self.maxDays, id: \.self) { days in
                    Group {
                        if days == 0 {
                            Text("On \(theme.title)")
                        } else {
                            Text("^[\(days) day](inflect: true) after")
                        }
                    }
                    .tag(days)
                }
            }
        } footer: {
            VStack(alignment: .leading) {
                Text(ThemeDates.text(for: theme, settings: settings))
                if case .dayAfterEnd(let preceding) = start {
                    Text("Starts once the \(preceding.title) theme ends, even if \(preceding.title) isn't in the schedule.")
                }
            }
        }
    }
}

/// How a theme's dates read, e.g. "Nov 28 – Dec 30".
private enum ThemeDates {
    static func text(for theme: AppTheme, settings: ThemeSettings) -> String {
        guard let dates = settings.schedule.upcomingDates(for: theme, from: settings.today) else { return "" }
        // Gregorian, to match the month and day pickers whatever calendar the user has chosen.
        let style = Date.FormatStyle(calendar: .themes).month(.abbreviated).day()
        return "\(dates.start.formatted(style)) – \(dates.end.formatted(style))"
    }
}

#Preview {
    NavigationStack {
        ThemeSettingsView()
    }
    .environment(AppModel.preview())
}
