import Foundation

/// Upright 96 × 96 samples from the current luminance plane.
struct FloorImage {
    let w=96, h=96
    let pixels: [UInt8]
    init(pixels:[UInt8]) {
        precondition(pixels.count == 96 * 96)
        self.pixels = pixels
    }
    func value(_ x:Int,_ y:Int) -> Int { Int(pixels[max(0,min(h-1,y))*w+max(0,min(w-1,x))]) }
    var visible: Bool {
        let mean=pixels.reduce(0){$0+Int($1)}/pixels.count
        var edges=0
        for y in stride(from:2,to:h-2,by:3) { for x in stride(from:2,to:w-2,by:3) {
            if abs(value(x-1,y)-value(x+1,y))+abs(value(x,y-1)-value(x,y+1)) > 14 { edges += 1 }
        } }
        return mean > 18 && mean < 238 && edges > 39
    }
    func signature(_ box:ImageBox) -> UInt64 {
        var bits:UInt64=0
        for y in 0..<8 { for x in 0..<8 {
            let xx=(box.left+(Double(x)+0.5)/9*(box.right-box.left))*Double(w)
            let yy=(box.top+(Double(y)+0.5)/8*(box.bottom-box.top))*Double(h)
            if value(Int(xx),Int(yy)) > value(Int(xx+max(1,(box.right-box.left)*Double(w)/9)),Int(yy)) { bits |= 1 << (y*8+x) }
        } }; return bits
    }
    /// Multiple long horizontal edges low in the image are negative-obstacle candidates, never floor proof.
    var possibleStep: Bool {
        var rows:[Int]=[]
        for y in 51..<89 {
            let xs=27..<69
            let dark=xs.filter { value($0,y+1)-value($0,y-1) < -21 }.count
            let light=xs.filter { value($0,y+1)-value($0,y-1) > 21 }.count
            if max(dark,light)>30 && y-(rows.last ?? 0)>4 { rows.append(y) }
        }; return rows.count>=2
    }
}

struct FloorPatch {
    let y:Double, polygon:[V3]
    func contains(_ p:V3) -> Bool {
        var inside=false, j=polygon.count-1
        for i in polygon.indices {
            let a=polygon[i], b=polygon[j]
            if (a.z>p.z) != (b.z>p.z), p.x < (b.x-a.x)*(p.z-a.z)/(b.z-a.z)+a.x { inside.toggle() }
            j=i
        }; return inside
    }
}

