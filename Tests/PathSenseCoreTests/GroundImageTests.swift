import XCTest
@testable import PathSenseCore

final class GroundImageTests: XCTestCase {
    private let world = UUID()
    private var floor: FloorPatch { FloorPatch(y: 0, polygon: [V3(-2,0,1), V3(2,0,1), V3(2,0,-3), V3(-2,0,-3)]) }
    private var features: [V3] {
        (-8...8).flatMap { x in (0...12).map { z in V3(Double(x)/5, 0, -Double(z)/5) } }
    }
    private func image(_ value: (Int,Int) -> UInt8) -> FloorImage {
        FloorImage(pixels: (0..<(96*96)).map { value($0 % 96, $0 / 96) })
    }
    private func pose(_ i: Int) -> FramePose {
        let a = 36 * Double.pi / 180, c = cos(a), s = sin(a)
        return .init(id: .init(session: world, world: 1, frame: i), time: Double(i)/10,
                     transform: [1,0,0,0, 0,c,-s,0, 0,s,c,0, 0,1.3,0,1], intrinsics: [540,0,0,0,540,0,500,400,1],width: 1000,height: 800,exif: 1, tracking:"normal")
    }
    private var textured: FloorImage { image { x,y in UInt8(65 + ((x*11 + y*7) % 112)) } }
    func testMeasuredPlaneAloneDoesNotOpenAisle() {
        let loop = GroundAssessment(), frame = textured
        for i in 0...3 {
            let r = loop.inspect(image:frame,pose:pose(i),planes:[floor],features:[],observations:[],personOK:true)
            XCTAssertTrue(r.visible); XCTAssertEqual(r.front,.unknown)
        }
    }
    func testCurrentFloorImageAndBodyWidthEvidenceAndAbruptChange() {
        let loop = GroundAssessment(), frame = textured
        _ = loop.inspect(image:frame,pose:pose(0),planes:[floor],features:features,observations:[],personOK:true)
        let clear = loop.inspect(image:frame,pose:pose(1),planes:[floor],features:features,observations:[],personOK:true)
        XCTAssertEqual(clear.front,.free)
        let changed = image { x,y in UInt8(170 + (x*5+y*2)%80) }
        let obstructed = loop.inspect(image:changed,pose:pose(2),planes:[floor],features:features,observations:[],personOK:true)
        XCTAssertEqual(obstructed.front,.occupied)
        let hidden = loop.inspect(image:image { _,_ in 5 },pose:pose(3),planes:[floor],features:features,observations:[],personOK:true)
        XCTAssertFalse(hidden.visible); XCTAssertEqual(hidden.front,.unknown)
    }
    func testLowObjectAndLowerLandingUseObservedGeometry() {
        let loop = GroundAssessment()
        let object = loop.inspect(image:textured,pose:pose(0),planes:[floor],features:features+[V3(0,0.13,-1.2)],observations:[],personOK:true)
        XCTAssertEqual(object.front,.occupied); XCTAssertEqual(object.sectors.first(where:{$0.angle == 0})?.nearest,1.2)
        let lower = FloorPatch(y:-0.19,polygon:[V3(-1,-0.19,-1),V3(1,-0.19,-1),V3(1,-0.19,-2),V3(-1,-0.19,-2)])
        let drop = loop.inspect(image:textured,pose:pose(1),planes:[floor,lower],features:features,observations:[],personOK:true)
        XCTAssertTrue(drop.hazards.contains(where:{$0.kind == .steps})); XCTAssertEqual(drop.front,.occupied)
    }
    func testFlatHighContrastStripesAreARecordedFalsePositive() {
        let flatStripes = image { _,y in (y / 7).isMultiple(of: 2) ? 42 : 176 }
        XCTAssertTrue(flatStripes.visible); XCTAssertTrue(flatStripes.possibleStep)
        let r=GroundAssessment().inspect(image:flatStripes,pose:pose(1),planes:[floor],features:features,observations:[],personOK:true)
        XCTAssertTrue(r.hazards.contains(where:{$0.kind == .steps})); XCTAssertEqual(r.front,.occupied)
    }
}
