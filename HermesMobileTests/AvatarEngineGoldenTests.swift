import XCTest
@testable import HermesMobile

final class AvatarEngineGoldenTests: XCTestCase {
    struct Fixture: Decodable {
        let definitions: [BotAvatarDefinition]
        let frames: [Frame]
        let validation: [Validation]
        struct Validation: Decodable { let label: String; let input: BotJSON; let valid: Bool; let normalized: BotAvatarDefinition? }
        struct Frame: Decodable {
            struct Options: Decodable { let depth: Double; let reducedMotion: Bool?; let motion: BotAvatarMood?; let time: Double?; let gaze: Gaze?; let view: View? }
            struct Gaze: Decodable { let x: Double; let y: Double; let weight: Double? }
            struct View: Decodable { let yaw: Double; let pitch: Double }
            struct Shape: Decodable { let key: String; let matrix: [Double]; let mark: Mark? }
            struct Mark: Decodable { let shape: String; let x: Double?; let y: Double?; let width: Double?; let height: Double?; let d: String?; let strokeWidth: Double? }
            struct Part: Decodable { let kind: String; let depth: Double; let thickness: Double; let z: [[Double]]; let x: [[Double]] }
            let id: String; let options: Options; let root: [Double]; let shapes: [Shape]; let parts: [Part]; let eyeZ: [Double]; let eyeScale: Double
        }
    }
    func fixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AvatarEngine/goldens.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("Could not read \(file.path); source tree is not present") }
        return try JSONDecoder().decode(Fixture.self, from: data)
    }
    func equal(_ a: [Double], _ b: [Double], _ context: String, tolerance: Double = 0.00002, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, context, file: file, line: line)
        for (x,y) in zip(a,b) { XCTAssertEqual(x,y,accuracy:tolerance,context,file:file,line:line) }
    }
    func testPreparedGeometryAndFramesMatchPinnedEngine() throws {
        let data = try fixture()
        var volumes: [String: BotAvatarVolume] = [:]
        for golden in data.frames {
            let key = "\(golden.id)/\(golden.options.depth)", o = golden.options
            let volume: BotAvatarVolume
            if let cached = volumes[key] { volume = cached }
            else {
                volume = try BotAvatarVolume.prepare(XCTUnwrap(data.definitions.first { $0.id == golden.id }), depth: o.depth)
                volumes[key] = volume
                XCTAssertEqual(volume.parts.count, golden.parts.count, key)
                for (part, expected) in zip(volume.parts, golden.parts) {
                    XCTAssertEqual(part.kind.rawValue, expected.kind, key)
                    equal([part.depth,part.thickness],[expected.depth,expected.thickness],key)
                    for (slices, summaries) in [(part.zSlices,expected.z),(part.xSlices,expected.x)] {
                        XCTAssertEqual(slices.count,summaries.count,key)
                        for (slice, summary) in zip(slices,summaries) {
                            let pts = slice.loops.flatMap { $0 }
                            let bounds = AvatarBounds(slice.loops)
                            let samples = [(0.17,0.23),(0.38,0.71),(0.59,0.47),(0.73,0.19),(0.89,0.83)].map { u,v -> Double in
                                let point = AvatarPoint(bounds.minX+u*bounds.width,bounds.minY+v*bounds.height)
                                var inside = false
                                for poly in slice.loops {
                                    var a = poly[poly.count-1]
                                    for b in poly {
                                        if (a.y > point.y) != (b.y > point.y) && point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
                                        a = b
                                    }
                                }
                                let d = AvatarGeometry.edgeDistance(slice.loops,point)
                                return inside ? d : -d
                            }
                            equal([slice.at,slice.inset,Double(slice.loops.count),Double(pts.count)],Array(summary.prefix(4)),key)
                            // Symmetric RDP ties differ across libm implementations by at most its 0.04-unit tolerance.
                            equal([bounds.minX,bounds.minY,bounds.maxX,bounds.maxY]+samples,Array(summary.dropFirst(4)),key,tolerance:0.05)

                        }
                    }
                }
                equal(volume.eyeZ,golden.eyeZ,key); XCTAssertEqual(volume.eyeScale,golden.eyeScale,accuracy:0.00001,key)
            }
            let pose = BotAvatarPose.compute(seed:volume.seed,time:o.time ?? 0,mood:.mood(o.motion ?? .idle),
                                            gaze:o.gaze.map { .init(x:$0.x,y:$0.y,weight:$0.weight ?? 1) },
                                            view:o.view.map { .init(yaw:$0.yaw,pitch:$0.pitch) } ?? .init(),reducedMotion:o.reducedMotion ?? false)
            let frame = BotAvatarFrame.make(volume:volume,pose:pose)
            equal(frame.root.values,golden.root,key)
            XCTAssertEqual(frame.shapes.count,golden.shapes.count,key)
            for (item,expected) in zip(frame.shapes,golden.shapes) {
                equal(item.matrix.values,expected.matrix,key)
                switch item.shape {
                case .slice(let part,let index,let side): XCTAssertEqual("\(part)\(side ? "x" : "z")\(index)",expected.key,key)
                case .eye(let mark):
                    XCTAssertEqual("eye-\(mark.index)",expected.key,key)
                    let e = try XCTUnwrap(expected.mark)
                    XCTAssertEqual(mark.happy ? "arc" : "pill",e.shape,key)
                    if !mark.happy {
                        equal([mark.x-mark.width/2,mark.y-mark.height/2,mark.width,mark.height], [try XCTUnwrap(e.x),try XCTUnwrap(e.y),try XCTUnwrap(e.width),try XCTUnwrap(e.height)],key)
                    } else {
                        let path = try AvatarPath.parse(XCTUnwrap(e.d))
                        let a = path[0].values + path[1].values
                        equal([mark.x-0.72*mark.width,mark.y+0.1*mark.height,mark.x,mark.y-0.42*mark.height,mark.x+0.72*mark.width,mark.y+0.1*mark.height],a,key,tolerance:0.0051)
                    }
                }
            }
        }
    }
    func testImportAcceptsAndRejectsPinnedCases() throws {
        for c in try fixture().validation {
            let result = BotAvatarValidator.validate(json: try JSONEncoder().encode(c.input))
            switch result {
            case .valid(let definition): XCTAssertTrue(c.valid,c.label); XCTAssertEqual(definition,c.normalized,c.label)
            case .invalid(let errors): XCTAssertFalse(c.valid,"\(c.label): \(errors)"); XCTAssertFalse(errors.isEmpty)
            }
        }
        for text in ["", "[]", "null", "{", String(repeating:"x",count:40000)] {
            guard case .invalid = BotAvatarValidator.validate(json:Data(text.utf8)) else { return XCTFail("Malformed JSON accepted") }
        }
    }
    func testStillPoseAndFollowSettleWithoutAClock() {
        XCTAssertEqual(BotAvatarPose.compute(seed:1,time:0).yaw,BotAvatarPose.compute(seed:1,time:100).yaw)
        var follow = BotAvatarFollow(x:1,y:-1,attention:1), moving = true
        for _ in 0..<100 { let step = follow.step(target:nil,dt:1/30,reducedMotion:false); follow = step.state; moving = step.moving }
        XCTAssertFalse(moving); XCTAssertNil(follow.gaze)
        let p = BotAvatarPose.compute(seed:1,gaze:.init(x:1,y:1),reducedMotion:true)
        XCTAssertEqual(p.yaw,BotAvatarPose.rest.yaw); XCTAssertEqual(p.gazeX,1)
    }

}
