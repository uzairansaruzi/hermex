import SwiftUI

/// The app's version, its troubleshooting tools, and its outside links: policy, support, and
/// the ways to back it. `server` is the active server, which the support details describe.
struct SettingsAboutPage: View {
    let server: ServerAccount?

    @State private var isShowingSupportDetails = false
    @State private var diagnostics = DiagnosticsModel()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
    }

    var body: some View {
        // Rebuilt with the page, so it always describes the server that is active now.
        let report = SupportReport(server: server)
        List {
            Section {
                LabeledContent(String(localized: "Version"), value: Self.appVersion)
                LabeledContent(String(localized: "Build"), value: appBuild)
            }

            Section {
                Button {
                    isShowingSupportDetails = true
                } label: {
                    SettingsLabel(title: String(localized: "Copy Support Details"), systemImage: "doc.on.doc")
                }
                .foregroundStyle(.primary)
                NavigationLink {
                    SettingsDiagnosticsPage(model: diagnostics)
                } label: {
                    LabeledContent {
                        if let count = diagnostics.entries?.count, count > 0 {
                            Text(count, format: .number)
                        }
                    } label: {
                        SettingsLabel(title: String(localized: "Diagnostics"), systemImage: "stethoscope")
                    }
                }
                SettingsExternalLink(
                    title: String(localized: "Report a Problem"),
                    systemImage: "ladybug",
                    destination: report.issueURL,
                    accessibilityLabel: String(localized: "Report a Problem, opens in browser")
                )
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Report a Problem opens GitHub with your app, iOS and server versions filled in.")
            }

            Section {
                SettingsExternalLink(title: String(localized: "Privacy Policy"), systemImage: "hand.raised", destination: AppConfig.privacyPolicyURL)
                SettingsExternalLink(title: String(localized: "Support"), systemImage: "questionmark.circle", destination: AppConfig.supportURL)
            }

            Section {
                Group {
                    SettingsExternalLink(
                        title: String(localized: "Become a supporter"),
                        systemImage: "heart",
                        destination: AppConfig.membershipURL,
                        accessibilityLabel: String(localized: "Become a supporter, opens in browser")
                    )
                    SettingsExternalLink(
                        title: String(localized: "Buy Uzi a coffee"),
                        systemImage: "cup.and.saucer",
                        destination: AppConfig.tipURL,
                        accessibilityLabel: String(localized: "Buy Uzi a coffee, opens in browser")
                    )
                }
                .environment(\.openURL, OpenURLAction { url in
                    TipJarPromptState(defaults: .standard).recordLinkOpened()
                    return .systemAction(url)
                })

                SettingsExternalLink(
                    title: String(localized: "Rate Hermex"),
                    systemImage: "star",
                    destination: AppConfig.writeReviewURL,
                    accessibilityLabel: String(localized: "Rate Hermex, opens the App Store")
                )
            }
        }
        .settingsPage(String(localized: "About Hermex"))
        .task { await diagnostics.load() }
        .sheet(isPresented: $isShowingSupportDetails) {
            SupportDetailsSheet(text: report.text)
        }
    }
}

/// The exact text Copy puts on the pasteboard, selectable, to read before sharing (#1396).
private struct SupportDetailsSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var isCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: text)
                        .font(AppFont.footnote().monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Read this before you share it. It has no server address, name or credentials.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(String(localized: "Support Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isCopied ? String(localized: "Copied") : String(localized: "Copy")) {
                        UIPasteboard.general.string = text
                        isCopied = true
                        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
                    }
                }
            }
            // A server switch while open rebuilds the text; Copied then no longer describes it.
            .onChange(of: text) { isCopied = false }
        }
    }
}

/// Maintainer tools: Debug-only helpers, and the browser sign-in testing toggle (#708) in Debug
/// and Hermex Branch builds. Not localized.
struct SettingsDeveloperPage: View {
    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        HermesBrowserSignIn.offersTestingToggle
        #endif
    }

    /// The testing toggle `HermesBrowserSignIn.isForcedForTesting` reads.
    @AppStorage(HermesBrowserSignIn.forcedKey) private var forcesBrowserSignIn = false

    var body: some View {
        List {
            #if DEBUG
            Section {
                Button(String(localized: "Reset rating prompt state")) {
                    RatingPromptState.shared.reset()
                }

                NavigationLink {
                    ProviderGlyphGalleryView()
                } label: {
                    SettingsLabel(title: "Provider Glyphs", systemImage: "square.grid.2x2")
                }
            } footer: {
                Text(verbatim: "Debug builds only.")
            }
            #endif

            if HermesBrowserSignIn.offersTestingToggle {
                Section {
                    Toggle(isOn: $forcesBrowserSignIn) { Text(verbatim: "Browser sign-in on password hosts") }
                } footer: {
                    Text(verbatim: "Hermes hosts that offer a password sign in through the browser instead, the next time a sign-in form opens. Debug and Hermex Branch builds only.")
                }
            }
        }
        .settingsPage("Developer")
    }
}
