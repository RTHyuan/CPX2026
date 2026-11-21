import XCTest
@testable import PathSenseCore

/// Analytic ray/plane intersections in metres. No RGB fixture, recording or device measurement.
final class LidarPassageTests: XCTestCase {
    private typealias Scene = (V3, V3) -> Double?
    private typealias Quality = (Int, Int, V3) -> UInt8?
    private let session = UUID()

    private func pose(_ i: Int, pitch: Double = 40, yaw: Double = 0, roll: Double = -90, exif: Int = 6,
                      position: V3 = V3(0, 1.32, 0), world: Int = 1) -> FramePose {
        let a = pitch * .pi / 180, h = yaw * .pi / 180, r = roll * .pi / 180
        let forward = V3(sin(h)*cos(a), -sin(a), -cos(h)*cos(a))
        let horizontal = V3(cos(h), 0, sin(h)), vertical = V3(sin(h)*sin(a), cos(a), -cos(h)*sin(a))
        let right = horizontal * cos(r) + vertical * sin(r), up = vertical * cos(r) - horizontal * sin(r)
        return FramePose(id: .init(session: session, world: world, frame: i), time: Double(i)*0.12,
                         transform: [right.x,right.y,right.z,0, up.x,up.y,up.z,0, -forward.x,-forward.y,-forward.z,0,
                                     position.x,position.y,position.z,1],
                         intrinsics: [1170,0,0,0,1020,0,994,709,1], width: 1920, height: 1440, exif: exif, tracking: "normal")
    }

    private func horizontal(_ y: Double = 0, where includes: @escaping (V3) -> Bool = { _ in true }) -> Scene {
        { origin, ray in
            guard ray.y < 0 else { return nil }
            let t = (y - origin.y) / ray.y
            return t > 0 && includes(origin + ray * t) ? t : nil
        }
    }

    private func panel(at center: V3, normal: V3 = V3(0,0,1), halfWidth: Double, halfHeight: Double) -> Scene {
        { origin, ray in
            let cosAngle = ray.dot(normal)
            guard abs(cosAngle) > 0.001 else { return nil }
            let t = (center - origin).dot(normal) / cosAngle
            let offset = origin + ray * t - center
            return t > 0 && abs(offset.dot(V3(normal.z,0,-normal.x))) <= halfWidth && abs(offset.y) <= halfHeight ? t : nil
        }
    }

    private func nearest(_ surfaces: Scene...) -> Scene { { o, r in surfaces.compactMap { $0(o, r) }.min() } }

    private func depth(_ p: FramePose, _ scene: Scene, _ quality: Quality) -> LidarDepthFrame? {
        let w = 256, h = 192
        return LidarDepthFrame(pose: p, width: w, height: h) { x, y in
            let uv = p.upright((Double(x)+0.5)/Double(w), (Double(y)+0.5)/Double(h))
            let unit = p.ray(uv.0, uv.1)
            guard let range = scene(p.position, unit), let confidence = quality(x, y, p.position + unit * range) else { return nil }
            return (range * unit.dot(p.forward), confidence)
        }
    }

    private func inspect(_ engine: GroundAssessment, _ p: FramePose, _ scene: Scene,
                         planes: [FloorPatch] = [], quality: Quality = { _,_,_ in 2 },
                         sightings: [Sighting] = [], personOK: Bool = true, exposed: Bool = true) -> NearField {
        engine.inspectLidar(pose: p, depth: depth(p, scene, quality), planes: planes,
                            observations: sightings, personOK: personOK, exposed: exposed)
    }

    private func patch(_ y: Double, z: ClosedRange<Double>, surface: FloorPatch.Surface) -> FloorPatch {
        FloorPatch(y: y, polygon: [V3(-3,y,z.lowerBound), V3(3,y,z.lowerBound), V3(3,y,z.upperBound), V3(-3,y,z.upperBound)], surface: surface)
    }

    private func sector(_ n: NearField, _ angle: Int) -> Sector { n.sectors.first { $0.angle == angle }! }

