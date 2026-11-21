import Foundation

enum CellState: String, Codable { case unknown, free, occupied }
enum StepEvidence: Equatable {
    case horizontalBands, systemClassification, conflictingPlanes
    /// A landing measured in the AR world, on the walking strip of this sector.
    case measuredDrop(V3)
}
struct Sector: Equatable {
    let angle: Int
    var state: CellState
    var nearest: Double? = nil
    var stepEvidence: StepEvidence? = nil
    var hasMeasuredDrop: Bool {
        if case .measuredDrop = stepEvidence { return true }
        return false
    }
}
struct NearField {
    let pose: FramePose
    var visible: Bool
    var sectors: [Sector]
    var hazards: [Sighting]
    var reason: String? = nil
    var best: Int? { best(toward: 0) }
    func best(toward angle: Double) -> Int? {
        sectors.filter { $0.state == .free }.min { abs(Double($0.angle)-angle)+abs(Double($0.angle))*0.12 < abs(Double($1.angle)-angle)+abs(Double($1.angle))*0.12 }?.angle
    }
    var front: CellState { sectors.first { $0.angle == 0 }?.state ?? .unknown }
}

extension FramePose {
    var observesGround: Bool { (14...55).contains(pitchDown) }
    /// Check pitch and roll as well as heading when reusing a camera measurement.
    func sameView(as other: FramePose, within degrees: Double) -> Bool {
        let minimum = cos(degrees * .pi / 180)
        let up = V3(transform[4], transform[5], transform[6])
        let otherUp = V3(other.transform[4], other.transform[5], other.transform[6])
        return exif == other.exif && abs(turnAngle(heading - other.heading)) <= degrees &&
            forward.dot(other.forward) >= minimum && up.dot(otherUp) >= minimum
    }

    func stripIntersects(_ box: ImageBox, at angle: Int) -> Bool {
        guard box.valid, box.bottom > 0.38 else { return false }
        let mid = ray(box.center.0, box.bottom).heading
        let left = abs(turnAngle(ray(box.left, box.bottom).heading - mid))
        let right = abs(turnAngle(ray(box.right, box.bottom).heading - mid))
        return abs(turnAngle(mid - heading - Double(angle))) <= max(left, right) + 11
    }
}

/// A measured lip vetoes only walking strips that still intersect it, even after a rescan.
/// A world change discards these coordinates. Nearby observations are merged to bound storage.
private struct LocalDrops {
    private var points: [V3] = []

    mutating func observe(_ field: NearField) {
        guard field.pose.normal, field.visible else { return }
        points.removeAll { $0.groundDistance(field.pose.position) > 3.5 }
        for sector in field.sectors {
            guard case let .measuredDrop(point) = sector.stepEvidence,
                  !points.contains(where: { $0.groundDistance(point) < 0.12 }) else { continue }
            points.append(point)
        }
    }

    func blocks(_ pose: FramePose, angle: Double = 0) -> Bool {
        let a = (pose.heading + angle) * .pi / 180
        let along = V3(sin(a), 0, -cos(a)), across = V3(cos(a), 0, sin(a))
        return points.contains { point in
            let offset = point - pose.position
            return (-0.05...2.15).contains(offset.dot(along)) && abs(offset.dot(across)) <= 0.37
        }
    }

    func nearby(at pose: FramePose) -> Bool { points.contains { $0.groundDistance(pose.position) <= 2.2 } }
}

