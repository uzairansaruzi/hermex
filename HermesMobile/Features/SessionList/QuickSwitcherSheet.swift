import SwiftUI
import UIKit

/// The quick switcher (#1415): a sheet that only navigates. Its search owns the
/// field's focus, so the rows' ↑/↓ and Return are handled by the field itself
/// (`QuickSwitcherSearchField`) rather than `List` selection, and Return during a
/// marked-text composition only commits the composition — it never navigates.
struct QuickSwitcherSheet: View {
    let snapshot: QuickSwitcherSnapshot
    /// Called for the picked row; the owner dismisses the sheet before it routes.
    let onPick: (QuickSwitcherItem) -> Void

    @State private var query = ""
    /// The selected row's identity, stable across filter changes: a row that still
    /// matches keeps the selection, and a filtered-out one hands it to the first match.
    @State private var selection: QuickSwitcherItem?

    private var items: [QuickSwitcherItem] {
        QuickSwitcherModel.items(
            sessions: snapshot.sessions, bots: snapshot.bots, destinations: snapshot.destinations,
            query: query, openSessionKey: snapshot.openSessionKey
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No Matches", systemImage: "magnifyingglass")
                } else {
                    list
                }
            }
            .navigationTitle("Quick Switcher")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: query) {
            let current = items
            guard !current.contains(selection) else { return }
            selection = current.first
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                Button {
                    pick(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .listRowBackground(item == selection ? Color.accentColor.opacity(0.14) : Color.clear)
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top) {
            QuickSwitcherSearchField(text: $query, placeholder: String(localized: "Search sessions, bots, and destinations"),
                                     onMove: moveSelection, onReturn: pickSelection)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    @ViewBuilder private func row(_ item: QuickSwitcherItem) -> some View {
        HStack(spacing: 12) {
            icon(item)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle = subtitle(for: item) {
                    Text(verbatim: subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44, alignment: .center)
        .contentShape(Rectangle())
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: item))
    }

    private func icon(_ item: QuickSwitcherItem) -> some View {
        switch item {
        case .session:
            Image(systemName: "bubble.left.and.bubble.right")
        case .bot:
            Image("LucideBot")
        case .utility(.tasks):
            Image("LucideCalendarClock")
        case .utility(.kanban):
            Image("LucideColumns3")
        case .utility(.skills):
            Image("LucideHammer")
        case .utility(.memory):
            Image("LucideBrain")
        case .utility(.insights):
            Image("LucideChartColumnIncreasing")
        case .utility(.archived):
            Image(systemName: "archivebox")
        default:
            Image(systemName: "gearshape")
        }
    }

    private func subtitle(for item: QuickSwitcherItem) -> String? {
        switch item {
        case .session(_, let profile, _):
            return profile
        case .bot(_, let title):
            // The title is the bot's display name when it has one, so its Profile
            // name reads as the detail; a bot without one would only be repeated.
            let name = botName(item)
            return name.isEmpty || name == title ? nil : name
        case .utility:
            return nil
        }
    }

    private func botName(_ item: QuickSwitcherItem) -> String {
        guard case .bot(let profile, _) = item,
              let bot = snapshot.bots.first(where: { $0.id == profile }) else { return "" }
        return bot.name
    }

    /// VoiceOver reads what the row is before what it says: "Session, <title>,
    /// <Profile>", "Bot, <name>", and a destination by its own title.
    private func accessibilityLabel(for item: QuickSwitcherItem) -> Text {
        switch item {
        case .session(_, let profile, let title):
            return Text("Session, \(title), \(profile ?? "")")
        case .bot(let profile, _):
            let name = snapshot.bots.first(where: { $0.id == profile }).map { $0.displayName ?? $0.name } ?? profile
            return Text("Bot, \(name)")
        case .utility(let destination):
            return Text(verbatim: QuickSwitcherItem.utilityTitle(destination))
        }
    }

    /// ↓ and ↑ walk the rows, stopping at the ends; from no selection, ↓ takes the
    /// first row and ↑ the last.
    private func moveSelection(_ offset: Int) {
        let current = items
        guard !current.isEmpty else { return }
        let index = current.firstIndex(of: selection).map { $0 + offset }
            ?? (offset > 0 ? current.startIndex : current.index(before: current.endIndex))
        selection = current[min(max(index, current.startIndex), current.index(before: current.endIndex))]
    }

    /// Return opens the selection, or the first row when none has been taken yet.
    private func pickSelection() {
        guard let item = selection ?? items.first else { return }
        pick(item)
    }

    private func pick(_ item: QuickSwitcherItem) {
        onPick(item)
    }
}

/// The switcher's search field: a plain text field, so the palette can act on
/// Return and the arrow keys itself. Return while a marked-text composition (an
/// IME, e.g. pinyin) is live only commits the composition — `markedTextRange`
/// decides, the same rule the composer's editor keeps (#312).
private struct QuickSwitcherSearchField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// +1 moves the selection down, -1 up.
    let onMove: (Int) -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> QuickSwitcherTextField {
        let field = QuickSwitcherTextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .go
        field.accessibilityLabel = placeholder
        field.onMove = onMove
        field.onReturn = onReturn
        // The sheet presents with search owning focus, so keyboard movement works
        // at once; the first responder pass has to wait out the presentation.
        DispatchQueue.main.async { [weak field] in field?.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: QuickSwitcherTextField, context: Context) {
        if field.text != text { field.text = text }
        field.onMove = onMove
        field.onReturn = onReturn
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard let field = textField as? QuickSwitcherTextField else { return false }
            // A composition's Return commits the marked text and navigates nothing.
            guard field.markedTextRange == nil else { return false }
            field.onReturn?()
            return false
        }
    }
}

/// The text field that reports the hardware keyboard's arrows to the sheet while
/// the field keeps focus.
final class QuickSwitcherTextField: UITextField {
    var onMove: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardUpArrow where markedTextRange == nil:
                onMove?(-1); handled = true
            case .keyboardDownArrow where markedTextRange == nil:
                onMove?(1); handled = true
            default:
                break
            }
        }
        guard !handled else { return }
        super.pressesBegan(presses, with: event)
    }
}
