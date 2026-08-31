/// Decides whether turn-end git controls belong in the chat transcript.
///
/// The Settings toggle is checked here with the existing workspace and turn
/// conditions so every transcript git surface follows the same visibility rule.
enum ChatGitControlsVisibilityPolicy {
    static func showsInlineCommitButton(
        showsGitControls: Bool,
        hasRepository: Bool,
        isStreaming: Bool,
        latestMessageRole: String?,
        hasCommittableChanges: Bool,
        isCommitting: Bool
    ) -> Bool {
        showsGitControls
            && hasRepository
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
