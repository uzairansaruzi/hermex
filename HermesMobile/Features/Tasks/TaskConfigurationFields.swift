import Foundation

/// One row of Task Detail's Configuration card.
struct TaskConfigurationField: Identifiable, Equatable {
    /// The label. Unique within a card, so it is also the row's identity.
    let title: String
    let value: String
    /// A dimmer second line under the value — the raw cron expression under
    /// its English sentence. `nil` when there is nothing more to say.
    let detail: String?

    var id: String { title }

    init(title: String, value: String, detail: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
    }
}

extension TaskConfigurationField {
    /// The Configuration card's rows, in reading order.
    ///
    /// A field the job does not have does not get a row. A job that leaves the
    /// model, profile or skills to the server has nothing to say about them,
    /// and a row saying so is a line of card the reader has to discount.
    ///
    /// Schedule and Deliver are the exceptions, because every job has both:
    /// Deliver falls back to `local`, which is the server's own default rather
    /// than a stand-in for a missing value.
    static func fields(for job: CronJob) -> [TaskConfigurationField] {
        var fields: [TaskConfigurationField] = []

        let schedule = job.scheduleDescription?.sentence
            ?? job.scheduleText
            ?? String(localized: "Not available")
        fields.append(
            TaskConfigurationField(
                title: String(localized: "Schedule"),
                value: schedule,
                // Only worth a second line when it is not already the value.
                detail: job.editableScheduleText.flatMap { $0 == schedule ? nil : $0 }
            )
        )

        fields.append(
            TaskConfigurationField(
                title: String(localized: "Deliver"),
                value: trimmed(job.deliver) ?? "local"
            )
        )

        if let model = trimmed(job.model) {
            fields.append(TaskConfigurationField(title: String(localized: "Model"), value: model))
        }

        if let provider = trimmed(job.provider) {
            fields.append(TaskConfigurationField(title: String(localized: "Provider"), value: provider))
        }

        if let profile = trimmed(job.profile) {
            fields.append(TaskConfigurationField(title: String(localized: "Profile"), value: profile))
        }

        let skills = (job.skills ?? []).compactMap(trimmed)
        if !skills.isEmpty {
            fields.append(
                TaskConfigurationField(
                    title: String(localized: "Skills"),
                    value: skills.joined(separator: ", ")
                )
            )
        }

        if let toastNotifications = job.toastNotifications {
            fields.append(
                TaskConfigurationField(
                    title: String(localized: "Notifications"),
                    value: toastNotifications ? String(localized: "On") : String(localized: "Off")
                )
            )
        }

        return fields
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
