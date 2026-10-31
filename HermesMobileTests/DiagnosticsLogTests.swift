import XCTest
@testable import HermesMobile

/// MetricKit reports kept for About → Diagnostics (#1397): what a payload keeps, and how retention
/// and deletion bound the store.
final class DiagnosticsLogTests: XCTestCase {
    private var directory: URL!
    private let clock = Clock()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "DiagnosticsLogTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Each diagnostic in a mixed payload becomes one report with its signal, build and frame
    /// offsets, even beside a diagnostic with missing fields. Messages, paths, signposts and the
    /// device model never reach the text About shows and copies.
    func testPayloadKeepsSymbolicationFieldsAndDropsSensitiveText() throws {
        let reports = DiagnosticReport.reports(
            fromPayload: Data(Self.documentedFormatPayload.utf8),
            begin: clock.now.addingTimeInterval(-86_400),
            end: clock.now
        )
        XCTAssertEqual(reports.map(\.kind), [.crash, .crash, .hang, .cpu, .diskWrites])

        let crash = reports[0]
        XCTAssertEqual(crash.signal, 11)
        XCTAssertEqual(crash.appBuildVersion, "412")
        let attributed = try XCTUnwrap(crash.callStacks.first)
        XCTAssertEqual(attributed.threadAttributed, true)
        let frame = try XCTUnwrap(attributed.frames.first)
        XCTAssertEqual(frame.binaryUUID, "70B89F27-1634-3580-A695-57CDB41D7743")
        XCTAssertEqual(frame.binaryName, "HermesMobile")
        XCTAssertEqual(frame.offsetIntoBinaryTextSegment, 165_304)
        XCTAssertEqual(frame.subFrames?.first?.offsetIntoBinaryTextSegment, 4_242)
        XCTAssertNil(reports[1].appBuildVersion)
        XCTAssertEqual(reports[2].hangDuration, "8 sec")

        let store = makeStore()
        store.save(reports, receivedAt: clock.now)
        let entries = store.entries()
        XCTAssertEqual(entries.count, 5)
        let copied = entries.compactMap(\.text).joined()
        for secret in ["USER-SECRET", "iPhone18,1", "/private/var"] {
            XCTAssertFalse(copied.contains(secret), secret)
        }
    }

    /// iOS can deliver the same payload again; it is kept once.
    func testRepeatedDeliveryIsKeptOnce() {
        let store = makeStore()
        store.save([report(build: "1")], receivedAt: clock.now)
        store.save([report(build: "1")], receivedAt: clock.now.addingTimeInterval(60))

        XCTAssertEqual(store.entries().count, 1)
    }