struct ScanCoverage {
    private(set) var seen = Set<Int>(), attempted = Set<Int>()
    private(set) var exhausted = false, hasAisle = false
    private(set) var exhaustionReported = false
    private var station: V3?, epoch: FrameID?
    private var aisleHeadings = Set<Int>()
    mutating func update(_ p: FramePose, visible: Bool, aisle: Bool) {
        if epoch?.sameWorld(p.id) != true || (station?.groundDistance(p.position) ?? 1) > 0.65 {
            self = Self(); station=p.position; epoch=p.id
        }
        let lo = turnAngle(p.ray(0.06,0.5).heading-p.heading), hi = turnAngle(p.ray(0.94,0.5).heading-p.heading)
        for i in 0..<24 where abs(turnAngle(Double(i*15)-p.heading)) <= min(48,max(8,min(abs(lo),abs(hi)))) {
            attempted.insert(i)
            if visible && p.normal { seen.insert(i) }
        }
        if visible && p.normal {
            let headingBin = (Int((p.heading / 15).rounded()) + 24) % 24
            if aisle { aisleHeadings.insert(headingBin) } else { aisleHeadings.remove(headingBin) }
        }
        hasAisle = !aisleHeadings.isEmpty
        exhausted = !hasAisle && (attempted.count == 24 || exhausted)
    }
    mutating func takeExhaustionNotice() -> LocalCue? {
        guard exhausted, !exhaustionReported else { return nil }
        exhaustionReported = true
        return .noConfirmedAisle
    }
    /// A newly identified landmark may refresh angular observations at this station. The
    /// completed-sweep notice remains pending or delivered until a fresh aisle is confirmed.
    mutating func retry() {
        seen.removeAll()
        attempted.removeAll()
        aisleHeadings.removeAll()
        hasAisle = false
    }
}

