import SwiftUI

/// The app's version and its outside links: policy, support, and the ways to back it.
struct SettingsAboutPage: View {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
    }

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "Version"), value: Self.appVersion)
                LabeledContent(String(localized: "Build"), value: appBuild)
            }

            Section {
                SettingsExternalLink(title: String(localized: "Privacy Policy"), systemImage: "hand.raised", destination: AppConfig.privacyPolicyURL)
                SettingsExternalLink(title: String(localized: "Support"), systemImage: "questionmark.circle", destination: AppConfig.supportURL)
                SettingsExternalLink(
                    title: String(localized: "Report a Problem"),
                    systemImage: "ladybug",
                    destination: AppConfig.reportProblemURL,
                    accessibilityLabel: String(localized: "Report a Problem, opens in browser")
                )
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
