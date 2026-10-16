import AVFoundation
import UIKit
import XCTest
@testable import HermesMobile

final class ComposerVoiceDraftComposerTests: XCTestCase {
    func testVoiceInputCannotStartBehindAppLockEvenInAnActiveScene() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: true))
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: false))
    }

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

    func testVoiceInputPreflightRejectsZeroChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 0)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputAudioSessionConfigurationDoesNotDuckOtherAudio() {
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.category, .playAndRecord)
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.mode, .measurement)
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.mixWithOthers))
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.allowBluetooth))
        XCTAssertFalse(ComposerVoiceAudioSessionConfiguration.options.contains(.duckOthers))
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
            speechRecognizerFactory: { _ in
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

    func testSpeechLocaleSelectionFallsBackPastUnsupportedAndModelLessLocales() {
        var askedFor: [String] = []
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "en_PK"),
                preferredLanguages: ["ur-PK", "fr-FR"]
            ),
            supportedLocales: [Locale(identifier: "ur-PK"), Locale(identifier: "fr_FR"), Locale(identifier: "en-US")],
            recognizer: { locale -> String? in
                askedFor.append(locale.normalizedSpeechIdentifier)
                return askedFor.last == "ur-pk" ? nil : askedFor.last
            }
        )

        XCTAssertEqual(selected, "fr-fr")
        XCTAssertEqual(askedFor, ["ur-pk", "fr-fr"], "Unsupported en_PK is never asked for a recognizer.")
    }

    func testSpeechLocaleSelectionIgnoresRegionOverrideKeywords() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "de_DE@rg=atzzzz"),
                preferredLanguages: []
            ),
            supportedLocales: [Locale(identifier: "de-DE"), Locale(identifier: "en-US")],
            recognizer: { $0.normalizedSpeechIdentifier }
        )

        XCTAssertEqual(selected, "de-de")
    }

    func testSpeechLocaleSelectionMatchesScriptTaggedPreferredLanguages() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "zh-Hans_US"),
                preferredLanguages: ["zh-Hans-CN", "zh-Hant-TW"]
            ),
            supportedLocales: [Locale(identifier: "zh-CN"), Locale(identifier: "zh-TW"), Locale(identifier: "en-US")],
            recognizer: { $0.identifier }
        )

        XCTAssertEqual(selected, "zh-CN")
    }

    func testSpeechLocaleSelectionPrefersAnExactMatchOverAVariant() {
        let supported: Set<Locale> = [
            Locale(identifier: "hi-IN-translit"),
            Locale(identifier: "hi-IN"),
            Locale(identifier: "en-US"),
        ]
        func select(current: String) -> String? {
            ComposerSpeechLocalePolicy.firstAvailable(
                in: ComposerSpeechLocalePolicy.candidates(current: Locale(identifier: current), preferredLanguages: []),
                supportedLocales: supported,
                recognizer: { $0.identifier }
            )
        }

        XCTAssertEqual(select(current: "hi_IN"), "hi-IN")
        XCTAssertEqual(select(current: "hi-IN-translit"), "hi-IN-translit")
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
}

private extension Locale {
    var normalizedSpeechIdentifier: String {
        ComposerSpeechLocalePolicy.normalizedIdentifier(identifier)
    }
}

private final class VoiceInputFactoryCounter {
    var speechRecognizerCalls = 0
    var audioEngineCalls = 0
}
