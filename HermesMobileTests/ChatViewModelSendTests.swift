import XCTest
import AVFoundation
import ImageIO
import Observation
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class ChatViewModelSendTests: XCTestCase {
    override func tearDown() {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testOpeningSessionDoesNotCreateSpeechSynthesizer() throws {
        var createdSynthesizers = 0

        _ = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return SpySpeechSynthesizer()
            }
        ) { request in
            XCTFail("Opening a session should not request network work in this test.")
            return apiTestJSONResponse("{}", for: request)
        }

        XCTAssertEqual(createdSynthesizers, 0)
    }

    @MainActor
    func testValidStreamProgressClearsRecoveryOwnedComposerError() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse(
                #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                for: request
            )
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        viewModel.streamCoordinatorDidReceiveRecoveryError(APIError.network(underlying: URLError(.timedOut)))
        XCTAssertNotNil(viewModel.sendErrorMessage)

        streamClient.emit(.token("Recovered response"))

        XCTAssertNil(viewModel.sendErrorMessage)
    }

    @MainActor
    func testRecoveryConfirmationDoesNotClearLaterComposerError() throws {
        let viewModel = try makeViewModel { request in
            XCTFail("This test should not make a network request: \(request)")
            throw URLError(.badURL)
        }

        viewModel.streamCoordinatorDidReceiveRecoveryError(APIError.network(underlying: URLError(.timedOut)))
        viewModel.setSendErrorMessage("The response failed on the server.")

        viewModel.streamCoordinatorDidConfirmRecovery()

        XCTAssertEqual(viewModel.sendErrorMessage, "The response failed on the server.")
    }

    @MainActor
    func testListenCreatesSpeechSynthesizerOnlyWhenRequested() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var createdSynthesizers = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return speechSynthesizer
            }
        ) { request in
            // Listen now prefers server TTS (#15); refuse it so the on-device
            // fallback path is what creates the synthesizer.
            XCTAssertEqual(request.url?.path, "/api/tts")
            return Self.ttsUnavailableResponse(for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Playback should be explicit.",
                timestamp: 1_770_000_001,
                messageId: "assistant-1"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-1")
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(createdSynthesizers, 1)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Playback should be explicit."])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-1")
    }

    func testListenAudioSessionRoutesToSpeakerNotEarpiece() {
        // `.playback` forces the speaker (not the receiver/earpiece) by default, and
        // `.spokenAudio` is Apple's recommended mode for synthesized speech. #252.
        XCTAssertEqual(ListenAudioSessionConfiguration.category, .playback)
        XCTAssertEqual(ListenAudioSessionConfiguration.mode, .spokenAudio)
        XCTAssertTrue(
            ListenAudioSessionConfiguration.deactivationOptions.contains(.notifyOthersOnDeactivation)
        )
    }

    @MainActor
    func testListenActivatesAudioSessionBeforeSpeaking() async throws {
        let recorder = ListenCallRecorder()
        let speechSynthesizer = SpySpeechSynthesizer(recorder: recorder)
        let audioSession = SpyListenAudioSession(recorder: recorder)
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            Self.ttsUnavailableResponse(for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Out loud, please.",
                timestamp: 1_770_000_002,
                messageId: "assistant-2"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        // Regression (review on #35): the tap itself must NOT activate the session —
        // a slow `/api/tts` fetch would otherwise silence other audio while Hermex
        // has nothing to play. Activation belongs to the moment playback starts.
        XCTAssertEqual(audioSession.activateCount, 0)
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(audioSession.activateCount, 1)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Out loud, please."])
        // Prove activate precedes speak on a single interleaved timeline shared by both
        // spies (the audio session and the synthesizer), so the "before speaking" claim
        // is provable rather than relying on two independent logs (review on #332).
        let activateIndex = try XCTUnwrap(recorder.events.firstIndex(of: "activate"))
        let speakIndex = try XCTUnwrap(recorder.events.firstIndex(of: "speak"))
        XCTAssertLessThan(activateIndex, speakIndex)
    }

    @MainActor
    func testStaleCancelAfterSwitchingMessagesKeepsNewListenActive() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let audioSession = SpyListenAudioSession()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            Self.ttsUnavailableResponse(for: request)
        }
        func makeContext(_ id: String, _ text: String, _ timestamp: Double) throws -> MessageActionContext {
            try XCTUnwrap(MessageActionContext(
                message: ChatMessage(role: "assistant", content: text, timestamp: timestamp, messageId: id),
                visibleIndex: 0,
                messagesOffset: 0
            ))
        }

        // Start listening to A, then switch to B while A is still "speaking".
        viewModel.toggleListening(to: try makeContext("assistant-A", "First message.", 1_770_000_010))
        await viewModel.listenPreparationTask?.value
        let utteranceA = try XCTUnwrap(speechSynthesizer.spokenUtterances.first)
        viewModel.toggleListening(to: try makeContext("assistant-B", "Second message.", 1_770_000_011))
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(viewModel.listeningMessageID, "assistant-B")
        let deactivationsBeforeStaleCallback = audioSession.deactivateCount

        // A's cancel callback now arrives late, after B has started speaking. It must be
        // ignored so it can't clear B's "now playing" state or deactivate the session.
        speechSynthesizer.fireDidCancel(utteranceA)
        await drainMainActor()

        XCTAssertEqual(viewModel.listeningMessageID, "assistant-B")
        XCTAssertEqual(audioSession.deactivateCount, deactivationsBeforeStaleCallback)

        // A matching completion (for the live utterance B) still tears down cleanly.
        let utteranceB = try XCTUnwrap(speechSynthesizer.spokenUtterances.last)
        speechSynthesizer.fireDidCancel(utteranceB)
        await drainMainActor()

        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertEqual(audioSession.deactivateCount, deactivationsBeforeStaleCallback + 1)
    }

    @MainActor
    func testStoppingListeningReleasesAudioSession() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let audioSession = SpyListenAudioSession()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            Self.ttsUnavailableResponse(for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Stop me cleanly.",
                timestamp: 1_770_000_003,
                messageId: "assistant-3"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value
        let deactivationsAfterStart = audioSession.deactivateCount

        viewModel.stopListening()

        XCTAssertGreaterThan(audioSession.deactivateCount, deactivationsAfterStart)
        XCTAssertNil(viewModel.listeningMessageID)
    }

    @MainActor
    func testListenPrefersServerTTSAndPlaysReturnedAudio() async throws {
        let audioSession = SpyListenAudioSession()
        let remoteControlCenter = SpyListenRemoteControlCenter()
        let userDefaults = try makeEphemeralUserDefaults()
        let player = SpyListenAudioPlayer()
        player.duration = 83
        var receivedAudioData: [Data] = []
        var createdSynthesizers = 0
        let serverAudio = Data([0xFF, 0xF3, 0x18, 0xC4])
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return SpySpeechSynthesizer()
            },
            listenAudioSession: audioSession,
            listenRemoteControlCenter: remoteControlCenter,
            serverTTSAudioPlayerFactory: { data in
                receivedAudioData.append(data)
                return player
            },
            userDefaults: userDefaults
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/tts")
            guard let body = apiTestBodyData(from: request),
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("Missing TTS request body")
                throw URLError(.badServerResponse)
            }
            XCTAssertEqual(json["text"] as? String, "Neural, please.")
            XCTAssertEqual(json["voice"] as? String, ServerTTSPolicy.defaultVoice)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, serverAudio)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Neural, please.",
                timestamp: 1_770_000_020,
                messageId: "assistant-20"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        XCTAssertTrue(viewModel.showsListenPlaybackBar)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .loading)
        // Regression (review on #35): no session activation while the fetch is in
        // flight — only once decoded server audio is about to play.
        XCTAssertEqual(audioSession.activateCount, 0)
        await viewModel.listenPreparationTask?.value

        // Server audio plays; the on-device synthesizer is never touched.
        XCTAssertEqual(receivedAudioData, [serverAudio])
        XCTAssertEqual(player.prepareToPlayCount, 1)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.rate, Float(1))
        XCTAssertEqual(createdSynthesizers, 0)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-20")
        XCTAssertTrue(viewModel.showsListenPlaybackBar)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
        XCTAssertEqual(viewModel.listenPlaybackDuration, 83)
        XCTAssertEqual(audioSession.activateCount, 1)
        XCTAssertEqual(remoteControlCenter.configureCount, 1)
        XCTAssertEqual(remoteControlCenter.snapshots.last, ListenNowPlayingSnapshot(
            title: "Hermex response 1",
            duration: 83,
            elapsedTime: 0,
            speed: .normal,
            isPlaying: true
        ))

        // Natural finish tears listen state down and releases the session. The
        // defensive stopListening() at the start of toggleListening also
        // deactivates once, so assert the finish-driven delta, not a total.
        let deactivationsBeforeFinish = audioSession.deactivateCount
        player.finishPlayback()
        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertFalse(viewModel.showsListenPlaybackBar)
        XCTAssertGreaterThan(audioSession.deactivateCount, deactivationsBeforeFinish)
    }

    @MainActor
    func testListenPlaybackCanPauseResumeSeekAndUseRemoteCommands() async throws {
        let player = SpyListenAudioPlayer()
        player.duration = 120
        let remoteControlCenter = SpyListenRemoteControlCenter()
        let viewModel = try makeViewModel(
            listenRemoteControlCenter: remoteControlCenter,
            serverTTSAudioPlayerFactory: { _ in player }
        ) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data([0xFF, 0xF3]))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Give me controls.",
                timestamp: 1_770_000_025,
                messageId: "assistant-25"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        remoteControlCenter.firePause()
        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .paused)
        XCTAssertFalse(try XCTUnwrap(remoteControlCenter.snapshots.last).isPlaying)

        remoteControlCenter.firePlay()
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
        XCTAssertTrue(try XCTUnwrap(remoteControlCenter.snapshots.last).isPlaying)

        remoteControlCenter.fireChangePlaybackPosition(37)
        XCTAssertEqual(player.currentTime, 37)
        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 37)

        viewModel.toggleListenPlaybackPlayPause()
        XCTAssertEqual(player.pauseCount, 2)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .paused)

        remoteControlCenter.fireTogglePlayPause()
        XCTAssertEqual(player.playCount, 3)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
    }

    @MainActor
    func testListenPlaybackResyncsProgressWhenSceneBecomesActive() async throws {
        let player = SpyListenAudioPlayer()
        player.duration = 90
        let remoteControlCenter = SpyListenRemoteControlCenter()
        let viewModel = try makeViewModel(
            listenRemoteControlCenter: remoteControlCenter,
            serverTTSAudioPlayerFactory: { _ in player }
        ) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data([0xFF, 0xF3]))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Keep progress honest.",
                timestamp: 1_770_000_026,
                messageId: "assistant-26"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value
        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 0)
        let nowPlayingUpdatesAfterStart = remoteControlCenter.snapshots.count

        // Simulates background audio advancing while the foreground UI timer is not
        // firing. Returning to the scene must pull the latest player time into the bar.
        player.currentTime = 42
        viewModel.refreshListenPlaybackProgressAfterSceneActivation()

        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 42)
        XCTAssertEqual(viewModel.listenPlaybackDisplayTime, 42)
        XCTAssertEqual(remoteControlCenter.snapshots.count, nowPlayingUpdatesAfterStart)
    }

    @MainActor
    func testListenPlaybackSeekAndSpeedPersist() async throws {
        let userDefaults = try makeEphemeralUserDefaults()
        let player = SpyListenAudioPlayer()
        player.duration = 120
        let viewModel = try makeViewModel(
            serverTTSAudioPlayerFactory: { _ in player },
            userDefaults: userDefaults
        ) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data([0xFF, 0xF3]))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Remember my speed.",
                timestamp: 1_770_000_026,
                messageId: "assistant-26"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        viewModel.scrubListenPlayback(to: 64)
        XCTAssertEqual(viewModel.listenPlaybackDisplayTime, 64)
        XCTAssertEqual(player.currentTime, 0)

        viewModel.setListenPlaybackScrubbing(false)
        XCTAssertEqual(player.currentTime, 64)
        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 64)
        XCTAssertNil(viewModel.listenPlaybackScrubTime)

        viewModel.setListenPlaybackSpeed(.oneAndHalf)
        XCTAssertEqual(player.rate, Float(1.5))
        XCTAssertEqual(userDefaults.double(forKey: ListenPlaybackSpeed.storageKey), 1.5)

        let reloadedViewModel = try makeViewModel(userDefaults: userDefaults) { request in
            XCTFail("Reading stored playback speed should not hit \(request.url?.path ?? "unknown path")")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(reloadedViewModel.listenPlaybackSpeed, .oneAndHalf)
    }

    @MainActor
    func testStartingListenOnDifferentMessageStopsCurrentServerAudio() async throws {
        let firstPlayer = SpyListenAudioPlayer()
        let secondPlayer = SpyListenAudioPlayer()
        var players = [firstPlayer, secondPlayer]
        let viewModel = try makeViewModel(
            serverTTSAudioPlayerFactory: { _ in
                players.removeFirst()
            }
        ) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data([0xFF, 0xF3]))
        }
        func makeContext(_ id: String, text: String, visibleIndex: Int) throws -> MessageActionContext {
            try XCTUnwrap(MessageActionContext(
                message: ChatMessage(role: "assistant", content: text, timestamp: 1_770_000_030, messageId: id),
                visibleIndex: visibleIndex,
                messagesOffset: 0
            ))
        }

        viewModel.toggleListening(to: try makeContext("assistant-30", text: "First audio.", visibleIndex: 0))
        await viewModel.listenPreparationTask?.value
        viewModel.toggleListening(to: try makeContext("assistant-31", text: "Second audio.", visibleIndex: 1))
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(firstPlayer.stopCount, 1)
        XCTAssertEqual(secondPlayer.playCount, 1)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-31")
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
    }

    @MainActor
    func testListenFallsBackToSynthesizerSilentlyWhenServerTTSFails() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var playerFactoryCalls = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            serverTTSAudioPlayerFactory: { _ in
                playerFactoryCalls += 1
                return SpyListenAudioPlayer()
            }
        ) { request in
            // A raw 429 from the ~2 s rate limit must never surface to the user.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "rate limit exceeded — please wait"}"#.utf8))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Fall back quietly.",
                timestamp: 1_770_000_021,
                messageId: "assistant-21"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(playerFactoryCalls, 0)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Fall back quietly."])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-21")
        // Silent fallback: no error alert for the user (#15).
        XCTAssertNil(viewModel.messageActionErrorMessage)
    }

    @MainActor
    func testListenFallsBackToSynthesizerWhenServerAudioIsUndecodable() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            serverTTSAudioPlayerFactory: { _ in
                throw URLError(.cannotDecodeContentData)
            }
        ) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data("not really audio".utf8))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Bad bytes, good fallback.",
                timestamp: 1_770_000_022,
                messageId: "assistant-22"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Bad bytes, good fallback."])
        XCTAssertNil(viewModel.messageActionErrorMessage)
    }

    @MainActor
    func testListenOverServerLimitSkipsServerTTSEntirely() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer }
        ) { request in
            XCTFail("Text over the 5000-char cap must not hit /api/tts.")
            return apiTestJSONResponse("{}", for: request)
        }
        let longText = String(repeating: "a", count: ServerTTSPolicy.maximumTextLength + 1)
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: longText,
                timestamp: 1_770_000_023,
                messageId: "assistant-23"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)

        // Straight to the on-device path — synchronous, no preparation task.
        XCTAssertNil(viewModel.listenPreparationTask)
        XCTAssertEqual(speechSynthesizer.spokenStrings, [longText])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-23")
    }

    @MainActor
    func testSecondTapWhileFetchingServerAudioStopsInsteadOfRestarting() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var playerFactoryCalls = 0
        var ttsRequests = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            serverTTSAudioPlayerFactory: { _ in
                playerFactoryCalls += 1
                return SpyListenAudioPlayer()
            }
        ) { request in
            ttsRequests += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data([0xFF, 0xF3]))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Tap tap.",
                timestamp: 1_770_000_024,
                messageId: "assistant-24"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        let firstFetch = viewModel.listenPreparationTask
        // Second tap lands while the server fetch is still in flight: it must act
        // as "Stop Listening", not queue a second /api/tts call (#15 double-tap).
        viewModel.toggleListening(to: context)

        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertNil(viewModel.listenPreparationTask)

        // Even if the first response completes after the stop, its stale request
        // ID must not start playback or speech.
        await firstFetch?.value
        XCTAssertEqual(playerFactoryCalls, 0)
        XCTAssertTrue(speechSynthesizer.spokenStrings.isEmpty)
        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertLessThanOrEqual(ttsRequests, 1)
    }

    func testServerTTSPolicyRoutesByServerTextCap() {
        XCTAssertTrue(ServerTTSPolicy.shouldUseServerTTS(for: String(repeating: "a", count: 5000)))
        XCTAssertFalse(ServerTTSPolicy.shouldUseServerTTS(for: String(repeating: "a", count: 5001)))
        XCTAssertEqual(ServerTTSPolicy.defaultVoice, "en-US-AriaNeural")
    }

    @MainActor
    func testUploadAttachmentRejectsOversizedFileBeforeRequest() async throws {
        var didRequestUpload = false
        let viewModel = try makeViewModel { request in
            didRequestUpload = true
            XCTFail("Oversized attachment should not reach \(request.url?.path ?? "unknown path")")
            throw URLError(.badURL)
        }

        await viewModel.uploadAttachment(
            data: Data(count: PendingAttachment.maximumUploadBytes + 1),
            filename: "too-large.mov"
        )

        XCTAssertFalse(didRequestUpload)
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
        XCTAssertEqual(
            viewModel.uploadAttachmentErrorMessage,
            "too-large.mov is too large. Attachments must be 20 MB or smaller."
        )
    }

    @MainActor
    func testUploadAttachmentDownsamplesImagePreviewButUploadsOriginalData() async throws {
        let originalData = try makeJPEGData(size: CGSize(width: 1_600, height: 1_200))
        var uploadedBody: Data?
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/upload")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            uploadedBody = body
            XCTAssertNotNil(body.range(of: originalData))

            return apiTestJSONResponse("""
            {
              "filename": "large.jpg",
              "path": "/tmp/workspace/large.jpg",
              "size": \(originalData.count),
              "mime": "image/jpeg",
              "is_image": true
            }
            """, for: request)
        }

        await viewModel.uploadAttachment(data: originalData, filename: "large.jpg", previewData: originalData)

        let attachment = try XCTUnwrap(viewModel.pendingAttachments.first)
        let thumbnailData = try XCTUnwrap(attachment.thumbnailData)
        XCTAssertNotNil(uploadedBody)
        XCTAssertNotEqual(thumbnailData, originalData)
        XCTAssertGreaterThan(try maxPixelDimension(in: originalData), ImagePreviewDownsampler.attachmentMaxPixelSize)
        XCTAssertLessThanOrEqual(
            try maxPixelDimension(in: thumbnailData),
            ImagePreviewDownsampler.attachmentMaxPixelSize
        )
    }

    func testImagePreviewDownsamplerSkipsWorkWhenCallerIsCancelled() async throws {
        let originalData = try makeJPEGData(size: CGSize(width: 1_600, height: 1_200))
        let task = Task<Data?, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }

            return await ImagePreviewDownsampler.previewDataAsync(
                from: originalData,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            )
        }

        task.cancel()

        let thumbnailData = await task.value

        XCTAssertNil(thumbnailData)
    }

    @MainActor
    func testUploadAttachmentFailurePreservesExistingPendingAttachment() async throws {
        var uploadCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadCount += 1

            if uploadCount == 1 {
                return apiTestJSONResponse("""
                {
                  "filename": "notes.txt",
                  "path": "/tmp/workspace/notes.txt",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """, for: request)
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 413,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )
            return (try XCTUnwrap(response), Data("too large".utf8))
        }

        await viewModel.uploadAttachment(data: Data("hello".utf8), filename: "notes.txt")
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)

        await viewModel.uploadAttachment(data: Data("large".utf8), filename: "large.bin")

        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertEqual(viewModel.pendingAttachments.first?.name, "notes.txt")
        XCTAssertNotNil(viewModel.uploadAttachmentErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testDuplicateUploadFilenamesUseDistinctServerPathsAndLocalPreviews() async throws {
        let imageA = try makeJPEGData(size: CGSize(width: 12, height: 12))
        let imageB = try makeJPEGData(size: CGSize(width: 16, height: 12))
        var uploadedFilenames: [String] = []
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/upload":
                let filename = try apiTestMultipartFilename(from: request)
                uploadedFilenames.append(filename)
                return apiTestJSONResponse("""
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 4,
                  "mime": "image/jpeg",
                  "is_image": true
                }
                """, for: request)
            case "/api/chat/start":
                let body = try apiTestJSONBody(from: request)
                let attachmentPayloads = try XCTUnwrap(body["attachments"] as? [[String: Any]])
                let paths = attachmentPayloads.compactMap { $0["path"] as? String }

                XCTAssertEqual(attachmentPayloads.compactMap { $0["name"] as? String }, [
                    "shared-image.jpg",
                    "shared-image.jpg"
                ])
                XCTAssertEqual(paths.count, 2)
                XCTAssertEqual(Set(paths).count, 2)

                let message = try XCTUnwrap(body["message"] as? String)
                XCTAssertTrue(message.hasPrefix("Compare these\n\n[Attached files: "))
                for path in paths {
                    XCTAssertTrue(message.contains(path))
                }

                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(data: Data("image-a".utf8), filename: "shared-image.jpg", previewData: imageA)
        await viewModel.uploadAttachment(data: Data("image-b".utf8), filename: "shared-image.jpg", previewData: imageB)

        XCTAssertEqual(uploadedFilenames.count, 2)
        XCTAssertEqual(uploadedFilenames[0], "shared-image.jpg")
        XCTAssertTrue(uploadedFilenames[1].hasPrefix("shared-image-"))
        XCTAssertTrue(uploadedFilenames[1].hasSuffix(".jpg"))
        XCTAssertNotEqual(uploadedFilenames[0], uploadedFilenames[1])
        XCTAssertEqual(viewModel.pendingAttachments.map(\.name), ["shared-image.jpg", "shared-image.jpg"])
        XCTAssertEqual(Set(viewModel.pendingAttachments.map(\.path)).count, 2)

        let didStart = await viewModel.sendMessage("Compare these")

        XCTAssertTrue(didStart)
        let message = try XCTUnwrap(viewModel.messages.first)
        let messageID = try XCTUnwrap(message.messageId)
        let paths = try XCTUnwrap(message.attachments?.compactMap(\.path))
        let previews = try XCTUnwrap(viewModel.localAttachmentPreviews[messageID])
        XCTAssertEqual(Set(previews.keys), Set(paths))
        XCTAssertEqual(previews[paths[0]], imageA)
        XCTAssertEqual(previews[paths[1]], imageB)
    }

    @MainActor
    func testSelectWorkspaceUpdatesSelectionAndRollsBackOnFailure() async throws {
        var updateCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session/update")
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            XCTAssertEqual(body["model"] as? String, "gpt-5.4")

            updateCount += 1
            if updateCount == 1 {
                XCTAssertEqual(body["workspace"] as? String, "/tmp/next")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/next",
                    "model": "gpt-5.4"
                  }
                }
                """, for: request)
            }

            XCTAssertEqual(body["workspace"] as? String, "/tmp/failing")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"workspace failed"}"#.utf8))
        }

        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/workspace")

        await viewModel.selectWorkspacePath("/tmp/next")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/next")
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)

        await viewModel.selectWorkspacePath("/tmp/failing")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/next")
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(updateCount, 2)
    }

    @MainActor
    func testSendMessageRollsBackOptimisticMessageWhenStartReturnsNoStreamID() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "photo.png",
                  "path": "/tmp/workspace/photo.png",
                  "size": 4,
                  "mime": "image/png",
                  "is_image": true
                }
                """, for: request)
            case "/api/chat/start":
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["message"] as? String, "Summarize it\n\n[Attached files: /tmp/workspace/photo.png]")
                XCTAssertNotNil(body["attachments"])

                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "error": "Could not start chat"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(
            data: Data([0x00, 0x01, 0x02, 0x03]),
            filename: "photo.png",
            previewData: Data([0x99])
        )

        XCTAssertEqual(viewModel.pendingAttachments.count, 1)

        let didStart = await viewModel.sendMessage("Summarize it")

        XCTAssertFalse(didStart)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.localAttachmentPreviews.isEmpty)
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertEqual(viewModel.pendingAttachments.first?.name, "photo.png")
        XCTAssertEqual(viewModel.sendErrorMessage, "Could not start chat")
    }

    @MainActor
    func testSendMessageAddsSingleOptimisticUserMessageWhenStartSucceeds() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["message"] as? String, "Keep working")

            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("  Keep working  ")

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.role, "user")
        XCTAssertEqual(viewModel.messages.first?.content, "Keep working")
        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" && $0.content == "Keep working" }.count, 1)
    }

    @MainActor
    func testSendVoiceNoteSendsBareTranscriptWithoutAttachedFilesSuffix() async throws {
        let streamClient = SpySSEStreamingClient()
        let transcript = "Hello, hello, testing. Can you hear me?"
        var startMessage: String?
        var startAttachments: [[String: Any]]?
        var requestedPaths: [String] = []

        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")
            switch path {
            case "/api/transcribe":
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "transcript": "\(transcript)"
                }
                """, for: request)
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "voice-note.m4a",
                  "path": "/tmp/workspace/voice-note.m4a",
                  "size": 2048,
                  "mime": "audio/m4a",
                  "is_image": false
                }
                """, for: request)
            case "/api/chat/start":
                let body = try apiTestJSONBody(from: request)
                startMessage = body["message"] as? String
                startAttachments = body["attachments"] as? [[String: Any]]
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendVoiceNote(
            audioData: Data("fake-m4a-bytes".utf8),
            filename: "voice-note.m4a"
        )

        XCTAssertTrue(didStart)
        XCTAssertEqual(requestedPaths, ["/api/transcribe", "/api/upload", "/api/chat/start"])

        // The message the model sees is exactly the transcript — no
        // "[Attached files: …]" suffix that would make the agent try to "inspect"
        // (transcribe) the clip itself instead of answering the transcript (#330).
        XCTAssertEqual(startMessage, transcript)
        XCTAssertFalse(try XCTUnwrap(startMessage).contains("[Attached files:"))

        // The clip still rides along as a display-only attachment so the inline
        // player renders and persists; the server strips this attachment metadata
        // before the model call, so it never reaches the agent.
        let attachments = try XCTUnwrap(startAttachments)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["path"] as? String, "/tmp/workspace/voice-note.m4a")
        XCTAssertEqual(attachments.first?["mime"] as? String, "audio/m4a")
        XCTAssertEqual(attachments.first?["is_image"] as? Bool, false)

        // Optimistic bubble: transcript text plus the playable clip attachment.
        let optimistic = try XCTUnwrap(viewModel.messages.first)
        XCTAssertEqual(optimistic.role, "user")
        XCTAssertEqual(optimistic.content, transcript)
        XCTAssertEqual(optimistic.attachments?.count, 1)
        XCTAssertEqual(optimistic.attachments?.first?.mime, "audio/m4a")
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    func testChatMessageTextStillAppendsAttachedFilesSuffixForFileUploads() {
        // Guard: the voice-note path deliberately bypasses chatMessageText to send
        // the bare transcript (#330), but real file uploads from the text composer
        // MUST keep the "[Attached files: …]" suffix so the agent can inspect them.
        let file = PendingAttachment(
            name: "report.pdf",
            path: "/tmp/workspace/report.pdf",
            mime: "application/pdf",
            size: 1234,
            isImage: false,
            thumbnailData: nil
        )

        let text = PendingAttachment.chatMessageText(draft: "Summarize this", attachments: [file])

        XCTAssertEqual(text, "Summarize this\n\n[Attached files: /tmp/workspace/report.pdf]")
    }

    func testChatMessageTextSynthesizesUploadedFormForEmptyDraft() {
        // Attachment-only send (#403): with no typed draft the message text is
        // synthesized exactly like the web UI (`static/messages.js`), since the
        // server requires non-empty text.
        let image = PendingAttachment(
            name: "photo.jpg",
            path: "/tmp/workspace/photo.jpg",
            mime: "image/jpeg",
            size: 45_678,
            isImage: true,
            thumbnailData: nil
        )
        let file = PendingAttachment(
            name: "report.pdf",
            path: "/tmp/workspace/report.pdf",
            mime: "application/pdf",
            size: 1234,
            isImage: false,
            thumbnailData: nil
        )

        XCTAssertEqual(
            PendingAttachment.chatMessageText(draft: "", attachments: [image, file]),
            "I've uploaded 2 file(s): /tmp/workspace/photo.jpg, /tmp/workspace/report.pdf"
        )
        XCTAssertEqual(
            PendingAttachment.chatMessageText(draft: "   ", attachments: [file]),
            "I've uploaded 1 file(s): /tmp/workspace/report.pdf",
            "Whitespace-only draft counts as attachment-only"
        )
        XCTAssertEqual(
            PendingAttachment.chatMessageText(draft: "", attachments: []),
            "",
            "No attachments: the empty draft passes through unchanged"
        )
    }

    @MainActor
    func testSendMessageWithEmptyDraftAndStagedAttachmentSendsSynthesizedMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        var startMessage: String?
        var startAttachments: [[String: Any]]?

        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "photo.jpg",
                  "path": "/tmp/workspace/photo.jpg",
                  "size": 45678,
                  "mime": "image/jpeg",
                  "is_image": true
                }
                """, for: request)
            case "/api/chat/start":
                let body = try apiTestJSONBody(from: request)
                startMessage = body["message"] as? String
                startAttachments = body["attachments"] as? [[String: Any]]
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-403"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        // Stage one attachment through the real coordinator (mocked upload).
        let staged = await viewModel.uploadAttachment(
            data: Data("fake-jpeg".utf8),
            filename: "photo.jpg"
        )
        try XCTUnwrap(staged)
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)

        // Empty draft + staged attachment: previously rejected, now sends.
        let didStart = await viewModel.sendMessage("")

        XCTAssertTrue(didStart)
        XCTAssertEqual(startMessage, "I've uploaded 1 file(s): /tmp/workspace/photo.jpg")
        XCTAssertEqual(viewModel.activeStreamID, "stream-403")

        // Optimistic bubble shows the synthesized text plus the attachment.
        let optimistic = try XCTUnwrap(viewModel.messages.first)
        XCTAssertEqual(optimistic.role, "user")
        XCTAssertEqual(optimistic.content, "I've uploaded 1 file(s): /tmp/workspace/photo.jpg")
        XCTAssertEqual(optimistic.attachments?.count, 1)
        XCTAssertEqual(optimistic.attachments?.first?.path, "/tmp/workspace/photo.jpg")
        XCTAssertEqual(try XCTUnwrap(startAttachments)?.count, 1)

        // The composer strip is empty after a successful send.
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
    }

    @MainActor
    func testSendMessageWithEmptyDraftAndNoAttachmentsStillReturnsFalse() async {
        let viewModel = try? makeViewModel { _ in
            XCTFail("No request should be made for an empty draft with no attachments")
            throw URLError(.badURL)
        }

        let didStart = await viewModel?.sendMessage("") ?? false

        XCTAssertFalse(didStart)
    }

    @MainActor
    func testSubmitGoalAttachesToServerStartedKickoffStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/goal":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["args"] as? String, "Ship the TestFlight build")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, "gpt-5.4")

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "action": "set",
                  "message": "Goal set.",
                  "goal": {
                    "goal": "Ship the TestFlight build",
                    "status": "active",
                    "turns_used": 0,
                    "max_turns": 20
                  },
                  "kickoff_prompt": "Start executing the goal."
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-goal",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Start executing the goal.",
                        "timestamp": 1770000100,
                        "message_id": "user-goal"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didSubmit = await viewModel.submitGoal(args: "Ship the TestFlight build")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(requestedPaths, ["/api/goal", "/api/session"])
        XCTAssertEqual(viewModel.currentGoal?.goal, "Ship the TestFlight build")
        XCTAssertEqual(viewModel.currentGoal?.status, "active")
        XCTAssertTrue(viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(viewModel.activeStreamID, "stream-goal")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/chat/stream")
        XCTAssertEqual(viewModel.messages.map(\.role), ["user"])
        XCTAssertEqual(viewModel.messages.last?.content, "Start executing the goal.")
        XCTAssertEqual(viewModel.pinnedLocalNotices, ["Goal set."])

        streamClient.emit(.token("Working now."))

        XCTAssertEqual(viewModel.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Working now.")
    }

    @MainActor
    func testGoalSlashCommandSubmitsStatusAndRevealsGoalControls() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/goal")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            XCTAssertEqual(body["args"] as? String, "status")
            XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body["model"] as? String, "gpt-5.4")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "action": "status",
              "message": "Goal is active.",
              "goal": {
                "goal": "Ship the TestFlight build",
                "status": "active",
                "turns_used": 1,
                "max_turns": 20
              }
            }
            """, for: request)
        }

        XCTAssertFalse(viewModel.hasActivatedGoalCommand)

        let result = await SlashCommandExecutor.execute(text: "/goal", viewModel: viewModel)

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(viewModel.currentGoal?.goal, "Ship the TestFlight build")
        XCTAssertEqual(viewModel.currentGoal?.status, "active")
        XCTAssertEqual(viewModel.messages.map(\.role), ["local_notice"])
        XCTAssertEqual(viewModel.messages.first?.content, "Goal is active.")
    }

    @MainActor
    func testBareResumeSlashCommandFallsThroughToNormalSendPath() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": []}"#, for: request)
            case "/api/chat/start":
                XCTFail("Executor fallthrough should let ChatView perform the normal send later.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/resume", viewModel: viewModel)

        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertEqual(requestedPaths, ["/api/skills"])
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testUnknownNonBlockedSlashCommandFallsThroughToNormalSendPath() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": []}"#, for: request)
            case "/api/chat/start":
                XCTFail("Executor fallthrough should let ChatView perform the normal send later.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/unknown-slash keep going", viewModel: viewModel)

        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertEqual(requestedPaths, ["/api/skills"])
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testKnownUnsupportedSlashCommandStaysBlockedWithoutSkillLookup() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestedPaths.append(request.url?.path ?? "nil")
            XCTFail("Known unsupported commands should not request skills or start chat.")
            throw URLError(.badURL)
        }

        let result = await SlashCommandExecutor.execute(text: "/terminal", viewModel: viewModel)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Terminal is not available in the mobile app."))
        XCTAssertEqual(requestedPaths, [])
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSkillShortcutExecutesBeforeUnknownCommandFallthrough() async throws {
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/start":
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/spotify check songs", viewModel: viewModel)

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(startedMessage, "/spotify check songs")
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testGoalResumeSlashCommandStillUsesGoalEndpoint() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/goal":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["args"] as? String, "resume")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, "gpt-5.4")

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "action": "resume",
                  "message": "Goal resumed.",
                  "goal": {
                    "goal": "Ship the TestFlight build",
                    "status": "active",
                    "turns_used": 2,
                    "max_turns": 20
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/goal resume", viewModel: viewModel)

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestedPaths, ["/api/goal"])
        XCTAssertTrue(viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(viewModel.currentGoal?.status, "active")
        XCTAssertEqual(viewModel.messages.map(\.role), ["local_notice"])
        XCTAssertEqual(viewModel.messages.first?.content, "Goal resumed.")
    }

    @MainActor
    func testApprovalStreamPublishesPromptAndRespondsWithoutStoppingChatStream() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var respondBody: [String: Any]?
        var didFetchPendingAfterResponse = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/approval/respond":
                respondBody = try XCTUnwrap(apiTestJSONBody(from: request))
                return apiTestJSONResponse(#"{"ok": true, "choice": "once"}"#, for: request)
            case "/api/approval/pending":
                didFetchPendingAfterResponse = true
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")

        XCTAssertTrue(didStart)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/chat/stream")
        XCTAssertEqual(approvalStreamClient.startedURLs.first?.path, "/api/approval/stream")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(approvalStreamClient.startedURLs.first), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session_id" })?
                .value,
            "session-abc"
        )

        let gatewayApproval = ApprovalPendingResponse.streamPayload(from: Data("""
        {
          "pending": {
            "id": "approval-1",
            "command": "curl https://example.test/install.sh | bash",
            "description": "High risk command",
            "pattern_keys": ["network_download", "pipe_to_shell"]
          },
          "pending_count": 2
        }
        """.utf8))
        approvalStreamClient.emit(.approvalPending(gatewayApproval))

        XCTAssertEqual(viewModel.approvalPrompt?.sessionID, "session-abc")
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertEqual(viewModel.approvalPrompt?.pendingCount, 2)
        XCTAssertEqual(viewModel.approvalPrompt?.patternKeys, ["network_download", "pipe_to_shell"])

        await viewModel.respondToApproval(.once)

        XCTAssertEqual(respondBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(respondBody?["choice"] as? String, "once")
        XCTAssertEqual(respondBody?["approval_id"] as? String, "approval-1")
        XCTAssertTrue(didFetchPendingAfterResponse)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testPendingApprovalRemainsAnswerableAfterChatStreamEnds() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var responded = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-123"}"#, for: request)
            case "/api/approval/respond":
                responded = true
                return apiTestJSONResponse(#"{"ok":true,"choice":"once"}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse(#"{"pending":null,"pending_count":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run setup")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(approvalId: "approval-1", command: "make install"),
            pendingCount: 1
        )))
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(pending: nil, pendingCount: nil)))
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")

        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertEqual(approvalStreamClient.stopCount, 0)

        let didRespond = await viewModel.respondToApproval(.once)
        XCTAssertTrue(didRespond)
        XCTAssertTrue(responded)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(approvalStreamClient.stopCount, 1)
    }

    @MainActor
    func testApprovalArrivingAfterChatStreamEndsIsShown() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-123"}"#, for: request)
            case "/api/approval/respond":
                return apiTestJSONResponse(#"{"ok":true,"choice":"once"}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse(#"{"pending":null,"pending_count":0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run setup")
        XCTAssertTrue(didStart)
        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(approvalStreamClient.stopCount, 0)

        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(pending: nil, pendingCount: 0)))
        XCTAssertEqual(approvalStreamClient.stopCount, 0)

        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(approvalId: "approval-1", command: "make install"),
            pendingCount: 1
        )))
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")

        let didRespond = await viewModel.respondToApproval(.once)
        XCTAssertTrue(didRespond)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(approvalStreamClient.stopCount, 1)
    }

    @MainActor
    func testIdleSessionLoadsPendingApprovalAndClearsOnServerUpdate() async throws {
        let approvalStreamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(approvalStreamClient: approvalStreamClient) { request in
            switch request.url?.path {
            case "/api/session/yolo":
                return apiTestJSONResponse(#"{"ok":true,"yolo_enabled":false}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse(
                    #"{"pending":{"approval_id":"approval-1","command":"make install"},"pending_count":1}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.refreshApprovalBypassState()

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertEqual(approvalStreamClient.startedURLs.count, 1)

        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(pending: nil, pendingCount: 0)))
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(approvalStreamClient.stopCount, 1)
    }

    @MainActor
    func testSuspendingChatConnectionKeepsPendingApprovalVisible() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-123"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Run setup")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(approvalId: "approval-1", command: "make install"),
            pendingCount: 1
        )))

        viewModel.suspendStreamForBackground()

        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertEqual(approvalStreamClient.stopCount, 1)
    }

    @MainActor
    func testApprovalResponseDoesNotUseSyntheticDisplayIDWhenServerIdentifierMissing() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var respondBody: [String: Any]?
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/respond":
                respondBody = try XCTUnwrap(apiTestJSONBody(from: request))
                return apiTestJSONResponse(#"{"ok": true, "choice": "once"}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        XCTAssertEqual(viewModel.approvalPrompt?.pending.id, "make install-Install command-install")

        await viewModel.respondToApproval(.once)

        XCTAssertEqual(respondBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(respondBody?["choice"] as? String, "once")
        XCTAssertNil(respondBody?["approval_id"])
    }

    @MainActor
    func testApprovalResponseFailureKeepsPromptAndPublishesActionError() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let clarifyStreamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/respond":
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToApproval(.deny)

        XCTAssertFalse(didRespond)
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.approvalErrorMessage, viewModel.sendErrorMessage)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testApprovalStale409DismissesPromptWithFriendlyExpiredMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let clarifyStreamClient = SpySSEStreamingClient()
        var didRefreshPendingAfterStale = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/respond":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"ok": false, "error": "Approval prompt expired or not found.", "stale": true}"#.utf8))
            case "/api/approval/pending":
                didRefreshPendingAfterStale = true
                return apiTestJSONResponse(#"{"pending": null}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToApproval(.once)

        // Expired prompt: the stale card dismisses with a friendly explanation
        // instead of sticking around behind a generic failure (issue #25).
        XCTAssertFalse(didRespond)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertNil(viewModel.approvalErrorMessage)
        XCTAssertEqual(
            viewModel.sendErrorMessage,
            PendingPromptExpiredError(prompt: .approval).localizedDescription
        )
        XCTAssertTrue(didRefreshPendingAfterStale)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    /// The protective refusals answer HTTP 200 with `{"ok": false}` — `j()`
    /// defaults to 200 — so only a non-2xx threw and a deliberate refusal read
    /// as success. The card was cleared with no explanation while the agent
    /// stayed blocked, and the next pending refresh made it reappear.
    @MainActor
    func testApprovalRespondRejectedWithOkFalseKeepsTheCardAndExplains() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()

        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: SpySSEStreamingClient()
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/respond":
                // 200, not an error status — that is the whole trap.
                return apiTestJSONResponse(#"{"ok": false, "choice": "once"}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse("""
                {"pending": {"approval_id": "approval-1", "command": "make install",
                 "description": "Install command", "pattern_key": "install"},
                 "pending_count": 1}
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToApproval(.once)

        XCTAssertFalse(didRespond, "A refusal is not a success.")
        XCTAssertNotNil(viewModel.approvalPrompt, "The agent is still waiting, so the card stays.")
        XCTAssertNotNil(viewModel.approvalErrorMessage, "Silence here is what made this untraceable.")
    }

    /// A response without `ok: true` is not proof the server accepted the
    /// choice, so the pending card must remain actionable.
    @MainActor
    func testApprovalRespondWithoutAnOkFieldKeepsTheCardAndExplains() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()

        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: SpySSEStreamingClient()
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/respond":
                return apiTestJSONResponse(#"{"choice": "once"}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse("""
                {"pending": {"approval_id": "approval-1", "command": "make install",
                 "description": "Install command", "pattern_key": "install"},
                 "pending_count": 1}
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToApproval(.once)

        XCTAssertFalse(didRespond)
        XCTAssertNotNil(viewModel.approvalPrompt)
        XCTAssertNotNil(viewModel.approvalErrorMessage)
    }

    @MainActor
    func testApprovalFallbackPollingFailureStaysDiagnosticOnly() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let approvalPendingRequests = LockedCounter()
        let pollingIntervals = ChatPollingIntervals(
            approvalNanoseconds: 100_000_000,
            clarificationNanoseconds: 100_000_000,
            backgroundNanoseconds: 100_000_000
        )
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            pollingIntervals: pollingIntervals
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/pending":
                _ = approvalPendingRequests.increment()
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)

        approvalStreamClient.emit(.transportError("approval stream failed"))
        try await waitUntil {
            approvalPendingRequests.count > 0
        }

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.approvalErrorMessage)

        viewModel.cleanupPollingTasks()
    }

    @MainActor
    func testApprovalFallbackFindsLateApprovalAfterEmptyIdleProbe() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let approvalPendingRequests = LockedCounter()
        let approvalAppeared = expectation(description: "late approval appeared")
        let pollingIntervals = ChatPollingIntervals(
            approvalNanoseconds: 10_000_000,
            clarificationNanoseconds: 100_000_000,
            backgroundNanoseconds: 100_000_000
        )
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            pollingIntervals: pollingIntervals
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-123"}"#, for: request)
            case "/api/approval/pending":
                if approvalPendingRequests.increment() == 1 {
                    return apiTestJSONResponse(#"{"pending":null,"pending_count":0}"#, for: request)
                }
                return apiTestJSONResponse(
                    #"{"pending":{"approval_id":"approval-1","command":"make install"},"pending_count":1}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run setup")
        XCTAssertTrue(didStart)
        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)

        withObservationTracking {
            _ = viewModel.approvalPrompt
        } onChange: {
            approvalAppeared.fulfill()
        }
        approvalStreamClient.emit(.transportError("approval stream failed"))
        await fulfillment(of: [approvalAppeared], timeout: 2)

        XCTAssertGreaterThanOrEqual(approvalPendingRequests.count, 2)
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        viewModel.cleanupPollingTasks()
    }

    @MainActor
    func testCleanupPollingTasksCancelsStoredPollingTasks() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let clarifyStreamClient = SpySSEStreamingClient()
        let approvalPendingRequests = LockedCounter()
        let clarificationPendingRequests = LockedCounter()
        let backgroundStatusRequests = LockedCounter()
        let pollingIntervals = ChatPollingIntervals(
            approvalNanoseconds: 100_000_000,
            clarificationNanoseconds: 100_000_000,
            backgroundNanoseconds: 100_000_000
        )
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            pollingIntervals: pollingIntervals
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/approval/pending":
                _ = approvalPendingRequests.increment()
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            case "/api/clarify/pending":
                _ = clarificationPendingRequests.increment()
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            case "/api/background":
                return apiTestJSONResponse(#"{"task_id": "task-1", "stream_id": "stream-bg", "session_id": "background-1"}"#, for: request)
            case "/api/background/status":
                _ = backgroundStatusRequests.increment()
                return apiTestJSONResponse(#"{"results": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.transportError("approval stream failed"))
        clarifyStreamClient.emit(.transportError("clarification stream failed"))

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "background")),
            args: "audit tests"
        )
        XCTAssertEqual(result, .executed(message: "Background task started. I'll add the result here when it completes."))

        try await waitUntil {
            approvalPendingRequests.count > 0 &&
                clarificationPendingRequests.count > 0 &&
                backgroundStatusRequests.count > 0
        }

        viewModel.cleanupPollingTasks()
        let approvalCountAfterCleanup = approvalPendingRequests.count
        let clarificationCountAfterCleanup = clarificationPendingRequests.count
        let backgroundCountAfterCleanup = backgroundStatusRequests.count

        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(approvalPendingRequests.count, approvalCountAfterCleanup)
        XCTAssertEqual(clarificationPendingRequests.count, clarificationCountAfterCleanup)
        XCTAssertEqual(backgroundStatusRequests.count, backgroundCountAfterCleanup)
    }

    @MainActor
    func testApprovalForDifferentSessionDoesNotRenderOverCurrentChat() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        viewModel.applyApprovalUpdate(
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: "other-approval",
                    command: "danger",
                    description: "Other session",
                    patternKey: "other"
                ),
                pendingCount: 1
            ),
            sessionID: "other-session"
        )

        XCTAssertNil(viewModel.approvalPrompt)

        viewModel.applyApprovalUpdate(
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: "current-approval",
                    command: "python script.py",
                    description: "Current session",
                    patternKey: "python_exec"
                ),
                pendingCount: 1
            ),
            sessionID: "session-abc"
        )

        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "current-approval")
    }

    @MainActor
    func testSkipAllThisSessionEnablesYoloAndClearsPrompt() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var yoloBody: [String: Any]?
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/session/yolo":
                yoloBody = try XCTUnwrap(apiTestJSONBody(from: request))
                return apiTestJSONResponse(#"{"ok": true, "yolo_enabled": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run setup")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))
        XCTAssertNotNil(viewModel.approvalPrompt)

        await viewModel.skipApprovalsForCurrentSession()

        XCTAssertEqual(yoloBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(yoloBody?["enabled"] as? Bool, true)
        XCTAssertEqual(viewModel.isSessionApprovalBypassEnabled, true)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testLiveStreamEventsUpdateTranscriptBeforeCompletion() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")

        streamClient.emit(.reasoning("I need to inspect the workspace."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading PROJECT_SPEC.md",
            args: ["path": .string("PROJECT_SPEC.md")],
            duration: nil,
            isError: nil
        )))
        let presentationID = try XCTUnwrap(viewModel.liveToolCalls.first?.presentationID)
        XCTAssertTrue(viewModel.liveToolCalls.first?.id.hasPrefix("live-tool-") == true)

        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read PROJECT_SPEC.md",
            args: ["path": .string("PROJECT_SPEC.md")],
            duration: 0.25,
            isError: false,
            stableID: "call-read-file"
        )))
        streamClient.emit(.token("First live token."))

        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.id, "call-read-file")
        XCTAssertEqual(viewModel.liveToolCalls.first?.presentationID, presentationID)
        XCTAssertEqual(
            ToolCallSummaryFormatter.entries(for: viewModel.liveToolCalls, isLive: true).first?.id,
            presentationID
        )
        XCTAssertEqual(viewModel.liveToolCalls.first?.name, "read_file")
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, true)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "First live token.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertFalse(viewModel.responseCompletionHapticTrigger > 0)
    }

    @MainActor
    func testReasoningAndToolEventsAnchorToStableAssistantTurnBeforeFirstToken() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Use tools before answering")
        XCTAssertTrue(didStart)

        streamClient.emit(.reasoning("I should inspect the workspace."))

        let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.messageId, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.content, "")
        XCTAssertEqual(viewModel.reasoningAnchorMessageID, liveAssistantID)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "terminal",
            preview: "pwd",
            args: ["cmd": .string("pwd")],
            duration: nil,
            isError: nil
        )))

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.toolCallAnchorMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["terminal"])

        streamClient.emit(.token("Live answer starts now."))

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.messageId, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.content, "Live answer starts now.")
    }

    @MainActor
    func testLiveStreamScrollTriggerCoalescesRapidUpdates() async throws {
        let streamClient = SpySSEStreamingClient()
        streamClient.automaticallyFlushPendingStreamingContent = false
        // Inject a tiny coalescing window. Determinism comes from flushing
        // synchronously and awaiting the pending scroll-trigger task below, not from
        // this value; a small delay just keeps those awaits fast. The production
        // default (16ms) is exercised everywhere else.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            streamingScrollCoalescingDelayNanoseconds: 1_000_000
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Stream a long response")
        XCTAssertTrue(didStart)

        // sendMessage's optimistic user-message append schedules a coalesced scroll
        // trigger. Settle it so the increments measured below come only from the
        // streaming bursts — this is the task that used to race the real 16ms window
        // before the synchronous assertion ran.
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        let initialTrigger = viewModel.streamingScrollTrigger

        // Burst 1: 20 rapid tokens batch behind a single coalesced flush. Nothing has
        // scrolled yet at this synchronous point — no await has elapsed since the
        // burst, regardless of CPU load.
        for index in 0..<20 {
            streamClient.emit(.token("token-\(index) "))
        }
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)

        // Flushing the batch schedules exactly one (still-deferred) scroll trigger;
        // draining it advances the trigger by exactly one — not 20 — proving the
        // 20-token burst coalesced into a single scroll.
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 1)
        XCTAssertTrue(viewModel.messages.last?.content?.hasPrefix("token-0 token-1") == true)

        // Burst 2: a distinct, heterogeneous reasoning + tool-start burst. Flushing
        // the batched reasoning while the tool-start scroll trigger is still pending
        // exercises the production coalescing guard (one pending trigger at a time),
        // so the whole burst collapses into exactly one more increment regardless of
        // task scheduling order.
        streamClient.emit(.reasoning("Check the next step."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading README.md",
            args: ["path": .string("README.md")],
            duration: nil,
            isError: nil
        )))
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 1)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 1)
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger + 2)
    }

    @MainActor
    func testDisplayedTranscriptMessagesMemoMatchesPureMappingAcrossAppendsAndEdits() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        func assertMemoMatchesPureMapping(_ message: String, line: UInt = #line) {
            XCTAssertEqual(
                viewModel.displayedTranscriptMessages,
                ChatViewModel.transcriptMessages(
                    from: viewModel.messages,
                    messageOffset: viewModel.messagesOffset
                ),
                message,
                line: line
            )
        }

        // Empty transcript before any work.
        assertMemoMatchesPureMapping("memo should match for an empty transcript")

        // Append: optimistic user message + streaming assistant turn.
        let didStart = await viewModel.sendMessage("Stream a long response")
        XCTAssertTrue(didStart)
        assertMemoMatchesPureMapping("memo should match after the optimistic append")

        // Edit: streaming tokens mutate the assistant message content in place.
        streamClient.emit(.token("first chunk "))
        viewModel.flushPendingStreamingContent()
        XCTAssertTrue(viewModel.messages.last?.content?.contains("first chunk") == true)
        assertMemoMatchesPureMapping("memo should match after a streaming content edit")

        // Further edit: a second flush updates the same message again.
        streamClient.emit(.token("second chunk "))
        viewModel.flushPendingStreamingContent()
        assertMemoMatchesPureMapping("memo should match after a second content edit")
    }

    @MainActor
    func testInterimAssistantEventUpdatesTranscriptBeforeCompletion() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Use the project skill")
        XCTAssertTrue(didStart)

        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "Inspecting repo structure.",
            alreadyStreamed: false
        )))

        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Inspecting repo structure.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertFalse(viewModel.responseCompletionHapticTrigger > 0)
    }

    @MainActor
    func testLoadMessagesClearsPendingStreamingBuffersBeforeReload() async throws {
        let streamClient = SpySSEStreamingClient()
        streamClient.automaticallyFlushPendingStreamingContent = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "From server.",
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        for index in 0..<5 {
            streamClient.emit(.token("buffered-\(index) "))
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "From server.")

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "From server.")
    }

    @MainActor
    func testLoadMessagesDuringActiveStreamPreservesLiveStateWhenServerSnapshotIsStale() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        streamClient.emit(.reasoning("I need to inspect the workspace."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading CURRENT.md",
            args: ["path": .string("CURRENT.md")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.token("Partial live answer."))

        let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Partial live answer.")
    }

    @MainActor
    func testTransportReconnectUsesReplayWhenInactiveStreamHasJournal() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Partial live answer."), lastEventID: "session-abc:4")
        streamClient.emit(.transportError("lost connection"), lastEventID: "session-abc:4")

        try await waitUntil {
            streamClient.startedURLs.count == 2
        }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let replayQueryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "stream_id" })?.value, "stream-123")
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    func testReopenedInactiveStreamReplayUsesRestoredSnapshotEventID() {
        runMainActorTest {
            ChatViewModel.resetActiveStreamSnapshotsForTesting()
            defer { ChatViewModel.resetActiveStreamSnapshotsForTesting() }
            let originalStreamClient = SpySSEStreamingClient()
            let originalViewModel = try self.makeViewModel(streamClient: originalStreamClient) { request in
                XCTAssertEqual(request.url?.path, "/api/chat/start")
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            }

            let didStart = await originalViewModel.sendMessage("Keep working")
            XCTAssertTrue(didStart)
            originalStreamClient.emit(.token("Partial live answer."), lastEventID: "session-abc:9")
            originalViewModel.suspendStreamForNavigation()

            let reopenedStreamClient = SpySSEStreamingClient()
            let reopenedViewModel = try self.makeViewModel(streamClient: reopenedStreamClient) { request in
                switch request.url?.path {
                case "/api/session":
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "title": "Planning",
                        "active_stream_id": "stream-123",
                        "messages": [
                          {
                            "role": "user",
                            "content": "Keep working",
                            "timestamp": 1770000100,
                            "message_id": "user-1"
                          }
                        ]
                      }
                    }
                    """, for: request)
                case "/api/chat/stream/status":
                    return apiTestJSONResponse("""
                    {
                      "active": false,
                      "stream_id": "stream-123",
                      "replay_available": true
                    }
                    """, for: request)
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }

            await reopenedViewModel.loadMessages()
            await reopenedViewModel.reconnectStreamIfNeeded()

            let replayURL = try XCTUnwrap(reopenedStreamClient.startedURLs.last)
            let replayQueryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(replayQueryItems.first(where: { $0.name == "stream_id" })?.value, "stream-123")
            XCTAssertEqual(replayQueryItems.first(where: { $0.name == "replay" })?.value, "1")
            XCTAssertEqual(replayQueryItems.first(where: { $0.name == "after_seq" })?.value, "9")
            XCTAssertEqual(reopenedViewModel.messages.compactMap(\.content), ["Keep working", "Partial live answer."])
        }
    }

    @MainActor
    func testStreamTicksAndKeystrokesReuseTheStoredReasoningGroups() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Reasoning",
                    "messages": [
                      {"role": "user", "content": "First question", "message_id": "user-1"},
                      {
                        "role": "assistant",
                        "content": "First answer.",
                        "reasoning": "Work through the first question.",
                        "message_id": "assistant-1"
                      },
                      {"role": "user", "content": "Second question", "message_id": "user-2"},
                      {
                        "role": "assistant",
                        "content": "Second answer.",
                        "reasoning": "Work through the second question.",
                        "message_id": "assistant-2"
                      }
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let groups = viewModel.displayedReasoningGroups
        XCTAssertEqual(groups.map(\.text), ["Work through the first question.", "Work through the second question."])
        XCTAssertEqual(viewModel.reasoningGroupsByAnchorID["assistant-2"]?.map(\.text), ["Work through the second question."])

        // A keystroke-only ChatView pass reads the groups again; it must get the stored buffer back.
        XCTAssertTrue(sharesStorage(groups, viewModel.displayedReasoningGroups))

        let didStart = await viewModel.sendMessage("Third question")
        XCTAssertTrue(didStart)
        let probe = ObservationChangeProbe()
        withObservationTracking {
            _ = viewModel.displayedReasoningGroups
            _ = viewModel.reasoningGroupsByAnchorID
        } onChange: {
            probe.increment()
        }

        streamClient.emit(.token("Streaming the third answer"))

        XCTAssertEqual(viewModel.messages.last?.content, "Streaming the third answer")
        XCTAssertEqual(probe.value, 0, "a stream tick that leaves the cards unchanged must not invalidate them")
        XCTAssertTrue(sharesStorage(groups, viewModel.displayedReasoningGroups))
    }

    private func sharesStorage(_ lhs: [ReasoningGroup], _ rhs: [ReasoningGroup]) -> Bool {
        lhs.withUnsafeBufferPointer { lhsBuffer in
            rhs.withUnsafeBufferPointer { $0.baseAddress == lhsBuffer.baseAddress }
        }
    }

    @MainActor
    func testColdReopenActiveStreamReplaysFromStartWithoutDuplicatingLoadedState() async throws {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Recovery",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Inspect the report",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Partial answer.",
                        "reasoning": "Plan the inspection.",
                        "attachments": [
                          {"name": "report.txt", "path": "/tmp/report.txt"}
                        ],
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ],
                    "tool_calls": [
                      {
                        "name": "read_file",
                        "snippet": "Read report.txt",
                        "tid": "tool-1",
                        "assistant_msg_idx": 1,
                        "args": {"path": "/tmp/report.txt"}
                      }
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        await viewModel.reconnectStreamIfNeeded()

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let replayQueryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "stream_id" })?.value, "stream-123")
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "after_seq" })?.value, "0")

        let replayedToolStart = ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading report.txt",
            args: ["path": .string("/tmp/report.txt")],
            duration: nil,
            isError: nil,
            stableID: "tool-1"
        )
        let replayedToolCompletion = ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read report.txt",
            args: ["path": .string("/tmp/report.txt")],
            duration: 0.2,
            isError: false,
            stableID: "tool-1"
        )
        let approval = ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "open report.txt",
                description: "Open the report"
            ),
            pendingCount: 1
        )
        let clarification = ClarificationPendingResponse(
            pending: PendingClarification(
                clarifyId: "clarify-1",
                question: "Inspect every section?",
                sessionId: "session-abc"
            ),
            pendingCount: 1
        )

        streamClient.emit(.reasoning("Plan the inspection."), lastEventID: "stream-123:1")
        streamClient.emit(.toolStarted(replayedToolStart), lastEventID: "stream-123:2")
        streamClient.emit(.toolCompleted(replayedToolCompletion), lastEventID: "stream-123:3")
        streamClient.emit(.approvalPending(approval), lastEventID: "stream-123:4")
        streamClient.emit(.clarificationPending(clarification), lastEventID: "stream-123:5")
        streamClient.emit(.token("Partial "), lastEventID: "stream-123:6")
        streamClient.emit(.token("answer."), lastEventID: "stream-123:7")
        streamClient.emit(.token(" Continued."), lastEventID: "stream-123:8")

        XCTAssertEqual(viewModel.messages.last?.content, "Partial answer. Continued.")
        XCTAssertEqual(viewModel.messages.last?.attachments?.count, 1)
        XCTAssertEqual(viewModel.displayedReasoningGroups.map(\.text), ["Plan the inspection."])
        XCTAssertEqual(viewModel.latestTurnToolCalls.map(\.id), ["tool-1"])
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "clarify-1")

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "title": "Recovery complete",
          "messages": [
            {
              "role": "user",
              "content": "Inspect the report",
              "timestamp": 1770000100,
              "message_id": "user-1"
            },
            {
              "role": "assistant",
              "content": "Partial answer. Continued and complete.",
              "reasoning": "Plan the inspection.",
              "attachments": [
                {"name": "report.txt", "path": "/tmp/report.txt"}
              ],
              "timestamp": 1770000101,
              "message_id": "assistant-1"
            }
          ],
          "tool_calls": [
            {
              "name": "read_file",
              "snippet": "Read report.txt",
              "tid": "tool-1",
              "assistant_msg_idx": 1,
              "args": {"path": "/tmp/report.txt"}
            }
          ]
        }
        """)
        streamClient.emit(.done(DoneStreamEvent(session: completedSession)), lastEventID: "stream-123:9")
        streamClient.emit(.streamEnd, lastEventID: "stream-123:10")

        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Inspect the report",
            "Partial answer. Continued and complete."
        ])
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(viewModel.latestTurnToolCalls.map(\.id), ["tool-1"])
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testColdReopenActiveStreamFallsBackToOrdinaryReconnectWithoutJournal() async throws {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {"role": "user", "content": "Keep working", "message_id": "user-1"},
                      {"role": "assistant", "content": "Server prefix. ", "message_id": "assistant-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": false
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        await viewModel.reconnectStreamIfNeeded()

        let reconnectURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: reconnectURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(queryItems.first(where: { $0.name == "replay" }))
        XCTAssertNil(queryItems.first(where: { $0.name == "after_seq" }))

        streamClient.emit(.token("new tail."))
        XCTAssertEqual(viewModel.messages.last?.content, "Server prefix. new tail.")
    }

    @MainActor
    func testActiveStreamStatusRefreshReloadsTranscriptWhenSSECompletionIsMissed() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Final answer loaded without leaving the chat.",
                        "timestamp": 1770000110,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working"])

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Final answer loaded without leaving the chat."
        ])
    }

    @MainActor
    func testActiveStreamStatusRefreshWaitsForFinalTranscriptBeforeStoppingStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionReloadCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                sessionReloadCount += 1
                if sessionReloadCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "title": "Planning",
                        "messages": [
                          {
                            "role": "user",
                            "content": "Keep working",
                            "timestamp": 1770000100,
                            "message_id": "user-1"
                          }
                        ]
                      }
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Final answer arrived after the stream was marked inactive.",
                        "timestamp": 1770000110,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial live answer."))

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertEqual(sessionReloadCount, 1)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Partial live answer."
        ])

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertEqual(sessionReloadCount, 2)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Final answer arrived after the stream was marked inactive."
        ])
    }

    func testActiveStreamStatusRefreshTreatsToolOnlyAssistantAsCompletedResponse() {
        runMainActorTest {
            let streamClient = SpySSEStreamingClient()
            let viewModel = try self.makeViewModel(streamClient: streamClient) { request in
                switch request.url?.path {
                case "/api/chat/start":
                    return apiTestJSONResponse("""
                    {
                      "session_id": "session-abc",
                      "stream_id": "stream-123"
                    }
                    """, for: request)
                case "/api/chat/stream/status":
                    return apiTestJSONResponse("""
                    {
                      "active": false,
                      "stream_id": "stream-123"
                    }
                    """, for: request)
                case "/api/session":
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "title": "Planning",
                        "messages": [
                          {
                            "role": "user",
                            "content": "Run terminal",
                            "timestamp": 1770000100,
                            "message_id": "user-1"
                          },
                          {
                            "role": "assistant",
                            "content": "",
                            "timestamp": 1770000110,
                            "message_id": "assistant-tool",
                            "tool_calls": [
                              {
                                "id": "functions.terminal:1",
                                "function": {
                                  "name": "terminal",
                                  "arguments": "{\\"command\\":\\"pwd\\"}"
                                }
                              }
                            ]
                          },
                          {
                            "role": "tool",
                            "content": "/Users/hermes",
                            "timestamp": 1770000111,
                            "message_id": "tool-1",
                            "tool_call_id": "functions.terminal:1"
                          }
                        ]
                      }
                    }
                    """, for: request)
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }

            let didStart = await viewModel.sendMessage("Run terminal")
            XCTAssertTrue(didStart)

            await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

            XCTAssertNil(viewModel.activeStreamID)
            XCTAssertEqual(streamClient.stopCount, 1)
            XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant", "tool"])
            XCTAssertEqual(viewModel.messages.first(where: { $0.role == "assistant" })?.toolCalls?.count, 1)
        }
    }

    @MainActor
    func testAlreadyStreamedInterimAssistantDoesNotDuplicateTokenText() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Explain this")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Inspecting repo structure."))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "Inspecting repo structure.",
            alreadyStreamed: true
        )))

        XCTAssertEqual(viewModel.messages.last?.content, "Inspecting repo structure.")
    }

    @MainActor
    func testDoneSessionReconcilesTranscriptAfterApprovalResume() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Do it one more time")
        XCTAssertTrue(didStart)

        streamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "curl https://example.test/install.sh | bash",
                description: "Approval required",
                patternKey: "network_download"
            ),
            pendingCount: 1
        )))
        streamClient.emit(.token("Same"))
        streamClient.emit(.approvalPending(ApprovalPendingResponse(pending: nil, pendingCount: 0)))

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "title": "Approval test",
          "messages": [
            {
              "role": "user",
              "content": "Do it one more time",
              "message_id": "user-1"
            },
            {
              "role": "assistant",
              "content": "Same result -- approval gate triggered, then the usual JSON-is-not-bash errors.",
              "message_id": "assistant-1"
            }
          ]
        }
        """)
        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.displayTitle, "Approval test")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Do it one more time",
            "Same result -- approval gate triggered, then the usual JSON-is-not-bash errors."
        ])
        XCTAssertEqual(viewModel.messages.last?.messageId, "assistant-1")
    }

    func testCompletedStreamSessionDoesNotRequireFollowUpTranscriptRefresh() {
        runMainActorTest {
            let streamClient = SpySSEStreamingClient()
            let viewModel = try self.makeViewModel(streamClient: streamClient) { request in
                XCTAssertEqual(request.url?.path, "/api/chat/start")
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            }

            let didStart = await viewModel.sendMessage("Summarize")
            XCTAssertTrue(didStart)

            let completedSession = try self.makeSessionDetail("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "messages": [
                {
                  "role": "user",
                  "content": "Summarize",
                  "message_id": "user-1"
                },
                {
                  "role": "assistant",
                  "content": "Done.",
                  "message_id": "assistant-1"
                }
              ]
            }
            """)

            streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

            XCTAssertNil(viewModel.activeStreamID)
            XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
            XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
            XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Summarize", "Done."])
        }
    }

    func testDoneWithoutCompletedSessionRequiresFollowUpTranscriptRefresh() {
        runMainActorTest {
            let streamClient = SpySSEStreamingClient()
            let viewModel = try self.makeViewModel(streamClient: streamClient) { request in
                XCTAssertEqual(request.url?.path, "/api/chat/start")
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            }

            let didStart = await viewModel.sendMessage("Summarize")
            XCTAssertTrue(didStart)

            streamClient.emit(.token("Done."))
            streamClient.emit(.done(DoneStreamEvent(session: nil)))

            XCTAssertNil(viewModel.activeStreamID)
            XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
            XCTAssertTrue(viewModel.responseCompletionNeedsTranscriptRefresh)
            XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Summarize", "Done."])
        }
    }

    @MainActor
    func testCompletedStreamSessionKeepsActivityFromMessageToolCalls() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Check the workspace")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "terminal",
            preview: "pwd",
            args: ["command": .string("pwd")],
            duration: nil,
            isError: nil
        )))

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {
              "role": "user",
              "content": "Check the workspace",
              "message_id": "user-1"
            },
            {
              "role": "assistant",
              "content": "",
              "message_id": "assistant-tool",
              "tool_calls": [
                {
                  "id": "call-1",
                  "function": {
                    "name": "terminal",
                    "arguments": "{\\"command\\":\\"pwd\\"}"
                  }
                }
              ]
            },
            {
              "role": "tool",
              "content": "/Users/uzair/project",
              "message_id": "tool-1",
              "tool_call_id": "call-1"
            },
            {
              "role": "assistant",
              "content": "The workspace is /Users/uzair/project.",
              "message_id": "assistant-final"
            }
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertEqual(viewModel.completedToolCallGroups.count, 1)
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.anchorMessageID, "assistant-tool")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.activityTitle, "Activity: 1 tool")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.name, "terminal")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.preview, "/Users/uzair/project")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.args?["command"], .string("pwd"))
        XCTAssertEqual(
            viewModel.completedToolCallGroupsForAnchor("assistant-tool"),
            viewModel.completedToolCallGroups
        )
        XCTAssertTrue(viewModel.completedToolCallGroupsForAnchor(nil).isEmpty)
    }

    @MainActor
    func testCompletedStreamSessionMergesLiveFallbackIntoCompletedTurnActivity() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Check option 2")
        XCTAssertTrue(didStart)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "skill_view",
            preview: "xurl",
            args: ["name": .string("xurl")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "skill_view",
            preview: "X/Twitter via xurl CLI",
            args: ["name": .string("xurl")],
            duration: 0.2,
            isError: false
        )))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "terminal",
            preview: "which xurl",
            args: ["command": .string("which xurl")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "terminal",
            preview: "xurl not installed",
            args: ["command": .string("which xurl")],
            duration: 0.4,
            isError: false
        )))

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {
              "role": "user",
              "content": "Check option 2",
              "message_id": "user-option"
            },
            {
              "role": "assistant",
              "message_id": "assistant-skills",
              "content": [
                {
                  "type": "tool_use",
                  "id": "toolu-skill-xurl",
                  "name": "skill_view",
                  "input": { "name": "xurl" }
                }
              ]
            },
            {
              "role": "assistant",
              "content": "xurl is not installed.",
              "message_id": "assistant-final"
            }
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertEqual(viewModel.completedToolCallGroups.count, 1)
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.anchorMessageID, "assistant-skills")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.map(\.name), ["skill_view", "terminal"])
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.id, "toolu-skill-xurl")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.preview, "X/Twitter via xurl CLI")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.last?.preview, "xurl not installed")
        XCTAssertEqual(
            viewModel.completedToolCallGroupsForAnchor("assistant-skills"),
            viewModel.completedToolCallGroups
        )
    }

    @MainActor
    func testCompletedStreamSessionDeduplicatesLiveFallbackToolsWithCompletedTranscriptTools() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("I am testing tool use. Use terminal and search files.")
        XCTAssertTrue(didStart)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "terminal",
            preview: "pwd",
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "terminal",
            preview: "/tmp/workspace",
            args: nil,
            duration: 0.2,
            isError: false
        )))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "search_files",
            preview: "README",
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "search_files",
            preview: "README.md",
            args: nil,
            duration: 0.4,
            isError: false
        )))

        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["terminal", "search_files"])

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {
              "role": "user",
              "content": "I am testing tool use. Use terminal and search files.",
              "message_id": "user-tools"
            },
            {
              "role": "assistant",
              "content": "",
              "message_id": "assistant-tools",
              "tool_calls": [
                {
                  "id": "call-terminal",
                  "function": {
                    "name": "terminal",
                    "arguments": "{\\"command\\":\\"pwd\\"}"
                  }
                },
                {
                  "id": "call-search",
                  "function": {
                    "name": "search_files",
                    "arguments": "{\\"pattern\\":\\"README\\"}"
                  }
                }
              ]
            },
            {
              "role": "tool",
              "content": "/tmp/workspace",
              "message_id": "tool-terminal",
              "tool_call_id": "call-terminal"
            },
            {
              "role": "tool",
              "content": "README.md",
              "message_id": "tool-search",
              "tool_call_id": "call-search"
            },
            {
              "role": "assistant",
              "content": "Done.",
              "message_id": "assistant-final"
            }
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertEqual(viewModel.completedToolCallGroups.count, 1)
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.anchorMessageID, "assistant-tools")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.map(\.name), ["terminal", "search_files"])
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.map(\.id), ["call-terminal", "call-search"])
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.preview, "/tmp/workspace")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.args?["command"], .string("pwd"))
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.last?.preview, "README.md")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.last?.args?["pattern"], .string("README"))
    }

    @MainActor
    func testReloadPreservesCachedOptimisticUserMessageWhenServerTemporarilyOmitsIt() async throws {
        let context = try makeContext()
        let streamClient = SpySSEStreamingClient()
        let sendingViewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await sendingViewModel.sendMessage("Keep working", modelContext: context)

        XCTAssertTrue(didStart)
        XCTAssertEqual(sendingViewModel.messages.compactMap(\.content), ["Keep working"])
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Keep working"]
        )

        let reopenedViewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Planning",
                "messages": [
                  {
                    "role": "assistant",
                    "content": "Recovered transcript.",
                    "timestamp": 1770000100,
                    "message_id": "assistant-1"
                  }
                ]
              }
            }
            """, for: request)
        }

        await reopenedViewModel.loadMessages(modelContext: context)

        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.content), ["Keep working", "Recovered transcript."])
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Keep working", "Recovered transcript."]
        )
    }

    @MainActor
    func testLoadMessagesUsesCachedTranscriptForTunnelUnavailableFailure() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        let streamClient = SpySSEStreamingClient()
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Wrong session", timestamp: 1_770_000_003, messageId: "wrong-session")
            ],
            serverURL: serverURL,
            sessionID: "other-session",
            in: context
        )
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Wrong server", timestamp: 1_770_000_004, messageId: "wrong-server")
            ],
            serverURL: otherServerURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 502,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )
                return (try XCTUnwrap(response), Data("bad gateway".utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("In-flight request")
        streamClient.emit(.token("Partial response"))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)

        await viewModel.loadMessages(modelContext: context)
        let didSend = await viewModel.sendMessage("New message", modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertNil(viewModel.streamingAssistantMessageID)
        XCTAssertNil(viewModel.contextWindowSnapshot)
        XCTAssertTrue(viewModel.completedToolCallGroups.isEmpty)
        XCTAssertTrue(viewModel.completedToolCallGroupsForAnchor("cached-assistant").isEmpty)
        XCTAssertTrue(viewModel.completedToolCallGroupsForAnchor(nil).isEmpty)
        XCTAssertTrue(viewModel.completedReasoningGroups.isEmpty)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertTrue(viewModel.liveReasoningText.isEmpty)
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.sendErrorMessage, "Reconnect to the server to send a message.")
    }

    @MainActor
    func testLoadMessagesUsesCachedTranscriptForNetworkTimeout() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            throw URLError(.timedOut)
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesSurfacesTunnelUnavailableFailureWhenCacheIsEmpty() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
            return (try XCTUnwrap(response), Data("bad gateway".utf8))
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Could not connect to the server. Check that hermes-webui is running and the tunnel is connected."
        )
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesDoesNotUseCachedTranscriptForRealServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached answer", timestamp: 1_770_000_001, messageId: "stale")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.errorMessage, "The Hermes server hit an internal error. Check the server logs, then try again.")
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesDoesNotReplaceSuccessfulOnlineTranscriptWithStaleCache() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached answer", timestamp: 1_770_000_001, messageId: "stale")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  },
                  {
                    "role": "assistant",
                    "content": "Fresh answer",
                    "timestamp": 1770000101,
                    "message_id": "fresh-assistant"
                  }
                ]
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question", "Fresh answer"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: serverURL,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Fresh question", "Fresh answer"]
        )
    }

    @MainActor
    func testLoadMessagesRendersCachedMessagesBeforeNetworkReconcile() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  },
                  {
                    "role": "assistant",
                    "content": "Fresh answer",
                    "timestamp": 1770000101,
                    "message_id": "fresh-assistant"
                  }
                ]
              }
            }
            """, for: request)
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        // While the network reload is still in flight, the cached transcript is
        // already on screen (no skeleton, since messages is non-empty) and the
        // offline indicator stays off because this is the success-expected window.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)

        releaseSessionResponse.signal()
        await loadTask.value

        // After the reload completes it reconciles in place to the fresh server content.
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question", "Fresh answer"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPrepareInitialMessageLoadSendsTranscriptRequestThatOnlyTheInitialLoadApplies() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let sessionRequests = LockedCounter()
        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            _ = sessionRequests.increment()
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Fresh answer"), for: request)
        }
        defer { releaseSessionResponse.signal() }

        viewModel.prepareInitialMessageLoad(modelContext: context)

        // The request goes out during the push transition while the cache paints.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)

        // A second first-pass preparation keeps the request already in flight.
        viewModel.prepareInitialMessageLoad(modelContext: context)
        releaseSessionResponse.signal()
        await viewModel.loadMessages(modelContext: context, usesInitialPrefetch: true)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh answer"])
        XCTAssertEqual(sessionRequests.count, 1)
    }

    @MainActor
    func testLoadMessagesWithoutInitialPrefetchDiscardsItAndRefetches() async throws {
        let context = try makeContext()
        let sessionRequests = LockedCounter()
        let prefetchStarted = expectation(description: "prefetch started")
        let releasePrefetch = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            if sessionRequests.increment() == 1 {
                prefetchStarted.fulfill()
                _ = releasePrefetch.wait(timeout: .now() + .seconds(5))
                return apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Stale answer"), for: request)
            }
            return apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Fresh answer"), for: request)
        }
        defer { releasePrefetch.signal() }

        viewModel.prepareInitialMessageLoad(modelContext: context)
        await fulfillment(of: [prefetchStarted], timeout: 2)

        // Any other load (refresh, reconnect, after a mutation) must not apply a
        // response requested before it.
        await viewModel.loadMessages(modelContext: context)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh answer"])

        // Nor may the initial load, which runs later, reuse the discarded prefetch.
        await viewModel.loadMessages(modelContext: context, usesInitialPrefetch: true)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh answer"])
        XCTAssertEqual(sessionRequests.count, 3)
    }

    @MainActor
    func testCleanupPollingTasksDiscardsTheInitialPrefetch() async throws {
        let context = try makeContext()
        let sessionRequests = LockedCounter()
        let prefetchStarted = expectation(description: "prefetch started")
        let releasePrefetch = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            if sessionRequests.increment() == 1 {
                prefetchStarted.fulfill()
                _ = releasePrefetch.wait(timeout: .now() + .seconds(5))
                return apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Stale answer"), for: request)
            }
            return apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Fresh answer"), for: request)
        }
        defer { releasePrefetch.signal() }

        viewModel.prepareInitialMessageLoad(modelContext: context)
        await fulfillment(of: [prefetchStarted], timeout: 2)

        // Leaving the chat (ChatView.onDisappear) drops the in-flight prefetch, so
        // a later initial load on the same view model asks the server again.
        viewModel.cleanupPollingTasks()
        releasePrefetch.signal()
        await viewModel.loadMessages(modelContext: context, usesInitialPrefetch: true)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh answer"])
        XCTAssertEqual(sessionRequests.count, 2)
    }

    @MainActor
    func testInitialLoadRefetchesWhenAStreamStartedAfterThePrefetch() async throws {
        let context = try makeContext()
        let streamClient = SpySSEStreamingClient()
        let sessionRequests = LockedCounter()
        let prefetchStarted = expectation(description: "prefetch started")
        let releasePrefetch = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/session":
                if sessionRequests.increment() == 1 {
                    prefetchStarted.fulfill()
                    _ = releasePrefetch.wait(timeout: .now() + .seconds(5))
                    return apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Before send"), for: request)
                }
                return apiTestJSONResponse(
                    Self.initialLoadSessionJSON(content: "After send", activeStreamID: "stream-123"),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        defer { releasePrefetch.signal() }

        viewModel.prepareInitialMessageLoad(modelContext: context)
        await fulfillment(of: [prefetchStarted], timeout: 2)
        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        releasePrefetch.signal()

        // The prefetch predates the stream, so it would read as the stream having
        // ended; the initial load asks again instead.
        await viewModel.loadMessages(modelContext: context, usesInitialPrefetch: true)

        XCTAssertEqual(sessionRequests.count, 2)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertTrue(viewModel.messages.contains { $0.content == "After send" })
    }

    @MainActor
    func testPrepareInitialMessageLoadBoundsLargeCachedTranscriptToNewestPage() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let cachedMessages = (0..<75).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Cached message \(index)",
                timestamp: Double(1_770_000_000 + index),
                messageId: "cached-\(index)"
            )
        }
        try CacheStore.cacheMessages(
            cachedMessages,
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            apiTestJSONResponse(Self.initialLoadSessionJSON(content: "Fresh answer"), for: request)
        }

        viewModel.prepareInitialMessageLoad(modelContext: context)

        XCTAssertEqual(viewModel.messages.count, 50)
        XCTAssertEqual(viewModel.messages.first?.content, "Cached message 25")
        XCTAssertEqual(viewModel.messages.last?.content, "Cached message 74")
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)

        // Settle the transcript request prepare sent so it cannot outlive this test.
        await viewModel.loadMessages(modelContext: context, usesInitialPrefetch: true)
    }

    private static func initialLoadSessionJSON(content: String, activeStreamID: String? = nil) -> String {
        let activeStream = activeStreamID.map { #", "active_stream_id": "\#($0)""# } ?? ""
        return """
        {
          "session": {
            "session_id": "session-abc",
            "title": "Planning"\(activeStream),
            "messages": [
              {"role": "assistant", "content": "\(content)", "timestamp": 1770000100, "message_id": "fresh-assistant"}
            ]
          }
        }
        """
    }

    @MainActor
    func testLoadMessagesKeepsTranscriptEmptyDuringNetworkWhenCacheIsEmpty() async throws {
        let context = try makeContext()

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  }
                ]
              }
            }
            """, for: request)
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        // With no cache, nothing is painted before the network resolves, so the
        // first-open skeleton path (isLoading && messages.isEmpty) is preserved.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.isLoading)

        releaseSessionResponse.signal()
        await loadTask.value

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question"])
    }

    @MainActor
    func testCacheFirstReconcileBumpsScrollTokenForSmoothSettle() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  },
                  {
                    "role": "assistant",
                    "content": "Fresh answer",
                    "timestamp": 1770000101,
                    "message_id": "fresh-assistant"
                  }
                ]
              }
            }
            """, for: request)
        }

        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 0)
        await viewModel.loadMessages(modelContext: context)

        // The cache-first reconcile fired exactly once so the view can snap back to the
        // bottom as the taller server transcript replaces the lighter cached render.
        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 1)
    }

    @MainActor
    func testColdOpenWithoutCacheDoesNotBumpReconcileScrollToken() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  }
                ]
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages(modelContext: context)

        // No cache was rendered first, so there is nothing to re-pin and the token stays put.
        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 0)
    }

    @MainActor
    func testCacheFirstRevertPreservesOptimisticSendOnNonCacheableError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                sessionRequestStarted.fulfill()
                XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        // The reload renders the cache then suspends on /api/session. Kick off a send
        // *without* awaiting it (its optimistic user message is appended synchronously
        // before the network call) so the transcript is mutated while the reload is
        // still in flight.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        let sendTask = Task { @MainActor in
            await viewModel.sendMessage("In-flight question", modelContext: context)
        }
        try await waitUntil { viewModel.messages.compactMap(\.content).contains("In-flight question") }
        XCTAssertTrue(viewModel.messages.compactMap(\.content).contains("In-flight question"))

        // Now let the reload fail with a non-cacheable error: the cache-first revert
        // must NOT wipe the optimistic send made during the load window (#289, Codex P2).
        releaseSessionResponse.signal()
        await loadTask.value
        _ = await sendTask.value

        XCTAssertTrue(
            viewModel.messages.compactMap(\.content).contains("In-flight question"),
            "Optimistic send made during the cache-first window must survive a non-cacheable reload failure"
        )
    }

    @MainActor
    func testNilContextReconnectPreservesInMemoryOptimisticUserMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-preserve-text"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-preserve-text"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-preserve-text",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Earlier question",
                        "message_id": "earlier-user"
                      },
                      {
                        "role": "assistant",
                        "content": "Earlier answer",
                        "message_id": "earlier-assistant"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "queue")),
            args: "Keep working"
        )
        XCTAssertEqual(result, .executed(message: nil))
        let optimisticID = try XCTUnwrap(viewModel.messages.last?.messageId)
        XCTAssertTrue(optimisticID.hasPrefix("local-"))

        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            ["Earlier question", "Earlier answer", "Keep working"]
        )
        XCTAssertEqual(viewModel.messages.last?.messageId, optimisticID)
    }

    @MainActor
    func testLateContextJoinPreservesNilContextReconnectMessageAndCachesIt() async throws {
        let context = try makeContext()
        let sessionRequestStarted = expectation(description: "nil-context session reload started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let sessionLoadCount = LockedCounter()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-late-context"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-late-context"}"#,
                    for: request
                )
            case "/api/session":
                if sessionLoadCount.increment() == 1 {
                    sessionRequestStarted.fulfill()
                    XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
                }
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-late-context",
                    "messages": [
                      {
                        "role": "assistant",
                        "content": "Earlier answer",
                        "message_id": "earlier-assistant"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "queue")),
            args: "Keep working"
        )
        XCTAssertEqual(result, .executed(message: nil))
        let optimisticID = try XCTUnwrap(viewModel.messages.last?.messageId)

        viewModel.suspendStreamForBackground()
        let nilContextReconnect = Task { @MainActor in
            await viewModel.reconnectStreamIfNeeded()
        }
        defer { releaseSessionResponse.signal() }
        await fulfillment(of: [sessionRequestStarted], timeout: 2)

        let contextReconnect = Task { @MainActor in
            await viewModel.reconnectStreamIfNeeded(modelContext: context)
        }
        await drainMainActor()
        releaseSessionResponse.signal()
        await nilContextReconnect.value
        await contextReconnect.value

        XCTAssertEqual(sessionLoadCount.count, 2)
        XCTAssertEqual(viewModel.messages.filter { $0.messageId == optimisticID }.count, 1)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc",
                in: context
            ).filter { $0.messageId == optimisticID }.count,
            1
        )
    }

    @MainActor
    func testNilContextReconnectDoesNotDuplicateServerEquivalentOptimisticMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-dedupe-text"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-dedupe-text"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-dedupe-text",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "message_id": "server-user"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(viewModel.messages.first?.messageId, "server-user")
    }

    @MainActor
    func testNilContextReconnectDoesNotMistakeOlderRepeatedPromptForConfirmation() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionLoadCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-repeated-prompt"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-repeated-prompt"}"#,
                    for: request
                )
            case "/api/session":
                sessionLoadCount += 1
                let activeStreamField = sessionLoadCount == 1
                    ? ""
                    : #","active_stream_id":"stream-repeated-prompt""#
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc"\(activeStreamField),
                    "messages": [
                      {
                        "role": "user",
                        "content": "Repeat",
                        "message_id": "older-user"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didStart = await viewModel.sendMessage("Repeat")
        XCTAssertTrue(didStart)

        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" }.count, 2)
        XCTAssertEqual(viewModel.messages.first?.messageId, "older-user")
        XCTAssertTrue(viewModel.messages.last?.messageId?.hasPrefix("local-") == true)
    }

    @MainActor
    func testInFlightReloadDoesNotCarryOptimisticMessageIntoSuccessorRun() async throws {
        let sessionRequestStarted = expectation(description: "old-run session reload started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-old"}"#,
                    for: request
                )
            case "/api/session":
                sessionRequestStarted.fulfill()
                XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-new",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Successor message",
                        "message_id": "successor-server-user"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let oldResult = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "queue")),
            args: "Old optimistic message"
        )
        XCTAssertEqual(oldResult, .executed(message: nil))
        let oldOptimisticID = try XCTUnwrap(viewModel.messages.last?.messageId)

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages()
        }
        defer { releaseSessionResponse.signal() }
        await fulfillment(of: [sessionRequestStarted], timeout: 2)

        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)

        releaseSessionResponse.signal()
        await loadTask.value

        XCTAssertEqual(viewModel.activeStreamID, "stream-new")
        XCTAssertFalse(viewModel.messages.contains { $0.messageId == oldOptimisticID })
        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" }.map(\.messageId), ["successor-server-user"])
    }

    @MainActor
    func testOrdinaryInactiveReloadDoesNotResurrectObsoleteOptimisticMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-finished"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Server transcript",
                        "message_id": "server-user"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "queue")),
            args: "Obsolete optimistic message"
        )
        XCTAssertEqual(result, .executed(message: nil))
        let obsoleteOptimisticID = try XCTUnwrap(viewModel.messages.last?.messageId)

        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)
        await viewModel.loadMessages()

        XCTAssertFalse(viewModel.messages.contains { $0.messageId == obsoleteOptimisticID })
        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" }.map(\.messageId), ["server-user"])
    }

    @MainActor
    func testNilContextReconnectPreservesInMemoryOptimisticAttachmentMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "photo.png",
                  "path": "/tmp/workspace/photo.png",
                  "size": 4,
                  "mime": "image/png",
                  "is_image": true
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-preserve-attachment"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-preserve-attachment"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-preserve-attachment",
                    "messages": [
                      {
                        "role": "assistant",
                        "content": "Earlier answer",
                        "message_id": "earlier-assistant"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(data: Data("test".utf8), filename: "photo.png")
        let didStart = await viewModel.sendMessage("Summarize it")
        XCTAssertTrue(didStart)

        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        let optimisticMessage = try XCTUnwrap(
            viewModel.messages.first(where: { $0.messageId?.hasPrefix("local-") == true })
        )
        XCTAssertEqual(optimisticMessage.content, "Summarize it")
        XCTAssertEqual(optimisticMessage.attachments?.map(\.path), ["/tmp/workspace/photo.png"])
    }

    @MainActor
    func testNilContextReconnectDeduplicatesServerEquivalentAttachmentMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "photo.png",
                  "path": "/tmp/workspace/photo.png",
                  "size": 4,
                  "mime": "image/png",
                  "is_image": true
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-dedupe-attachment"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-dedupe-attachment"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "active_stream_id": "stream-dedupe-attachment",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Summarize it\\n\\n[Attached files: /tmp/workspace/photo.png]",
                        "message_id": "server-attachment-user"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(data: Data("test".utf8), filename: "photo.png")
        let didStart = await viewModel.sendMessage("Summarize it")
        XCTAssertTrue(didStart)

        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(viewModel.messages.first?.messageId, "server-attachment-user")
        XCTAssertEqual(viewModel.messages.first?.attachments?.map(\.identityKey), ["photo.png"])
    }

    @MainActor
    func testReloadDoesNotDuplicateCachedOptimisticAttachmentMessageWhenServerReturnsIt() async throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Summarize it",
                    timestamp: 1_770_000_000,
                    messageId: "local-attachment",
                    attachments: [
                        MessageAttachment(
                            name: "photo.png",
                            path: "/tmp/workspace/photo.png",
                            mime: "image/png",
                            size: 4,
                            isImage: true
                        )
                    ]
                )
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let reopenedViewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {
                    "role": "user",
                    "content": "Summarize it\\n\\n[Attached files: /tmp/workspace/photo.png]",
                    "timestamp": 1770000001,
                    "message_id": "user-1"
                  },
                  {
                    "role": "assistant",
                    "content": "Recovered transcript.",
                    "timestamp": 1770000100,
                    "message_id": "assistant-1"
                  }
                ]
              }
            }
            """, for: request)
        }

        await reopenedViewModel.loadMessages(modelContext: context)

        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.first?.messageId, "user-1")
        XCTAssertEqual(reopenedViewModel.messages.filter { $0.role == "user" }.count, 1)
    }

    @MainActor
    func testSendMessageRollsBackOptimisticMessageWhenStartThrows() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "photo.png",
                  "path": "/tmp/workspace/photo.png",
                  "size": 4,
                  "mime": "image/png",
                  "is_image": true
                }
                """, for: request)
            case "/api/chat/start":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"server unavailable"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(
            data: Data([0x00, 0x01, 0x02, 0x03]),
            filename: "photo.png",
            previewData: Data([0x99])
        )

        let didStart = await viewModel.sendMessage("Summarize it")

        XCTAssertFalse(didStart)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.localAttachmentPreviews.isEmpty)
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.sendErrorMessage)
    }

    @MainActor
    func testTransportErrorChecksStatusAndReattachesWhenStreamIsActive() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)

        streamClient.emit(.transportError("The network connection was lost."))
        try await waitUntil {
            didRequestStatus && didReloadMessages && streamClient.startedURLs.count == 2
        }

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.startedURLs.last?.path, "/api/chat/stream")
    }

    @MainActor
    func testReconnectAfterBackgroundRefreshesTranscriptBeforeReattachingActiveStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "First middle ",
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()
        streamClient.emit(.token("last."))

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle last."])
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
    }

    @MainActor
    func testStaleActiveStreamShowsCheckingStateAndPollsStatus() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(requestPaths, ["/api/chat/start", "/api/chat/stream/status"])
    }

    @MainActor
    func testStaleActiveStreamKeepsLiveReasoningVisibleWhileChecking() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Think through the plan")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("I need to inspect the workspace first."))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace first.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
    }

    @MainActor
    func testStaleActiveStreamDoesNotShowRecoveryStateBeforeFirstVisibleProgress() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                XCTFail("Initial assistant wait should not poll stream status before visible progress.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(requestPaths, ["/api/chat/start"])
    }

    @MainActor
    func testStaleActiveStreamRefreshesCompletedTranscriptAndClearsActiveStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Recovered full answer.",
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial "))

        // 13s: past transportFreshInterval (12), so stale recovery polls status
        // and finalizes the inactive run (#227).
        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Recovered full answer."])
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(requestPaths, ["/api/chat/start", "/api/chat/stream/status", "/api/session"])
    }

    @MainActor
    func testStaleActiveStreamInactiveWithoutFinalAssistantStopsChecking() async throws {
        let streamClient = SpySSEStreamingClient()
        let liveActivityManager = SpyChatLiveActivityManager()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial "))

        // 13s: past transportFreshInterval (12), so stale recovery polls status
        // and finalizes the inactive run (#227).
        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(liveActivityManager.ends, [
            SpyChatLiveActivityManager.End(
                status: .failed,
                activity: "Response failed",
                errorSummary: nil
            )
        ])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Partial "])
    }

    @MainActor
    func testStaleActiveStreamReconnectsWithReplayAndSkipsDuplicateTokens() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "), lastEventID: "stream-123:1")

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "1")

        streamClient.emit(.token("First "), lastEventID: "stream-123:1")
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        streamClient.emit(.token("answer."), lastEventID: "stream-123:2")

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First answer."])
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
    }

    @MainActor
    func testStaleActiveStreamReconnectsWithReplayFromBeginningWhenLastEventIDIsMissing() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "0")

        streamClient.emit(.token("First "))
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        streamClient.emit(.token("answer."))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First answer."])
    }

    @MainActor
    func testStaleActiveStreamReconnectsWithoutReplayQueryWhenReplayUnavailable() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": false
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "), lastEventID: "stream-123:1")

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let reconnectURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: reconnectURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(queryItems.first(where: { $0.name == "replay" })?.value)
        XCTAssertNil(queryItems.first(where: { $0.name == "after_seq" })?.value)
    }

    @MainActor
    func testStaleActiveStreamStatusErrorOnlyReconnectsAfterForceThreshold() async throws {
        let streamClient = SpySSEStreamingClient()
        var statusRequestCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                statusRequestCount += 1
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(statusRequestCount, 1)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        XCTAssertEqual(statusRequestCount, 2)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "0")
    }

    @MainActor
    func testStaleActiveStreamStatusPollHonorsCooldown() async throws {
        let streamClient = SpySSEStreamingClient()
        var statusRequestCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                statusRequestCount += 1
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        let firstPollDate = Date().addingTimeInterval(12.5)
        await viewModel.recoverStaleActiveStreamIfNeeded(now: firstPollDate)
        await viewModel.recoverStaleActiveStreamIfNeeded(now: firstPollDate.addingTimeInterval(2))
        await viewModel.recoverStaleActiveStreamIfNeeded(now: firstPollDate.addingTimeInterval(5))

        XCTAssertEqual(statusRequestCount, 2)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
    }

    @MainActor
    func testStaleActiveStreamDoesNotForceReconnectPlainSlowStreamAtTenSeconds() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

        // #227: 10s of quiet is still inside transportFreshInterval, so the
        // slow-but-alive stream shows no recovery chip at all — and is
        // certainly not force-reconnected.
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesMultiTokenPrefix() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))
        streamClient.emit(.token("middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        streamClient.emit(.token("First "))
        streamClient.emit(.token("middle "))
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle "])

        streamClient.emit(.token("last."))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle last."])
    }

    @MainActor
    func testStaleActiveStreamReplayBatchedTokensMatchLiveModeFinalContent() async throws {
        let tokens = ["Alpha ", "beta ", "gamma ", "delta."]

        let liveStreamClient = SpySSEStreamingClient()
        let liveViewModel = try makeViewModel(streamClient: liveStreamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartLive = await liveViewModel.sendMessage("Keep working")
        XCTAssertTrue(didStartLive)
        for token in tokens {
            liveStreamClient.emit(.token(token))
        }
        let liveTranscript = liveViewModel.messages.compactMap(\.content)
        XCTAssertEqual(liveTranscript, ["Keep working", "Alpha beta gamma delta."])

        let replayStreamClient = SpySSEStreamingClient()
        let replayViewModel = try makeViewModel(streamClient: replayStreamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartReplay = await replayViewModel.sendMessage("Keep working")
        XCTAssertTrue(didStartReplay)
        replayStreamClient.emit(.token(tokens[0]))
        replayStreamClient.emit(.token(tokens[1]))

        await replayViewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        // The replay connection re-sends the full token sequence from the start.
        for token in tokens {
            replayStreamClient.emit(.token(token))
        }

        XCTAssertEqual(replayViewModel.messages.compactMap(\.content), liveTranscript)
    }

    @MainActor
    func testStaleActiveStreamReplayDedupSurvivesLoadOlderMessages() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                if query["msg_before"] == "2" {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "messages": [
                          {"role": "user", "content": "Old question", "timestamp": 1, "message_id": "u-0"},
                          {"role": "assistant", "content": "Old answer", "timestamp": 2, "message_id": "a-1"},
                          {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"}
                        ],
                        "_messages_truncated": false,
                        "_messages_offset": 0
                      }
                    }
                    """, for: request)
                }
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        XCTAssertTrue(viewModel.hasOlderMessages)

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))
        streamClient.emit(.token("middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        // Partial replay match keeps the replay connection armed mid-stride...
        streamClient.emit(.token("First "))

        // ...then the user paginates older messages, which drops pending buffers.
        let didLoadOlder = await viewModel.loadOlderMessages()
        XCTAssertTrue(didLoadOlder)

        // Replay continues: the duplicate must still dedup, the new token must append.
        streamClient.emit(.token("middle "))
        streamClient.emit(.token("last."))

        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Old question",
            "Old answer",
            "Recent question",
            "Keep working",
            "First middle last."
        ])
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesStridingOverlap() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.token("middle last."))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle last."])
    }

    @MainActor
    func testStaleActiveStreamReplayDuplicateOnlyConnectionCanRecoverAgain() async throws {
        let streamClient = SpySSEStreamingClient()
        var statusRequestCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                statusRequestCount += 1
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.token("First "))

        XCTAssertEqual(statusRequestCount, 1)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(statusRequestCount, 2)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testStaleActiveStreamReplayDedupFallbackDoesNotSuppressNextNewToken() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.token("middle "))
        streamClient.emit(.token("First "))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle First "])
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesInterimAssistant() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Draft answer.")))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Draft answer.")))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Draft answer."])
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesReasoningAndCompletedToolEvents() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let startedTool = ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: nil,
            isError: nil
        )
        let completedTool = ToolStreamEvent(
            eventType: "tool.completed",
            name: "run_command",
            preview: "Passed tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: 1.5,
            isError: false
        )

        let didStart = await viewModel.sendMessage("Inspect logs")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("Plan."))
        streamClient.emit(.toolStarted(startedTool))
        streamClient.emit(.toolCompleted(completedTool))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.reasoning("Plan."))
        streamClient.emit(.toolStarted(startedTool))
        streamClient.emit(.toolCompleted(completedTool))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.liveReasoningText, "Plan.")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.name, "run_command")
        XCTAssertEqual(viewModel.liveToolCalls.first?.preview, "Passed tests")
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, true)
    }

    @MainActor
    func testReplayCompletesSecondSameNameToolByStableID() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Run both checks")
        XCTAssertTrue(didStart)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running first check",
            args: ["cmd": .string("swift test")],
            duration: nil,
            isError: nil,
            stableID: "call-first"
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "run_command",
            preview: "First check passed",
            args: ["cmd": .string("swift test")],
            duration: 0.5,
            isError: false,
            stableID: "call-first"
        )))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running second check",
            args: ["cmd": .string("swift test")],
            duration: nil,
            isError: nil,
            stableID: "call-second"
        )))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "run_command",
            preview: "Second check passed",
            args: ["cmd": .string("swift test")],
            duration: 0.75,
            isError: false,
            stableID: "call-second"
        )))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.liveToolCalls.count, 2)
        XCTAssertEqual(viewModel.liveToolCalls.map(\.id), ["call-first", "call-second"])
        XCTAssertEqual(viewModel.liveToolCalls.map(\.preview), ["First check passed", "Second check passed"])
        XCTAssertEqual(viewModel.liveToolCalls.map(\.isCompleted), [true, true])
    }

    @MainActor
    func testStaleActiveStreamDoesNotForceReconnectDuringRunningToolAtNormalThreshold() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Inspect logs")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: nil,
            isError: nil
        )))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, false)
    }

    @MainActor
    func testStaleActiveStreamForceReconnectsRunningToolAfterToolThreshold() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Inspect logs")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: nil,
            isError: nil
        )))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(26))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testReopeningActiveStreamRestoresLiveSnapshotBeforeBufferedTailArrives() async throws {
        let originalStreamClient = SpySSEStreamingClient()
        let originalViewModel = try makeViewModel(streamClient: originalStreamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await originalViewModel.sendMessage("Tell me a tiger story")
        XCTAssertTrue(didStart)

        originalStreamClient.emit(.reasoning("Planning the tiger story."))
        originalStreamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading jungle notes",
            args: ["path": .string("notes.md")],
            duration: nil,
            isError: nil
        )))
        originalStreamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read jungle notes",
            args: ["path": .string("notes.md")],
            duration: 0.15,
            isError: false
        )))
        originalStreamClient.emit(
            .token("Once Raj reached the river. "),
            lastEventID: "stream-123:4"
        )

        originalViewModel.suspendStreamForNavigation()

        XCTAssertEqual(originalStreamClient.stopCount, 1)

        let reopenedStreamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var sessionReloadCount = 0
        let reopenedViewModel = try makeViewModel(streamClient: reopenedStreamClient) { request in
            switch request.url?.path {
            case "/api/session":
                sessionReloadCount += 1
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Tiger Story",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Tell me a tiger story",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await reopenedViewModel.loadMessages()
        await reopenedViewModel.reconnectStreamIfNeeded()

        XCTAssertTrue(didRequestStatus)
        XCTAssertEqual(sessionReloadCount, 2)
        XCTAssertEqual(reopenedStreamClient.startedURLs.count, 1)
        let reconnectURL = try XCTUnwrap(reopenedStreamClient.startedURLs.last)
        let reconnectQueryItems = URLComponents(url: reconnectURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(reconnectQueryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(reconnectQueryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(reopenedViewModel.activeStreamID, "stream-123")
        XCTAssertEqual(reopenedViewModel.liveReasoningText, "Planning the tiger story.")
        XCTAssertEqual(reopenedViewModel.liveToolCalls.count, 1)
        XCTAssertEqual(reopenedViewModel.liveToolCalls.first?.name, "read_file")
        XCTAssertEqual(reopenedViewModel.liveToolCalls.first?.isCompleted, true)
        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.last?.content, "Once Raj reached the river. ")

        reopenedStreamClient.emit(.token("The snare broke."))

        XCTAssertEqual(
            reopenedViewModel.messages.compactMap(\.content),
            ["Tell me a tiger story", "Once Raj reached the river. The snare broke."]
        )
        XCTAssertEqual(reopenedViewModel.messages.filter { $0.role == "assistant" }.count, 1)
    }

    @MainActor
    func testComposerConfigurationUsesSessionProfileDefaultBeforeSending() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        let streamClient = SpySSEStreamingClient()
        let requestPaths = LockedStrings()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: nil, modelProvider: nil, profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter"}
                  ]
                }
                """, for: request)
            case "/api/profile/switch":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "work")
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "default_model": "\(openRouterModel)",
                  "default_workspace": "/tmp/workspace",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterModel)",
                  "active_provider": "openrouter",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterModel)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["model"] as? String, openRouterModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                XCTAssertEqual(body["profile"] as? String, "work")
                XCTAssertNil(body["explicit_model_pick"])
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-profile"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertEqual(viewModel.selectedModelID, openRouterModel)
        XCTAssertEqual(viewModel.selectedProfileTitle, "work")

        let didStart = await viewModel.sendMessage("Use the profile default")

        XCTAssertTrue(didStart)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        let paths = requestPaths.values
        // Profile resolution stays serial; the four follow-ups share one wave.
        XCTAssertEqual(Array(paths.prefix(2)), ["/api/profiles", "/api/profile/switch"])
        XCTAssertEqual(
            Set(paths.dropFirst(2).dropLast()),
            Set(["/api/models", "/api/reasoning", "/api/workspaces", "/api/commands"])
        )
        XCTAssertEqual(paths.last, "/api/chat/start")
        XCTAssertEqual(paths.count, 7)
    }

    @MainActor
    func testSessionModelOverrideSurvivesProfileDefaultLoad() async throws {
        let openRouterDefault = "deepseek/deepseek-chat-v3-0324:free"
        let sessionModel = "@openai:gpt-5.5"
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: sessionModel, modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "\(openRouterDefault)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterDefault)",
                  "active_provider": "openrouter",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterDefault)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    },
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [
                        {"id": "\(sessionModel)", "name": "GPT 5.5"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["model"] as? String, sessionModel)
                XCTAssertEqual(body["model_provider"] as? String, "openai")
                XCTAssertEqual(body["profile"] as? String, "work")
                // The session's saved route differs from the owning profile's
                // default (both are loaded here), so this restored override is
                // a deliberate selection and must be sent as an explicit pick —
                // updated from the former nil expectation when session route
                // intent became persistent (#model-selection-audit).
                XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-override"}"#, for: request)
            case "/api/default-model":
                XCTFail("Session-scoped chat model overrides must not save profile defaults.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertEqual(viewModel.selectedModelID, sessionModel)

        let didStart = await viewModel.sendMessage("Keep the session override")

        XCTAssertTrue(didStart)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testComposerConfigurationReloadDoesNotOverwriteConcurrentWorkspaceSelection() async throws {
        let initialWorkspace = "/tmp/workspace"
        let selectedWorkspace = "/tmp/selected-workspace"
        let firstProfilesStarted = expectation(description: "first profiles request started")
        let releaseFirstProfiles = DispatchSemaphore(value: 0)
        let profileRequests = LockedCounter()
        var didReleaseFirstProfiles = false
        func releaseProfilesIfNeeded() {
            guard !didReleaseFirstProfiles else { return }
            didReleaseFirstProfiles = true
            releaseFirstProfiles.signal()
        }

        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                let requestCount = profileRequests.increment()
                if requestCount == 1 {
                    firstProfilesStarted.fulfill()
                    XCTAssertEqual(releaseFirstProfiles.wait(timeout: .now() + .seconds(5)), .success)
                }

                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "gpt-5.4", "provider": "openai", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["workspace"] as? String, selectedWorkspace)
                XCTAssertEqual(body["model"] as? String, "gpt-5.4")
                XCTAssertEqual(body["model_provider"] as? String, "openai")

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "\(selectedWorkspace)",
                    "model": "gpt-5.4",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "gpt-5.4",
                  "active_provider": "openai",
                  "groups": [
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [
                        {"id": "gpt-5.4", "name": "GPT 5.4"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse("""
                {
                  "workspaces": [
                    {"path": "\(initialWorkspace)"},
                    {"path": "\(selectedWorkspace)"}
                  ],
                  "last": "\(initialWorkspace)"
                }
                """, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadComposerConfiguration()
        }
        await fulfillment(of: [firstProfilesStarted], timeout: 1)
        defer { releaseProfilesIfNeeded() }

        let selectWorkspaceTask = Task { @MainActor in
            await viewModel.selectWorkspacePath(selectedWorkspace)
        }
        try await waitUntil { viewModel.selectedWorkspacePath == selectedWorkspace }
        releaseProfilesIfNeeded()

        let didSelectWorkspace = await selectWorkspaceTask.value
        await loadTask.value

        XCTAssertTrue(didSelectWorkspace)
        XCTAssertEqual(viewModel.selectedWorkspacePath, selectedWorkspace)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(profileRequests.count, 2)
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testDraftSettingsRestoreDoesNotOverwriteANewerComposerInteraction() async throws {
        var requestCount = 0
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestCount += 1
            XCTFail("A fenced restore must not call \(request.url?.path ?? "nil").")
            throw URLError(.badURL)
        }
        let expectedGeneration = viewModel.composerConfigurationInteractionGeneration
        viewModel.markComposerConfigurationInteraction()

        await viewModel.restoreDraftSettings(
            ChatDraftSettings(
                modelID: "claude-sonnet-4",
                modelProviderID: "anthropic",
                workspacePath: "/tmp/saved"
            ),
            expectedInteractionGeneration: expectedGeneration
        )

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/workspace")
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testDraftSettingsRestoreStopsWhenSavedProfileSwitchFails() async throws {
        let requestPaths = LockedStrings()
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            let path = request.url?.path ?? ""
            // Composer config now fans out concurrent GETs; lock the recorder.
            requestPaths.append(path)
            switch path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "gpt-5.4", "provider": "openai", "is_active": true},
                    {"name": "saved", "model": "claude-sonnet-4", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "groups": [
                    {
                      "name": "Anthropic",
                      "provider_id": "anthropic",
                      "models": [{"id": "claude-sonnet-4", "name": "Claude Sonnet 4"}]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort":"medium","supported_efforts":["medium","high"]}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[{"path":"/tmp/workspace"},{"path":"/tmp/saved"}]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            case "/api/profile/switch":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"profile unavailable"}"#.utf8))
            case "/api/session/update":
                XCTFail("Dependent model or workspace settings must not apply after profile failure.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        let expectedGeneration = viewModel.composerConfigurationInteractionGeneration
        await viewModel.restoreDraftSettings(
            ChatDraftSettings(
                modelID: "claude-sonnet-4",
                modelProviderID: "anthropic",
                reasoningEffort: "high",
                profileName: "saved",
                workspacePath: "/tmp/saved"
            ),
            expectedInteractionGeneration: expectedGeneration
        )

        let paths = requestPaths.values
        XCTAssertEqual(viewModel.selectedProfileName, "work")
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/workspace")
        XCTAssertEqual(paths.last, "/api/profile/switch")
        XCTAssertFalse(paths.contains("/api/session/update"))
    }

    @MainActor
    func testSelectingComposerModelUpdatesOnlyTheSessionAndCarriesProviderOnSend() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: nil, profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, openRouterModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(openRouterModel)",
                    "model_provider": "openrouter",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["model"] as? String, openRouterModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                XCTAssertEqual(body["profile"] as? String, "work")
                XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-selected"}"#, for: request)
            case "/api/default-model":
                XCTFail("Composer model selection must not save profile defaults.")
                throw URLError(.badURL)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: openRouterModel,
            displayName: "DeepSeek Chat v3 Free",
            providerID: "openrouter"
        ))
        XCTAssertEqual(viewModel.selectedModelID, openRouterModel)

        let didStart = await viewModel.sendMessage("Use the selected OpenRouter model")

        XCTAssertTrue(didStart)
        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning", "/api/chat/start"])
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testExplicitComposerModelPickSurvivesFailedChatStartUntilStreamStarts() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        var chatStartBodies: [[String: Any]] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: nil, profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(openRouterModel)",
                    "model_provider": "openrouter",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/chat/start":
                chatStartBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                if chatStartBodies.count == 1 {
                    return apiTestJSONResponse(#"{"session_id": "session-abc", "error": "No stream yet"}"#, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-second"
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: openRouterModel,
            displayName: "DeepSeek Chat v3 Free",
            providerID: "openrouter"
        ))

        let didStartFirstMessage = await viewModel.sendMessage("Use the explicit model")
        XCTAssertFalse(didStartFirstMessage)
        XCTAssertEqual(chatStartBodies.first?["explicit_model_pick"] as? Bool, true)

        let didStartSecondMessage = await viewModel.sendMessage("Use the same model again")
        XCTAssertTrue(didStartSecondMessage)
        XCTAssertEqual(chatStartBodies.count, 2)
        XCTAssertEqual(chatStartBodies[1]["explicit_model_pick"] as? Bool, true)
    }

    @MainActor
    func testSelectingCustomComposerModelCarriesExplicitProviderOnSend() async throws {
        let customModel = "moonshotai/kimi-k2-0905"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(customModel)",
                    "model_provider": "openrouter",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                XCTAssertEqual(body["profile"] as? String, "work")
                XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-custom"}"#, for: request)
            case "/api/default-model":
                XCTFail("Custom composer models must not save Settings defaults.")
                throw URLError(.badURL)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: customModel,
            displayName: customModel,
            providerID: "openrouter"
        ))
        XCTAssertEqual(viewModel.selectedModelID, customModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "openrouter")
        XCTAssertEqual(viewModel.selectedModelTitle, "kimi-k2-0905")

        let didStart = await viewModel.sendMessage("Use the custom OpenRouter model")

        XCTAssertTrue(didStart)
        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning", "/api/chat/start"])
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testTypedSlashModelSelectionWithoutCatalogMatchMarksNextChatStartExplicit() async throws {
        let typedModel = "gpt-5.4-mini"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "claude-sonnet-4", modelProvider: nil, profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["model"] as? String, typedModel)
                XCTAssertNil(body["model_provider"])
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(typedModel)",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["model"] as? String, typedModel)
                XCTAssertNil(body["model_provider"])
                XCTAssertEqual(body["profile"] as? String, "work")
                XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-slash-model"}"#, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "model")),
            args: typedModel
        )
        let didStart = await viewModel.sendMessage("Use the typed model")

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(didStart)
        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning", "/api/chat/start"])
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testSelectingCustomComposerModelWhenSessionUpdateFailsDoesNotMutateState() async throws {
        let customModel = "moonshotai/kimi-k2-0905"
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")

                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"model update failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: customModel,
            displayName: customModel,
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(requestPaths, ["/api/session/update"])
    }

    @MainActor
    func testSelectingCustomComposerModelWhileStreamingIsBlocked() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-active"}"#, for: request)
            case "/api/session/update":
                XCTFail("Selecting a composer model while streaming must not call session update.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Start streaming")
        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        ))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(
            viewModel.composerConfigurationErrorMessage,
            "Wait for the current response to finish before changing models."
        )
        XCTAssertEqual(requestPaths, ["/api/chat/start"])
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testSelectingCustomComposerModelWithNilSessionIDIsBlocked() async throws {
        let session = SessionSummary(
            sessionId: nil,
            title: "Planning",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            modelProvider: "openai",
            profile: "work"
        )
        let viewModel = try makeViewModel(sessionSummary: session) { request in
            XCTFail("Selecting a composer model without a session ID must not call \(request.url?.path ?? "nil").")
            throw URLError(.badURL)
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(viewModel.composerConfigurationErrorMessage, "The server did not provide a session ID.")
    }

    @MainActor
    func testSelectingCustomComposerModelSessionUpdateOmittingProviderFallsBackToOptionProvider() async throws {
        let customModel = "moonshotai/kimi-k2-0905"
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(customModel)",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: customModel,
            displayName: customModel,
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, customModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "openrouter")
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning"])
    }

    @MainActor
    func testSelectingComposerModelRefreshesEffortGatingAndSnapsUnsupportedEffort() async throws {
        let limitedModel = "o4-mini"
        var reasoningQueries: [[String: String?]] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/reasoning" where request.httpMethod == "POST":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["effort"] as? String, "xhigh")
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse(#"{"ok": true, "reasoning_effort": "xhigh"}"#, for: request)
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(limitedModel)",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                reasoningQueries.append(Dictionary(
                    uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
                ))
                return apiTestJSONResponse("""
                {
                  "show_reasoning": true,
                  "reasoning_effort": "high",
                  "supported_efforts": ["low", "medium", "high"],
                  "supports_reasoning_effort": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectReasoningEffort("xhigh")
        XCTAssertEqual(viewModel.selectedReasoningEffort, "xhigh")

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: limitedModel,
            displayName: limitedModel,
            providerID: "openai"
        ))

        // The gating query is scoped to the newly selected model, never stale
        // session state (upstream #3750 class of bug).
        XCTAssertEqual(reasoningQueries.count, 1)
        XCTAssertEqual(reasoningQueries[0]["model"], limitedModel)
        XCTAssertEqual(reasoningQueries[0]["provider"], "openai")
        XCTAssertEqual(viewModel.supportedReasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(viewModel.supportsReasoningEffort, true)
        XCTAssertTrue(viewModel.showsReasoningEffortControl)
        // "xhigh" is not supported by the new model: snap to the server's
        // coerced reasoning_effort.
        XCTAssertEqual(viewModel.selectedReasoningEffort, "high")
    }

    @MainActor
    func testReasoningEffortSlashCommandSendsActiveSessionID() async throws {
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai")
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/reasoning")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["effort"] as? String, "high")
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            return apiTestJSONResponse(#"{"ok": true, "reasoning_effort": "high"}"#, for: request)
        }

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "reasoning")),
            args: "high"
        )

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(viewModel.selectedReasoningEffort, "high")
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testReasoningEffortChangesWithBlankSessionIDAreBlockedLocally() async throws {
        let session = SessionSummary(
            sessionId: "   ",
            title: "Planning",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            modelProvider: "openai"
        )
        let viewModel = try makeViewModel(sessionSummary: session) { request in
            XCTFail("Changing reasoning effort without a session ID must not call \(request.url?.path ?? "nil").")
            throw URLError(.badURL)
        }

        let didSelect = await viewModel.selectReasoningEffort("high")
        XCTAssertFalse(didSelect)
        XCTAssertEqual(viewModel.composerConfigurationErrorMessage, "The server did not provide a session ID.")

        let slashResult = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "reasoning")),
            args: "high"
        )
        XCTAssertEqual(
            slashResult,
            .unsupported(friendlyMessage: "The server did not provide a session ID.")
        )
        XCTAssertEqual(viewModel.composerConfigurationErrorMessage, "The server did not provide a session ID.")
    }

    @MainActor
    func testSelectingComposerModelHidesEffortControlWhenUnsupported() async throws {
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "no-effort-model",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse("""
                {
                  "show_reasoning": true,
                  "reasoning_effort": "",
                  "supported_efforts": [],
                  "supports_reasoning_effort": false
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        XCTAssertTrue(viewModel.showsReasoningEffortControl)

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "no-effort-model",
            displayName: "no-effort-model",
            providerID: "openai"
        ))

        XCTAssertEqual(viewModel.supportedReasoningEfforts, [])
        XCTAssertEqual(viewModel.supportsReasoningEffort, false)
        XCTAssertFalse(viewModel.showsReasoningEffortControl)
    }

    @MainActor
    func testEffortGatingRefreshFailureResetsStaleGatingToFallback() async throws {
        // First switch lands restrictive gating (no effort support); the second
        // switch succeeds but its gating refresh fails. The stale "hidden"
        // gating from the first model must not stick to the new model — it
        // resets to the unknown fallback (static list, control shown).
        var reasoningCalls = 0
        var sessionModel = "gpt-5.4"
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(sessionModel)",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                reasoningCalls += 1
                if reasoningCalls == 1 {
                    return apiTestJSONResponse("""
                    {
                      "show_reasoning": true,
                      "reasoning_effort": "",
                      "supported_efforts": [],
                      "supports_reasoning_effort": false
                    }
                    """, for: request)
                }
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        sessionModel = "no-effort-model"
        let didSelectFirst = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "no-effort-model",
            displayName: "no-effort-model",
            providerID: "openai"
        ))
        XCTAssertTrue(didSelectFirst)
        XCTAssertEqual(viewModel.supportsReasoningEffort, false)
        XCTAssertFalse(viewModel.showsReasoningEffortControl)

        sessionModel = "flaky-model"
        let didSelect = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "flaky-model",
            displayName: "flaky-model",
            providerID: "openai"
        ))

        // The model change still succeeds; the failed refresh drops the stale
        // gating instead of applying it to the new model.
        XCTAssertTrue(didSelect)
        XCTAssertEqual(viewModel.selectedModelID, "flaky-model")
        XCTAssertNil(viewModel.supportedReasoningEfforts)
        XCTAssertNil(viewModel.supportsReasoningEffort)
        XCTAssertTrue(viewModel.showsReasoningEffortControl)
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testSelectedModelTitleRequiresExactProviderCatalogMatch() async throws {
        func makeConfiguredViewModel(
            model: String,
            provider: String?,
            modelsJSON: String
        ) throws -> ChatViewModel {
            try makeViewModel(
                sessionSummary: makeSession(model: model, modelProvider: provider)
            ) { request in
                switch request.url?.path {
                case "/api/profiles":
                    return apiTestJSONResponse(#"{"profiles": []}"#, for: request)
                case "/api/models":
                    return apiTestJSONResponse(modelsJSON, for: request)
                case "/api/reasoning":
                    return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
                case "/api/workspaces":
                    return apiTestJSONResponse(#"{"workspaces": []}"#, for: request)
                case "/api/commands":
                    return apiTestJSONResponse(#"{"commands": []}"#, for: request)
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }
        }

        let exact = try makeConfiguredViewModel(
            model: "shared/model",
            provider: "openai",
            modelsJSON: """
            {
              "groups": [
                {
                  "name": "OpenAI",
                  "provider_id": "openai",
                  "models": [{"id": "shared/model", "name": "OpenAI Shared"}]
                },
                {
                  "name": "Anthropic",
                  "provider_id": "anthropic",
                  "models": [{"id": "shared/model", "name": "Anthropic Shared"}]
                }
              ]
            }
            """
        )

        await exact.loadComposerConfiguration()
        XCTAssertEqual(exact.selectedModelTitle, "OpenAI Shared")

        let providerMismatch = try makeConfiguredViewModel(
            model: "shared/model",
            provider: "openrouter",
            modelsJSON: """
            {
              "groups": [
                {
                  "name": "OpenAI",
                  "provider_id": "openai",
                  "models": [{"id": "shared/model", "name": "OpenAI Shared"}]
                }
              ]
            }
            """
        )

        await providerMismatch.loadComposerConfiguration()
        XCTAssertEqual(providerMismatch.selectedModelTitle, "model")

        let unknownCustom = try makeConfiguredViewModel(
            model: "vendor/custom-model",
            provider: "openrouter",
            modelsJSON: #"{"groups": []}"#
        )

        await unknownCustom.loadComposerConfiguration()
        XCTAssertEqual(unknownCustom.selectedModelTitle, "custom-model")
    }

    func testDeduplicatedReasoningTextsRemovesIdenticalThinkingBodies() {
        let texts = ChatViewModel.deduplicatedReasoningTexts([
            "  **Reading workout profile**\nChecking the user's profile and workout log.  ",
            "\n**Reading workout profile**\nChecking the user's profile and workout log.\n",
            "Checking a different source.",
            "   "
        ])

        XCTAssertEqual(
            texts,
            [
                "**Reading workout profile**\nChecking the user's profile and workout log.",
                "Checking a different source."
            ]
        )
    }

    @MainActor
    func testCompletedResponseRefreshesGeneratedSessionTitle() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRefreshTitle = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(title: "Untitled Session")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["messages"], "0")
                didRefreshTitle = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Generated Meal Plan"
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        XCTAssertEqual(viewModel.displayTitle, "Untitled Session")

        let didStart = await viewModel.sendMessage("Name this chat")
        XCTAssertTrue(didStart)
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        try await waitUntil {
            didRefreshTitle && viewModel.displayTitle == "Generated Meal Plan"
        }

        XCTAssertEqual(viewModel.displayTitle, "Generated Meal Plan")
    }

    @MainActor
    func testDoneUsageReplacesLiveResponseSpeedOnAssistantMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didSend = await viewModel.sendMessage("Measure this")
        XCTAssertTrue(didSend)
        streamClient.emit(.token("Measured response."))
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 18.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(viewModel.liveTokensPerSecond, 18.25)

        streamClient.emit(.done(DoneStreamEvent(usage: ContextWindowSnapshot(
            contextLength: nil,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil,
            tokensPerSecond: 20.5
        ))))

        XCTAssertNil(viewModel.liveTokensPerSecond)
        XCTAssertEqual(viewModel.messages.last(where: { $0.role == "assistant" })?.turnTps, 20.5)
    }

    @MainActor
    func testDoneUsageAppliesResponseSpeedToLastAssistantInCompletedToolTurn() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didSend = await viewModel.sendMessage("Run a tool")
        XCTAssertTrue(didSend)
        streamClient.emit(.token("I'll inspect that."))
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role":"user","content":"Run a tool"},
            {"role":"assistant","content":"I'll inspect that."},
            {"role":"tool","content":"Tool output"},
            {"role":"assistant","content":"Finished."}
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(
            usage: ContextWindowSnapshot(
                contextLength: nil,
                thresholdTokens: nil,
                lastPromptTokens: nil,
                inputTokens: nil,
                outputTokens: nil,
                estimatedCost: nil,
                tokensPerSecond: 20.5
            ),
            session: completedSession
        )))

        let assistantMessages = viewModel.messages.filter { $0.role == "assistant" }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertNil(assistantMessages.first?.turnTps)
        XCTAssertEqual(assistantMessages.last?.turnTps, 20.5)
        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
    }

    @MainActor
    func testDoneUsageDoesNotOverwritePreviousAssistantWithoutCurrentStreamingAnchor() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didSend = await viewModel.sendMessage("Run a tool only")
        XCTAssertTrue(didSend)
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role":"user","content":"Earlier question","messageId":"user-previous"},
            {"role":"assistant","content":"Earlier answer","messageId":"assistant-previous"},
            {"role":"user","content":"Run a tool only","messageId":"user-current"}
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(
            usage: ContextWindowSnapshot(
                contextLength: nil,
                thresholdTokens: nil,
                lastPromptTokens: nil,
                inputTokens: nil,
                outputTokens: nil,
                estimatedCost: nil,
                tokensPerSecond: 20.5
            ),
            session: completedSession
        )))

        XCTAssertNil(viewModel.messages.first(where: { $0.messageId == "assistant-previous" })?.turnTps)
        XCTAssertFalse(viewModel.messages.contains(where: { $0.turnTps != nil }))
    }

    @MainActor
    func testCompletedResponseCachesFinalTurnTpsWithoutTranscriptReload() async throws {
        let streamClient = SpySSEStreamingClient()
        let modelContext = try makeContext()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didSend = await viewModel.sendMessage("Measure this", modelContext: modelContext)
        XCTAssertTrue(didSend)
        streamClient.emit(.token("Measured response."))
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role":"user","content":"Measure this","messageId":"user-current"},
            {"role":"assistant","content":"Measured response.","messageId":"assistant-server"}
          ]
        }
        """)
        streamClient.emit(.done(DoneStreamEvent(
            usage: ContextWindowSnapshot(
                contextLength: nil,
                thresholdTokens: nil,
                lastPromptTokens: nil,
                inputTokens: nil,
                outputTokens: nil,
                estimatedCost: nil,
                tokensPerSecond: 20.5
            ),
            session: completedSession
        )))

        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
        viewModel.cacheCompletedResponse(modelContext: modelContext)

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: URL(string: "https://example.test")!,
            sessionID: "session-abc",
            in: modelContext
        )
        XCTAssertEqual(
            cachedMessages.first(where: { $0.messageId == "assistant-server" })?.turnTps,
            20.5
        )
    }

    @MainActor
    func testTransportErrorChecksStatusAndFinishesWhenStreamIsInactive() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "assistant",
                        "content": "Recovered transcript.",
                        "timestamp": 1770000100,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")

        streamClient.emit(.transportError("The network connection was lost."))
        try await waitUntil {
            didRequestStatus && didReloadMessages
        }

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Recovered transcript."])
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.stopCount, 2)
    }

    @MainActor
    func testLoadMessagesReattachesActiveStreamFromReloadedSession() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertTrue(didRequestStatus)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/chat/stream")
    }

    /// #406 fallback ordering: an older server omits `pending_started_at`, so the
    /// run clock falls back to the latest user turn rather than the moment this
    /// session was opened.
    @MainActor
    func testLoadMessagesWithoutPendingStartedAtSeedsRunStartFromLatestUserMessage() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(viewModel.activeRunStartedAt, Date(timeIntervalSince1970: 1_770_000_100))
    }

    @MainActor
    func testLoadMessagesDoesNotFailForWebUICreatedSessionDecodeDrift() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "WebUI-created",
                "messages": [
                  {
                    "role": "user",
                    "content": [
                      {"type": "text", "text": "Open this in mobile"}
                    ],
                    "_ts": "1770000000",
                    "message_id": 42
                  },
                  {
                    "role": "assistant",
                    "content": "Loaded",
                    "timestamp": 1770000001,
                    "tool_calls": {"unexpected": "shape"}
                  }
                ],
                "_messages_offset": "8"
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messagesOffset, 8)
        XCTAssertEqual(viewModel.messages.first?.messageId, "42")
        XCTAssertTrue(viewModel.messages.first?.content?.contains("Open this in mobile") == true)
    }

    @MainActor
    func testLoadMessagesTracksOlderHistoryAvailability() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Recent question", "timestamp": 1, "message_id": "u-50"}
                ],
                "_messages_truncated": true,
                "_messages_offset": 50
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messagesOffset, 50)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testLoadOlderMessagesUsesCurrentOffsetAndPrependsWithoutDuplicates() async throws {
        var requestQueries: [[String: String]] = []
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            requestQueries.append(query)

            switch query["msg_before"] {
            case nil:
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            case "2":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Older question", "timestamp": 1, "message_id": "u-0"},
                      {"role": "assistant", "content": "Older answer", "timestamp": 2, "message_id": "a-1"},
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"}
                    ],
                    "_messages_truncated": false,
                    "_messages_offset": 0
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected query: \(query)")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()

        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(requestQueries.count, 2)
        XCTAssertNil(requestQueries[0]["msg_before"])
        XCTAssertEqual(requestQueries[1]["msg_before"], "2")
        XCTAssertEqual(requestQueries[1]["msg_limit"], "50")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Older question",
            "Older answer",
            "Recent question",
            "Recent answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testLoadOlderMessagesFallbackOffsetUsesMergedTranscriptCount() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            switch query["msg_before"] {
            case nil:
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 5, "message_id": "u-4"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 6, "message_id": "a-5"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 4
                  }
                }
                """, for: request)
            case "4":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "message_count": 6,
                    "messages": [
                      {"role": "user", "content": "Middle question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Middle answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected query: \(query)")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()

        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Middle question",
            "Middle answer",
            "Recent question",
            "Recent answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 2)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testLoadMessagesPreservesExpandedTranscriptWhenReloadReturnsLatestWindow() async throws {
        var latestLoadCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            switch query["msg_before"] {
            case nil:
                latestLoadCount += 1
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            case "2":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Older question", "timestamp": 1, "message_id": "u-0"},
                      {"role": "assistant", "content": "Older answer", "timestamp": 2, "message_id": "a-1"}
                    ],
                    "_messages_truncated": false,
                    "_messages_offset": 0
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected query: \(query)")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()
        await viewModel.loadMessages()

        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(latestLoadCount, 2)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Older question",
            "Older answer",
            "Recent question",
            "Recent answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testCompletedStreamSessionPreservesExpandedTranscriptWhenDoneReturnsLatestWindow() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

                if query["msg_before"] == "2" {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "messages": [
                          {"role": "user", "content": "Older question", "timestamp": 1, "message_id": "u-0"},
                          {"role": "assistant", "content": "Older answer", "timestamp": 2, "message_id": "a-1"}
                        ],
                        "_messages_truncated": false,
                        "_messages_offset": 0
                      }
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()
        let didStart = await viewModel.sendMessage("Newest question")
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role": "user", "content": "Recent question", "message_id": "u-2"},
            {"role": "assistant", "content": "Recent answer", "message_id": "a-3"},
            {"role": "user", "content": "Newest question", "message_id": "u-4"},
            {"role": "assistant", "content": "Newest answer", "message_id": "a-5"}
          ],
          "_messages_truncated": true,
          "_messages_offset": 2
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertTrue(didLoadOlder)
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Older question",
            "Older answer",
            "Recent question",
            "Recent answer",
            "Newest question",
            "Newest answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertFalse(viewModel.hasOlderMessages)
        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
    }

    @MainActor
    func testCompletedStreamSessionKeepsCurrentOffsetWhenDoneReturnsWidenedWindow() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didStart = await viewModel.sendMessage("Newest question")
        // `.done` widens the window all the way back to the session start
        // (offset 0). The rows already on screen must keep their positional
        // renderIDs, so the current offset wins and the widened head is trimmed.
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role": "user", "content": "Older question", "message_id": "u-0"},
            {"role": "assistant", "content": "Older answer", "message_id": "a-1"},
            {"role": "user", "content": "Recent question", "message_id": "u-2"},
            {"role": "assistant", "content": "Recent answer", "message_id": "a-3"},
            {"role": "user", "content": "Newest question", "message_id": "u-4"},
            {"role": "assistant", "content": "Newest answer", "message_id": "a-5"}
          ],
          "_messages_truncated": false,
          "_messages_offset": 0
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Recent question",
            "Recent answer",
            "Newest question",
            "Newest answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 2)
        XCTAssertTrue(viewModel.hasOlderMessages)
        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
    }

    @MainActor
    func testCompletedStreamSessionKeepsCurrentOffsetWhenDoneOmitsOffset() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let didStart = await viewModel.sendMessage("Newest question")
        // `.done` without `_messages_offset` used to resolve to offset 0 and
        // renumber every on-screen row. The overlap trim must keep offset 2.
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role": "user", "content": "Older question", "message_id": "u-0"},
            {"role": "assistant", "content": "Older answer", "message_id": "a-1"},
            {"role": "user", "content": "Recent question", "message_id": "u-2"},
            {"role": "assistant", "content": "Recent answer", "message_id": "a-3"},
            {"role": "user", "content": "Newest question", "message_id": "u-4"},
            {"role": "assistant", "content": "Newest answer", "message_id": "a-5"}
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Recent question",
            "Recent answer",
            "Newest question",
            "Newest answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 2)
        XCTAssertTrue(viewModel.hasOlderMessages)
        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
    }

    @MainActor
    func testReloadWithoutOverlapStillReplacesTranscript() async throws {
        var sessionRequestCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestCount += 1
            if sessionRequestCount == 1 {
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            }

            // Truncation/compaction rewrote history: no overlap with the
            // on-screen window, so the reload must fully replace it.
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Rewritten question", "timestamp": 5, "message_id": "u-9"},
                  {"role": "assistant", "content": "Rewritten answer", "timestamp": 6, "message_id": "a-10"}
                ],
                "_messages_truncated": false,
                "_messages_offset": 0
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()
        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Rewritten question",
            "Rewritten answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testReloadWithMisalignedOverlapStillReplacesTranscript() async throws {
        var sessionRequestCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestCount += 1
            if sessionRequestCount == 1 {
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                      {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            }

            // A rewrite retained the first on-screen message but moved it to a
            // different absolute index. Preserving offset 2 would make both row
            // identity and destructive action keep-counts incorrect.
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "assistant", "content": "Compacted context", "timestamp": 2, "message_id": "a-1"},
                  {"role": "user", "content": "Recent question", "timestamp": 3, "message_id": "u-2"},
                  {"role": "assistant", "content": "Recent answer", "timestamp": 4, "message_id": "a-3"}
                ],
                "_messages_truncated": false,
                "_messages_offset": 0
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()
        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Compacted context",
            "Recent question",
            "Recent answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testReloadUsesExpectedOverlapWhenFallbackMessageIDsRepeat() async throws {
        var sessionRequestCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestCount += 1
            if sessionRequestCount == 1 {
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Repeated question"},
                      {"role": "assistant", "content": "Recent answer", "message_id": "a-3"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 2
                  }
                }
                """, for: request)
            }

            // The first and third messages intentionally share ChatMessage's
            // fallback ID. The offset delta identifies index 2 as the real
            // overlap; firstIndex would incorrectly choose index 0.
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Repeated question"},
                  {"role": "assistant", "content": "Older answer", "message_id": "a-1"},
                  {"role": "user", "content": "Repeated question"},
                  {"role": "assistant", "content": "Recent answer", "message_id": "a-3"}
                ],
                "_messages_truncated": false,
                "_messages_offset": 0
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()
        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Repeated question",
            "Recent answer"
        ])
        XCTAssertEqual(viewModel.messagesOffset, 2)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testLoadOlderMessagesKeepsAffordanceWhenAnotherOlderPageExists() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            if query["msg_before"] == nil {
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Tail", "timestamp": 51, "message_id": "u-50"}
                    ],
                    "_messages_truncated": true,
                    "_messages_offset": 50
                  }
                }
                """, for: request)
            }

            XCTAssertEqual(query["msg_before"], "50")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "assistant", "content": "Earlier page", "timestamp": 50, "message_id": "a-49"}
                ],
                "_messages_truncated": true,
                "_messages_offset": 49
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()
        let didLoadOlder = await viewModel.loadOlderMessages()

        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Earlier page", "Tail"])
        XCTAssertEqual(viewModel.messagesOffset, 49)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testSkillShortcutWithoutArgsReturnsLocalSkillInfoWithoutStartingChat() async throws {
        var didRequestSkills = false
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/skills":
                didRequestSkills = true
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/start":
                XCTFail("Skill shortcut without args should not start chat.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "")

        XCTAssertTrue(didRequestSkills)
        guard case .executed(let message) = result else {
            XCTFail("Expected local skill detail response.")
            return
        }
        let unwrappedMessage = try XCTUnwrap(message)
        XCTAssertTrue(unwrappedMessage.contains("### `/spotify`"))
        XCTAssertTrue(unwrappedMessage.contains("Control Spotify playback."))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSkillShortcutWithArgsStartsChatMessage() async throws {
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/start":
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "check songs")

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(startedMessage, "/spotify check songs")
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testEditUserMessageTruncatesBeforeMessageThenStartsChatWithEditedText() async throws {
        var requestPaths: [String] = []
        var truncateKeepCount: Int?
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 10,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-10"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-11"},
                      {"role": "user", "content": "Original question", "timestamp": 3, "message_id": "u-12"},
                      {"role": "assistant", "content": "Original answer", "timestamp": 4, "message_id": "a-13"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/truncate":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                truncateKeepCount = body["keep_count"] as? Int
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 10,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-10"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-11"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-edit"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[2], visibleIndex: 2))
        let didEdit = await viewModel.editMessage(context, newText: "  Edited question  ")

        XCTAssertTrue(didEdit)
        XCTAssertEqual(requestPaths, ["/api/session", "/api/session/truncate", "/api/chat/start"])
        XCTAssertEqual(truncateKeepCount, 12)
        XCTAssertEqual(startedMessage, "Edited question")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["First question", "First answer", "Edited question"])
        XCTAssertEqual(viewModel.activeStreamID, "stream-edit")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testRegenerateAssistantResponseUsesPrecedingUserAndTruncatesAtAssistantIndex() async throws {
        var truncateKeepCount: Int?
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 5,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-5"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-6"},
                      {"role": "user", "content": "Second question", "timestamp": 3, "message_id": "u-7"},
                      {"role": "assistant", "content": "Second answer", "timestamp": 4, "message_id": "a-8"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/truncate":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                truncateKeepCount = body["keep_count"] as? Int
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 5,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-5"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-6"},
                      {"role": "user", "content": "Second question", "timestamp": 3, "message_id": "u-7"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-regen"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[3], visibleIndex: 3))
        let didRegenerate = await viewModel.regenerateAssistantResponse(context)

        XCTAssertTrue(didRegenerate)
        XCTAssertEqual(truncateKeepCount, 8)
        XCTAssertEqual(startedMessage, "Second question")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["First question", "First answer", "Second question"])
        XCTAssertEqual(viewModel.activeStreamID, "stream-regen")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testForkFromMessageUsesKeepCountThroughMessageAndHandlesMissingForkID() async throws {
        var branchBodies: [[String: Any]] = []
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                if query["session_id"] == "fork-123" {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "fork-123",
                        "title": "Forked thread"
                      }
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 4,
                    "messages": [
                      {"role": "user", "content": "Question", "timestamp": 1, "message_id": "u-4"},
                      {"role": "assistant", "content": "Answer", "timestamp": 2, "message_id": "a-5"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/branch":
                branchBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                if branchBodies.count == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session_id": "fork-123",
                      "parent_session_id": "session-abc"
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "error": "Could not fork"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[1], visibleIndex: 1))
        let forked = await viewModel.forkFromMessage(context)
        let missingID = await viewModel.forkFromMessage(context)

        XCTAssertEqual(branchBodies.count, 2)
        XCTAssertEqual(branchBodies[0]["session_id"] as? String, "session-abc")
        XCTAssertEqual(branchBodies[0]["keep_count"] as? Int, 6)
        XCTAssertEqual(forked?.sessionId, "fork-123")
        XCTAssertNil(missingID)
        XCTAssertEqual(viewModel.messageActionErrorMessage, "Could not fork")
    }

    @MainActor
    func testClearSlashCommandEmptiesTranscriptTitleAndCacheAfterServerClear() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        var requestPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {"role": "user", "content": "Old question", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/clear":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "session": {
                    "session_id": "session-abc",
                    "title": "Untitled"
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages(modelContext: context)
        XCTAssertFalse(viewModel.messages.isEmpty)

        let result = await viewModel.clearConversationFromSlashCommand(modelContext: context)

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestPaths, ["/api/session", "/api/session/clear"])
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.displayTitle, "Untitled")
        XCTAssertTrue(try CacheStore.cachedMessages(serverURL: serverURL, sessionID: "session-abc", in: context).isEmpty)
    }

    @MainActor
    func testSendIsRefusedWhileClearIsInFlight() async throws {
        let clearRequestStarted = expectation(description: "clear request reached the server")
        let releaseClearResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session/clear":
                clearRequestStarted.fulfill()
                releaseClearResponse.wait()
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "session": {"session_id": "session-abc", "title": "Untitled"}
                }
                """, for: request)
            default:
                XCTFail("A send during a clear must not reach \(request.url?.path ?? "unknown path").")
                throw URLError(.badURL)
            }
        }

        let clearTask = Task { await viewModel.clearConversationFromSlashCommand(modelContext: nil) }
        await fulfillment(of: [clearRequestStarted], timeout: 5)

        XCTAssertTrue(viewModel.isClearingConversation)
        let didSend = await viewModel.sendMessage("Sneak this in")
        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.sendErrorMessage, "Wait for the conversation to finish clearing.")

        let secondClear = await viewModel.clearConversationFromSlashCommand(modelContext: nil)
        XCTAssertEqual(secondClear, .unsupported(friendlyMessage: "Wait for the conversation to finish clearing."))

        releaseClearResponse.signal()
        let result = await clearTask.value

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertFalse(viewModel.isClearingConversation)
    }

    @MainActor
    func testClearRefusalIsKnownBeforeConfirmingForCLISessions() async throws {
        let webUIViewModel = try makeViewModel { request in
            XCTFail("Reading the refusal must not call \(request.url?.path ?? "unknown path").")
            throw URLError(.badURL)
        }
        XCTAssertNil(webUIViewModel.clearConversationRefusal)

        let cliViewModel = try makeViewModel(
            sessionSummary: SessionSummary(sessionId: "session-abc", title: "Planning", isCliSession: true)
        ) { request in
            XCTFail("Reading the refusal must not call \(request.url?.path ?? "unknown path").")
            throw URLError(.badURL)
        }

        XCTAssertEqual(
            cliViewModel.clearConversationRefusal,
            "Clearing the conversation is available for WebUI sessions only."
        )
    }

    @MainActor
    func testClearSlashCommandLeavesTranscriptIntactOnServerError() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {"role": "user", "content": "Old question", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/clear":
                return apiTestJSONResponse("""
                {
                  "error": "Session not found"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let result = await viewModel.clearConversationFromSlashCommand(modelContext: nil)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Session not found"))
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Old question"])
        XCTAssertEqual(viewModel.displayTitle, "Planning")
    }

    @MainActor
    func testClearSlashCommandLeavesTranscriptIntactWhenRequestThrows() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {"role": "user", "content": "Old question", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/clear":
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let result = await viewModel.clearConversationFromSlashCommand(modelContext: nil)

        guard case .unsupported = result else {
            return XCTFail("Expected a thrown request to surface as .unsupported, got \(result).")
        }
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Old question"])
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testClearSlashCommandRefusesWhileViewingCachedData() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user")],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            guard request.url?.path == "/api/session" else {
                XCTFail("Clear should not call the server while viewing cached data.")
                throw URLError(.badURL)
            }
            throw URLError(.timedOut)
        }

        await viewModel.loadMessages(modelContext: context)
        XCTAssertTrue(viewModel.isViewingCachedData)

        let result = await viewModel.clearConversationFromSlashCommand(modelContext: context)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Reconnect to the server to clear the conversation."))
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question"])
    }

    @MainActor
    func testClearSlashCommandRefusesForCLISessions() async throws {
        let viewModel = try makeViewModel(
            sessionSummary: SessionSummary(sessionId: "session-abc", title: "Planning", isCliSession: true)
        ) { request in
            XCTFail("Clear should not call the server for a CLI session: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let result = await viewModel.clearConversationFromSlashCommand(modelContext: nil)

        XCTAssertEqual(
            result,
            .unsupported(friendlyMessage: "Clearing the conversation is available for WebUI sessions only.")
        )
    }

    @MainActor
    func testClearSlashCommandIsBlockedWhileStreaming() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session/clear":
                XCTFail("Clear should not call the server while streaming.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)

        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "clear")))

        XCTAssertEqual(
            result,
            .unsupported(friendlyMessage: "Wait for the current response to finish before clearing the conversation.")
        )
    }

    @MainActor
    func testUndoSlashCommandCallsServerThenReloadsMessages() async throws {
        var requestPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session/undo":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "removed_count": 2
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Remaining message", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "undo")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestPaths, ["/api/session/undo", "/api/session"])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Remaining message"])
    }

    @MainActor
    func testUndoSlashCommandIsBlockedWhileStreaming() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session/undo":
                XCTFail("Undo should not call the server while streaming.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "undo")))

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Wait for the current response to finish before undoing messages."))
    }

    @MainActor
    func testRetrySlashCommandReloadsTruncatedSessionThenStartsChatWithLastUserText() async throws {
        var requestPaths: [String] = []
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session/retry":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "last_user_text": "Summarize the logs",
                  "removed_count": 2
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Earlier message", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-retry"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "retry")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestPaths, ["/api/session/retry", "/api/session", "/api/chat/start"])
        XCTAssertEqual(startedMessage, "Summarize the logs")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Earlier message", "Summarize the logs"])
        XCTAssertEqual(viewModel.activeStreamID, "stream-retry")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testRetrySlashCommandHandlesMissingLastUserTextAndMissingStreamID() async throws {
        var retryCount = 0
        var startCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session/retry":
                retryCount += 1
                if retryCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "ok": true,
                      "removed_count": 2
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "last_user_text": "Try again",
                  "removed_count": 2
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": []
                  }
                }
                """, for: request)
            case "/api/chat/start":
                startCount += 1
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "error": "No stream"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let retry = try XCTUnwrap(SlashCommandCatalog.command(named: "retry"))
        let missingTextResult = await viewModel.executeSlashCommand(retry)
        let missingStreamResult = await viewModel.executeSlashCommand(retry)

        XCTAssertEqual(
            missingTextResult,
            .unsupported(friendlyMessage: "The server did not return a message to retry.")
        )
        XCTAssertEqual(
            missingStreamResult,
            .unsupported(friendlyMessage: "No stream")
        )
        XCTAssertEqual(startCount, 1)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSuccessfulSteeringUsesOneTransientConfirmationAndRestartsDismissal() async throws {
        let streamClient = SpySSEStreamingClient()
        let dismissalDelay = ManualAsyncDelay()
        var steerRequests = 0
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            steeringConfirmationDismissDelay: { await dismissalDelay.wait() }
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-123"}"#,
                    for: request
                )
            case "/api/chat/steer":
                steerRequests += 1
                return apiTestJSONResponse(#"{"accepted":true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Start a response")
        XCTAssertTrue(didStart)

        let steerCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "steer"))
        let slashResult = await viewModel.executeSlashCommand(steerCommand, args: "First hint")
        XCTAssertEqual(slashResult, .executed(message: nil))
        XCTAssertEqual(viewModel.steeringConfirmationNotice, "Steering hint delivered.")
        await dismissalDelay.waitForRegistrationCount(1)

        let normalSendResult = await viewModel.submitStreamingMessage("Second hint", behavior: .steer)
        XCTAssertEqual(normalSendResult, .executed(message: nil))
        await dismissalDelay.waitForRegistrationCount(2)

        XCTAssertEqual(steerRequests, 2)
        XCTAssertEqual(viewModel.steeringConfirmationNotice, "Steering hint delivered.")
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)

        await dismissalDelay.resumeNext()
        await drainMainActor()

        XCTAssertEqual(viewModel.steeringConfirmationNotice, "Steering hint delivered.")

        await dismissalDelay.resumeNext()
        await drainMainActor()

        XCTAssertNil(viewModel.steeringConfirmationNotice)
        XCTAssertFalse(viewModel.messages.contains { $0.content == "Steering hint delivered." })
    }

    @MainActor
    func testStreamCompletionDiscardsSteeringConfirmationInsteadOfPersistingIt() async throws {
        let streamClient = SpySSEStreamingClient()
        let dismissalDelay = ManualAsyncDelay()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            steeringConfirmationDismissDelay: { await dismissalDelay.wait() }
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-123"}"#,
                    for: request
                )
            case "/api/chat/steer":
                return apiTestJSONResponse(#"{"accepted":true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Start a response")
        XCTAssertTrue(didStart)
        _ = await viewModel.submitStreamingMessage("Steer it", behavior: .steer)
        await dismissalDelay.waitForRegistrationCount(1)
        XCTAssertNotNil(viewModel.steeringConfirmationNotice)

        streamClient.emit(.streamEnd)

        XCTAssertNil(viewModel.steeringConfirmationNotice)
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertFalse(viewModel.messages.contains { $0.content == "Steering hint delivered." })

        await dismissalDelay.resumeNext()
        await drainMainActor()
        XCTAssertNil(viewModel.steeringConfirmationNotice)
    }

    /// Issue #202: a queued slash message whose send fails must not be retried in a tight loop.
    /// This is the verify-first verdict test — it queues one message behind a live stream, makes
    /// every drained send fail, triggers the drain, and counts how many times the send is retried.
    /// A failure-driven retry loop shows up as more than one drained attempt; the guard makes it 1.
    @MainActor
    func testQueuedSlashMessageFailureDoesNotRetryInTightLoop() async throws {
        let streamClient = SpySSEStreamingClient()
        var startChatAttempts = 0
        // The first /api/chat/start establishes a live stream so the next slash message queues
        // behind it. Every drained send after that fails (no stream_id). The forced success at
        // attempt 7 is a safety escape hatch: it guarantees even a buggy retry loop terminates
        // (a successful send clears activeStreamID's nil guard / empties the queue), so the test
        // can never hang regardless of whether the loop exists.
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                startChatAttempts += 1
                if startChatAttempts == 1 || startChatAttempts >= 7 {
                    return apiTestJSONResponse(
                        #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                        for: request
                    )
                }
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "error": "server unreachable"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        // 1. Establish a live stream so the queued message has something to wait behind.
        let didStart = await viewModel.sendMessage("first message")
        XCTAssertTrue(didStart)
        XCTAssertNotNil(viewModel.activeStreamID)

        // 2. Queue one slash message behind the active stream.
        let queueCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "queue"))
        let queued = await viewModel.executeSlashCommand(queueCommand, args: "retry-me")
        XCTAssertEqual(queued, .executed(message: "Queued for next turn (#1)."))

        let attemptsBeforeDrain = startChatAttempts // only the establishing send so far

        // 3. Finishing the stream is the natural drain trigger. The drained send fails persistently.
        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)

        // 4. Let the drain (and any retry loop) fully quiesce. MockURLProtocol resolves
        //    synchronously, so once the attempt count is stable across several short polls no
        //    further sends are in flight.
        var lastSeen = startChatAttempts
        var stablePolls = 0
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if startChatAttempts == lastSeen {
                stablePolls += 1
                if stablePolls >= 3 { break }
            } else {
                stablePolls = 0
                lastSeen = startChatAttempts
            }
        }

        let drainedAttempts = startChatAttempts - attemptsBeforeDrain

        // The guard makes a failed queued send attempt exactly once — no tight retry loop.
        XCTAssertEqual(
            drainedAttempts,
            1,
            "A failed queued send should be attempted exactly once, not retried in a loop. "
                + "Observed \(drainedAttempts) drained attempt(s)."
        )
        // The message remains queued for a later natural trigger instead of being dropped.
        let status = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "status")))
        guard case let .executed(message) = status, let statusText = message else {
            return XCTFail("Expected /status to return an executed message, got \(status).")
        }
        XCTAssertTrue(
            statusText.contains("Queued messages: 1"),
            "The failed queued message should still be queued. Status was:\n\(statusText)"
        )
    }

    @MainActor
    func testSuccessfulQueuedSendDeletesItsDurableDraftCopy() async throws {
        let streamClient = SpySSEStreamingClient()
        let attachmentStore = RecordingSendDraftAttachmentStore()
        var chatStartCount = 0
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            draftAttachmentStore: attachmentStore
        ) { request in
            switch request.url?.path {
            case "/api/upload":
                return apiTestJSONResponse("""
                {
                  "filename": "notes.txt",
                  "path": "/tmp/workspace/notes.txt",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """, for: request)
            case "/api/chat/start":
                chatStartCount += 1
                return apiTestJSONResponse(
                    """
                    {"session_id":"session-abc","stream_id":"stream-\(chatStartCount)"}
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartFirstMessage = await viewModel.sendMessage("first message")
        XCTAssertTrue(didStartFirstMessage)
        await viewModel.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")
        let queueCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "queue"))
        let queued = await viewModel.executeSlashCommand(queueCommand, args: "queued message")
        XCTAssertEqual(queued, .executed(message: "Queued for next turn (#1)."))

        streamClient.emit(.streamEnd)
        try await waitUntil { chatStartCount == 2 }
        let deletedNames = await attachmentStore.deletedNames()

        XCTAssertEqual(deletedNames, ["saved-1-notes.txt"])
    }

    // MARK: - Model-selection route intent (model-selection-audit, native hardening)

    /// Mock endpoints used by the route-intent tests below. Paths are the ones
    /// `Endpoint` already emits; no new wire shapes are invented here.
    private func makeModelRouteRecorder() -> NSLockBox {
        NSLockBox()
    }

    private func modelRouteTestResponse(
        chatStartBodies: NSLockBox,
        streamIDPrefix: String,
        sessionLoadRecorder sessionLoads: NSLockBox? = nil
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        // The `/api/session` recorder may be supplied by the caller when a test
        // has to fence on the completed-response title refresh actually
        // landing: a real non-nil `Done.session` carries its own title, so
        // "the title changed" is no longer proof the follow-up GET was sent
        // and consumed.
        let sessionRequests = sessionLoads ?? NSLockBox()
        return { request in
            switch request.url?.path {
            case "/api/chat/start":
                chatStartBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                let count = chatStartBodies.all.count
                return apiTestJSONResponse(
                    """
                    {
                      "session_id": "session-abc",
                      "stream_id": "\(streamIDPrefix)-\(count)"
                    }
                    """,
                    for: request
                )
            case "/api/profiles":
                return apiTestJSONResponse(
                    """
                    {
                      "active": "poolops",
                      "profiles": [
                        {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true}
                      ]
                    }
                    """,
                    for: request
                )
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: "@custom:opencode-go:deepseek-v4.1-flash",
                        provider: "custom:opencode-go"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
    }

    /// Completes the in-flight turn the way the real stream lifecycle does:
    /// token → done → stream_end through the spy, then fences on the per-turn
    /// follow-up work the finish triggers. Finishing a normally completed
    /// stream makes the view model fire a completed-response title refresh
    /// (`GET /api/session`) on an unstructured task — actor yields and even
    /// `activeStreamID == nil` cannot order against it, and that request is
    /// what used to leak into the NEXT test's MockURLProtocol handler. The
    /// route fixtures therefore serve a rotating title, and this helper waits
    /// for it to land in `displayTitle`: proof the refresh request was made
    /// AND its response fully consumed. Only then is the view model
    /// network-idle and a follow-up send a genuinely second send.
    @MainActor
    private func completeStreamingTurn(
        _ streamClient: SpySSEStreamingClient,
        thenDrain viewModel: ChatViewModel
    ) async throws {
        let titleBefore = viewModel.displayTitle
        streamClient.emit(.token("Partial answer."))
        streamClient.emit(.done(DoneStreamEvent(session: nil)))
        streamClient.emit(.streamEnd)
        try await waitUntil { viewModel.displayTitle != titleBefore }
        XCTAssertNotEqual(
            viewModel.displayTitle,
            titleBefore,
            "The completed-response title refresh did not settle; per-turn follow-up work is still in flight."
        )
        XCTAssertNil(viewModel.activeStreamID)
    }

    /// Real `/api/session` reload payload for the route-intent fixtures. The
    /// title rotates per request so `completeStreamingTurn`'s settle fence
    /// observes a `displayTitle` change for every completed turn, even
    /// back-to-back within one test. The recorder keeps the count by live
    /// reference (MockURLProtocol handlers cannot capture a mutating var).
    private func modelRouteSessionReloadJSON(
        sessionRequests: NSLockBox,
        model: String,
        provider: String?
    ) -> String {
        sessionRequests.append([:])
        let providerJSON = provider.map { ", \"model_provider\": \"\($0)\"" } ?? ""
        return """
        {"session": {"session_id": "session-abc", "title": "Completed Turn \(sessionRequests.all.count)", "workspace": "/tmp/workspace", "model": "\(model)"\(providerJSON), "messages": []}}
        """
    }

    /// Completes the in-flight turn with a REAL non-nil `Done.session` — the
    /// payload a server sends on a `done` frame when it has the completed
    /// session — then fences on the completed-response title refresh
    /// (`GET /api/session`) actually landing.
    ///
    /// `completeStreamingTurn`'s fence ("the title changed") is deliberately
    /// not reused here. A non-nil `Done.session` carries its own title, so the
    /// view model changes `displayTitle` as soon as that payload applies —
    /// before the follow-up GET is even sent — and the "changed" fence could
    /// return while per-turn work is still in flight. Waiting for the
    /// fixture's rotating `Completed Turn N` title proves the refresh request
    /// was made AND its response fully consumed, so the next send is genuinely
    /// a second send.
    @MainActor
    private func completeStreamingTurnReportingCompletedSession(
        _ streamClient: SpySSEStreamingClient,
        completedSessionJSON: String,
        sessionLoads: NSLockBox,
        thenDrain viewModel: ChatViewModel
    ) async throws {
        // Decode the completion through the same call `SSEClient` makes for a
        // live `done` frame, so the test exercises the shipped SSE shape
        // instead of a hand-built event.
        let doneEvent = SSEEventDecoder.decode(
            eventType: "done",
            data: "{\"session\": \(completedSessionJSON)}"
        )
        guard case .done(let donePayload) = doneEvent,
              let completedSession = donePayload.session
        else {
            XCTFail("The completed-session fixture did not decode through the real SSE done path.")
            return
        }

        // Fixture sanity: the completed session really does report the
        // owning profile's own route, not the requested one.
        XCTAssertEqual(completedSession.model, "gpt-6-astra")
        XCTAssertEqual(completedSession.modelProvider, "openai-codex")

        streamClient.emit(.token("Partial answer."))
        streamClient.emit(doneEvent)
        streamClient.emit(.streamEnd)

        let loadsBeforeRefresh = sessionLoads.all.count
        try await waitUntil {
            let served = sessionLoads.all.count
            guard served > loadsBeforeRefresh else { return false }
            return viewModel.displayTitle == "Completed Turn \(served)"
        }
        XCTAssertGreaterThan(
            sessionLoads.all.count,
            loadsBeforeRefresh,
            "A completed turn must fire its title-refresh GET."
        )
        XCTAssertEqual(
            viewModel.displayTitle,
            "Completed Turn \(sessionLoads.all.count)",
            "The completed-response title refresh did not settle; per-turn follow-up work is still in flight."
        )
        XCTAssertNil(viewModel.activeStreamID)
    }

    /// A real `/api/session`-shaped payload for a completed turn that reports
    /// the owning profile's OWN route (Astra on openai-codex) rather than the
    /// route the request carried — what a server-side fallback or a cold
    /// provider catalog resolves to.
    private func completedSessionReportingProfileRoute(
        turn: Int,
        userText: String
    ) -> String {
        """
        {
          "session_id": "session-abc",
          "title": "Resolved on the profile route \(turn)",
          "workspace": "/tmp/workspace",
          "model": "gpt-6-astra",
          "model_provider": "openai-codex",
          "messages": [
            {"role": "user", "content": "\(userText)", "message_id": "user-\(turn)"},
            {"role": "assistant", "content": "Answered on the profile route.", "message_id": "assistant-\(turn)"}
          ]
        }
        """
    }

    @MainActor
    func testRestoredSessionWithNonDefaultRouteKeepsExplicitPickOnSecondMessage() async throws {
        // Session restored from disk with a named custom-provider route. The
        // backend resolver honors explicit picks but re-resolves bare requests
        // against whichever provider catalog it happens to have loaded, so the
        // second (and every later) send must keep telling the server the
        // route was a deliberate pick — not just the first send.
        let chatStartBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "@custom:opencode-go:deepseek-v4.1-flash",
                modelProvider: "custom:opencode-go"
            ),
            handler: modelRouteTestResponse(chatStartBodies: chatStartBodies, streamIDPrefix: "stream-restored")
        )

        let didStartFirst = await viewModel.sendMessage("Continue with the restored route")
        XCTAssertTrue(didStartFirst)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let didStartSecond = await viewModel.sendMessage("Keep going")
        XCTAssertTrue(didStartSecond)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 2)
        for (index, body) in bodies.enumerated() {
            XCTAssertEqual(
                body["explicit_model_pick"] as? Bool,
                true,
                "Restored non-default route must stay explicit on send #\(index + 1)."
            )
            XCTAssertEqual(body["model"] as? String, "@custom:opencode-go:deepseek-v4.1-flash")
            XCTAssertEqual(body["model_provider"] as? String, "custom:opencode-go")
        }
    }

    @MainActor
    func testCompletedSessionReportingProfileDefaultKeepsRequestedRouteOnNextSend() async throws {
        // Finding #2 (native-review-1840, P1): `applyCompletedStreamSession`
        // assigns `currentModel`/`currentModelProvider` from the completed
        // session's metadata with no guard, and the deliberate-route check
        // then compares that overwritten pair against the owning profile's
        // default. A turn that completes while reporting the profile's OWN
        // route — server-side fallback, or a cold provider catalog — therefore
        // replaces the user's DeepSeek/OpenCode Go route, and the NEXT request
        // goes out as the profile default with no explicit-pick intent: the
        // original bug, one message later.
        //
        // The completion is injected as a REAL non-nil `Done.session` decoded
        // through the shipped SSE decoder (see
        // `completeStreamingTurnReportingCompletedSession`), not the
        // `Done(session: nil)` shape the rest of this suite uses.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let requestedProvider = "custom:opencode-go"
        let chatStartBodies = makeModelRouteRecorder()
        let sessionLoads = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: requestedProvider,
                profile: "poolops"
            ),
            handler: modelRouteTestResponse(
                chatStartBodies: chatStartBodies,
                streamIDPrefix: "stream-completed-route",
                sessionLoadRecorder: sessionLoads
            )
        )

        // The session was restored with its own non-default route, so the
        // first send is deliberate and says so.
        let didStartFirst = await viewModel.sendMessage("Use DeepSeek on OpenCode Go")
        XCTAssertTrue(didStartFirst)
        try await completeStreamingTurnReportingCompletedSession(
            streamClient,
            completedSessionJSON: completedSessionReportingProfileRoute(
                turn: 1,
                userText: "Use DeepSeek on OpenCode Go"
            ),
            sessionLoads: sessionLoads,
            thenDrain: viewModel
        )

        let didStartSecond = await viewModel.sendMessage("Keep going")
        XCTAssertTrue(didStartSecond)
        try await completeStreamingTurnReportingCompletedSession(
            streamClient,
            completedSessionJSON: completedSessionReportingProfileRoute(
                turn: 2,
                userText: "Keep going"
            ),
            sessionLoads: sessionLoads,
            thenDrain: viewModel
        )

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 2)
        let firstBody = try XCTUnwrap(bodies.first)
        XCTAssertEqual(firstBody["model"] as? String, requestedModel)
        XCTAssertEqual(firstBody["model_provider"] as? String, requestedProvider)
        XCTAssertEqual(
            firstBody["explicit_model_pick"] as? Bool,
            true,
            "The restored non-default route is a deliberate pick on the first send."
        )

        let secondBody = try XCTUnwrap(bodies.last)
        XCTAssertEqual(
            secondBody["model"] as? String,
            requestedModel,
            "A completed turn's session metadata must not replace the requested model."
        )
        XCTAssertEqual(
            secondBody["model_provider"] as? String,
            requestedProvider,
            "A completed turn's session metadata must not replace the requested provider."
        )
        XCTAssertEqual(
            secondBody["explicit_model_pick"] as? Bool,
            true,
            "The next request must still claim the deliberate route, not the profile default it was reported with."
        )
    }

    // MARK: - Unknown owning-profile metadata (finding #1)

    @MainActor
    func testRestoredUnprefixedRouteStaysExplicitWhileProfileMetadataIsDelayed() async throws {
        // Finding #1: the deliberate-route fallback only trusted `@`-prefixed
        // routes or colon-qualified providers, so a saved BARE model with an
        // unprefixed provider was sent as an implicit seed while the owning
        // profile's default was still unknown — and a cold backend is free to
        // re-resolve an implicit seed into another provider. `/api/profiles` is
        // gated open across the send, so the metadata is genuinely unknown when
        // the request is built. The pair here (gpt-5.4 on openai) is a real
        // model/provider pairing, not an assumed one.
        let chatStartBodies = makeModelRouteRecorder()
        let profilesStarted = expectation(description: "profiles request started")
        let releaseProfiles = DispatchSemaphore(value: 0)
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "gpt-5.4",
                modelProvider: "openai",
                profile: "poolops"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                profilesStarted.fulfill()
                XCTAssertEqual(releaseProfiles.wait(timeout: .now() + .seconds(5)), .success)
                return apiTestJSONResponse(
                    """
                    {
                      "active": "poolops",
                      "profiles": [
                        {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true, "is_active": true}
                      ]
                    }
                    """,
                    for: request
                )
            case "/api/models":
                return apiTestJSONResponse(
                    """
                    {
                      "default_model": "gpt-6-astra",
                      "active_provider": "openai-codex",
                      "groups": [
                        {
                          "name": "Codex",
                          "provider_id": "openai-codex",
                          "models": [
                            {"id": "gpt-6-astra", "name": "Astra"}
                          ]
                        }
                      ]
                    }
                    """,
                    for: request
                )
            default:
                return try self.modelRouteTestResponse(
                    chatStartBodies: chatStartBodies,
                    streamIDPrefix: "stream-delayed-metadata"
                )(request)
            }
        }

        let loadTask = Task { @MainActor in await viewModel.loadComposerConfiguration() }
        await fulfillment(of: [profilesStarted], timeout: 2)

        let didStart = await viewModel.sendMessage("Use the restored route")
        XCTAssertTrue(didStart)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?["model"] as? String, "gpt-5.4")
        XCTAssertEqual(bodies.first?["model_provider"] as? String, "openai")
        XCTAssertEqual(
            bodies.first?["explicit_model_pick"] as? Bool,
            true,
            "A saved route is the session's own choice while the owning profile's default is still unknown."
        )

        releaseProfiles.signal()
        await loadTask.value
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testRestoredUnprefixedRouteStaysExplicitWhenProfileMetadataFails() async throws {
        // The other half of finding #1: configuration loading that FAILS
        // outright (not just slow) must not demote the saved route either.
        let chatStartBodies = makeModelRouteRecorder()
        let profileRequests = LockedCounter()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "gpt-5.4",
                modelProvider: "openai",
                profile: "poolops"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                _ = profileRequests.increment()
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"profiles unavailable"}"#.utf8))
            default:
                return try self.modelRouteTestResponse(
                    chatStartBodies: chatStartBodies,
                    streamIDPrefix: "stream-failed-metadata"
                )(request)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertEqual(profileRequests.count, 1, "The owning profile's metadata really did fail to load.")
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")

        let didStart = await viewModel.sendMessage("Use the restored route")
        XCTAssertTrue(didStart)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?["model"] as? String, "gpt-5.4")
        XCTAssertEqual(bodies.first?["model_provider"] as? String, "openai")
        XCTAssertEqual(
            bodies.first?["explicit_model_pick"] as? Bool,
            true,
            "A failed configuration load leaves the owning default unknown; the saved route stays deliberate."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testPopulatedProfileNavigationReturnRestoresOwnershipBeforeWrites() async throws {
        let requests = makeModelRouteRecorder()
        let stream = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: stream, sessionSummary: try makeSession(profile: "work")) { request in
            let body: [String: Any] = request.httpMethod == "POST" ? try apiTestJSONBody(from: request) : [:]
            requests.append(["path": request.url?.path ?? "", "body": body])
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse(#"{"session":{"session_id":"session-abc","profile":"work","model":"gpt-5.4","messages":[{"role":"user","content":"Existing conversation"}]}}"#, for: request)
            case "/api/profile/switch":
                let name = body["name"] as? String ?? ""
                let workRestores = requests.all.filter {
                    ($0["body"] as? [String: Any])?["name"] as? String == "work"
                }.count
                if name == "work", workRestores == 1 {
                    throw URLError(.notConnectedToInternet)
                }
                return apiTestJSONResponse("{\"active\":\"\(name)\",\"default_model\":\"new-model\"}", for: request)
            case "/api/session/new":
                return apiTestJSONResponse(#"{"session":{"session_id":"research-new","profile":"research","model":"new-model"}}"#, for: request)
            case "/api/session/update":
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse(#"{"session":{"session_id":"session-abc","profile":"work","workspace":"/returned"}}"#, for: request)
            case "/api/chat/start":
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["profile"] as? String, "work")
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"returned-stream"}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        await viewModel.loadMessages()
        XCTAssertFalse(viewModel.messages.isEmpty)
        let originalSelectedProfile = viewModel.selectedProfileName
        let research = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                      gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let outcome = await viewModel.switchProfile(research, startNewSession: true)
        XCTAssertEqual(outcome?.session?.sessionId, "research-new")
        let hiddenSend = await viewModel.sendMessage("Hidden parent must not send")
        XCTAssertFalse(hiddenSend)
        // Background reconnect must not steal ownership from the destination.
        await viewModel.reconnectStreamIfNeeded()
        XCTAssertEqual(requests.all.filter { $0["path"] as? String == "/api/profile/switch" }.count, 1)
        // Same boundary invoked by ChatView.onAppear when Back reveals this VM.
        await viewModel.restoreProfileOwnershipAfterNavigation()
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
        let unsafeUpdate = await viewModel.selectWorkspacePath("/must-stay-fenced")
        XCTAssertFalse(unsafeUpdate, "A failed cookie restore must not unlock the original session.")
        await viewModel.restoreProfileOwnershipAfterNavigation()
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
        await viewModel.reconnectStreamIfNeeded()
        XCTAssertEqual(viewModel.selectedProfileName, originalSelectedProfile)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        let didUpdate = await viewModel.selectWorkspacePath("/returned")
        XCTAssertTrue(didUpdate)
        let didPickModel = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "returned-model", displayName: "Returned Model", providerID: "openai"
        ))
        XCTAssertTrue(didPickModel)
        let didSend = await viewModel.sendMessage("Continue original conversation")
        XCTAssertTrue(didSend)
        let switches = requests.all.filter { $0["path"] as? String == "/api/profile/switch" }
        XCTAssertEqual((switches.last?["body"] as? [String: Any])?["name"] as? String, "work")
        viewModel.suspendStreamForNavigation()
        viewModel.cleanupPollingTasks()
    }

    @MainActor
    func testLeavingDuringSuspendedProfileCreationCannotRecreateRecoveredDraft() async throws {
        let creationStarted = expectation(description: "Session creation suspended")
        let releaseCreation = DispatchSemaphore(value: 0)
        let requests = makeModelRouteRecorder()
        let viewModel = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                requests.append(body)
                return apiTestJSONResponse("{\"active\":\"\(body["name"] as? String ?? "")\"}", for: request)
            case "/api/session/new":
                creationStarted.fulfill()
                guard releaseCreation.wait(timeout: .now() + 10) == .success else {
                    throw URLError(.timedOut)
                }
                return apiTestJSONResponse(#"{"session":{"session_id":"replacement-b","profile":"research"}}"#, for: request)
            default:
                XCTFail("Unexpected request")
                throw URLError(.badURL)
            }
        }
        let owner = ChatProfileSwitchOwnership()
        let token = try XCTUnwrap(owner.begin())
        let server = URL(string: "https://example.com")!
        actor DraftPersistence: ChatDraftPersisting {
            func load() async -> [ChatDraftKey: ChatDraft] { [:] }
            func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws {}
        }
        let store = ChatDraftStore(persistence: DraftPersistence(), debounceDuration: .seconds(10))
        let original = ChatDraftKey.session(server: server, sessionID: "session-abc")
        let replacement = ChatDraftKey.session(server: server, sessionID: "replacement-b")
        let newChat = ChatDraftKey.newChat(server: server)
        let content = ComposerDraftContent(text: "Do not duplicate", quotes: [ComposerQuote(text: "Quote")])
        store.setContent(content, for: original)
        let profile = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                     gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        var didNavigate = false
        let switching = Task {
            let outcome = await viewModel.switchProfile(profile, startNewSession: true, canComplete: { owner.owns(token) })
            if outcome?.session != nil {
                store.setContent(content, for: original)
                store.moveDraft(from: original, to: replacement)
                didNavigate = true
            }
            owner.finish(token)
            return outcome
        }
        await fulfillment(of: [creationStarted], timeout: 3)
        // The container invalidates completion ownership before recovering A.
        owner.abandon()
        _ = store.restoreAbandonedNewChatDraft(from: original, to: newChat, didStartConversation: false)
        // Even a reappearance cannot give the old suspended operation ownership.
        owner.appear()
        releaseCreation.signal()
        let outcome = await switching.value
        XCTAssertNil(outcome)
        XCTAssertFalse(didNavigate)
        let recovered = await store.draft(for: newChat)
        let stranded = await store.draft(for: replacement)
        let old = await store.draft(for: original)
        XCTAssertEqual(recovered?.text, content.text)
        XCTAssertEqual(recovered?.quotes, content.quotes)
        XCTAssertNil(stranded)
        XCTAssertNil(old)
        XCTAssertEqual(requests.all.last?["name"] as? String, "work")
        XCTAssertNotNil(owner.begin(), "A fresh appearance can start a new operation.")
    }

    @MainActor
    func testAbandonedCreationCannotRollBackNewerSessionListProfileOwner() async throws {
        let creationStarted = expectation(description: "A creation suspended")
        let releaseCreation = DispatchSemaphore(value: 0)
        defer { releaseCreation.signal() }
        let switches = makeModelRouteRecorder()
        let viewModel = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                switches.append(body)
                return apiTestJSONResponse("{\"active\":\"\(body["name"] as? String ?? "")\"}", for: request)
            case "/api/session/new":
                creationStarted.fulfill()
                guard releaseCreation.wait(timeout: .now() + 10) == .success else {
                    throw URLError(.timedOut)
                }
                return apiTestJSONResponse(#"{"session":{"session_id":"replacement-b","profile":"research"}}"#, for: request)
            default:
                XCTFail("Unexpected request")
                throw URLError(.badURL)
            }
        }
        let owner = ChatProfileSwitchOwnership()
        let token = try XCTUnwrap(owner.begin())
        let research = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                      gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let switching = Task {
            await viewModel.switchProfile(research, startNewSession: true, canComplete: { owner.owns(token) })
        }
        await fulfillment(of: [creationStarted], timeout: 3)
        owner.abandon()

        // A different screen owns a different APIClient, but the same server cookie.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let server = URL(string: "https://example.test")!
        let list = SessionListViewModel(server: server, client: APIClient(baseURL: server, session: session))
        let third = ProfileSummary(name: "third", path: nil, isDefault: nil, isActive: nil,
                                   gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let didSwitch = await list.switchActiveProfile(third)
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(list.activeProfileName, "third")
        releaseCreation.signal()
        let outcome = await switching.value
        XCTAssertNil(outcome)
        XCTAssertEqual(switches.all.compactMap { $0["name"] as? String }, ["research", "third"],
                       "Retired A must not send a cookie-changing rollback after C owns the server.")
        await viewModel.restoreProfileOwnershipAfterNavigation()
        XCTAssertEqual(switches.all.last?["name"] as? String, "third", "Recovery must not revive retired ownership.")
        let unsafeWrite = await viewModel.selectWorkspacePath("/retired")
        XCTAssertFalse(unsafeWrite)
    }

    @MainActor
    func testFailedRollbackRetryCannotReclaimNewerClientOwnership() async throws {
        let switches = makeModelRouteRecorder()
        let viewModel = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                switches.append(body)
                let name = body["name"] as? String ?? ""
                if name == "work" { throw URLError(.notConnectedToInternet) }
                return apiTestJSONResponse("{\"active\":\"\(name)\"}", for: request)
            case "/api/session/new":
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Retired recovery must not write")
                throw URLError(.badURL)
            }
        }
        let research = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                      gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let outcome = await viewModel.switchProfile(research, startNewSession: true)
        XCTAssertNil(outcome)
        XCTAssertTrue(viewModel.canRetryProfileOwnership)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let other = APIClient(baseURL: URL(string: "https://example.test")!, session: session)
        _ = try await other.switchProfile(name: "third")
        await viewModel.restoreProfileOwnershipAfterNavigation()
        await viewModel.restoreProfileOwnershipAfterNavigation()
        XCTAssertEqual(switches.all.compactMap { $0["name"] as? String }, ["research", "work", "third"])
        XCTAssertFalse(viewModel.canRetryProfileOwnership)
        let unsafeWrite = await viewModel.selectWorkspacePath("/retired")
        XCTAssertFalse(unsafeWrite)
    }

    @MainActor
    func testFailedCreationAndRollbackRetainsRetryableOriginalOwnership() async throws {
        let switches = makeModelRouteRecorder()
        let viewModel = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                switches.append(body)
                let name = body["name"] as? String ?? ""
                if name == "work", switches.all.count <= 3 {
                    throw URLError(.notConnectedToInternet)
                }
                return apiTestJSONResponse("{\"active\":\"\(name)\"}", for: request)
            case "/api/session/new":
                throw URLError(.notConnectedToInternet)
            case "/api/session/update":
                XCTAssertEqual(try apiTestJSONBody(from: request)["session_id"] as? String, "session-abc")
                return apiTestJSONResponse(#"{"session":{"session_id":"session-abc","profile":"work","workspace":"/recovered"}}"#, for: request)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "")")
                throw URLError(.badURL)
            }
        }
        let profile = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                     gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let outcome = await viewModel.switchProfile(profile, startNewSession: true)
        XCTAssertNil(outcome)
        XCTAssertTrue(viewModel.canRetryProfileOwnership)
        let blocked = await viewModel.selectWorkspacePath("/unsafe")
        XCTAssertFalse(blocked)
        await viewModel.restoreProfileOwnershipAfterNavigation()
        let stillBlocked = await viewModel.selectWorkspacePath("/unsafe")
        XCTAssertFalse(stillBlocked)
        await viewModel.restoreProfileOwnershipAfterNavigation()
        XCTAssertEqual(switches.all.compactMap { $0["name"] as? String }, ["research", "work", "work", "work"])
        XCTAssertFalse(viewModel.canRetryProfileOwnership)
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        let recovered = await viewModel.selectWorkspacePath("/recovered")
        XCTAssertTrue(recovered)
    }

    @MainActor
    func testNewProfileSessionFailureRestoresOriginalComposerAndCookie() async throws {
        let switches = makeModelRouteRecorder()
        let viewModel = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                switches.append(body)
                let name = body["name"] as? String ?? "research"
                return apiTestJSONResponse("{\"active\": \"\(name)\", \"default_model\": \"new-model\"}", for: request)
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active":"research","profiles":[{"name":"research"}]}"#, for: request)
            case "/api/models":
                return apiTestJSONResponse(#"{"default_model":"new-model","groups":[]}"#, for: request)
            case "/api/reasoning", "/api/workspaces", "/api/commands":
                return apiTestJSONResponse("{}", for: request)
            case "/api/session/new":
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let research = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                      gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let outcome = await viewModel.switchProfile(research, startNewSession: true)
        XCTAssertNil(outcome)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(switches.all.last?["name"] as? String, "work")
        XCTAssertFalse(viewModel.isUpdatingComposerConfiguration)
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testNewProfileSessionRejectsRapidSwitchAndOldSessionPolling() async throws {
        let switchStarted = expectation(description: "Profile switch started")
        let releaseSwitch = DispatchSemaphore(value: 0)
        let requests = makeModelRouteRecorder()
        let viewModel = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            requests.append(["path": request.url?.path ?? ""])
            switch request.url?.path {
            case "/api/profile/switch":
                if requests.all.filter({ $0["path"] as? String == "/api/profile/switch" }).count == 1 {
                    switchStarted.fulfill()
                    _ = releaseSwitch.wait(timeout: .now() + 5)
                }
                return apiTestJSONResponse(#"{"active":"research","default_model":"new-model"}"#, for: request)
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active":"research","profiles":[{"name":"research"}]}"#, for: request)
            case "/api/models":
                return apiTestJSONResponse(#"{"default_model":"new-model","groups":[]}"#, for: request)
            case "/api/reasoning", "/api/workspaces", "/api/commands", "/api/session/yolo":
                return apiTestJSONResponse("{}", for: request)
            case "/api/session/new":
                return apiTestJSONResponse(#"{"session":{"session_id":"research-new","profile":"research"}}"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let research = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                      gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let first = Task { await viewModel.switchProfile(research, startNewSession: true) }
        await fulfillment(of: [switchStarted], timeout: 2)
        // Release before awaiting other requests: the fixture's URL loading queue
        // may be serial, so holding it would test a semaphore, not ownership.
        releaseSwitch.signal()
        let second = await viewModel.switchProfile(research, startNewSession: true)
        await viewModel.refreshApprovalBypassState()
        let outcome = await first.value
        XCTAssertNil(second)
        XCTAssertEqual(outcome?.session?.sessionId, "research-new")
        XCTAssertEqual(requests.all.filter { $0["path"] as? String == "/api/profile/switch" }.count, 1)
        XCTAssertFalse(requests.all.contains { $0["path"] as? String == "/api/session/yolo" })
    }

    @MainActor
    func testProfileReplacementUsesNewSessionForComposerWritesAndAttachmentRestore() async throws {
        let old = try makeViewModel(sessionSummary: try makeSession(profile: "work")) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return apiTestJSONResponse(#"{"active":"research","default_model":"new-model"}"#, for: request)
            case "/api/session/new":
                XCTAssertEqual(try apiTestJSONBody(from: request)["profile"] as? String, "research")
                return apiTestJSONResponse(#"{"session":{"session_id":"research-new","profile":"research","model":"new-model"}}"#, for: request)
            default:
                XCTFail("Old session must not load configuration during handoff")
                throw URLError(.badURL)
            }
        }
        let research = ProfileSummary(name: "research", path: nil, isDefault: nil, isActive: nil,
                                      gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let outcome = await old.switchProfile(research, startNewSession: true)
        let session = try XCTUnwrap(outcome?.session)
        await old.restoreProfileOwnershipAfterNavigation()
        let oldSend = await old.sendMessage("Do not send to the old session")
        XCTAssertFalse(oldSend)
        await old.loadComposerConfiguration()
        await old.refreshApprovalBypassState()

        let replacement = try makeViewModel(sessionSummary: session) { request in
            switch request.url?.path {
            case "/api/session/update":
                XCTAssertEqual(try apiTestJSONBody(from: request)["session_id"] as? String, "research-new")
                return apiTestJSONResponse(#"{"session":{"session_id":"research-new","workspace":"/new-workspace"}}"#, for: request)
            case "/api/upload":
                let body = apiTestBodyData(from: request) ?? Data()
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("research-new"))
                return apiTestJSONResponse(#"{"filename":"notes.txt","path":"/research-new/notes.txt","size":5,"mime":"text/plain","is_image":false}"#, for: request)
            default:
                XCTFail("Unexpected replacement request: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let updated = await replacement.selectWorkspacePath("/new-workspace")
        XCTAssertTrue(updated)
        let record = ChatDraftAttachment(id: UUID(), name: "notes.txt", mime: "text/plain",
                                         size: 5, isImage: false, file: "durable-notes.txt")
        let attachment = await replacement.reuploadDraftAttachment(record, data: Data("notes".utf8))
        XCTAssertEqual(attachment?.id, record.id)
        XCTAssertEqual(attachment?.draftFileName, record.file)
        XCTAssertEqual(attachment?.path, "/research-new/notes.txt")
    }

    // MARK: - Profile switch with omitted defaults (finding #3)

    @MainActor
    func testProfileSwitchOmittingDefaultModelUsesTheReturnedProfileRoute() async throws {
        // Finding #3: a switch reply that omits `default_model` used to leave
        // BOTH the model and the provider untouched, so the previous profile's
        // route leaked into the new profile as an implicit seed.
        let chatStartBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "gpt-5.4",
                modelProvider: "openai",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return apiTestJSONResponse(
                    """
                    {
                      "active": "research",
                      "profiles": [
                        {"name": "work", "model": "gpt-5.4", "provider": "openai"},
                        {"name": "research", "model": "gpt-4o-mini", "provider": "openai-codex", "is_active": true}
                      ]
                    }
                    """,
                    for: request
                )
            case "/api/profiles":
                return apiTestJSONResponse(
                    """
                    {
                      "active": "research",
                      "profiles": [
                        {"name": "work", "model": "gpt-5.4", "provider": "openai"},
                        {"name": "research", "model": "gpt-4o-mini", "provider": "openai-codex", "is_active": true}
                      ]
                    }
                    """,
                    for: request
                )
            case "/api/models":
                return apiTestJSONResponse(
                    """
                    {
                      "default_model": "gpt-4o-mini",
                      "active_provider": "openai-codex",
                      "groups": [
                        {
                          "name": "Codex",
                          "provider_id": "openai-codex",
                          "models": [
                            {"id": "gpt-4o-mini", "name": "Mini"}
                          ]
                        }
                      ]
                    }
                    """,
                    for: request
                )
            default:
                return try self.modelRouteTestResponse(
                    chatStartBodies: chatStartBodies,
                    streamIDPrefix: "stream-switch-omitted"
                )(request)
            }
        }

        let research = ProfileSummary(
            name: "research", path: nil, isDefault: nil, isActive: nil,
            gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil
        )
        let outcome = await viewModel.switchProfile(research, startNewSession: false)
        XCTAssertNotNil(outcome)

        XCTAssertEqual(viewModel.selectedModelID, "gpt-4o-mini")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai-codex")

        let didStart = await viewModel.sendMessage("On the new profile")
        XCTAssertTrue(didStart)

        let body = try XCTUnwrap(chatStartBodies.all.first)
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(
            body["model_provider"] as? String,
            "openai-codex",
            "The previous profile's route must never carry across a switch."
        )
        XCTAssertNil(
            body["explicit_model_pick"],
            "The new profile's own default is a seed, not a deliberate pick."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testProfileSwitchWithOnlyPartialMetadataNeverKeepsThePreviousRoute() async throws {
        // Same rule with no usable metadata in the switch reply at all: the old
        // pair is cleared, and the new profile seeds from its own configuration
        // (which is exactly what the configuration load right after the switch
        // reads) instead of inheriting the previous route.
        let chatStartBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "@custom:opencode-go:deepseek-v4.1-flash",
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return apiTestJSONResponse(
                    #"{"active": "research", "profiles": [{"name": "research", "is_active": true}]}"#,
                    for: request
                )
            case "/api/profiles":
                return apiTestJSONResponse(
                    """
                    {
                      "active": "research",
                      "profiles": [
                        {"name": "work", "model": "gpt-5.4", "provider": "openai"},
                        {"name": "research", "model": "gpt-4o-mini", "provider": "openai-codex", "is_active": true}
                      ]
                    }
                    """,
                    for: request
                )
            case "/api/models":
                return apiTestJSONResponse(
                    """
                    {
                      "default_model": "gpt-4o-mini",
                      "active_provider": "openai-codex",
                      "groups": [
                        {
                          "name": "Codex",
                          "provider_id": "openai-codex",
                          "models": [
                            {"id": "gpt-4o-mini", "name": "Mini"}
                          ]
                        }
                      ]
                    }
                    """,
                    for: request
                )
            default:
                return try self.modelRouteTestResponse(
                    chatStartBodies: chatStartBodies,
                    streamIDPrefix: "stream-switch-partial"
                )(request)
            }
        }

        let research = ProfileSummary(
            name: "research", path: nil, isDefault: nil, isActive: nil,
            gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil
        )
        let outcome = await viewModel.switchProfile(research, startNewSession: false)
        XCTAssertNotNil(outcome)

        XCTAssertEqual(viewModel.selectedModelID, "gpt-4o-mini")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai-codex")

        let didStart = await viewModel.sendMessage("On the new profile")
        XCTAssertTrue(didStart)

        let body = try XCTUnwrap(chatStartBodies.all.first)
        XCTAssertNotEqual(body["model"] as? String, "@custom:opencode-go:deepseek-v4.1-flash")
        XCTAssertNotEqual(body["model_provider"] as? String, "custom:opencode-go")
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    // MARK: - Typed /model with a cold catalog (finding #4)

    @MainActor
    func testTypedModelCommandWithColdCatalogNeverInheritsTheReplacedProvider() async throws {
        // Finding #4: with no catalog match and a reply that omits
        // `model_provider`, the provider fell back to the model being REPLACED,
        // producing an incoherent pair (a custom-prefixed model sent with
        // `openai`). The qualifier in the typed model is the provider identity.
        let typedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartBodies = makeModelRouteRecorder()
        let sessionUpdateBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "gpt-5.4",
                modelProvider: "openai",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/session/update":
                sessionUpdateBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                // Cold catalog: the update reply echoes the model and omits the
                // provider entirely.
                return apiTestJSONResponse(
                    """
                    {"session": {"session_id": "session-abc", "workspace": "/tmp/workspace", "model": "\(typedModel)"}}
                    """,
                    for: request
                )
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                return try self.modelRouteTestResponse(
                    chatStartBodies: chatStartBodies,
                    streamIDPrefix: "stream-typed-model"
                )(request)
            }
        }

        XCTAssertTrue(viewModel.modelCatalogGroups.isEmpty, "Precondition: the shared catalog is cold.")

        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "model"))
        let result = await viewModel.executeSlashCommand(command, args: typedModel)
        guard case .executed = result else {
            XCTFail("The typed /model command did not execute: \(result)")
            return
        }

        XCTAssertEqual(sessionUpdateBodies.all.first?["model"] as? String, typedModel)
        XCTAssertNil(
            sessionUpdateBodies.all.first?["model_provider"],
            "A cold catalog has no provider to send with the update."
        )
        XCTAssertEqual(viewModel.selectedModelID, typedModel)
        XCTAssertEqual(
            viewModel.selectedModelProviderID,
            "custom:opencode-go",
            "The provider must be derived from the qualified model, never inherited from the replaced one."
        )

        let didStart = await viewModel.sendMessage("Use the typed model")
        XCTAssertTrue(didStart)

        let body = try XCTUnwrap(chatStartBodies.all.first)
        XCTAssertEqual(body["model"] as? String, typedModel)
        XCTAssertEqual(body["model_provider"] as? String, "custom:opencode-go")
        XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    // MARK: - Effective-route disclosure states (finding #5)

    @MainActor
    func testEffectiveRouteReplyOmittingProviderLeavesPriorMismatchNoticeIntact() async throws {
        // Finding #5: the whole comparison collapsed to a Bool, so a reply that
        // named the model but NO provider anywhere read as confirmation and
        // retired a real mismatch notice. Omission is not confirmation.
        //
        // Lifecycle note: a completed turn promotes every pinned notice into the
        // transcript as a `local_notice` message and empties `pinnedLocalNotices`
        // (`ChatStreamCoordinator.finishStream` → `flushPinnedLocalNoticesToTranscript`).
        // After the first drain the standing disclosure therefore lives in
        // `messages`, and the pin list is expected to stay empty — that is what
        // "not disclosed again" looks like from the outside.
        let requestedModel = "gpt-5.4"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "openai",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                let count = chatStartCount.increment()
                if count == 2 {
                    // Same model, provider omitted everywhere: unknown.
                    return apiTestJSONResponse(
                        #"{"session_id": "session-abc", "stream_id": "stream-unknown-2", "effective_model": "gpt-5.4"}"#,
                        for: request
                    )
                }
                // A genuine mismatch, and byte-for-byte the same one on every
                // other send.
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-mismatch-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "openai"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartFirst = await viewModel.sendMessage("First")
        XCTAssertTrue(didStartFirst)
        let notice = try XCTUnwrap(
            viewModel.pinnedLocalNotices.first { $0.contains("gpt-6-astra (openai-codex)") },
            "A genuine mismatch must be disclosed."
        )
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let didStartSecond = await viewModel.sendMessage("Second")
        XCTAssertTrue(didStartSecond)

        // The disclosure now lives in the transcript (a promoted `local_notice`).
        // An unknown reply must leave it exactly as it was: no new pin invented,
        // and nothing retired.
        XCTAssertTrue(
            viewModel.messages.contains {
                $0.role == "local_notice" && $0.content?.contains("gpt-6-astra (openai-codex)") == true
            },
            "An unconfirmed provider must leave the standing disclosure visible."
        )
        XCTAssertTrue(
            viewModel.pinnedLocalNotices.isEmpty,
            "An unconfirmed provider must not invent a new pinned notice."
        )
        XCTAssertEqual(viewModel.selectedModelID, requestedModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        // The SAME mismatch again. Because the unknown reply in between was not
        // treated as confirmation, the standing disclosure was never released, so
        // this identical mismatch must not be disclosed a second time.
        let didStartThird = await viewModel.sendMessage("Third")
        XCTAssertTrue(didStartThird)
        XCTAssertTrue(
            viewModel.pinnedLocalNotices.isEmpty,
            "An already-disclosed mismatch must not be pinned again."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        XCTAssertEqual(
            viewModel.messages.filter { $0.role == "local_notice" && $0.content == notice }.count,
            1,
            "An unconfirmed provider leaves the standing disclosure in force: neither dropped nor duplicated."
        )
        XCTAssertEqual(viewModel.selectedModelID, requestedModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
    }

    @MainActor
    func testEffectiveRouteReplyMatchingTheQualifiedSpellingIsConfirmationAndClearsTheNotice() async throws {
        // A requested provider CAN be confirmed without the provider field: the
        // effective model's own `@provider:` qualifier supplies the identity.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                let count = chatStartCount.increment()
                if count == 1 {
                    return apiTestJSONResponse(
                        #"{"session_id": "session-abc", "stream_id": "stream-qualified-1", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}"#,
                        for: request
                    )
                }
                // Matching qualified spelling, provider field omitted.
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-qualified-2", "effective_model": "\(requestedModel)"}
                    """,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartFirst = await viewModel.sendMessage("First")
        XCTAssertTrue(didStartFirst)
        XCTAssertTrue(viewModel.pinnedLocalNotices.contains { $0.contains("gpt-6-astra") })
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let didStartSecond = await viewModel.sendMessage("Second")
        XCTAssertTrue(didStartSecond)

        XCTAssertTrue(
            viewModel.pinnedLocalNotices.isEmpty,
            "The effective model's qualifier confirms the requested provider, so the outdated mismatch notice must go."
        )
        XCTAssertEqual(viewModel.selectedModelID, requestedModel)

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testEffectiveRouteReplyWithSameModelOnAnotherProviderStaysAMismatch() async throws {
        // Same model text behind a different provider is still a mismatch: the
        // provider is part of the route.
        let requestedModel = "gpt-5.4"
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "openai",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-same-model", "effective_model": "gpt-5.4", "effective_model_provider": "openai-codex"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "openai"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Use the same model elsewhere")
        XCTAssertTrue(didStart)

        let notice = try XCTUnwrap(viewModel.pinnedLocalNotices.first)
        XCTAssertTrue(notice.contains("Requested gpt-5.4 (openai)"))
        XCTAssertTrue(notice.contains("with gpt-5.4 (openai-codex)"))
        XCTAssertEqual(viewModel.pinnedLocalNotices.count, 1)

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    // MARK: - Transcript-load race against the pinned notice (finding #6)

    @MainActor
    func testIdenticalMismatchNoticeCanBePinnedAgainAfterATranscriptLoadReplacesIt() async throws {
        // Finding #6, ownership half: a load that replaces the visible notice
        // list left the private "already shown" pointer behind, so every later
        // identical mismatch was deduplicated against a notice the user could no
        // longer see. Visible state and ownership must move together.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-reload-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartFirst = await viewModel.sendMessage("First")
        XCTAssertTrue(didStartFirst)
        let notice = try XCTUnwrap(viewModel.pinnedLocalNotices.first)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        // Completion promoted the notice into the transcript. A transcript load
        // then replaces that transcript, and a promoted `local_notice` is not
        // kept by the merge (`mergingLoadedMessages` preserves only local
        // optimistic USER messages) — so after the load no visible copy of the
        // notice remains anywhere.
        XCTAssertTrue(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "Precondition: the completed turn promotes the pinned notice into the transcript."
        )
        await viewModel.loadMessages()
        XCTAssertFalse(
            viewModel.pinnedLocalNotices.contains(notice),
            "The transcript load replaces the visible notice list."
        )
        XCTAssertFalse(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "The load replaces the transcript, so no visible copy of the notice remains."
        )

        let didStartSecond = await viewModel.sendMessage("Second")
        XCTAssertTrue(didStartSecond)

        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "The same mismatch must be able to pin again once the earlier copy is no longer visible."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testTranscriptLoadInFlightDoesNotDropANoticePinnedByANewerStartReply() async throws {
        // Finding #6, race half: the load's clear was unfenced, so an older load
        // completing after a newer `chat/start` reply dropped that fresh notice —
        // and the surviving pointer then suppressed every identical one after it.
        // The gate holds the load open until after the reply has landed.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionLoadStarted = expectation(description: "session load started")
        let releaseSessionLoad = DispatchSemaphore(value: 0)
        let sessionLoadCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "@custom:opencode-go:deepseek-v4.1-flash",
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-race-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            case "/api/session":
                // Only the explicit load is gated; the completion title
                // refreshes must stay responsive.
                if sessionLoadCount.increment() == 1 {
                    sessionLoadStarted.fulfill()
                    XCTAssertEqual(releaseSessionLoad.wait(timeout: .now() + .seconds(5)), .success)
                }
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loadTask = Task { @MainActor in await viewModel.loadMessages() }
        await fulfillment(of: [sessionLoadStarted], timeout: 2)

        let didStartFirst = await viewModel.sendMessage("Race the load")
        XCTAssertTrue(didStartFirst)
        let notice = try XCTUnwrap(viewModel.pinnedLocalNotices.first)
        XCTAssertEqual(viewModel.pinnedLocalNotices.filter { $0 == notice }.count, 1)

        // The load lands while the notice is still PINNED — the review's repro
        // ordering. The load began before the notice existed, so it does not own
        // it and must not remove it. (On the unfixed code its unfenced clear
        // wiped the list right here.)
        releaseSessionLoad.signal()
        await loadTask.value
        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "A load that began before this notice must not remove it when it finally lands."
        )

        // Completing the turn promotes the surviving notice into the transcript.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
        XCTAssertTrue(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "Completing the turn promotes the surviving notice into the transcript."
        )

        // A subsequent identical mismatch: already disclosed by the promoted
        // copy, so it must not be pinned again, and that copy must stay the only
        // one.
        let didStartSecond = await viewModel.sendMessage("Same route again")
        XCTAssertTrue(didStartSecond)
        XCTAssertTrue(
            viewModel.pinnedLocalNotices.isEmpty,
            "An already-disclosed mismatch must not be pinned again."
        )
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == "local_notice" && $0.content == notice }.count,
            1,
            "A subsequent identical mismatch stays visible: neither dropped nor duplicated."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    // MARK: - Wholesale transcript replacements (round 3)

    /// `/api/session` payload for the wholesale-replacement probes: the real
    /// reload shape (`modelRouteSessionReloadJSON`'s rotating completion title
    /// plus the session's own route) with a transcript attached, which the
    /// edit / regenerate / retry paths need in order to have a target row.
    private func routeFixtureSessionWithTranscript(
        sessionRequests: NSLockBox,
        model: String,
        provider: String?,
        messagesJSON: String
    ) -> String {
        sessionRequests.append([:])
        let providerJSON = provider.map { ", \"model_provider\": \"\($0)\"" } ?? ""
        return """
        {"session": {"session_id": "session-abc", "title": "Completed Turn \(sessionRequests.all.count)", "workspace": "/tmp/workspace", "model": "\(model)"\(providerJSON), "_messages_offset": 0, "messages": [\(messagesJSON)]}}
        """
    }

    /// The transcript the replacement probes start from. Indices matter: 2 is a
    /// user row (editable) and 3 an assistant row (regenerable).
    private var replacementProbeTranscriptJSON: String {
        """
        {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-1"},
        {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-2"},
        {"role": "user", "content": "Original question", "timestamp": 3, "message_id": "u-3"},
        {"role": "assistant", "content": "Original answer", "timestamp": 4, "message_id": "a-4"}
        """
    }

    /// Sends one turn, takes the standing mismatch disclosure through its
    /// promotion into the transcript, and returns that notice's text. Used by
    /// every round-3 probe so they all start from the same real state: a
    /// disclosure that is visible only as a promoted `local_notice` row, with the
    /// dedupe pointer set.
    @MainActor
    private func pinAndPromoteMismatchNotice(
        _ streamClient: SpySSEStreamingClient,
        in viewModel: ChatViewModel
    ) async throws -> String {
        let didStart = await viewModel.sendMessage("First")
        XCTAssertTrue(didStart)
        let notice = try XCTUnwrap(
            viewModel.pinnedLocalNotices.first,
            "A mismatch reply must pin the disclosure."
        )
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
        XCTAssertTrue(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "Precondition: the completed turn promotes the pinned notice into the transcript."
        )
        return notice
    }

    @MainActor
    func testCompressReplacedTranscriptLetsTheMismatchNoticeReShow() async throws {
        // Round 3: `/compress` adopts the server's compressed transcript
        // wholesale, which keeps no promoted `local_notice` copy. Without the
        // pointer reconcile the standing disclosure disappears for good and the
        // next identical mismatch is deduped against a notice nobody can see.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse(
                    self.routeFixtureSessionWithTranscript(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go",
                        messagesJSON: self.replacementProbeTranscriptJSON
                    ),
                    for: request
                )
            case "/api/session/compress":
                return apiTestJSONResponse(
                    """
                    {
                      "session": {
                        "session_id": "session-abc",
                        "_messages_offset": 0,
                        "messages": [
                          {"role": "user", "content": "Compressed question", "timestamp": 1, "message_id": "c-1"},
                          {"role": "assistant", "content": "Compressed answer", "timestamp": 2, "message_id": "c-2"}
                        ]
                      }
                    }
                    """,
                    for: request
                )
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-compress-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let notice = try await pinAndPromoteMismatchNotice(streamClient, in: viewModel)

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "compress"))
        )
        XCTAssertEqual(result, .executed(message: "Context compressed."))
        XCTAssertEqual(chatStartCount.count, 1, "The compress path does not send.")

        XCTAssertFalse(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "The compressed transcript keeps no promoted notice copy."
        )

        let didStartAgain = await viewModel.sendMessage("Same route again")
        XCTAssertTrue(didStartAgain)
        XCTAssertEqual(chatStartCount.count, 2)
        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "An identical mismatch after the replacement must re-show the disclosure."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testRetryReplacedTranscriptLetsTheMismatchNoticeReShow() async throws {
        // Round 3: the `/retry` transcript reload replaces `messages` wholesale.
        // Its own follow-up send is the subsequent identical mismatch.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse(
                    self.routeFixtureSessionWithTranscript(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go",
                        messagesJSON: self.replacementProbeTranscriptJSON
                    ),
                    for: request
                )
            case "/api/session/retry":
                return apiTestJSONResponse(
                    #"{"ok": true, "last_user_text": "Original question", "removed_count": 2}"#,
                    for: request
                )
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-retry-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let notice = try await pinAndPromoteMismatchNotice(streamClient, in: viewModel)

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "retry"))
        )
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chatStartCount.count, 2, "The retry path sends the recovered user text itself.")

        XCTAssertFalse(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "The reloaded transcript keeps no promoted notice copy."
        )
        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "An identical mismatch after the replacement must re-show the disclosure."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testEditReplacedTranscriptLetsTheMismatchNoticeReShow() async throws {
        // Round 3: the edit path's truncate response replaces `messages`
        // wholesale. Its own follow-up send is the subsequent identical mismatch.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse(
                    self.routeFixtureSessionWithTranscript(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go",
                        messagesJSON: self.replacementProbeTranscriptJSON
                    ),
                    for: request
                )
            case "/api/session/truncate":
                return apiTestJSONResponse(
                    """
                    {
                      "session": {
                        "session_id": "session-abc",
                        "_messages_offset": 0,
                        "messages": [
                          {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-1"},
                          {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-2"}
                        ]
                      }
                    }
                    """,
                    for: request
                )
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-edit-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let notice = try await pinAndPromoteMismatchNotice(streamClient, in: viewModel)

        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[2], visibleIndex: 2))
        let didEdit = await viewModel.editMessage(context, newText: "Edited question")
        XCTAssertTrue(didEdit)
        XCTAssertEqual(chatStartCount.count, 2, "The edit path sends the edited text itself.")

        XCTAssertFalse(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "The truncated transcript keeps no promoted notice copy."
        )
        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "An identical mismatch after the replacement must re-show the disclosure."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testRegenerateReplacedTranscriptLetsTheMismatchNoticeReShow() async throws {
        // Round 3: the regenerate path's truncate response replaces `messages`
        // wholesale. Its own follow-up send is the subsequent identical mismatch.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse(
                    self.routeFixtureSessionWithTranscript(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go",
                        messagesJSON: self.replacementProbeTranscriptJSON
                    ),
                    for: request
                )
            case "/api/session/truncate":
                return apiTestJSONResponse(
                    """
                    {
                      "session": {
                        "session_id": "session-abc",
                        "_messages_offset": 0,
                        "messages": [
                          {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-1"},
                          {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-2"},
                          {"role": "user", "content": "Original question", "timestamp": 3, "message_id": "u-3"}
                        ]
                      }
                    }
                    """,
                    for: request
                )
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-regen-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let notice = try await pinAndPromoteMismatchNotice(streamClient, in: viewModel)

        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[3], visibleIndex: 3))
        let didRegenerate = await viewModel.regenerateAssistantResponse(context)
        XCTAssertTrue(didRegenerate)
        XCTAssertEqual(chatStartCount.count, 2, "The regenerate path sends the preceding user text itself.")

        XCTAssertFalse(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "The truncated transcript keeps no promoted notice copy."
        )
        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "An identical mismatch after the replacement must re-show the disclosure."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testDoneCarriedTranscriptLetsTheMismatchNoticeReShow() async throws {
        // Round 3.5: a completed turn whose `done` frame CARRIES a transcript
        // takes `applyCompletedStreamSession`'s non-empty-messages branch, which
        // replaces `messages` via `mergingLoadedMessages` — that merge keeps only
        // local `-user` rows, so a promoted `local_notice` copy is dropped. This
        // is the fifth wholesale replacement, and without the pointer reconcile
        // the standing disclosure vanishes for good while the pointer keeps
        // suppressing every later identical mismatch.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let chatStartCount = LockedCounter()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: requestedModel,
                modelProvider: "custom:opencode-go",
                profile: "work"
            )
        ) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse(
                    self.routeFixtureSessionWithTranscript(
                        sessionRequests: sessionRequests,
                        model: requestedModel,
                        provider: "custom:opencode-go",
                        messagesJSON: self.replacementProbeTranscriptJSON
                    ),
                    for: request
                )
            case "/api/chat/start":
                let count = chatStartCount.increment()
                return apiTestJSONResponse(
                    """
                    {"session_id": "session-abc", "stream_id": "stream-done-\(count)", "effective_model": "gpt-6-astra", "effective_model_provider": "openai-codex"}
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let notice = try await pinAndPromoteMismatchNotice(streamClient, in: viewModel)
        XCTAssertEqual(chatStartCount.count, 1)

        // Drive the fifth site: the in-flight turn completes with a `done` frame
        // whose transcript cannot contain the promoted copy.
        let didStart = await viewModel.sendMessage("Same route again")
        XCTAssertTrue(didStart)
        XCTAssertEqual(chatStartCount.count, 2)

        let revisionBeforeDone = viewModel.transcriptRevision
        try await completeStreamingTurnReportingCompletedSession(
            streamClient,
            completedSessionJSON: completedSessionReportingProfileRoute(
                turn: 1,
                userText: "Same route again"
            ),
            sessionLoads: sessionRequests,
            thenDrain: viewModel
        )

        // Positive control: the path really did adopt the done-carried transcript,
        // so a silently non-firing branch fails the probe instead of passing it.
        XCTAssertTrue(
            viewModel.messages.contains { $0.messageId == "assistant-1" },
            "Positive control: the done-carried transcript must replace the transcript."
        )
        XCTAssertGreaterThan(
            viewModel.transcriptRevision,
            revisionBeforeDone,
            "Positive control: adopting the done-carried transcript bumps the revision."
        )
        XCTAssertFalse(
            viewModel.messages.contains { $0.role == "local_notice" && $0.content == notice },
            "The done-carried transcript keeps no promoted notice copy."
        )

        // The identical mismatch again must re-show the disclosure.
        let didStartAgain = await viewModel.sendMessage("Same route again")
        XCTAssertTrue(didStartAgain)
        XCTAssertEqual(chatStartCount.count, 3)
        XCTAssertEqual(
            viewModel.pinnedLocalNotices.filter { $0 == notice }.count,
            1,
            "An identical mismatch after the done-carried replacement must re-show the disclosure."
        )

        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testFreshPickerChoiceStaysExplicitAcrossCompletedSends() async throws {
        // A deliberate picker choice must carry explicit-pick intent into both
        // the first and a later fully-completed send in the same chat.
        let chatStartBodies = makeModelRouteRecorder()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: "gpt-5.4"),
            handler: { request in
                switch request.url?.path {
                case "/api/session/update":
                    return apiTestJSONResponse(
                        #"{"session": {"session_id": "session-abc", "workspace": "/tmp/workspace", "model": "deepseek-v4.1-flash", "model_provider": "custom:opencode-go", "profile": null}}"#,
                        for: request
                    )
                case "/api/reasoning":
                    return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
                case "/api/chat/start":
                    chatStartBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                    let count = chatStartBodies.all.count
                    return apiTestJSONResponse(
                        """
                        {
                          "session_id": "session-abc",
                          "stream_id": "stream-picked-\(count)"
                        }
                        """,
                        for: request
                    )
                case "/api/session":
                    return apiTestJSONResponse(
                        self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "deepseek-v4.1-flash", provider: "custom:opencode-go"),
                        for: request
                    )
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }
        )

        let didSelect = await viewModel.selectComposerModel(
            ModelCatalogOption(
                id: "deepseek-v4.1-flash",
                displayName: "DeepSeek v4.1 Flash",
                providerID: "custom:opencode-go"
            )
        )
        XCTAssertTrue(didSelect)

        let didStartFirst = await viewModel.sendMessage("Use the picked model")
        XCTAssertTrue(didStartFirst)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let didStartSecond = await viewModel.sendMessage("Continue with it")
        XCTAssertTrue(didStartSecond)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 2)
        for (index, body) in bodies.enumerated() {
            XCTAssertEqual(
                body["explicit_model_pick"] as? Bool,
                true,
                "Picker-persisted route must stay explicit on send #\(index + 1)."
            )
            XCTAssertEqual(body["model_provider"] as? String, "custom:opencode-go")
        }
    }

    @MainActor
    func testNewChatComposerDefaultsDoNotClaimExplicitPickBeforePickerUse() async throws {
        // A profile-default seed routed through the real loader is context,
        // not a deliberate pick — the false-positive control for the two
        // restored-route tests above.
        let chatStartBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: nil, modelProvider: nil, profile: "poolops"),
            handler: { request in
                switch request.url?.path {
                case "/api/profile/switch":
                    return apiTestJSONResponse(
                        """
                        {
                          "active": "poolops",
                          "default_model": "gpt-6-astra",
                          "profiles": [
                            {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true, "is_active": true}
                          ]
                        }
                        """,
                        for: request
                    )
                case "/api/models":
                    return apiTestJSONResponse(
                        """
                        {
                          "default_model": "gpt-6-astra",
                          "active_provider": "openai-codex",
                          "groups": [
                            {
                              "name": "Codex",
                              "provider_id": "openai-codex",
                              "models": [
                                {"id": "gpt-6-astra", "name": "Astra"}
                              ]
                            }
                          ]
                        }
                        """,
                        for: request
                    )
                default:
                    return try self.modelRouteTestResponse(
                        chatStartBodies: chatStartBodies,
                        streamIDPrefix: "stream-default"
                    )(request)
                }
            }
        )

        await viewModel.loadComposerConfiguration()

        let didStart = await viewModel.sendMessage("Use the profile default")
        XCTAssertTrue(didStart)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 1)
        XCTAssertNil(
            bodies.first?["explicit_model_pick"],
            "A profile-default seed is context, not a deliberate pick."
        )
        XCTAssertEqual(bodies.first?["model"] as? String, "gpt-6-astra")
    }

    @MainActor
    func testPickerChoiceThroughLoadedProfileDefaultBecomesExplicitAgain() async throws {
        // The restore-path parent test asked for: the same loaded-default
        // session, but after a deliberate picker write, sends DO carry
        // explicit intent — separate rule from the default-seed control.
        let chatStartBodies = makeModelRouteRecorder()
        let sessionRequests = makeModelRouteRecorder()
        let pickedOption = ModelCatalogOption(
            id: "deepseek-v4.1-flash",
            displayName: "DeepSeek v4.1 Flash",
            providerID: "custom:opencode-go"
        )
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: "gpt-5.4"),
            handler: { request in
                switch request.url?.path {
                case "/api/session/update":
                    return apiTestJSONResponse(
                        #"{"session": {"session_id": "session-abc", "workspace": "/tmp/workspace", "model": "deepseek-v4.1-flash", "model_provider": "custom:opencode-go", "profile": null}}"#,
                        for: request
                    )
                case "/api/reasoning":
                    return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
                case "/api/chat/start":
                    chatStartBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                    let count = chatStartBodies.all.count
                    return apiTestJSONResponse(
                        """
                        {
                          "session_id": "session-abc",
                          "stream_id": "stream-picked-\(count)"
                        }
                        """,
                        for: request
                    )
                case "/api/session":
                    return apiTestJSONResponse(
                        self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "deepseek-v4.1-flash", provider: "custom:opencode-go"),
                        for: request
                    )
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }
        )

        let didSelect = await viewModel.selectComposerModel(pickedOption)
        XCTAssertTrue(didSelect)

        let didStartFirst = await viewModel.sendMessage("Use the picked model")
        XCTAssertTrue(didStartFirst)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let didStartSecond = await viewModel.sendMessage("Keep going with it")
        XCTAssertTrue(didStartSecond)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 2)
        for (index, body) in bodies.enumerated() {
            XCTAssertEqual(
                body["explicit_model_pick"] as? Bool,
                true,
                "Picker-persisted route must stay explicit on send #\(index + 1)."
            )
            XCTAssertEqual(body["model_provider"] as? String, "custom:opencode-go")
        }
    }

    @MainActor
    func testDefaultSessionWithLoadedProfileDefaultStaysImplicitAfterSendCompletes() async throws {
        // Same loaded-profile-default fixture as the pre-send control, but the
        // assertion runs AFTER a fully-completed send: so the send itself did
        // not make the default route explicit by accident.
        let chatStartBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: nil, modelProvider: nil, profile: "poolops"),
            handler: { request in
                switch request.url?.path {
                case "/api/profile/switch":
                    return apiTestJSONResponse(
                        """
                        {
                          "active": "poolops",
                          "default_model": "gpt-6-astra",
                          "profiles": [
                            {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true, "is_active": true}
                          ]
                        }
                        """,
                        for: request
                    )
                case "/api/models":
                    return apiTestJSONResponse(
                        """
                        {
                          "default_model": "gpt-6-astra",
                          "active_provider": "openai-codex",
                          "groups": [
                            {
                              "name": "Codex",
                              "provider_id": "openai-codex",
                              "models": [
                                {"id": "gpt-6-astra", "name": "Astra"}
                              ]
                            }
                          ]
                        }
                        """,
                        for: request
                    )
                default:
                    return try self.modelRouteTestResponse(
                        chatStartBodies: chatStartBodies,
                        streamIDPrefix: "stream-default"
                    )(request)
                }
            }
        )

        await viewModel.loadComposerConfiguration()
        let didStart = await viewModel.sendMessage("Use the profile default")
        XCTAssertTrue(didStart)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 1)
        XCTAssertNil(bodies.first?["explicit_model_pick"])
    }

    @MainActor
    func testEffectiveRouteMismatchOnChatStartPinsNoticeWithoutChangingRequestedRoute() async throws {
        // Honest effective-route reporting (vertical slice to be implemented —
        // RED by design): when chat/start reports a server-resolved route that
        // differs from the requested one, the composer must surface both in a
        // pinned local notice, while requested selected model/provider stays
        // authoritative for the next send. No invented seam: asserts
        // `pinnedLocalNotices` and `selectedModelID` only.
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: requestedModel, modelProvider: "custom:opencode-go")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"""
                    {
                      "session_id": "session-abc",
                      "stream_id": "stream-effective",
                      "effective_model": "gpt-6-astra",
                      "effective_model_provider": "openai-codex"
                    }
                    """#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: "@custom:opencode-go:deepseek-v4.1-flash",
                        provider: "custom:opencode-go"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Continue with the restored route")
        XCTAssertTrue(didStart)

        try await waitUntil {
            !viewModel.pinnedLocalNotices.isEmpty
                && viewModel.pinnedLocalNotices.contains { notice in
                    notice.contains(requestedModel) && notice.contains("gpt-6-astra")
                }
        }
        // Requested route stays authoritative.
        XCTAssertEqual(viewModel.selectedModelID, requestedModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "custom:opencode-go")

        // End idle: finish the stream so no live work leaks into the next test.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testLegacyChatStartWithoutEffectiveFieldsPinsNoRouteNotice() async throws {
        // Older servers omit both effective fields: no notice, nothing to
        // disclose.
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: "gpt-5.4")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-legacy"}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "gpt-5.4", provider: nil),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Plain send")
        XCTAssertTrue(didStart)

        // The route-notice decision is made synchronously inside the send,
        // so this assertion is deterministic without fixed yields.
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")

        // End idle: finish the stream so no live work leaks into the next test.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testEffectiveRouteNoticeForStaleChatStartDoesNotOutliveNewerPickerChoice() async throws {
        // A newer picker write after an in-flight send must govern: the stale
        // mismatch notice is replaced/cleared so the composer never shows a
        // mismatch against a route the user has since chosen deliberately.
        let pickedOption = ModelCatalogOption(
            id: "gpt-6-astra",
            displayName: "Astra",
            providerID: "openai-codex"
        )
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let sessionRequests = makeModelRouteRecorder()
        // Real gate: the synchronous MockURLProtocol handler blocks its
        // loading-thread work on a semaphore (the established pattern in this
        // suite), so the chat-start reply genuinely arrives AFTER the picker
        // write below.
        let chatStartStarted = expectation(description: "chat start request started")
        let releaseChatStart = DispatchSemaphore(value: 0)
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: requestedModel, modelProvider: "custom:opencode-go")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                chatStartStarted.fulfill()
                XCTAssertEqual(releaseChatStart.wait(timeout: .now() + .seconds(5)), .success)
                return apiTestJSONResponse(
                    #"""
                    {
                      "session_id": "session-abc",
                      "stream_id": "stream-stale",
                      "effective_model": "gpt-6-astra",
                      "effective_model_provider": "openai-codex"
                    }
                    """#,
                    for: request
                )
            case "/api/session/update":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "workspace": "/tmp/workspace", "model": "gpt-6-astra", "model_provider": "openai-codex", "profile": null}}"#,
                    for: request
                )
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "gpt-6-astra", provider: "openai-codex"),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        defer { releaseChatStart.signal() }

        let sendTask = Task { await viewModel.sendMessage("In-flight send") }
        await fulfillment(of: [chatStartStarted], timeout: 2)

        // The picker must stay usable while an older chat-start request is
        // still pending; the pending reply is protected by the captured
        // selection generation, not by forbidding the pick.
        let didSelect = await viewModel.selectComposerModel(pickedOption)
        XCTAssertTrue(didSelect)

        releaseChatStart.signal()
        let didStart = await sendTask.value
        XCTAssertTrue(didStart)

        // The stale-reply suppression runs synchronously as the send
        // resolves, so these assertions are deterministic without fixed
        // yields. The requested route is what the user picked last; the
        // stale mismatch must not be presented as current.
        XCTAssertEqual(viewModel.selectedModelID, pickedOption.id)
        XCTAssertEqual(viewModel.selectedModelProviderID, pickedOption.providerID)
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)

        // End idle: finish the stream so no live work leaks into the next test.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testRestoredSameModelDifferentProviderRouteStaysExplicitAfterConfigLoad() async throws {
        // Defect: the restored-route check compared the current provider
        // against the RESTORED provider instead of the owning profile's
        // default provider, so a saved override whose model text matches the
        // profile default but runs on another provider was wrongly treated as
        // an implicit seed. The provider is part of the route.
        let chatStartBodies = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "deepseek-v4.1-flash",
                modelProvider: "custom:opencode-go",
                profile: "poolops"
            ),
            handler: { request in
                switch request.url?.path {
                case "/api/profiles":
                    return apiTestJSONResponse(
                        """
                        {
                          "active": "poolops",
                          "profiles": [
                            {"name": "poolops", "model": "deepseek-v4.1-flash", "provider": "openai-codex", "is_default": true, "is_active": true}
                          ]
                        }
                        """,
                        for: request
                    )
                case "/api/models":
                    return apiTestJSONResponse(
                        """
                        {
                          "default_model": "deepseek-v4.1-flash",
                          "active_provider": "openai-codex",
                          "groups": [
                            {
                              "name": "Codex",
                              "provider_id": "openai-codex",
                              "models": [
                                {"id": "deepseek-v4.1-flash", "name": "DeepSeek v4.1 Flash"}
                              ]
                            }
                          ]
                        }
                        """,
                        for: request
                    )
                default:
                    return try self.modelRouteTestResponse(
                        chatStartBodies: chatStartBodies,
                        streamIDPrefix: "stream-same-model"
                    )(request)
                }
            }
        )

        await viewModel.loadComposerConfiguration()
        // The session's own route survives the catalog load untouched.
        XCTAssertEqual(viewModel.selectedModelID, "deepseek-v4.1-flash")
        XCTAssertEqual(viewModel.selectedModelProviderID, "custom:opencode-go")

        let didStart = await viewModel.sendMessage("Continue with the restored route")
        XCTAssertTrue(didStart)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(
            bodies.first?["explicit_model_pick"] as? Bool,
            true,
            "Same model text on a provider other than the profile default's is an override, not the default seed."
        )
        XCTAssertEqual(bodies.first?["model"] as? String, "deepseek-v4.1-flash")
        XCTAssertEqual(bodies.first?["model_provider"] as? String, "custom:opencode-go")
    }

    @MainActor
    func testNewSessionSlashCommandKeepsOldViewModelRouteIntent() async throws {
        // The /new action creates a session for the parent to navigate to. If
        // that navigation fails or is never adopted, THIS view model is still
        // live — its picker-established intent must not have been cleared as
        // a side effect of creating the other session.
        let chatStartBodies = makeModelRouteRecorder()
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: "gpt-5.4"),
            handler: { request in
                switch request.url?.path {
                case "/api/session/update":
                    return apiTestJSONResponse(
                        #"{"session": {"session_id": "session-abc", "workspace": "/tmp/workspace", "model": "gpt-5.5", "model_provider": "openai", "profile": null}}"#,
                        for: request
                    )
                case "/api/reasoning":
                    return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
                case "/api/session/new":
                    return apiTestJSONResponse(
                        #"{"session": {"session_id": "session-new", "workspace": "/tmp/workspace", "model": "gpt-5.5", "model_provider": "openai", "messages": []}}"#,
                        for: request
                    )
                case "/api/chat/start":
                    chatStartBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                    return apiTestJSONResponse(
                        #"{"session_id": "session-abc", "stream_id": "stream-old-vm"}"#,
                        for: request
                    )
                case "/api/session":
                    return apiTestJSONResponse(
                        self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "gpt-5.5", provider: "openai"),
                        for: request
                    )
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }
        )

        let didSelect = await viewModel.selectComposerModel(
            ModelCatalogOption(id: "gpt-5.5", displayName: "GPT 5.5", providerID: "openai")
        )
        XCTAssertTrue(didSelect)

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "new"))
        )
        guard case .openedSession = result else {
            XCTFail("Expected the new session to be returned for navigation, got \(result).")
            return
        }

        // Navigation not adopted: the old view model keeps sending, and its
        // pick must still be explicit.
        let didStart = await viewModel.sendMessage("Still on the old session")
        XCTAssertTrue(didStart)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(
            bodies.first?["explicit_model_pick"] as? Bool,
            true,
            "Creating a new session must not clear route intent on the old view model."
        )
        XCTAssertEqual(bodies.first?["model"] as? String, "gpt-5.5")
        XCTAssertEqual(bodies.first?["model_provider"] as? String, "openai")
    }

    @MainActor
    func testEffectiveRouteEqualCanonicalSpellingPinsNoNotice() async throws {
        // The server resolving the SAME route under a different spelling
        // (`@provider:` prefix carried in the model id instead of the
        // provider field) is not a mismatch: no warning.
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: "deepseek-v4.1-flash", modelProvider: "custom:opencode-go")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"""
                    {
                      "session_id": "session-abc",
                      "stream_id": "stream-equal",
                      "effective_model": "@custom:opencode-go:deepseek-v4.1-flash"
                    }
                    """#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "deepseek-v4.1-flash", provider: "custom:opencode-go"),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Plain send")
        XCTAssertTrue(didStart)

        // The route-notice decision is made synchronously inside the send.
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertEqual(viewModel.selectedModelID, "deepseek-v4.1-flash")
        XCTAssertEqual(viewModel.selectedModelProviderID, "custom:opencode-go")

        // End idle: finish the stream so no live work leaks into the next test.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testEffectiveRouteNoticeClearsWhenLaterStartConfirmsRequestedRoute() async throws {
        // Lifecycle: a mismatch notice from one start is cleared by a later
        // non-stale start whose effective route matches the requested one —
        // and only THIS feature's notice is removed; unrelated pinned notices
        // survive.
        let chatStartBodies = makeModelRouteRecorder()
        let sessionRequests = makeModelRouteRecorder()
        let requestedModel = "@custom:opencode-go:deepseek-v4.1-flash"
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: requestedModel, modelProvider: "custom:opencode-go")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                chatStartBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                let count = chatStartBodies.all.count
                if count == 1 {
                    return apiTestJSONResponse(
                        #"""
                        {
                          "session_id": "session-abc",
                          "stream_id": "stream-mismatch",
                          "effective_model": "gpt-6-astra",
                          "effective_model_provider": "openai-codex"
                        }
                        """#,
                        for: request
                    )
                }
                return apiTestJSONResponse(
                    #"""
                    {
                      "session_id": "session-abc",
                      "stream_id": "stream-confirmed",
                      "effective_model": "@custom:opencode-go:deepseek-v4.1-flash",
                      "effective_model_provider": "custom:opencode-go"
                    }
                    """#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(
                        sessionRequests: sessionRequests,
                        model: "@custom:opencode-go:deepseek-v4.1-flash",
                        provider: "custom:opencode-go"
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartFirst = await viewModel.sendMessage("First send")
        XCTAssertTrue(didStartFirst)
        XCTAssertEqual(viewModel.pinnedLocalNotices.count, 1)
        XCTAssertTrue(viewModel.pinnedLocalNotices.first?.contains("gpt-6-astra") == true)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        viewModel.pinLocalNoticeMessage("Unrelated note.")

        let didStartSecond = await viewModel.sendMessage("Second send")
        XCTAssertTrue(didStartSecond)

        XCTAssertEqual(
            viewModel.pinnedLocalNotices,
            ["Unrelated note."],
            "The confirmed start clears only this feature's own outdated notice."
        )
        XCTAssertEqual(viewModel.selectedModelID, requestedModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "custom:opencode-go")

        // End idle: finish the second stream so no live work (or queued
        // transcript reload) leaks into the next test's handler.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testMalformedEffectiveFieldsPinNoNotice() async throws {
        // A malformed effective_model (wrong JSON type) decodes lossily to
        // nil: no crash, no notice, no invented route.
        let sessionRequests = makeModelRouteRecorder()
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(model: "gpt-5.4")
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-malformed", "effective_model": {"nested": true}, "effective_model_provider": 42}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    self.modelRouteSessionReloadJSON(sessionRequests: sessionRequests, model: "gpt-5.4", provider: nil),
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Plain send")
        XCTAssertTrue(didStart)

        // The lossy decode runs synchronously inside the send.
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")

        // End idle: finish the stream so no live work leaks into the next test.
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)
    }

    @MainActor
    func testProfileRoundTripDoesNotResurrectRestoredRouteIntent() async throws {
        // Switching profiles drops the restored session's route intent (the
        // new default is a seed). Switching BACK must not resurrect the old
        // override: the round trip leaves the profile-default seed implicit.
        let chatStartBodies = makeModelRouteRecorder()
        let profileSwitches = makeModelRouteRecorder()
        let profilesLoads = makeModelRouteRecorder()
        // Keep title-generation state across both turns, not one factory per request.
        let fallbackHandler = modelRouteTestResponse(
            chatStartBodies: chatStartBodies,
            streamIDPrefix: "stream-roundtrip"
        )
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: try makeSession(
                model: "@custom:opencode-go:deepseek-v4.1-flash",
                modelProvider: "custom:opencode-go",
                profile: "poolops"
            ),
            handler: { request in
                switch request.url?.path {
                case "/api/profile/switch":
                    profileSwitches.append([:])
                    if profileSwitches.all.count == 1 {
                        return apiTestJSONResponse(
                            """
                            {
                              "active": "research",
                              "default_model": "gpt-4o-mini",
                              "profiles": [
                                {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true},
                                {"name": "research", "model": "gpt-4o-mini", "provider": "openai-codex", "is_active": true}
                              ]
                            }
                            """,
                            for: request
                        )
                    }
                    return apiTestJSONResponse(
                        """
                        {
                          "active": "poolops",
                          "default_model": "gpt-6-astra",
                          "profiles": [
                            {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true, "is_active": true},
                            {"name": "research", "model": "gpt-4o-mini", "provider": "openai-codex"}
                          ]
                        }
                        """,
                        for: request
                    )
                case "/api/profiles":
                    profilesLoads.append([:])
                    let active = profilesLoads.all.count == 1 ? "research" : "poolops"
                    return apiTestJSONResponse(
                        """
                        {
                          "active": "\(active)",
                          "profiles": [
                            {"name": "poolops", "model": "gpt-6-astra", "provider": "openai-codex", "is_default": true},
                            {"name": "research", "model": "gpt-4o-mini", "provider": "openai-codex"}
                          ]
                        }
                        """,
                        for: request
                    )
                case "/api/models":
                    return apiTestJSONResponse(
                        """
                        {
                          "default_model": "gpt-6-astra",
                          "active_provider": "openai-codex",
                          "groups": [
                            {
                              "name": "Codex",
                              "provider_id": "openai-codex",
                              "models": [
                                {"id": "gpt-6-astra", "name": "Astra"},
                                {"id": "gpt-4o-mini", "name": "Mini"}
                              ]
                            }
                          ]
                        }
                        """,
                        for: request
                    )
                default:
                    return try fallbackHandler(request)
                }
            }
        )

        let researchProfile = ProfileSummary(
            name: "research", path: nil, isDefault: nil, isActive: nil,
            gatewayRunning: nil, model: "gpt-4o-mini", provider: "openai-codex",
            hasEnv: nil, skillCount: nil
        )
        let poolopsProfile = ProfileSummary(
            name: "poolops", path: nil, isDefault: true, isActive: nil,
            gatewayRunning: nil, model: "gpt-6-astra", provider: "openai-codex",
            hasEnv: nil, skillCount: nil
        )

        let firstOutcome = await viewModel.switchProfile(researchProfile, startNewSession: false)
        XCTAssertNotNil(firstOutcome)
        let didStartFirst = await viewModel.sendMessage("Send on the research default")
        XCTAssertTrue(didStartFirst)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let secondOutcome = await viewModel.switchProfile(poolopsProfile, startNewSession: false)
        XCTAssertNotNil(secondOutcome)
        let didStartSecond = await viewModel.sendMessage("Send back on the poolops default")
        XCTAssertTrue(didStartSecond)
        try await completeStreamingTurn(streamClient, thenDrain: viewModel)

        let bodies = chatStartBodies.all
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["model"] as? String, "gpt-4o-mini")
        XCTAssertNil(
            bodies[0]["explicit_model_pick"],
            "A profile default after a switch is a seed, not a pick."
        )
        XCTAssertEqual(bodies[1]["model"] as? String, "gpt-6-astra")
        XCTAssertNil(
            bodies[1]["explicit_model_pick"],
            "The round trip must not resurrect the old restored override's intent."
        )
    }

    /// Reference-type recorder for chat-start request bodies captured from
    /// MockURLProtocol's loading thread. `requestHandler` closures cannot
    /// capture a `var` array mutated after the closure was built (the value
    /// would be copied), so body records funnel through this box instead.
    private final class NSLockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String: Any]] = []

        func append(_ body: [String: Any]) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(body)
        }

        var all: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Lets a `Task { @MainActor … }` enqueued by a delegate callback run to completion
    /// before assertions. Same-actor tasks run FIFO, so awaiting a task enqueued *after*
    /// the callback's drains it; the leading yields add slack.
    @MainActor
    private func drainMainActor() async {
        for _ in 0..<3 { await Task.yield() }
        await Task { @MainActor in }.value
    }

    /// A `503 {"error": ...}` for `/api/tts` — the canonical "server TTS refused,
    /// use the on-device fallback" stimulus for Listen tests (#15).
    // MARK: - Skill slash suggestions

    /// The composer asks for the skill list from `.task` modifiers that SwiftUI
    /// cancels on an unrelated view update — the chip warm-up for a restored
    /// draft is keyed on the draft itself, so hydrating one cancels it. The
    /// request used to run inside the caller, so that cancellation threw it away
    /// and left a draft's `/skill` references drawn as plain text.
    @MainActor
    func testCancellingACallerDoesNotAbortTheSkillLoad() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            return apiTestJSONResponse(#"{"skills": [{"name": "handoff"}]}"#, for: request)
        }

        let caller = Task { await viewModel.loadSkillSlashSuggestions() }
        caller.cancel()
        await caller.value

        XCTAssertEqual(viewModel.skillSlashSuggestions.map(\.slashName), ["handoff"])
    }

    /// A load that fails leaves nothing behind, so the next caller retries
    /// rather than being told the list is already loaded.
    @MainActor
    func testAFailedSkillLoadIsRetriedByTheNextCaller() async throws {
        var attempts = 0
        let viewModel = try makeViewModel { request in
            attempts += 1
            guard attempts > 1 else {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return apiTestJSONResponse(#"{"skills": [{"name": "handoff"}]}"#, for: request)
        }

        await viewModel.loadSkillSlashSuggestions()
        XCTAssertTrue(viewModel.skillSlashSuggestions.isEmpty)

        await viewModel.loadSkillSlashSuggestions()
        XCTAssertEqual(viewModel.skillSlashSuggestions.map(\.slashName), ["handoff"])
        XCTAssertEqual(attempts, 2)
    }

    // MARK: - Personality slash suggestions

    /// The personality list is loaded from the same kind of `.task` modifier as
    /// the skill list, so it needs the same protection (#387): a caller SwiftUI
    /// cancels must not take the shared fetch down with it and leave the
    /// personality picker permanently empty.
    @MainActor
    func testCancellingACallerDoesNotAbortThePersonalityLoad() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/personalities")
            return apiTestJSONResponse(#"{"personalities": [{"name": "mentor"}]}"#, for: request)
        }

        let caller = Task { await viewModel.loadPersonalitySuggestions() }
        caller.cancel()
        await caller.value

        XCTAssertEqual(viewModel.personalitySuggestions, ["none", "mentor"])
    }

    /// A load that fails leaves nothing behind, so the next caller retries
    /// rather than awaiting the finished, empty-handed task.
    @MainActor
    func testAFailedPersonalityLoadIsRetriedByTheNextCaller() async throws {
        var attempts = 0
        let viewModel = try makeViewModel { request in
            attempts += 1
            guard attempts > 1 else {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return apiTestJSONResponse(#"{"personalities": [{"name": "mentor"}]}"#, for: request)
        }

        await viewModel.loadPersonalitySuggestions()
        XCTAssertEqual(viewModel.personalitySuggestions, ["none"])

        await viewModel.loadPersonalitySuggestions()
        XCTAssertEqual(viewModel.personalitySuggestions, ["none", "mentor"])
        XCTAssertEqual(attempts, 2)
    }

    /// The point of the shared handle: a caller arriving mid-flight joins the
    /// request already running instead of firing its own and returning early
    /// with an empty list. The mock holds the response open until the second
    /// caller has arrived, so it really does land on the in-flight branch.
    @MainActor
    func testAConcurrentCallerJoinsTheInFlightPersonalityLoad() async throws {
        let requestStarted = XCTestExpectation(description: "personality request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        var attempts = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/personalities")
            attempts += 1
            requestStarted.fulfill()
            // Bounded so a second, unshared request fails the count assertion
            // below instead of hanging the test.
            _ = releaseResponse.wait(timeout: .now() + 5)
            return apiTestJSONResponse(#"{"personalities": [{"name": "mentor"}]}"#, for: request)
        }

        let first = Task { await viewModel.loadPersonalitySuggestions() }
        await fulfillment(of: [requestStarted], timeout: 5)

        let second = Task { await viewModel.loadPersonalitySuggestions() }
        await Task.yield()
        releaseResponse.signal()

        await first.value
        await second.value

        XCTAssertEqual(viewModel.personalitySuggestions, ["none", "mentor"])
        XCTAssertEqual(attempts, 1)
    }

    /// Sent references become chips the moment the catalog lands, and a chip is
    /// not the size of the `/slug` it replaces, so the transcript has to be told
    /// it just re-laid out under the reader (#388).
    @MainActor
    func testTheFirstSkillCatalogSignalsATranscriptRelayout() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            return apiTestJSONResponse(#"{"skills": [{"name": "handoff"}]}"#, for: request)
        }

        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 0)
        XCTAssertTrue(viewModel.skillChipCatalog.isEmpty)

        await viewModel.loadSkillSlashSuggestions()

        XCTAssertEqual(viewModel.skillChipCatalog.label(forSlug: "handoff"), "handoff")
        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 1)
    }

    /// A server with no skills leaves the transcript exactly as it was drawn, so
    /// it must not claim a relayout. Covers the general rule too: a catalog that
    /// came back unchanged says nothing.
    @MainActor
    func testAnEmptySkillListDoesNotSignalARelayout() async throws {
        let viewModel = try makeViewModel { request in
            apiTestJSONResponse(#"{"skills": []}"#, for: request)
        }

        await viewModel.loadSkillSlashSuggestions()
        await viewModel.loadSkillSlashSuggestions()

        XCTAssertTrue(viewModel.skillChipCatalog.isEmpty)
        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 0)
    }

    // MARK: - Workspace file references (`@path`)

    /// `.` holds `a/`; `a/` holds `b.md` and `c.md`.
    private func fileListingJSON(for path: String) -> String? {
        switch path {
        case ".":
            return #"{"path": ".", "entries": [{"name": "a", "path": "a", "type": "dir", "is_dir": true}]}"#
        case "a":
            return #"{"path": "a", "entries": [{"name": "b.md", "path": "a/b.md", "type": "file"}, {"name": "c.md", "path": "a/c.md", "type": "file"}]}"#
        default:
            return nil
        }
    }

    private func listedPath(in request: URLRequest) -> String {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first { $0.name == "path" }?.value ?? "."
    }

    /// What the composer picked dies with the view model, so a chat re-entered
    /// from the session list has to ask the server whether a `@word` in the
    /// restored draft is really a file before it can draw the chip again.
    @MainActor
    func testARestoredDraftReferenceIsConfirmedAgainstTheWorkspace() async throws {
        let listed = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            XCTAssertEqual(request.url?.path, "/api/list")
            let path = listedPath(in: request)
            listed.append(path)
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        XCTAssertFalse(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))

        await viewModel.loadFileChipReferences(draft: "read @a/b.md please")

        XCTAssertEqual(listed.values, ["a"])
        XCTAssertTrue(viewModel.fileChipPaths.contains("a/b.md"))
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 1)
    }

    /// A `@word` the folder does not hold stays plain text, and the answer
    /// sticks: it must not cost a listing on every later transcript update.
    @MainActor
    func testACandidateItsFolderDoesNotHoldIsNeverDrawnAsAChip() async throws {
        let listed = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            let path = listedPath(in: request)
            listed.append(path)
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        await viewModel.loadFileChipReferences(draft: "see @a/missing.md now")
        await viewModel.loadFileChipReferences(draft: "see @a/missing.md now")

        XCTAssertEqual(listed.values, ["a"])
        XCTAssertFalse(viewModel.composerChipCatalog.containsFile(path: "a/missing.md"))
        XCTAssertEqual(viewModel.transcriptRelayoutScrollToken, 0)
    }

    @MainActor
    func testTwoReferencesInOneFolderCostOneListing() async throws {
        let listed = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            let path = listedPath(in: request)
            listed.append(path)
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        await viewModel.loadFileChipReferences(draft: "@a/b.md and @a/c.md together")

        XCTAssertEqual(listed.values, ["a"])
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/c.md"))
    }

    /// The confirmation lives on a task the view model owns, so a caller
    /// cancelled by an unrelated view update cannot take the listing down with
    /// it — and the next caller finds the answer rather than asking again.
    @MainActor
    func testACancelledCallerDoesNotCancelTheConfirmation() async throws {
        let listed = LockedStrings()
        let listingStarted = expectation(description: "listing started")
        let releaseListing = DispatchSemaphore(value: 0)

        let viewModel = try makeViewModel { [self] request in
            let path = listedPath(in: request)
            listed.append(path)
            listingStarted.fulfill()
            releaseListing.wait()
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        let cancelled = Task { await viewModel.loadFileChipReferences(draft: "@a/b.md here") }
        await fulfillment(of: [listingStarted], timeout: 5)
        cancelled.cancel()
        releaseListing.signal()

        await viewModel.loadFileChipReferences(draft: "@a/b.md here")

        XCTAssertEqual(listed.values, ["a"])
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
    }

    /// A listing that failed is not an answer, so the candidate stays open and
    /// the next pass asks again.
    @MainActor
    func testAFailedListingIsRetriedByTheNextCaller() async throws {
        let attempts = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            let path = listedPath(in: request)
            attempts.append(path)
            if attempts.values.count == 1 {
                return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
            }
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        await viewModel.loadFileChipReferences(draft: "@a/b.md here")
        XCTAssertFalse(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))

        await viewModel.loadFileChipReferences(draft: "@a/b.md here")

        XCTAssertEqual(attempts.values, ["a", "a"])
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
    }

    /// The sent bubble draws from the same catalog, so a reference that only
    /// exists in the loaded transcript has to be confirmed too.
    @MainActor
    func testASentMessageReferenceIsConfirmedAfterTheTranscriptLoads() async throws {
        let viewModel = try makeViewModel { [self] request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "look at @a/b.md",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            case "/api/list":
                let path = listedPath(in: request)
                return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        await viewModel.loadFileChipReferences(draft: "")

        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
    }

    /// A path the panel just offered is a chip immediately: the listing that
    /// produced the row is the same answer a confirmation pass would get.
    @MainActor
    func testAPickedPathIsNeverRecheckedAgainstTheServer() async throws {
        let listed = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            let path = listedPath(in: request)
            listed.append(path)
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        viewModel.recordFileChipReference("a/b.md")
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))

        await viewModel.loadFileChipReferences(draft: "@a/b.md here")

        XCTAssertTrue(listed.values.isEmpty)
    }

    /// A path is only a file inside the workspace it was found in, so switching
    /// the session's workspace has to take every confirmed chip with it —
    /// including one accepted straight from the panel — and ask again.
    @MainActor
    func testAWorkspaceChangeDropsConfirmedFileChipsAndAsksAgain() async throws {
        let listed = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            guard request.url?.path == "/api/list" else {
                return apiTestJSONResponse(#"""
                {"session": {"session_id": "session-abc", "workspace": "/tmp/other", "model": "gpt-5.4"}}
                """#, for: request)
            }
            let path = listedPath(in: request)
            listed.append(path)
            return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
        }

        await viewModel.loadFileChipReferences(draft: "@a/b.md here")
        viewModel.recordFileChipReference("a/c.md")
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/c.md"))
        let scopeBefore = viewModel.fileChipScopeRevision

        await viewModel.selectWorkspacePath("/tmp/other")

        XCTAssertTrue(viewModel.fileChipPaths.isEmpty)
        XCTAssertFalse(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
        XCTAssertFalse(viewModel.composerChipCatalog.containsFile(path: "a/c.md"))
        XCTAssertGreaterThan(viewModel.fileChipScopeRevision, scopeBefore)

        await viewModel.loadFileChipReferences(draft: "@a/b.md here")

        // The folder is listed again rather than answered from a cache filled
        // against the old root.
        XCTAssertEqual(listed.values, ["a", "a"])
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
    }

    /// A pass still listing the old workspace's folders when the workspace moves
    /// is cancelled outright: it stops before the next folder, settles nothing,
    /// and the candidates are asked again under the new root.
    @MainActor
    func testAWorkspaceChangeCancelsTheConfirmationPassInFlight() async throws {
        let listed = LockedStrings()
        let listingStarted = expectation(description: "first listing started")
        let releaseListing = DispatchSemaphore(value: 0)

        let viewModel = try makeViewModel { [self] request in
            guard request.url?.path == "/api/list" else {
                return apiTestJSONResponse(#"""
                {"session": {"session_id": "session-abc", "workspace": "/tmp/other", "model": "gpt-5.4"}}
                """#, for: request)
            }

            let path = listedPath(in: request)
            listed.append(path)
            if listed.values.count == 1 {
                listingStarted.fulfill()
                releaseListing.wait()
            }
            return apiTestJSONResponse(
                #"{"path": "\#(path)", "entries": [{"name": "b.md", "path": "\#(path)/b.md", "type": "file"}]}"#,
                for: request
            )
        }

        let draft = "@a/b.md and @e/b.md here"
        let stale = Task { await viewModel.loadFileChipReferences(draft: draft) }
        await fulfillment(of: [listingStarted], timeout: 5)

        // Moves `currentWorkspace` synchronously, before its own request goes out.
        await viewModel.selectWorkspacePath("/tmp/other")
        releaseListing.signal()
        await stale.value

        // Stopped between folders: `e` was never asked for, and `a`'s listing
        // arrived after the reset so it settled nothing.
        XCTAssertEqual(listed.values, ["a"])
        XCTAssertTrue(viewModel.fileChipPaths.isEmpty)

        await viewModel.loadFileChipReferences(draft: draft)

        XCTAssertEqual(listed.values, ["a", "a", "e"])
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "e/b.md"))
    }

    /// Every folder the candidates name is answered, a batch at a time, rather
    /// than the first batch and silence for the rest.
    @MainActor
    func testEveryFolderIsAnsweredBeyondOneBatch() async throws {
        let folders = (0..<25).map { "d\($0)" }
        let listed = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            let path = listedPath(in: request)
            listed.append(path)
            return apiTestJSONResponse(
                #"{"path": "\#(path)", "entries": [{"name": "f.md", "path": "\#(path)/f.md", "type": "file"}]}"#,
                for: request
            )
        }

        let draft = folders.map { "@\($0)/f.md" }.joined(separator: " ") + " done"
        await viewModel.loadFileChipReferences(draft: draft)

        XCTAssertEqual(listed.values, folders)
        for folder in folders {
            XCTAssertTrue(
                viewModel.composerChipCatalog.containsFile(path: "\(folder)/f.md"),
                "\(folder)/f.md was never confirmed"
            )
        }
    }

    /// A cache-first transcript swapped for the server's copy can rewrite a
    /// message in the middle of the list without changing the count or the last
    /// id, so the swap itself has to be the signal.
    @MainActor
    func testReplacingAMiddleUserMessageIsRescanned() async throws {
        let loads = LockedStrings()
        let viewModel = try makeViewModel { [self] request in
            switch request.url?.path {
            case "/api/session":
                loads.append("session")
                let firstUserContent = loads.values.count == 1 ? "hello" : "look at @a/b.md"
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {"role": "user", "content": "\(firstUserContent)", "timestamp": 1770000100, "message_id": "user-1"},
                      {"role": "assistant", "content": "sure", "timestamp": 1770000101, "message_id": "assistant-1"},
                      {"role": "user", "content": "thanks", "timestamp": 1770000102, "message_id": "user-2"}
                    ]
                  }
                }
                """, for: request)
            case "/api/list":
                let path = listedPath(in: request)
                return apiTestJSONResponse(try XCTUnwrap(fileListingJSON(for: path)), for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        await viewModel.loadFileChipReferences(draft: "")
        let revisionBefore = viewModel.transcriptRevision
        XCTAssertFalse(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.count, 3)
        XCTAssertEqual(viewModel.messages.last?.messageId, "user-2")
        XCTAssertGreaterThan(viewModel.transcriptRevision, revisionBefore)

        await viewModel.loadFileChipReferences(draft: "")

        XCTAssertTrue(viewModel.composerChipCatalog.containsFile(path: "a/b.md"))
    }

    private static func ttsUnavailableResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(#"{"error": "TTS engine unavailable"}"#.utf8))
    }

    private func makeEphemeralUserDefaults() throws -> UserDefaults {
        let suiteName = "HermesMobileTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @MainActor
    private func makeViewModel(
        streamClient: SSEStreamingClient? = nil,
        approvalStreamClient: SSEStreamingClient? = nil,
        clarifyStreamClient: SSEStreamingClient? = nil,
        sessionSummary: SessionSummary? = nil,
        liveActivityManager: (any AgentLiveActivityManaging)? = nil,
        pollingIntervals: ChatPollingIntervals = .standard,
        steeringConfirmationDismissDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        },
        streamingScrollCoalescingDelayNanoseconds: UInt64 = 16_000_000,
        speechSynthesizerFactory: @escaping () -> any ChatSpeechSynthesizing = { AVSpeechSynthesizer() },
        listenAudioSession: (any ListenAudioSessionControlling)? = nil,
        listenRemoteControlCenter: (any ListenRemoteControlControlling)? = nil,
        serverTTSAudioPlayerFactory: (@MainActor (Data) throws -> any ListenAudioPlaying)? = nil,
        draftAttachmentStore: any ChatDraftAttachmentStoring = RecordingSendDraftAttachmentStore(),
        userDefaults: UserDefaults = .standard,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)
        let summary: SessionSummary
        if let sessionSummary {
            summary = sessionSummary
        } else {
            summary = try makeSession()
        }

        let resolvedStreamClient = streamClient ?? SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: resolvedStreamClient,
            approvalStreamClient: approvalStreamClient ?? SpySSEStreamingClient(),
            clarifyStreamClient: clarifyStreamClient ?? SpySSEStreamingClient(),
            liveActivityManager: liveActivityManager,
            pollingIntervals: pollingIntervals,
            steeringConfirmationDismissDelay: steeringConfirmationDismissDelay,
            streamingScrollCoalescingDelayNanoseconds: streamingScrollCoalescingDelayNanoseconds,
            speechSynthesizerFactory: speechSynthesizerFactory,
            // Default to a spy so unit tests never drive the live shared AVAudioSession.
            listenAudioSession: listenAudioSession ?? SpyListenAudioSession(),
            listenRemoteControlCenter: listenRemoteControlCenter ?? SpyListenRemoteControlCenter(),
            serverTTSAudioPlayerFactory: serverTTSAudioPlayerFactory,
            draftAttachmentStore: draftAttachmentStore,
            userDefaults: userDefaults
        )

        if let spyStreamClient = resolvedStreamClient as? SpySSEStreamingClient {
            spyStreamClient.flushPendingStreamingContent = { [weak viewModel] in
                viewModel?.flushPendingStreamingContent()
            }
        }

        return viewModel
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runMainActorTest(
        timeout: TimeInterval = 5,
        _ body: @escaping @MainActor () async throws -> Void
    ) {
        let expectation = expectation(description: "MainActor async test")
        Task { @MainActor in
            defer { expectation.fulfill() }

            do {
                try await body()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [expectation], timeout: timeout)
    }

    private func makeSession(
        title: String = "Planning",
        model: String? = "gpt-5.4",
        modelProvider: String? = nil,
        profile: String? = nil
    ) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let modelJSON = model.map { ",\n              \"model\": \"\($0)\"" } ?? ""
        let modelProviderJSON = modelProvider.map { ",\n              \"model_provider\": \"\($0)\"" } ?? ""
        let profileJSON = profile.map { ",\n              \"profile\": \"\($0)\"" } ?? ""
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "\(title)",
              "workspace": "/tmp/workspace"\(modelJSON)\(modelProviderJSON)\(profileJSON)
            }
            """.utf8)
        )
    }

    private func makeSessionDetail(_ json: String) throws -> SessionDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: Data(json.utf8))
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func makeJPEGData(size: CGSize) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }

        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func maxPixelDimension(in data: Data) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        return max(width, height)
    }

    @MainActor
    func testLiveStreamContentCoalescesRapidTokenUpdates() async throws {
        let streamClient = SpySSEStreamingClient()
        streamClient.automaticallyFlushPendingStreamingContent = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse("""
            {
              "session_id": "session-abc",
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let didStart = await viewModel.sendMessage("Stream a long response")
        XCTAssertTrue(didStart)

        for index in 0..<25 {
            streamClient.emit(.token("chunk-\(index)"))
        }

        try await waitForStreamingContent(
            viewModel,
            toSatisfy: { $0 == (0..<25).map { "chunk-\($0)" }.joined() }
        )
    }

    @MainActor
    private func waitForStreamingContent(
        _ viewModel: ChatViewModel,
        toSatisfy predicate: (String?) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if predicate(viewModel.messages.last?.content) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(
            predicate(viewModel.messages.last?.content),
            file: file,
            line: line
        )
    }
}

