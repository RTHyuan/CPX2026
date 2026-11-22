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
    var stepCoverage: StepCoverage? = nil
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
    var hasDepthMap = false, hasConfidenceMap = false
    /// Exposure and tracking allow a holding-angle hint even when LiDAR has no usable returns.
    var canCoachFraming = false
    var liveStepView: LiveStepView? = nil
    var best: Int? { best(toward: 0) }
    func best(toward angle: Double, among allowed: Set<Int>? = nil) -> Int? {
        let available = sectors.filter { $0.state == .free && (allowed?.contains($0.angle) ?? true) }
        func cost(_ sector: Sector) -> Double {
            abs(turnAngle(Double(sector.angle) - angle)) + abs(Double(sector.angle)) * 0.12
        }
        return available.min { (cost($0), $0.angle) < (cost($1), $1.angle) }?.angle
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
    struct Observation { let point: V3, frame: FrameID, time: Double }
    private var records: [Observation] = []

    mutating func observe(_ field: NearField) {
        guard field.pose.normal, field.visible else { return }
        for sector in field.sectors {
            guard case let .measuredDrop(point) = sector.stepEvidence else { continue }
            let sighting = Observation(point: point, frame: field.pose.id, time: field.pose.time)
            if let index = records.firstIndex(where: { $0.point.groundDistance(point) < 0.12 }) { records[index] = sighting }
            else { records.append(sighting) }
        }
        if records.count > 256 { records.sort { $0.time > $1.time }; records.removeLast(records.count - 256) }
    }

    func blocks(_ pose: FramePose, angle: Double = 0) -> Bool {
        let a = (pose.heading + angle) * .pi / 180
        let along = V3(sin(a), 0, -cos(a)), across = V3(cos(a), 0, sin(a))
        return records.contains { observation in
            let offset = observation.point - pose.position
            return (-0.05...2.15).contains(offset.dot(along)) && abs(offset.dot(across)) <= 0.37
        }
    }

    func nearby(at pose: FramePose) -> Bool { records.contains { $0.point.groundDistance(pose.position) <= 2.2 } }
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
    var isAvoidanceTurn = false
    var permitID: UUID? = nil
    var isEmergency: Bool { kind == .stop }
    static let obstacleAtRest = Self(kind: .wait, text: "前方有障碍，请留在原地，查看两侧过道。")
    static let personAtRest = Self(kind: .wait, text: "前方有人，等对方通过后再观察。")
    static let dropAtRest = Self(kind: .wait, text: "前方可能有落差，请原地观察两侧的平坦过道。")
    static let uncheckedMotion = Self(kind: .stop, text: "请停步，重新观察脚前。")
    static let stepReview = Self(kind: .wait, text: "还不能确认这一步是否完成。站稳后点重新扫描。")
    static let verifyCrossingView = Self(kind: .scan, text: "请站定，观察门外的走廊或当前位置牌，核对是否已经出门。")
    static let findStepTarget = Self(kind: .scan, text: "请原地观察，寻找下一处过道、门或路线标识。")
    static let inspectStep = Self(kind: .scan, text: "把手机朝前适度下倾，让脚前、落脚处和身体前方都入镜。")
    static let lookAround = Self(kind: .scan, text: "请慢慢环顾四周。")
    static let noConfirmedAisle = Self(kind: .wait, text: "暂时没找到可以确认的过道。请站定，向身边的人求助。")
    static let revokeAdvance = Self(kind: .wait, text: "请先停步，重新确认前方通道。")
    static let dropStop = Self(kind: .stop, text: "请停步，前方可能有下行台阶。留在原地，向两侧扫找平坦过道。")
    static let obstacleStop = Self(kind: .stop, text: "先停一下。")
    static let tiltDown = Self(kind: .scan, text: "要查看过道，请把手机朝前，向下倾约三十度。")
    static let liftPhone = Self(kind: .scan, text: "请把手机稍微抬起，让前方过道也入镜。")
    static let scanSideGround = Self(kind: .scan, text: "还没看清过道。保持这个角度，把手机慢慢转向两侧。")
    static let inspectBody = Self(kind: .scan, text: "请稍微抬起手机，补看身体前方，再看落脚处。")
    var isFramingHint: Bool { self == .tiltDown || self == .liftPhone || self == .scanSideGround || self == .inspectStep || self == .inspectBody }
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
    private(set) var plannedExit: Int?, crossing: MappedDoorCrossing?
    private var localExitMatch: Int?
    private struct CompletedAisle { let id: Int, station: V3, mappedEntrance: V3? }
    private var completedAisles: [CompletedAisle] = []
    private var selectedStrip: (id: Int, origin: FramePose, heading: Double)?
    var priorWaypoint: V3?
    private var selectedDoorIsLocal: Bool { door.map { doorsSeen.contains($0) || ($0 == plannedExit && localExitMatch.map(doorsSeen.contains) == true) } == true }
    var canManuallyVerifyDoor: Bool { doorTarget && !emergency && current?.normal == true && selectedDoorIsLocal && (!requiresPlannedTarget || waypoint == door) }
    mutating func nearLost() {
        near = nil
        framing = nil
        proofHistory.removeAll()
        confirmedAngles.removeAll()
        if let p = current, execution.active != nil { revokeStep("nearEvidenceLost", at: p.time) }
        if bodyHeading == nil { aligned = Alignment() }
    }
    private(set) var current: FramePose?, near: NearField?, door: Int?, waypoint: Int?, generation = 0
    private(set) var summary: [FramePose] = []
    private(set) var doorsSeen = Set<Int>(), arrived = false, lastHazardAt: Double?
    private var aligned = Alignment(), bodyHeading: Double?, lastStation: V3?
    private var announcedDoor = false, lastNearTime = -Double.infinity
    private var framing: (hint: LocalCue, since: Double)?
    private var proofHistory: [NearField] = [], confirmedAngles: Set<Int> = []
    private var drops = LocalDrops(), blockedSince: Double?, blockedKind: FrontHazard?
    private var stopOffered = false
    private var execution = StepExecution()
    private var urgentHazard: FrontHazard?, lostWhileMoving = false
    private var task = StepTarget(destination: "", task: "观察近处过道", revision: 0, landmarkID: nil, localOpeningHeading: nil)
    var activeStep: StepPermit? { execution.active }
    var stepPhase: StepPhase { execution.phase }
    var stepIsMoving: Bool { execution.moving }
    mutating func takeStepEvents() -> [StepEvent] { execution.drain() }
    var stepNeedsReview: Bool { execution.needsReview }
    mutating func confirmStepReview() { execution.confirmReview(current) }
    private var stepTarget: StepTarget {
        var t = task
        t.landmarkID = task.task == PlannerTask.verifyCrossing.rawValue ? crossing?.id : (waypoint ?? (doorTarget && !requiresPlannedTarget ? door : nil))
        if let bypass { t.localOpeningHeading = bypass.heading }
        else if t.landmarkID == nil { t.localOpeningHeading = desiredHeading }
        return t
    }
    mutating func setStepTask(destination: String, task name: String, revision: Int) {
        guard task.destination != destination || task.task != name || task.revision != revision else { return }
        invalidate(); task = .init(destination: destination, task: name, revision: revision, landmarkID: nil, localOpeningHeading: nil)
    }
    mutating func revokeStep(_ reason: String, at now: Double) {
        if execution.active?.spokenAt != nil && execution.moving { lostWhileMoving = true }
        execution.close(.revoked, reason, at: now, pose: current)
    }
    func permitsSpeech(_ cue: LocalCue, at now: Double) -> Bool {
        guard cue.kind == .advance, let id = cue.permitID else { return false }
        guard let check = latestStepCheck, check.coverage.allSatisfy({ $0.bodyTime.map { (0...0.65).contains(now - $0) } ?? true }) else { return false }
        return execution.permits(id, at: now, pose: current, target: stepTarget, proof: canAdvance)
    }
    mutating func submittedStep(_ id: UUID, at now: Double) {
        guard permitsSpeech(.init(kind: .advance, text: "", permitID: id), at: now) else { return }
        execution.submit(id, at: now, pose: current)
    }
    @discardableResult mutating func stepSpeechStarted(_ id: UUID, at now: Double) -> Bool {
        guard permitsSpeech(.init(kind: .advance, text: "", permitID: id), at: now) else {
            if activeStep?.id == id, activeStep?.spokenAt == nil { revokeStep("speechStartNoLongerValid", at: now) }
            return false
        }
        guard let proof = latestStepCheck else { return false }
        return execution.started(id, at: now, pose: current, proof: proof)
    }
    mutating func stepSpeechEnded(_ id: UUID, at now: Double) { execution.speechEnded(id, at: now, pose: current) }
    mutating func cancelStepSpeech(_ id: UUID, at now: Double) { execution.cancelSpeech(id, at: now, pose: current) }
    private var latestStepCheck: StepCheck? {
        guard let p = current, hasFrontProof, proofHistory.count == 3 else { return nil }
        // A bearing survey tolerates some camera movement. The footprint for this step
        // must have been sampled at the station and heading where it will be spoken.
        guard proofHistory.allSatisfy({ field in
            field.pose.time > execution.barrier && (0...0.55).contains(p.time - field.pose.time) &&
                (p.position - field.pose.position).length <= 0.075 && p.sameView(as: field.pose, within: 7)
        }) else { return nil }
        let coverage = proofHistory.compactMap { f in f.sectors.first { $0.angle == 0 && $0.state == .free }?.stepCoverage }
        guard coverage.count == 3, coverage.allSatisfy({ $0.isCurrent(at: p, after: execution.barrier) }) else { return nil }
        return .init(origin: p, frames: proofHistory.map { $0.pose.id }, times: proofHistory.map { $0.pose.time }, coverage: coverage)
    }
    private func stationary(_ hazard: FrontHazard) -> LocalCue {
        switch hazard { case .person: return .personAtRest; case .obstacle: return .obstacleAtRest; case .drop: return .dropAtRest }
    }
    private var generationOrigin: V3?
    private var desiredHeading: Double?, aimOrigin: V3?, selectedAt = 0.0
    private var bypass: (world: FrameID, heading: Double, origin: V3)?
    // A planner may ask to see more. Its wording is only eligible during a local search.
    var cloudHold: LocalCue?, cloudHoldUntil = 0.0
    var verifyingRoute = false {
        didSet { if verifyingRoute && !oldValue, let p = current { revokeStep("verifyingRoute", at: p.time) } }
    }
    var lastInstruction = ""
    var doorTarget: Bool
    var requiresPlannedTarget: Bool {
        didSet { if requiresPlannedTarget && !oldValue && stepTarget.landmarkID == nil, let p = current { revokeStep("noPlannedTarget", at: p.time) } }
    }
    init(doorTarget: Bool, requiresPlannedTarget: Bool = false) {
        self.doorTarget = doorTarget; self.requiresPlannedTarget = requiresPlannedTarget
    }
    /// The arbiter may supply actual speech delivery, including a suppressed .advance proposal.
    func safetyCue(forwardOutstanding: Bool) -> LocalCue? {
        if let hazard = frontHazard {
            if urgentHazard != nil || execution.moving || execution.unauthorizedMotion { return hazard == .drop ? .dropStop : .obstacleStop }
            if bypassAngle(for: hazard, forwardOutstanding: false) != nil { return nil }
            return stationary(hazard)
        }
        if lostWhileMoving || execution.unauthorizedMotion { return .uncheckedMotion }
        if execution.needsReview { return .stepReview }
        return hasFrontProof || waitingAtScannedStation ? nil : .lookAround
    }
    var cueForSafety: LocalCue? { safetyCue(forwardOutstanding: false) }
    var hasFrontProof: Bool {
        guard let p = current, let n = near, fresh(n, p), confirmedAngles.contains(0) else { return false }
        return !drops.blocks(p)
    }
    /// Floor clearance and the user's confirmation are separate; moving cues require both.
    var canAdvance: Bool {
        guard let p = current, !arrived, !verifyingRoute, latestStepCheck != nil, aligned.latched, let bodyHeading,
              abs(turnAngle(p.heading - bodyHeading)) <= 12, !execution.needsReview, !execution.unauthorizedMotion else { return false }
        if let id = stepTarget.landmarkID {
            guard let bearing = stepBearing(id, at: p), targetObserved(id, at: p) else { return false }
            return abs(bypass.map { turnAngle($0.heading - p.heading) } ?? bearing) <= 8
        }
        guard !requiresPlannedTarget else { return false }
        let aim = bypass?.heading ?? desiredHeading ?? p.heading
        return abs(turnAngle(aim - p.heading)) <= 8
    }
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
        guard crossing == nil, !arrived, !verifyingRoute, hazard != .person, let p = current, let since = blockedSince,
              let field = near, fresh(field, p) else { return nil }
        // A measured object beyond the close zone can be steered around before an
        // advance is issued. A moving user, person, drop or unmeasured object gets the stop first.
        let distantObject = hazard == .obstacle && field.sectors.first(where: { $0.angle == 0 })?.nearest.map { $0 > 1.5 } == true
        guard !forwardOutstanding && (distantObject || (stopOffered && p.time - since > 1.25)) else { return nil }
        let routeBearing = record(waypoint)?.bearing(at: p) ?? record(door)?.bearing(at: p) ?? 0
        return field.best(toward: routeBearing, among: confirmedAngles.filter { $0 != 0 && !drops.blocks(p, angle: Double($0)) })
    }
    private func fresh(_ n: NearField, _ p: FramePose) -> Bool {
        p.normal && n.pose.normal && p.id.sameWorld(n.pose.id) && (0...0.55).contains(p.time-n.pose.time) &&
            p.observesGround == n.pose.observesGround && (p.position-n.pose.position).length < 0.23 && p.sameView(as: n.pose, within: 10)
    }
    mutating func pose(_ p: FramePose) {
        if let previous=current, !previous.id.sameWorld(p.id) {
            // ARFrame/near callbacks from an old epoch may arrive after a reset.
            if p.id.session == previous.id.session && p.id.world < previous.id.world || p.time < previous.time { return }
            let newGeneration = generation + 1, keepTask = task
            execution.worldReset(at: p.time, pose: p)
            let audit = execution
            self = Self(doorTarget: doorTarget, requiresPlannedTarget: requiresPlannedTarget)
            generation = newGeneration; task = keepTask; execution = audit
        }
        guard current.map({ p.time >= $0.time }) ?? true else { return }
        if !p.normal && current?.normal == true { revokeStep("trackingLost", at: p.time); invalidate(clearTarget: false); nearLost(); clearAlignment() }
        if let origin=generationOrigin, origin.groundDistance(p.position)>0.38 { generation+=1; generationOrigin=p.position }
        if generationOrigin == nil {generationOrigin=p.position}
        let activeBeforeMotion = execution.active?.id
        current=p; crossing?.sample(p); execution.sample(p)
        if let activeBeforeMotion, execution.last?.id == activeBeforeMotion, execution.last?.status == .completed { bypass = nil }
        if let bypass, !bypass.world.sameWorld(p.id) || bypass.origin.groundDistance(p.position) > 0.90 { self.bypass = nil }
        let selected = [waypoint, door, plannedExit, localExitMatch].compactMap { $0 }
        book.expire(at: p.time, preserving: Set(selected.filter { $0 > 0 }))
        cloudBook.expire(at: p.time, preserving: Set(selected.filter { $0 < 0 }.map { -$0 }))
        if p.time-(summary.last?.time ?? -1e9) >= 0.5 { summary.append(p); if summary.count > 48 { summary.removeFirst() } }
        if let n = near, !fresh(n, p) { nearLost() }
        if execution.active != nil && near == nil { revokeStep("nearEvidenceStale", at: p.time) }
        if let active = execution.active, let id = active.target.landmarkID {
            let target = record(id)
            // The finite measured strip remains valid while completing this spoken, straight step.
            // Its original single-view landmark must be observed again before the next step.
            let withinIssuedStep = active.status == .moving && target != nil
            if !withinIssuedStep && (stepBearing(id, at: p) == nil || (active.spokenAt == nil && !targetObserved(id, at: p))) {
                revokeStep("landmarkNeedsObservation", at: p.time)
            }
        }
        if !execution.moving && !execution.unauthorizedMotion { lostWhileMoving = false }
        if let bodyHeading, abs(turnAngle(p.heading-bodyHeading)) >= 16 { clearAlignment() }
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
    mutating func invalidate(clearTarget: Bool = true) {
        generation += 1
        if let p = current { revokeStep(clearTarget ? "taskChanged" : "evidenceChanged", at: p.time) }
        clearAlignment()
        if clearTarget { waypoint = nil; bypass = nil }
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
        if let hazard {
            urgentHazard = execution.moving || execution.active?.spokenAt != nil || execution.unauthorizedMotion ? hazard : nil
            lastHazardAt = time
            revokeStep(hazard.rawValue, at: time)
            invalidate(clearTarget: false)
        } else { urgentHazard = nil }
    }
    private func approachingHazard(_ hazard: FrontHazard, now: NearField, prior: NearField?) -> Bool {
        let center = now.sectors.first { $0.angle == 0 }
        // A measured lip/obstacle beside the feet merits a single immediate warning even at rest.
        if let d = center?.nearest, d.isFinite, (0...0.35).contains(d) { return true }
        guard hazard == .person, let prior, (0.05...0.55).contains(now.pose.time - prior.pose.time),
              prior.pose.sameView(as: now.pose, within: 6), prior.pose.position.groundDistance(now.pose.position) < 0.07 else { return false }
        let here = now.hazards.filter { $0.kind == .person && now.pose.stripIntersects($0.box, at: 0) }
        return here.contains { item in
            let box = item.box, area = (box.right - box.left) * (box.bottom - box.top)
            return box.bottom > 0.80 && prior.hazards.contains { old in
                let b = old.box, priorArea = (b.right - b.left) * (b.bottom - b.top)
                return old.kind == .person && abs(b.center.0 - box.center.0) < 0.16 &&
                    area > priorArea * 1.35 && box.bottom > b.bottom + 0.045
            }
        }
    }
    mutating func risk(_ raw: NearField) {
        guard let p = current, p.id.sameWorld(raw.pose.id), raw.pose.time > lastNearTime,
              (0...0.55).contains(p.time - raw.pose.time) else { return }
        lastNearTime = raw.pose.time
        drops.observe(raw)
        guard fresh(raw, p) else { updateHazard(at: p.time); return }
        let hadFrontProof = hasFrontProof, priorField = near
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
        if n.canCoachFraming, n.reason != nil || n.best == nil {
            let hint: LocalCue = n.pose.pitchDown < 14 ? .tiltDown : n.pose.pitchDown > 55 ? .liftPhone : .scanSideGround
            if framing?.hint != hint { framing = (hint, n.pose.time) }
        } else { framing = nil }
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
        updateHazard(at: p.time)
        if let danger = frontHazard, approachingHazard(danger, now: n, prior: priorField) { urgentHazard = danger }
        if let a = execution.active {
            let centre = n.sectors.first { $0.angle == 0 }
            let full = centre?.state == .free && centre?.stepCoverage?.complete == true
            // Movement shifts the next full step into a different footprint. For this already-spoken
            // permit, check the remaining part of its original measured volume on the new capture.
            let remaining = a.spokenAt != nil && centre != nil && centre?.state != .occupied && n.liveStepView?.watches(a, at: n.pose) == true
            if n.reason != nil || (!full && !remaining) { revokeStep("stepEvidenceLost", at: p.time) }
        }
        if hadFrontProof && !hasFrontProof && frontHazard == nil { generation += 1; if bodyHeading == nil { aligned = Alignment() } }
    }
    mutating func recheck() {
        scan = ScanCoverage() // An explicit recheck opens another sweep at the same station.
        invalidate(clearTarget: false)
        confirmStepReview(); nearLost()
        // The same world-space lip still exists after a user-requested scan.
    }
    mutating func faceForward() {
        // Body orientation is a user-supplied fact. It can be confirmed before a pitch sweep;
        // the independent evidence and alignment checks still gate every permit.
        guard let p = current, p.normal, !execution.moving, frontHazard == nil else { return }
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
            // Cold OCR can take longer than a motion decision. Keep its capture-bound
            // inscription for recall, while moving objects and route targets still expire.
            guard (local && item.kind == .sign) || (!local && item.kind.waypoint) || live.time-p.time < 8 else { return nil }
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
        if local, plannedExit.map({ $0 < 0 }) == true, localExitMatch == nil { matchHistoricalExit() }
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
            if door != nil && scan.exhausted { scan.retry() }
        }
        return ids
    }
    mutating func select(_ id: Int) {
        guard let r=record(id), r.kind.waypoint else { return }
        if r.kind == .door && doorTarget { if let door, door != id { return }; if doorsSeen.contains(id) { door=id } }
        guard waypoint != id else { return }
        if let p = current { revokeStep("landmarkChanged", at: p.time) }
        waypoint=id; desiredHeading=nil; bypass=nil; cloudHold=nil
        selectedStrip = nil
        if r.kind == .aisle_entrance, id > 0, let field = near, let p = current, fresh(field, p),
           let bearing = r.bearing(at: field.pose), let sector = field.best(toward: bearing),
           abs(turnAngle(bearing - Double(sector))) <= 12, abs(field.pose.time - r.last.time) <= 0.55 {
            selectedStrip = (id, field.pose, field.pose.heading + Double(sector))
        }
    }
    /// Keep the same observed landmark at the threshold. Its triangulated centre and
    /// approach direction guide the finite crossing, including when that centre moves behind the phone.
    mutating func beginCrossing() {
        let localID = localExitMatch ?? door
        if let id = door, let localID, localID > 0, let r = record(localID), let p = current {
            crossing = MappedDoorCrossing(id: id, localDoor: r, from: p)
        }
        arrived = false; doorTarget = false; waypoint = nil
        plannedExit = door
    }
    mutating func clearRoomTargets() {
        door = nil
        plannedExit = nil; localExitMatch = nil; crossing = nil; completedAisles.removeAll(); selectedStrip = nil
    }
    private func stepBearing(_ id: Int, at p: FramePose) -> Double? {
        if task.task == PlannerTask.verifyCrossing.rawValue { return crossing?.id == id ? crossing?.bearing(at: p) : nil }
        return record(id)?.bearing(at: p)
    }
    private func targetObserved(_ id: Int, at p: FramePose) -> Bool {
        // In the short mapped threshold corridor the original door can drop outside the
        // image. Both the finite local geometry and fresh step coverage remain mandatory.
        if task.task == PlannerTask.verifyCrossing.rawValue {
            guard let crossing, crossing.id == id, let latest = record(id)?.last else { return false }
            return (0...20).contains(p.time - max(latest.time, crossing.observed.time)) && crossing.bearing(at: p) != nil
        }
        return record(id)?.recentlyObservedForStep(at: p.time) == true
    }
    mutating func manualDoorArrival() -> Bool {
        guard canManuallyVerifyDoor else { return false }
        if let p = current { revokeStep("manualDoorArrival", at: p.time) }
        arrived=true; return true
    }
    func record(_ id: Int?) -> Landmark? {
        guard let id else { return nil }
        if id < 0, id == plannedExit, let localExitMatch { return book.records.first { $0.id == localExitMatch } }
        return id < 0 ? cloudBook.records.first { $0.id == -id } : book.records.first { $0.id == id }
    }
    /// A rejected proposal is eligible again on the next frame that still sees this door.
    mutating func didDeliver(_ cue: LocalCue) {
        if cue.kind == .found { announcedDoor = true }
    }

    private func framingHint(at p: FramePose) -> LocalCue? {
        guard !verifyingRoute, let framing, p.time - framing.since >= 1.6 else { return nil }
        let reading = book.records.contains { sign in
            sign.kind == .sign && (0...2).contains(p.time - sign.last.time) &&
                p.position.groundDistance(sign.last.position) < 0.38 && p.sameView(as: sign.last, within: 15)
        }
        return reading ? nil : framing.hint
    }
    mutating func cue(forwardOutstanding: Bool? = nil, canAnnounceSweep: Bool = true) -> LocalCue? {
        guard let p = current else { return nil }
        let outstanding = execution.active?.spokenAt != nil
        if let hazard = frontHazard {
            let emergencyFirst = urgentHazard != nil && (!stopOffered || p.time - (blockedSince ?? p.time) < 1.25)
            if !emergencyFirst, !execution.moving, let side = bypassAngle(for: hazard, forwardOutstanding: outstanding) {
                urgentHazard = nil
                let heading = p.heading + Double(side)
                if bypass == nil || abs(turnAngle(heading - bypass!.heading)) > 12 { bypass = (p.id, heading, p.position) }
                desiredHeading = bypass?.heading; aimOrigin = p.position; selectedAt = p.time
                return .init(kind: .turn, text: "请原地" + turnText(Double(side)), isAvoidanceTurn: true)
            }
            stopOffered = true
            return urgentHazard != nil || execution.moving || outstanding ? (hazard == .drop ? .dropStop : .obstacleStop) : stationary(hazard)
        }
        if lostWhileMoving || execution.unauthorizedMotion { return .uncheckedMotion }
        if execution.needsReview { return .stepReview }
        if arrived { return .init(kind:.arrived,text:"已到教室门口，请停下。") }
        let field = near.flatMap { fresh($0, p) ? $0 : nil }
        let target=record(door), chosen=record(waypoint)
        if field?.visible == true, doorTarget, selectedDoorIsLocal, !requiresPlannedTarget || waypoint == door,
           let target, let point=target.point,
           p.time-target.last.time < 0.8, target.count >= 3, target.box.bottom > 0.58,
           target.box.bottom-target.box.top > 0.43, abs(target.bearing(at:p) ?? 180) < 18,
           p.position.groundDistance(point) < 1.15, target.first.position.groundDistance(point)-p.position.groundDistance(point) > 0.40 {
            revokeStep("landmarkReached", at: p.time); arrived=true; return .init(kind:.arrived,text:"已到教室门口，请停下。")
        }
        if let a = execution.active, a.status != .offered { return nil }
        if canAnnounceSweep, let notice = scan.takeExhaustionNotice() { return notice }
        if doorTarget, !announcedDoor, let target, selectedDoorIsLocal, p.normal,
           (0..<1.4).contains(p.time - target.last.time), p.sameView(as: target.last, within: 15),
           p.position.groundDistance(target.last.position) <= 0.23 {
            return .init(kind: .found, text: "找到门了。")
        }
        if waitingAtScannedStation || verifyingRoute { return nil }
        if task.task == PlannerTask.verifyCrossing.rawValue, crossing?.bearing(at: p) == nil { return .verifyCrossingView }
        if requiresPlannedTarget && stepTarget.landmarkID == nil { return .findStepTarget }
        if let id = stepTarget.landmarkID ?? waypoint ?? (doorTarget ? door : nil) {
            guard let b = stepBearing(id, at: p) else {
                if execution.active != nil { revokeStep("landmarkNeedsObservation", at: p.time) }
                return .init(kind: .scan, text: record(id)?.kind == .door || id == door ? "请把镜头转向门框。" : "请重新观察刚才选定的目标。")
            }
            // The phone can turn in place to frame a visual target even when the floor is not observed.
            let angle = bypass.map { turnAngle($0.heading - p.heading) } ?? b
            if abs(angle) > 8, field?.front != .occupied, field?.best == nil || field?.front == .free {
                if bodyHeading != nil && abs(angle) >= 16 { clearAlignment() }
                if aligned.latched && abs(angle) < 16 { return nil }
                _ = aligned.sample(error: angle, time: p.time)
                return .init(kind: .turn, text: "请原地" + turnText(angle), isAvoidanceTurn: bypass != nil)
            }
            if !targetObserved(id, at: p) { return .init(kind: .scan, text: "请重新观察刚才选定的目标。") }
        }
        guard var n = field, n.visible else { return framingHint(at: p) ?? (waypoint != nil ? .inspectStep : .lookAround) }
        let avoidingDrop = drops.nearby(at: p)
        if avoidingDrop {
            for i in n.sectors.indices where n.sectors[i].state == .free && !confirmedAngles.contains(n.sectors[i].angle) {
                n.sectors[i].state = .unknown
            }
        }
        guard n.reason == nil, n.best != nil else {
            if let hint = framingHint(at: p) { return hint }
            if p.time < cloudHoldUntil, let cloudHold, cloudHold.kind == .scan { return cloudHold }
            return .lookAround
        }
        let bearing = stepTarget.landmarkID.flatMap { stepBearing($0, at: p) } ?? chosen?.bearing(at:p) ?? target?.bearing(at:p) ?? priorWaypoint.map { turnAngle(($0-p.position).heading-p.heading) }
        let goal = (bypass.map { turnAngle($0.heading - p.heading) } ?? bearing).flatMap { drops.blocks(p, angle: $0) ? nil : $0 }
        if let remembered = desiredHeading, drops.blocks(p, angle: turnAngle(remembered - p.heading)) { desiredHeading = nil }
        if let start=aimOrigin, start.groundDistance(p.position) > 0.8 || p.time-selectedAt > 10 {
            desiredHeading=nil; aimOrigin=nil
            // Retain the chosen identity across detours until the planner replaces it.
        }
        // Route bearings choose what to inspect. A reachable side strip takes precedence
        // over a stale straight-ahead aim, even before the planner identifies a landmark.
        let preference = goal ?? desiredHeading.map { turnAngle($0 - p.heading) } ?? 0
        let best = n.best(toward: preference)
        let needsSide = n.front != .free || avoidingDrop
        var angle: Double?
        if needsSide, let best { angle = Double(best) }
        else if let goal, abs(goal) > 43 { angle = goal } // turn in place to reacquire a landmark
        else if let goal, let best, abs(Double(best) - goal) <= 15 { angle = goal }
        else if let best { angle = Double(best) }
        if let angle, goal == nil || needsSide, desiredHeading == nil || needsSide {
            desiredHeading = p.heading + angle
            aimOrigin = p.position
            selectedAt = p.time
        }
        if !needsSide && target != nil && target?.bearing(at:p) == nil && chosen == nil && n.best == 0 {
            return .init(kind:.scan,text:"请把镜头转向门框。")
        }
        guard let angle else { return .lookAround }
        if abs(angle) > 8 {
            if bodyHeading != nil && abs(angle) >= 16 { clearAlignment() }
            if aligned.latched && abs(angle) < 16 { return nil }
            _ = aligned.sample(error: angle, time: p.time)
            if execution.active != nil { revokeStep("turnRequired", at: p.time) }
            return .init(kind: .turn, text: (needsSide ? "请原地" : "") + turnText(angle), isAvoidanceTurn: needsSide)
        }
        let justAligned = aligned.sample(error: angle, time: p.time)
        guard hasFrontProof else { return .lookAround }
        if justAligned { return .init(kind: .aligned, text: "方向已对准。") }
        guard aligned.latched else { return .init(kind: .wait, text: "保持手机朝向前方。") }
        guard let proof = latestStepCheck else {
            if let coverage = n.sectors.first(where: { $0.angle == 0 })?.stepCoverage {
                // Correctly framed credit after a completed step is still observation only.
                // Give the new frames a chance to accumulate before asking for a camera adjustment.
                if coverage.complete, let finished = execution.last, finished.status == .completed,
                   let end = finished.endedAt, (0...0.55).contains(p.time - end) { return nil }
                if coverage.nearGround && coverage.landing && !coverage.body { return .inspectBody }
            }
            return .inspectStep
        }
        guard bodyHeading != nil else { return .init(kind: .face, text: "请让手机朝向身体前方，再点“手机已朝向身体前方”。") }
        guard canAdvance, let id = execution.offer(stepTarget, proof: proof) else { return nil }
        return .init(kind: .advance, text: "向前迈一步。", permitID: id)
    }
    private func turnText(_ angle: Double) -> String {
        let degrees = min(60,max(15,Int((abs(angle)/15).rounded())*15))
        return "向\(angle<0 ? "左" : "右")转约\(degrees)度。"
    }
}

