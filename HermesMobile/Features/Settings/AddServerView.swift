import AuthenticationServices
import SwiftUI

/// Add Server: onboarding's connect form (`OnboardingViewModel`, #900) in a sheet, plus
/// the new server's identity. A webui address goes through `AuthManager.addServer`, which
/// never disturbs the active server on failure (#17); a Hermes dashboard gets username
/// and password and becomes a Hermes server. Presented from Settings and from the
/// avatar's long-press switcher on every home (#283, #899), and as "Sign In to Hermes" from
/// Move to Hermes's host choice (#1266), which adds the server without switching to it.
struct AddServerView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    /// Told the address of the server it added, before the sheet closes.
    private let onAdded: (URL) -> Void
    @State private var form: OnboardingViewModel
    /// The Add in flight; closing the sheet cancels it before a Hermes server is added.
    @State private var operation: Task<Void, Never>?
    @State private var isConfirmingReplace = false
    @State private var displayName = ""
    @State private var initials = ""
    @State private var colorHex = HeaderLogoColor.defaultHex

    init(authManager: AuthManager, moveSource: OnboardingViewModel.MoveSource? = nil, onAdded: @escaping (URL) -> Void = { _ in }) {
        self.authManager = authManager
        self.onAdded = onAdded
        _form = State(initialValue: OnboardingViewModel(entry: .addServer, moveSource: moveSource))
    }

    private var canSubmit: Bool { form.canSubmit && !form.isWorking }
    private var isMoveSignIn: Bool { form.moveSource != nil }
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SettingsCard(title: String(localized: "Network")) {
                        ConnectionModePicker(selection: $form.connectionMode)
                        SettingsFootnote(form.connectionMode.help)
                    }
                    .disabled(form.isConnectionLocked)

                    VStack(alignment: .leading, spacing: 10) {
                        SettingsCard(title: String(localized: "Server")) {
                            serverFields
                        }
                        .disabled(form.isConnectionLocked)

                        statusBanner
                            .padding(.horizontal, 4)
                    }

                    SettingsCard(title: String(localized: "Connection Headers")) {
                        if let source = form.moveSource, form.offersMoveSourceHeaders {
                            moveSourceHeadersRow(source)
                        }
                        if form.connectionMode == .cloudflareTunnel {
                            SettingsFootnote(String(localized: "Cloudflare Access: paste your service token’s Client ID and Client Secret as the values. Leave both empty if Access is off."))
                        }
                        CustomHeadersEditor(headers: $form.customHeaders)
                        if let source = form.moveSource, !source.headers.isEmpty {
                            SettingsFootnote(form.usedMoveSourceHeaders
                                ? String(localized: "Copied from \(source.name). Edit or remove them if this host uses a different token.")
                                : String(localized: "If the same Cloudflare Access protects both hosts, \(source.name)’s service token works here too."))
                        }
                    }
                    .disabled(form.isConnectionLocked)

                    SettingsCard(title: String(localized: "Identity")) {
                        ServerIdentityEditor(
                            displayName: $displayName,
                            initials: $initials,
                            colorHex: $colorHex,
                            fallbackName: form.addressPreview?.host ?? ""
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(Color(.systemBackground))
            .navigationTitle(isMoveSignIn ? String(localized: "Sign In to Hermes") : String(localized: "Add Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMoveSignIn ? String(localized: "Sign In") : String(localized: "Add"), action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        .confirmationDialog("Replace the webui server?", isPresented: $isConfirmingReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { submit(replacingWebuiServer: true) }
        } message: {
            Text("Its sign-in, cached chats and drafts are removed from this iPhone. Conversations on the host stay.")
        }
        .adaptiveFormPresentation()
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder
    private var serverFields: some View {
        SettingsTextFieldRow(
            title: String(localized: "URL"),
            text: $form.serverURLString,
            placeholder: form.connectionMode.placeholder,
            keyboardType: .URL,
            autocapitalization: .never,
            submitLabel: .go,
            isStacked: true,
            onSubmit: submit
        )

        // The trailing mark keeps a URL ending in a neutral character, such as an
        // IPv6 literal's "]", in one left-to-right run inside right-to-left text.
        if let preview = form.addressPreview {
            Text("Will connect to \(preview.absoluteString + "\u{200E}")")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if form.showsHermesCredentials {
            savedSignInRows

            SettingsDivider()

            SettingsTextFieldRow(
                title: String(localized: "Username"),
                text: $form.username,
                placeholder: String(localized: "Dashboard username"),
                autocapitalization: .never,
                submitLabel: .next
            )
        }

        if form.showsPasswordField {
            SettingsDivider()

            SettingsTextFieldRow(
                title: String(localized: "Password"),
                text: $form.password,
                placeholder: form.detectedKind == .hermes
                    ? String(localized: "Dashboard password") : String(localized: "Server password"),
                autocapitalization: .never,
                isSecure: true,
                submitLabel: .go,
                onSubmit: submit
            )
        }
    }

    /// One row per webui server whose Hermes connection uses exactly this address, or the
    /// note that the fields came from one.
    @ViewBuilder
    private var savedSignInRows: some View {
        if let reused = form.reusedSignIn {
            Label("Filled in from \(reused.serverName)’s Hermes connection.", systemImage: "checkmark.circle")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        } else {
            ForEach(form.savedSignIns, id: \.connection.id) { saved in
                Button {
                    form.useSavedSignIn(saved)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.key.fill")
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use the sign-in saved on \(saved.serverName)")
                                .font(AppFont.subheadline(weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Text("Fills in the username, password and headers.")
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Use the sign-in saved on \(saved.serverName)"))
                .accessibilityHint(Text("Fills in the username, password and headers."))
            }
        }
    }

    /// "Use <webui server>'s Headers" (#1266): one tap fills the move source's headers in, visibly.
    private func moveSourceHeadersRow(_ source: OnboardingViewModel.MoveSource) -> some View {
        Button {
            form.useMoveSourceHeaders()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use \(source.name)’s Headers")
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("\(source.headers.count) headers")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// What the last Add found, under the address it is about.
    @ViewBuilder
    private var statusBanner: some View {
        if form.isWorking {
            SettingsFootnote(String(localized: "Checking server…"))
        } else if form.showsHermesSignIn, form.errorMessage == nil {
            switch form.signInMethod {
            case .password:
                SettingsFootnote(String(localized: "Hermes dashboard found. Sign in with your dashboard username and password."))
            case .browser:
                SettingsFootnote(String(localized: "Hermes dashboard found. It signs in through your browser."))
            case .open:
                Label(HermesSignInMethod.openWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(AppFont.footnote())
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hermes-open-dashboard-warning")
            }
        } else if form.showsPasswordField, form.detectedKind != .hermes, form.errorMessage == nil {
            SettingsFootnote(String(localized: "This server requires a password."))
        }

        if let errorMessage = form.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if form.offersWebuiReplace {
            SettingsButton(String(localized: "Replace…")) { isConfirmingReplace = true }
                .disabled(form.isConnectionLocked)
        }
    }

    private func submit() { submit(replacingWebuiServer: false) }

    private func submit(replacingWebuiServer: Bool) {
        guard canSubmit, !form.isConnectionLocked else { return }
        operation = Task {
            // A URL means the server is already saved, so its chosen identity applies even
            // when the sheet closed meanwhile.
            guard let url = await form.connect(authManager: authManager, replacingWebuiServer: replacingWebuiServer,
                                               browser: .init(webAuthenticationSession)) else { return }
            // A replaced webui server's name, initials and color stay unless new ones were chosen.
            let choseIdentity = !displayName.isEmpty || !initials.isEmpty || colorHex != HeaderLogoColor.defaultHex
            if !replacingWebuiServer || choseIdentity { applyIdentity(to: url) }
            if !Task.isCancelled { onAdded(url) }
            dismiss()
        }
    }

    /// Overrides the new server's seeded identity (the registry seeds it from the
    /// previous active server's global defaults) with the add-flow's chosen values.
    private func applyIdentity(to url: URL) {
        guard let account = authManager.servers.first(where: { $0.id == url.absoluteString }) else { return }

        let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host ?? account.displayName)
            : displayName
        let finalInitials = SessionIdentitySettings.displayInitials(
            displayName: finalName,
            storedInitials: initials,
            fallbackFullName: url.host ?? finalName
        )
        authManager.updateServerIdentity(
            account,
            displayName: finalName,
            initials: finalInitials,
            headerLogoColorHex: colorHex
        )
    }
}

/// Reusable per-server identity editor (display name, initials, Header Logo Color),
/// used by the add-server flow and the server page (#17).
struct ServerIdentityEditor: View {
    @Binding var displayName: String
    @Binding var initials: String
    @Binding var colorHex: String
    /// Host-derived fallback used for the avatar preview when fields are empty.
    let fallbackName: String

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: displayName.isEmpty ? fallbackName : displayName,
            storedInitials: initials,
            fallbackFullName: fallbackName
        )
    }

    private var initialsBinding: Binding<String> {
        Binding(
            get: { initials },
            set: { initials = SessionIdentitySettings.normalizedInitials($0) }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { HeaderLogoColor.color(for: colorHex) },
            set: { if let hex = HeaderLogoColor.hexString(from: $0) { colorHex = hex } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ServerAvatarBadge(initials: previewInitials, colorHex: colorHex, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Server Avatar")
                        .font(AppFont.subheadline(weight: .medium))

                    Text("Stored on this device only.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsTextFieldRow(
                title: String(localized: "Display Name"),
                text: $displayName,
                placeholder: fallbackName.isEmpty ? String(localized: "Server") : fallbackName
            )

            SettingsDivider()

            SettingsTextFieldRow(title: String(localized: "Initials"), text: initialsBinding, placeholder: previewInitials)

            SettingsDivider()

            HeaderLogoColorSettings(selectedHex: $colorHex, customColor: colorBinding)
        }
    }
}

// The add-server form keeps its card layout; Settings' own pages are lists (#1252).
private struct SettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .body) private var contentSpacing: CGFloat = 12

    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: contentSpacing) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(.secondarySystemBackground).opacity(cardFillOpacity))
            }
            .adaptiveGlass(
                .regular,
                fallbackMaterial: .regularMaterial,
                in: shape
            )
            .overlay {
                shape
                    .stroke(Color.primary.opacity(cardStrokeOpacity), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
    }

    private var cardFillOpacity: Double {
        reduceTransparency ? 1 : 0.34
    }

    private var cardStrokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.16 : 0.06
    }
}

private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsButton: View {
    let title: String
    var role: ButtonRole?
    var isLoading = false
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(_ title: String, role: ButtonRole? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Button(role: role, action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(role == .destructive ? .red : .primary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background {
                shape.fill((role == .destructive ? Color.red : Color.primary).opacity(0.08))
            }
            .adaptiveGlass(
                .regular,
                isInteractive: true,
                tint: role == .destructive ? .red.opacity(0.08) : nil,
                fallbackMaterial: .thinMaterial,
                in: shape
            )
            .overlay {
                shape
                    .stroke((role == .destructive ? Color.red : Color.primary).opacity(strokeOpacity), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var strokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.24 : 0.12
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 2)
            .opacity(0.72)
    }
}
