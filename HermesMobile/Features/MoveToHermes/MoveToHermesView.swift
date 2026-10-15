import SwiftData
import SwiftUI
import UIKit

/// The guided Move to Hermes sheet (#1218): host choice (D), the checking scan (A1b), refusals
/// (R), Review with Profile mapping (A2, M), progress (A3), paused details and pauses (finish-early
/// A, 3A, 4C), and the report kept until Done (A4). Static rows, no spinners or repeating
/// animation. Closing it pauses a move; Done switches to the destination. The report can also
/// remove the webui server or move the next one in this sheet (#1268).
struct MoveToHermesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var model: MoveToHermesModel
    @State private var isSigningIn = false
    @State private var isConfirmingFinish = false
    @State private var isConfirmingRemove = false
    @State private var copiedPrompt = false
    private let auth: AuthManager
    private let entry: MoveToHermesEntry

    init(auth: AuthManager, sourceID: String, entry: MoveToHermesEntry) {
        self.auth = auth
        self.entry = entry
        _model = State(initialValue: MoveToHermesModel(auth: auth, sourceID: sourceID))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task { model.open(entry) }
        .onDisappear { model.close() }
        .sheet(isPresented: $isSigningIn) {
            AddServerView(authManager: auth, moveSource: .init(name: source, headers: model.sourceHeaders)) {
                model.signedIn(at: $0)
            }
        }
        .alert("Finish without the rest?", isPresented: $isConfirmingFinish) {
            Button("Finish Move", role: .destructive) { model.finishEarly() }
            Button("Keep Paused", role: .cancel) {}
        } message: {
            Text(finishMessage)
        }
        .alert(String(localized: "Remove \(source)?"), isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Server", role: .destructive) { removeSource() }
        } message: {
            if let account = model.source {
                Text(MoveToHermesRemoval.message(for: account, servers: auth.servers) ?? "")
            }
        }
    }

    private var source: String { model.sourceName }
    private var destination: String { model.destinationName }

    private var title: String {
        switch model.screen {
        case .chooseHost: String(localized: "Which Hermes host?")
        case .checking: String(localized: "Checking")
        case .review: String(localized: "Review")
        case .progress: String(localized: "Moving")
        case .paused(.workLeft), .paused(.cancelled), .paused(.destinationUnavailable), .paused(.saveFailed):
            String(localized: "Move Paused")
        case .finished(let report): report.finishedEarly ? String(localized: "Finished Early") : String(localized: "Moved")
        case .loading, .refused, .paused, .couldNotStart: ""
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.screen {
        case .chooseHost, .checking, .review, .refused:
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        case .paused:
            ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
        // The report's Done is its first button (5A).
        case .loading, .progress, .finished, .couldNotStart:
            ToolbarItem(placement: .cancellationAction) { EmptyView() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .loading: Color.clear
        case .chooseHost: hostChoice
        case .checking: checking
        case .refused(let refusal): refused(refusal)
        case .review: review
        case .progress(let step): progress(step)
        case .paused(let pause): paused(pause)
        case .finished(let report):
            MoveToHermesReportView(report: report, source: source, destination: destination, keptProfiles: keptProfiles,
                                   canCopyAgain: model.source != nil, next: model.nextSource.map(MoveToHermesModel.name),
                                   copyAgain: model.copyMissingChatsAgain, done: finish, moveNext: moveNext,
                                   remove: model.source == nil ? nil : { isConfirmingRemove = true })
        case .couldNotStart(let failure): couldNotStart(failure)
        }
    }

    /// Done acknowledges the report, then switches to the destination.
    private func finish() {
        model.done()
        dismiss()
    }

    /// "Move <next> Next" shows the next webui server's move in this sheet.
    private func moveNext() {
        if let next = model.moveNext() { model = next }
    }

    /// Remove's confirmation: switches to the destination as Done does, then removes the webui
    /// server. The removal outlives the sheet, which the switch may tear down.
    private func removeSource() {
        let model = model
        let modelContext = modelContext
        Task { await model.removeSource(modelContext: modelContext) }
        dismiss()
    }

    private var keptProfiles: [String] {
        auth.moveRecord(forSource: model.sourceID)?.record.profiles.filter { $0.destination == .keepOnWebui }.map(\.source) ?? []
    }

    // MARK: D

    private var hostChoice: some View {
        List {
            Section {
                Text(model.savedHost == nil ? String(localized: "\(source) has no saved Hermes sign-in. Pick the host that should take its chats.")
                                            : String(localized: "Pick the host that should take \(source)’s chats. The first is its saved Hermes sign-in."))
                    .foregroundStyle(.secondary)
            }
            Section {
                if let saved = model.savedHost {
                    Button { model.useSaved() } label: {
                        MoveToHermesRow(title: saved.name.isEmpty ? Self.hostAndPort(saved.address.absoluteString) : saved.name,
                                        detail: Self.hostAndPort(saved.address.absoluteString), chevron: true)
                    }
                }
                ForEach(model.hostChoices) { server in
                    Button { model.choose(server) } label: {
                        MoveToHermesRow(title: MoveToHermesModel.name(server),
                                        detail: String(localized: "\(Self.hostAndPort(server.urlString)) · added"),
                                        chevron: true)
                    }
                }
                Button { isSigningIn = true } label: {
                    MoveToHermesRow(title: String(localized: "Sign in to a Hermes host"),
                                    detail: String(localized: "Password or browser sign-in"), chevron: true)
                }
            }
        }
    }

    /// A host as D lists it: with its port, so two hosts on one machine read apart.
    private static func hostAndPort(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    // MARK: A1b

    private var checking: some View {
        let state = model.checking
        let failed = state.hostError != nil || state.webuiFailed
        return List {
            Section {
                MoveToHermesStep(state: state.signedIn ? .done : (state.hostError != nil ? .failed : .current(1)),
                                 title: String(localized: "Signed in to \(destination)"), detail: state.hostError)
                MoveToHermesStep(
                    state: state.webuiFailed ? .failed : (state.chats != nil ? .done : (state.signedIn ? .current(2) : .waiting)),
                    title: state.webuiFailed ? String(localized: "Couldn’t read \(source)’s chats") : String(localized: "Read \(source)’s chats"),
                    detail: state.webuiFailed
                        ? String(localized: "\(source) didn’t answer. Check that it’s running and that you’re signed in.")
                        : state.chats.map { String(localized: "\($0) chats") })
                MoveToHermesStep(state: state.chats == nil || failed ? .waiting : .current(3),
                                 title: String(localized: "Checking which are in \(destination)"),
                                 detail: state.chats.map { String(localized: "Checked \(state.located) of \($0)") })
            } footer: {
                Text("Nothing has been changed yet. Cancel leaves both servers as they are.")
            }
            if failed {
                Section { Button("Try Again") { model.scan() } }
            }
        }
    }

    // MARK: R

    @ViewBuilder
    private func refused(_ refusal: MoveToHermesModel.Refusal) -> some View {
        switch refusal {
        case .noSignIn:
            MoveToHermesNoticeScreen(
                tint: .orange, title: String(localized: "This Hermes host has no sign-in"),
                message: String(localized: "Hermex needs a password to reach Hermes from your phone. On the host, turn on basic auth with a persistent secret, then try again. \(source) keeps working as it is.")) {
                Button(copiedPrompt ? String(localized: "Copied") : String(localized: "How to Turn On Sign-In")) {
                    UIPasteboard.general.string = BotConnectionSetup.prompt
                    copiedPrompt = true
                }
                .buttonStyle(.bordered)
                Button("Try Again") { model.scan() }.buttonStyle(.borderedProminent)
            }
        case .outdated(let version):
            MoveToHermesNoticeScreen(
                tint: .orange, title: String(localized: "Update Hermes first"),
                message: String(localized: "\(destination) runs \(version). Moving needs \(HermesCompatibility.minimumVersion) or later. \(source) keeps working as it is.")) {
                Button("OK") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case .sourceUnreadable:
            MoveToHermesNoticeScreen(
                tint: .orange, title: String(localized: "Couldn’t read \(source)’s chats"),
                message: String(localized: "\(source) didn’t answer. Check that it’s running and that you’re signed in.")) {
                Button("Try Again") { model.retryCheckedPass() }.buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
        case .running(let count):
            MoveToHermesNoticeScreen(
                tint: .orange, title: String(localized: "Wait for running chats"),
                message: String(localized: "\(count) chats on \(source) are still running. Move once they finish, so no reply is lost.")) {
                Button("OK") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: A2 and M

    @ViewBuilder
    private var review: some View {
        if let review = model.review {
            let counts = model.counts
            List {
                Section {
                    Text(review.version.map { String(localized: "Signed in to \(destination) as \(review.connection.username). Hermes \($0).") }
                         ?? String(localized: "Signed in to \(destination) as \(review.connection.username)."))
                        .foregroundStyle(.secondary)
                    if let only = review.scan.onlyProfile {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Only “\(only)” was checked.").fontWeight(.semibold)
                            Text("\(source) shows one Profile at a time, so chats in its other Profiles aren’t counted or copied by this move.")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    Text("\(counts.present) already in Hermes")
                    Text("\(counts.toCopy) to copy")
                    if counts.overLimit > 0 { Text("\(counts.overLimit) over 10,000 messages") }
                    if counts.unchecked > 0 { Text("\(counts.unchecked) couldn’t be checked") }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A chat over 5 MB is found only while copying and is listed when the move ends.")
                        if counts.unchecked > 0 {
                            Text("\(destination) didn’t answer for them, or two of its Profiles have them. This move won’t copy them; Copy Missing Chats Again checks them later.")
                        }
                    }
                }
                Section {
                    ForEach(review.profiles) { choice in
                        if review.isRepeat {
                            profileRow(choice)
                        } else {
                            NavigationLink {
                                MoveToHermesProfilePicker(model: model, choice: choice)
                            } label: {
                                profileRow(choice)
                            }
                        }
                    }
                } header: {
                    Text("Profiles")
                } footer: {
                    if let unchosen = model.unchosenProfile { Text("Choose where “\(unchosen)” goes to continue.") }
                }
                Section("Also brought over") {
                    LabeledContent("Titles, pins, archives", value: String(localized: "Filled after you move"))
                    LabeledContent("Drafts", value: "\(counts.drafts)")
                    LabeledContent("Notifications", value: String(localized: "Checked after you move"))
                }
                Section("Stays behind") {
                    Text("Project tags (Hermes groups by folder). Cleared history: Hermes shows the full transcript. Offline copies: Hermes caches its own.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button(review.isRepeat ? String(localized: "Copy Missing Chats Again") : String(localized: "Move")) { model.move() }
                        .fontWeight(.semibold)
                        .disabled(model.unchosenProfile != nil)
                }
            }
        }
    }

    private func profileRow(_ choice: MoveToHermesModel.ProfileChoice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.source)
                Text(choice.sameName ? String(localized: "\(choice.chats) chats · same name")
                                     : String(localized: "\(choice.chats) chats · no Profile with this name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch model.mapping[choice.source] {
            case .hermes(let profile)?: Text(profile).foregroundStyle(.secondary)
            case .keepOnWebui?: Text("Keep on \(source)").foregroundStyle(.secondary)
            case nil: Text("Choose…").foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: A3

    private func progress(_ step: MoveToHermesRunner.Step?) -> some View {
        let order: [MoveToHermesRunner.Step] = [.pairing, .copying, .reconciling, .movingDrafts, .finishing]
        let index = step.flatMap { order.firstIndex(of: $0) } ?? -1
        func state(_ position: Int) -> MoveToHermesStep.State {
            position < index ? .done : (position == index ? .current(position + 2) : .waiting)
        }
        let copied = model.runner?.copyProgress
        return List {
            Section {
                MoveToHermesStep(state: index >= 0 || model.destinationAdded ? .done : .current(1),
                                 title: String(localized: "\(destination) added"),
                                 detail: index >= 0 || model.destinationAdded ? String(localized: "Signed in") : nil)
                MoveToHermesStep(state: state(0), title: String(localized: "Notifications checked"))
                MoveToHermesStep(state: state(1), title: String(localized: "Copying chats"),
                                 detail: copied.map { String(localized: "\($0.settled) of \($0.total)") })
                MoveToHermesStep(state: state(2), title: String(localized: "Applying titles, pins and folders"))
                MoveToHermesStep(state: state(3), title: String(localized: "Moving drafts"))
            } footer: {
                Text("You can close this or quit the app. The move resumes where it stopped. Any change it can’t confirm is listed for you to check, not applied again.")
            }
            Section { Button("Close") { dismiss() } }
        }
    }

    // MARK: Paused (finish-early A1, 3A, 4C)

    @ViewBuilder
    private func paused(_ pause: MoveToHermesRunner.Pause) -> some View {
        switch pause {
        case .workLeft, .cancelled, .destinationUnavailable, .saveFailed:
            pausedDetails(pause)
        case .unreadable:
            MoveToHermesNoticeScreen(
                tint: .blue, title: String(localized: "Can’t read this move right now"),
                message: String(localized: "This iPhone can’t read the move’s progress right now, which can happen before it’s unlocked for the first time. Nothing more is sent until it can be read.")) {
                Button("Try Again") { model.resume() }.buttonStyle(.borderedProminent)
            }
        case .damaged, .needsRescan:
            MoveToHermesNoticeScreen(
                tint: .orange, title: String(localized: "This move’s progress was lost"),
                message: String(localized: "The record of what was sent can’t be trusted, so nothing more will be sent from it. Copy Missing Chats Again checks \(source) again and copies what \(destination) still lacks. It can’t finish titles, pins, folders or drafts for chats already in \(destination).")) {
                Button("Copy Missing Chats Again…") { model.copyMissingChatsAgain() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.source == nil)
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
        case .destinationRemoved:
            MoveToHermesNoticeScreen(
                tint: .red, title: String(localized: "\(destination) was removed"),
                message: String(localized: "The move stopped when \(destination) was removed from this iPhone. Chats it copied stay in \(destination). \(source) works as before and can be moved again.")) {
                Button("OK") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func pausedDetails(_ pause: MoveToHermesRunner.Pause) -> some View {
        let snapshot = model.snapshot
        let report = snapshot?.report
        let signedOut = pause == .destinationUnavailable && !model.destinationIsSignedIn
        return List {
            Section {
                switch pause {
                case .destinationUnavailable where signedOut:
                    MoveToHermesStep(state: .failed, title: String(localized: "\(destination) is signed out. Nothing more was sent."))
                case .destinationUnavailable:
                    MoveToHermesStep(state: .failed, title: String(localized: "Can’t reach \(destination). Nothing more was sent."))
                case .saveFailed:
                    MoveToHermesStep(state: .failed, title: String(localized: "This iPhone couldn’t save the move’s progress, so nothing more was sent."))
                default:
                    EmptyView()
                }
                pairingStep(report?.pairing)
                if let snapshot, let report {
                    MoveToHermesStep(
                        state: snapshot.copyLeft > 0 ? .attention : .done, title: String(localized: "Copying chats"),
                        detail: snapshot.copyLeft > 0
                            ? String(localized: "\(snapshot.inHermes) of \(snapshot.total) in \(destination). \(snapshot.copyLeft) still to try.")
                            : String(localized: "\(snapshot.inHermes) of \(snapshot.total) in \(destination)."))
                    MoveToHermesStep(
                        state: snapshot.changesLeft + snapshot.unplanned > 0 ? .attention : .done,
                        title: String(localized: "Titles, pins and folders"),
                        detail: [snapshot.changesLeft > 0
                                    ? String(localized: "\(report.changesApplied) applied. \(snapshot.changesLeft) still to send.")
                                    : String(localized: "\(report.changesApplied) applied."),
                                 snapshot.unplanned > 0 ? String(localized: "\(snapshot.unplanned) chats still to check.") : nil]
                            .compactMap { $0 }.joined(separator: " "))
                    MoveToHermesStep(
                        state: snapshot.draftsLeft > 0 ? .attention : .done, title: String(localized: "Moving drafts"),
                        detail: snapshot.draftsLeft > 0
                            ? String(localized: "\(report.draftsMoved) moved. \(snapshot.draftsLeft) still to move.")
                            : String(localized: "\(report.draftsMoved) moved."))
                }
            } footer: {
                Text(pausedLine(pause, signedOut: signedOut))
            }
            Section {
                if signedOut, let destinationID = model.destinationID, let url = URL(string: destinationID) {
                    NavigationLink("Sign In…") {
                        BotConnectionView(server: url) { auth.hermesSignInSaved(server: url, offersMove: false) }
                    }
                }
                if model.source != nil {
                    Button("Resume") { model.resume() }.fontWeight(.semibold)
                }
                Button("Finish with What’s Done…") { isConfirmingFinish = true }
                    .disabled(snapshot == nil)
            }
        }
    }

    @ViewBuilder
    private func pairingStep(_ pairing: MoveToHermesPairing?) -> some View {
        switch pairing {
        case .copied?:
            MoveToHermesStep(state: .done, title: String(localized: "Notifications checked"), detail: String(localized: "Same host: kept on"))
        case .differentInstall?:
            MoveToHermesStep(state: .done, title: String(localized: "Notifications checked"), detail: String(localized: "Different host: not copied"))
        case .sourceUnpaired?, .destinationAlreadyPaired?:
            MoveToHermesStep(state: .done, title: String(localized: "Notifications checked"))
        case .unchecked?, nil:
            MoveToHermesStep(state: .waiting, title: String(localized: "Notifications not checked yet"))
        }
    }

    /// 3A: neutral, unless the app knows the user closed the move or the webui server is gone.
    private func pausedLine(_ pause: MoveToHermesRunner.Pause, signedOut: Bool) -> String {
        switch pause {
        case .destinationUnavailable where signedOut: return String(localized: "Sign in to \(destination) again, then Resume.")
        case .destinationUnavailable: return String(localized: "Check that \(destination) is running and reachable, then Resume.")
        case .saveFailed: return String(localized: "Free up some storage, then Resume.")
        default: break
        }
        if model.source == nil {
            return String(localized: "\(source) was removed from this iPhone, so its remaining chats can’t be copied. Finish keeps what’s done in \(destination).")
        }
        if model.wasClosed {
            return String(localized: "The move was closed before it finished. Resume picks up where it stopped. Changes it can’t confirm are listed, not sent again.")
        }
        return String(localized: "Some work didn’t finish. Resume tries it again. Changes it can’t confirm are listed, not sent again.")
    }

    /// Finish-early A2's confirmation, with the counts as they stand.
    private var finishMessage: String {
        guard let report = model.snapshot?.report else { return "" }
        var sentences = [String(localized: "The move stops retrying.")]
        let notCopied = report.notCopied.count + report.rejected.count
        if notCopied > 0 { sentences.append(String(localized: "\(notCopied) chats it couldn’t copy stay on \(source).")) }
        if !report.unchecked.isEmpty { sentences.append(String(localized: "\(report.unchecked.count) more weren’t checked, so this move didn’t copy them.")) }
        if !report.draftsKept.isEmpty { sentences.append(String(localized: "\(report.draftsKept.count) drafts stay on this iPhone under \(source).")) }
        if !report.changesNotApplied.isEmpty {
            sentences.append(String(localized: "\(report.changesNotApplied.count) titles, pins or folders won’t be applied."))
        }
        if !report.notReconciled.isEmpty {
            sentences.append(String(localized: "\(report.notReconciled.count) chats weren’t checked for titles, pins, folders or drafts."))
        }
        if !report.sentUnconfirmed.isEmpty {
            sentences.append(String(localized: "\(report.sentUnconfirmed.count) chats were sent without a reply, so they may or may not be in \(destination). They’re listed for you to check."))
        }
        sentences.append(String(localized: "Nothing in \(destination) is undone. Copy Missing Chats Again can later copy chats \(destination) still lacks, with their titles, pins and drafts. It can’t finish the titles, pins, folders or drafts left undone for chats already in \(destination)."))
        return sentences.joined(separator: " ")
    }

    // MARK: Couldn't start

    private func couldNotStart(_ failure: MoveToHermesRunner.StartFailure) -> some View {
        let reason: String = switch failure {
        case .moveInProgress: String(localized: "A move from \(source) is already in progress. Resume or finish it first.")
        case .commit(.destinationSignedOut): String(localized: "\(destination) is signed out. Sign in, then try again.")
        case .commit(.destinationNotHermes), .commit(.sameAddress): String(localized: "A hermes-webui server is saved at this Hermes address.")
        case .commit(.sourceAlreadyMoved(let holder)):
            String(localized: "\(source) already moved to \(auth.servers.first { $0.id == holder }.map(MoveToHermesModel.name) ?? holder).")
        case .journal, .commit(.saveFailed): String(localized: "This iPhone couldn’t save the move.")
        case .commit: String(localized: "This move can’t start right now.")
        }
        return MoveToHermesNoticeScreen(tint: .red, title: String(localized: "Couldn’t start the move"),
                                        message: reason + " " + String(localized: "Nothing was changed.")) {
            Button("OK") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - M2

/// Where one webui Profile's chats go: a Hermes Profile, or kept on the webui server.
private struct MoveToHermesProfilePicker: View {
    @Bindable var model: MoveToHermesModel
    let choice: MoveToHermesModel.ProfileChoice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(model.review?.hermesProfiles ?? [], id: \.self) { profile in
                    Button { pick(.hermes(profile: profile)) } label: {
                        HStack {
                            Text(profile).foregroundStyle(.primary)
                            Spacer()
                            if model.mapping[choice.source] == .hermes(profile: profile) {
                                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
                            }
                        }
                    }
                }
            } header: {
                Text("Copy “\(choice.source)” chats to")
            }
            Section {
                Button { pick(.keepOnWebui) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep on \(model.sourceName)").foregroundStyle(.primary)
                            Text("Its \(choice.chats) chats stay there, and its Shortcuts keep opening \(model.sourceName) while it’s configured.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.mapping[choice.source] == .keepOnWebui {
                            Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
                        }
                    }
                }
            }
        }
        .navigationTitle(choice.source)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ destination: MovedWebuiProfile.Destination) {
        model.mapping[choice.source] = destination
        dismiss()
    }
}

// MARK: - A4

/// The move's report, kept until Done (A4, A4b, finish-early A3), with its actions stacked
/// below (5A): Done, "Move <next> Next" while another webui server hasn't moved, and Remove
/// while the webui server is still configured.
private struct MoveToHermesReportView: View {
    let report: MoveToHermesReport
    let source: String
    let destination: String
    let keptProfiles: [String]
    let canCopyAgain: Bool
    /// The next webui server's name, while one hasn't moved.
    let next: String?
    let copyAgain: () -> Void
    let done: () -> Void
    let moveNext: () -> Void
    /// Asks to remove the webui server; nil once it is gone.
    let remove: (() -> Void)?

    var body: some View {
        List {
            Section {
                MoveToHermesStep(state: .done, title: String(localized: "\(report.chatsInHermes) chats in \(destination)"),
                                 detail: report.presentUnconfirmed.isEmpty
                                    ? String(localized: "\(report.copied.count) copied, \(report.alreadyThere.count) already there")
                                    : String(localized: "\(report.copied.count) copied, \(report.alreadyThere.count) already there, \(report.presentUnconfirmed.count) there but the copy wasn’t confirmed"))
                if staying > 0 {
                    MoveToHermesStep(state: .attention, title: String(localized: "\(staying) chats stay on \(source)"), detail: stayingDetail)
                }
                if unchecked > 0 {
                    MoveToHermesStep(state: .attention, title: String(localized: "\(unchecked) chats unchecked"), detail: uncheckedDetail)
                }
                if report.changesApplied > 0 {
                    MoveToHermesStep(state: .done, title: String(localized: "\(report.changesApplied) titles, pins and archives applied"))
                }
                if notApplied > 0 {
                    MoveToHermesStep(state: .attention, title: String(localized: "\(notApplied) titles, pins or folders not applied"))
                }
                if !report.notReconciled.isEmpty {
                    MoveToHermesStep(state: .attention,
                                     title: String(localized: "\(report.notReconciled.count) chats weren’t checked for titles, pins, folders or drafts."))
                }
                if !report.changesUnconfirmed.isEmpty {
                    MoveToHermesStep(state: .attention, title: String(localized: "\(report.changesUnconfirmed.count) changes couldn’t be confirmed"),
                                     detail: String(localized: "\(changeList(report.changesUnconfirmed)). Check them in \(destination)."))
                }
                if !report.foldersMissing.isEmpty {
                    MoveToHermesStep(state: .attention, title: String(localized: "\(report.foldersMissing.count) chats open without a folder"),
                                     detail: String(localized: "This host doesn’t have a matching folder."))
                }
                if drafts > 0 {
                    MoveToHermesStep(state: .attention, title: String(localized: "\(drafts) drafts stay on this iPhone under \(source)"),
                                     detail: draftsDetail)
                }
                if report.pairing == .differentInstall {
                    MoveToHermesStep(state: .attention, title: String(localized: "Notifications not copied"),
                                     detail: String(localized: "\(destination) is a different host from \(source). Its own notifications are unchanged; set them up in its Settings if they’re off. \(source) keeps its own until you remove it."))
                }
            }
            if canCopyAgain, report.notCopied.count + report.rejected.count + report.unchecked.count + report.sentUnconfirmed.count > 0 {
                Section {
                    Button("Copy Missing Chats Again", action: copyAgain)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actions }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: done) { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            if let next {
                Button(action: moveNext) { Text("Move \(next) Next").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .tint(.primary)
            }
            if let remove {
                Button(role: .destructive, action: remove) { Text("Remove \(source)…").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Text("\(source)’s chats stay on its host. Only Hermex’s copy of the server is removed.")
                    .font(.footnote)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .controlSize(.large)
        .fontWeight(.semibold)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var staying: Int { report.notCopied.count + report.rejected.count + report.oversized.count + report.keptOnWebui.count }
    private var unchecked: Int { report.unchecked.count + report.sentUnconfirmed.count }
    private var notApplied: Int { report.changesNotApplied.count + report.changesRejected.count }
    private var drafts: Int { report.draftsKept.count + report.draftConflicts.count }

    private var stayingDetail: String {
        var parts: [String] = []
        let notCopied = report.notCopied.count + report.rejected.count
        if notCopied > 0 { parts.append(String(localized: "\(notCopied) couldn’t be copied")) }
        if !report.oversized.isEmpty { parts.append(String(localized: "\(report.oversized.count) over the import limit")) }
        if !report.keptOnWebui.isEmpty {
            let names = ListFormatter.localizedString(byJoining: keptProfiles.map { "“\($0)”" })
            parts.append(keptProfiles.isEmpty ? String(localized: "\(report.keptOnWebui.count) kept there")
                                              : String(localized: "\(report.keptOnWebui.count) in \(names)"))
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    private var uncheckedDetail: String {
        var sentences: [String] = []
        if !report.unchecked.isEmpty {
            sentences.append(String(localized: "\(report.unchecked.count) couldn’t be checked and weren’t copied."))
        }
        if !report.sentUnconfirmed.isEmpty {
            sentences.append(String(localized: "\(report.sentUnconfirmed.count) were sent without a reply: check whether they’re in \(destination)."))
            sentences.append(titles(report.sentUnconfirmed))
        }
        return sentences.joined(separator: " ")
    }

    private var draftsDetail: String {
        var parts: [String] = []
        if !report.draftsKept.isEmpty { parts.append(String(localized: "\(report.draftsKept.count) not moved")) }
        if !report.draftConflicts.isEmpty { parts.append(String(localized: "\(report.draftConflicts.count) in conflict (both kept)")) }
        return ListFormatter.localizedString(byJoining: parts)
    }

    /// Up to three chats by title, so the user knows which to check.
    private func titles(_ ids: [String]) -> String {
        Self.shortList(ids) { "“\(report.titles[$0] ?? $0)”" }
    }

    /// Three items joined naturally, or the first three and how many more. Formats only those shown.
    private static func shortList<Item>(_ items: [Item], _ format: (Item) -> String) -> String {
        let shown = items.prefix(3).map(format)
        guard items.count > 3 else { return ListFormatter.localizedString(byJoining: shown) }
        return String(localized: "\(shown.joined(separator: ", ")) and \(items.count - 3) more")
    }

    private func changeList(_ operations: [MoveToHermesReconcile.Operation]) -> String {
        Self.shortList(operations) { operation in
            let title = report.titles[operation.id] ?? operation.id
            return switch operation.change {
            case .title: String(localized: "Title on “\(title)”")
            case .pinned: String(localized: "Pin on “\(title)”")
            case .folder: String(localized: "Folder on “\(title)”")
            }
        }
    }
}

// MARK: - Shared pieces

/// One step: done, current (numbered), waiting, needing attention or failed. Static glyphs only.
struct MoveToHermesStep: View {
    enum State: Equatable {
        case done, waiting, attention, failed
        case current(Int)
    }

    let state: State
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            glyph
                .font(.body)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .current(let number): Image(systemName: "\(number).circle").foregroundStyle(.tint)
        }
    }

    private var accessibilityState: String {
        switch state {
        case .done: String(localized: "Done")
        case .waiting: String(localized: "Not started")
        case .attention: String(localized: "Needs attention")
        case .failed: String(localized: "Failed")
        case .current: String(localized: "In progress")
        }
    }
}

/// A title with a secondary line, as the host list and Profile rows show.
private struct MoveToHermesRow: View {
    let title: String
    let detail: String
    var chevron = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if chevron {
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A whole-screen stop or refusal (R, 4C): what happened, what didn't, and the way out.
private struct MoveToHermesNoticeScreen<Actions: View>: View {
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary)
                VStack(spacing: 10) { actions }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Banners

/// The session list's Move to Hermes banner for `serverID` (S1, 2A, A5), shown on the webui
/// server and, while a move is paused or its report waits, on the destination too. It opens
/// the guided sheet; A5's More menu offers Copy Missing Chats Again and removal (S2). Before
/// any move, a webui server asked the one-time question shows the invite instead (#1267, 2A)
/// until ✕.
struct MoveToHermesBanner: View {
    let serverID: String
    @Environment(AuthManager.self) private var auth
    @Environment(\.modelContext) private var modelContext
    @State private var request: Request?
    @State private var isConfirmingRemove = false
    private let notices = MoveToHermesNotices.shared

    /// The banner a sheet opened from: the row stays while its sheet is up, though a running
    /// move has no banner of its own, so the sheet isn't torn down with it. The invite's has no
    /// notice yet.
    private struct Request: Identifiable {
        let sourceID: String
        let notice: MoveToHermesNotice?
        let entry: MoveToHermesEntry
        var id: String { "\(sourceID)\(entry)" }
    }

    var body: some View {
        let notice = notices.banner(for: serverID, in: auth.servers) ?? request?.notice
        if notice != nil || request != nil || auth.showsMoveInvite(for: serverID) {
            // One row for every card, so a sheet survives the invite turning into a notice.
            VStack(spacing: 0) {
                if let notice { banner(notice) } else { invite }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .sessionsScreenListRow()
            .sheet(item: $request) { MoveToHermesSheet(auth: auth, sourceID: $0.sourceID, entry: $0.entry) }
            .alert(notice.map { String(localized: "Remove \(sourceName($0.sourceID))?") } ?? "", isPresented: $isConfirmingRemove) {
                Button("Cancel", role: .cancel) {}
                if let notice { Button("Remove Server", role: .destructive) { remove(notice) } }
            } message: {
                if let source = auth.servers.first(where: { $0.id == notice?.sourceID }) {
                    Text(MoveToHermesRemoval.message(for: source, servers: auth.servers) ?? "")
                }
            }
        }
    }

    private func sourceName(_ sourceID: String) -> String {
        auth.servers.first { $0.id == sourceID }.map(MoveToHermesModel.name) ?? URL(string: sourceID)?.host ?? sourceID
    }

    /// "Move <server> to Hermes" (2A): Move starts the guided move as Settings does; ✕ hides it
    /// for this server for good.
    private var invite: some View {
        let source = sourceName(serverID)
        return HStack(spacing: 12) {
            Image(systemName: "arrow.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move \(source) to Hermes").fontWeight(.semibold)
                Text("Bring your chats to Hermes.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button("Move") { request = Request(sourceID: serverID, notice: nil, entry: .start) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fontWeight(.semibold)
                .accessibilityLabel(Text("Move \(source) to Hermes"))
            Button { auth.noteMovePrompt(.dismissed, forSource: serverID) } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Dismiss"))
        }
        .font(.subheadline)
        .moveToHermesCard(Color(.secondarySystemBackground))
    }

    private func banner(_ notice: MoveToHermesNotice) -> some View {
        let destination = MoveToHermesModel.name(notice.destination)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                switch notice.stage {
                case .paused:
                    Text("Move paused.").fontWeight(.semibold)
                    if let inHermes = notice.inHermes, let total = notice.total {
                        Text("\(inHermes) of \(total) chats are in \(destination). Some work isn’t finished.")
                    } else {
                        Text("Some work isn’t finished.")
                    }
                case .finished:
                    Text("Move finished.").fontWeight(.semibold)
                    Text("See what moved to \(destination) and what stayed on \(sourceName(notice.sourceID)).")
                case .moved, .running:
                    Text("Moved to \(destination).").fontWeight(.semibold)
                    Text("Continue your chats there. Sending here too can split a conversation.")
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 18) {
                switch notice.stage {
                case .paused(let canResume):
                    if canResume { Button("Resume") { request = Request(sourceID: notice.sourceID, notice: notice, entry: .resume) } }
                    Button("Details") { request = Request(sourceID: notice.sourceID, notice: notice, entry: .details) }
                case .finished:
                    Button("See Report") { request = Request(sourceID: notice.sourceID, notice: notice, entry: .details) }
                case .moved, .running:
                    Button(String(localized: "Open \(destination)")) { auth.switchActiveServer(to: notice.destination) }
                    Menu("More…") {
                        Button("Copy Missing Chats Again") { request = Request(sourceID: notice.sourceID, notice: notice, entry: .copyMissingAgain) }
                        Button("Remove This Server", role: .destructive) { isConfirmingRemove = true }
                    }
                }
            }
            .fontWeight(.semibold)
            .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .moveToHermesCard(Color.orange.opacity(0.12))
    }

    private func remove(_ notice: MoveToHermesNotice) {
        guard let source = auth.servers.first(where: { $0.id == notice.sourceID }) else { return }
        Task { await MoveToHermesRemoval.remove(source, auth: auth, modelContext: modelContext) }
    }
}

private extension View {
    /// The Move banners' shared card.
    func moveToHermesCard(_ background: Color) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// Applied once at the root (`ContentView`): hands `auth` to the Move banners, keeps
    /// `MoveToHermesNotices` current when the registry changes and on foreground, and shows
    /// the offer after a Hermes sign-in (`AuthManager.moveOffer`) and the one-time question
    /// (`AuthManager.moveQuestion`), above any server's screens.
    func moveToHermesNotices(_ auth: AuthManager) -> some View {
        modifier(MoveToHermesNoticesRefresh(auth: auth))
    }
}

private struct MoveToHermesNoticesRefresh: ViewModifier {
    @Bindable var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(auth)
            .task(id: auth.servers) { await MoveToHermesNotices.shared.refresh(auth) }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                Task { await MoveToHermesNotices.shared.refresh(auth) }
            }
            .sheet(item: $auth.moveOffer) { MoveToHermesOfferSheet(auth: auth, offer: $0) }
            .sheet(item: $auth.moveQuestion) { MoveToHermesQuestionSheet(auth: auth, question: $0) }
            .task(id: QuestionTrigger(state: auth.state, servers: auth.servers, offer: auth.moveOffer?.id, phase: scenePhase,
                                      showsList: MoveToHermesNotices.shared.showsChatList(of: auth.activeServer?.id))) {
                guard scenePhase == .active else { return }
                await MoveToHermesQuestionTiming.ask(auth, notices: .shared)
            }
    }

    /// What can make the one-time question due: a launch, a sign-in or switch, a server added,
    /// the offer closing, a return to the foreground, or the active server's chat list coming
    /// back on screen.
    private struct QuestionTrigger: Equatable {
        let state: AuthManager.State
        let servers: [ServerAccount]
        let offer: String?
        let phase: ScenePhase
        let showsList: Bool
    }
}

/// When the root asks the one-time question (#1267): once it is due, the active server's chat
/// list is on screen (`MoveToHermesNotices.showsChatList`), and no window presents a sheet or
/// alert. A covering presentation is waited out, not skipped: its dismissal checks again. A
/// hidden list ends the wait; the root asks again when it returns.
@MainActor
enum MoveToHermesQuestionTiming {
    /// Asks `auth`'s question once it is due over its chat list and nothing covers the app. Waits
    /// `settle` first and after each covering presentation closes, so a launch's own sheets and
    /// links, or a sheet closing, finish before it. Returns once asked, no longer due, off its
    /// list, or cancelled (another trigger, the app leaving the foreground).
    static func ask(_ auth: AuthManager, notices: MoveToHermesNotices, settle: Duration = .seconds(1),
                    windows: @MainActor () -> [UIWindow] = { appWindows }) async {
        func isDue() -> Bool { auth.isMoveQuestionDue && notices.showsChatList(of: auth.activeServer?.id) }
        while isDue() {
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, isDue() else { return }
            guard let cover = windows().lazy.compactMap({ $0.rootViewController?.presentedViewController }).first else {
                return auth.askAboutMoveIfDue()
            }
            await dismissal(of: cover)
        }
    }

    private static var appWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    /// Returns when `controller`'s view leaves its window (it was dismissed) or the task is
    /// cancelled. UIKit has no public dismissal callback a non-owner can observe, so a hidden
    /// probe view in the presentation reports it.
    private static func dismissal(of controller: UIViewController) async {
        let probe = DismissalProbe()
        controller.view.addSubview(probe)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.onDismissal = { continuation.resume() }
                if Task.isCancelled || probe.window == nil { probe.dismissed() }
            }
        } onCancel: {
            Task { @MainActor in probe.dismissed() }
        }
        probe.removeFromSuperview()
    }

    private final class DismissalProbe: UIView {
        /// Called once, the first time the probe leaves a window.
        var onDismissal: (() -> Void)?

        init() {
            super.init(frame: .zero)
            isHidden = true
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            if window == nil { dismissed() }
        }

        func dismissed() {
            let onDismissal = onDismissal
            self.onDismissal = nil
            onDismissal?()
        }
    }
}

/// "Move <server> to Hermes" (#1267, 1A): asked once for each webui server that hasn't moved.
/// Move to Hermes turns this sheet into the guided move as Settings starts it: straight to the
/// scan with a Bots connection, otherwise the host choice and its Hermes sign-in. Not Now and
/// closing leave the chat list's banner.
private struct MoveToHermesQuestionSheet: View {
    let auth: AuthManager
    let question: MoveToHermesQuestion
    @Environment(\.dismiss) private var dismiss
    @State private var isMoving = false

    var body: some View {
        Group {
            if isMoving {
                MoveToHermesSheet(auth: auth, sourceID: question.sourceID, entry: .start)
            } else {
                ask
            }
        }
        .presentationDetents(isMoving ? [.large] : [.medium, .large])
    }

    private var ask: some View {
        let source = auth.servers.first { $0.id == question.sourceID }.map(MoveToHermesModel.name)
            ?? URL(string: question.sourceID)?.host ?? question.sourceID
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Text("Move \(source) to Hermes")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Hermex now talks to Hermes directly. Your chats, titles, pins and drafts come with you.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    point(String(localized: "Nothing is deleted. \(source) keeps working until you remove it."))
                    point(question.hasBotsSignIn
                        ? String(localized: "Uses the Hermes sign-in you set up for Bots.")
                        : String(localized: "You’ll sign in to your Hermes host first."))
                }
                VStack(spacing: 4) {
                    Button { isMoving = true } label: {
                        Text("Move to Hermes").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { dismiss() } label: {
                        Text("Not Now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                }
                .controlSize(.large)
                .fontWeight(.semibold)
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func point(_ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.green)
        }
    }
}

/// "Signed in to <host>" (#1266, 3A): offers to bring a webui server's chats to the Hermes
/// server just signed in to. Bring My Chats turns this sheet into the guided move, scanning that
/// server; Not Now and closing leave everything as it is.
private struct MoveToHermesOfferSheet: View {
    let auth: AuthManager
    let offer: MoveToHermesOffer
    @Environment(\.dismiss) private var dismiss
    @State private var isBringing = false

    var body: some View {
        Group {
            if isBringing {
                MoveToHermesSheet(auth: auth, sourceID: offer.sourceID, entry: .offer(destinationID: offer.destinationID))
            } else {
                question
            }
        }
        .presentationDetents(isBringing ? [.large] : [.medium, .large])
    }

    private func name(_ id: String) -> String {
        auth.servers.first { $0.id == id }.map(MoveToHermesModel.name) ?? URL(string: id)?.host ?? id
    }

    private var question: some View {
        let source = name(offer.sourceID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Signed in to \(URL(string: offer.destinationID)?.host ?? offer.destinationID)")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Bring your chats from \(source)? Hermex checks which ones Hermes already has, then shows you what it will copy before it starts.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button { isBringing = true } label: {
                        Text("Bring My Chats").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { dismiss() } label: {
                        Text("Not Now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 8)
                Text("You can do this later in Settings › \(source).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
