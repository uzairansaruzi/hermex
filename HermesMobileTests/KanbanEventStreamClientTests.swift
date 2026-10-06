import XCTest
@testable import HermesMobile

final class KanbanEventStreamClientTests: XCTestCase {
    func testDecodesHandshakeAndEventsFrameWithResumeID() {
        XCTAssertEqual(
            KanbanStreamFrameDecoder.decode(
                eventType: "hello",
                data: #"{"cursor":7,"board":"main","future":true}"#,
                frameID: nil
            ),
            .hello(cursor: 7, board: "main")
        )

        let frame = KanbanStreamFrameDecoder.decode(
            eventType: "events",
            data: #"{"events":[{"id":8,"task_id":"CARD-8","kind":"future_kind","payload":{"private":"value"},"created_at":1700000000}],"cursor":8,"future":true}"#,
            frameID: "8"
        )
        guard case let .events(events, cursor, frameID) = frame else {
            return XCTFail("Expected events frame, got \(frame)")
        }
        XCTAssertEqual(cursor, 8)
        XCTAssertEqual(frameID, 8)
        XCTAssertEqual(events.first?.eventID, 8)
        XCTAssertEqual(events.first?.cardID, "CARD-8")
        XCTAssertEqual(events.first?.kind, "future_kind")
    }

    func testMalformedKnownFramesDoNotAdvanceAndUnknownTypesAreIgnored() {
        for frame in [
            KanbanStreamFrameDecoder.decode(eventType: "hello", data: #"{"cursor":-1,"board":"main"}"#, frameID: nil),
            KanbanStreamFrameDecoder.decode(eventType: "hello", data: #"{"cursor":1,"board":" "}"#, frameID: nil),
            KanbanStreamFrameDecoder.decode(eventType: "events", data: #"{"events":[],"cursor":"bad"}"#, frameID: nil),
            KanbanStreamFrameDecoder.decode(eventType: "events", data: #"{"events":[],"cursor":2}"#, frameID: "bad"),
            KanbanStreamFrameDecoder.decode(eventType: "events", data: "not json", frameID: nil)
        ] {
            XCTAssertEqual(frame, .malformed)
        }
        XCTAssertEqual(
            KanbanStreamFrameDecoder.decode(eventType: "future-frame", data: #"{"payload":"ignored"}"#, frameID: "9"),
            .ignored
        )
    }

    /// A Hermes socket frame is `{events, cursor}` with no event type or frame id (#1045).
    func testHermesSocketFramesReadAsEventsAndOtherMessagesAreIgnored() {
        let frame = KanbanStreamFrameDecoder.decodeSocketFrame(Data(
            #"{"events":[{"id":2,"task_id":"t_8aa1b5e6","run_id":null,"kind":"status","payload":{"status":"ready"},"created_at":1791255525,"future":1}],"cursor":2,"future":true}"#.utf8
        ))
        guard case let .events(events, cursor, frameID) = frame else {
            return XCTFail("Expected events frame, got \(frame)")
        }
        XCTAssertEqual(cursor, 2)
        XCTAssertNil(frameID)
        XCTAssertEqual(events.map(\.eventID), [2])
        XCTAssertEqual(events.first?.cardID, "t_8aa1b5e6")

        XCTAssertEqual(KanbanStreamFrameDecoder.decodeSocketFrame(Data(#"{"type":"hello"}"#.utf8)), .ignored)
        for malformed in [#"{"events":[],"cursor":-1}"#, #"{"events":[]}"#, #"{"cursor":"2"}"#, "not json"] {
            XCTAssertEqual(KanbanStreamFrameDecoder.decodeSocketFrame(Data(malformed.utf8)), .malformed, malformed)
        }
    }

    func testSSECommentsAreTransportKeepalives() {
        // LDSwiftEventSource delivers comment lines through EventHandler.onComment,
        // which KanbanEventStreamClient intentionally treats as a no-op. The
        // decoder therefore never receives or misclassifies keepalive payloads.
        XCTAssertEqual(
            KanbanStreamFrameDecoder.decode(eventType: "", data: "", frameID: nil),
            .ignored
        )
    }
}
