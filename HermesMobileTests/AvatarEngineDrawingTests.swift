import XCTest
import SwiftUI
@testable import HermesMobile

@MainActor final class AvatarEngineDrawingTests: XCTestCase {
    func testEveryExpressionFitsANarrowFaceIncludingGazeAndLean() async throws {
        // A narrow approved silhouette forces large expressions to shrink. Inspect actual drawn paths.
        let def = BotAvatarDefinition(version:1,id:"narrow",name:"Narrow",body:.init(path:"M30 10H70V90H30Z"),eyes:.init(x:50,y:50,spacing:14,scale:1))
        let volume = try await Task.detached { try BotAvatarVolume.prepare(def,depth:0) }.value
        for expression in BotAvatarExpression.allCases {
            let geometry = expression.geometry
            let layout = await Task.detached { BotAvatarEyeLayout.fit(volume:volume,geometry:geometry,lean:-18) }.value
            XCTAssertGreaterThan(layout.scale,0,expression.rawValue)
            for lid in [0.0,1.0] { for direction in [-1.0,1.0] {
                let marks = layout.marks(eyes:def.eyes,lid:lid,gaze:AvatarPoint(direction*1.5*volume.eyeScale,direction*1.1*volume.eyeScale))
                for mark in marks {
                    let bounds = BotAvatarDrawing.eyePath(mark).boundingBoxOfPath
                    XCTAssertGreaterThanOrEqual(bounds.minX,31.49,expression.rawValue)
                    XCTAssertLessThanOrEqual(bounds.maxX,68.51,expression.rawValue)
                    XCTAssertGreaterThanOrEqual(bounds.minY,11.49,expression.rawValue)
                    XCTAssertLessThanOrEqual(bounds.maxY,88.51,expression.rawValue)
                }
            } }
        }
    }
    func testBitmapLayersMatchFullRestDrawing() async throws {
        for id in ["barbell","witch-hat","cat"] {
            let def = try XCTUnwrap(BotAvatarCatalog.entries.first { $0.definition.id == id }).definition
            let rest = try await Task.detached { BotAvatarRestDrawing(volume:try BotAvatarVolume.prepare(def)) }.value
            let key = try XCTUnwrap(BotAvatarBodyCache.Key(volume:rest.volume,color:.init(200,80,20),appearance:"light",pointSize:100,displayScale:2))
            let rendered = await Task.detached { BotAvatarBodyCache.render(key:key,rest:rest) }.value
            let bitmap = try XCTUnwrap(rendered)
            func context() throws -> CGContext {
                try XCTUnwrap(CGContext(data:nil,width:200,height:200,bitsPerComponent:8,bytesPerRow:800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            }
            let full = try context(), layered = try context()
            full.translateBy(x:0,y:200); full.scaleBy(x:2,y:-2)
            BotAvatarDrawing.draw(frame:rest.frame,volume:rest.volume,context:full,body:key.color,ink:.init(0,0,0))
            layered.draw(bitmap.behind,in:CGRect(x:0,y:0,width:200,height:200))
            layered.saveGState(); layered.translateBy(x:0,y:200); layered.scaleBy(x:2,y:-2)
            for item in rest.frame.shapes {
                if case .eye(let mark) = item.shape {
                    layered.saveGState(); layered.concatenate(rest.frame.root.times(item.matrix).affine)
                    layered.setFillColor(BotAvatarDrawing.color(.init(0,0,0))); BotAvatarDrawing.paintEye(mark,in:layered); layered.restoreGState()
                }
            }
            layered.restoreGState()
            if let front = bitmap.front { layered.draw(front,in:CGRect(x:0,y:0,width:200,height:200)) }
            let a = try XCTUnwrap(full.data).assumingMemoryBound(to:UInt8.self), b = try XCTUnwrap(layered.data).assumingMemoryBound(to:UInt8.self)
            let difference = (0..<(800*200)).reduce(0.0) { $0 + abs(Double(a[$1])-Double(b[$1])) } / Double(800*200)
            XCTAssertLessThan(difference,0.5,"\(id) compositing differs from back-to-front frame")
        }
    }
    func testHostedCanvasTimingReport() async throws {
        for id in ["barbell","sprout","cat"] {
            let def = try XCTUnwrap(BotAvatarCatalog.entries.first { $0.definition.id == id }).definition
            let volume = try await Task.detached { try BotAvatarVolume.prepare(def) }.value
            let drawn = expectation(description:"90 actual Canvas drawing callbacks for " + id)
            let driver = AvatarCanvasDriver(volume:volume,done:drawn)
            let host = UIHostingController(rootView:AvatarCanvasProbe(driver:driver).frame(width:240,height:240))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene:scene)
            window.frame = CGRect(x:0,y:0,width:480,height:480)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            await fulfillment(of:[drawn],timeout:20)
            XCTAssertEqual(driver.samples.count,90)
            guard driver.samples.count == 90 else { continue }
            let batches = stride(from:0,to:driver.samples.count,by:30).map { start in
                driver.samples[start..<min(start+30,driver.samples.count)].reduce(0,+)/30
            }
            print("AVATAR Canvas \(id) 240pt, hosted front/side, Debug drawing callback CPU: median batch \(batches.sorted()[batches.count/2]) ms, worst frame \(driver.samples.max() ?? 0) ms")
        }
    }
}

@MainActor private final class AvatarCanvasDriver: ObservableObject {
    @Published var index = 0
    let volume: BotAvatarVolume
    let done: XCTestExpectation
    var samples: [Double] = []
    init(volume:BotAvatarVolume,done:XCTestExpectation) { self.volume = volume; self.done = done }
    func record(_ milliseconds:Double) {
        guard samples.count < 90 else { return }
        samples.append(milliseconds)
        if samples.count == 90 { done.fulfill() }
        else { DispatchQueue.main.async { self.index += 1 } }
    }
}

private struct AvatarCanvasProbe: View {
    @ObservedObject var driver: AvatarCanvasDriver
    var body: some View {
        let index = driver.index, volume = driver.volume
        let pose = BotAvatarPose.compute(seed:volume.seed,time:Double(index)/30,mood:.mood(.thinking),view:.init(yaw:index % 2 == 0 ? 1.5 : 0))
        Canvas { context,size in
            let start = CFAbsoluteTimeGetCurrent()
            context.scaleBy(x:size.width/100,y:size.height/100)
            let frame = BotAvatarFrame.make(volume:volume,pose:pose)
            BotAvatarDrawing.draw(frame:frame,volume:volume,context:&context,body:.orange,ink:.black)
            let elapsed = (CFAbsoluteTimeGetCurrent()-start)*1000
            DispatchQueue.main.async { driver.record(elapsed) }
        }
    }
}
