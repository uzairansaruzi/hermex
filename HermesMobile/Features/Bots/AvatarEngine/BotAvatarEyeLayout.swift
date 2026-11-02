// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

/// Expression dimensions in face-plane units. Prepare alongside the volume, never inside a blink draw.
nonisolated struct BotAvatarEyeLayout: Sendable {
    struct Eye: Sendable { let width: Double; let height: Double; let tilt: Double }
    let left: Eye, right: Eye
    let spacing: Double
    let scale: Double
    let happy: Bool
    static func fit(volume: BotAvatarVolume, geometry: BotAvatarExpression.Geometry, lean: Double = 0, happy: Bool = false) -> Self {
        let boost = volume.eyeScale
        func converted(_ e: BotAvatarExpression.Eye) -> Eye {
            Eye(width: e.width / 0.186 * 4 * boost, height: e.height / 0.412 * 11 * boost, tilt: e.tilt + lean)
        }
        let left = converted(geometry.left), right = converted(geometry.right)
        guard [left.width,left.height,left.tilt,right.width,right.height,right.tilt,geometry.split].allSatisfy(\.isFinite),
              left.width > 0, left.height > 0, right.width > 0, right.height > 0 else {
            return Self(left: Eye(width: 0, height: 0, tilt: 0), right: Eye(width: 0, height: 0, tilt: 0), spacing: 0, scale: 0, happy: happy)
        }
        let spacing = volume.definition.eyes.spacing * geometry.split / 15.46, center = volume.definition.eyes
        let polygons = volume.body.polys
        // The same clearance includes the entire permitted gaze rectangle and the closed lid.
        func fits(_ scale: Double) -> Bool {
            for (index, eye) in [left, right].enumerated() {
                let x = center.x + (index == 0 ? -1 : 1) * spacing * scale / 2
                let angle = eye.tilt * .pi / 180, co = cos(angle), si = sin(angle)
                let w = eye.width*scale, h = eye.height*scale
                for lid in [0.0,1.0] {
                    let height = max(w*0.55,h*max(0.09,lid)), radius = min(w,height)/2
                    var points: [AvatarPoint] = []
                    if happy {
                        // Bound the stroked quadratic, including its round caps.
                        for k in 0...24 {
                            let t = Double(k)/24, u = 1-t
                            let px = (t*t-u*u)*0.72*w, py = (u*u+t*t)*0.1*h-2*u*t*0.42*h
                            for j in 0..<16 { let a = Double(j)/16 * 2 * .pi; points.append(AvatarPoint(px+cos(a)*0.3*w,py+sin(a)*0.3*w)) }
                        }
                    } else {
                        for k in 0..<64 {
                            let a = Double(k)/64 * 2 * .pi, c = cos(a), s = sin(a)
                            points.append(AvatarPoint(c*radius + (c >= 0 ? 1 : -1)*(w/2-radius), s*radius + (s >= 0 ? 1 : -1)*(height/2-radius)+(h-height)*0.18))
                        }
                    }
                    for p in points {
                        let rx = co*p.x-si*p.y, ry = si*p.x+co*p.y
                        for dx in [-1.5*boost,0,1.5*boost] { for dy in [-1.1*boost,0,1.1*boost] {
                            let point = AvatarPoint(x+rx+dx,center.y+ry+dy)
                            if !AvatarGeometry.inside(polygons,point.x,point.y) || AvatarGeometry.edgeDistance(polygons,point) < 1.5 { return false }
                        } }
                    }
                }
            }
            return true
        }
        var lo = 0.0, hi = 1.0
        if fits(1) { lo = 1 }
        else { for _ in 0..<14 { let mid = (lo+hi)/2; if fits(mid) { lo = mid } else { hi = mid } } }
        return Self(left: left,right: right,spacing: spacing,scale: lo,happy: happy)
    }
    func marks(eyes: BotAvatarDefinition.Eyes, lid: Double = 1, gaze: AvatarPoint = AvatarPoint(0,0)) -> [BotAvatarEyeMark] {
        guard scale > 0 else { return [] }
        return [left,right].enumerated().map { i,e in
            let w = e.width*scale, h = e.height*scale, open = max(w*0.55,h*max(0.09,BotAvatarPose.clamp(lid,0,1)))
            return BotAvatarEyeMark(index:i,x:eyes.x+(i == 0 ? -1 : 1)*spacing*scale/2+gaze.x,
                                    y:eyes.y+gaze.y+(happy ? 0 : (h-open)*0.18),width:w,height:happy ? h : open,happy:happy,tilt:e.tilt)
        }
    }
}
