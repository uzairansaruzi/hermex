import Foundation

/// A cron expression rendered for people.
///
/// `recurrence` is the period on its own ("Every 15 minutes", "Weekdays"), for
/// a row that already shows the next run time beside it. `sentence` folds the
/// time of day back in ("Weekdays at 9:25 AM"), for rows with no next run and
/// for Task Detail.
struct CronScheduleDescription: Equatable {
    let recurrence: String
    let sentence: String
}

/// Turns the standard five-field cron expressions the server sends into
/// English.
///
/// Deliberately narrow: it recognises the shapes people actually schedule and
/// returns `nil` for everything else, so callers fall back to the server's own
/// string. A wrong guess about when a job runs is worse than a raw expression.
enum CronScheduleHumanizer {
    /// Describes `expression`, or `nil` when it is not a five-field cron
    /// expression in one of the recognised shapes.
    static func describe(
        _ expression: String?,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> CronScheduleDescription? {
        guard let expression else { return nil }

        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }

        let (minuteField, hourField, dayOfMonthField, monthField, dayOfWeekField) =
            (fields[0], fields[1], fields[2], fields[3], fields[4])

        // Anything month-scoped beyond "every month" is rare enough that the
        // raw expression is the honest answer.
        guard monthField == "*" else { return nil }

        if let recurrence = intervalRecurrence(
            minuteField: minuteField,
            hourField: hourField,
            dayOfMonthField: dayOfMonthField,
            dayOfWeekField: dayOfWeekField,
            locale: locale
        ) {
            // An interval has no single time of day to append.
            return CronScheduleDescription(recurrence: recurrence, sentence: recurrence)
        }

        guard let minute = fixedValue(minuteField, in: 0...59),
              let hour = fixedValue(hourField, in: 0...23),
              let recurrence = calendarRecurrence(
                  dayOfMonthField: dayOfMonthField,
                  dayOfWeekField: dayOfWeekField,
                  locale: locale
              )
        else { return nil }

        let time = timeText(hour: hour, minute: minute, locale: locale, calendar: calendar)
        return CronScheduleDescription(
            recurrence: recurrence,
            sentence: String(localized: "\(recurrence) at \(time)")
        )
    }

    // MARK: - Shapes

    /// `*/15 * * * *` and `0 */2 * * *`: a step over an otherwise unrestricted
    /// field. The hourly form requires minute zero so the phrase cannot imply
    /// an offset it is not describing.
    private static func intervalRecurrence(
        minuteField: String,
        hourField: String,
        dayOfMonthField: String,
        dayOfWeekField: String,
        locale: Locale
    ) -> String? {
        guard dayOfMonthField == "*", dayOfWeekField == "*" else { return nil }

        if hourField == "*" {
            if minuteField == "*" { return String(localized: "Every minute") }
            guard let step = stepValue(minuteField, in: 1...59) else { return nil }
            guard step > 1 else { return String(localized: "Every minute") }
            return String(localized: "Every \(durationText(minutes: step, locale: locale))")
        }

        guard minuteField == "0", let step = stepValue(hourField, in: 1...23) else { return nil }
        guard step > 1 else { return nil }   // `0 */1 * * *` is just hourly; let it fall through.
        return String(localized: "Every \(durationText(hours: step, locale: locale))")
    }

    /// The day-of-week and day-of-month shapes that pair with a fixed time.
    private static func calendarRecurrence(
        dayOfMonthField: String,
        dayOfWeekField: String,
        locale: Locale
    ) -> String? {
        if dayOfMonthField == "*" {
            if dayOfWeekField == "*" { return String(localized: "Daily") }

            guard let days = dayOfWeekSet(dayOfWeekField) else { return nil }
            if days == [1, 2, 3, 4, 5] { return String(localized: "Weekdays") }
            if days == [0, 6] { return String(localized: "Weekends") }
            guard days.count == 1, let day = days.first else { return nil }
            // A separate frame from the interval one: "Every %@" has to read
            // correctly for "15 minutes" in every language, and a weekday would
            // force a different article or case in several of them.
            return String(localized: "Weekly on \(weekdayName(day, locale: locale))")
        }

        // A day-of-month and a day-of-week together mean different things on
        // different cron implementations, so only the unambiguous form counts.
        guard dayOfWeekField == "*",
              let day = fixedValue(dayOfMonthField, in: 1...31),
              let ordinal = ordinalText(day, locale: locale)
        else { return nil }

        return String(localized: "Monthly on the \(ordinal)")
    }

