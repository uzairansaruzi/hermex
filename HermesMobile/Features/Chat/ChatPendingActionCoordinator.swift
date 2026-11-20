import Foundation
import Observation
import OSLog

private let chatPendingActionCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatPendingActionCoordinator"
)

struct PendingPromptExpiredError: LocalizedError, Equatable {
    enum Prompt: Equatable {
        case approval
        case clarification
    }

    let prompt: Prompt

    var errorDescription: String? {
        switch prompt {
        case .approval:
            String(localized: "That approval request already expired, so the agent has moved on.")
        case .clarification:
            String(localized: "That clarification prompt already expired, so the agent has moved on.")
        }
    }
}

@MainActor
protocol ChatPendingActionCoordinatorDelegate: AnyObject {
    var pendingActionSessionID: String? { get }
    var pendingActionHasActiveStream: Bool { get }
    var pendingActionIsStreamConnectionSuspended: Bool { get }

    func pendingActionCoordinatorWillSubmitAction()
    func pendingActionCoordinatorDidFailAction(_ error: Error)
}

@MainActor
@Observable
final class ChatPendingActionCoordinator {
    private(set) var approvalPrompt: ApprovalPromptState?
    private(set) var isRespondingToApproval = false
    private(set) var approvalErrorMessage: String?
    private(set) var isSessionApprovalBypassEnabled = false
    private(set) var isChangingApprovalBypass = false
    private(set) var approvalBypassErrorMessage: String?
    private var approvalBypassWrites = 0

    private(set) var clarificationPrompt: ClarificationPromptState?
    private(set) var isRespondingToClarification = false
    private(set) var clarificationErrorMessage: String?

    weak var delegate: ChatPendingActionCoordinatorDelegate?

    private let client: APIClient
    private let approvalStreamClient: SSEStreamingClient
    private let clarifyStreamClient: SSEStreamingClient
    private let pollingIntervals: ChatPollingIntervals

    private var approvalPendingBySession: [String: ApprovalPromptState] = [:]
    private var approvalMonitoringSessionID: String?
    private var approvalHadPendingWhileMonitoring = false
    @ObservationIgnored private var approvalPollingTask: Task<Void, Never>?
    private var approvalStateGeneration = 0

    private var clarificationPendingBySession: [String: ClarificationPromptState] = [:]
    private var clarificationMonitoringSessionID: String?
    @ObservationIgnored private var clarificationPollingTask: Task<Void, Never>?

    var hasPendingPrompt: Bool {
        approvalPrompt != nil || clarificationPrompt != nil
    }

    init(
        client: APIClient,
        approvalStreamClient: SSEStreamingClient,
        clarifyStreamClient: SSEStreamingClient,
        pollingIntervals: ChatPollingIntervals
    ) {
        self.client = client
        self.approvalStreamClient = approvalStreamClient
        self.clarifyStreamClient = clarifyStreamClient
        self.pollingIntervals = pollingIntervals
    }

    deinit {
        approvalPollingTask?.cancel()
        clarificationPollingTask?.cancel()
    }

    func refreshApprovalBypassState() async {
        guard let sessionID = delegate?.pendingActionSessionID else { return }
        let writesBefore = approvalBypassWrites

        do {
            let response = try await client.sessionYolo(sessionID: sessionID)
            guard !Task.isCancelled, delegate?.pendingActionSessionID == sessionID,
                  approvalBypassWrites == writesBefore else { return }
            isSessionApprovalBypassEnabled = response.yoloEnabled == true
            if isSessionApprovalBypassEnabled {
                approvalStateGeneration &+= 1
                approvalPendingBySession[sessionID] = nil
                approvalPrompt = nil
            } else {
                renderApprovalPromptForCurrentSession()
            }
        } catch {
        }

        guard !Task.isCancelled, !isSessionApprovalBypassEnabled else { return }
        await refreshApprovalPending(sessionID: sessionID)
    }

