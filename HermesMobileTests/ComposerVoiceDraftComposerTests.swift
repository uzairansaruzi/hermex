import AVFoundation
import UIKit
import XCTest
@testable import HermesMobile

final class ComposerVoiceDraftComposerTests: XCTestCase {
    func testVoiceInputCannotStartBehindAppLockEvenInAnActiveScene() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: true))
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: false))
    }

    private func replacing(_ location: Int, _ length: Int = 0, in text: String, with transcript: String) -> String? {
        ComposerVoiceDraftComposer.replacing(NSRange(location: location, length: length), in: text, with: transcript)?.text
    }

    private func state(_ text: String, caret: Int, generation: Int = 0) -> ComposerVoiceDraftState {
        ComposerVoiceDraftState(
            text: text,
            selection: ComposerSelection(range: NSRange(location: caret, length: 0), publishGeneration: generation)
        )
    }

    func testDictationInsertsAtTheCaretAndLeavesTheCaretAfterIt() throws {
        let draft = "Fix the bug in the parser and add tests"
        let update = try XCTUnwrap(ComposerVoiceDraftComposer.replacing(
            NSRange(location: 25, length: 0), in: draft, with: " for nested lists\n"
        ))
        XCTAssertEqual(update.text, "Fix the bug in the parser for nested lists and add tests")
        XCTAssertEqual(update.caret, NSRange(location: 42, length: 0))
    }

    func testDictationReplacesTheSelection() {
        XCTAssertEqual(
            replacing(4, 7, in: "Fix the bug in the parser", with: "the crash"),
            "Fix the crash in the parser"
        )
    }

    func testSpacingFollowsTheTextAroundTheCaret() {
        XCTAssertEqual(replacing(0, in: "", with: "Open the workspace"), "Open the workspace")
        XCTAssertEqual(replacing(3, in: "foobar", with: "and"), "foo and bar")
        XCTAssertEqual(replacing(5, in: "Hello.", with: "there"), "Hello there.")
        XCTAssertEqual(replacing(6, in: "Hello ", with: "there"), "Hello there")
        XCTAssertEqual(replacing(1, in: "(x)", with: "see"), "(see x)")
        XCTAssertEqual(replacing(5, in: "Hello/plan", with: "there"), "Hello there /plan")
    }

    func testChineseAndJapaneseTakeNoSpaces() {
        XCTAssertEqual(replacing(3, in: "これはテスト", with: "新しい"), "これは新しいテスト")
        XCTAssertEqual(replacing(5, in: "Hello world", with: "世界"), "Hello世界 world")
    }

    func testARangeThatSplitsACharacterIsRefused() {
        XCTAssertNil(replacing(1, in: "😀 hi", with: "words"))
        XCTAssertNil(replacing(9, in: "short", with: "words"))
    }

    func testEachResultReplacesOnlyTheOwnedSpan() {
        var session = ComposerVoiceDraftUpdateSession()
        var draft = state("Fix the parser and add tests", caret: 14)
        session.begin(draft)

        let first = session.update(for: "for", current: draft)
        XCTAssertEqual(first?.text, "Fix the parser for and add tests")

        draft = ComposerVoiceDraftState(text: first!.text, selection: draft.selection.moved(to: first!.caret))
        let second = session.update(for: "for nested lists", current: draft)
        XCTAssertEqual(second?.text, "Fix the parser for nested lists and add tests")
        XCTAssertEqual(second?.caret, NSRange(location: 31, length: 0))
    }

    func testAnEditEndsDictationEvenWhenUndoneBackToTheSameText() {
        var session = ComposerVoiceDraftUpdateSession()
        session.begin(state("Keep", caret: 4))
        XCTAssertNil(session.update(for: "late", current: state("Keep", caret: 4, generation: 2)))
    }

    func testAWriteFromOutsideTheEditorEndsDictation() {
        var session = ComposerVoiceDraftUpdateSession()
        session.begin(state("Keep", caret: 4))
        XCTAssertNil(session.update(for: "late", current: state("Replaced", caret: 4)))
    }

    func testAMovedCaretDoesNotMoveWhereTheWordsLand() {
        var session = ComposerVoiceDraftUpdateSession()
        session.begin(state("one two", caret: 3))
        XCTAssertEqual(session.update(for: "and", current: state("one two", caret: 0))?.text, "one and two")
    }

    func testCancelPutsBackTheDraftAndCaretOnlyAfterAWrite() throws {
        var session = ComposerVoiceDraftUpdateSession()
        let start = ComposerVoiceDraftState(
            text: "Fix the bug",
            selection: ComposerSelection(range: NSRange(location: 4, length: 7))
        )
        session.begin(start)
        XCTAssertNil(session.restoredDraft(current: start))

        let update = try XCTUnwrap(session.update(for: "the crash", current: start))
        let afterWrite = ComposerVoiceDraftState(text: update.text, selection: start.selection.moved(to: update.caret))
        XCTAssertEqual(
            session.restoredDraft(current: afterWrite),
            ComposerVoiceDraftUpdate(text: "Fix the bug", caret: NSRange(location: 4, length: 7))
        )
    }

    func testCancelLeavesADraftThatMovedOn() {
        var session = ComposerVoiceDraftUpdateSession()
        session.begin(state("Keep", caret: 4))
        XCTAssertNil(session.restoredDraft(current: state("Keep and more", caret: 13, generation: 1)))
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
