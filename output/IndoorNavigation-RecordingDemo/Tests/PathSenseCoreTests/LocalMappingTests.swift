import XCTest
@testable import PathSenseCore

final class LocalMappingTests: XCTestCase {
    private let session = UUID()
    private func pose(_ frame: Int, time: Double? = nil, x: Double = 0, world: Int = 1, tracking: String = "normal") -> FramePose {
        .init(id: .init(session: session, world: world, frame: frame), time: time ?? Double(frame) / 10,
              transform: [1,0,0,0, 0,1,0,0, 0,0,1,0, x,1.4,0,1], intrinsics: [550,0,0,0,550,0,500,400,1],
              width: 1000, height: 800, exif: 1, tracking: tracking)
    }

    func testTrajectorySamplesActualNormalPosesAndBoundsStorage() {
        var recorder = LocalMappingRecorder()
        recorder.record(pose: pose(0))
        recorder.record(pose: pose(1, x: 0.04))
        recorder.record(pose: pose(2, x: 0.12))
        recorder.record(pose: pose(3, x: 0.30, tracking: "limited"))
        XCTAssertEqual(recorder.snapshot.path.map(\.position.x), [0, 0.12])
        XCTAssertEqual(recorder.snapshot.pose?.id.frame, 2)
        for i in 4...1_105 { recorder.record(pose: pose(i, x: Double(i))) }
        XCTAssertEqual(recorder.snapshot.path.count, 1_000)
        XCTAssertEqual(recorder.snapshot.path.last?.position.x, 1_105)
    }

    func testWorldChangeClearsCoordinatesEvenBeforeNormalTrackingReturns() {
        var recorder = LocalMappingRecorder()
        recorder.record(pose: pose(0))
        recorder.record(field: .init(pose: pose(1), visible: true, sectors: [.init(angle: 0, state: .free)], hazards: []))
        recorder.record(pose: pose(2, world: 2, tracking: "limited"))
        XCTAssertNil(recorder.snapshot.pose)
        XCTAssertTrue(recorder.snapshot.path.isEmpty)
        XCTAssertTrue(recorder.snapshot.sectors.isEmpty)
        recorder.record(pose: pose(3, x: 5, world: 2))
        XCTAssertEqual(recorder.snapshot.path.map(\.position.x), [5])
    }

    func testDelayedNearFieldCannotResetTheCurrentWorldOrClearNewOccupancy() {
        var recorder = LocalMappingRecorder()
        // A first near-field observation may initialize a recorder before a pose callback.
        recorder.record(field: .init(pose: pose(1), visible: true, sectors: [.init(angle: 0, state: .free)], hazards: []))
        XCTAssertEqual(recorder.snapshot.pose?.id.world, 1)
        recorder.record(pose: pose(2, x: 5, world: 2))
        recorder.record(field: .init(pose: pose(3, x: 5, world: 2), visible: true, sectors: [.init(angle: 0, state: .occupied)], hazards: []))
        let current = recorder.snapshot
        recorder.record(field: .init(pose: pose(4, x: 0, world: 1), visible: true, sectors: [.init(angle: 0, state: .free)], hazards: []))
        XCTAssertEqual(recorder.snapshot.pose, current.pose)
        XCTAssertEqual(recorder.snapshot.path, current.path)
        XCTAssertEqual(recorder.snapshot.sectors, current.sectors)
        XCTAssertEqual(recorder.snapshot.sectors.first?.state, .occupied)
        XCTAssertEqual(recorder.snapshot.sectorPose?.frame.world, 2)
    }

