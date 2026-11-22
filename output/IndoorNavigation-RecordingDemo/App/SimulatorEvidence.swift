#if DEBUG && targetEnvironment(simulator)
import Foundation
import notify

/// Controlled capture hardware inputs. Only the runner knows a recording's name or annotations.
struct SimulatorEvidence: Decodable {
    let heading: Double
    let position: V3
    let tracking: String
    let world: Int
    let sectors: [Int]
    let occupied: Bool
    let features: [Sighting]
    let pitchDown: Double?
    let headingOffsets: [Double]?
    /// Samples from the phase's first tick. Hold the last offset to model settling after motion.
    let positionOffsets: [V3]?
    let reason: String?
    let picture: Int?
    let readSigns: Bool?
    let measuredDrop: V3?
    let injectedFrontDistance: Double?
    /// Free sector labels alone must never imply the foot, landing and swept body checks passed.
    let checkedStepSectors: [Int]?
    /// With capture playback the last source frame stays frozen when the clip ends.
    struct Capture: Decodable { let picture: Int, sourceFrame: Int, pts: Double }
    let captures: [Capture]?
    let freezeCapture: Bool?

    func events(session: UUID, frame: Int, tick: Int, time: Double, width: Int, height: Int) -> (FramePose, NearField) {
        let offsets = headingOffsets ?? []
        let yaw = (heading + (offsets.isEmpty ? 0 : offsets[tick % offsets.count])) * .pi / 180
        let p = positionOffsets.flatMap { $0.isEmpty ? nil : $0[min(tick, $0.count - 1)] }.map { position + $0 } ?? position
        let pitch = (pitchDown ?? 0) * .pi / 180
        let c = cos(yaw), s = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let w = Double(width), h = Double(height), focal = 0.55 * w
        let pose = FramePose(id: .init(session: session, world: world, frame: frame), time: time,
                             transform: [c,0,s,0, s*sp,cp,-c*sp,0, -s*cp,sp,c*cp,0, p.x,p.y,p.z,1],
                             intrinsics: [focal,0,0,0,focal,0,w/2,h/2,1], width: width, height: height, exif: 1, tracking: tracking)
        let bins = stride(from: -60, through: 60, by: 15).map { angle -> Sector in
            if angle == 0, let measuredDrop {
                return Sector(angle: angle, state: .occupied, nearest: p.groundDistance(measuredDrop),
                              stepEvidence: .measuredDrop(measuredDrop))
            }
            var sector = Sector(angle: angle, state: occupied && angle == 0 ? .occupied : (sectors.contains(angle) ? .free : .unknown))
            if angle == 0, occupied { sector.nearest = injectedFrontDistance }
            if sector.state == .free, checkedStepSectors?.contains(angle) == true { sector.stepCoverage = .controlled }
            return sector
        }
        return (pose, NearField(pose: pose, visible: tracking == "normal", sectors: bins,
                                hazards: features.filter { $0.kind.mobile || $0.kind == .steps }, reason: reason,
                                canCoachFraming: tracking == "normal"))
    }
}

/// In legacy phases geometry is generated at the live tick rate. A frozen capture or a recorded
/// sequence instead emits each source frame exactly once, using its original inter-frame timing.
final class SimulatorEvidenceTape {
    struct Sample {
        let observation: SimulatorEvidence
        let picture: Int?, frame: Int, tick: Int, time: Double, isFresh: Bool
    }
    private let observations: [SimulatorEvidence]
    private var phaseToken: Int32 = NOTIFY_TOKEN_INVALID
    private var previousPhase: Int?, startSequence = 0, startedAt = 0.0, lastSource: Int?

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let json = env["PATHSENSE_TEST_EVIDENCE"] else { return nil }
        do { observations = try JSONDecoder().decode([SimulatorEvidence].self, from: Data(json.utf8)) }
        catch { preconditionFailure("Invalid simulator evidence: \(error)") }
        precondition(!observations.isEmpty, "Empty simulator evidence tape")
        for item in observations {
            if let clips = item.captures {
                precondition(!clips.isEmpty && clips.allSatisfy { $0.pts.isFinite && $0.sourceFrame >= 0 && $0.picture >= 0 })
                precondition(zip(clips, clips.dropFirst()).allSatisfy { $0.pts < $1.pts && $0.sourceFrame < $1.sourceFrame })
            }
        }
        if let name = env["PATHSENSE_TEST_PHASE"] {
            precondition(notify_register_check(name, &phaseToken) == NOTIFY_STATUS_OK, "Cannot read the XCTest phase")
        }
    }
    deinit { if phaseToken != NOTIFY_TOKEN_INVALID { notify_cancel(phaseToken) } }

    /// The XCTest controller can start its injected gait immediately after the accepted player
    /// cursor callback. Waiting for a screen snapshot can outlast the permission to begin moving.
    static func signalAcceptedStepPlayback() {
        guard let phase = ProcessInfo.processInfo.environment["PATHSENSE_TEST_PHASE"] else { return }
        notify_post(phase + ".accepted-step")
    }

    func sample(at sequence: Int, time: Double) -> Sample {
        var phase = min(sequence, observations.count - 1)
        if phaseToken != NOTIFY_TOKEN_INVALID {
            var selected: UInt64 = 0
            precondition(notify_get_state(phaseToken, &selected) == NOTIFY_STATUS_OK && selected < observations.count, "Invalid XCTest phase")
            phase = Int(selected)
        }
        if sequence == 0 || previousPhase != phase {
            previousPhase = phase; startSequence = sequence; startedAt = time; lastSource = nil
        }
        let tick = sequence - startSequence, item = observations[phase]
        if let captures = item.captures, let first = captures.first {
            let sourceTime = first.pts + time - startedAt
            let index = captures.lastIndex(where: { $0.pts <= sourceTime + 0.000001 }) ?? 0
            let capture = captures[index]
            let fresh = lastSource != capture.sourceFrame
            lastSource = capture.sourceFrame
            return .init(observation: item, picture: capture.picture, frame: capture.sourceFrame, tick: index,
                         time: startedAt + (capture.pts - first.pts), isFresh: fresh)
        }
        let frozen = item.freezeCapture == true
        return .init(observation: item, picture: item.picture, frame: frozen ? startSequence : sequence, tick: tick,
                     time: frozen ? startedAt : time, isFresh: !frozen || tick == 0)
    }
}

