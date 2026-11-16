import SwiftUI
import WidgetKit

/// Provider limits on the Home Screen and Lock Screen (#1409), drawn from the snapshot the app
/// writes when Usage loads on a Hermes server (`ProviderLimitsSnapshot`). It makes no network or
/// Keychain call: opening Usage is the only refresh. Each window shows its percentage until the
/// earlier of its reset and an hour after its measurement, then asks to open Hermex; the timeline
/// has an entry at each of those instants rather than trusting WidgetKit to reload on time.
struct ProviderLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ProviderLimitsSnapshot.widgetKind, provider: ProviderLimitsTimeline()) { entry in
            ProviderLimitsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.snapshot?.destination.url)
        }
        .configurationDisplayName("Limits")
        .description("Subscription limits from Usage in Hermex.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ProviderLimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: ProviderLimitsSnapshot?
}

struct ProviderLimitsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ProviderLimitsEntry {
        ProviderLimitsEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProviderLimitsEntry) -> Void) {
        completion(ProviderLimitsEntry(date: Date(), snapshot: ProviderLimitsSnapshotFile.shared?.read()))
    }

    /// An entry now and one at every later instant a window expires, so each percentage goes on
    /// time even when the system reloads late.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProviderLimitsEntry>) -> Void) {
        let now = Date()
        let snapshot = ProviderLimitsSnapshotFile.shared?.read()
        let deadlines = snapshot?.deadlines(after: now) ?? []
        let entries = ([now] + deadlines).map { ProviderLimitsEntry(date: $0, snapshot: snapshot) }
        let after = deadlines.last ?? now.addingTimeInterval(ProviderLimitsSnapshot.measurementLifetime)
        completion(Timeline(entries: entries, policy: .after(after)))
    }
}

/// One window as an entry draws it.
private struct LimitReading {
    let provider: ProviderLimitsSnapshot.Provider
    let window: ProviderLimitsSnapshot.Window
    /// Nil once the window expired.
    let percent: Double?

    init(_ provider: ProviderLimitsSnapshot.Provider, _ window: ProviderLimitsSnapshot.Window, at now: Date) {
        self.provider = provider
        self.window = window
        percent = provider.remainingPercent(of: window, at: now)
    }
}

private struct ProviderLimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProviderLimitsEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
            switch family {
            case .systemMedium:
                MediumLimits(snapshot: snapshot, now: entry.date)
            case .accessoryRectangular:
                if let reading = tightest(in: snapshot) {
                    RectangularLimit(reading: reading, profile: snapshot.profile, now: entry.date)
                }
            default:
                if let reading = tightest(in: snapshot) {
                    SmallLimit(reading: reading, profile: snapshot.profile, now: entry.date)
                }
            }
        } else {
            EmptyLimits()
        }
    }

    /// The window with the least left that still shows a percentage, else the one with the least
    /// left when it was measured, shown as expired.
    private func tightest(in snapshot: ProviderLimitsSnapshot) -> LimitReading? {
        let readings = snapshot.providers.flatMap { provider in
            provider.windows.map { LimitReading(provider, $0, at: entry.date) }
        }
        return readings.filter { $0.percent != nil }.min { $0.window.remainingPercent < $1.window.remainingPercent }
            ?? readings.min { $0.window.remainingPercent < $1.window.remainingPercent }
    }
}

private struct SmallLimit: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let reading: LimitReading
    let profile: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowTitle(reading: reading)
            Spacer(minLength: 4)
            if let percent = reading.percent {
                Text("\(Text(percentText(percent)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(LimitTint(percent: percent, renderingMode: renderingMode, isLuminanceReduced: isLuminanceReduced).color)) left")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                LimitBar(percent: percent, height: 8)
                    .padding(.vertical, 6)
            } else {
                RefreshPrompt()
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 4)
            }
            WindowFootnote(reading: reading, now: now)
                .font(.caption2)
            ProfileLabel(profile: profile)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Up to two providers side by side, two windows each.
private struct MediumLimits: View {
    let snapshot: ProviderLimitsSnapshot
    let now: Date

