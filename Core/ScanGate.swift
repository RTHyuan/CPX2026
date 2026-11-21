import Foundation

/// A generation belongs to its target and capture session. A restarted session gets a fresh gate.
struct ScanGate {
    private var recent: [(TimeInterval, SignReading)] = []
    private var lastFrame: UInt64?
    private var lastDelivered: SignReading?
    private var hasSignaledSuccess = false
    private var startedAt: TimeInterval
    private var lastUseful: TimeInterval
    private var saidUnclear = false

    init(now: TimeInterval) { startedAt = now; lastUseful = now }

    /// Keep the haptic history of this search across pauses, mode switches and camera interruptions.
    mutating func restartObservations(now: TimeInterval) {
        recent.removeAll(keepingCapacity: true)
        lastFrame = nil
        lastDelivered = nil
        startedAt = now
        lastUseful = now
        saidUnclear = false
    }

    mutating func ingest(_ reading: SignReading, frame: UInt64, now: TimeInterval) -> SignReading? {
        guard lastFrame.map({ frame > $0 }) ?? true, now >= startedAt else { return nil }
        lastFrame = frame
        recent.removeAll { now - $0.0 > 2.5 }
        recent.append((now, reading))
        if recent.count > 3 { recent.removeFirst() }
        guard reading.kind != .unclear, recent.filter({ $0.1 == reading }).count >= 2 else {
            return idle(now: now)
        }
        lastUseful = now; saidUnclear = false
        guard lastDelivered != reading else { return nil }
        lastDelivered = reading
        recent.removeAll(keepingCapacity: true)
        return reading
    }
    /// Visual and spoken results follow the current sign. The success haptic fires once per search session.
    mutating func shouldSignalSuccess(for reading: SignReading) -> Bool {
        guard reading.isMatch, !hasSignaledSuccess else { return false }
        hasSignaledSuccess = true
        return true
    }

    mutating func idle(now: TimeInterval) -> SignReading? {
        guard now - lastUseful >= 6, !saidUnclear else { return nil }
        saidUnclear = true; lastDelivered = .unclear
        recent.removeAll { now - $0.0 > 2.5 }
        return .unclear
    }
}
