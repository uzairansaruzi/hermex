import Foundation
import StoreKit
import UIKit

enum UsageFeature: String, CaseIterable, Codable, CodingKey {
    case workspace, tasks, skills, memory, insights, kanban, bots
    case shareExtension = "share_extension"
    case homeWidget = "home_widget"
    case liveActivity = "live_activity"
    case voiceInput = "voice_input"
    case appIntents = "app_intents"
}

struct UsageCardTally: Codable, Equatable {
    var shown = false
    var dismissed = false
    var linkOpened = false

    enum CodingKeys: String, CodingKey {
        case shown, dismissed
        case linkOpened = "link_opened"
    }
}

struct UsageWeekID: Codable, Hashable {
    let monday: Date

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        return calendar
    }()

    init(containing date: Date) {
        monday = Self.calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    var previous: UsageWeekID { UsageWeekID(containing: monday.addingTimeInterval(-24 * 60 * 60)) }

    var id: String {
        let parts = Self.calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: monday)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    func isInSameMonth(as other: UsageWeekID) -> Bool {
        Self.calendar.isDate(monday, equalTo: other.monday, toGranularity: .month)
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }
}

struct UsageTallies: Codable, Equatable {
    var week: UsageWeekID
    var activeDays: Set<String> = []
    var completedResponses = 0
    var features: Set<UsageFeature> = []
    var tip = UsageCardTally()
    var star = UsageCardTally()

    static func sample(week: UsageWeekID) -> UsageTallies {
        UsageTallies(week: week, activeDays: Set((0..<5).map { UsageWeekID.day(week.monday.addingTimeInterval(Double($0) * 86_400)) }),
                     completedResponses: 42, features: [.workspace, .insights, .bots, .liveActivity],
                     tip: UsageCardTally(shown: true))
    }
}

struct UsageDevice: Equatable {
    var channel: UsageReport.Channel
    var appVersion: String
    var osVersion: String
    var deviceModel: String
    var language: String
    var region: String

    @MainActor static func current() async -> UsageDevice {
        UsageDevice(
            channel: await channel(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareModel,
            language: String((Bundle.main.preferredLocalizations.first ?? "en").prefix(16)),
            region: region(Locale.current.region?.identifier)
        )
    }

    private static func channel() async -> UsageReport.Channel {
        guard let result = try? await AppTransaction.shared else { return .appstore }
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            return transaction.environment == .sandbox ? .testflight : .appstore
        }
    }

    private static var hardwareModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func region(_ identifier: String?) -> String {
        guard let identifier, identifier.wholeMatch(of: /[A-Z]{2}|[0-9]{3}/) != nil else { return "ZZ" }
        return identifier
    }
}

struct UsageReport: Encodable, Equatable {
    static let currentVersion = 2

    static func fieldsAdded(after version: Int) -> [String] {
        version < 2 ? [String(localized: "whether each Hermes server is a Webapp or a dashboard")] : []
    }

    enum Channel: String, Encodable { case appstore, testflight }

    struct Servers: Encodable, Equatable {
        var hermes: Int
        var webui: Int
        var versions: [Version]
    }

    struct Version: Encodable, Equatable {
        var kind: ServerKind
        var version: String
        var gateway: Gateway?
    }

    enum Gateway: String, Encodable { case webapp, dashboard, unknown }

