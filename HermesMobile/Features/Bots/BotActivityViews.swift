import SwiftUI

/// Settled or live activity in the Sessions log-row style: the reasoning row
/// above the tool rows, both behind the shared "Thinking and Tool Cards" setting.
struct BotActivityBlocksView: View {
    let id: String
    let reasoning: String?
    let toolCalls: [ToolCall]
    var isLive = false

    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) private var showsCards = true

    var body: some View {
        if showsCards {
            if let reasoning, !reasoning.isEmpty {
                ReasoningBlockView(text: reasoning, liveStreamID: isLive ? "\(id)-reasoning" : nil)
            }
            if !toolCalls.isEmpty {
                ToolActivityGroupView(group: ToolCallGroup(id: "\(id)-tools", anchorMessageID: nil, toolCalls: toolCalls), isLive: isLive)
            }
        }
    }
}