    func testCentralObstacleAndBothSidePassagesWithoutAnchorOrTexture() {
        let engine = GroundAssessment(), floor = horizontal()
        let scene = nearest(floor, panel(at: V3(0,0.38,-1.25), halfWidth: 0.10, halfHeight: 0.34))
        let first = inspect(engine, pose(1), scene)
        XCTAssertEqual(first.front, .occupied)
        XCTAssertEqual(sector(first, 0).nearest ?? 0, 1.25, accuracy: 0.03)
        for angle in [-30,30] { XCTAssertEqual(sector(first, angle).state, .unknown) }
        let next = inspect(engine, pose(2), scene)
        for angle in [-30,30] { XCTAssertEqual(sector(next, angle).state, .free, "angle \(angle)") }
        XCTAssertEqual(next.front, .occupied)
        XCTAssertFalse(sector(next, 0).hasMeasuredDrop)
        XCTAssertEqual(sector(next, 60).state, .unknown)
    }

    func testLocalDescentNeedsUpperAndLowerSurfaceInSameWalkingStrip() {
        let engine = GroundAssessment()
        let cut: (V3) -> Bool = { abs($0.x) < 0.25 && $0.z < -1.06 }
        let upper = horizontal { !cut($0) }, landing = horizontal(-0.19, where: cut)
        let first = inspect(engine, pose(1), nearest(upper, landing))
        XCTAssertEqual(first.front, .occupied)
        guard case let .measuredDrop(q) = sector(first, 0).stepEvidence else { return XCTFail("Missing local landing") }
        XCTAssertEqual(q.y, -0.19, accuracy: 0.005)
        XCTAssertTrue(cut(q))
        XCTAssertTrue(first.hazards.contains { $0.kind == .steps && $0.box.valid })
        let next = inspect(engine, pose(2), nearest(upper, landing))
        for side in [-30,30] { XCTAssertEqual(sector(next, side).state, .free) }
        let missingOrDistant = [upper, nearest(upper, horizontal(-0.19) { cut($0) && $0.z < -1.80 })]
        for (i, scene) in missingOrDistant.enumerated() {
            let result = inspect(engine, pose(3 + i), scene)
            XCTAssertEqual(result.front, .unknown)
            XCTAssertFalse(sector(result, 0).hasMeasuredDrop)
        }
    }

    func testScatteredMissingRaysToleratedButLowConfidenceLaneAndCrosswiseHoleRevokeProof() {
        let engine = GroundAssessment(), floor = horizontal()
        let scattered: Quality = { x,y,_ in (x/2 + 3*(y/2)).isMultiple(of: 11) ? nil : 1 }
        _ = inspect(engine, pose(1), floor, quality: scattered)
        XCTAssertEqual(inspect(engine, pose(2), floor, quality: scattered).front, .free)
        let lane: Quality = { _,_,q in (0.07...0.30).contains(q.x) && (-1.65 ... -1.25).contains(q.z) ? 0 : 2 }
        let blind = inspect(engine, pose(3), floor, quality: lane)
        XCTAssertEqual(blind.front, .unknown)
        XCTAssertEqual(sector(blind, -30).state, .free)
        XCTAssertEqual(inspect(engine, pose(4), floor).front, .unknown)
        XCTAssertEqual(inspect(engine, pose(5), floor).front, .free)
        let hole = horizontal { !((-1.35 ... -1.10).contains($0.z) && abs($0.x) < 0.26) }
        let after = inspect(engine, pose(6), hole)
        XCTAssertEqual(after.front, .unknown)
        XCTAssertFalse(sector(after, 0).hasMeasuredDrop)
    }

    func testVisibleFloorWithBlindBodyVolumeRemainsUnknown() {
        let engine = GroundAssessment(), floor = horizontal()
        _ = inspect(engine, pose(1), floor)
        XCTAssertEqual(inspect(engine, pose(2), floor).front, .free)
        // The entire first two metres of the floor still return. Rays through the higher
        // portion of the corridor would hit the floor farther away, in this blind region.
        let blind: Quality = { _,_,q in q.z < -2.30 && abs(q.x) < 0.45 ? nil : 2 }
        let current = inspect(engine, pose(3), floor, quality: blind)
        XCTAssertEqual(current.front, .unknown)
        XCTAssertEqual(sector(current, 30).state, .free)
    }

