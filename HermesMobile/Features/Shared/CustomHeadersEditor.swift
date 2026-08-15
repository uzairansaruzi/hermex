import SwiftUI

/// Add/remove editor for custom request headers, shared by the onboarding connect
/// screen (dark theme) and Settings (standard theme). Binds directly to the header
/// list; the owner decides when to persist. See issue #255.
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]
    /// Nil adopts the palette-aware standard style resolved from the environment.
    var style: Style?

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedStyle: Style {
        style ?? .standard(colorScheme: colorScheme)
    }

    struct Style {
        var primaryText: Color
        var secondaryText: Color
        var fieldBackground: Color
        var fieldStroke: Color
        var accent: Color
        var removeTint: Color

        /// Resolves the field surface from the active chat palette so the
        /// editor matches surrounding settings cards.
        static func standard(colorScheme: ColorScheme) -> Style {
            Style(
                primaryText: .primary,
                secondaryText: .secondary,
                fieldBackground: ChatPalette.appChrome(colorScheme: colorScheme).surface,
                fieldStroke: Color(.separator),
                accent: .accentColor,
                removeTint: .red
            )
        }

        static func onboarding(accent: Color) -> Style {
            Style(
                primaryText: .white,
                secondaryText: .white.opacity(0.5),
                fieldBackground: .white.opacity(0.08),
                fieldStroke: .white.opacity(0.14),
                accent: accent,
                removeTint: Color(red: 1.0, green: 0.5, blue: 0.4)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($headers) { $header in
                headerRow($header)
            }

            Button {
                headers.append(CustomHeader())
            } label: {
                Label("Add Header", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(resolvedStyle.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add header")

            Text("Sent with every request to your server, including media and live streams. Use for a reverse proxy (e.g. Authentik) or token auth, such as an Authorization header.")
                .font(.caption)
                .foregroundStyle(resolvedStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headerRow(_ header: Binding<CustomHeader>) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field {
                    TextField("Header name", text: header.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(resolvedStyle.primaryText)
                        .accessibilityLabel("Header name")
                }

                Button {
                    remove(header.wrappedValue)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(resolvedStyle.removeTint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove header")
            }

            field {
                SecureField("Value", text: header.value)
                    .foregroundStyle(resolvedStyle.primaryText)
                    .accessibilityLabel("Header value")
            }
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(resolvedStyle.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(resolvedStyle.fieldStroke, lineWidth: 1)
            )
    }

    private func remove(_ header: CustomHeader) {
        headers.removeAll { $0.id == header.id }
    }
}