/// Every request path a handler was asked for, in call order. Handlers run
/// off the test's thread, so the record needs its own lock.
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }

        stored.append(value)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }

        return stored
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }

        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return value
    }
}

@MainActor
private final class SpyChatLiveActivityManager: AgentLiveActivityManaging {
    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var ends: [End] = []

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {}

    func update(_ event: AgentLiveActivityEvent) {}

    func markStale() {}

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}

/// Shared, interleaved call log so tests can prove ordering ACROSS the audio-session
/// spy and the speech-synthesizer spy in one timeline — not two independent logs.
private final class ListenCallRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private final class SpySpeechSynthesizer: ChatSpeechSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    private(set) var spokenStrings: [String] = []
    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private let recorder: ListenCallRecorder?

    init(recorder: ListenCallRecorder? = nil) {
        self.recorder = recorder
    }

    func speak(_ utterance: AVSpeechUtterance) {
        spokenStrings.append(utterance.speechString)
        spokenUtterances.append(utterance)
        isSpeaking = true
        recorder?.record("speak")
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopBoundaries.append(boundary)
        isSpeaking = false
        isPaused = false
        return true
    }

    /// Drives the production delegate's `didCancel` exactly as `AVSpeechSynthesizer`
    /// would after `stopSpeaking(at:)` — late, via the delegate's `@MainActor` hop. The
    /// delegate ignores the synthesizer argument, so a throwaway instance is fine.
    func fireDidCancel(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }
}

