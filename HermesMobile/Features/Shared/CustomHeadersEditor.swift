import SwiftUI

/// Add/remove editor for custom request headers, shared by Add Server's Connection Options,
/// a webui server's settings and a Hermes connection. Binds directly to the header list; the
/// owner decides when to persist. See issue #255. The owner may hide a row as it is edited
/// (Connection Options moves Cloudflare Access's rows to their own fields), so rows bind by
/// id, never by index (#1705).
struct CustomHeadersEditor: View {
    @Binding var headers: [CustomHeader]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(headers) { header in
                headerRow($headers.row(header))
            }

            Button {
                headers.append(CustomHeader())
            } label: {
                Label("Add Header", systemImage: "plus.circle.fill")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add header")

            Text("Sent with every request to your server, including media and live streams. Use for a reverse proxy (e.g. Authentik) or token auth, such as an Authorization header.")
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
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
                        .foregroundStyle(.appPrimary)
                        .accessibilityLabel("Header name")
                }

                Button {
                    remove(header.wrappedValue)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(AppFont.title3())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove header")
            }

            field {
                headerValueField(header.value)
                    .foregroundStyle(.appPrimary)
                    .accessibilityLabel("Header value")
            }
        }
    }

    private func headerNameField(_ text: Binding<String>) -> TextField<Text> {
        #if targetEnvironment(macCatalyst)
        TextField("Header name", text: text,
                  prompt: Text("Header name").foregroundStyle(Color(.appTextSecondary)))
        #else
        TextField("Header name", text: text)
        #endif
    }

    private func headerValueField(_ text: Binding<String>) -> SecureField<Text> {
        #if targetEnvironment(macCatalyst)
        SecureField("Value", text: text,
                    prompt: Text("Value").foregroundStyle(Color(.appTextSecondary)))
        #else
        SecureField("Value", text: text)
        #endif
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(AppFont.subheadline())
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

extension Binding where Value == [CustomHeader] {
    /// A binding to the row with `snapshot`'s id, wherever it now sits. Once the row is gone
    /// it reads `snapshot` and drops writes, so a field SwiftUI still holds can't read past
    /// the end of a list that just shrank.
    func row(_ snapshot: CustomHeader) -> Binding<CustomHeader> {
        Binding<CustomHeader>(
            get: { wrappedValue.first { $0.id == snapshot.id } ?? snapshot },
            set: { header in
                guard let index = wrappedValue.firstIndex(where: { $0.id == snapshot.id }) else { return }
                wrappedValue[index] = header
            }
        )
    }
}
