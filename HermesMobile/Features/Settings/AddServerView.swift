import AuthenticationServices
import SwiftUI

struct AddServerView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private let onAdded: (URL) -> Void
    private let isSigningInAgain: Bool
    @State private var form: OnboardingViewModel
    @State private var operation: Task<Void, Never>?
    @State private var isConfirmingReplace = false
    @State private var displayName = ""
    @State private var initials = ""
    @State private var colorHex = HeaderLogoColor.defaultHex

    init(authManager: AuthManager, entry: OnboardingViewModel.Entry = .addServer, savedServer: URL? = nil,
         moveSource: OnboardingViewModel.MoveSource? = nil, onAdded: @escaping (URL) -> Void = { _ in }) {
        self.authManager = authManager
        self.onAdded = onAdded
        isSigningInAgain = savedServer != nil
        _form = State(initialValue: OnboardingViewModel(
            entry: entry,
            moveSource: moveSource,
            savedServer: savedServer,
            savedHeaders: entry == .onboarding ? authManager.currentCustomHeaders : [],
            initialErrorMessage: savedServer == nil ? nil : authManager.lastErrorMessage
        ))
    }

    private var canSubmit: Bool { form.canSubmit && !form.isWorking }
    private var isMoveSignIn: Bool { form.moveSource != nil }

    private var title: String {
        if isMoveSignIn { return String(localized: "Sign In to Hermes") }
        return isSigningInAgain ? String(localized: "Sign In") : String(localized: "Add Server")
    }

    private var submitTitle: String {
        if form.showsHermesSignIn, form.signInMethod == .browser { return String(localized: "Sign In with Browser") }
        if form.detectedKind == nil, !form.showsPasswordField { return String(localized: "Continue") }
        return String(localized: "Connect")
    }

    private var showsSignIn: Bool {
        form.offersSignInChoice || form.browserHeaderRejection != nil || form.showsPasswordField
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsCard(title: String(localized: "Server")) {
                            addressFields
                        }
                        .disabled(form.isConnectionLocked)

                        statusLine
                            .padding(.horizontal, 4)
                    }

                    if showsSignIn {
                        SettingsCard(title: String(localized: "Sign In")) {
                            signInFields
                        }
                        .disabled(form.isConnectionLocked)
                    }

                    SettingsCard {
                        if let source = form.moveSource, !source.headers.isEmpty {
                            moveSourceHeaders(source)
                                .disabled(form.isConnectionLocked)
                        }
                        connectionOptionsRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .background(Color(.appCanvas))
            .safeAreaInset(edge: .bottom, spacing: 0) { submitButton }
            .themedPageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
    private var addressFields: some View {
        SettingsTextFieldRow(
            title: String(localized: "URL"),
            text: $form.serverURLString,
            placeholder: "https://hermes.example.com",
            keyboardType: .URL,
            autocapitalization: .never,
            submitLabel: .go,
            isStacked: true,
            onSubmit: submit
        )

        if let preview = form.addressPreview {
            Text("Will connect to \(preview.absoluteString + "\u{200E}")")
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if form.isWorking {
            SettingsFootnote(String(localized: "Checking server…"))
        } else if let errorMessage = form.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let attempt = form.failedAttempt {
                ConnectionAttemptDetails(attempt: attempt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if form.offersWebuiReplace {
                SettingsButton(String(localized: "Replace…")) { isConfirmingReplace = true }
                    .disabled(form.isConnectionLocked)
            }
        } else if form.showsHermesSignIn, form.signInMethod == .open {
            Label(HermesSignInMethod.openWarning, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("hermes-open-dashboard-warning")
        } else if form.showsHermesSignIn {
            Label {
                Text(verbatim: ["Hermes", form.hermesVersion].compactMap { $0 }.joined(separator: " "))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(AppFont.footnote(weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if form.showsPasswordField {
            SettingsFootnote(String(localized: "This server requires a password."))
        }
    }

    @ViewBuilder
    private var signInFields: some View {
        if form.offersSignInChoice {
            HermesSignInMethodPicker(selection: $form.signInMethod)
        }

        if let rejection = form.browserHeaderRejection {
            Label(rejection, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if form.showsHermesCredentials {
            savedSignInRows

            SettingsTextFieldRow(
                title: String(localized: "Username"),
                text: $form.username,
                placeholder: String(localized: "Dashboard username"),
                autocapitalization: .never,
                submitLabel: .next
            )
        }

        if form.showsPasswordField {
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

    @ViewBuilder
    private var savedSignInRows: some View {
        if let reused = form.reusedSignIn {
            Label("Filled in from \(reused.serverName)’s Hermes connection.", systemImage: "checkmark.circle")
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)
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
                                .foregroundStyle(.appSecondary)
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

    @ViewBuilder
    private func moveSourceHeaders(_ source: OnboardingViewModel.MoveSource) -> some View {
        if form.offersMoveSourceHeaders {
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
                            .foregroundStyle(.appSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
        SettingsFootnote(form.usedMoveSourceHeaders
            ? String(localized: "Copied from \(source.name). Edit or remove them if this host uses a different token.")
            : String(localized: "If the same Cloudflare Access protects both hosts, \(source.name)’s service token works here too."))
    }

    private var changedOptionCount: Int {
        form.customHeaders.filter { !$0.sanitizedName.isEmpty && !$0.sanitizedValue.isEmpty }.count
            + (displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            + (initials.isEmpty ? 0 : 1)
            + (colorHex == HeaderLogoColor.defaultHex ? 0 : 1)
    }

    private var connectionOptionsRow: some View {
        NavigationLink {
            ConnectionOptionsPage(form: form, displayName: $displayName, initials: $initials, colorHex: $colorHex)
        } label: {
            HStack(spacing: 12) {
                Text("Connection Options")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appPrimary)
                Spacer(minLength: 12)
                Group {
                    if changedOptionCount == 0 {
                        Text("Default")
                    } else {
                        Text(changedOptionCount, format: .number)
                    }
                }
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                Image(systemName: "chevron.forward")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.appTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var submitButton: some View {
        Button(action: submit) {
            Text(submitTitle)
                .font(AppFont.subheadline(weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
        }
        .buttonStyle(.appProminent)
        .controlSize(.large)
        .disabled(!canSubmit)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(.appCanvas))
    }

    private func submit() { submit(replacingWebuiServer: false) }

    private func submit(replacingWebuiServer: Bool) {
        guard canSubmit, !form.isConnectionLocked else { return }
        let savedServers = Set(authManager.servers.map(\.id))
        operation = Task {
            guard let url = await form.connect(authManager: authManager, replacingWebuiServer: replacingWebuiServer,
                                               browser: .init(webAuthenticationSession)) else { return }
            let choseIdentity = !displayName.isEmpty || !initials.isEmpty || colorHex != HeaderLogoColor.defaultHex
            if !savedServers.contains(url.absoluteString) || choseIdentity { applyIdentity(to: url) }
            if !Task.isCancelled { onAdded(url) }
            dismiss()
        }
    }

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

private struct ConnectionOptionsPage: View {
    @Bindable var form: OnboardingViewModel
    @Binding var displayName: String
    @Binding var initials: String
    @Binding var colorHex: String

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsCard(title: "Cloudflare Access") {
                    SettingsTextFieldRow(
                        title: String(localized: "Client ID"),
                        text: $form.accessClientID,
                        placeholder: "",
                        autocapitalization: .never
                    )

                    SettingsTextFieldRow(
                        title: String(localized: "Client Secret"),
                        text: $form.accessClientSecret,
                        placeholder: "",
                        autocapitalization: .never,
                        isSecure: true
                    )

                    SettingsFootnote(String(localized: "Cloudflare Access: paste your service token’s Client ID and Client Secret as the values. Leave both empty if Access is off."))
                }
                .disabled(form.isConnectionLocked)

                SettingsCard(title: String(localized: "Connection Headers")) {
                    CustomHeadersEditor(headers: $form.otherHeaders)
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
        .background(Color(.appCanvas))
        .themedPageBackground()
        .navigationTitle(String(localized: "Connection Options"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ServerIdentityEditor: View {
    @Binding var displayName: String
    @Binding var initials: String
    @Binding var colorHex: String
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
                        .foregroundStyle(.appSecondary)
                }
            }

            SettingsTextFieldRow(
                title: String(localized: "Display Name"),
                text: $displayName,
                placeholder: fallbackName.isEmpty ? String(localized: "Server") : fallbackName
            )

            SettingsTextFieldRow(title: String(localized: "Initials"), text: initialsBinding, placeholder: previewInitials)

            HeaderLogoColorSettings(selectedHex: $colorHex, customColor: colorBinding)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .body) private var contentSpacing: CGFloat = 12

    var title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .textCase(.uppercase)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: contentSpacing) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(.appSurface).opacity(cardFillOpacity))
            }
            .adaptiveGlass(
                .regular,
                fallbackMaterial: .regularMaterial,
                in: shape
            )
            .overlay {
                shape
                    .stroke(Color(.appText).opacity(cardStrokeOpacity), lineWidth: 0.7)
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
            .foregroundStyle(.appSecondary)
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
            .foregroundStyle(role == .destructive ? .red : Color(.appText))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background {
                shape.fill((role == .destructive ? Color.red : Color(.appText)).opacity(0.08))
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
                    .stroke((role == .destructive ? Color.red : Color(.appText)).opacity(strokeOpacity), lineWidth: 0.7)
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