private actor RecordingSendDraftAttachmentStore: ChatDraftAttachmentStoring {
    private var nextFileNumber = 1
    private var deletedFileNames: [String] = []

    func save(data: Data, suggestedFilename: String) async throws -> String {
        let fileName = "saved-\(nextFileNumber)-\(URL(fileURLWithPath: suggestedFilename).lastPathComponent)"
        nextFileNumber += 1
        return fileName
    }

    func data(named fileName: String) async throws -> Data {
        Data()
    }

    func delete(named fileName: String) async {
        deletedFileNames.append(fileName)
    }

    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {}

    func deletedNames() -> [String] {
        deletedFileNames
    }
}

@MainActor
private final class SpyListenAudioPlayer: ListenAudioPlaying {
    var onFinish: (@MainActor () -> Void)?
    var playResult = true
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 75
    var rate: Float = 1
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var prepareToPlayCount = 0

    func prepareToPlay() {
        prepareToPlayCount += 1
    }

    func play() -> Bool {
        playCount += 1
        return playResult
    }

    func pause() {
        pauseCount += 1
    }

    func stop() {
        stopCount += 1
    }

    /// Simulates the wrapped `AVAudioPlayer` finishing naturally.
    func finishPlayback() {
        onFinish?()
    }
}

@MainActor
private final class SpyListenAudioSession: ListenAudioSessionControlling {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private let recorder: ListenCallRecorder?

