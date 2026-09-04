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
    /// How a job runs is a fixed set of questions, so the answers to them are
    /// always shown: a missing model means "Server default", not a row that
    /// silently disappears. The two exceptions earn their absence —
    /// **Provider** only qualifies an explicitly chosen model, and
    /// **Notifications** is omitted when the server did not say, because
    /// printing "On" for a value we do not have would be a guess rather than
    /// a stand-in for absence.
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

        let model = trimmed(job.model)
        fields.append(
            TaskConfigurationField(
                title: String(localized: "Model"),
                value: model ?? String(localized: "Server default")
            )
        )

        if model != nil, let provider = trimmed(job.provider) {
            fields.append(TaskConfigurationField(title: String(localized: "Provider"), value: provider))
        }

        fields.append(
            TaskConfigurationField(
                title: String(localized: "Profile"),
                value: trimmed(job.profile) ?? String(localized: "Server default")
            )
        )

        let skills = (job.skills ?? []).compactMap(trimmed)
        fields.append(
            TaskConfigurationField(
                title: String(localized: "Skills"),
                value: skills.isEmpty ? String(localized: "None") : skills.joined(separator: ", ")
            )
        )

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
