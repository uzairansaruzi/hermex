import UIKit

struct SupportReport {
    enum Channel: String {
        case debug = "Debug", branch = "Branch", release = "Release"
    }

    var appVersion: String?
    var build: String?
    var channel: Channel
    var iOSVersion: String
    var device: String
    var serverKind: ServerKind?
    var serverRelease: String?
    var lastAttempt: HermesAttemptRecord? = nil

    var text: String {
        var lines = [
            "Hermex support details",
            "App version: \(appVersion ?? "unknown") (\(build ?? "unknown"))",
            "Channel: \(channel.rawValue)",
            "iOS: \(iOSVersion)",
            "Device: \(device)",
            "Server kind: \(serverKindName ?? "unknown")",
            "Server release: \(serverRelease ?? "unknown")",
        ]
        if serverKind == .hermes {
            lines.append("Tested Hermes release: \(HermesCompatibility.testedVersion)")
        }
        if let lastAttempt {
            lines.append("Last connection attempt: \(lastAttempt.startedText)")
            lines += HermesAttemptRecord.Stage.allCases.map {
                "Attempt \($0.reportName.lowercased()): \(lastAttempt[$0].reportText)"
            }
        }
        return lines.joined(separator: "\n")
    }

    var troubleshootingPrompt: String {
        """
        I'm having a problem with Hermex, the iPhone app I use to reach you. Fetch
        \(AppConfig.triagePlaybookURL.absoluteString)
        and follow it to help me triage it.

        \(text)
        """
    }

    var issueURL: URL {
        guard let appVersion, let build,
              var components = URLComponents(url: AppConfig.bugReportURL, resolvingAgainstBaseURL: false) else {
            return AppConfig.reportProblemURL
        }
        let fields: [(String, String?)] = [
            ("app-version", "\(appVersion) (\(build))"),
            ("ios-version", "iOS \(iOSVersion) on \(device)"),
            ("server-version", serverKindName.flatMap { kind in serverRelease.map { "\(kind) \($0)" } }),
        ]
        components.queryItems = (components.queryItems ?? [])
            + fields.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? AppConfig.reportProblemURL
    }

    private var serverKindName: String? {
        switch serverKind {
        case .hermes: "Hermes"
        case .webui: "webui"
        case nil: nil
        }
    }
}

extension SupportReport {
    @MainActor init(server: ServerAccount?, connections: HermesConnections = .shared) {
        let info = Bundle.main.infoDictionary
        let channel: Channel
        #if DEBUG
        channel = .debug
        #else
        channel = Bundle.main.bundleIdentifier?.hasSuffix(".branch") == true ? .branch : .release
        #endif
        self.init(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            channel: channel,
            iOSVersion: UIDevice.current.systemVersion,
            device: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            serverKind: server?.kind,
            serverRelease: server?.serverVersion,
            lastAttempt: server.flatMap { URL(string: $0.id) }.flatMap { connections.lastAttempt(server: $0) }
        )
    }
}
