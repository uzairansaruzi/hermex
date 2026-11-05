#if DEBUG
import SwiftUI

/// The real chat components under one theme and color scheme at a time, switched with the real
/// settings: nested hosting in a reply reads the window's trait, not a local override. Debug builds only.
struct ThemeGalleryView: View {
    private static let user = ChatMessage(role: "user", content: "Fix the login retry bug", timestamp: 1, messageId: "gallery-user")
    private static let reply = ChatMessage(role: "assistant", content: """
    ## Found the cause

    The retry loop never resets `attempt`. See [AuthManager.swift](https://example.com) and $E = mc^2$.

    ```swift
    func retry(_ attempt: Int) async throws {
        guard attempt < limit else { throw RetryError.exhausted }
    }
    ```

    | Suite | Result |
    | --- | --- |
    | Auth | 12 passed |

    > Sign-in hangs after a dropped connection.
    """, timestamp: 2, messageId: "gallery-reply")

    @AppStorage(AppAppearanceSettings.lightThemeKey) private var lightTheme = ColorTheme.default
    @AppStorage(AppAppearanceSettings.darkThemeKey) private var darkTheme = ColorTheme.default
    @AppStorage(AppTheme.storageKey) private var colorScheme = AppTheme.system.rawValue

    private var theme: Binding<ColorTheme> {
        Binding {
            lightTheme
        } set: {
            lightTheme = $0
            darkTheme = $0
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker(selection: theme) {
                    ForEach(ColorTheme.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text(verbatim: "Theme")
                }
                Picker(selection: $colorScheme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Text(verbatim: "Color Scheme")
                }
                .pickerStyle(.segmented)

                MessageBubbleView(message: Self.user, transcriptMediaCacheNamespace: "")
                MessageBubbleView(message: Self.reply, transcriptMediaCacheNamespace: "")

                HStack(spacing: 12) {
                    Text(verbatim: "Secondary").foregroundStyle(.appSecondary)
                    Text(verbatim: "Tertiary").foregroundStyle(.appTertiary)
                    Text(verbatim: "Tint").foregroundStyle(.tint)
                    Button(action: {}) { Text(verbatim: "Button") }.buttonStyle(.appProminent)
                }
                .font(AppFont.footnote())

                Toggle(isOn: .constant(true)) { Text(verbatim: "Toggle") }
            }
            .padding()
        }
        .background(Color(.appCanvas))
        .navigationTitle(Text(verbatim: "Theme Gallery"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: lightTheme) { AppAppearanceSettings.applyStoredToConnectedScenes() }
    }
}
#endif
