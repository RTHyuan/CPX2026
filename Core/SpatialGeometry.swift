import Foundation

struct V3: Codable, Equatable {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: Self, b: Self) -> Self { .init(a.x+b.x, a.y+b.y, a.z+b.z) }
    static func - (a: Self, b: Self) -> Self { .init(a.x-b.x, a.y-b.y, a.z-b.z) }
    static func * (a: Self, k: Double) -> Self { .init(a.x*k, a.y*k, a.z*k) }
    func dot(_ b: Self) -> Double { x*b.x + y*b.y + z*b.z }
    var length: Double { sqrt(dot(self)) }
    var unit: Self { self * (1 / max(1e-12, length)) }
    var heading: Double { atan2(x, -z) * 180 / .pi }
    func groundDistance(_ b: Self) -> Double { hypot(x-b.x, z-b.z) }
}

func turnAngle(_ degrees: Double) -> Double {
    let value = degrees.truncatingRemainder(dividingBy: 360)
    return value > 180 ? value-360 : (value <= -180 ? value+360 : value)
}

/// Normalized, upright, top-left coordinates. Wire format is [left, top, right, bottom].
struct ImageBox: Codable, Equatable {
    var left, top, right, bottom: Double
    init(_ l: Double, _ t: Double, _ r: Double, _ b: Double) { left=l; top=t; right=r; bottom=b }
    var valid: Bool { left >= 0 && top >= 0 && right <= 1 && bottom <= 1 && left < right && top < bottom }
    var center: (Double, Double) { ((left+right)/2, (top+bottom)/2) }
    init(from decoder: Decoder) throws {
        let a = try [Double](from: decoder)
        guard a.count == 4 else { throw SpatialError.invalid }
        self.init(a[0], a[1], a[2], a[3]); guard valid else { throw SpatialError.invalid }
    }
    func encode(to encoder: Encoder) throws { try [left,top,right,bottom].encode(to: encoder) }
}
enum SpatialError: Error { case invalid }
struct FrameID: Codable, Equatable, Hashable {
    var session: UUID, world: Int, frame: Int
    func sameWorld(_ other: Self) -> Bool { session == other.session && world == other.world }
}
struct FramePose: Codable, Equatable {
    var id: FrameID, time: Double
    /// Column-major ARKit worldFromCamera and native sensor intrinsics.
    var transform, intrinsics: [Double]
    var width, height, exif: Int
    var tracking: String
    var headingDelta = 0.0, horizontalDelta = 0.0
    var position: V3 { V3(transform[12], transform[13], transform[14]) }
    var forward: V3 { V3(-transform[8], -transform[9], -transform[10]) }
    var heading: Double { forward.heading }
    var pitchDown: Double { asin(max(-1,min(1,-forward.y))) * 180 / .pi }
    var normal: Bool { tracking == "normal" && abs(pitchDown) < 76 }
    func sensor(_ u: Double, _ v: Double) -> (Double, Double) {
        switch exif { case 6: return (v,1-u); case 8: return (1-v,u); case 3: return (1-u,1-v); default: return (u,v) }
    }
    func upright(_ u: Double, _ v: Double) -> (Double, Double) {
        switch exif { case 6: return (1-v,u); case 8: return (v,1-u); case 3: return (1-u,1-v); default: return (u,v) }
    }
    func ray(_ u: Double, _ v: Double) -> V3 {
        let (x,y) = sensor(u,v)
        let a = (x*Double(width)-intrinsics[6])/intrinsics[0]
        let b = -(y*Double(height)-intrinsics[7])/intrinsics[4]
        return V3(transform[0]*a+transform[4]*b-transform[8], transform[1]*a+transform[5]*b-transform[9], transform[2]*a+transform[6]*b-transform[10]).unit
    }
    func project(_ point: V3) -> (Double,Double)? {
        let d = point-position
        let depth = forward.dot(d)
        guard depth > 0.05 else { return nil }
        let x = V3(transform[0],transform[1],transform[2]).dot(d)
        let y = V3(transform[4],transform[5],transform[6]).dot(d)
        return upright((intrinsics[0]*x/depth+intrinsics[6])/Double(width), (-intrinsics[4]*y/depth+intrinsics[7])/Double(height))
    }
}

