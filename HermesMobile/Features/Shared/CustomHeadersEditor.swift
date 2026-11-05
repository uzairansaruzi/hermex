import SwiftUI

/// Add/remove editor for custom request headers, shared by Add Server's Connection Options,
/// a webui server's settings and a Hermes connection. Binds directly to the header list; the
/// owner decides when to persist. See issue #255.
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]

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
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add header")

            Text("Sent with every request to your server, including media and live streams. Use for a reverse proxy (e.g. Authentik) or token auth, such as an Authorization header.")
                .font(.caption)
                .foregroundStyle(.appSecondary)
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
                        .foregroundStyle(.appPrimary)
                        .accessibilityLabel("Header name")
                }

                Button {
                    remove(header.wrappedValue)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove header")
            }

            field {
                SecureField("Value", text: header.value)
                    .foregroundStyle(.appPrimary)
                    .accessibilityLabel("Header value")
            }
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.appSurface), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(.appSeparator), lineWidth: 1)
            )
    }

    private func remove(_ header: CustomHeader) {
        headers.removeAll { $0.id == header.id }
    }
}