    @discardableResult
    func respondToApproval(_ choice: ApprovalChoice) async -> Bool {
        guard let prompt = approvalPrompt,
              prompt.sessionID == delegate?.pendingActionSessionID
        else { return false }

        isRespondingToApproval = true
        approvalErrorMessage = nil
        delegate?.pendingActionCoordinatorWillSubmitAction()
        defer { isRespondingToApproval = false }

        do {
            let response = try await client.respondApproval(
                sessionID: prompt.sessionID,
                choice: choice,
                approvalID: prompt.pending.approvalId
            )

            guard response.ok == true || response.staleCleared == true else {
                approvalErrorMessage = String(localized: "The server did not accept that response. The request is still waiting.")
                await refreshApprovalPending(sessionID: prompt.sessionID)
                return false
            }

            approvalStateGeneration &+= 1
            approvalPendingBySession[prompt.sessionID] = nil
            approvalPrompt = nil
            await refreshApprovalPending(sessionID: prompt.sessionID)
            return true
        } catch {
            if (error as? APIError)?.indicatesExpiredPendingPrompt == true {
                approvalStateGeneration &+= 1
                approvalPendingBySession[prompt.sessionID] = nil
                approvalPrompt = nil
                delegate?.pendingActionCoordinatorDidFailAction(PendingPromptExpiredError(prompt: .approval))
                await refreshApprovalPending(sessionID: prompt.sessionID)
                return false
            }

            approvalErrorMessage = error.localizedDescription
            delegate?.pendingActionCoordinatorDidFailAction(error)
            return false
        }
    }

    @discardableResult
    func skipApprovalsForCurrentSession() async -> Bool {
        guard let prompt = approvalPrompt,
              prompt.sessionID == delegate?.pendingActionSessionID
        else { return false }

        isRespondingToApproval = true
        approvalErrorMessage = nil
        delegate?.pendingActionCoordinatorWillSubmitAction()
        defer { isRespondingToApproval = false }

        do {
            approvalBypassWrites &+= 1
            let response = try await client.setSessionYolo(sessionID: prompt.sessionID, enabled: true)
            approvalBypassWrites &+= 1
            isSessionApprovalBypassEnabled = response.yoloEnabled ?? true
            approvalStateGeneration &+= 1
            approvalPendingBySession[prompt.sessionID] = nil
            approvalPrompt = nil
            return true
        } catch {
            approvalErrorMessage = error.localizedDescription
            delegate?.pendingActionCoordinatorDidFailAction(error)
            return false
        }
    }

    func setApprovalBypass(_ enabled: Bool) async {
        guard let sessionID = delegate?.pendingActionSessionID, !isChangingApprovalBypass,
              enabled != isSessionApprovalBypassEnabled else { return }
        isChangingApprovalBypass = true
        approvalBypassWrites &+= 1
        approvalBypassErrorMessage = nil
        defer { isChangingApprovalBypass = false }

        do {
            let response = try await client.setSessionYolo(sessionID: sessionID, enabled: enabled)
            approvalBypassWrites &+= 1
            guard !Task.isCancelled, delegate?.pendingActionSessionID == sessionID else { return }
            isSessionApprovalBypassEnabled = response.yoloEnabled ?? enabled
            if isSessionApprovalBypassEnabled {
                approvalStateGeneration &+= 1
                approvalPendingBySession[sessionID] = nil
                approvalPrompt = nil
            } else {
                await refreshApprovalPending(sessionID: sessionID)
                startApprovalMonitoring()
            }
        } catch {
            guard !Task.isCancelled, delegate?.pendingActionSessionID == sessionID else { return }
            approvalBypassErrorMessage = error.localizedDescription
        }
    }

    func startMonitoring() {
        startApprovalMonitoring()
        startClarificationMonitoring()
    }

    func stopMonitoring(clearPrompt: Bool) {
        stopApprovalMonitoring(clearPrompt: clearPrompt)
        stopClarificationMonitoring(clearPrompt: clearPrompt)
    }

    func stopMonitoringForStreamTransition(clearClarification: Bool) {
        if delegate?.pendingActionIsStreamConnectionSuspended == true {
            stopApprovalMonitoring(clearPrompt: false)
        }
        stopClarificationMonitoring(clearPrompt: clearClarification)
    }

    func applyApprovalUpdate(_ update: ApprovalPendingResponse, sessionID: String) {
        if let pending = update.pending, !pending.isEmpty {
            let prompt = ApprovalPromptState(
                sessionID: sessionID,
                pending: pending,
                pendingCount: max(update.pendingCount ?? 1, 1)
            )
            approvalPendingBySession[sessionID] = prompt
        } else if update.pendingCount == 0 {
            approvalPendingBySession[sessionID] = nil
        } else {
            return
        }

        guard sessionID == delegate?.pendingActionSessionID else { return }
        approvalStateGeneration &+= 1
        renderApprovalPromptForCurrentSession()
        if approvalPendingBySession[sessionID] != nil {
            approvalHadPendingWhileMonitoring = true
            startApprovalMonitoring()
        } else if delegate?.pendingActionHasActiveStream != true,
                  approvalMonitoringSessionID == sessionID,
                  approvalHadPendingWhileMonitoring {
            stopApprovalMonitoring(clearPrompt: false)
        }
    }

