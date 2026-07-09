import XCTest
import AVFoundation
import ImageIO
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
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read PROJECT_SPEC.md",
            args: ["path": .string("PROJECT_SPEC.md")],
            duration: 0.25,
            isError: false
        )))
        streamClient.emit(.token("First live token."))

        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
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
        XCTAssertFalse(viewModel.hasStreamingAssistantMessageContent)

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
        XCTAssertTrue(viewModel.hasStreamingAssistantMessageContent)
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
                        "timestamp": 1770000100,
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
            "The server or Cloudflare tunnel is unavailable. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
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

        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 0)
        await viewModel.loadMessages(modelContext: context)

        // The cache-first reconcile fired exactly once so the view can snap back to the
        // bottom as the taller server transcript replaces the lighter cached render.
        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 1)
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
        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 0)
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
                        "timestamp": 1770000100,
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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(6))

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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(6))

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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(6))

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

        let firstPollDate = Date().addingTimeInterval(6)
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

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(6))

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

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

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
        originalStreamClient.emit(.token("Once Raj reached the river. "))

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
                  "stream_id": "stream-123"
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
        var requestPaths: [String] = []
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
        XCTAssertEqual(requestPaths, [
            "/api/profiles",
            "/api/profile/switch",
            "/api/models",
            "/api/reasoning",
            "/api/workspaces",
            "/api/commands",
            "/api/chat/start"
        ])
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
                XCTAssertNil(body["explicit_model_pick"])
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
    func testClearSlashCommandClearsLocalTranscriptWithoutServerRequest() async throws {
        var requestCount = 0
        let viewModel = try makeViewModel { request in
            requestCount += 1
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Question", "timestamp": 1, "message_id": "u-1"},
                      {"role": "assistant", "content": "Answer", "timestamp": 2, "message_id": "a-2"}
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Clear should not call \(request.url?.path ?? "unknown path").")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "clear")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(requestCount, 1)
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
        streamingScrollCoalescingDelayNanoseconds: UInt64 = 16_000_000,
        speechSynthesizerFactory: @escaping () -> any ChatSpeechSynthesizing = { AVSpeechSynthesizer() },
        listenAudioSession: (any ListenAudioSessionControlling)? = nil,
        listenRemoteControlCenter: (any ListenRemoteControlControlling)? = nil,
        serverTTSAudioPlayerFactory: (@MainActor (Data) throws -> any ListenAudioPlaying)? = nil,
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
            streamingScrollCoalescingDelayNanoseconds: streamingScrollCoalescingDelayNanoseconds,
            speechSynthesizerFactory: speechSynthesizerFactory,
            // Default to a spy so unit tests never drive the live shared AVAudioSession.
            listenAudioSession: listenAudioSession ?? SpyListenAudioSession(),
            listenRemoteControlCenter: listenRemoteControlCenter ?? SpyListenRemoteControlCenter(),
            serverTTSAudioPlayerFactory: serverTTSAudioPlayerFactory,
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

    func start(sessionID: String, sessionTitle: String, streamID: String?) {}

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