    struct Features: Encodable, Equatable {
        var used: Set<UsageFeature>

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: UsageFeature.self)
            for feature in UsageFeature.allCases { try container.encode(used.contains(feature), forKey: feature) }
        }
    }

    struct Settings: Encodable, Equatable {
        var pushEnabled: Bool
        var appLock: Bool

        enum CodingKeys: String, CodingKey {
            case pushEnabled = "push_enabled"
            case appLock = "app_lock"
        }
    }

    struct Cards: Encodable, Equatable {
        var tip: UsageCardTally
        var star: UsageCardTally
    }

    let v: Int
    let week: String
    let channel: Channel
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let language: String
    let region: String
    let installDay: String
    let daysActive: Int
    let firstReportOfMonth: Bool
    let servers: Servers
    let completedResponses: Int
    let features: Features
    let settings: Settings
    let cards: Cards

    enum CodingKeys: String, CodingKey {
        case v, week, channel, language, region, servers, features, settings, cards
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case installDay = "install_day"
        case daysActive = "days_active"
        case firstReportOfMonth = "first_report_of_month"
        case completedResponses = "completed_responses"
    }

    init(version: Int, tallies: UsageTallies, firstReportOfMonth: Bool, installDate: Date, device: UsageDevice,
         servers: [ServerAccount], settings: Settings) {
        v = version
        week = tallies.week.id
        channel = device.channel
        appVersion = device.appVersion
        osVersion = device.osVersion
        deviceModel = String(device.deviceModel.prefix(20))
        language = device.language
        region = device.region
        installDay = UsageWeekID.day(installDate)
        daysActive = min(tallies.activeDays.count, 7)
        self.firstReportOfMonth = firstReportOfMonth
        self.servers = Servers(
            hermes: min(servers.count { $0.kind == .hermes }, 99),
            webui: min(servers.count { $0.kind == .webui }, 99),
            versions: servers.prefix(20).map {
                Version(kind: $0.kind, version: Self.reportedVersion(of: $0),
                        gateway: version >= 2 ? Self.reportedGateway(of: $0) : nil)
            }
        )
        completedResponses = min(tallies.completedResponses, 100_000)
        features = Features(used: tallies.features)
        self.settings = settings
        cards = Cards(tip: tallies.tip, star: tallies.star)
    }

    static func reportedVersion(of server: ServerAccount) -> String {
        guard server.kind == .hermes, let version = server.serverVersion else { return "unknown" }
        return version.wholeMatch(of: /[0-9]+(\.[0-9]+){1,3}/) != nil ? version : "other"
    }

    static func reportedGateway(of server: ServerAccount) -> Gateway {
        guard server.kind == .hermes, let gateway = server.hermesGateway else { return .unknown }
        return switch gateway {
        case .webapp: .webapp
        case .dashboard: .dashboard
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

struct UsageReportConsent: Equatable {
    var acceptedVersion: Int?
    var declinedVersion: Int?

    enum Question: Equatable {
        case allow
        case moreFields([String])
    }

    func question(currentVersion: Int = UsageReport.currentVersion) -> Question? {
        guard (declinedVersion ?? 0) < currentVersion else { return nil }
        guard let acceptedVersion else { return declinedVersion == nil ? .allow : nil }
        return acceptedVersion < currentVersion ? .moreFields(UsageReport.fieldsAdded(after: acceptedVersion)) : nil
    }
}

@MainActor
final class UsageReports {
    static let shared = UsageReports(defaults: .standard)
    static let collectorURL = URL(staticString: "https://hermex-stats.uzairansar.com/v1/report")

    nonisolated static var buildSends: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    enum Keys {
        static let acceptedVersion = "usageReports.acceptedVersion"
        static let declinedVersion = "usageReports.declinedVersion"
        static let week = "usageReports.week"
        static let endedWeek = "usageReports.endedWeek"
        static let lastAttemptedWeek = "usageReports.lastAttemptedWeek"
        static let debugForcesCard = "usageReports.debugForcesCard"
    }

    private let defaults: UserDefaults
    private let servers: () -> [ServerAccount]
    private let readSettings: @MainActor ([ServerAccount]) -> UsageReport.Settings
    private let device: () async -> UsageDevice
    private let session: URLSession
    private let buildSends: Bool
    private let currentVersion: Int

    init(defaults: UserDefaults,
         servers: @escaping () -> [ServerAccount] = { ServerRegistry.shared.servers },
         readSettings: @escaping @MainActor ([ServerAccount]) -> UsageReport.Settings = UsageReports.liveSettings,
         device: @escaping () async -> UsageDevice = UsageDevice.current,
         session: URLSession = URLSession(configuration: .usageReports),
         buildSends: Bool = UsageReports.buildSends,
         currentVersion: Int = UsageReport.currentVersion) {
        self.defaults = defaults
        self.servers = servers
        self.readSettings = readSettings
        self.device = device
        self.session = session
        self.buildSends = buildSends
        self.currentVersion = currentVersion
    }

    var consent: UsageReportConsent {
        UsageReportConsent(acceptedVersion: defaults.object(forKey: Keys.acceptedVersion) as? Int,
                           declinedVersion: defaults.object(forKey: Keys.declinedVersion) as? Int)
    }

    var isAllowed: Bool { consent.acceptedVersion != nil }

    func allow(now: Date = Date()) {
        defaults.set(currentVersion, forKey: Keys.acceptedVersion)
        recordActiveDay(now)
    }

    func decline() {
        defaults.set(currentVersion, forKey: Keys.declinedVersion)
    }

    func turnOff() {
        defaults.removeObject(forKey: Keys.acceptedVersion)
        defaults.set(currentVersion, forKey: Keys.declinedVersion)
        defaults.removeObject(forKey: Keys.week)
        defaults.removeObject(forKey: Keys.endedWeek)
    }

    #if DEBUG
    func forgetAnswerForTesting() {
        for key in [Keys.acceptedVersion, Keys.declinedVersion, Keys.week, Keys.endedWeek] {
            defaults.removeObject(forKey: key)
        }
    }
    #endif

    private var isRecording: Bool { isAllowed && !servers().isEmpty }

    var thisWeek: UsageTallies? { load(Keys.week) }

    func record(_ feature: UsageFeature, now: Date = Date()) {
        update(now) { $0.features.insert(feature) }
    }

    func recordCompletedResponse(now: Date = Date()) {
        update(now) { $0.completedResponses += 1 }
    }

    func record(_ card: SessionListCard, _ event: WritableKeyPath<UsageCardTally, Bool>, now: Date = Date()) {
        switch card {
        case .tip: update(now) { $0.tip[keyPath: event] = true }
        case .star: update(now) { $0.star[keyPath: event] = true }
        case .usageReports: return
        }
    }

    private func recordActiveDay(_ now: Date) {
        update(now) { $0.activeDays.insert(UsageWeekID.day(now)) }
    }

    private func update(_ now: Date, _ change: (inout UsageTallies) -> Void) {
        guard isRecording else { return }
        var tallies = rollOver(now)
        change(&tallies)
        save(tallies, forKey: Keys.week)
    }

    private func rollOver(_ now: Date) -> UsageTallies {
        let week = UsageWeekID(containing: now)
        if let stored: UsageTallies = load(Keys.week), stored.week != week {
            defaults.removeObject(forKey: Keys.week)
            if stored.week == week.previous { save(stored, forKey: Keys.endedWeek) }
        }
        if let ended: UsageTallies = load(Keys.endedWeek), ended.week != week.previous {
            defaults.removeObject(forKey: Keys.endedWeek)
        }
        return load(Keys.week) ?? UsageTallies(week: week)
    }

    func appBecameActive(now: Date = Date()) async {
        recordActiveDay(now)
        await sendEndedWeek(now: now)
    }

    private func sendEndedWeek(now: Date) async {
        guard isRecording else { return }
        _ = rollOver(now)
        guard defaults.data(forKey: Keys.endedWeek) != nil else { return }
        let device = await device()
        guard let ended: UsageTallies = load(Keys.endedWeek) else { return }
        defaults.removeObject(forKey: Keys.endedWeek)
        guard lastAttemptedWeek != ended.week else { return }
        let firstOfMonth = isFirstReport(ofMonthOf: ended.week)
        defaults.set(ended.week.monday, forKey: Keys.lastAttemptedWeek)
        guard buildSends, isRecording, let version = consent.acceptedVersion,
              let body = try? build(version: version, tallies: ended, firstOfMonth: firstOfMonth, device: device).encoded()
        else { return }
        var request = URLRequest(url: Self.collectorURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await session.data(for: request)
    }

    func preview(now: Date = Date(), asking: Bool = false) async -> UsageReport {
        let week = UsageWeekID(containing: now)
        guard let accepted = consent.acceptedVersion else {
            return build(version: currentVersion, tallies: .sample(week: week), firstOfMonth: true, device: await device())
        }
        let tallies = rollOver(now)
        return build(version: asking ? currentVersion : accepted, tallies: tallies, firstOfMonth: isFirstReport(ofMonthOf: week), device: await device())
    }

    private func build(version: Int, tallies: UsageTallies, firstOfMonth: Bool, device: UsageDevice) -> UsageReport {
        let servers = servers()
        return UsageReport(version: version, tallies: tallies, firstReportOfMonth: firstOfMonth,
                           installDate: defaults.object(forKey: RatingPromptSettings.firstLaunchDateKey) as? Date ?? Date(),
                           device: device, servers: servers, settings: readSettings(servers))
    }

    private var lastAttemptedWeek: UsageWeekID? {
        (defaults.object(forKey: Keys.lastAttemptedWeek) as? Date).map(UsageWeekID.init(containing:))
    }

    private func isFirstReport(ofMonthOf week: UsageWeekID) -> Bool {
        guard let last = lastAttemptedWeek, last != week else { return true }
        return !last.isInSameMonth(as: week)
    }

    static func liveSettings(servers: [ServerAccount]) -> UsageReport.Settings {
        let paired = Set(((try? KeychainPushPairingStore()?.allPairings()) ?? [:]).keys.map(\.absoluteString))
        return UsageReport.Settings(pushEnabled: servers.contains { paired.contains($0.id) },
                                    appLock: UserDefaults.standard.bool(forKey: AppLock.enabledKey))
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save(_ tallies: UsageTallies, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(tallies), forKey: key)
    }
}

extension URLSessionConfiguration {
    static var usageReports: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }
}