struct Alignment {
    private var since: Double?
    private(set) var latched = false
    mutating func sample(error: Double, time: Double) -> Bool {
        if abs(error) >= 16 { latched=false; since=nil }
        guard abs(error) <= 8 else { since=nil; return false }
        if since == nil { since=time }
        guard !latched, time-(since ?? time) >= 0.32 else { return false }
        latched=true; return true
    }
}
enum CueKind: Equatable { case wait, scan, turn, face, aligned, advance, stop, found, arrived, route }
struct LocalCue: Equatable {
    var kind: CueKind, text: String
    var isEmergency: Bool { kind == .stop }
    static let lookAround = Self(kind: .scan, text: "请慢慢环顾四周。")
    static let noConfirmedAisle = Self(kind: .wait, text: "暂时没找到可以确认的过道，请先站定。")
    static let revokeAdvance = Self(kind: .wait, text: "请先停步，重新确认前方通道。")
    static let dropStop = Self(kind: .stop, text: "请停步，前方可能有下行台阶。")
    static let obstacleStop = Self(kind: .stop, text: "先停一下。")
}
enum FrontHazard: String { case drop, person, obstacle }
struct DecisionTicket {
    let pose: FramePose, generation: Int, destination: String
    func current(at p: FramePose, generation current: Int, destination goal: String) -> Bool {
        pose.id.sameWorld(p.id) && p.normal && current == generation && goal == destination && p.time >= pose.time && p.time-pose.time <= 7 && p.position.groundDistance(pose.position) <= 0.38
    }
}
struct SpatialNavigator {
    var book = LandmarkBook(), scan = ScanCoverage()
    private var cloudBook = LandmarkBook()
    var priorWaypoint: V3?
    var canManuallyVerifyDoor: Bool { doorTarget && !emergency && current?.normal == true && door.map(doorsSeen.contains) == true }
    mutating func nearLost() {
        near = nil
        proofHistory.removeAll()
        confirmedAngles.removeAll()
        clearAlignment()
    }
    private(set) var current: FramePose?, near: NearField?, door: Int?, waypoint: Int?, generation = 0
    private(set) var summary: [FramePose] = []
    private(set) var doorsSeen = Set<Int>(), arrived = false, lastHazardAt: Double?
    private var aligned = Alignment(), bodyHeading: Double?, lastStation: V3?
    private var announcedDoor = false, lastNearTime = -Double.infinity
    private var proofHistory: [NearField] = [], confirmedAngles: Set<Int> = []
    private var drops = LocalDrops(), blockedSince: Double?, blockedKind: FrontHazard?
    private var stopOffered = false, advanceOffered = false
    private var relookHeading: Double?
    private var generationOrigin: V3?
    private var desiredHeading: Double?, aimOrigin: V3?, selectedAt = 0.0
    var cloudHold: LocalCue?, cloudHoldUntil = 0.0
    var lastInstruction = ""
    var doorTarget: Bool
    init(doorTarget: Bool) { self.doorTarget=doorTarget }
    /// The arbiter may supply actual speech delivery, including a suppressed .advance proposal.
    func safetyCue(forwardOutstanding: Bool) -> LocalCue? {
        if let hazard = frontHazard {
            if bypassAngle(for: hazard, forwardOutstanding: forwardOutstanding) != nil { return nil }
            return hazard == .drop ? .dropStop : .obstacleStop
        }
        if forwardOutstanding && !canAdvance { return .revokeAdvance }
        // cue() owns the one-shot end-of-sweep announcement.
        return hasFrontProof || waitingAtScannedStation ? nil : .lookAround
    }
    var cueForSafety: LocalCue? { safetyCue(forwardOutstanding: advanceOffered) }
    var hasFrontProof: Bool {
        guard let p = current, let n = near, fresh(n, p), confirmedAngles.contains(0) else { return false }
        return !drops.blocks(p)
    }
    /// Floor clearance and the user's confirmation are separate; moving cues require both.
    var canAdvance: Bool { hasFrontProof && aligned.latched && bodyHeading != nil }
    var frontHazard: FrontHazard? {
        guard let p = current, p.normal else { return nil }
        let observed = near.flatMap { fresh($0, p) && $0.visible ? $0 : nil }
        if let n = observed, n.hazards.contains(where: { $0.kind == .person && n.pose.stripIntersects($0.box, at: 0) }) {
            return .person
        }
        if drops.blocks(p) { return .drop }
        return observed?.front == .occupied ? .obstacle : nil
    }
    var emergency: Bool { frontHazard != nil }
    private var waitingAtScannedStation: Bool {
        scan.exhausted || (scan.exhaustionReported && confirmedAngles.isEmpty)
    }
    private func bypassAngle(for hazard: FrontHazard, forwardOutstanding: Bool) -> Int? {
        guard stopOffered, !forwardOutstanding, !arrived, hazard != .person,
              let p = current, let since = blockedSince, p.time - since > 1.25,
              let n = near, fresh(n, p), !n.hazards.contains(where: { $0.kind == .person }) else { return nil }
        return confirmedAngles.filter { $0 != 0 && !drops.blocks(p, angle: Double($0)) }
            .min { (abs($0), $0) < (abs($1), $1) }
    }
    private func fresh(_ n: NearField, _ p: FramePose) -> Bool {
        p.normal && n.pose.normal && p.id.sameWorld(n.pose.id) && (0...0.55).contains(p.time-n.pose.time) &&
            p.observesGround == n.pose.observesGround && (p.position-n.pose.position).length < 0.23 && p.sameView(as: n.pose, within: 10)
    }
    mutating func pose(_ p: FramePose) {
        if let previous=current, !previous.id.sameWorld(p.id) {
            let newGeneration = generation + 1, outstanding = advanceOffered
            self = Self(doorTarget: doorTarget)
            generation = newGeneration
            advanceOffered = outstanding
        }
        guard current.map({ p.time >= $0.time }) ?? true else { return }
        if !p.normal && current?.normal == true { invalidate(); nearLost() }
        if let origin=generationOrigin, origin.groundDistance(p.position)>0.38 { generation+=1; generationOrigin=p.position }
        if generationOrigin == nil {generationOrigin=p.position}
        current=p; book.expire(at:p.time); cloudBook.expire(at:p.time)
        if p.time-(summary.last?.time ?? -1e9) >= 0.5 { summary.append(p); if summary.count > 48 { summary.removeFirst() } }
        if let n = near, !fresh(n, p) { nearLost() }
        if let bodyHeading, abs(turnAngle(p.heading-bodyHeading)) > 18 { clearAlignment() }
        if let start=lastStation, start.groundDistance(p.position) > 0.25 {
            if abs(turnAngle((p.position-start).heading-p.heading)) > 38 { clearAlignment() }
            else { lastStation=p.position }
        }
        updateHazard(at: p.time)
    }
    private mutating func clearAlignment() {
        bodyHeading = nil
        lastStation = nil
        aligned = Alignment()
    }
    mutating func invalidate() {
        generation += 1
        clearAlignment()
        waypoint = nil
        desiredHeading = nil
        aimOrigin = nil
        cloudHold = nil
    }
    private mutating func updateHazard(at time: Double) {
        let hazard = frontHazard
        guard hazard != blockedKind else { return }
        blockedKind = hazard
        stopOffered = false
        blockedSince = hazard == nil ? nil : time
        if hazard != nil { lastHazardAt = time; invalidate() }
    }
    mutating func risk(_ raw: NearField) {
        guard let p = current, p.id.sameWorld(raw.pose.id), raw.pose.time > lastNearTime,
              (0...0.55).contains(p.time - raw.pose.time) else { return }
        lastNearTime = raw.pose.time
        drops.observe(raw)
        guard fresh(raw, p) else { updateHazard(at: p.time); return }
        let hadFrontProof = hasFrontProof
        var n = raw
        // Untyped .steps sightings from replay/semantic adapters are coarse image classifications.
        // Only GroundAssessment's measured geometry can create a persistent veto.
        let untyped = raw.hazards.filter { $0.kind == .steps }
        let measured = raw.sectors.contains(where: \.hasMeasuredDrop)
        for i in n.sectors.indices {
            let sector = n.sectors[i]
            let mobile = raw.hazards.contains { $0.kind.mobile && n.pose.stripIntersects($0.box, at: sector.angle) }
            if mobile || drops.blocks(n.pose, angle: Double(sector.angle)) {
                n.sectors[i].state = .occupied
            } else if !measured, sector.stepEvidence == nil, untyped.contains(where: { n.pose.stripIntersects($0.box, at: sector.angle) }) {
                n.sectors[i].stepEvidence = .systemClassification
                if sector.state == .free { n.sectors[i].state = .unknown }
            }
        }
        near = n
        // Three reprocessings of a capture, or three arrivals spread across a stale window,
        // cannot certify a walking strip. Keep the newest result for a repeated capture.
        proofHistory.removeAll { prior in
            n.pose.time - prior.pose.time > 0.55 || prior.pose.id.frame >= n.pose.id.frame
        }
        proofHistory.append(n)
        if proofHistory.count > 3 { proofHistory.removeFirst() }
        confirmedAngles.removeAll()
        if proofHistory.count == 3 && proofHistory.allSatisfy({ field in
            field.visible && field.reason == nil && field.pose.sameView(as: n.pose, within: 10) &&
                (field.pose.position - n.pose.position).length < 0.35
        }) {
            for sector in n.sectors where sector.state == .free {
                if proofHistory.allSatisfy({ $0.sectors.contains { $0.angle == sector.angle && $0.state == .free } }) {
                    confirmedAngles.insert(sector.angle)
                }
            }
        }
        scan.update(n.pose, visible: n.visible, aisle: !confirmedAngles.isEmpty)
        if hadFrontProof && !hasFrontProof { invalidate() }
        updateHazard(at: p.time)
    }
    mutating func recheck() {
        relookHeading = nil
        scan = ScanCoverage() // An explicit recheck opens another sweep at the same station.
        invalidate()
        nearLost()
        // The same world-space lip still exists after a user-requested scan.
    }
    mutating func faceForward() {
        guard let p = current, hasFrontProof, aligned.latched else { return }
        bodyHeading = p.heading
        lastStation = p.position
    }
    mutating func register(_ items: [Sighting], at p: FramePose, local: Bool, capturedSigns: [(Sighting, Int)] = []) -> [Int?] {
        guard let live=current, p.id.sameWorld(live.id), p.normal, live.time >= p.time, live.time-p.time < 120 else { return items.map { _ in nil } }
        var used=Set<Int>()
        let ids: [Int?] = items.map { item in
            if !local, item.kind == .sign {
                // Match only the OCR boxes actually sent on this capture, never a nearby sign in today's view.
                let matches = capturedSigns.filter { sighting, _ in
                    let center = sighting.box.center
                    return (item.box.left...item.box.right).contains(center.0) && (item.box.top...item.box.bottom).contains(center.1)
                }
                let match = matches.count == 1 ? matches[0].1 : nil
                if let match, used.contains(match) { return nil }
                let id = book.registerSemanticSign(item, at: p, localMatch: match)
                if let id { used.insert(id) }
                return id
            }
            guard live.time-p.time < 8 else { return nil }
            if !local {
                let (u,v) = item.box.center
                let matches = book.records.filter { r in r.kind == item.kind && r.last.id == p.id && !used.contains(r.id) && abs(r.box.center.0-u)<0.10 && abs(r.box.center.1-v)<0.13 }
                if matches.count == 1 { used.insert(matches[0].id); return matches[0].id }
                guard matches.isEmpty, let id=cloudBook.observe(item,at:p,excluding:Set(used.filter{$0<0}.map { -$0 })) else { return nil }
                used.insert(-id); return -id
            }
            let id=book.observe(item,at:p,excluding:used)
            if let id { used.insert(id)
                if local && item.kind == .door, let r=book.records.first(where:{$0.id == id}), r.count >= 2 {
                    doorsSeen.insert(id)

                }
            }; return id
        }
        if local && doorTarget && door == nil {
            let candidates = ids.compactMap { $0 }.filter(doorsSeen.contains)
            if candidates.count == 1 { door=candidates[0] }
            else if let near, near.visible, near.best != nil {
                let ranked = candidates.compactMap { id -> (Int, Double)? in
                    guard let bearing=record(id)?.bearing(at:live), let corridor=near.best(toward:bearing) else { return nil }
                    return (id, abs(turnAngle(bearing-Double(corridor))))
                }.sorted { $0.1 < $1.1 }
                door = ranked.first?.0
            }
            if door != nil { relookHeading=nil; if scan.exhausted {scan.retry()} }
        }
        return ids
    }
    mutating func select(_ id: Int) {
        guard let r=record(id), r.kind.waypoint else { return }
        if r.kind == .door && doorTarget { if let door, door != id { return }; if doorsSeen.contains(id) { door=id } }
        waypoint=id; desiredHeading=nil; cloudHold=nil
    }
    mutating func manualDoorArrival() -> Bool {
        guard doorTarget, !emergency, current?.normal == true, let door, doorsSeen.contains(door) else { return false }
        arrived=true; return true
    }
    func record(_ id: Int?) -> Landmark? {
        guard let id else { return nil }; return id < 0 ? cloudBook.records.first { $0.id == -id } : book.records.first { $0.id == id }
    }
    mutating func cue(forwardOutstanding: Bool? = nil) -> LocalCue? {
        guard let p = current else { return nil }
        let outstanding = forwardOutstanding ?? advanceOffered
        if let hazard = frontHazard {
            advanceOffered = false
            if let side = bypassAngle(for: hazard, forwardOutstanding: outstanding) {
                desiredHeading = p.heading + Double(side)
                aimOrigin = p.position
                selectedAt = p.time
                return .init(kind: .turn, text: "请原地" + turnText(Double(side)))
            }
            stopOffered = true
            return hazard == .drop ? .dropStop : .obstacleStop
        }
        if outstanding && !canAdvance {
            advanceOffered = false
            clearAlignment()
            return .revokeAdvance
        }
        if arrived { return .init(kind:.arrived,text:"已到教室门口，请停下。") }
        guard var n = near, fresh(n, p), n.visible else {
            return waitingAtScannedStation ? scan.takeExhaustionNotice() : .lookAround
        }
        let target=record(door), chosen=record(waypoint)
        if doorTarget, let target, doorsSeen.contains(target.id), let point=target.point,
           p.time-target.last.time < 0.8, target.count >= 3, target.box.bottom > 0.58,
           target.box.bottom-target.box.top > 0.43, abs(target.bearing(at:p) ?? 180) < 18,
           p.position.groundDistance(point) < 1.15, target.first.position.groundDistance(point)-p.position.groundDistance(point) > 0.40 {
            arrived=true; return .init(kind:.arrived,text:"已到教室门口，请停下。")
        }
        if let notice = scan.takeExhaustionNotice() { return notice }
        if doorTarget, let target, doorsSeen.contains(target.id), !announcedDoor, p.time-target.last.time < 1.4 {
            announcedDoor = true
            return .init(kind: .found, text: "找到门了。")
        }
        if waitingAtScannedStation { return nil }
        let avoidingDrop = drops.nearby(at: p)
        if avoidingDrop {
            for i in n.sectors.indices where n.sectors[i].state == .free && !confirmedAngles.contains(n.sectors[i].angle) {
                n.sectors[i].state = .unknown
            }
        }
        guard n.reason == nil, n.best != nil else { return .lookAround }
        if let hold=cloudHold, p.time < cloudHoldUntil { return hold }
        guard doorTarget || chosen != nil || priorWaypoint != nil else {
            return hasFrontProof ? nil : .lookAround
        }
        let bearing = chosen?.bearing(at:p) ?? target?.bearing(at:p) ?? priorWaypoint.map { turnAngle(($0-p.position).heading-p.heading) }
        let goal = bearing.flatMap { drops.blocks(p, angle: $0) ? nil : $0 }
        if let remembered = desiredHeading, drops.blocks(p, angle: turnAngle(remembered - p.heading)) { desiredHeading = nil }
        if let start=aimOrigin, start.groundDistance(p.position) > 0.8 || p.time-selectedAt > 10 {
            desiredHeading=nil; aimOrigin=nil
            if chosen?.kind == .aisle_entrance { waypoint=nil }
            if goal == nil { bodyHeading=nil; relookHeading=p.heading }
        }
        if let previous = relookHeading, goal == nil {
            guard abs(turnAngle(previous-p.heading)) >= 36, n.best != nil else {
                return .lookAround
            }
            relookHeading=nil
        }
        // Reserve an observed side aisle before aiming at a door behind rows of furniture.
        var angle: Double?
        if avoidingDrop { angle = n.best(toward: goal ?? 0).map(Double.init) }
        else if let goal, abs(goal) > 43 { angle=goal }
        else if let best=n.best(toward:goal ?? 0), let goal, abs(Double(best)-goal) <= 15 { angle=goal }
        else if let remembered=desiredHeading { angle=turnAngle(remembered-p.heading) }
        else if let best=n.best(toward:goal ?? 0) { angle=Double(best); desiredHeading=p.heading+Double(best); aimOrigin=p.position; selectedAt=p.time }
        if target != nil && target?.bearing(at:p) == nil && chosen == nil && n.best == 0 {
            return .init(kind:.scan,text:"请把镜头转向门框。")
        }
        guard let angle else { return .lookAround }
        if abs(angle) > 8 {
            if bodyHeading != nil { clearAlignment() }
            _ = aligned.sample(error: angle, time: p.time)
            if outstanding { advanceOffered = false; return .revokeAdvance }
            return .init(kind: .turn, text: (avoidingDrop ? "请原地" : "") + turnText(angle))
        }
        let justAligned = aligned.sample(error: angle, time: p.time)
        guard hasFrontProof else { return .lookAround }
        if justAligned { return .init(kind: .aligned, text: "方向已对准。") }
        guard aligned.latched else { return .init(kind: .wait, text: "保持手机朝向前方。") }
        guard canAdvance else { return .init(kind: .face, text: "请让手机朝向身体前方，确认后再移动。") }
        advanceOffered = true
        return .init(kind:.advance,text:"沿眼前过道慢行一小段。")
    }
    private func turnText(_ angle: Double) -> String {
        let degrees = min(60,max(15,Int((abs(angle)/15).rounded())*15))
        return "向\(angle<0 ? "左" : "右")转约\(degrees)度。"
    }
}
