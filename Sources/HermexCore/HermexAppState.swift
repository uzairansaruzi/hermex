import Foundation

public enum HermexAuthState: Codable, Equatable, Sendable {
    case unconfigured
    case loggedOut(server: HermexServerIdentity)
    case loggedIn(server: HermexServerIdentity)
}

public struct HermexAppState: Codable, Equatable, Sendable {
    public var auth: HermexAuthState
    public var selectedSessionID: String?
    public var pendingSharedDraft: HermexSharedDraft?
    public var route: HermexRoute

    public init(
        auth: HermexAuthState = .unconfigured,
        selectedSessionID: String? = nil,
        pendingSharedDraft: HermexSharedDraft? = nil,
        route: HermexRoute = .onboarding
    ) {
        self.auth = auth
        self.selectedSessionID = selectedSessionID
        self.pendingSharedDraft = pendingSharedDraft
        self.route = route
    }
}

public struct HermexOnboardingState: Codable, Equatable, Sendable {
    public var serverURLString: String
    public var displayName: String
    public var password: String
    public var customHeaderText: String
    public var lastValidatedServer: HermexServerIdentity?
    public var isTestingConnection: Bool
    public var isSigningIn: Bool
    public var statusMessage: String?
    public var errorMessage: String?

    public init(
        serverURLString: String = "",
        displayName: String = "",
        password: String = "",
        customHeaderText: String = "",
        lastValidatedServer: HermexServerIdentity? = nil,
        isTestingConnection: Bool = false,
        isSigningIn: Bool = false,
        statusMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.serverURLString = serverURLString
        self.displayName = displayName
        self.password = password
        self.customHeaderText = customHeaderText
        self.lastValidatedServer = lastValidatedServer
        self.isTestingConnection = isTestingConnection
        self.isSigningIn = isSigningIn
        self.statusMessage = statusMessage
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case serverURLString
        case displayName
        case customHeaderText
        case lastValidatedServer
        case isTestingConnection
        case isSigningIn
        case statusMessage
        case errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverURLString = try container.decodeIfPresent(String.self, forKey: CodingKeys.serverURLString) ?? ""
        self.displayName = try container.decodeIfPresent(String.self, forKey: CodingKeys.displayName) ?? ""
        self.password = ""
        self.customHeaderText = try container.decodeIfPresent(String.self, forKey: CodingKeys.customHeaderText) ?? ""
        self.lastValidatedServer = try container.decodeIfPresent(HermexServerIdentity.self, forKey: CodingKeys.lastValidatedServer)
        self.isTestingConnection = try container.decodeIfPresent(Bool.self, forKey: CodingKeys.isTestingConnection) ?? false
        self.isSigningIn = try container.decodeIfPresent(Bool.self, forKey: CodingKeys.isSigningIn) ?? false
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: CodingKeys.statusMessage)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: CodingKeys.errorMessage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverURLString, forKey: CodingKeys.serverURLString)
        try container.encode(displayName, forKey: CodingKeys.displayName)
        try container.encode(customHeaderText, forKey: CodingKeys.customHeaderText)
        try container.encodeIfPresent(lastValidatedServer, forKey: CodingKeys.lastValidatedServer)
        try container.encode(isTestingConnection, forKey: CodingKeys.isTestingConnection)
        try container.encode(isSigningIn, forKey: CodingKeys.isSigningIn)
        try container.encodeIfPresent(statusMessage, forKey: CodingKeys.statusMessage)
        try container.encodeIfPresent(errorMessage, forKey: CodingKeys.errorMessage)
    }
}

public enum HermexRoute: String, Codable, Equatable, Sendable {
    case onboarding
    case sessions
    case chat
    case settings
    case workspace
    case git
    case panels
}

public struct HermexSessionListState: Codable, Equatable, Sendable {
    public var sessions: [HermexSessionDTO]
    public var projects: [HermexProjectDTO]
    public var searchQuery: String
    public var selectedProjectID: String?
    public var activeProfileName: String?
    public var isLoading: Bool
    public var isShowingArchived: Bool
    public var isViewingCachedData: Bool
    public var errorMessage: String?

    public init(
        sessions: [HermexSessionDTO] = [],
        projects: [HermexProjectDTO] = [],
        searchQuery: String = "",
        selectedProjectID: String? = nil,
        activeProfileName: String? = nil,
        isLoading: Bool = false,
        isShowingArchived: Bool = false,
        isViewingCachedData: Bool = false,
        errorMessage: String? = nil
    ) {
        self.sessions = sessions
        self.projects = projects
        self.searchQuery = searchQuery
        self.selectedProjectID = selectedProjectID
        self.activeProfileName = activeProfileName
        self.isLoading = isLoading
        self.isShowingArchived = isShowingArchived
        self.isViewingCachedData = isViewingCachedData
        self.errorMessage = errorMessage
    }
}

