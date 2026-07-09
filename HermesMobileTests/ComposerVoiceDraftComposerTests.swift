import AVFoundation
import XCTest
@testable import HermesMobile

final class ComposerVoiceDraftComposerTests: XCTestCase {
    func testComposedDraftUsesTranscriptWhenDraftIsEmpty() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "", transcript: "Open the workspace"),
            "Open the workspace"
        )
    }

    func testComposedDraftAppendsTranscriptToExistingDraft() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "Please", transcript: "summarize this file"),
            "Please summarize this file"
        )
    }

    func testComposedDraftPreservesBaseDraftWhenTranscriptIsBlank() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "Keep this", transcript: "   \n"),
            "Keep this"
        )
    }

    func testDraftUpdateSessionComposesWhileAcceptingUpdates() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Please")

        XCTAssertEqual(session.composedDraft(for: "summarize this file"), "Please summarize this file")
    }

    func testDraftUpdateSessionIgnoresLateTranscriptAfterStop() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Send this")
        session.stopAcceptingUpdates()

        XCTAssertNil(session.composedDraft(for: "late final transcript"))
    }

    func testDraftUpdateSessionUsesNewBaseDraftAfterRestart() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Old")
        session.stopAcceptingUpdates()
        session.begin(baseDraft: "New")

        XCTAssertEqual(session.composedDraft(for: "transcript"), "New transcript")
    }

    func testVoiceInputPreflightAcceptsValidInputFormatValues() {
        XCTAssertNoThrow(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 1)
        )
    }

    func testVoiceInputPreflightRejectsZeroSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 0, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsInfiniteSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: .infinity, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooLowSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: ComposerVoiceInputPreflight.validSampleRateRange.lowerBound - 1,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooHighSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: ComposerVoiceInputPreflight.validSampleRateRange.upperBound + 1,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsZeroChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 0)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooHighChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: 44_100,
                channelCount: ComposerVoiceInputPreflight.validChannelCountRange.upperBound + 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputAudioSessionConfigurationDoesNotDuckOtherAudio() {
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.category, .playAndRecord)
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.mode, .measurement)
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.mixWithOthers))
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.allowBluetoothHFP))
        XCTAssertFalse(ComposerVoiceAudioSessionConfiguration.options.contains(.duckOthers))
    }

    func testVoiceInputStartPolicyAllowsActiveAppState() {
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true))
    }

    func testVoiceInputStartPolicyRejectsInactiveAppState() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: false))
    }

    func testVoiceInputStartPolicyRejectsMissingAudioInput() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: false,
                sampleRate: 44_100,
                inputNumberOfChannels: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .noAudioInput)
        }
    }

    func testVoiceInputStartPolicyRejectsInvalidSessionFormat() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: true,
                sampleRate: 0,
                inputNumberOfChannels: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputStartPolicyRejectsRunningEngineBeforeTapInstall() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: true)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .audioEngineAlreadyRunning)
        }
    }

    @MainActor
    func testVoiceInputControllerDoesNotCreateSpeechOrAudioObjectsBeforeRecording() {
        let counter = VoiceInputFactoryCounter()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: {
                counter.speechRecognizerCalls += 1
                return nil
            },
            audioEngineFactory: {
                counter.audioEngineCalls += 1
                return AVAudioEngine()
            }
        )

        XCTAssertEqual(counter.speechRecognizerCalls, 0)
        XCTAssertEqual(counter.audioEngineCalls, 0)

        controller.stopKeepingTranscript()

        XCTAssertEqual(counter.speechRecognizerCalls, 0)
        XCTAssertEqual(counter.audioEngineCalls, 0)
    }

    func testSTTProviderPreferenceDefaultsToServerFirst() {
        XCTAssertEqual(ComposerSTTProviderPreference.defaultValue, .serverFirst)
        XCTAssertEqual(
            ComposerSTTProviderPreference.storedValue("unknown"),
            .serverFirst
        )
    }

    func testServerFirstPolicyPrefersServerThenOnDevice() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .serverFirst,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            [.server, .onDevice]
        )
    }

    func testServerFirstPolicyFallsBackToOnDeviceWhenServerIsNotConfigured() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .serverFirst,
                serverConfigured: false,
                onDeviceSupported: true
            ),
            [.onDevice]
        )
    }

    func testOnDeviceFirstPolicyFallsBackToServerWhenOnDeviceIsUnsupported() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceFirst,
                serverConfigured: true,
                onDeviceSupported: false
            ),
            [.server]
        )
    }

    func testOnDeviceOnlyPolicyNeverRoutesToServer() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            [.onDevice]
        )
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: false
            ),
            []
        )
    }

    func testProviderPolicyReturnsNextFallbackOnly() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.fallbackProvider(
                after: .server,
                preference: .serverFirst,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            .onDevice
        )
        XCTAssertNil(
            ComposerSTTProviderPolicy.fallbackProvider(
                after: .server,
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: true
            )
        )
    }
}

private final class VoiceInputFactoryCounter {
    var speechRecognizerCalls = 0
    var audioEngineCalls = 0
}
