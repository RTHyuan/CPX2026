import Foundation

/// A sector can be useful for choosing where to look even when part of this footprint is unseen.
struct StepCoverage: Equatable, Codable {
    enum Source: String, Codable { case lidar, multiView, controlledReplay }
    let source: Source
    var nearGround: Bool, landing: Bool, body: Bool
    var bodyFrame: FrameID? = nil, bodyTime: Double? = nil
    var bodyFrames: [FrameID]? = nil
    /// Bit (distance*3 + lateral)*5 + height records the sample used in the checked volume.
    var checkedBodySites: UInt32? = nil
    var complete: Bool { nearGround && landing && body }
    func isCurrent(at pose: FramePose, after boundary: Double) -> Bool {
        guard complete else { return false }
        if source == .controlledReplay { return true }
        guard let bodyTime, bodyTime > boundary, (0...0.65).contains(pose.time - bodyTime),
              let bodyFrame, let bodyFrames, bodyFrames.contains(bodyFrame) else { return false }
        return bodyFrames.allSatisfy { $0.sameWorld(pose.id) && $0.frame <= pose.id.frame }
    }
    /// For injected capture-boundary evidence in tests and simulator tapes only.
    static let controlled = Self(source: .controlledReplay, nearGround: true, landing: true, body: true)
}

struct StepFootprint: Encodable, Equatable {
    // Metres forward from the camera's ground projection; this is a checked envelope, not a stride estimate.
    let groundStart = 0.24, landingStart = 0.56, end = 1.04, halfWidth = 0.30
    let bodyHeights = [0.30, 0.65, 1.05, 1.50, 1.85]
    enum CodingKeys: String, CodingKey { case groundStart, landingStart, end, halfWidth, bodyHeights }
    init() {}
}

struct StepTarget: Equatable, Codable {
    var destination: String, task: String, revision: Int
    var landmarkID: Int? = nil
    /// The observed opening supplies the target when no named landmark is locked.
    var localOpeningHeading: Double?
}
struct StepCheck: Encodable {
    let origin: FramePose, frames: [FrameID], times: [Double], coverage: [StepCoverage]
    let footprint = StepFootprint()
    var checkedAt: Double { times.last ?? origin.time }
}
enum StepPhase: String, Codable { case observing, preparing, executing, reviewing }
struct StepPermit: Encodable {
    enum Status: String, Codable { case offered, submitted, spoken, moving, completed, expired, revoked }
    let id: UUID, check: StepCheck, target: StepTarget
    var status: Status = .offered
    var spokenCheck: StepCheck?
    var submittedAt: Double?, spokenAt: Double?, startedMovingAt: Double?, endedAt: Double?, reason: String?
}
struct StepEvent: Encodable {
    let type: String, time: Double, permit: StepPermit?, frame: FrameID?, position: V3?, heading: Double?
    let forwardMetres: Double?, lateralMetres: Double?, moving: Bool, settled: Bool, reason: String?
}

/// The phone is not a foot sensor. Require persistent, directed translation and a stable endpoint.
/// A long, discontinuous or ambiguous movement is held for human review instead of counted as a step.
private struct StepMotion {
    private var samples: [FramePose] = []
    private(set) var moving = false, settled = false
    static func offsets(_ p: FramePose, from origin: FramePose) -> (forward: Double, lateral: Double) {
        let a = origin.heading * .pi / 180, d = p.position - origin.position
        return (d.x * sin(a) - d.z * cos(a), d.x * cos(a) + d.z * sin(a))
    }
    mutating func sample(_ p: FramePose) {
        guard p.normal else { self = Self(); return }
        if let last = samples.last {
            if !p.id.sameWorld(last.id) || p.time - last.time > 0.55 { self = Self() }
            else if p.time <= last.time || p.id.frame <= last.id.frame { return }
        }
        samples.append(p); samples.removeAll { p.time - $0.time > 0.58 }
        let window = samples.filter { p.time - $0.time <= 0.39 }
        guard window.count >= 3, let first = window.first, p.time - first.time >= 0.19 else { moving = false; settled = false; return }
        let legs = zip(window, window.dropFirst()).map { $0.position.groundDistance($1.position) }
        let span = first.position.groundDistance(p.position), path = legs.reduce(0, +)
        let earlier = window.filter { $0.time <= (first.time + p.time) / 2 }
        // A single camera pose jump (or one hand jerk) does not show sustained locomotion.
        let middle = earlier.last ?? first
        let firstProgress = first.position.groundDistance(middle.position), lastProgress = middle.position.groundDistance(p.position)
        let headingRange = window.allSatisfy { abs(turnAngle($0.heading - first.heading)) < 20 }
        moving = headingRange && span >= 0.115 && span >= 0.75 * path && min(firstProgress, lastProgress) >= 0.027
        settled = window.count >= 3 && p.time - first.time >= 0.27 && window.allSatisfy { $0.position.groundDistance(p.position) <= 0.035 }
    }
}