    func testAnchorAndFarFloorCannotBridgeVisibleHoleAtToes() {
        let engine = GroundAssessment(), floor = horizontal()
        let anchor = patch(0, z: -4...1, surface: .floor)
        _ = inspect(engine, pose(1, pitch: 47), floor, planes: [anchor])
        XCTAssertEqual(inspect(engine, pose(2, pitch: 47), floor, planes: [anchor]).front, .free)
        let hole = horizontal { !(abs($0.x) < 0.17 && (-0.54 ... -0.22).contains($0.z)) }
        let n = inspect(engine, pose(3, pitch: 47), hole, planes: [anchor])
        XCTAssertEqual(n.front, .unknown)
        XCTAssertFalse(sector(n, 0).hasMeasuredDrop)
    }

    func testDropUnderOneSideOfBodyVetoesAnOtherwiseLevelCentreline() {
        let engine = GroundAssessment()
        let cut: (V3) -> Bool = { (0.035...0.40).contains($0.x) && (-1.95 ... -1.04).contains($0.z) }
        let scene = nearest(horizontal { !cut($0) }, horizontal(-0.17, where: cut))
        _ = inspect(engine, pose(1), scene)
        let n = inspect(engine, pose(2), scene)
        guard case let .measuredDrop(point) = sector(n, 0).stepEvidence else { return XCTFail("No measured right-edge drop") }
        XCTAssertTrue(cut(point))
        XCTAssertEqual(n.front, .occupied)
        XCTAssertEqual(sector(n, -30).state, .free)
    }

    func testTableTopsAndRemoteLandingsCannotEstablishApproachLevel() {
        let remote = patch(-0.20, z: -4 ... -1.05, surface: .floor)
        let table = patch(0.72, z: -3...1, surface: .unclassified)
        let labeledBench = patch(0.10, z: -3...1, surface: .nonFloor)
        let cases: [(Scene, [FloorPatch])] = [
            (horizontal(0.72), [table]), (horizontal(0.10), [labeledBench]),
            (horizontal(-0.20) { $0.z < -1.05 }, [remote]),
            (horizontal(0.0) { $0.z < -0.88 }, []),
            (horizontal(-0.20), [patch(0, z: -2...1, surface: .floor)])
        ]
        for (scene, planes) in cases {
            let engine = GroundAssessment()
            for i in 1...3 {
                let n = inspect(engine, pose(i), scene, planes: planes)
                XCTAssertNil(n.best)
                XCTAssertFalse(sector(n, 0).hasMeasuredDrop)
            }
        }
    }

    func testTorsoObstacleWithoutGroundAndPersonDetectionVeto() {
        let engine = GroundAssessment(), wall = panel(at: V3(0,1.13,-1.2), halfWidth: 0.10, halfHeight: 0.18)
        let blocked = inspect(engine, pose(1, pitch: 6), wall)
        XCTAssertEqual(blocked.front, .occupied)
        XCTAssertEqual(sector(blocked, 30).state, .unknown)
        let floor = horizontal(), person = Sighting(kind: .person, box: .init(0.48,0.41,0.52,0.75), confidence: 0.9)
        _ = inspect(engine, pose(2), floor)
        let mobile = inspect(engine, pose(3), floor, sightings: [person])
        XCTAssertEqual(mobile.front, .occupied)
        XCTAssertEqual(mobile.hazards, [person])
        XCTAssertNil(inspect(engine, pose(4), floor, personOK: false).best)
        XCTAssertFalse(inspect(engine, pose(5), floor, exposed: false).visible)
        XCTAssertNil(inspect(engine, pose(6), floor, quality: { _,_,_ in 0 }).best)
    }

    func testClassifiedFloorBesideFeetSupportsALowerHandheldPose() {
        let engine = GroundAssessment(), position = V3(0,0.98,0)
        let nearFloor = patch(0, z: -3.0 ... -0.28, surface: .floor)
        XCTAssertFalse(nearFloor.contains(position))
        let farWall = panel(at: V3(0,1,-3.6), halfWidth: 3, halfHeight: 1)
        let scene = nearest(horizontal(), farWall)
        for i in 1...2 {
            let n = inspect(engine, pose(i, position: position), scene)
            XCTAssertNil(n.best)
        }
        _ = inspect(engine, pose(3, position: position), scene, planes: [nearFloor])
        let reliable = inspect(engine, pose(4, position: position), scene, planes: [nearFloor])
        XCTAssertEqual(reliable.front, .free)
    }

