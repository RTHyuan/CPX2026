import Foundation

/// A session-local ground grid. Only the latest verified wedge sweeps may mark cells free.
struct LocalGrid {
    struct Key: Hashable { let x, z: Int }
    struct Cell { let state: CellState, time: Double, needsRecheck: Bool }
    private var cells: [Key: Cell] = [:]
    private var epoch: FrameID?
    private func key(_ p: V3) -> Key { Key(x: Int(floor(p.x / 0.25)), z: Int(floor(p.z / 0.25))) }
    mutating func update(_ observation: NearField) {
        let p = observation.pose
        if epoch?.sameWorld(p.id) != true { cells.removeAll(); epoch = p.id }
        cells = cells.filter { p.time - $0.value.time < 0.65 }
        guard p.normal && observation.visible else { cells.removeAll(); return }
        var current: [Key: CellState] = [:]
        for sector in observation.sectors {
            let a = (p.heading + Double(sector.angle)) * .pi / 180
            for depth in stride(from: 0.75, through: 1.85, by: 0.15) {
                let place = key(p.position + V3(sin(a), 0, -cos(a)) * depth)
                let state: CellState
                switch sector.state {
                case .free: state = observation.reason == nil ? .free : .unknown
                case .occupied: state = sector.nearest.map { abs($0 - depth) < 0.20 } == true ? .occupied : .unknown
                case .unknown: state = .unknown
                }
                if current[place] == .occupied { continue }
                if current[place] == .unknown && state == .free { continue }
                current[place] = state
            }
        }
        for (place, state) in current {
            let justCleared = cells[place]?.state == .occupied && state != .occupied
            let next: CellState = justCleared ? .unknown : state
            cells[place] = Cell(state: next, time: p.time, needsRecheck: justCleared || (cells[place]?.needsRecheck == true && state == .unknown))
        }
    }
    func state(at point: V3, time: Double) -> CellState {
        guard let cell = cells[key(point)], time - cell.time <= 0.65 else { return .unknown }; return cell.state
    }

    /// A current free sector can be vetoed by a recently occupied cell. No historical cell grants passage.
    mutating func reconcile(_ observation: NearField) -> NearField {
        update(observation)
        var result = observation
        let pose = observation.pose
        for i in result.sectors.indices where result.sectors[i].state == .free {
            let angle = (pose.heading + Double(result.sectors[i].angle)) * .pi / 180
            let direction = V3(sin(angle), 0, -cos(angle))
            for depth in stride(from: 0.75, through: 1.85, by: 0.15) {
                guard let cell = cells[key(pose.position + direction * depth)] else { continue }
                if cell.state == .occupied || cell.needsRecheck {
                    result.sectors[i].state = cell.state == .occupied ? .occupied : .unknown
                    break
                }
            }
        }
        return result
    }
}

/// Optional surveyed reference in floor-local metres (x east, z south). Never a clearance source.
struct PriorMap: Codable {
    struct Node: Codable { let id: String, x, z: Double, label: String?, goal: String? }
    struct Edge: Codable { let a, b: String, accessible: Bool }
    let version: Int, floor: String, nodes: [Node], edges: [Edge]
    struct Registration {
        let ax, az, bx, bz, cosA, sinA: Double
        func world(_ n: Node) -> V3 {
            let x=n.x-ax, z=n.z-az
            return V3(bx + cosA*x - sinA*z, 0, bz + sinA*x + cosA*z)
        }
    }
    func validate() throws {
        let ids = Set(nodes.map(\.id))
        guard version == 1, !floor.isEmpty, (2...256).contains(nodes.count), ids.count == nodes.count, edges.count <= 1024,
              nodes.allSatisfy({ !$0.id.isEmpty && $0.x.isFinite && $0.z.isFinite && abs($0.x) < 10000 && abs($0.z) < 10000 }),
              edges.allSatisfy({ ids.contains($0.a) && ids.contains($0.b) && $0.a != $0.b }) else { throw SpatialError.invalid }
    }
    func registration(_ anchors: [Landmark], at pose: FramePose) -> Registration? {
        let pairs: [(Node,V3)] = nodes.compactMap { node in
            guard let label=node.label, nodes.filter({$0.label == label}).count == 1 else { return nil }
            let matches=anchors.filter { $0.kind == .sign && $0.label == label && $0.last.id.sameWorld(pose.id) && pose.time-$0.last.time < 30 && $0.count >= 2 && $0.point != nil }
            guard matches.count == 1, let point=matches[0].point else { return nil }; return (node,point)
        }
        guard let a=pairs.first, let b=pairs.dropFirst().max(by:{ hypot($0.0.x-a.0.x,$0.0.z-a.0.z) < hypot($1.0.x-a.0.x,$1.0.z-a.0.z) }) else { return nil }
        let dx=b.0.x-a.0.x, dz=b.0.z-a.0.z, length=hypot(dx,dz)
        guard length >= 1.5, abs(length-a.1.groundDistance(b.1)) <= 0.32 else { return nil }
        let rot=atan2(b.1.z-a.1.z,b.1.x-a.1.x)-atan2(dz,dx)
        let transform=Registration(ax:a.0.x,az:a.0.z,bx:a.1.x,bz:a.1.z,cosA:cos(rot),sinA:sin(rot))
        return pairs.allSatisfy { transform.world($0.0).groundDistance($0.1) <= 0.35 } ? transform : nil
    }
    func nextPoint(for goal: String, from p: FramePose, anchors: [Landmark], level: String?) -> V3? {
        guard p.normal, level == nil || level == floor, let t=registration(anchors, at:p),
              let start=nodes.min(by:{ t.world($0).groundDistance(p.position) < t.world($1).groundDistance(p.position) }),
              t.world(start).groundDistance(p.position) < 2.5 else { return nil }
        let goals=nodes.filter { $0.goal == goal }; guard goals.count == 1, let end=goals.first, start.id != end.id else { return nil }
        var queue=[start.id], prev=[start.id:start.id], cursor=0
        while cursor<queue.count {
            let id=queue[cursor]; cursor+=1
            for edge in edges where edge.accessible && (edge.a == id || edge.b == id) {
                let next=edge.a == id ? edge.b:edge.a
                if prev[next] == nil { prev[next]=id; queue.append(next) }
            }
        }
        var next=end.id; guard prev[next] != nil else {return nil}
        while let parent=prev[next], parent != start.id { next=parent }
        return nodes.first { $0.id == next }.map(t.world)
    }
}