    // MARK: - Field parsing

    /// A single literal number, e.g. `25`. Lists, ranges and steps are not
    /// fixed values.
    private static func fixedValue(_ field: String, in range: ClosedRange<Int>) -> Int? {
        guard let value = Int(field), range.contains(value) else { return nil }
        return value
    }

    /// The `N` of `*/N`, valid only when the rest of the field is unrestricted.
    private static func stepValue(_ field: String, in range: ClosedRange<Int>) -> Int? {
        guard field.hasPrefix("*/") else { return nil }
        guard let step = Int(field.dropFirst(2)), range.contains(step) else { return nil }
        return step
    }

    /// Day-of-week as Sunday-zero indices. Accepts `3`, `1-5` and `0,6`; cron's
    /// `7` is Sunday. Anything else is unrecognised.
    private static func dayOfWeekSet(_ field: String) -> Set<Int>? {
        func normalized(_ token: String) -> Int? {
            guard let value = Int(token), (0...7).contains(value) else { return nil }
            return value % 7
        }

        if field.contains("-") {
            let bounds = field.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2,
                  let lower = normalized(String(bounds[0])),
                  let upper = normalized(String(bounds[1])),
                  lower <= upper
            else { return nil }
            return Set(lower...upper)
        }

        let tokens = field.split(separator: ",", omittingEmptySubsequences: false)
        guard !tokens.isEmpty else { return nil }

        var days: Set<Int> = []
        for token in tokens {
            guard let day = normalized(String(token)) else { return nil }
            days.insert(day)
        }
        return days
    }

    // MARK: - Locale-aware pieces

    private static func timeText(hour: Int, minute: Int, locale: Locale, calendar: Calendar) -> String {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = hour
        components.minute = minute

        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }

        // Pin calendar and time zone to the ones the components were built in,
        // so the rendered clock time is the one cron will actually fire at.
        let style = Date.FormatStyle(
            date: .omitted,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return style.format(date)
    }

    /// Foundation owns the plural rules here, so "15 minutes" is correct in
    /// every language without a plural entry per interval in the catalog.
    /// The wait until `date` as one compact figure — "in 6m", "in 12h 21m",
    /// "in 3d 4h" — for the number Task Detail leads with.
    ///
    /// Deliberately computed on demand instead of ticked by a timer: a
    /// self-updating label repaints its whole card every second for a figure
    /// nobody watches count down, and Refresh already brings it current.
    static func countdown(
        to date: Date,
        from now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval >= 60 else {
            return interval > 0 ? String(localized: "Due now") : String(localized: "Overdue")
        }

        let allowed: Set<Duration.UnitsFormatStyle.Unit>
        if interval < 3_600 {
            allowed = [.minutes]
        } else if interval < 86_400 {
            allowed = [.hours, .minutes]
        } else {
            allowed = [.days, .hours]
        }

        let duration = Duration.seconds(interval)
            .formatted(.units(allowed: allowed, width: .narrow, maximumUnitCount: 2).locale(locale))
        return String(localized: "in \(duration)", comment: "Countdown to a task's next run, e.g. 'in 12h 21m'")
    }

    private static func durationText(minutes: Int, locale: Locale) -> String {
        Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.minutes], width: .wide).locale(locale))
    }

    private static func durationText(hours: Int, locale: Locale) -> String {
        Duration.seconds(hours * 3600)
            .formatted(.units(allowed: [.hours], width: .wide).locale(locale))
    }

    /// Sunday-zero index to a standalone weekday name in `locale`.
    private static func weekdayName(_ day: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.standaloneWeekdaySymbols ?? []
        guard symbols.indices.contains(day) else { return "\(day)" }
        return symbols[day]
    }

    private static func ordinalText(_ value: Int, locale: Locale) -> String? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value))
    }
}
