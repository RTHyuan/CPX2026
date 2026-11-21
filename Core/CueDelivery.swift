import Foundation

/// Audio and UI share one decision. Routine changes of wording within an observation
/// episode must not interrupt a sign or re-arm an emergency haptic.
struct CueDelivery {
    private(set) var last: LocalCue?
    private(set) var forwardOutstanding = false
    private var lastAt = -Double.infinity
    private var ambientAt = -Double.infinity
    private var holdUntil = -Double.infinity
    private var spokenDangers = Set<String>()
    private var clearSince: Double?

    mutating func sampled(at t: Double, dangerPresent: Bool, frontProven: Bool) {
        if dangerPresent { clearSince = nil; return }
        if clearSince == nil { clearSince = t }
        if frontProven || t - (clearSince ?? t) >= 1 { spokenDangers.removeAll() }
    }

    mutating func take(_ cue: LocalCue, at t: Double, cause: String = "obstacle", revoke: Bool = false) -> Bool {
        if cue.kind == .stop {
            // A person and an unclassified object use the same immediate stop. Fluctuating
            // labels must not restart those words while the person is already stopped.
            let episode = cause == "person" ? "obstacle" : cause
            guard !spokenDangers.contains(episode) || forwardOutstanding || last?.kind != .stop else { return false }
            spokenDangers.insert(episode)
            clearSince = nil
            forwardOutstanding = false
            holdUntil = t + 1.1
        } else if revoke {
            forwardOutstanding = false
            holdUntil = t + 1.2
        } else {
            guard cue != last || cue == .noConfirmedAisle else { return false }
            switch cue.kind {
            case .arrived: forwardOutstanding = false
            case .aligned: break // The one-shot alignment pulse is silent and can coincide with reading.
            case .route, .found:
                if last?.kind == .stop && t < holdUntil { return false }
                holdUntil = t + 3.2
            case .wait, .scan:
                // The navigator offers the end of a completed sweep exactly once per station.
                if cue != .noConfirmedAisle {
                    guard t >= holdUntil, t - ambientAt >= 8 else { return false }
                }
                ambientAt = t
            case .turn:
                guard t >= holdUntil, last?.kind != .turn || t-lastAt >= 0.75 else { return false }
            default:
                guard t >= holdUntil else { return false }
            }
            if cue.kind == .advance { forwardOutstanding = true }
        }
        last = cue; lastAt = t
        return true
    }
}

/// A confirmed access notice applies to its sign's current bearing. A boxless OCR line
/// can only veto the recent camera view. Neither observation certifies another entrance.
struct AccessNotices {
    private var votes: [Int: Double] = [:]
    private var confirmed: [Int: Double] = [:]
    private var previous: FramePose?
    private var previousHadText = false
    private var boxless: FramePose?
    private static let voteWindow = 0.1...3.5

    mutating func observe(_ capture: FramePose, signs: [(Sighting, Int)], printedRestriction: Bool) {
        guard capture.normal else { return }
        if let previous, !capture.id.sameWorld(previous.id) { self = Self() }
        guard previous.map({ capture.time > $0.time && capture.id.frame > $0.id.frame }) ?? true else { return }
        let matches = signs.compactMap { sign, id in
            sign.label.map(WayfindingParser.isRestriction) == true ? id : nil
        }
        confirmed = confirmed.filter { capture.time - $0.value < Landmark.signLifetime }
        // Initializing Vision can delay the next capture. Repeated text from the same
        // station and camera view can still confirm a posted restriction after that delay.
        let stableView = previous.map {
            $0.sameView(as:capture, within:12) && $0.position.groundDistance(capture.position) <= 0.38
        } ?? false
        let interval = stableView ? 0.1...12.0 : Self.voteWindow
        for id in matches where votes[id].map({ interval.contains(capture.time - $0) }) == true {
            confirmed[id] = capture.time
        }
        votes = Dictionary(matches.map { ($0, capture.time) }, uniquingKeysWith: max)
        if printedRestriction, previousHadText, let previous, stableView,
           interval.contains(capture.time - previous.time) {
            boxless = capture
        }
        previous = capture
        previousHadText = printedRestriction
    }

    func blocks(_ pose: FramePose, in book: LandmarkBook) -> Bool {
        guard pose.normal else { return false }
        if let source = boxless, source.id.sameWorld(pose.id), (0...4).contains(pose.time - source.time),
           source.position.groundDistance(pose.position) <= 0.38, abs(turnAngle(source.heading - pose.heading)) <= 30 { return true }
        guard !confirmed.isEmpty else { return false }
        return book.records.contains { sign in
            guard let t = confirmed[sign.id], (0..<Landmark.signLifetime).contains(pose.time - t),
                  let bearing = sign.bearing(at: pose) else { return false }
            return abs(bearing) <= 35
        }
    }
}