struct StepExecution {
    private(set) var active: StepPermit?, last: StepPermit?
    private(set) var phase = StepPhase.observing
    private(set) var barrier = -Double.infinity
    private var motion = StepMotion(), events: [StepEvent] = []
    private(set) var unauthorizedMotion = false
    private var reviewRequired = false
    private var peakForward = 0.0
    var moving: Bool { motion.moving }
    var settled: Bool { motion.settled }
    var needsReview: Bool { reviewRequired }
    mutating func drain() -> [StepEvent] { let result = events; events.removeAll(keepingCapacity: true); return result }
    private mutating func log(_ type: String, _ t: Double, _ p: FramePose?, _ permit: StepPermit?, _ reason: String? = nil) {
        let d = p.flatMap { live in permit.map { StepMotion.offsets(live, from: $0.check.origin) } }
        events.append(.init(type: type, time: t, permit: permit, frame: p?.id, position: p?.position, heading: p?.heading,
                            forwardMetres: d?.forward, lateralMetres: d?.lateral, moving: moving, settled: motion.settled, reason: reason))
    }
    mutating func offer(_ target: StepTarget, proof: StepCheck) -> UUID? {
        guard !reviewRequired, !unauthorizedMotion, !moving else { return nil }
        if let active { return active.status == .offered ? active.id : nil }
        guard proof.frames.count == 3, proof.times.allSatisfy({ $0 > barrier }), proof.coverage.allSatisfy({ $0.isCurrent(at: proof.origin, after: barrier) }) else { return nil }
        let permit = StepPermit(id: UUID(), check: proof, target: target)
        active = permit; phase = .preparing; peakForward = 0
        log("offered", proof.origin.time, proof.origin, permit)
        return permit.id
    }
    /// The original frames themselves have a deadline. Later frames may veto them, never extend a queued utterance.
    func permits(_ id: UUID, at t: Double, pose p: FramePose?, target: StepTarget, proof: Bool) -> Bool {
        guard let p, let a = active, a.id == id, [.offered, .submitted].contains(a.status), !moving,
              proof, p.normal, target == a.target, p.id.sameWorld(a.check.origin.id),
              (0...0.55).contains(t - a.check.checkedAt), (0...0.55).contains(t - p.time),
              p.sameView(as: a.check.origin, within: 10), p.position.groundDistance(a.check.origin.position) < 0.10 else { return false }
        return true
    }
    mutating func submit(_ id: UUID, at t: Double, pose: FramePose?) {
        guard var a = active, a.id == id, a.status == .offered else { return }
        a.status = .submitted; a.submittedAt = t; active = a; log("submitted", t, pose, a)
    }
    mutating func started(_ id: UUID, at t: Double, pose: FramePose?, proof: StepCheck) -> Bool {
        guard var a = active, a.id == id, a.status == .submitted else { return false }
        a.status = .spoken; a.spokenAt = t; a.spokenCheck = proof; active = a; phase = .preparing
        log("speechStarted", t, pose, a); return true
    }
    mutating func speechEnded(_ id: UUID, at t: Double, pose: FramePose?) {
        if let a = [active, last].compactMap({$0}).first(where: { $0.id == id }) { log("speechEnded", t, pose, a) }
    }
    mutating func cancelSpeech(_ id: UUID, at t: Double, pose: FramePose?) {
        guard let a = [active, last].compactMap({$0}).first(where: { $0.id == id }) else { return }
        log("speechCancelled", t, pose, a)
        if active?.id == id { close(.revoked, "speechCancelled", at: t, pose: pose) }
    }
    mutating func close(_ state: StepPermit.Status, _ reason: String, at t: Double, pose: FramePose?, requireReview: Bool = false) {
        barrier = max(barrier, t)
        if var a = active {
            a.status = state; a.reason = reason; a.endedAt = t; active = nil; last = a
            log(state.rawValue, t, pose, a, reason)
        }
        reviewRequired = reviewRequired || requireReview
        phase = reviewRequired || state == .completed ? .reviewing : .observing
    }
    mutating func confirmReview(_ p: FramePose?) {
        guard let p, p.normal, !moving, !unauthorizedMotion else { return }
        if reviewRequired { log("reviewConfirmed", p.time, p, last) }
        reviewRequired = false; phase = .observing; barrier = max(barrier, p.time)
    }
    mutating func worldReset(at t: Double, pose p: FramePose?) {
        close(.revoked, "worldReset", at: t, pose: p)
        motion = StepMotion(); unauthorizedMotion = false; reviewRequired = false; phase = .observing
        // Frame timestamps are scoped to the new world; its first observation cannot use the old triplet.
        barrier = t
    }
    mutating func sample(_ p: FramePose) {
        motion.sample(p)
        if var a = active {
            let origin = a.check.origin, d = StepMotion.offsets(p, from: origin)
            let t = p.time
            let state: (StepPermit.Status, String, Bool)?
            if !p.normal || !p.id.sameWorld(origin.id) { state = (.revoked, "tracking", false) }
            else if abs(turnAngle(p.heading - origin.heading)) > 16 { state = (.revoked, "headingChanged", false) }
            else if abs(d.lateral) > 0.14 || d.forward < -0.11 { state = (.revoked, "leftCheckedStrip", moving) }
            else if a.spokenAt == nil {
                if t - a.check.checkedAt > 0.55 { state = (.expired, "queuedProofExpired", false) }
                else if origin.position.groundDistance(p.position) >= 0.10 { state = (.revoked, "movedBeforeSpeech", moving) }
                else { state = nil }
            } else if d.forward > a.check.footprint.end - 0.10 { state = (.revoked, "reachedCheckedLimit", true) }
            else if let started = a.startedMovingAt, t - started > 3.2 { state = (.expired, "motionUnresolved", true) }
            else if a.startedMovingAt == nil, let spoken = a.spokenAt, t - spoken > 3.5 { state = (.expired, "startUnconfirmed", true) }
            else { state = nil }
            if let (end, reason, review) = state { close(end, reason, at: t, pose: p, requireReview: review) }
            else if a.spokenAt != nil {
                peakForward = max(peakForward, d.forward)
                if a.startedMovingAt == nil, moving, d.forward >= 0.115, abs(d.lateral) < max(0.065, d.forward * 0.45) {
                    a.startedMovingAt = t; a.status = .moving; active = a; phase = .executing
                    log("motionStarted", t, p, a)
                } else if let started = a.startedMovingAt, t - started >= 0.25, motion.settled {
                    if d.forward >= 0.17 && peakForward - d.forward < 0.085 { close(.completed, "forwardMotionThenSettled", at: t, pose: p) }
                    else { close(.revoked, "ambiguousMotion", at: t, pose: p, requireReview: true) }
                }
            }
        }
        if active?.spokenAt == nil && moving && !unauthorizedMotion {
            unauthorizedMotion = true; phase = .reviewing; log("movingWithoutPermit", p.time, p, last, "sustainedTranslation")
        } else if unauthorizedMotion && motion.settled {
            unauthorizedMotion = false; barrier = max(barrier, p.time); log("stationaryAgain", p.time, p, last)
        }
    }
}