extension SpatialNavigator {
    /// A cloud-only door may describe a local landmark which did not yet exist when the
    /// keyframe was taken. Match the local triangulation back into that original box.
    /// A door which is merely nearer/reachable from the new camera position is ineligible.
    private mutating func matchHistoricalExit() {
        guard let id = plannedExit, id < 0, let source = cloudBook.records.first(where: { $0.id == -id }),
              let p = current else { return }
        let candidates = book.records.filter { door in
            guard door.kind == .door, doorsSeen.contains(door.id), door.count >= 3, let point = door.point,
                  door.last.id.sameWorld(source.last.id), (0...1.2).contains(p.time - door.last.time),
                  let (x, y) = source.last.project(point) else { return false }
            let b = source.box
            return (b.left...b.right).contains(x) && (b.top...b.bottom).contains(y)
        }
        guard candidates.count == 1, let local = candidates.first,
              let box = local.projectedBox(at: source.last), box.overlap(with: source.box) >= 0.40 else { return }
        localExitMatch = local.id
    }

    func acceptsRoomTarget(_ id: Int) -> Bool {
        guard let proposed = record(id) else { return false }
        if proposed.kind == .aisle_entrance { return !completedAisle(id, proposed) && crossing == nil }
        if proposed.kind == .door, let plannedExit { return id == plannedExit || id == localExitMatch }
        return true
    }
    /// The first explicit image-bound exit can supersede the tentative local survey choice.
    /// Later proposals must refer to that same identity, even during an aisle detour.
    @discardableResult mutating func selectRoomTarget(_ id: Int) -> Bool {
        guard acceptsRoomTarget(id), let r = record(id) else { return false }
        if r.kind == .door {
            if plannedExit == nil {
                if door != id { arrived = false; announcedDoor = false }
                plannedExit = id; door = id
                if id < 0 { matchHistoricalExit() }
            }
            select(plannedExit ?? id)
        } else { select(id) }
        return true
    }
    private func completedAisle(_ id: Int, _ record: Landmark) -> Bool {
        completedAisles.contains { completed in
            if completed.id == id { return true }
            guard let a = record.point, let b = completed.mappedEntrance else { return false }
            return a.groundDistance(b) <= 0.45
        }
    }
    private func reachedAisle(_ id: Int, _ record: Landmark, at p: FramePose) -> Bool {
        if let point = record.point, record.count >= 3, (0...0.8).contains(p.time - record.last.time),
           p.position.groundDistance(point) <= 1.05,
           record.first.position.groundDistance(point) - p.position.groundDistance(point) > 0.40 { return true }
        // The local camera represents a surveyed sector by a box, not a fixed world point.
        // Reaching it means a completed permit for this identity entered its original
        // observed strip AND the new station has fresh passage evidence in that direction.
        guard let strip = selectedStrip, strip.id == id, strip.origin.id.sameWorld(p.id), hasFrontProof,
              let permit = execution.last, permit.status == .completed, permit.target.landmarkID == id,
              permit.target.task == PlannerTask.approachAisle.rawValue, permit.check.origin.time >= strip.origin.time,
              abs(turnAngle(p.heading - strip.heading)) < 16 else { return false }
        let a = strip.heading * .pi / 180, delta = p.position - strip.origin.position
        let along = delta.dot(V3(sin(a), 0, -cos(a))), across = delta.dot(V3(cos(a), 0, sin(a)))
        return (StepFootprint().groundStart...1.35).contains(along) && abs(across) <= StepFootprint().halfWidth
    }
    /// Shared by the formal live adapter and the deterministic classroom-to-hall replay.
    /// Return the landmark to select after the caller commits a changed semantic task.
    mutating func roomWaypoint(for journey: inout WayfindingJourney, capture: FramePose, features: [Sighting]) -> Int? {
        guard journey.requiresExit, let p = current, p.normal, capture.normal, p.id.sameWorld(capture.id),
              (0...1.5).contains(p.time - capture.time) else { return nil }
        if journey.plannerTask == .verifyCrossing { return crossing?.id }
        if journey.plannerTask == .approachAisle, let id = waypoint, let aisle = record(id), aisle.kind == .aisle_entrance {
            guard reachedAisle(id, aisle, at: p) else { return id }
            completedAisles.append(.init(id: id, station: p.position, mappedEntrance: aisle.point))
            journey.reachedWaypoint(.aisle_entrance)
            return plannedExit ?? door
        }
        if let id = waypoint, let r = record(id), r.kind == .sign { return id }
        let exit = plannedExit ?? door
        let angle = exit.flatMap { record($0)?.bearing(at: p) }
        // Return to the selected exit after reaching a side aisle; an unchanged chair in
        // the next keyframe is not a new task. The executor can still steer around it.
        if let latest = completedAisles.last, latest.station.groundDistance(p.position) < 0.85 { return exit }
        let chairOnRoute = angle.map { wanted in features.contains {
            [.chair, .stool].contains($0.kind) && abs(turnAngle(capture.ray($0.box.center.0, $0.box.center.1).heading - p.heading - wanted)) <= 20
        } } ?? false
        let field = near.flatMap { fresh($0, p) ? $0 : nil }
        let hidden = chairOnRoute || field?.front == .occupied
        let considerOpening = exit == nil || hidden
        if considerOpening, let field, let side = field.best(toward: angle ?? 0), !hidden || side != 0 {
            let candidates = book.records.filter { $0.kind == .aisle_entrance && $0.last.id == capture.id && !completedAisle($0.id, $0) }
                .compactMap { r in r.bearing(at: p).map { (id: r.id, error: abs(turnAngle($0 - Double(side)))) } }
            if let opening = candidates.min(by: { $0.error < $1.error }), opening.error < 14 {
                let next = PlannerDirective(scene: .room, scene_uncertain: false, task: .approachAisle,
                                            reason: "观察侧过道入口，再从新位置复核已选出口。", completion: .aisleReached)
                if journey.applyPlan(next, targetKind: .aisle_entrance) { return opening.id }
            }
        }
        if let exit, journey.plannerTask == .findExit {
            _ = journey.applyPlan(.init(scene: .room, scene_uncertain: false, task: .approachExit,
                                        reason: "已找到一扇可复核的出口。", completion: .doorReached), targetKind: .door)
            return exit
        }
        return exit
    }
}