    func testNearSectorsExpireInsteadOfBecomingHistoricFreeSpace() throws {
        var recorder = LocalMappingRecorder()
        recorder.record(field: .init(pose: pose(0), visible: true, sectors: [.init(angle: 0, state: .free, nearest: 1.2)], hazards: []))
        XCTAssertEqual(recorder.snapshot.sectors.first?.state, .free)
        XCTAssertEqual(recorder.snapshot.sectorExpiresAt, 0.65)
        recorder.clearNearField()
        XCTAssertTrue(recorder.snapshot.sectors.isEmpty)
        XCTAssertEqual(recorder.snapshot.path.count, 1)
        recorder.record(field: .init(pose: pose(0), visible: true, sectors: [.init(angle: 0, state: .free)], hazards: []))
        recorder.record(pose: pose(1, time: 0.66))
        XCTAssertTrue(recorder.snapshot.sectors.isEmpty)
        XCTAssertNil(recorder.snapshot.sectorPose)
        recorder.record(field: .init(pose: pose(2, time: 0.7), visible: true, sectors: [.init(angle: 0, state: .free)], hazards: []))
        recorder.record(pose: pose(3, time: 0.8, x: 0.06))
        XCTAssertTrue(recorder.snapshot.sectors.isEmpty)
        recorder.record(field: .init(pose: pose(4, time: 0.9, x: 0.06), visible: true, sectors: [.init(angle: 0, state: .occupied)], hazards: []))
        recorder.record(field: .init(pose: pose(3, time: 0.8, x: 0.06), visible: true, sectors: [.init(angle: 0, state: .free)], hazards: []))
        XCTAssertEqual(recorder.snapshot.sectors.first?.state, .occupied, "A late observation cannot replace newer occupancy")
        recorder.record(field: .init(pose: pose(5, time: 1, x: 0.06), visible: false, sectors: [.init(angle: 0, state: .free)], hazards: []))
        XCTAssertTrue(recorder.snapshot.sectors.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(recorder.snapshot))
    }

    func testMeasuredPointAndBearingOnlyLandmarkRemainDistinct() throws {
        let p = pose(0)
        let rayOnly = Landmark(id: 1, kind: .door, first: p, last: p, firstRay: .init(0,0,-1), ray: .init(0,0,-1),
                               box: .init(0.3,0.2,0.7,0.9), confidence: 0.9, label: "Door", appearance: nil, point: nil, count: 1)
        var located = rayOnly; located.id = 2; located.point = .init(0, 1.4, -2)
        var recorder = LocalMappingRecorder(); recorder.record(pose: p); recorder.record(landmarks: [rayOnly, located])
        let initial = recorder.snapshot.landmarks.sorted { $0.id < $1.id }
        XCTAssertNil(initial[0].point)
        XCTAssertEqual(initial[0].bearing, 0)
        XCTAssertEqual(initial[1].point, .init(0,1.4,-2))
        recorder.record(pose: pose(1, x: 0.4))
        XCTAssertEqual(recorder.snapshot.landmarks.map(\.id), [2], "A retained ray cannot invent a location after translation")
        let decoded = try JSONDecoder().decode(LocalMapSnapshot.self, from: JSONEncoder().encode(recorder.snapshot))
        XCTAssertEqual(decoded.landmarks.first?.point, .init(0,1.4,-2))
    }

    func testPointCloudKeepsMeasuredSourceAndRejectsOldWorldAndNonFinitePoints() throws {
        var recorder = LocalMappingRecorder()
        let first = pose(1)
        recorder.record(pose: first)
        recorder.record(points: .init(pose: first, points: [.init(0,1,-1), .init(0.01,1.01,-0.99), .init(.nan,0,0)], source: "visual_features"))
        XCTAssertEqual(recorder.snapshot.points.count, 1)
        let second = pose(2)
        recorder.record(pose: second)
        recorder.record(points: .init(pose: second, points: [.init(1,1,-2), .init(1.01,1.01,-2)], source: "lidar_depth"))
        XCTAssertEqual(recorder.snapshot.pointSource, "lidar_depth")
        XCTAssertEqual(recorder.snapshot.points, [[1,1,-2]])
        recorder.record(pose: pose(3, world: 2))
        recorder.record(points: .init(pose: second, points: [.init(3,3,3)], source: "lidar_depth"))
        XCTAssertTrue(recorder.snapshot.points.isEmpty)
        XCTAssertNil(recorder.snapshot.pointSource)
        XCTAssertNoThrow(try JSONEncoder().encode(recorder.snapshot))
    }
}
