import XCTest
@testable import PathSenseCore

final class CueDeliveryTests: XCTestCase {
    func testStationaryViewChangesDoNotTalkOverSignOrAlternateStopPrompts() {
        var channel = CueDelivery()
        let pan = LocalCue(kind: .scan, text: "转动手机看看四周。")
        XCTAssertTrue(channel.take(pan, at: 1))
        XCTAssertTrue(channel.take(.init(kind: .route, text: "前方是402门牌。"), at: 1.2))
        for i in 0..<30 {
            let cue = i.isMultiple(of: 2) ? pan : .init(kind: .wait, text: "正在观察。")
            XCTAssertFalse(channel.take(cue, at: 1.3 + Double(i) * 0.1))
        }
        XCTAssertTrue(channel.take(.init(kind: .stop, text: "先停一下。"), at: 4.5, cause: "person"))
    }
    func testLossOfWalkingEvidencePreemptsSignAndFreshPersonPreemptsRecheck() {
        var channel = CueDelivery()
        XCTAssertTrue(channel.take(.init(kind: .advance, text: "慢行一小段。"), at: 1))
        XCTAssertTrue(channel.take(.init(kind: .route, text: "左侧有电梯图标。"), at: 1.2))
        XCTAssertTrue(channel.forwardOutstanding)
        XCTAssertTrue(channel.take(.init(kind: .wait, text: "先停一下，通道还没看清。"), at: 1.3, revoke: true))
        XCTAssertFalse(channel.forwardOutstanding)
        let stop = LocalCue(kind: .stop, text: "先停一下。")
        XCTAssertTrue(channel.take(stop, at: 1.4, cause: "person"))
        channel.sampled(at: 1.55, dangerPresent: false, frontProven: false)
        channel.sampled(at: 1.7, dangerPresent: true, frontProven: false)
        XCTAssertFalse(channel.take(stop, at: 1.7, cause: "person"))
        channel.sampled(at: 2.5, dangerPresent: false, frontProven: true)
        XCTAssertTrue(channel.take(stop, at: 2.55, cause: "person"))
    }
    func testEndOfSweepSurvivesAmbientCooldownAndDangerLabelsDoNotRepeatStop() {
        var channel = CueDelivery()
        XCTAssertTrue(channel.take(.lookAround, at: 1))
        XCTAssertTrue(channel.take(.noConfirmedAisle, at: 2))
        XCTAssertTrue(channel.take(.obstacleStop, at: 2.1, cause: "person"))
        XCTAssertFalse(channel.take(.obstacleStop, at: 2.2, cause: "obstacle"))
        XCTAssertTrue(channel.take(.dropStop, at: 2.3, cause: "drop"))
        XCTAssertFalse(channel.take(.obstacleStop, at: 2.4, cause: "person"))
    }

    func testDirectionalAvoidanceInterruptsReadoutAndJitterDoesNotRearmSameDrop() {
        var channel = CueDelivery()
        let side = LocalCue(kind: .turn, text: "请原地向左转约30度。", isAvoidanceTurn: true)
        XCTAssertTrue(channel.take(.init(kind: .route, text: "右边有门牌。"), at: 0))
        XCTAssertTrue(channel.take(side, at: 0.2))
        XCTAssertFalse(channel.take(.init(kind: .route, text: "左边有标识。"), at: 0.3))
        XCTAssertTrue(channel.take(.dropStop, at: 0.4, cause: "drop"))
        XCTAssertTrue(channel.take(side, at: 2))
        XCTAssertFalse(channel.take(.dropStop, at: 2.1, cause: "drop"))
        XCTAssertTrue(channel.take(.obstacleStop, at: 2.2, cause: "person"))
    }

    func testPostedRestrictionTracksTheObservedSignAndRequiresDistinctCaptures() throws {
        let world = UUID()
        func pose(_ frame: Int, _ t: Double, yaw: Double = 0, x: Double = 0, version: Int = 1) -> FramePose {
            let a = yaw * .pi / 180, c = cos(a), s = sin(a)
            return FramePose(id: .init(session: world, world: version, frame: frame), time: t,
                transform: [c,0,s,0, 0,1,0,0, -s,0,c,0, x,1.4,0,1],
                intrinsics: [550,0,0,0,550,0,500,400,1], width: 1000, height: 800, exif: 1, tracking: "normal")
        }
        let notice = Sighting(kind: .sign, box: ImageBox(0.46,0.35,0.54,0.42), confidence: 0.9, label: "Staff Only")
        var book = LandmarkBook(), notices = AccessNotices()
        let a = pose(1, 1), b = pose(2, 1.6)
        let id = try XCTUnwrap(book.observe(notice, at: a))
        notices.observe(a, signs: [(notice, id)], printedRestriction: true)
        notices.observe(a, signs: [(notice, id)], printedRestriction: true)
        XCTAssertFalse(notices.blocks(a, in: book))
        XCTAssertEqual(book.observe(notice, at: b), id)
        notices.observe(b, signs: [(notice, id)], printedRestriction: true)
        XCTAssertTrue(notices.blocks(b, in: book))
        XCTAssertFalse(notices.blocks(pose(3, 4, yaw: 70), in: book))
        XCTAssertTrue(notices.blocks(pose(4, 9), in: book))
        XCTAssertFalse(notices.blocks(pose(5, 10, x: 2), in: book))
        XCTAssertFalse(notices.blocks(pose(6, 11, version: 2), in: book))
        var noBox = AccessNotices()
        noBox.observe(a, signs: [], printedRestriction: true)
        noBox.observe(b, signs: [], printedRestriction: true)
        XCTAssertTrue(noBox.blocks(b, in: book))
        XCTAssertFalse(noBox.blocks(pose(7, 8), in: book))
    }

    func testSamePrintedFactsVoteAcrossDoorBoxJitterButDifferentArrowsDoNot() {
        var a = WayfindingSigns(nearbyRoom: "BSG33")
        a.scene = .init(setting:.room, door:"左侧", doorBoxes:[CGRect(x:0.2,y:0.1,width:0.2,height:0.5)])
        var b = a
        b.scene.doorBoxes[0].origin.x += 0.015
        b.scene.setting = nil
        var gate = RouteEvidenceGate(now:0)
        XCTAssertFalse(gate.accept(a, at:1))
        XCTAssertTrue(gate.accept(b, at:1.5))
        XCTAssertFalse(gate.accept(a, at:2))
        b.onward = .left
        XCTAssertFalse(gate.accept(b, at:2.5))
        b.onward = .right
        XCTAssertFalse(gate.accept(b, at:3))
        XCTAssertTrue(gate.accept(b, at:3.5))
    }

}