public struct HermexChatState: Codable, Equatable, Sendable {
    public var session: HermexSessionDTO?
    public var messages: [HermexChatMessageDTO]
    public var composer: HermexComposerState
    public var stream: HermexStreamState
    public var pendingApproval: HermexApprovalPrompt?
    public var pendingClarification: HermexClarificationPrompt?
    public var isLoading: Bool
    public var isViewingCachedData: Bool
    public var errorMessage: String?

    public init(
        session: HermexSessionDTO? = nil,
        messages: [HermexChatMessageDTO] = [],
        composer: HermexComposerState = HermexComposerState(),
        stream: HermexStreamState = HermexStreamState(),
        pendingApproval: HermexApprovalPrompt? = nil,
        pendingClarification: HermexClarificationPrompt? = nil,
        isLoading: Bool = false,
        isViewingCachedData: Bool = false,
        errorMessage: String? = nil
    ) {
        self.session = session
        self.messages = messages
        self.composer = composer
        self.stream = stream
        self.pendingApproval = pendingApproval
        self.pendingClarification = pendingClarification
        self.isLoading = isLoading
        self.isViewingCachedData = isViewingCachedData
        self.errorMessage = errorMessage
    }
}

public struct HermexComposerState: Codable, Equatable, Sendable {
    public var draft: String
    public var selectedModel: String?
    public var selectedModelProvider: String?
    public var selectedWorkspace: String?
    public var selectedProfile: String?
    public var selectedReasoningEffort: String?
    public var availableModels: [HermexModelOption]
    public var availableProfiles: [HermexProfileOption]
    public var availableWorkspaces: [HermexWorkspaceRootDTO]
    public var supportedReasoningEfforts: [String]
    public var attachments: [HermexAttachmentDTO]
    public var isUploadingAttachment: Bool
    public var isRecordingVoice: Bool
    public var isLoadingConfiguration: Bool
    public var configurationErrorMessage: String?
    public var showsReasoningControl: Bool

    public init(
        draft: String = "",
        selectedModel: String? = nil,
        selectedModelProvider: String? = nil,
        selectedWorkspace: String? = nil,
        selectedProfile: String? = nil,
        selectedReasoningEffort: String? = nil,
        availableModels: [HermexModelOption] = [],
        availableProfiles: [HermexProfileOption] = [],
        availableWorkspaces: [HermexWorkspaceRootDTO] = [],
        supportedReasoningEfforts: [String] = [],
        attachments: [HermexAttachmentDTO] = [],
        isUploadingAttachment: Bool = false,
        isRecordingVoice: Bool = false,
        isLoadingConfiguration: Bool = false,
        configurationErrorMessage: String? = nil,
        showsReasoningControl: Bool = true
    ) {
        self.draft = draft
        self.selectedModel = selectedModel
        self.selectedModelProvider = selectedModelProvider
        self.selectedWorkspace = selectedWorkspace
        self.selectedProfile = selectedProfile
        self.selectedReasoningEffort = selectedReasoningEffort
        self.availableModels = availableModels
        self.availableProfiles = availableProfiles
        self.availableWorkspaces = availableWorkspaces
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.attachments = attachments
        self.isUploadingAttachment = isUploadingAttachment
        self.isRecordingVoice = isRecordingVoice
        self.isLoadingConfiguration = isLoadingConfiguration
        self.configurationErrorMessage = configurationErrorMessage
        self.showsReasoningControl = showsReasoningControl
    }
}

public struct HermexStreamState: Codable, Equatable, Sendable {
    public var streamID: String?
    public var isStreaming: Bool
    public var isRecovering: Bool
    public var liveReasoning: String
    public var liveToolActivity: String?

    public init(
        streamID: String? = nil,
        isStreaming: Bool = false,
        isRecovering: Bool = false,
        liveReasoning: String = "",
        liveToolActivity: String? = nil
    ) {
        self.streamID = streamID
        self.isStreaming = isStreaming
        self.isRecovering = isRecovering
        self.liveReasoning = liveReasoning
        self.liveToolActivity = liveToolActivity
    }
}

public struct HermexApprovalPrompt: Codable, Equatable, Sendable {
    public var approvalID: String?
    public var title: String?
    public var command: String?
    public var details: String?

    public init(approvalID: String? = nil, title: String? = nil, command: String? = nil, details: String? = nil) {
        self.approvalID = approvalID
        self.title = title
        self.command = command
        self.details = details
    }
}

public struct HermexClarificationPrompt: Codable, Equatable, Sendable {
    public var promptID: String?
    public var question: String
    public var options: [String]
    public var draft: String

    public init(promptID: String? = nil, question: String, options: [String] = [], draft: String = "") {
        self.promptID = promptID
        self.question = question
        self.options = options
        self.draft = draft
    }
}

