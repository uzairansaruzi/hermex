enum ChatGitControlsVisibilityPolicy {
    static func showsInlineCommitButton(
        showsGitControls: Bool,
        hasRepository: Bool,
        supportsWrites: Bool,
        isStreaming: Bool,
        latestMessageRole: String?,
        hasCommittableChanges: Bool,
        isCommitting: Bool
    ) -> Bool {
        showsGitControls
            && hasRepository
            && supportsWrites
            && !isStreaming
            && latestMessageRole == "assistant"
            && (hasCommittableChanges || isCommitting)
    }

    static func showsTurnChangesRecap(
        showsGitControls: Bool,
        hasRepository: Bool,
        isStreaming: Bool,
        latestMessageRole: String?
    ) -> Bool {
        showsGitControls
            && hasRepository
            && !isStreaming
            && latestMessageRole == "assistant"
    }
}