    func testUnprovenAnchorCannotPinLevelAndMeasuredStationCannotRebaseAcrossLip() {
        let engine = GroundAssessment(), floor = horizontal()
        let wrongAnchor = patch(0.19, z: -2...1, surface: .floor)
        XCTAssertNil(inspect(engine, pose(1), floor, planes: [wrongAnchor]).best)
        _ = inspect(engine, pose(2), floor)
        XCTAssertEqual(inspect(engine, pose(3), floor).front, .free)
        for i in 4...6 {
            let lowerOnly = inspect(engine, pose(i), horizontal(-0.18))
            XCTAssertNil(lowerOnly.best)
            XCTAssertFalse(sector(lowerOnly, 0).hasMeasuredDrop)
        }
    }

    func testInvalidCalibrationRangesAndConfidenceDoNotSupplyEvidence() {
        let engine = GroundAssessment()
        for (index, value) in [Double.nan, .infinity, -0.4, 0, 0.08, 6.0].enumerated() {
            let p = pose(index + 1)
            let map = LidarDepthFrame(pose: p, width: 256, height: 192) { _,_ in (value, 2) }
            let n = engine.inspectLidar(pose: p, depth: map, planes: [], observations: [], personOK: true, exposed: true)
            XCTAssertFalse(n.visible)
            XCTAssertTrue(n.sectors.allSatisfy { $0.state == .unknown })
        }
        let p = pose(7)
        XCTAssertNil(LidarDepthFrame(pose: p, width: 192, height: 256) { _,_ in (1.4, 2) })
        let invalid = LidarDepthFrame(pose: p, width: 256, height: 192) { _,_ in (1.4, 255) }
        XCTAssertFalse(engine.inspectLidar(pose: p, depth: invalid, planes: [], observations: [], personOK: true, exposed: true).visible)
        var uncalibrated = pose(8)
        uncalibrated.intrinsics[0] = 0
        XCTAssertNil(depth(uncalibrated, horizontal()) { _,_,_ in 2 })
        XCTAssertNil(engine.inspectLidar(pose: uncalibrated, depth: nil, planes: [], observations: [], personOK: true, exposed: true).best)
    }

    func testFreshPerSectorEvidenceResetsAcrossMotionGapsWorldsAndMissingMaps() {
        let engine = GroundAssessment(), floor = horizontal()
        _ = inspect(engine, pose(1), floor)
        XCTAssertNil(inspect(engine, pose(1), floor).best)
        XCTAssertEqual(inspect(engine, pose(2), floor).front, .free)
        XCTAssertNil(inspect(engine, pose(8), floor).best)
        XCTAssertNil(inspect(engine, pose(9, yaw: 21), floor).best)
        XCTAssertNil(inspect(engine, pose(10, world: 2), floor).best)
        XCTAssertEqual(inspect(engine, pose(11, world: 2), floor).front, .free)
        let p = pose(12, world: 2), staleMap = depth(pose(11, world: 2), floor) { _,_,_ in 2 }
        for map in [staleMap, nil] {
            XCTAssertNil(engine.inspectLidar(pose: p, depth: map, planes: [], observations: [], personOK: true, exposed: true).best)
        }
        XCTAssertNil(inspect(engine, pose(13, world: 2), floor).best)
        var lost = pose(14, world: 2)
        lost.tracking = "limited"
        XCTAssertFalse(inspect(engine, lost, floor).visible)
        XCTAssertNil(inspect(engine, pose(13, world: 2), floor).best)
        XCTAssertNil(inspect(engine, pose(15, world: 2), floor).best)
    }

    func testNativeDepthScalingOppositeRollWorldTranslationAndAsymmetricObstacle() {
        let engine = GroundAssessment(), position = V3(2.3,0.92,-0.65), level = -0.40
        let pane = panel(at: V3(3.80,0.12,0.19), normal: V3(1,0,0), halfWidth: 0.10, halfHeight: 0.28)
        let scene = nearest(horizontal(level), pane)
        for i in 1...2 {
            let n = inspect(engine, pose(i, yaw: 90, roll: 90, exif: 8, position: position), scene)
            XCTAssertEqual(sector(n, 30).state, .occupied)
            XCTAssertEqual(sector(n, 0).state, i == 1 ? .unknown : .free)
            if i == 2 { XCTAssertEqual(sector(n, -30).state, .free) }
        }
    }
}
