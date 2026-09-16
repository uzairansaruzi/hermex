import SwiftUI

/// Pushed from the editor's Expression row: a large live preview of the draft face
/// above the sixteen named rest expressions. Tapping a tile edits the draft only;
/// Save on the editor persists it.
@MainActor struct BotExpressionPickerView: View {
    let editor: BotProfileEditor

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private var selected: BotAvatarExpression { BotAvatarExpression.resolve(editor.draft.appearance.expression) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BotAnimatedFaceView(name: editor.profile.id, appearance: editor.draft.appearance, size: 132)
                    .padding(.top, 20)
                    .accessibilityLabel(selected.localizedName)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(BotAvatarExpression.allCases) { expression in
                        Button { editor.setExpression(expression) } label: {
                            VStack(spacing: 4) {
                                BotAvatarMarkView(name: editor.profile.id, appearance: appearance(expression), size: 52)
                                Text(expression.localizedName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 78)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                if selected == expression {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.secondary, lineWidth: 2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expression.localizedName)
                        .accessibilityAddTraits(selected == expression ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Expression")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func appearance(_ expression: BotAvatarExpression) -> BotProfileAppearance {
        var appearance = editor.draft.appearance
        appearance.expression = expression.rawValue; appearance.custom = true; appearance.imageKind = "shape"
        return appearance
    }
}
