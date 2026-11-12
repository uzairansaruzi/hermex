import SwiftUI

/// Settings › About › Usage Reports (#1662): the device-wide switch, what it sends, and what
/// turning it off can't undo.
struct SettingsUsageReportsPage: View {
    @AppStorage(UsageReports.Keys.acceptedVersion) private var acceptedVersion: Int?

    var body: some View {
        AppList {
            Section {
                Toggle("Send Usage Reports", isOn: Binding(
                    get: { acceptedVersion != nil },
                    set: { $0 ? UsageReports.shared.allow() : UsageReports.shared.turnOff() }
                ))
            } appFooter: {
                Text("A weekly summary of which versions and features you use goes to the developer. Never message text, server addresses or file names. One setting for this iPhone and every server.")
            }

            Section {
                NavigationLink("See What’s Sent") {
                    UsageReportPreview()
                }
            } appFooter: {
                Text("Turning this off stops sending and erases this week’s tallies. Reports already sent can’t be recalled or deleted.")
            }
        }
        .settingsPage(String(localized: "Usage Reports"))
    }
}

/// The preview as the consent card's sheet.
struct UsageReportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UsageReportPreview()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
        }
    }
}

/// Every field of a usage report, grouped like the wire format (#1659). Before consent it is a
/// labelled example: real device, server and report values, sample weekly counts. After
/// consent it is this week so far, from the builder the sender uses.
struct UsageReportPreview: View {
    @AppStorage(UsageReports.Keys.acceptedVersion) private var acceptedVersion: Int?
    @State private var report: UsageReport?

    private var isExample: Bool { acceptedVersion == nil }

    var body: some View {
        AppList {
            Section {
                (isExample
                    ? Text("Example report. Nothing is recorded until you allow usage reports. This iPhone, Servers and Report show real values; the weekly counts are samples.")
                    : Text("This week so far, built by the same code that sends it. It goes to the developer the first time you open Hermex after the week ends (Monday, UTC)."))
                    .font(AppFont.footnote())
                    .foregroundStyle(isExample ? Color.black : Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(isExample ? Color(red: 1, green: 224 / 255, blue: 0) : nil)
            }

            if let report {
                sections(report)
            }

            Section {
                LabeledContent("Arrival day", value: String(localized: "The UTC day"))
                LabeledContent("Country", value: String(localized: "From the connection"))
            } header: {
                Text("Added when it arrives")
            } appFooter: {
                Text("The collector adds these two. It never stores your IP address.")
            }
        }
        .settingsPage(String(localized: "What’s Sent"))
        .task(id: acceptedVersion) { report = await UsageReports.shared.preview() }
    }

    @ViewBuilder private func sections(_ report: UsageReport) -> some View {
        Section("Report") {
            value("Week", report.week)
            LabeledContent("Channel", value: report.channel == .testflight ? "TestFlight" : "App Store")
            value("App version", report.appVersion)
            value("iOS version", report.osVersion)
            LabeledContent("Format") { Text(report.v, format: .number) }
        }

        Section("This iPhone") {
            value("Device model", report.deviceModel)
            value("Language", report.language)
            value("Region", report.region)
            value("Install day", report.installDay)
        }

        Section {
            LabeledContent("Hermes") { Text(report.servers.hermes, format: .number) }
            LabeledContent { Text(report.servers.webui, format: .number) } label: { Text(verbatim: "webui") }
            ForEach(Array(report.servers.versions.enumerated()), id: \.offset) { _, server in
                value(server.kind == .hermes ? "Hermes version" : "webui version", server.version)
            }
        } header: {
            Text("Servers")
        } appFooter: {
            Text("Kinds and release numbers only. A custom version string shows as other.")
        }

        Section {
            LabeledContent("Days active") { Text(report.daysActive, format: .number) }
            LabeledContent("Completed responses") { Text(report.completedResponses, format: .number) }
            LabeledContent("First report of the month", value: report.firstReportOfMonth
                           ? String(localized: "Yes") : String(localized: "No"))
        } header: {
            header("This week")
        }

        Section {
            ForEach(UsageFeature.allCases, id: \.self) { feature in
                let used = report.features.used.contains(feature)
                LabeledContent {
                    (used ? Text("Used") : Text(verbatim: "–"))
                        .accessibilityLabel(used ? Text("Used") : Text("Not used"))
                } label: {
                    Text(feature.title)
                }
            }
        } header: {
            header("Features used this week")
        }

        Section("Settings") {
            LabeledContent("Push notifications", value: report.settings.pushEnabled ? String(localized: "On") : String(localized: "Off"))
            LabeledContent("App lock", value: report.settings.appLock ? String(localized: "On") : String(localized: "Off"))
        }

        Section {
            LabeledContent("Tip card", value: Self.summary(report.cards.tip))
            LabeledContent("Star card", value: Self.summary(report.cards.star))
        } header: {
            header("Cards")
        }
    }

    /// A row whose value is the report's own text, shown exactly as sent.
    private func value(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) { Text(verbatim: value) }
    }

    /// A weekly section's header, tagged Sample on the example.
    private func header(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if isExample {
                Text("Sample")
                    .textCase(nil)
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    /// Every flag the report carries for the card, each on its own.
    private static func summary(_ card: UsageCardTally) -> String {
        var parts = [card.shown ? String(localized: "Shown") : String(localized: "Not shown")]
        if card.dismissed { parts.append(String(localized: "closed")) }
        if card.linkOpened { parts.append(String(localized: "link opened")) }
        return parts.formatted(.list(type: .and))
    }
}

private extension UsageFeature {
    var title: LocalizedStringResource {
        switch self {
        case .workspace: "Workspace"
        case .tasks: "Tasks"
        case .skills: "Skills"
        case .memory: "Memory"
        case .insights: "Insights"
        case .kanban: "Kanban"
        case .bots: "Bots"
        case .shareExtension: "Share extension"
        case .homeWidget: "Home Screen widget"
        case .liveActivity: "Live Activity"
        case .voiceInput: "Voice input"
        case .appIntents: "Shortcuts and Siri"
        }
    }
}
