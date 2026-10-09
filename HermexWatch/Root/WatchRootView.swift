import SwiftUI
import HermexWatchRoot
import WatchShared

enum WatchScreenshotPage: String {
    case now
    /// Now with a reply-control failure already on the model, to check that a
    /// failed send no longer paints a banner over the composer.
    case nowReplyError
    case sessions
    case detail
    case tasks
    case kanban
    case usage
    case memory
    case skills
    case profile
    case projects
    /// Detail screens, opened on the fixture's first item.
    case taskDetail
    case taskRunOutput
    case kanbanCard
    case memorySection
    case skillDetail
}

enum WatchChrome: Hashable {
    case sessions
    case tasks
    case kanban
    case usage
    case memory
    case skills
    case profile
    case projects
    #if DEBUG
    case fixtureDetail(WatchScreenshotPage)
    #endif
}

struct WatchRootView: View {
    @Bindable var model: WatchRootModel
    var screenshotPage: WatchScreenshotPage = .now
    @State private var path = NavigationPath()

    var body: some View {
        switch model.state {
        case .setupRequired, .connecting, .unavailable, .signedOut:
            connectionState
        case .ready:
            NavigationStack(path: $path) {
                WatchNowView(model: model)
                    .navigationDestination(for: WatchChrome.self) { chrome in
                        switch chrome {
                        case .sessions: WatchSessionListView(model: model)
                        case .tasks: WatchTaskListView(model: model)
                        case .kanban: WatchKanbanListView(model: model)
                        case .usage: WatchUsageListView(model: model)
                        case .memory: WatchMemoryListView(model: model)
                        case .skills: WatchSkillListView(model: model)
                        case .profile: WatchProfileListView(model: model)
                        case .projects: WatchProjectListView(model: model)
                        #if DEBUG
                        case .fixtureDetail(let page): WatchFixtureDetailHost(model: model, page: page)
                        #endif
                        }
                    }
                    .navigationDestination(for: SessionKey.self) { key in
                        if let session = model.sessions.first(where: { $0.key == key }) {
                            WatchSessionDetailView(model: model, session: session)
                        } else {
                            ProgressView()
                        }
                    }
            }
            .onAppear {
                applyScreenshotPath()
            }
            .onChange(of: model.complicationRecordID) { _, id in
                if id != nil { path = NavigationPath() }
            }
            .onChange(of: model.sessions) { _, _ in
                WatchWidgetSnapshotPublisher.publish(model)
            }
        }
    }

    private func applyScreenshotPath() {
        switch screenshotPage {
        case .now, .nowReplyError:
            break
        case .sessions:
            path.append(WatchChrome.sessions)
        case .tasks:
            path.append(WatchChrome.tasks)
        case .kanban:
            path.append(WatchChrome.kanban)
        case .usage:
            path.append(WatchChrome.usage)
        case .memory:
            path.append(WatchChrome.memory)
        case .skills:
            path.append(WatchChrome.skills)
        case .profile:
            path.append(WatchChrome.profile)
        case .projects:
            path.append(WatchChrome.projects)
        case .taskDetail, .taskRunOutput, .kanbanCard, .memorySection, .skillDetail:
            #if DEBUG
            path.append(WatchChrome.fixtureDetail(screenshotPage))
            #endif
        case .detail:
            if let key = model.nowSession?.key {
                path.append(key)
            }
        }
    }

    private var connectionState: some View {
        VStack(spacing: 8) {
            Text("Hermex")
                .font(.headline)

            switch model.state {
            case .setupRequired:
                Text(model.primaryMessage)
                    .font(.body.weight(.semibold))
                Text("Pairing and server provisioning are not configured yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .connecting:
                ProgressView()
                Text("Connecting")
                    .font(.footnote)
            case .unavailable:
                Text("Hermex is unavailable")
                    .font(.body.weight(.semibold))
                Text(model.phoneStatusNote ?? "Open Hermex on your iPhone to review setup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .signedOut:
                Text("Sign in on iPhone")
                    .font(.body.weight(.semibold))
                Text("Open Hermex on your iPhone and sign in to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .ready:
                EmptyView()
            }
        }
        .padding()
    }
}

#if DEBUG
/// Screenshot-fixture only: loads the glance the page names and opens its
/// first item, since detail screens are pushed from rows, not from a path.
private struct WatchFixtureDetailHost: View {
    let model: WatchRootModel
    let page: WatchScreenshotPage
    @State private var content: AnyView?

    var body: some View {
        Group {
            if let content { content } else { ProgressView() }
        }
        .task { content = await load() }
    }

    private func load() async -> AnyView? {
        switch page {
        case .taskDetail:
            guard let task = await model.loadTasks().first else { return nil }
            return AnyView(WatchTaskDetailView(model: model, task: task) {})
        case .taskRunOutput:
            guard let task = await model.loadTasks().first,
                  let run = await model.loadTaskRuns(jobID: task.key.jobID)?.first else { return nil }
            return AnyView(WatchTaskRunOutputView(model: model, run: run))
        case .kanbanCard:
            guard let card = await model.loadKanbanCards().first else { return nil }
            return AnyView(WatchKanbanCardView(model: model, card: card) {})
        case .memorySection:
            guard let section = await model.loadMemory()?.sections.last else { return nil }
            return AnyView(WatchMemorySectionView(section: section))
        case .skillDetail:
            guard let skill = await model.loadSkills().first else { return nil }
            return AnyView(WatchSkillDetailView(model: model, skill: skill) {})
        default:
            return nil
        }
    }
}
#endif