/// Shared by the real AR/Vision adapter and pixel/pose replays. This loop never waits for a network response.
final class GroundAssessment {
    private var previous:(FramePose, FloorImage)?, floorHeight:Double?
    func inspect(image:FloorImage?, pose p:FramePose, planes:[FloorPatch], features:[V3],
                 observations:[Sighting], personOK:Bool, depth:(((Double,Double))->Double?)?=nil) -> NearField {
        var bins = stride(from:-60,through:60,by:15).map { Sector(angle:$0,state:.unknown) }
        var hazards=observations.filter { $0.kind.mobile || $0.kind == .steps }
        guard let image, image.visible, p.normal else {
            previous=nil; return .init(pose:p,visible:false,sectors:bins,hazards:[],reason:"先停一下，画面不清或位置追踪不足。")
        }
        let prev=previous; previous=(p,image)
        if image.possibleStep { hazards.append(.init(kind:.steps,box:.init(0.26,0.52,0.74,0.94),confidence:0.65)) }
        let underCamera=planes.filter { $0.contains(p.position) }
        let ground=underCamera.min { $0.y < $1.y } ?? planes.filter { plane in
            plane.polygon.contains { $0.groundDistance(p.position) < 0.85 } && plane.polygon.count >= 3
        }.min { $0.y < $1.y }
        var reason:String?
        if !personOK { reason="先停一下，人员检测暂不可用。" }
        if p.pitchDown < 14 || p.pitchDown > 55 { reason="请站定，将手机向下倾斜，让前方地面进入画面。" }
        if let level=ground?.y, let old=floorHeight, abs(level-old)>0.15 { reason="先停一下，地面高度发生变化。"; previous=nil }
        floorHeight=ground?.y
        if let ground {
            // A directly observed lower floor patch ahead is evidence of a possible drop.
            let forward = V3(p.forward.x,0,p.forward.z).unit
            let side = V3(-forward.z,0,forward.x)
            for distance in [0.65,1.0,1.35,1.7] {
                var q=p.position+forward*distance; q.y=ground.y
                guard let lower=planes.first(where:{ (0.12...0.65).contains(ground.y-$0.y) && $0.contains(q) && $0.contains(q+side*0.15) }),
                      let uv=p.project(V3(q.x,lower.y,q.z)), (0.04...0.96).contains(uv.0), (0.05...0.95).contains(uv.1) else {continue}
                hazards.append(.init(kind:.steps,box:.init(max(0,uv.0-0.17),max(0,uv.1-0.04),min(1,uv.0+0.17),min(1,uv.1+0.05)),confidence:0.8)); break
            }
        }
        for i in bins.indices {
            let angle=(p.heading+Double(bins[i].angle)) * .pi/180
            let aim=V3(sin(angle),0,-cos(angle)), side=V3(cos(angle),0,sin(angle))
            // Project the body-width path into the upright image; boxes outside the camera cannot certify a sector.
            let rayHeading=aim.heading
            let inPath=hazards.contains { s in
                let lo=p.ray(s.box.left,s.box.bottom).heading, hi=p.ray(s.box.right,s.box.bottom).heading
                let mid=p.ray(s.box.center.0,s.box.bottom).heading
                return s.box.bottom > 0.38 && abs(turnAngle(mid-rayHeading)) <= max(abs(turnAngle(lo-mid)),abs(turnAngle(hi-mid)))+11
            }
            if inPath { bins[i].state = .occupied; continue }
            guard let ground else { continue }
            let elevated=features.compactMap { f -> Double? in
                let d=f-p.position, ahead=d.dot(aim)
                guard (0.18...2.05).contains(ahead), abs(d.dot(side)) < 0.35, f.y-ground.y > 0.075, f.y-ground.y < 1.95,
                      let (u,v)=p.project(f), (0...1).contains(u), (0...1).contains(v) else { return nil }; return ahead
            }.min()
            if let elevated { bins[i].state = .occupied; bins[i].nearest=elevated; continue }
            guard reason == nil, let prev, prev.0.id.sameWorld(p.id), p.time-prev.0.time < 0.5 else { continue }
            var checked=0, contradicts=false
            for distance in [0.75,1.1,1.5,1.85] { for lateral in [-0.27,0,0.27] {
                var q=p.position+aim*distance+side*lateral; q.y=ground.y
                guard ground.contains(q),
                      let (u,v)=p.project(q), (0.025...0.975).contains(u), (0.025...0.975).contains(v),
                      let (a,b)=prev.0.project(q), (0.025...0.975).contains(a), (0.025...0.975).contains(b) else { continue }
                if let depth {
                    guard let measured=depth(p.sensor(u,v)) else { continue }
                    let expected=(q-p.position).dot(p.forward)
                    if measured < expected-0.14 { contradicts=true }; if abs(measured-expected)<0.13 { checked+=1 }
                } else {
                    let x=Int(u*96), y=Int(v*96), xx=Int(a*96), yy=Int(b*96)
                    var difference=0, minimum=255, maximum=0
                    for dy in -1...1 { for dx in -1...1 { let k=image.value(x+dx,y+dy); minimum=min(minimum,k); maximum=max(maximum,k); difference+=abs(k-prev.1.value(xx+dx,yy+dy)) } }
                    if difference>9*24 { contradicts=true }
                    // Require tracked floor returns on the same strip as well as current pixel agreement.
                    if difference<9*15, maximum-minimum>=4, features.contains(where:{ abs($0.y-ground.y)<0.075 && $0.groundDistance(q)<0.38 }) { checked+=1 }
                }
            } }
            if contradicts { bins[i].state = .occupied }
            else if checked==12 { bins[i].state = .free }
        }
        return .init(pose:p,visible:true,sectors:bins,hazards:hazards,reason:reason)
    }
}
