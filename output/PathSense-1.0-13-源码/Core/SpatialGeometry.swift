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
    fileprivate func containsCenter(of other: Self) -> Bool {
        let (u, v) = other.center
        return (left...right).contains(u) && (top...bottom).contains(v)
    }
    func overlap(with other: Self) -> Double {
        let width = max(0, min(right, other.right) - max(left, other.left))
        let height = max(0, min(bottom, other.bottom) - max(top, other.top))
        let union = (right-left)*(bottom-top) + (other.right-other.left)*(other.bottom-other.top) - width*height
        return union > 0 ? width*height/union : 0
    }
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
    var sign: SignMeaning? = nil
}
struct Landmark: Equatable {
    var id: Int, kind: FeatureKind, first: FramePose, last: FramePose
    var firstRay: V3, ray: V3, box: ImageBox, confidence: Double
    var label: String?, appearance: UInt64?, point: V3?, count: Int
    var sign: SignMeaning? = nil
    private(set) var signCapture: FramePose? = nil
    var signObservedAt: Double? { signCapture?.time }
    private(set) var signConflict = false
    fileprivate(set) var hasLocalSign = false
    fileprivate(set) var labelCapture: FramePose? = nil
    var labelObservedAt: Double? { labelCapture?.time }
    static let signLifetime = 120.0

    /// Updating the box alone does not mean the inscription was read from the new pose.
    var lastReadPose: FramePose {
        if let labelCapture, labelCapture.time >= (signObservedAt ?? -.infinity) { return labelCapture }
        return signCapture ?? last
    }

    /// A cloud reply contributes facts at its capture time. Conflicting readings need a fresh frame.
    fileprivate mutating func remember(_ meaning: SignMeaning, at capture: FramePose) {
        let time = capture.time
        let previous = signObservedAt ?? -.infinity
        guard time >= previous, !(time == previous && signConflict) else { return }
        let contradictsLocal = label.map { !meaning.agrees(withLocal: $0) } ?? false
        if contradictsLocal || (time - previous < Self.signLifetime && sign?.agrees(with: meaning) == false) {
            sign = nil
            signConflict = true
            signCapture = capture
            return
        }
        sign = signObservedAt == time ? sign?.addingDetails(from: meaning) ?? meaning : meaning
        signCapture = capture
        signConflict = false
    }

    fileprivate mutating func expireReadings(at time: Double) {
        if let seen = signObservedAt, time - seen >= Self.signLifetime { sign = nil; signConflict = false }
        if let seen = labelObservedAt, time - seen >= Self.signLifetime { label = nil }
    }

