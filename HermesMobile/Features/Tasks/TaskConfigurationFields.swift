import Foundation

struct TaskConfigurationField: Identifiable, Equatable {
    let title: String
    let value: String
    let detail: String?

    var id: String { title }

    init(title: String, value: String, detail: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
    }
}

extension TaskConfigurationField {
    static func fields(for job: CronJob) -> [TaskConfigurationField] {
        var fields: [TaskConfigurationField] = []

        let schedule = job.scheduleDescription?.sentence
            ?? job.scheduleText
            ?? String(localized: "Not available")
        fields.append(
            TaskConfigurationField(
                title: String(localized: "Schedule"),
                value: schedule,
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
