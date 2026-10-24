import SwiftUI

/// Add/remove editor for custom request headers, shared by the onboarding connect
/// screen (dark theme) and Settings (standard theme). Binds directly to the header
/// list; the owner decides when to persist. See issue #255.
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]
    var style: Style = .standard

    struct Style {
        var primaryText: Color
        var secondaryText: Color
        var fieldBackground: Color
        var fieldStroke: Color
        var accent: Color
        var removeTint: Color

        static let standard = Style(
            primaryText: .primary,
            secondaryText: .secondary,
            fieldBackground: Color(.secondarySystemBackground),
            fieldStroke: Color(.separator),
            accent: .accentColor,
            removeTint: .red
        )

        static let onboarding = Style(
            primaryText: .white,
            secondaryText: .white.opacity(0.5),
            fieldBackground: .white.opacity(0.08),
            fieldStroke: .white.opacity(0.14),
            accent: Color(red: 1.0, green: 0.74, blue: 0.10),
            removeTint: Color(red: 1.0, green: 0.5, blue: 0.4)
        )
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
                    .foregroundStyle(style.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add header")

            Text("Sent with every request to your server, including media and live streams. Use for a reverse proxy (e.g. Authentik) or token auth, such as an Authorization header.")
                .font(.caption)
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headerRow(_ header: Binding<CustomHeader>) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field {
                    headerNameField(header.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(style.primaryText)
                        .accessibilityLabel("Header name")
                }

                Button {
                    remove(header.wrappedValue)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(style.removeTint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove header")
            }

            field {
                headerValueField(header.value)
                    .foregroundStyle(style.primaryText)
                    .accessibilityLabel("Header value")
            }
        }
    }

    private func headerNameField(_ text: Binding<String>) -> TextField<Text> {
        #if targetEnvironment(macCatalyst)
        TextField("Header name", text: text,
                  prompt: Text("Header name").foregroundStyle(style.secondaryText))
        #else
        TextField("Header name", text: text)
        #endif
    }

    private func headerValueField(_ text: Binding<String>) -> SecureField<Text> {
        #if targetEnvironment(macCatalyst)
        SecureField("Value", text: text,
                    prompt: Text("Value").foregroundStyle(style.secondaryText))
        #else
        SecureField("Value", text: text)
        #endif
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(style.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style.fieldStroke, lineWidth: 1)
            )
    }

    private func remove(_ header: CustomHeader) {
        headers.removeAll { $0.id == header.id }
    }
}