public struct HermexWorkspaceState: Codable, Equatable, Sendable {
    public var roots: [HermexWorkspaceRootDTO]
    public var currentPath: String?
    public var entries: [HermexWorkspaceEntryDTO]
    public var preview: HermexFilePreview?
    public var isLoading: Bool
    public var errorMessage: String?

    public init(
        roots: [HermexWorkspaceRootDTO] = [],
        currentPath: String? = nil,
        entries: [HermexWorkspaceEntryDTO] = [],
        preview: HermexFilePreview? = nil,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.roots = roots
        self.currentPath = currentPath
        self.entries = entries
        self.preview = preview
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

public struct HermexWorkspaceEntryDTO: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var type: String?
    public var isDirectory: Bool
    public var size: Int?

    public init(name: String, path: String, type: String? = nil, isDirectory: Bool, size: Int? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct HermexFilePreview: Codable, Equatable, Sendable {
    public var path: String
    public var content: String?
    public var mimeType: String?
    public var isBinary: Bool

    public init(path: String, content: String? = nil, mimeType: String? = nil, isBinary: Bool = false) {
        self.path = path
        self.content = content
        self.mimeType = mimeType
        self.isBinary = isBinary
    }
}

public struct HermexGitState: Codable, Equatable, Sendable {
    public var isRepository: Bool
    public var branch: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var files: [HermexGitFileChange]
    public var diffPath: String?
    public var diffText: String?
    public var commitMessage: String
    public var isMutating: Bool
    public var errorMessage: String?

    public init(
        isRepository: Bool = false,
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        files: [HermexGitFileChange] = [],
        diffPath: String? = nil,
        diffText: String? = nil,
        commitMessage: String = "",
        isMutating: Bool = false,
        errorMessage: String? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.diffPath = diffPath
        self.diffText = diffText
        self.commitMessage = commitMessage
        self.isMutating = isMutating
        self.errorMessage = errorMessage
    }
}

public enum HermexGitCommand: Equatable, Sendable {
    case fetch
    case pull
    case push
    case diff(path: String, kind: String)
    case stage(path: String)
    case unstage(path: String)
    case discard(path: String, deleteUntracked: Bool)
    case commit(message: String)
}

public struct HermexPanelsState: Codable, Equatable, Sendable {
    public var tasks: [HermexTaskDTO]
    public var skills: [HermexSkillDTO]
    public var memory: [HermexMemorySectionDTO]
    public var insights: HermexJSONValue?
    public var selectedPanel: HermexPanel
    public var isLoading: Bool
    public var errorMessage: String?

    public init(
        tasks: [HermexTaskDTO] = [],
        skills: [HermexSkillDTO] = [],
        memory: [HermexMemorySectionDTO] = [],
        insights: HermexJSONValue? = nil,
        selectedPanel: HermexPanel = .tasks,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.tasks = tasks
        self.skills = skills
        self.memory = memory
        self.insights = insights
        self.selectedPanel = selectedPanel
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

public enum HermexPanel: String, Codable, Equatable, Sendable {
    case tasks
    case skills
    case memory
    case insights
}

public struct HermexTaskDTO: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var status: String?
    public var schedule: String?

    public init(id: String, title: String? = nil, status: String? = nil, schedule: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.schedule = schedule
    }
}

public struct HermexSkillDTO: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var enabled: Bool?
    public var summary: String?

    public init(name: String, enabled: Bool? = nil, summary: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.summary = summary
    }
}

public struct HermexMemorySectionDTO: Codable, Identifiable, Equatable, Sendable {
    public var id: String { section }
    public var section: String
    public var content: String

    public init(section: String, content: String) {
        self.section = section
        self.content = content
    }
}

public struct HermexSettingsState: Codable, Equatable, Sendable {
    public var activeServer: HermexServerIdentity?
    public var servers: [HermexServerIdentity]
    public var appTheme: String
    public var defaultModel: String?
    public var defaultProfile: String?
    public var hapticsEnabled: Bool
    public var glassEnabled: Bool
    public var notificationsEnabled: Bool

    public init(
        activeServer: HermexServerIdentity? = nil,
        servers: [HermexServerIdentity] = [],
        appTheme: String = "system",
        defaultModel: String? = nil,
        defaultProfile: String? = nil,
        hapticsEnabled: Bool = true,
        glassEnabled: Bool = true,
        notificationsEnabled: Bool = false
    ) {
        self.activeServer = activeServer
        self.servers = servers
        self.appTheme = appTheme
        self.defaultModel = defaultModel
        self.defaultProfile = defaultProfile
        self.hapticsEnabled = hapticsEnabled
        self.glassEnabled = glassEnabled
        self.notificationsEnabled = notificationsEnabled
    }
}
