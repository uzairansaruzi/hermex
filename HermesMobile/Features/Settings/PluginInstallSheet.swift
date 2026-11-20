import SwiftUI

struct PluginInstallSheet: View {
    let model: PluginsModel
    let profile: String
    private let entry: HermesCatalogEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var enablesAfterInstall = true
    @State private var isInstalling = false
    @State private var refusal: String?
    @State private var canReplace = false
    @State private var isConfirmingReplace = false

    private static let refusalID = "refusal"

    init(model: PluginsModel, profile: String, entry: HermesCatalogEntry? = nil) {
        self.model = model
        self.profile = profile
        self.entry = entry
        _input = State(initialValue: entry?.name ?? "")
    }

    private var parsed: PluginInstallInput { PluginInstallInput(input) }
    private var review: PluginsModel.InstallReview { model.review(of: parsed) }

    private var source: HermesPluginSource? {
        switch review {
        case .repo(let identifier): return .repo(identifier)
        case .catalog(let entry): return model.isTooNew(entry) ? nil : .catalog(name: entry.name, pin: entry.pin)
        default: return nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                AppList {
                    if entry == nil { inputSection }
                    if let refusal { refusalSection(refusal).id(Self.refusalID) }
                    reviewSections
                    if source != nil { installOptions }
                }
                .listSectionSpacing(.compact)
                .onChange(of: refusal) { if refusal != nil { proxy.scrollTo(Self.refusalID, anchor: .top) } }
            }
            .themedPageBackground()
            .navigationTitle(entry == nil ? String(localized: "Install Plugin") : String(localized: "Review Install"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isInstalling)
                }
            }
            .safeAreaInset(edge: .bottom) { installButton }
            .scrollDismissesKeyboard(.interactively)
        }
        .interactiveDismissDisabled(isInstalling)
        .task(id: parsed) {
            if case .catalogName = parsed { await model.loadCatalog() }
        }
        .onChange(of: input) {
            refusal = nil
            canReplace = false
        }
        .alert("Replace the copy on \(profile)?", isPresented: $isConfirmingReplace) {
            Button("Replace", role: .destructive) { Task { await install(replace: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .some(.repo) = source {
                Text("This overwrites the installed plugin. Replacing also lets through anything Hermes's security scan marks as caution, without showing it to you. A dangerous result is still blocked.")
            } else {
                Text("This overwrites the installed plugin with the commit shown here.")
            }
        }
    }

    private var inputSection: some View {
        Section {
            TextField("owner/repository", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(isInstalling)
        } header: {
            Text("Repository or URL")
        } appFooter: {
            Text(verbatim: inputFooter)
        }
    }

    private var inputFooter: String {
        switch review {
        case .invalid: String(localized: "Hermex can't read that as a repository or a plugin name.")
        case .notInCatalog(let name): String(localized: "The catalog has no plugin named \(name). Enter owner/repository to install from a repository.")
        case .catalogUnavailable(let message): message
        default: String(localized: "Also takes a catalog name, hermes plugins install name, or a hermes://plugin/install link.")
        }
    }

    @ViewBuilder
    private var reviewSections: some View {
        switch review {
        case .repo(let identifier):
            Section {
                PluginWarningRow(level: .strongest, text: String(localized: "Nobody reviewed this. Hermes will download this code and run it on your host, with the same access as Hermes. It installs the latest commit, not a pinned one."))
                LabeledContent(String(localized: "Installs to")) { Text(verbatim: profile) }
                LabeledContent(String(localized: "Source")) { Text(verbatim: identifier).textSelection(.enabled) }
            }
        case .catalog(let entry):
            PluginCatalogReview(entry: entry, profile: profile, isTooNew: model.isTooNew(entry))
        case .removed(let name, let reason):
            Section {
                PluginWarningRow(level: .strongest, text: reason.isEmpty
                    ? String(localized: "Nous removed \(name) from the catalog, so it can't be installed.")
                    : String(localized: "Nous removed \(name) from the catalog, so it can't be installed: \(reason)"))
            }
        case .loadingCatalog:
            Section {
                Text("Looking in the catalog…").foregroundStyle(.appSecondary)
            }
        case .none, .invalid, .notInCatalog, .catalogUnavailable:
            EmptyView()
        }
    }

    private var installOptions: some View {
        Section {
            Toggle("Enable after install", isOn: $enablesAfterInstall)
                .disabled(isInstalling)
        } appFooter: {
            Text("Makes it available to new sessions on \(profile).")
        }
    }

    private func refusalSection(_ message: String) -> some View {
        Section {
            PluginWarningRow(level: .strongest, text: message)
            if canReplace {
                Button(String(localized: "Replace…"), role: .destructive) { isConfirmingReplace = true }
                    .disabled(isInstalling)
            }
        }
    }

    private var installButton: some View {
        VStack(spacing: 6) {
            Button {
                Task { await install(replace: false) }
            } label: {
                Text(isInstalling ? String(localized: "Installing…") : String(localized: "Install on \(profile)"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.appProminent)
            .controlSize(.large)
            .disabled(source == nil || isInstalling)
            if isInstalling {
                Text("The host is downloading it, which can take a few minutes.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.appMaterial(.bar))
    }

    private func install(replace: Bool) async {
        guard let source, !isInstalling else { return }
        isInstalling = true
        refusal = nil
        let result = await model.install(source, profile: profile, replace: replace, enable: enablesAfterInstall)
        isInstalling = false
        switch result {
        case .finished: dismiss()
        case .alreadyExists(let message):
            refusal = message
            canReplace = true
        case .refused(let message):
            refusal = message
            canReplace = false
        }
    }
}

struct PluginCatalogReview: View {
    let entry: HermesCatalogEntry
    var profile: String?
    let isTooNew: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title).font(AppFont.headline())
                Text(verbatim: [entry.tier.title, entry.maintainer, entry.version].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
            if isTooNew {
                PluginWarningRow(level: .strongest, text: String(localized: "This plugin needs Hermes \(entry.minimumHermes) or later, so this host can't install it yet."))
            }
            if let profile {
                PluginWarningRow(level: warningLevel, text: warning)
                LabeledContent(String(localized: "Installs to")) { Text(verbatim: profile) }
            }
            LabeledContent(String(localized: "Source")) { Text(verbatim: entry.source).textSelection(.enabled) }
            LabeledContent(String(localized: "Commit")) { Text(verbatim: entry.commit).monospaced() }
            if !entry.requiredKeys.isEmpty {
                LabeledContent(String(localized: "Needs key")) {
                    Text(verbatim: entry.requiredKeys.joined(separator: ", ")).monospaced().textSelection(.enabled)
                }
            }
            if entry.needsDesktop {
                LabeledContent(String(localized: "Needs")) { Text("Hermes Desktop") }
            }
            if !entry.platforms.isEmpty {
                LabeledContent(String(localized: "Runs on")) { Text(verbatim: entry.platforms.joined(separator: ", ")) }
            }
            if let url = githubURL {
                Link(String(localized: "Open on GitHub"), destination: url)
            }
        }
        if !entry.summary.isEmpty {
            Section(String(localized: "About")) { Text(verbatim: entry.summary).font(AppFont.footnote()) }
        }
        if let disclosure = entry.disclosure {
            Section(String(localized: "Disclosure")) { Text(verbatim: disclosure).font(AppFont.footnote()) }
        }
        if !entry.knownIssues.isEmpty {
            Section(String(localized: "Known Issues")) {
                ForEach(entry.knownIssues, id: \.self) { Text(verbatim: $0).font(AppFont.footnote()) }
            }
        }
    }

    private var warningLevel: PluginWarningRow.Level { entry.tier == .community ? .strong : .plain }

    private var warning: String {
        switch entry.tier {
        case .official: String(localized: "Nous maintains this plugin. It still runs on your host with the same access as Hermes.")
        case .verified: String(localized: "Nous verified this comes from the company whose product it integrates. It still runs on your host with the same access as Hermes.")
        case .community: String(localized: "Nous reviewed this listing at this commit. It still runs on your host with the same access as Hermes. Install only what you trust.")
        }
    }

    private var githubURL: URL? {
        guard let url = URL(string: entry.repo), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }
}

extension HermesCatalogEntry.Tier {
    var title: String {
        switch self {
        case .official: String(localized: "Official")
        case .verified: String(localized: "Verified")
        case .community: String(localized: "Community")
        }
    }
}

private struct PluginWarningRow: View {
    enum Level { case plain, strong, strongest }

    let level: Level
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text).font(AppFont.footnote())
        } icon: {
            switch level {
            case .plain: Image(systemName: "info.circle.fill").foregroundStyle(.appSecondary)
            case .strong: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .strongest: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}

struct PluginSetupSection: View {
    let setup: PluginsModel.PluginSetup
    let model: PluginsModel

    var body: some View {
        Section {
            ForEach(setup.keys, id: \.self) { PluginKeyRow(name: $0, model: model) }
            Button("Not Now") { model.dismissSetup() }
        } header: {
            Text("Finish Setup")
        } appFooter: {
            Text("\(setup.name) needs these on \(setup.profile) before it can run.")
        }
    }
}

private struct PluginKeyRow: View {
    let name: String
    let model: PluginsModel

    @State private var value = ""
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: name).font(.footnote.monospaced())
            SecureField("Paste the key", text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let failure {
                Text(verbatim: failure).font(AppFont.footnote()).foregroundStyle(.red)
            }
            Button("Save Key") { Task { await save() } }
                .buttonStyle(.borderless)
                .disabled(value.isEmpty || isSaving)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        failure = nil
        do {
            try await model.saveKey(name, value: value)
            value = ""
        } catch {
            failure = error.localizedDescription
        }
    }
}