    /// Project the previous sign footprint through a rotation or a triangulated position.
    /// This distinguishes adjacent rows whose centre rays fall inside the same angular gate.
    /// The returned upright box can extend outside the current image.
    func projectedBox(at pose: FramePose) -> ImageBox? {
        if last == pose { return box }
        let corners = [(box.left, box.top), (box.right, box.top), (box.left, box.bottom), (box.right, box.bottom)]
        let depth = point.map { last.forward.dot($0 - last.position) }
        let projected = corners.compactMap { u, v -> (Double, Double)? in
            let direction = last.ray(u, v)
            if let depth { return pose.project(last.position + direction * (depth / last.forward.dot(direction))) }
            return pose.project(pose.position + direction)
        }
        guard projected.count == 4 else { return nil }
        let xs = projected.map(\.0), ys = projected.map(\.1)
        guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else { return nil }
        return ImageBox(left, top, right, bottom)
    }
    func bearing(at pose: FramePose) -> Double? {
        guard pose.id.sameWorld(last.id), pose.normal else { return nil }
        if let point { return turnAngle((point-pose.position).heading-pose.heading) }
        guard last.position.groundDistance(pose.position) <= 0.38 else { return nil }
        return turnAngle(ray.heading-pose.heading)
    }
    /// A retained survey ray can point the camera back to its subject. Issuing another
    /// step also requires a recent observation of that particular landmark.
    func recentlyObservedForStep(at time: Double) -> Bool {
        (0...(kind == .aisle_entrance ? 3.0 : 8.0)).contains(time - last.time)
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
    private struct SignFrame {
        let pose: FramePose
        var localBoxes: [Int: ImageBox] = [:]
        var cloudBoxes: [Int: ImageBox] = [:]
    }
    private var signFrames: [FrameID: SignFrame] = [:]
    private var latestTime = -Double.infinity
    mutating func expire(at t: Double, preserving selected: Set<Int> = []) {
        latestTime = max(latestTime, t)
        records.removeAll { record in
            if record.kind.waypoint && selected.contains(record.id) { return false }
            let lifetime = record.kind.mobile ? 0.7 : (record.kind == .aisle_entrance ? 3 : Landmark.signLifetime)
            return t - record.last.time > lifetime
        }
        for i in records.indices where records[i].kind == .sign { records[i].expireReadings(at: t) }
    }

    private mutating func keepSignFrame(_ capture: FramePose) {
        guard signFrames[capture.id] == nil else { return }
        // At one keyframe per 0.55 s this covers the entire sign lifetime; forced bursts are bounded too.
        if signFrames.count >= 256, let oldest = signFrames.min(by: { $0.value.pose.time < $1.value.pose.time }) {
            signFrames.removeValue(forKey: oldest.key)
        }
        signFrames[capture.id] = SignFrame(pose: capture)
    }

    /// `localMatch` identifies a local observation in the original image. Its newer geometry
    /// and OCR label belong to the local tracker. An unmatched sign has its own map identity.
    @discardableResult mutating func registerSemanticSign(_ item: Sighting, at capture: FramePose, localMatch: Int?) -> Int? {
        guard item.kind == .sign, capture.time.isFinite, capture.normal, item.box.valid,
              (0.55...1).contains(item.confidence), latestTime - capture.time < Landmark.signLifetime else { return nil }
        let frame = signFrames[capture.id]
        if let frame, frame.pose != capture { return nil }
        let enclosed = frame?.localBoxes.filter { item.box.containsCenter(of: $0.value) } ?? [:]
        var meaning = item.sign
        if enclosed.count > 1 { meaning?.arrow = nil }
        if let id = localMatch {
            guard enclosed.count == 1, enclosed[id] != nil, let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            if let meaning { records[index].remember(meaning, at: capture) }
            signFrames[capture.id]?.cloudBoxes[id] = item.box
            return id
        }
        if let id = frame?.cloudBoxes.first(where: { $0.value == item.box })?.key,
           let index = records.firstIndex(where: { $0.id == id }) {
            if let meaning { records[index].remember(meaning, at: capture) }
            return id
        }
        // A whole directory can contain several local OCR rows. Never choose one of them
        // merely because its ray is close to the centre of the board.
        var excluded = Set(records.lazy.filter(\.hasLocalSign).map(\.id))
        // Distinct boxes in one cloud exposure can be adjacent, even with the same legend.
        // Exact replays returned above already have an identity in that exposure.
        if let frame { excluded.formUnion(frame.cloudBoxes.keys) }
        let cloud = Sighting(kind: .sign, box: item.box, confidence: item.confidence, sign: meaning)
        guard let id = track(cloud, at: capture, excluding: excluded, local: false) else { return nil }
        keepSignFrame(capture)
        signFrames[capture.id]?.cloudBoxes[id] = item.box
        return id
    }
    /// One observation per landmark per frame. Ambiguous matches never inherit the locked identity.
    @discardableResult mutating func observe(_ item: Sighting, at p: FramePose, excluding used: Set<Int> = []) -> Int? {
        let id = track(item, at: p, excluding: used, local: true)
        if item.kind == .sign, let id {
            keepSignFrame(p)
            signFrames[p.id]?.localBoxes[id] = item.box
        }
        return id
    }
    private mutating func track(_ item: Sighting, at p: FramePose, excluding used: Set<Int>, local: Bool) -> Int? {
        guard p.normal, item.box.valid, item.confidence >= 0.55 else { return nil }
        latestTime = max(latestTime, p.time)
        let (u,v) = item.box.center, ray = p.ray(u,v)
        let candidates: [(Int,Double)] = records.indices.compactMap { i in
            let r = records[i]
            guard r.kind == item.kind, r.last.id.sameWorld(p.id), r.last.time <= p.time,
                  !used.contains(r.id) else { return nil }
            if item.kind != .sign, let old = r.label, let new = item.label, old != new { return nil }
            let gap = r.last.position.groundDistance(p.position)
            let similar = r.appearance.flatMap { a in item.appearance.map { (a ^ $0).nonzeroBitCount } }
            if let similar, similar > 22 { return nil }
            let expected = r.point.map { ($0-p.position).unit } ?? r.ray
            let angle = acos(min(1,max(-1,expected.dot(ray)))) * 180 / .pi
            var identity = (similar.map { $0 <= 13 } ?? false) || (r.label != nil && r.label == item.label)
            if item.kind == .sign {
                guard p.time-r.last.time < Landmark.signLifetime else { return nil }
                if let known = r.label ?? r.sign?.text, let incoming = item.label ?? item.sign?.text {
                    guard WayfindingParser.compatibleInscription(known, incoming) else { return nil }
                    identity = true
                }
                if gap > 0.38 && r.point == nil && !identity { return nil }
                // Two rows remain distinct even with identical labels. Parallax needs a known
                // point or independent identity evidence before relaxing the image-space gate.
                if r.point != nil || gap < 0.08 || !identity {
                    guard let expectedBox = r.projectedBox(at: p), expectedBox.overlap(with: item.box) >= 0.40 else { return nil }
                }
            }
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
            if item.kind == .sign {
                r.expireReadings(at: p.time)
                if local { r.hasLocalSign = true }
                if let label = item.label {
                    r.label = label
                    r.labelCapture = p
                    if let prior = r.sign, !prior.agrees(withLocal: label) { r.remember(prior, at: p) }
                }
                if let meaning = item.sign { r.remember(meaning, at: p) }
            }
            records[i]=r; return r.id
        }
        guard records.count < 96 else { return nil }
        let id = nextID; nextID += 1
        var record = Landmark(id:id, kind:item.kind, first:p, last:p, firstRay:ray, ray:ray, box:item.box, confidence:item.confidence, label:item.label, appearance:item.appearance, point:nil, count:1)
        if item.kind == .sign {
            record.hasLocalSign = local
            if item.label != nil { record.labelCapture = p }
            if let meaning = item.sign { record.remember(meaning, at: p) }
        }
        records.append(record)
        return id
    }
}
