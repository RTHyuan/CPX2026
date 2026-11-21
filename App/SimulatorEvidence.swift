#if DEBUG && targetEnvironment(simulator)
import Foundation
import notify

/// Capture-boundary inputs from the UI runner. Pixel indices carry no sign names or answers.
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
    let reason: String?
    let picture: Int?
    let readSigns: Bool?

    func events(session: UUID, sequence: Int, time: Double, width: Int, height: Int) -> (FramePose, NearField) {
        let offsets = headingOffsets ?? []
        let yaw = (heading + (offsets.isEmpty ? 0 : offsets[sequence % offsets.count])) * .pi / 180
        let pitch = (pitchDown ?? 0) * .pi / 180
        let c = cos(yaw), s = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        // Upright sensor pixels. Keep the original replay's horizontal FOV at every fixture size.
        let w = Double(width), h = Double(height), focal = 0.55 * w
        let pose = FramePose(id: .init(session: session, world: world, frame: sequence), time: time,
                             transform: [c,0,s,0, s*sp,cp,-c*sp,0, -s*cp,sp,c*cp,0, position.x,position.y,position.z,1],
                             intrinsics: [focal,0,0,0,focal,0,w/2,h/2,1], width: width, height: height, exif: 1, tracking: tracking)
        let bins = stride(from: -60, through: 60, by: 15).map { angle in
            Sector(angle: angle, state: occupied && angle == 0 ? .occupied : (sectors.contains(angle) ? .free : .unknown))
        }
        return (pose, NearField(pose: pose, visible: tracking == "normal", sectors: bins,
                                hazards: features.filter { $0.kind.mobile || $0.kind == .steps }, reason: reason))
    }
}

/// Optional XCTest-controlled position in a tape. Repeats the selected measurement with a fresh
/// frame ID and timestamp until the runner advances it, independently of OCR and speech speed.
final class SimulatorEvidenceTape {
    private let observations: [SimulatorEvidence]
    private var phaseToken: Int32 = NOTIFY_TOKEN_INVALID

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let json = env["PATHSENSE_TEST_EVIDENCE"] else { return nil }
        do { observations = try JSONDecoder().decode([SimulatorEvidence].self, from: Data(json.utf8)) }
        catch { preconditionFailure("Invalid simulator evidence: \(error)") }
        precondition(!observations.isEmpty, "Empty simulator evidence tape")
        if let name = env["PATHSENSE_TEST_PHASE"] {
            precondition(notify_register_check(name, &phaseToken) == NOTIFY_STATUS_OK, "Cannot read the XCTest phase")
        }
    }
    deinit { if phaseToken != NOTIFY_TOKEN_INVALID { notify_cancel(phaseToken) } }

    func sample(at sequence: Int) -> SimulatorEvidence {
        guard phaseToken != NOTIFY_TOKEN_INVALID else { return observations[min(sequence, observations.count - 1)] }
        var phase: UInt64 = 0
        precondition(notify_get_state(phaseToken, &phase) == NOTIFY_STATUS_OK && phase < observations.count, "Invalid XCTest phase")
        return observations[Int(phase)]
    }
}
#endif