    @discardableResult
    func respondToClarification(_ responseText: String) async -> Bool {
        guard let prompt = clarificationPrompt,
              prompt.sessionID == delegate?.pendingActionSessionID
        else { return false }

        let response = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            clarificationErrorMessage = String(localized: "Enter a response before submitting.")
            return false
        }

        isRespondingToClarification = true
        clarificationErrorMessage = nil
        delegate?.pendingActionCoordinatorWillSubmitAction()
        defer { isRespondingToClarification = false }

        do {
            _ = try await client.respondClarification(
                sessionID: prompt.sessionID,
                response: response,
                clarifyID: prompt.pending.clarifyId
            )
            clarificationPendingBySession[prompt.sessionID] = nil
            clarificationPrompt = nil
            await refreshClarificationPending(sessionID: prompt.sessionID)
            return true
        } catch {
            if (error as? APIError)?.indicatesExpiredPendingPrompt == true {
                clarificationPendingBySession[prompt.sessionID] = nil
                clarificationPrompt = nil
                delegate?.pendingActionCoordinatorDidFailAction(PendingPromptExpiredError(prompt: .clarification))
                await refreshClarificationPending(sessionID: prompt.sessionID)
                return false
            }

            clarificationErrorMessage = error.localizedDescription
            delegate?.pendingActionCoordinatorDidFailAction(error)
            return false
        }
    }

    func applyClarificationUpdate(_ update: ClarificationPendingResponse, sessionID: String) {
        if let pending = update.pending, !pending.isEmpty {
            let prompt = ClarificationPromptState(
                sessionID: sessionID,
                pending: pending,
                pendingCount: max(update.pendingCount ?? 1, 1)
            )
            clarificationPendingBySession[sessionID] = prompt
        } else {
            clarificationPendingBySession[sessionID] = nil
        }

        renderClarificationPromptForCurrentSession()
    }

    private func startApprovalMonitoring() {
        guard let sessionID = delegate?.pendingActionSessionID,
              delegate?.pendingActionHasActiveStream == true || approvalPendingBySession[sessionID] != nil,
              approvalMonitoringSessionID != sessionID
        else { return }

        stopApprovalMonitoring(clearPrompt: false)
        approvalMonitoringSessionID = sessionID
        approvalHadPendingWhileMonitoring = approvalPendingBySession[sessionID] != nil
        approvalStreamClient.start(url: client.approvalStreamURL(sessionID: sessionID)) { [weak self] event in
            self?.handleApprovalMonitorEvent(event, sessionID: sessionID)
        }
    }

    private func stopApprovalMonitoring(clearPrompt: Bool) {
        let shouldStopStream = approvalMonitoringSessionID != nil || approvalPollingTask != nil
        approvalPollingTask?.cancel()
        approvalPollingTask = nil
        if shouldStopStream {
            approvalStreamClient.stop()
        }
        approvalMonitoringSessionID = nil
        approvalHadPendingWhileMonitoring = false

        guard clearPrompt else { return }
        approvalStateGeneration &+= 1
        if let sessionID = delegate?.pendingActionSessionID {
            approvalPendingBySession[sessionID] = nil
        }
        approvalPrompt = nil
        approvalErrorMessage = nil
    }

    private func handleApprovalMonitorEvent(_ event: SSEEvent, sessionID: String) {
        guard approvalMonitoringSessionID == sessionID else { return }
        switch event {
        case .approvalPending(let update):
            applyApprovalUpdate(update, sessionID: sessionID)
        case .transportError, .error:
            startApprovalFallbackPolling(sessionID: sessionID)
        case .token, .interimAssistant, .reasoning, .toolStarted, .toolCompleted, .title, .metering, .done, .clarificationPending,
             .pendingSteerLeftover, .streamEnd, .cancelled, .heartbeat, .ignored:
            break
        }
    }

    private func startApprovalFallbackPolling(sessionID: String) {
        guard approvalMonitoringSessionID == sessionID else { return }

        approvalStreamClient.stop()
        approvalPollingTask?.cancel()
        let pollingInterval = pollingIntervals.approvalNanoseconds, waitInterval = pollingIntervals.sleep
        approvalPollingTask = Task { @MainActor [weak self] in
            pollingLoop: while !Task.isCancelled {
                do {
                    guard let self,
                          self.delegate?.pendingActionSessionID == sessionID,
                          self.delegate?.pendingActionIsStreamConnectionSuspended != true
                    else { break pollingLoop }

                    await self.refreshApprovalPending(sessionID: sessionID)
                }

                guard !Task.isCancelled else { break }
                await waitInterval(pollingInterval)
            }
        }
    }

    private func refreshApprovalPending(sessionID: String) async {
        guard delegate?.pendingActionSessionID == sessionID else { return }
        approvalStateGeneration &+= 1
        let generation = approvalStateGeneration

        do {
            let response = try await client.approvalPending(sessionID: sessionID)
            guard !Task.isCancelled,
                  delegate?.pendingActionSessionID == sessionID,
                  approvalStateGeneration == generation else { return }
            applyApprovalUpdate(response, sessionID: sessionID)
        } catch {
            chatPendingActionCoordinatorLogger.debug(
                "Approval polling failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    private func renderApprovalPromptForCurrentSession() {
        guard let sessionID = delegate?.pendingActionSessionID else {
            approvalPrompt = nil
            return
        }

        guard !isSessionApprovalBypassEnabled,
              let prompt = approvalPendingBySession[sessionID]
        else {
            if approvalPrompt?.sessionID == sessionID {
                approvalPrompt = nil
            }
            return
        }

        approvalPrompt = prompt
    }

    private func startClarificationMonitoring() {
        guard let sessionID = delegate?.pendingActionSessionID,
              delegate?.pendingActionHasActiveStream == true,
              clarificationMonitoringSessionID != sessionID
        else { return }

        stopClarificationMonitoring(clearPrompt: false)
        clarificationMonitoringSessionID = sessionID
        clarifyStreamClient.start(url: client.clarifyStreamURL(sessionID: sessionID)) { [weak self] event in
            self?.handleClarificationMonitorEvent(event, sessionID: sessionID)
        }
    }

    private func stopClarificationMonitoring(clearPrompt: Bool) {
        let shouldStopStream = clarificationMonitoringSessionID != nil || clarificationPollingTask != nil
        clarificationPollingTask?.cancel()
        clarificationPollingTask = nil
        if shouldStopStream {
            clarifyStreamClient.stop()
        }
        clarificationMonitoringSessionID = nil

        guard clearPrompt else { return }
        if let sessionID = delegate?.pendingActionSessionID {
            clarificationPendingBySession[sessionID] = nil
        }
        clarificationPrompt = nil
        clarificationErrorMessage = nil
    }

    private func handleClarificationMonitorEvent(_ event: SSEEvent, sessionID: String) {
        switch event {
        case .clarificationPending(let update):
            applyClarificationUpdate(update, sessionID: sessionID)
        case .approvalPending(let update):
            if update.pending == nil {
                applyClarificationUpdate(
                    ClarificationPendingResponse(pending: nil, pendingCount: update.pendingCount),
                    sessionID: sessionID
                )
            }
        case .transportError, .error:
            startClarificationFallbackPolling(sessionID: sessionID)
        case .token, .interimAssistant, .reasoning, .toolStarted, .toolCompleted, .title, .metering, .done,
             .pendingSteerLeftover, .streamEnd, .cancelled, .heartbeat, .ignored:
            break
        }
    }

    private func startClarificationFallbackPolling(sessionID: String) {
        guard clarificationMonitoringSessionID == sessionID else { return }

        clarifyStreamClient.stop()
        clarificationPollingTask?.cancel()
        let pollingInterval = pollingIntervals.clarificationNanoseconds, waitInterval = pollingIntervals.sleep
        clarificationPollingTask = Task { @MainActor [weak self] in
            pollingLoop: while !Task.isCancelled {
                do {
                    guard let self,
                          self.delegate?.pendingActionSessionID == sessionID,
                          self.delegate?.pendingActionHasActiveStream == true,
                          self.delegate?.pendingActionIsStreamConnectionSuspended != true
                    else { break pollingLoop }

                    await self.refreshClarificationPending(sessionID: sessionID)
                }

                guard !Task.isCancelled else { break }
                await waitInterval(pollingInterval)
            }
        }
    }

    private func refreshClarificationPending(sessionID: String) async {
        guard delegate?.pendingActionHasActiveStream == true else { return }

        do {
            let response = try await client.clarifyPending(sessionID: sessionID)
            applyClarificationUpdate(response, sessionID: sessionID)
        } catch {
            chatPendingActionCoordinatorLogger.debug(
                "Clarification polling failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    private func renderClarificationPromptForCurrentSession() {
        guard let sessionID = delegate?.pendingActionSessionID else {
            clarificationPrompt = nil
            return
        }

        guard delegate?.pendingActionHasActiveStream == true,
              let prompt = clarificationPendingBySession[sessionID]
        else {
            if clarificationPrompt?.sessionID == sessionID {
                clarificationPrompt = nil
            }
            return
        }

        clarificationPrompt = prompt
    }
}
