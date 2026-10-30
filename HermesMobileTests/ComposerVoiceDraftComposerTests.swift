import AVFoundation
import UIKit
import XCTest
@testable import HermesMobile

final class ComposerVoiceDraftComposerTests: XCTestCase {
    func testVoiceInputCannotStartBehindAppLockEvenInAnActiveScene() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: true))
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: false))
    }

    func testReplacementInsertsAtTheCaretWithSurroundingTextKept() {
        let update = ComposerVoiceDraftComposer.replacement(
            transcript: "for nested lists",
            ownedRange: NSRange(location: 14, length: 0),
            in: "Fix the parser and add tests"
        )

        XCTAssertEqual(update?.text, "Fix the parser for nested lists and add tests")
        XCTAssertEqual(update?.caret.location, 14 + " for nested lists".utf16.count)
    }

    func testReplacementReplacesTheSelectedSpanAndPutsTheCaretAfterIt() {
        let update = ComposerVoiceDraftComposer.replacement(
            transcript: "the crash",
            ownedRange: NSRange(location: 7, length: 7),
            in: "Select the bug and run"
        )

        XCTAssertEqual(update?.text, "Select the crash and run")
        XCTAssertEqual(update?.caret.location, 7 + " the crash".utf16.count)
        XCTAssertEqual(update?.ownedRange, NSRange(location: 7, length: " the crash".utf16.count))
    }

    func testReplacementUsesTheBareTranscriptOnAnEmptyDraftWithNoStraySpaces() {
        let update = ComposerVoiceDraftComposer.replacement(
            transcript: "  Open the workspace \n",
            ownedRange: NSRange(location: 0, length: 0),
            in: ""
        )

        XCTAssertEqual(update?.text, "Open the workspace")
        XCTAssertEqual(update?.caret.location, "Open the workspace".utf16.count)
    }

    func testReplacementAddsNoSpacesAroundCJKText() {
        let update = ComposerVoiceDraftComposer.replacement(
            transcript: "ネストしたリスト",
            ownedRange: NSRange(location: 3, length: 0),
            in: "設計を直す"
        )

        XCTAssertEqual(update?.text, "設計をネストしたリスト直す")
    }

    func testReplacementAddsNoSpaceBeforeExistingPunctuation() {
        let update = ComposerVoiceDraftComposer.replacement(
            transcript: "fig",
            ownedRange: NSRange(location: 4, length: 0),
            in: "See ."
        )

        XCTAssertEqual(update?.text, "See fig.")
    }

    func testReplacementAddsOneSpaceAgainstUnseparatedNeighbors() {
        let update = ComposerVoiceDraftComposer.replacement(
            transcript: "then run tests",
            ownedRange: NSRange(location: 12, length: 0),
            in: "Fix the bug."
        )

        XCTAssertEqual(update?.text, "Fix the bug. then run tests")
    }

    func testReplacementRejectsARangeThatSplitsASurrogatePair() {
        XCTAssertNil(
            ComposerVoiceDraftComposer.replacement(
                transcript: "hello",
                ownedRange: NSRange(location: 2, length: 0),
                in: "a😀b"
            )
        )
        XCTAssertNil(
            ComposerVoiceDraftComposer.replacement(
                transcript: "hello",
                ownedRange: NSRange(location: 0, length: 2),
                in: "a😀b"
            )
        )
    }

    func testBoundarySpacesFollowTheSeparatedWordScriptOfTheTranscript() {
        XCTAssertFalse(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "こんにちは"))
        XCTAssertFalse(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "설계를 검토해"))
        XCTAssertFalse(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "。"))
        XCTAssertTrue(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "hello"))
        XCTAssertTrue(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "привет"))
        XCTAssertTrue(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "123"))
        XCTAssertFalse(ComposerVoiceDraftComposer.addsSeparatorSpaces(for: "…"))
    }

    func testDraftUpdateSessionAppliesPartialsToTheOwnedRangeOnly() {
        var session = ComposerVoiceDraftUpdateSession()
        let owner = NSObject()
        let selection = ComposerSelection(
            range: NSRange(location: 14, length: 0),
            revision: 3,
            publishGeneration: 7
        )
        session.begin(baseDraft: "Fix the parser and add tests", selection: selection, owner: owner)
        var current = ComposerVoiceDraftSnapshot(
            owner: owner,
            text: "Fix the parser and add tests",
            selection: selection
        )

        guard case .applied(let first) = session.apply(transcript: "for nested lists", current: current) else {
            return XCTFail("First partial must apply")
        }
        current.text = first.text
        current.selection = selection.moved(to: first.caret)
        session.commit(first)

        guard case .applied(let second) = session.apply(transcript: "for nested lists and chips", current: current) else {
            return XCTFail("A partial that replaces the owned span must apply")
        }
        XCTAssertEqual(second.text, "Fix the parser for nested lists and chips and add tests")
    }

    func testDraftUpdateSessionIgnoresTranscriptAfterStop() {
        var session = ComposerVoiceDraftUpdateSession()
        let owner = NSObject()
        session.begin(baseDraft: "Send this", selection: ComposerSelection(), owner: owner)
        session.stopAcceptingUpdates()

        XCTAssertEqual(
            session.apply(
                transcript: "late final transcript",
                current: ComposerVoiceDraftSnapshot(owner: owner, text: "Send this", selection: ComposerSelection())
            ),
            .rejected
        )
    }

    func testDraftUpdateSessionUsesNewSnapshotAfterRestart() {
        var session = ComposerVoiceDraftUpdateSession()
        let owner = NSObject()
        session.begin(baseDraft: "Old", selection: ComposerSelection(), owner: owner)
        session.stopAcceptingUpdates()
        session.begin(baseDraft: "New", selection: ComposerSelection(), owner: owner)

        XCTAssertEqual(
            session.apply(
                transcript: "transcript",
                current: ComposerVoiceDraftSnapshot(owner: owner, text: "New", selection: ComposerSelection())
            ),
            .applied(ComposerVoiceDraftUpdate(
                text: "New transcript",
                ownedRange: NSRange(location: 3, length: " transcript".utf16.count),
                caret: NSRange(location: 3 + " transcript".utf16.count, length: 0)
            ))
        )
    }

    func testDraftUpdateSessionRejectsAnEditMadeAfterStart() {
        var session = ComposerVoiceDraftUpdateSession()
        let owner = NSObject()
        let selection = ComposerSelection(
            range: NSRange(location: 6, length: 0),
            revision: 2,
            publishGeneration: 5
        )
        session.begin(baseDraft: "Please", selection: selection, owner: owner)

        // An edit dates a new publish generation, even when undone back to the
        // same text, so every snapshot that carries one is stale.
        XCTAssertEqual(
            session.apply(
                transcript: "more words",
                current: ComposerVoiceDraftSnapshot(
                    owner: owner,
                    text: "Please",
                    selection: ComposerSelection(
                        range: selection.range, revision: selection.revision,
                        publishGeneration: selection.publishGeneration + 1
                    )
                )
            ),
            .rejected
        )

        // Changed text is stale even at the captured revision pair.
        XCTAssertEqual(
            session.apply(
                transcript: "more words",
                current: ComposerVoiceDraftSnapshot(owner: owner, text: "Please edited", selection: selection)
            ),
            .rejected
        )

        // A different owner — a replacement capture — must not write here.
        XCTAssertEqual(
            session.apply(
                transcript: "more words",
                current: ComposerVoiceDraftSnapshot(owner: NSObject(), text: "Please", selection: selection)
            ),
            .rejected
        )

        // A live IME composition must not be committed by a voice write.
        XCTAssertEqual(
            session.apply(
                transcript: "more words",
                current: ComposerVoiceDraftSnapshot(
                    owner: owner,
                    text: "Please",
                    selection: ComposerSelection(
                        range: selection.range, revision: selection.revision,
                        publishGeneration: selection.publishGeneration, hasMarkedText: true
                    )
                )
            ),
            .rejected
        )
    }

    /// A plain caret move — a tap, an arrow key — does not edit the draft, so
    /// the owned span is still written and the caret lands after the dictated
    /// text, never on the newly selected position.
    func testDraftUpdateSessionWritesTheOwnedSpanPastACaretMove() {
        var session = ComposerVoiceDraftUpdateSession()
        let owner = NSObject()
        let selection = ComposerSelection(
            range: NSRange(location: 6, length: 0),
            revision: 2,
            publishGeneration: 5
        )
        session.begin(baseDraft: "Please", selection: selection, owner: owner)

        XCTAssertEqual(
            session.apply(
                transcript: "hold the line",
                current: ComposerVoiceDraftSnapshot(
                    owner: owner,
                    text: "Please",
                    selection: ComposerSelection(
                        range: NSRange(location: 0, length: 0),
                        revision: selection.revision,
                        publishGeneration: selection.publishGeneration
                    )
                )
            ),
            .applied(ComposerVoiceDraftUpdate(
                text: "Please hold the line",
                ownedRange: NSRange(location: 6, length: " hold the line".utf16.count),
                caret: NSRange(location: 6 + " hold the line".utf16.count, length: 0)
            ))
        )
    }

    func testDraftUpdateSessionSkipsABlankTranscriptWithoutStopping() {
        var session = ComposerVoiceDraftUpdateSession()
        let owner = NSObject()
        session.begin(baseDraft: "Please", selection: ComposerSelection(), owner: owner)

        XCTAssertEqual(
            session.apply(
                transcript: "   \n",
                current: ComposerVoiceDraftSnapshot(owner: owner, text: "Please", selection: ComposerSelection())
            ),
            .skipped
        )
        XCTAssertEqual(
            session.apply(
                transcript: "words",
                current: ComposerVoiceDraftSnapshot(owner: owner, text: "Please", selection: ComposerSelection())
            ),
            .applied(ComposerVoiceDraftUpdate(
                text: "Please words",
                ownedRange: NSRange(location: 6, length: " words".utf16.count),
                caret: NSRange(location: 6 + " words".utf16.count, length: 0)
            ))
        )
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
