#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Inputs are measured/synthetic observations supplied by XCTest. Production has no replay entry point.
struct SimulatorEvidence: Decodable {
    let heading: Double
    let position: V3
    let tracking: String
    let world: Int
    let sectors: [Int]
    let occupied: Bool
    let features: [Sighting]
    func events(session: UUID, sequence: Int, time: Double) -> (FramePose, NearField) {
        let angle = heading * Double.pi / 180
        let c = cos(angle), s = sin(angle)
        let pose = FramePose(id: .init(session: session, world: world, frame: sequence), time: time,
                             transform: [c,0,s,0, 0,1,0,0, -s,0,c,0, position.x,position.y,position.z,1],
                             intrinsics: [550,0,0,0,550,0,500,400,1], width: 1000, height: 800, exif: 1, tracking: tracking)
        let bins = stride(from: -60, through: 60, by: 15).map { angle in
            Sector(angle: angle, state: occupied && angle == 0 ? .occupied : (sectors.contains(angle) ? .free : .unknown))
        }
        return (pose, NearField(pose: pose, visible: tracking == "normal", sectors: bins, hazards: features.filter { $0.kind.mobile || $0.kind == .steps }))
    }
}
#endif