struct WalkMeasures: Encodable {
    struct PlanEvent: Encodable { let frame: FrameID, box: ImageBox, landmark: Int, directive: PlannerDirective, receivedAt: FrameID }
    var plans: [PlanEvent] = []
    var stepEvents: [StepEvent] = []
    struct Stop: Encodable { let detectedAt: Double; var requestedAt, speechStarted, speechEnded: Double? }
    private(set) var started: Double?, finished: Double?, fullScans = 0, peakSameStationSweeps = 0, stops: [Stop] = []
    private(set) var arrivedDoor: Int?, firstDoor: Int?, changedDoor = false, manuallyConfirmed = false
    private(set) var activeSeconds = 0.0, segments = 0, identityContinuous = true
    private var segmentStart: Double?, doorWorld: FrameID?
    private var scanOrigin: V3?, lastHeading: Double?, turnSum = 0.0, stationSweeps = 0, world: FrameID?
    enum CodingKeys: String, CodingKey { case plans, stepEvents, started, finished, activeSeconds, segments, identityContinuous, fullScans, peakSameStationSweeps, stops, firstDoor, arrivedDoor, changedDoor, manuallyConfirmed }
    mutating func start(_ t:Double) { self=Self(); started=t }
    mutating func openSegment(at time: Double) {
        if started == nil { start(time) }
        guard segmentStart == nil, finished == nil else { return }
        segmentStart = time; segments += 1
    }
    mutating func closeSegment(at time: Double) {
        guard let start = segmentStart else { return }
        activeSeconds += max(0, time-start); segmentStart = nil
    }
    mutating func sample(_ p:FramePose, scanning:Bool) {
        if let doorWorld, !doorWorld.sameWorld(p.id) { identityContinuous = false }
        guard p.normal, scanning else { lastHeading=nil; return }
        if world?.sameWorld(p.id) != true || scanOrigin.map({ $0.groundDistance(p.position)>0.65 }) != false {
            world=p.id; scanOrigin=p.position; lastHeading=nil; turnSum=0; stationSweeps=0
        }
        if let old=lastHeading { turnSum += turnAngle(p.heading-old) }; lastHeading=p.heading
        if abs(turnSum) >= 359.999 {
            turnSum -= turnSum<0 ? -360 : 360; fullScans+=1; stationSweeps+=1
            peakSameStationSweeps=max(peakSameStationSweeps,stationSweeps)
        }
    }
    mutating func hazard(at t:Double) { if stops.count < 200 { stops.append(.init(detectedAt:t)) } }
    mutating func requested(at t:Double) { if !stops.isEmpty, stops[stops.count-1].requestedAt == nil { stops[stops.count-1].requestedAt=t } }
    mutating func speech(at t:Double, ended:Bool) {
        guard let i=stops.indices.last, stops[i].requestedAt != nil else {return}
        if ended { if stops[i].speechStarted != nil && stops[i].speechEnded == nil { stops[i].speechEnded=t } }
        else if stops[i].speechStarted == nil { stops[i].speechStarted=t }
    }
    mutating func lock(_ door:Int, in frame:FrameID) {
        if let doorWorld, doorWorld.sameWorld(frame), let firstDoor { changedDoor = changedDoor || firstDoor != door }
        else if firstDoor == nil { firstDoor = door; doorWorld = frame }
        else { identityContinuous = false }
    }
    mutating func finish(_ t:Double, door:Int?, manual:Bool) { closeSegment(at:t); finished=t; arrivedDoor=door; manuallyConfirmed=manual }
}