extension SpatialNavigator {
    /// A pictured door may be an intermediate exit. To approach it as a named destination,
    /// require an entrance inscription or symbol in its own image, bound to this same door.
    func supportsDestination(_ target: Destination, id: Int, box: ImageBox, signsInImage: [(Sighting, Int)], otherDoorBoxes: [ImageBox] = []) -> Bool {
        guard let selected = record(id) else { return false }
        func entrance(_ record: Landmark) -> Bool {
            guard record.kind == .sign, !record.signConflict, record.sign?.arrow == nil else { return false }
            if record.sign?.representsEntrance(for: target) == true { return true }
            guard let text = record.label ?? record.sign?.text else { return false }
            let words = [SignLine(text)]
            return WayfindingParser.read(.init(lines: words, reading: SignParser.analyze(words, for: target)), for: target).target == .plate
        }
        if selected.kind == .sign { return entrance(selected) }
        guard selected.kind == .door else { return false }
        return signsInImage.contains { sign, signID in
            let center = sign.box.center
            func encloses(_ door: ImageBox) -> Bool {
                (door.left...door.right).contains(center.0) && (door.top...door.bottom).contains(center.1)
            }
            return encloses(box) && !otherDoorBoxes.contains(where: encloses) && record(signID).map(entrance) == true
        }
    }
}
