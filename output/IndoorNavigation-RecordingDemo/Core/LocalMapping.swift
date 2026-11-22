import Foundation

/// ARKit session coordinates only: +x is right, heading zero faces -z.
/// A recorded trajectory is where the camera was, not a certified walking route.
struct LocalMapPose: Codable, Equatable {
    let frame: FrameID
    let time: Double
    let position: V3
    let heading: Double

    init(_ pose: FramePose) {
        frame = pose.id; time = pose.time; position = pose.position; heading = pose.heading
    }
}

struct LocalMapLandmark: Codable, Equatable {
    let id: Int
    let kind: FeatureKind
    let label: String?
    /// Present only when the existing landmark tracker has a measured 3D position.
    let point: V3?
    /// Degrees relative to the current camera; a direction alone does not locate a landmark.
    let bearing: Double?
    let observedFrom: V3
    let observedAt: Double
    let confidence: Double
}

struct LocalMapSector: Codable, Equatable {
    let angle: Int
    let state: CellState
    let nearest: Double?
}

/// Display/export samples already expressed in the ARKit world coordinate system.
/// Depth geometry and visual features have different sources; neither permits a step.
struct MappingPointBatch {
    let pose: FramePose
    let points: [V3]
    let source: String
}

/// A bounded, local display/export record. It does not grant a navigation step permit.
struct LocalMapSnapshot: Codable {
    let pose: FramePose?
    let path: [LocalMapPose]
    let landmarks: [LocalMapLandmark]
    let sectors: [LocalMapSector]
    let sectorPose: LocalMapPose?
    let sectorExpiresAt: Double?
    var points: [[Double]] = []
    var pointSource: String? = nil

    static let empty = LocalMapSnapshot(pose: nil, path: [], landmarks: [], sectors: [],
                                        sectorPose: nil, sectorExpiresAt: nil)
}

struct LocalMappingRecorder {
    private var epoch: FrameID?
    private var current: FramePose?
    private var path: [LocalMapPose] = []
    private var landmarks: [Landmark] = []
    private var field: NearField?
    private var points: [V3] = []
    private var voxels: Set<Voxel> = []
    private var pointSource: String?
    private var lastPointFrame: FrameID?
    private struct Voxel: Hashable { let x, y, z: Int }

    mutating func clearNearField() { field = nil }

    mutating func record(pose: FramePose) {
        if epoch?.sameWorld(pose.id) != true {
            self = Self()
            epoch = pose.id
        }
        guard Self.usable(pose) else { field = nil; return }
        guard
              current.map({ pose.time >= $0.time && pose.id.frame >= $0.id.frame }) ?? true else { return }
        current = pose
        if path.last.map({ $0.position.groundDistance(pose.position) >= 0.10 }) ?? true {
            path.append(LocalMapPose(pose))
            if path.count > 1_000 { path.removeFirst(path.count - 1_000) }
        }
        if !fieldIsCurrent { field = nil }
    }

    mutating func record(field: NearField) {
        // Only an explicit pose update changes coordinate worlds. A delayed near-field
        // callback from the previous world must not reset the current map.
        guard epoch?.sameWorld(field.pose.id) ?? true else { return }
        if let previous = self.field, previous.pose.id.sameWorld(field.pose.id),
           field.pose.time < previous.pose.time || field.pose.id.frame < previous.pose.id.frame { return }
        record(pose: field.pose)
        guard Self.usable(field.pose), field.visible, let current,
              current.id.sameWorld(field.pose.id), field.pose.id.frame <= current.id.frame,
              (0...0.65).contains(current.time - field.pose.time),
              current.position.groundDistance(field.pose.position) < 0.055,
              current.sameView(as: field.pose, within: 5) else { self.field = nil; return }
        self.field = field
    }

    mutating func record(points batch: MappingPointBatch) {
        guard let current, Self.usable(batch.pose), current.id.sameWorld(batch.pose.id),
              batch.pose.id.frame <= current.id.frame,
              (0...1.0).contains(current.time - batch.pose.time),
              batch.source == "lidar_depth" || batch.source == "visual_features",
              lastPointFrame.map({ batch.pose.id.frame > $0.frame }) ?? true else { return }
        lastPointFrame = batch.pose.id
        // Avoid mixing depth surfaces with sparse visual tracking points.
        if pointSource == "lidar_depth", batch.source != "lidar_depth" { return }
        if pointSource != batch.source { points.removeAll(); voxels.removeAll() }
        pointSource = batch.source
        for point in batch.points.prefix(2_000) where Self.finite(point)
            && abs(point.x) < 1_000 && abs(point.y) < 1_000 && abs(point.z) < 1_000 {
            let voxel = Voxel(x: Int(floor(point.x / 0.08)), y: Int(floor(point.y / 0.08)), z: Int(floor(point.z / 0.08)))
            if points.count < 24_000, voxels.insert(voxel).inserted { points.append(point) }
        }
    }

    /// Pass the current LandmarkBook records; no points are inferred by this recorder.
    mutating func record(landmarks: [Landmark]) {
        guard let current else { return }
        self.landmarks = Array(landmarks.filter {
            Self.usable($0.last) && $0.last.id.sameWorld(current.id)
                && $0.last.time <= current.time && $0.last.id.frame <= current.id.frame
                && $0.ray.x.isFinite && $0.ray.y.isFinite && $0.ray.z.isFinite
                && $0.confidence.isFinite
                && ($0.point.map(Self.finite) ?? true)
        }.sorted { $0.last.time > $1.last.time }.prefix(256))
    }

    var snapshot: LocalMapSnapshot {
        let visibleLandmarks: [LocalMapLandmark] = current.map { pose in
            landmarks.compactMap { mark in
                let lifetime = mark.kind.mobile ? 0.7 : (mark.kind == .aisle_entrance ? 3.0 : Landmark.signLifetime)
                guard (0...lifetime).contains(pose.time - mark.last.time) else { return nil }
                let bearing = mark.bearing(at: pose)
                guard mark.point != nil || bearing != nil else { return nil }
                return LocalMapLandmark(id: mark.id, kind: mark.kind, label: mark.label,
                                        point: mark.point, bearing: bearing, observedFrom: mark.last.position,
                                        observedAt: mark.last.time, confidence: mark.confidence)
            }
        } ?? []
        let live = fieldIsCurrent ? field : nil
        let sectors = live?.sectors.filter { (-180...180).contains($0.angle) }.map {
            LocalMapSector(angle: $0.angle, state: $0.state,
                           nearest: $0.nearest.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        } ?? []
        return LocalMapSnapshot(pose: current, path: path, landmarks: visibleLandmarks, sectors: sectors,
                                sectorPose: live.map { LocalMapPose($0.pose) },
                                sectorExpiresAt: live.map { $0.pose.time + 0.65 },
                                points: points.map { [$0.x, $0.y, $0.z] }, pointSource: pointSource)
    }

    private var fieldIsCurrent: Bool {
        guard let field, let current, field.visible, current.id.sameWorld(field.pose.id) else { return false }
        return (0...0.65).contains(current.time - field.pose.time)
            && current.position.groundDistance(field.pose.position) < 0.055
            && current.sameView(as: field.pose, within: 5)
    }

    private static func finite(_ point: V3) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }
    private static func usable(_ pose: FramePose) -> Bool {
        pose.time.isFinite && pose.transform.count == 16 && pose.transform.allSatisfy(\.isFinite)
            && pose.normal && finite(pose.position) && pose.heading.isFinite
    }
}