    init(recorder: ListenCallRecorder? = nil) {
        self.recorder = recorder
    }

    func activate() {
        activateCount += 1
        recorder?.record("activate")
    }

    func deactivate() {
        deactivateCount += 1
        recorder?.record("deactivate")
    }
}

@MainActor
private final class SpyListenRemoteControlCenter: ListenRemoteControlControlling {
    private(set) var configureCount = 0
    private(set) var clearCount = 0
    private(set) var snapshots: [ListenNowPlayingSnapshot] = []
    private var playHandler: (@MainActor () -> Void)?
    private var pauseHandler: (@MainActor () -> Void)?
    private var togglePlayPauseHandler: (@MainActor () -> Void)?
    private var changePlaybackPositionHandler: (@MainActor (TimeInterval) -> Void)?

    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    ) {
        configureCount += 1
        playHandler = play
        pauseHandler = pause
        togglePlayPauseHandler = togglePlayPause
        changePlaybackPositionHandler = changePlaybackPosition
    }

    func update(_ snapshot: ListenNowPlayingSnapshot) {
        snapshots.append(snapshot)
    }

    func clear() {
        clearCount += 1
        snapshots.removeAll()
    }

    func firePlay() {
        playHandler?()
    }

    func firePause() {
        pauseHandler?()
    }

    func fireTogglePlayPause() {
        togglePlayPauseHandler?()
    }

    func fireChangePlaybackPosition(_ position: TimeInterval) {
        changePlaybackPositionHandler?(position)
    }
}

private final class SpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?
    var automaticallyFlushPendingStreamingContent = true
    var flushPendingStreamingContent: (() -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(_ event: SSEEvent, lastEventID: String? = nil) {
        self.lastEventID = lastEventID
        onEvent?(event)
        if automaticallyFlushPendingStreamingContent {
            flushPendingStreamingContent?()
        }
    }
}

private actor ManualAsyncDelay {
    private var waiters: [UnsafeContinuation<Void, Never>] = []
    private var registrationCount = 0
    private var registrationObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async {
        await withUnsafeContinuation { continuation in
            waiters.append(continuation)
            registrationCount += 1
            resumeSatisfiedRegistrationObservers()
        }
    }

    func waitForRegistrationCount(_ expectedCount: Int) async {
        guard registrationCount < expectedCount else { return }

        await withCheckedContinuation { continuation in
            registrationObservers.append((expectedCount, continuation))
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    private func resumeSatisfiedRegistrationObservers() {
        let satisfied = registrationObservers.filter { $0.count <= registrationCount }
        registrationObservers.removeAll { $0.count <= registrationCount }
        for observer in satisfied {
            observer.continuation.resume()
        }
    }
}
