import Foundation

enum CellState: String, Codable { case unknown, free, occupied }
struct Sector: Equatable {
    let angle: Int
    var state: CellState
    var nearest: Double? = nil
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

struct ScanCoverage {
    private(set) var seen = Set<Int>(), attempted = Set<Int>()
    private(set) var exhausted = false, hasAisle = false
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
        exhausted = attempted.count == 24 && !hasAisle
    }
    mutating func retry() { self = Self() }
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
}
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
    mutating func nearLost() { near=nil; goodFront=0 }
    private(set) var current: FramePose?, near: NearField?, door: Int?, waypoint: Int?, generation = 0
    private(set) var summary: [FramePose] = []
    private(set) var doorsSeen = Set<Int>(), arrived = false, lastHazardAt: Double?
    private var aligned = Alignment(), bodyHeading: Double?, lastStation: V3?
    private var goodFront = 0, lastKey: String?, announcedDoor = false, lastNearTime = -Double.infinity
    private var stepped = false, blockedSince: Double?
    private var relookHeading: Double?
    private var generationOrigin: V3?
    private var desiredHeading: Double?, aimOrigin: V3?, selectedAt = 0.0
    var cloudHold: LocalCue?, cloudHoldUntil = 0.0
    var lastInstruction = ""
    var doorTarget: Bool
    init(doorTarget: Bool) { self.doorTarget=doorTarget }
    var cueForSafety: LocalCue? {
        guard !hasFrontProof else { return nil }
        return emergency ? .init(kind:.stop,text:"先停一下。") : .init(kind:.wait,text:"请站定，重新确认眼前通道。")
    }
    var hasFrontProof: Bool {
        guard let p=current, let n=near, fresh(n,p), n.visible, n.front == .free, goodFront >= 3, n.reason == nil, !stepped else { return false }; return true
    }
    var emergency: Bool { guard let n=near, let p=current, fresh(n,p) else { return false }; return n.front == .occupied || stepped }
    private func fresh(_ n: NearField,_ p: FramePose) -> Bool {
        p.normal && p.id.sameWorld(n.pose.id) && p.time-n.pose.time <= 0.55 && p.position.groundDistance(n.pose.position) < 0.23 && abs(turnAngle(p.heading-n.pose.heading)) <= 10
    }
    mutating func pose(_ p: FramePose) {
        if let previous=current, !previous.id.sameWorld(p.id) {
            let newGeneration=generation+1; self=Self(doorTarget:doorTarget); generation=newGeneration
        }
        guard current.map({ p.time >= $0.time }) ?? true else { return }
        if !p.normal && current?.normal == true { invalidate(); near=nil; goodFront=0 }
        if let origin=generationOrigin, origin.groundDistance(p.position)>0.38 { generation+=1; generationOrigin=p.position }
        if generationOrigin == nil {generationOrigin=p.position}
        current=p; book.expire(at:p.time); cloudBook.expire(at:p.time)
        if p.time-(summary.last?.time ?? -1e9) >= 0.5 { summary.append(p); if summary.count > 48 { summary.removeFirst() } }
        if let bodyHeading, abs(turnAngle(p.heading-bodyHeading)) > 18 { self.bodyHeading=nil }
        if let start=lastStation, start.groundDistance(p.position) > 0.25 {
            if abs(turnAngle((p.position-start).heading-p.heading)) > 38 { bodyHeading=nil }; lastStation=p.position
        }
    }
    mutating func invalidate() { generation += 1; bodyHeading=nil; waypoint=nil; desiredHeading=nil; aligned=Alignment(); cloudHold=nil }
    mutating func risk(_ n: NearField) {
        guard let p=current, n.pose.id.sameWorld(p.id), n.pose.time > lastNearTime, p.time-n.pose.time <= 0.55 else { return }
        let consecutive = near.map { fresh($0, n.pose) } == true && n.pose.time-lastNearTime < 0.50
        lastNearTime=n.pose.time
        near=n; scan.update(n.pose, visible:n.visible, aisle:n.best != nil && n.reason == nil)
        let key = !n.visible || n.reason != nil ? (n.reason ?? "unknown") : n.front.rawValue
        if key != lastKey {
            if key != CellState.free.rawValue { invalidate() }
            lastKey=key
        }
        goodFront = n.visible && n.front == .free && n.reason == nil ? (consecutive ? min(5,goodFront+1) : 1) : 0
        if n.hazards.contains(where: { $0.kind == .steps && $0.box.left < 0.68 && $0.box.right > 0.32 }) { stepped=true }
        if n.front == .occupied || stepped {
            if blockedSince == nil { blockedSince=n.pose.time; lastHazardAt=n.pose.time }
        } else if goodFront >= 3 { blockedSince=nil }
    }
    mutating func recheck() { relookHeading=nil; scan.retry(); invalidate(); stepped=false; goodFront=0; near=nil; lastKey=nil; blockedSince=nil }
    mutating func faceForward() { guard let p=current, hasFrontProof, aligned.latched else { return }; bodyHeading=p.heading; lastStation=p.position }
    mutating func register(_ items: [Sighting], at p: FramePose, local: Bool) -> [Int?] {
        guard let live=current, p.id.sameWorld(live.id), p.normal, live.time-p.time < 8 else { return items.map { _ in nil } }
        var used=Set<Int>()
        let ids: [Int?] = items.map { item in
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
    mutating func cue() -> LocalCue? {
        guard let p=current else { return nil }
        if arrived { return .init(kind:.arrived,text:"已到教室门口，请停下。") }
        guard p.normal else { return .init(kind:.wait,text:"请先站定，正在重新确认位置。") }
        guard let n=near, fresh(n,p) else { return .init(kind:.wait,text:"先停一下，正在复核眼前通道。") }
        if stepped { return .init(kind:.stop,text:"先停一下。疑似台阶，请找人协助或寻找平坦通道。") }
        if n.front == .occupied {
            // After stopping at a static obstruction, propose a stationary pivot only.
            if let since=blockedSince, p.time-since > 1.25, n.visible, n.reason == nil,
               !n.hazards.contains(where:{$0.kind == .person}), let side=n.best, side != 0 {
                return .init(kind:.turn,text:"请保持站定，" + turnText(Double(side)))
            }
            return .init(kind:.stop,text:"先停一下。")
        }
        if !n.visible { return .init(kind:.wait,text:n.reason ?? "先停一下，镜头被遮挡或画面不清。") }
        let target=record(door), chosen=record(waypoint)
        if doorTarget, let target, doorsSeen.contains(target.id), !announcedDoor, p.time-target.last.time < 1.4 {
            announcedDoor=true; return .init(kind:.found,text:"找到门了。请站定核对通道。")
        }
        if doorTarget, let target, doorsSeen.contains(target.id), let point=target.point,
           p.time-target.last.time < 0.8, target.count >= 3, target.box.bottom > 0.58,
           target.box.bottom-target.box.top > 0.43, abs(target.bearing(at:p) ?? 180) < 18,
           p.position.groundDistance(point) < 1.15, target.first.position.groundDistance(point)-p.position.groundDistance(point) > 0.40 {
            arrived=true; return .init(kind:.arrived,text:"已到教室门口，请停下。")
        }
        if let reason=n.reason {return .init(kind:.wait,text:reason)}
        if scan.exhausted { return .init(kind:.wait,text:"暂时没找到可以确认的过道，请先站定。") }
        if let hold=cloudHold, p.time < cloudHoldUntil { return hold }
        guard doorTarget || chosen != nil || priorWaypoint != nil else {
            return hasFrontProof ? nil : .init(kind:.wait,text:"请先站定，正在复核眼前地面。")
        }
        let goal = chosen?.bearing(at:p) ?? target?.bearing(at:p) ?? priorWaypoint.map { turnAngle(($0-p.position).heading-p.heading) }
        if let start=aimOrigin, start.groundDistance(p.position) > 0.8 || p.time-selectedAt > 10 {
            desiredHeading=nil; aimOrigin=nil
            if chosen?.kind == .aisle_entrance { waypoint=nil }
            if goal == nil { bodyHeading=nil; relookHeading=p.heading }
        }
        if let previous = relookHeading, goal == nil {
            guard abs(turnAngle(previous-p.heading)) >= 36, n.best != nil else {
                return .init(kind:.scan,text:"请站定，转动手机重新查看两侧的门和过道。")
            }
            relookHeading=nil
        }
        // Reserve an observed side aisle before aiming at a door behind rows of furniture.
        var angle: Double?
        if let goal, abs(goal) > 43 { angle=goal }
        else if let best=n.best(toward:goal ?? 0), let goal, abs(Double(best)-goal) <= 15 { angle=goal }
        else if let remembered=desiredHeading { angle=turnAngle(remembered-p.heading) }
        else if let best=n.best(toward:goal ?? 0) { angle=Double(best); desiredHeading=p.heading+Double(best); aimOrigin=p.position; selectedAt=p.time }
        if target != nil && target?.bearing(at:p) == nil && chosen == nil && n.best == 0 {
            return .init(kind:.scan,text:"此前看到的门需要复核。请站定，把镜头转向门框。")
        }
        guard let angle else { return .init(kind:.scan,text:"请站定，慢慢转动手机寻找侧过道。") }
        if abs(angle) > 8 { _=aligned.sample(error:angle,time:p.time); return .init(kind:.turn,text:turnText(angle)) }
        if aligned.sample(error:angle,time:p.time) { return .init(kind:.aligned,text:"方向已对准。") }
        guard hasFrontProof else { return .init(kind:.wait,text:"先停一下，正在复核这一小段地面。") }
        guard aligned.latched else { return .init(kind:.wait,text:"请站定，保持当前朝向。") }
        guard bodyHeading != nil else { return .init(kind:.face,text:"请让手机朝向身体前方，确认后再移动。") }
        return .init(kind:.advance,text:"沿眼前过道慢行一小段。")
    }
    private func turnText(_ angle: Double) -> String {
        let degrees = min(60,max(15,Int((abs(angle)/15).rounded())*15))
        return "向\(angle<0 ? "左" : "右")转约\(degrees)度。"
    }
}
