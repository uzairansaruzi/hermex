import Foundation

enum AppConfig {
    static let tipURL = URL(staticString: "https://buymeacoffee.com/callmeuzi")
    static let membershipURL = URL(staticString: "https://buymeacoffee.com/callmeuzi/membership")
    static let writeReviewURL = URL(staticString: "https://apps.apple.com/app/id6767006319?action=write-review")
    /// GitHub's issue template chooser: Report a Problem's fallback when the app can't prefill the bug form.
    static let reportProblemURL = URL(staticString: "https://github.com/uzairansaruzi/hermex/issues/new/choose")
    /// The bug report form; `SupportReport.issueURL` fills in its version inputs.
    static let bugReportURL = URL(staticString: "https://github.com/uzairansaruzi/hermex/issues/new?template=bug_report.yml")
    static let privacyPolicyURL = URL(staticString: "https://www.uzairansar.com/hermes-mobile/privacy")
    static let supportURL = URL(staticString: "https://www.uzairansar.com/hermes-mobile")
}

extension URL {
    init(staticString string: StaticString) {
        let value = string.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid static URL literal: \(value)")
        }
        self = url
    }
}