enum FeatureKind: String, Codable, CaseIterable {
    case door, aisle_entrance, chair, stool, person, steps, obstacle, sign, junction
    var mobile: Bool { self == .chair || self == .stool || self == .person || self == .obstacle }
    var waypoint: Bool { [.door,.aisle_entrance,.sign,.junction].contains(self) }
}
struct Sighting: Equatable, Codable {
    var kind: FeatureKind, box: ImageBox, confidence: Double
    var label: String? = nil
    // A coarse local appearance descriptor for ambiguous rays. Never sent to the provider.
    var appearance: UInt64? = nil
}
struct Landmark: Equatable {
    var id: Int, kind: FeatureKind, first: FramePose, last: FramePose
    var firstRay: V3, ray: V3, box: ImageBox, confidence: Double
    var label: String?, appearance: UInt64?, point: V3?, count: Int
    func bearing(at pose: FramePose) -> Double? {
        guard pose.id.sameWorld(last.id), pose.normal else { return nil }
        if let point { return turnAngle((point-pose.position).heading-pose.heading) }
        guard last.position.groundDistance(pose.position) <= 0.38 else { return nil }
        return turnAngle(ray.heading-pose.heading)
    }
    static func intersection(_ a: V3, _ u: V3, _ b: V3, _ v: V3) -> V3? {
        let w = a-b, c = u.dot(v), det = 1-c*c
        guard a.groundDistance(b) >= 0.32, c > 0, det > 0.008 else { return nil }
        let s = (c*v.dot(w)-u.dot(w))/det, t = (v.dot(w)-c*u.dot(w))/det
        guard (0.25...18).contains(s), (0.25...18).contains(t) else { return nil }
        let p = a+u*s, q = b+v*t
        guard (p-q).length < min(0.16, 0.03+0.022*min(s,t)) else { return nil }
        return (p+q)*0.5
    }
}
struct LandmarkBook {
    private(set) var records: [Landmark] = []
    private var nextID = 1
    mutating func expire(at t: Double) {
        records.removeAll { t-$0.last.time > ($0.kind.mobile ? 0.7 : ($0.kind == .aisle_entrance ? 3 : 120)) }
    }
    /// One observation per landmark per frame. Ambiguous matches never inherit the locked identity.
    @discardableResult mutating func observe(_ item: Sighting, at p: FramePose, excluding used: Set<Int> = []) -> Int? {
        guard p.normal, item.box.valid, item.confidence >= 0.55 else { return nil }
        let (u,v) = item.box.center, ray = p.ray(u,v)
        let candidates: [(Int,Double)] = records.indices.compactMap { i in
            let r = records[i]
            guard r.kind == item.kind, r.last.id.sameWorld(p.id), r.last.time <= p.time,
                  !used.contains(r.id), r.label == item.label || r.label == nil || item.label == nil else { return nil }
            let gap = r.last.position.groundDistance(p.position)
            let similar = r.appearance.flatMap { a in item.appearance.map { (a ^ $0).nonzeroBitCount } }
            if let similar, similar > 22 { return nil }
            let expected = r.point.map { ($0-p.position).unit } ?? r.ray
            let angle = acos(min(1,max(-1,expected.dot(ray)))) * 180 / .pi
            let identity = (similar.map { $0 <= 13 } ?? false) || (r.label != nil && r.label == item.label)
            if r.point == nil && gap > 0.40 {
                guard identity || (gap < 0.95 && p.time-r.last.time < 1.8 && records.filter({ $0.kind == item.kind }).count == 1),
                      Landmark.intersection(r.first.position,r.firstRay,p.position,ray) != nil else { return nil }
            }
            let limit = r.point != nil ? 6.0 : (gap > 0.18 ? 17.0 : 5.0)
            guard angle < limit else { return nil }; return (i,angle)
        }.sorted { $0.1 < $1.1 }
        if candidates.count > 1 && candidates[1].1-candidates[0].1 < 2.0 { return nil }
        if let i = candidates.first?.0 {
            var r = records[i]
            if r.last.id != p.id {
                r.count += 1
                if !r.kind.mobile, let hit = Landmark.intersection(r.first.position,r.firstRay,p.position,ray) {
                    if let prior = r.point { if (prior-hit).length < 0.35 { r.point = prior*0.75 + hit*0.25 } }
                    else { r.point = hit }
                }
            }
            r.last=p; r.ray=ray; r.box=item.box; r.confidence=item.confidence
            records[i]=r; return r.id
        }
        guard records.count < 96 else { return nil }
        let id = nextID; nextID += 1
        records.append(.init(id:id, kind:item.kind, first:p, last:p, firstRay:ray, ray:ray, box:item.box, confidence:item.confidence, label:item.label, appearance:item.appearance, point:nil, count:1))
        return id
    }
}
