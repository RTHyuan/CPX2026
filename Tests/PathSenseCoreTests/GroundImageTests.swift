import XCTest
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
@testable import PathSenseCore

/// JPEG pixels come from the two time-stamped field recordings. Camera intrinsics, poses, AR
/// planes, features, detections and optical-axis depths below are controlled test inputs.
/// Reusing a recorded still holds the appearance fixed while the numerical input changes.
final class GroundImageTests: XCTestCase {
    private enum Capture: String {
        case overheadSign = "rtr2-10.6.jpg", lectureTheatre = "rtr1-12.0.jpg"
    }

    private func recorded(_ capture: Capture) throws -> FloorImage {
        #if canImport(ImageIO)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["PATHSENSE_REAL_FRAMES_DIR"]
        let dir = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repo.appendingPathComponent(".build-local/field-feedback/real-frames")
        let url = dir.appendingPathComponent(capture.rawValue)
        if override == nil && !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("Place the extracted RTR JPEGs in \(dir.path) or set PATHSENSE_REAL_FRAMES_DIR.")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.path)
        let jpeg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.path)
        XCTAssertEqual(jpeg.width, 720)
        XCTAssertEqual(jpeg.height, 1280)
        // The supplied JPEGs are already upright. Decode their brightness at the camera adapter's
        // 96 × 96 sample locations, in memory and with nearest-neighbour sampling.
        let w = 96, h = 96
        var samples = [UInt8](repeating: 0, count: w * h)
        try samples.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.interpolationQuality = .none
            context.draw(jpeg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return FloorImage(pixels: samples)
        #else
        throw XCTSkip("ImageIO is required to decode the original field JPEGs.")
        #endif
    }

    private let world = UUID()
    private func patch(_ y: Double, x: ClosedRange<Double> = -3...3, z: ClosedRange<Double>) -> FloorPatch {
        FloorPatch(y: y, polygon: [V3(x.lowerBound,y,z.lowerBound), V3(x.upperBound,y,z.lowerBound),
                                   V3(x.upperBound,y,z.upperBound), V3(x.lowerBound,y,z.upperBound)])
    }
    private var floor: FloorPatch { patch(0, z: -3...2) }
    private var lip: FloorPatch { patch(0, z: -0.96...2) }
    private var landing: FloorPatch { patch(-0.19, z: -2.4 ... -0.97) }
    private var features: [V3] {
        (-11...11).flatMap { x in (-12...10).map { z in V3(Double(x)/5, 0, Double(z)/5) } }
    }
    private func pose(_ i: Int, yaw: Double = 0, pitch: Double = 36, x: Double = 0) -> FramePose {
        let a = pitch * .pi / 180, h = yaw * .pi / 180, c = cos(a), s = sin(a)
        return .init(id: .init(session: world, world: 1, frame: i), time: Double(i)/10,
                     transform: [cos(h),0,sin(h),0, sin(h)*s,c,-cos(h)*s,0, -sin(h)*c,s,cos(h)*c,0, x,1.3,0,1],
                     intrinsics: [540,0,0,0,540,0,500,400,1], width: 1000,height: 800,exif: 1, tracking:"normal")
    }
    private func front(_ n: NearField) -> Sector { n.sectors.first { $0.angle == 0 }! }
    private let systemStairs = Sighting(kind: .steps, box: .init(0.30,0.36,0.70,0.96), confidence: 0.99, label: "staircase")

    func testRealRTRPixelsAndPlaneAloneLeaveGroundUnknown() throws {
        for capture in [Capture.overheadSign, .lectureTheatre] {
            let frame = try recorded(capture), loop = GroundAssessment()
            for i in 0...3 {
                let n = loop.inspect(image: frame, pose: pose(i), planes: i == 0 ? [] : [floor], features: [], observations: [], personOK: true)
                XCTAssertTrue(n.visible)
                XCTAssertEqual(n.front, .unknown)
                XCTAssertTrue(n.hazards.isEmpty)
            }
        }
    }

    func testRealRTRFloorProofNeedsMatchingPixelsAndBodyWidthReturns() throws {
        let loop = GroundAssessment(), theatre = try recorded(.lectureTheatre), sign = try recorded(.overheadSign)
        let points = features
        _ = loop.inspect(image: theatre, pose: pose(0), planes: [floor], features: points, observations: [], personOK: true)
        let centerOnly = loop.inspect(image: theatre, pose: pose(1), planes: [floor], features: points.filter { $0.x == 0 }, observations: [], personOK: true)
        XCTAssertEqual(centerOnly.front, .unknown)
        let clear = loop.inspect(image: theatre, pose: pose(2), planes: [floor], features: points, observations: [], personOK: true)
        XCTAssertEqual(clear.front, .free)
        let mismatch = loop.inspect(image: sign, pose: pose(3), planes: [floor], features: points, observations: [], personOK: true)
        XCTAssertTrue(mismatch.visible)
        XCTAssertEqual(mismatch.front, .unknown)
        XCTAssertTrue(mismatch.hazards.isEmpty)
        let p = pose(4)
        let depthMismatch = loop.inspect(image: theatre, pose: p, planes: [floor], features: [], observations: [], personOK: true,
                                         depth: { self.range(p, at: $0, level: { _ in 0 }) })
        XCTAssertEqual(depthMismatch.front, .unknown)
        XCTAssertTrue(depthMismatch.hazards.isEmpty)
        let lost = loop.inspect(image: nil, pose: pose(5), planes: [floor], features: points, observations: [], personOK: true)
        XCTAssertFalse(lost.visible)
        XCTAssertEqual(lost.front, .unknown)
    }

    func testRealRTRLockerBandsAndCoarseCategoryNeedIndependentGeometry() throws {
        let sign = try recorded(.overheadSign)
        XCTAssertTrue(sign.hasHorizontalBands)
        for system in [false, true] {
            let loop = GroundAssessment(), obs = system ? [systemStairs] : []
            let expected: StepEvidence = system ? .systemClassification : .horizontalBands
            for i in 0...3 {
                let n = loop.inspect(image: sign, pose: pose(i), planes: [floor], features: [], observations: obs, personOK: true)
                XCTAssertEqual(front(n).stepEvidence, expected)
                XCTAssertEqual(n.front, .unknown)
                XCTAssertTrue(n.hazards.isEmpty)
            }
            // Supply flat numerical depths independently across the entire walking strip.
            let p = pose(4)
            let flat = loop.inspect(image: sign, pose: p, planes: [floor], features: [], observations: obs, personOK: true,
                                    depth: { self.range(p, at: $0, level: { _ in 0 }) })
            XCTAssertEqual(flat.front, .free)
            XCTAssertEqual(front(flat).stepEvidence, expected)
            XCTAssertTrue(flat.hazards.isEmpty)
        }
    }

    func testRealRTRPixelsWithNumericalLowObjectAndAdjacentLowerLanding() throws {
        let theatre = try recorded(.lectureTheatre), sign = try recorded(.overheadSign)
        let object = GroundAssessment().inspect(image: theatre, pose: pose(0), planes: [floor], features: [V3(0,0.13,-1.2)], observations: [], personOK: true)
        XCTAssertEqual(object.front, .occupied)
        XCTAssertEqual(front(object).nearest, 1.2)
        for frame in [theatre, sign] {
            let n = GroundAssessment().inspect(image: frame, pose: pose(0), planes: [lip, landing], features: [], observations: [], personOK: false)
            guard case let .measuredDrop(point) = front(n).stepEvidence else { return XCTFail("Missing geometric drop on the first frame") }
            XCTAssertTrue(landing.contains(point))
            XCTAssertFalse(lip.contains(point))
            XCTAssertEqual(point.y, -0.19, accuracy: 1e-6)
            XCTAssertEqual(n.front, .occupied)
            XCTAssertTrue(n.hazards.contains { $0.kind == .steps && $0.box.valid })
        }
    }

    func testRealRTROverlappingPlanesRequireLowerReturns() throws {
        let loop = GroundAssessment(), frame = try recorded(.overheadSign), points = features
        for i in 0...3 {
            let n = loop.inspect(image: frame, pose: pose(i), planes: [floor, landing], features: points, observations: [], personOK: true)
            XCTAssertEqual(front(n).stepEvidence, .conflictingPlanes)
            XCTAssertEqual(n.front, .unknown)
            XCTAssertTrue(n.hazards.isEmpty)
        }
        let lowerReturns = [V3(-0.10,-0.19,-1.1), V3(0.10,-0.19,-1.1)]
        let observed = loop.inspect(image: frame, pose: pose(4), planes: [floor, landing], features: points + lowerReturns, observations: [], personOK: true)
        XCTAssertTrue(front(observed).hasMeasuredDrop)
        XCTAssertEqual(observed.front, .occupied)
        let noApproach = loop.inspect(image: frame, pose: pose(5), planes: [landing], features: points, observations: [], personOK: true)
        XCTAssertEqual(noApproach.front, .unknown)
        XCTAssertFalse(front(noApproach).hasMeasuredDrop)
    }

    /// Numerical raycast through the production projection. A level callback describes the
    /// surface hit, in metres. The recording only supplies brightness.
    private func range(_ p: FramePose, at sensor: (Double, Double), level: (V3) -> Double?) -> Double? {
        let uv = p.upright(sensor.0, sensor.1), ray = p.ray(uv.0, uv.1)
        guard ray.y < -0.01 else { return nil }
        let flatHit = p.position + ray * (-p.position.y / ray.y)
        guard let y = level(flatHit) else { return nil }
        return (y - p.position.y) / ray.y * ray.dot(p.forward)
    }

    func testRealRTRDepthDiscontinuityNeedsUpperAndAdjacentLowerReturns() throws {
        let p = pose(1), frame = try recorded(.lectureTheatre)
        func run(_ level: @escaping (V3) -> Double?) -> NearField {
            GroundAssessment().inspect(image: frame, pose: p, planes: [floor], features: [], observations: [], personOK: true,
                                       depth: { self.range(p, at: $0, level: level) })
        }
        for weak in [run { abs($0.z + 1.1) < 0.1 && abs($0.x) < 0.1 ? -0.19 : 0 },
                     run { _ in -0.19 }, run { $0.z < -1 ? nil : 0 }] {
            XCTAssertEqual(weak.front, .unknown)
            XCTAssertFalse(front(weak).hasMeasuredDrop)
        }
        let descent = run { $0.z < -1 ? -0.19 : 0 }
        XCTAssertEqual(descent.front, .occupied)
        XCTAssertTrue(front(descent).hasMeasuredDrop)
    }

    func testRealRTRSignGlanceAndStationaryJitterUseAmbientCue() throws {
        let loop = GroundAssessment(), sign = try recorded(.overheadSign), theatre = try recorded(.lectureTheatre)
        var nav = SpatialNavigator(doorTarget: false)
        for i in 0..<12 {
            let p = pose(i, yaw: Double(i % 3 - 1) * 3, pitch: i < 6 ? 2 : 32, x: i.isMultiple(of: 2) ? 0.02 : -0.02)
            nav.pose(p)
            let n = loop.inspect(image: i < 6 ? sign : theatre, pose: p, planes: [floor], features: i < 6 ? features : [], observations: [], personOK: true)
            nav.risk(n)
            XCTAssertEqual(n.front, .unknown)
            XCTAssertFalse(nav.emergency)
            XCTAssertEqual(nav.cue(), .lookAround)
            XCTAssertEqual(nav.cueForSafety, .lookAround)
        }
    }

    func testRealRTRPixelsThroughGridToBypassAndBodyConfirmation() throws {
        let loop = GroundAssessment(), theatre = try recorded(.lectureTheatre), sign = try recorded(.overheadSign)
        let points = features
        var nav = SpatialNavigator(doorTarget: true), grid = LocalGrid()
        func feed(_ i: Int, yaw: Double, geometry: [FloorPatch], returns: [V3]) -> LocalCue? {
            let p = pose(i, yaw: yaw)
            nav.pose(p)
            let n = loop.inspect(image: i < 14 ? theatre : sign, pose: p, planes: geometry, features: returns, observations: [], personOK: true,
                                 depth: yaw == 90 ? { self.range(p, at: $0, level: { q in self.lip.contains(q) ? 0 : nil }) } : nil)
            nav.risk(grid.reconcile(n))
            return nav.cue()
        }
        for i in 0..<7 { _ = feed(i, yaw: 0, geometry: [floor], returns: points) }
        nav.faceForward()
        XCTAssertEqual(nav.cue()?.kind, .advance)
        XCTAssertEqual(feed(7, yaw: 0, geometry: [lip, landing], returns: []), .dropStop)
        nav.recheck()
        for i in 8..<14 {
            XCTAssertEqual(feed(i, yaw: 4, geometry: [], returns: []), .dropStop)
            XCTAssertFalse(nav.hasFrontProof)
        }
        for i in 14..<22 {
            let cue = feed(i, yaw: 90, geometry: [lip, landing], returns: [])
            XCTAssertNotEqual(cue?.kind, .advance)
            if i < 17 { XCTAssertFalse(nav.hasFrontProof) }
        }
        XCTAssertTrue(nav.hasFrontProof)
        XCTAssertNil(nav.frontHazard)
        XCTAssertEqual(nav.cue()?.kind, .face)
        nav.faceForward()
        XCTAssertEqual(nav.cue()?.kind, .advance)
        XCTAssertEqual(feed(22, yaw: 0, geometry: [], returns: []), .dropStop)
        XCTAssertFalse(nav.canAdvance)
    }
}