    /// The count and age limits hold on read alone, newest first, with no new delivery to
    /// trigger them, and the dropped files leave the disk.
    func testRetentionPrunesOnRead() throws {
        let store = makeStore(maxCount: 2)
        let day: TimeInterval = 86_400
        for (offset, build) in [(-3, "1"), (-2, "2"), (-1, "3")] {
            store.save([report(build: build)], receivedAt: clock.now.addingTimeInterval(Double(offset) * day))
        }
        XCTAssertEqual(store.entries().map(\.report?.appBuildVersion), ["3", "2"])

        clock.now = clock.now.addingTimeInterval(12.5 * day)
        XCTAssertEqual(store.entries().map(\.report?.appBuildVersion), ["3"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    /// Reports delivered together list by when they happened, the newest window first.
    func testReportsListNewestWindowFirst() {
        let store = makeStore()
        let day: TimeInterval = 86_400
        let reports = [(-2, "1"), (0, "2"), (-1, "3")].map { offset, build in
            report(build: build, windowEnd: clock.now.addingTimeInterval(Double(offset) * day))
        }
        store.save(reports, receivedAt: clock.now)

        XCTAssertEqual(store.entries().map(\.report?.appBuildVersion), ["2", "3", "1"])
    }

    /// A delivery received before Delete All, or before its own report was deleted, lands too
    /// late to bring the report back; one received after is kept.
    func testDeletesWinOverOlderPendingWrites() {
        let store = makeStore()
        let received = clock.now
        store.save([report(build: "1")], receivedAt: received)

        clock.now = received.addingTimeInterval(10)
        store.deleteAll()
        store.save([report(build: "2")], receivedAt: received)
        XCTAssertEqual(store.entries().count, 0)

        let third = report(build: "3")
        store.save([third], receivedAt: received.addingTimeInterval(20))
        let kept = store.entries()
        XCTAssertEqual(kept.map(\.report?.appBuildVersion), ["3"])

        clock.now = received.addingTimeInterval(30)
        store.delete(id: kept[0].id)
        store.save([third], receivedAt: received.addingTimeInterval(20))
        XCTAssertEqual(store.entries().count, 0)
    }

    /// A report MetricKit delivers while About or Diagnostics is open shows up there without
    /// leaving the page.
    @MainActor
    func testOpenPageListsAReportDeliveredWhileItIsShown() async {
        let store = makeStore()
        let model = DiagnosticsModel(store: store)
        let loaded = expectation(description: "first load")
        withObservationTracking { _ = model.entries } onChange: { loaded.fulfill() }
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(model.entries?.count, 0)

        let reloaded = expectation(description: "reload after delivery")
        withObservationTracking { _ = model.entries } onChange: { reloaded.fulfill() }
        store.save([report(build: "1")], receivedAt: clock.now)
        await fulfillment(of: [reloaded], timeout: 5)
        XCTAssertEqual(model.entries?.map(\.report?.appBuildVersion), ["1"])
    }

    private func makeStore(maxCount: Int = 10) -> DiagnosticsStore {
        let clock = clock
        return DiagnosticsStore(directory: directory, maxCount: maxCount, now: { clock.now })
    }

    private func report(build: String, windowEnd: Date? = nil) -> DiagnosticReport {
        DiagnosticReport(
            kind: .hang, windowStart: windowEnd ?? clock.now, windowEnd: windowEnd ?? clock.now, appVersion: "2.0.1",
            appBuildVersion: build, signal: nil, exceptionType: nil, exceptionCode: nil,
            hangDuration: "8 sec", totalCPUTime: nil, writesCaused: nil, callStacks: []
        )
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// A documented-format sample, not a device capture: the shape of
    /// `MXDiagnosticPayload.jsonRepresentation()` as Apple documents it, seeded with sensitive
    /// values (USER-SECRET, a device model, a container path) that must not survive projection.
    /// The second crash has no metadata and a mistyped stack tree.
    private static let documentedFormatPayload = """
    {
      "timeStampBegin": "2026-10-28 00:00:00",
      "timeStampEnd": "2026-10-29 00:00:00",
      "crashDiagnostics": [
        {
          "version": "1.0.0",
          "callStackTree": {
            "callStackPerThread": true,
            "callStacks": [
              {
                "threadAttributed": false,
                "callStackRootFrames": [
                  {"binaryUUID": "1C3D5E7F-0000-0000-0000-000000000001", "binaryName": "libsystem_kernel.dylib",
                   "offsetIntoBinaryTextSegment": 1000, "address": 7000000000, "sampleCount": 1}
                ]
              },
              {
                "threadAttributed": true,
                "callStackRootFrames": [
                  {"binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
                   "binaryName": "/private/var/containers/Bundle/Application/USER-SECRET/HermesMobile.app/HermesMobile",
                   "offsetIntoBinaryTextSegment": 165304, "address": 7170766264, "sampleCount": 1,
                   "subFrames": [
                     {"binaryUUID": "2A4B6C8D-0000-0000-0000-000000000002", "binaryName": "UIKitCore",
                      "offsetIntoBinaryTextSegment": 4242, "address": 7000004242, "sampleCount": 1}
                   ]}
                ]
              }
            ]
          },
          "diagnosticMetaData": {
            "appBuildVersion": "412",
            "appVersion": "2.0.1",
            "regionFormat": "US",
            "exceptionType": 1,
            "exceptionCode": 0,
            "signal": 11,
            "osVersion": "iPhone OS 27.0.1 (24A100)",
            "deviceType": "iPhone18,1",
            "platformArchitecture": "arm64e",
            "bundleIdentifier": "com.uzairansar.hermesmobile",
            "terminationReason": "Namespace SIGNAL, Code 0xb USER-SECRET",
            "virtualMemoryRegionInfo": "0 is not in any region. USER-SECRET",
            "exceptionReason": {
              "composedMessage": "USER-SECRET did not respond",
              "formatString": "%@ did not respond",
              "arguments": ["USER-SECRET"],
              "exceptionType": "NSInvalidArgumentException",
              "className": "NSException",
              "exceptionName": "NSInvalidArgumentException"
            }
          },
          "signpostData": [{"subsystem": "USER-SECRET", "category": "USER-SECRET", "name": "USER-SECRET"}]
        },
        {"callStackTree": "USER-SECRET"}
      ],
      "hangDiagnostics": [
        {
          "callStackTree": {"callStackPerThread": false, "callStacks": [
            {"callStackRootFrames": [{"binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
              "binaryName": "HermesMobile", "offsetIntoBinaryTextSegment": 9000, "sampleCount": 20}]}
          ]},
          "diagnosticMetaData": {"appBuildVersion": "412", "appVersion": "2.0.1", "hangDuration": "8 sec",
                                 "deviceType": "iPhone18,1", "osVersion": "iPhone OS 27.0.1 (24A100)"}
        }
      ],
      "cpuExceptionDiagnostics": [
        {"diagnosticMetaData": {"appBuildVersion": "409", "appVersion": "2.0.0", "totalCPUTime": "20 sec",
                                "totalSampledTime": "60 sec", "deviceType": "iPhone18,1"}}
      ],
      "diskWriteExceptionDiagnostics": [
        {"diagnosticMetaData": {"appBuildVersion": "409", "appVersion": "2.0.0", "writesCaused": "2,000 MB",
                                "deviceType": "iPhone18,1"}}
      ]
    }
    """
}