/// Optional simctl entry point. Exercise the same Scanner, camera tape and AVAudioPlayer
/// as the UI test. Only the body-facing button and replay input phases are automated.
@MainActor enum SimulatorStepReplay {
    private static var started = false
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func runIfRequested(_ scanner: Scanner) async {
        let env = ProcessInfo.processInfo.environment
        guard !started, let run = env["PATHSENSE_HEADLESS_STEP_REPLAY"], UUID(uuidString: run) != nil,
              let phaseName = env["PATHSENSE_TEST_PHASE"], env["PATHSENSE_TEST_FEEDBACK"] == "1" else { return }
        started = true
        let fm = FileManager.default
        let directory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PathSenseReplay", isDirectory: true).appendingPathComponent(run, isDirectory: true)
        var token = NOTIFY_TOKEN_INVALID
        let previousSound = scanner.sound
        var progress: [[String: Any]] = []
        func mark(_ stage: String) throws {
            progress.append(["stage":stage, "uptime":ProcessInfo.processInfo.systemUptime, "message":scanner.message])
            try JSONSerialization.data(withJSONObject:progress).write(to:directory.appendingPathComponent("progress.json"),options:.atomic)
        }
        func phase(_ index: UInt64) throws {
            guard notify_set_state(token, index) == NOTIFY_STATUS_OK else { throw Failure("Could not select input phase \(index)") }
        }
        func wait(_ description: String, timeout: TimeInterval, until predicate: () -> Bool) async throws {
            let limit = ProcessInfo.processInfo.systemUptime + timeout
            while !predicate() {
                guard ProcessInfo.processInfo.systemUptime < limit else { throw Failure(description) }
                try await Task.sleep(for:.milliseconds(35))
            }
        }
        let played = "开读/zh-CN/向前迈一步。"
        func starts() -> Int { scanner.feedback.trace.filter { $0 == played }.count }
        var fault: String?
        do {
            try fm.createDirectory(at:directory, withIntermediateDirectories:true)
            guard notify_register_check(phaseName, &token) == NOTIFY_STATUS_OK else { throw Failure("Cannot open replay phase") }
            try phase(0)
            try mark("launched")
            // The independent replay explicitly suppresses the optional opening narration.
            // The one-step audio file and its cursor callbacks are always real for this run.
            scanner.sound = false
            scanner.entry = "教室门口"
            scanner.begin()
            try await wait("No live capture or unchecked-target prompt", timeout:35) {
                scanner.canGuide && (scanner.message.contains("脚前") || scanner.message.contains("落脚"))
            }
            guard starts() == 0 else { throw Failure("An unchecked capture started the player") }
            try mark("uncheckedTarget")
            try phase(1)
            try await wait("No body-facing prompt after checked video frames", timeout:25) { scanner.lastSpatialCue == .face }
            scanner.sound = true
            scanner.bodyForward()
            try await wait("First player start missing", timeout:20) { starts() >= 1 && scanner.lastSpatialCue == .advance }
            try mark("firstPlayerStarted")
            try phase(2)
            try await wait("Second player start missing after moving and settling", timeout:18) { starts() >= 2 && scanner.lastSpatialCue == .advance }
            try mark("secondPlayerStarted")
            try phase(3)
            try await wait("Frozen input did not withdraw the displayed advance", timeout:8) { !scanner.message.contains("向前迈一步") }
            try mark("withdrawnAfterFreeze")
        } catch { fault = error.localizedDescription }
        if scanner.canGuide { scanner.pauseOrResume() }
        let trace = scanner.feedback.trace
        scanner.sound = previousSound
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
        let report: [String: Any] = ["run":run, "state":fault == nil ? "finished" : "failed", "reason":fault ?? "",
            "captureError":scanner.capture.description, "audioIssue":scanner.feedback.issue ?? "", "trace":trace,
            "progress":progress, "actualStepPlayerStarts": trace.filter { $0 == played }.count]
        do {
            if !scanner.metricsText.isEmpty {
                try Data(scanner.metricsText.utf8).write(to:directory.appendingPathComponent("walk-measures.json"),options:.atomic)
            }
            try JSONSerialization.data(withJSONObject:report, options:[.sortedKeys]).write(to:directory.appendingPathComponent("result.json"),options:.atomic)
        } catch { NSLog("PathSense simulator replay could not write its report: %@", error.localizedDescription) }
    }
}
#endif