    private var providers: [ProviderLimitsSnapshot.Provider] { Array(snapshot.providers.prefix(2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProfileLabel(profile: snapshot.profile)
                Spacer(minLength: 8)
                // The oldest measurement shown: a newer publication never makes it look fresh.
                if let measured = providers.compactMap(\.updatedAt).min() {
                    Text("Updated \(shortMoment(measured, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(providers, id: \.id) { provider in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(verbatim: provider.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if provider.isStale { StaleBadge() }
                        }
                        ForEach(Array(provider.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                            MediumRow(reading: LimitReading(provider, window, at: now), now: now)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MediumRow: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let reading: LimitReading
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: reading.window.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let percent = reading.percent {
                    Text("\(Int(clamped(percent).rounded()))% left")
                        .fontWeight(.semibold)
                        .foregroundStyle(LimitTint(percent: percent, renderingMode: renderingMode, isLuminanceReduced: isLuminanceReduced).color)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            if let percent = reading.percent {
                LimitBar(percent: percent, height: 5)
            } else {
                RefreshPrompt()
                    .font(.caption2.weight(.semibold))
            }
            WindowFootnote(reading: reading, now: now)
                .font(.caption2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Lock Screen's rectangle: the tightest window, in the system's one-color rendering.
private struct RectangularLimit: View {
    let reading: LimitReading
    let profile: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text(verbatim: "\(profile) · \(reading.provider.title) \(reading.window.label)")
            } icon: {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            .font(.caption2)
            .lineLimit(1)
            if let percent = reading.percent {
                Text("\(Int(clamped(percent).rounded()))% left")
                    .font(.headline)
                LimitBar(percent: percent, height: 4)
                    .padding(.vertical, 2)
            } else {
                RefreshPrompt()
                    .font(.headline)
                    .minimumScaleFactor(0.7)
            }
            WindowFootnote(reading: reading, now: now)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyLimits: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Label("Limits", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption2)
                Text("Open Usage in Hermex")
                    .font(.headline)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("No limits yet")
                    .font(.subheadline.weight(.semibold))
                Text("Open Usage in Hermex to show them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct WindowTitle: View {
    let reading: LimitReading

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: reading.provider.title)
                .font(.subheadline.weight(.semibold))
            Text(verbatim: reading.window.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if reading.provider.isStale { StaleBadge() }
        }
        .lineLimit(1)
    }
}

/// The reset, or for a stale value still showing, when it was measured.
private struct WindowFootnote: View {
    let reading: LimitReading
    let now: Date

    var body: some View {
        Group {
            if reading.percent != nil, reading.provider.isStale, let measured = reading.provider.updatedAt {
                Text("As of \(shortMoment(measured, now: now))")
            } else if let reset = reading.window.resetAt {
                if reset <= now {
                    Text("Reset at \(shortMoment(reset, now: now))")
                } else {
                    Text("Resets \(shortMoment(reset, now: now))")
                }
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct RefreshPrompt: View {
    var body: some View {
        Text("Open Hermex to refresh")
            .lineLimit(2)
    }
}

private struct StaleBadge: View {
    var body: some View {
        Text("Stale")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }
}

private struct ProfileLabel: View {
    let profile: String

    var body: some View {
        Label {
            Text(verbatim: profile)
        } icon: {
            Image(systemName: "person.crop.circle")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The remaining share, unanimated: it changes only between timeline entries.
private struct LimitBar: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let percent: Double
    let height: CGFloat

    var body: some View {
        let fraction = clamped(percent) / 100
        Capsule()
            .fill(Color.primary.opacity(0.14))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(LimitTint(percent: percent, renderingMode: renderingMode, isLuminanceReduced: isLuminanceReduced).color)
                        .frame(width: max(proxy.size.width * fraction, fraction > 0 ? height : 0))
                        .widgetAccentable()
                }
            }
            .accessibilityHidden(true)
    }
}

/// The Usage card's tiers (`providerLimitTint`): accent, orange at 25% or less, red at 10% or
/// less, in full color only. Tinted and vibrant rendering draw it in primary and Always-On in
/// secondary, so the number and bar carry it alone.
private struct LimitTint {
    let percent: Double
    let renderingMode: WidgetRenderingMode
    let isLuminanceReduced: Bool

    var color: Color {
        if isLuminanceReduced { return .secondary }
        guard renderingMode == .fullColor else { return .primary }
        if percent <= 10 { return .red }
        if percent <= 25 { return .orange }
        return .accentColor
    }
}

private func clamped(_ percent: Double) -> Double { min(max(percent, 0), 100) }

/// "12%" for the small widget's large figure.
private func percentText(_ percent: Double) -> String {
    (clamped(percent).rounded() / 100).formatted(.percent.precision(.fractionLength(0)))
}

/// "3:40 PM" today, "Thu" within the week, "Nov 12" beyond.
private func shortMoment(_ date: Date, now: Date) -> String {
    if Calendar.current.isDate(date, inSameDayAs: now) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
