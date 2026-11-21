import XCTest
@testable import PathSenseCore

/// Deterministic optical geometry. These are evidence-level replays, not timing measurements of a phone.
final class SpatialReplayTests: XCTestCase {
    let session=UUID()
    func pose(_ index:Int,_ yaw:Double=0,x:Double=0,z:Double=0,world:Int=1) -> FramePose {
        let theta=yaw*Double.pi/180, c=cos(theta), s=sin(theta)
        return .init(id:.init(session:session,world:world,frame:index),time:Double(index)/10,
                     transform:[c,0,s,0, 0,1,0,0, -s,0,c,0, x,1.4,z,1],intrinsics:[550,0,0,0,550,0,500,400,1],width:1000,height:800,exif:1,tracking:"normal")
    }
    func object(_ p:FramePose,_ target:V3,as kind:FeatureKind = .door,height:Double=0.53,tag:UInt64?=nil) -> Sighting {
        let uv=p.project(target)!
        return .init(kind:kind,box:.init(uv.0-0.035,uv.1-height/2,uv.0+0.035,uv.1+height/2),confidence:0.9,appearance:tag)
    }
    func near(_ p:FramePose,_ front:CellState = .free,side:Int?=nil,person:Bool=false,drop:V3?=nil) -> NearField {
        var bins=stride(from:-60,through:60,by:15).map { Sector(angle:$0,state:$0==0 ? front:($0==side ? .free:.unknown)) }
        if let drop, let i = bins.firstIndex(where: { $0.angle == 0 }) {
            bins[i].state = .occupied
            bins[i].nearest = p.position.groundDistance(drop)
            bins[i].stepEvidence = .measuredDrop(drop)
        }
        let hz: [Sighting] = person ? [.init(kind:.person,box:.init(0.36,0.3,0.7,0.9),confidence:0.92)] : []
        return .init(pose:p,visible:true,sectors:bins,hazards:hz)
    }
    func testProjectionAcrossExifAndAngleWrap() {
        XCTAssertEqual(turnAngle(1-359),2); XCTAssertEqual(turnAngle(359-1),-2)
        for orientation in [1,3,6,8] {
            var p=pose(1,22,x:2,z:0.4); p.exif=orientation
            let (u,v)=p.project(p.position+p.ray(0.23,0.73)*3)!
            XCTAssertEqual(u,0.23,accuracy:0.00001); XCTAssertEqual(v,0.73,accuracy:0.00001)
        }
    }
    func testRightThirtyThenRightSixtyBecomesLeftThirtyAndTwoMetresNeedsEvidence() throws {
        let a=pose(0), target=V3(3*tan(.pi/6),1.4,-3)
        var book=LandmarkBook(); _=book.observe(object(a,target),at:a)
        let landmark=try XCTUnwrap(book.records.first)
        XCTAssertNil(landmark.point); XCTAssertEqual(try XCTUnwrap(landmark.bearing(at:a)),30,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(landmark.bearing(at:pose(4,60))),-30,accuracy:0.01)
        XCTAssertNil(landmark.bearing(at:pose(5,60,x:2)))
    }
    func testTwoDoorsRemainDistinctAfterParallaxDetourAndReacquisition() throws {
        var nav=SpatialNavigator(doorTarget:true); let a=V3(-0.58,1.4,-3), b=V3(0.68,1.4,-3)
        for i in 0...4 {
            let p=pose(i,x:Double(i)*0.15); nav.pose(p);nav.risk(near(p,.free,side:-15))
            _=nav.register([object(p,a,tag:0xFFFF0000FFFF0000),object(p,b,tag:0x1111EEEE1111EEEE)],at:p,local:true)
        }
        let locked=try XCTUnwrap(nav.door); XCTAssertEqual(nav.book.records.count,2)
        let point=try XCTUnwrap(nav.record(locked)?.point); XCTAssertLessThan((point-a).length,0.02)
        let away=pose(8,120,x:2); nav.pose(away)
        let expected=turnAngle((a-away.position).heading-away.heading)
        XCTAssertEqual(try XCTUnwrap(nav.record(locked)?.bearing(at:away)),expected,accuracy:0.1)
        let back=pose(13,-30,x:1.7,z:-0.3); nav.pose(back)
        let id=nav.register([object(back,b,tag:0x1111EEEE1111EEEE),object(back,a,tag:0xFFFF0000FFFF0000)],at:back,local:true)
        XCTAssertEqual(id.last!,locked); XCTAssertNotEqual(id[0],locked)
    }
    func testStationCoverageDoesNotRepeatAndHiddenFramesAreNotSeen() {
        var scan=ScanCoverage()
        for i in 0..<25 {scan.update(pose(i,Double(i*15)),visible:i != 8,aisle:false)}
        XCTAssertTrue(scan.exhausted); scan.update(pose(26),visible:true,aisle:false); XCTAssertTrue(scan.exhausted)
        scan.update(pose(27),visible:true,aisle:true); XCTAssertTrue(scan.hasAisle); XCTAssertFalse(scan.exhausted)
        scan.update(pose(28,x:1),visible:false,aisle:false); XCTAssertFalse(scan.exhausted); XCTAssertTrue(scan.seen.isEmpty)
        for i in 0..<24 { scan.update(pose(30+i,Double(i*15),x:1),visible:false,aisle:false) }
        XCTAssertTrue(scan.exhausted); XCTAssertTrue(scan.seen.isEmpty); scan.retry(); XCTAssertTrue(scan.attempted.isEmpty)
    }
    func testCompletedSweepReportsOnceAndStaysQuietThroughJitterAndMissingEvidence() {
        var nav = SpatialNavigator(doorTarget: true)
        var notices = 0
        for i in 0..<48 {
            let p = pose(i, Double(i % 24) * 15)
            nav.pose(p)
            nav.risk(near(p, .unknown))
            let cue = nav.cue(forwardOutstanding: false)
            if cue == .noConfirmedAisle { notices += 1 }
            if notices > 0 {
                XCTAssertTrue(cue == nil || cue == .noConfirmedAisle)
                XCTAssertNil(nav.safetyCue(forwardOutstanding: false))
            } else { XCTAssertEqual(cue, .lookAround) }
        }
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(LocalCue.noConfirmedAisle.kind, .wait)
        XCTAssertEqual(LocalCue.noConfirmedAisle.text, "暂时没找到可以确认的过道，请先站定。")
        nav.nearLost()
        XCTAssertNil(nav.cue())
        // Seeing a single plausible strip must not restart a completed sweep.
        let flash = pose(48)
        nav.pose(flash); nav.risk(near(flash)); XCTAssertNil(nav.cue())
        XCTAssertEqual(nav.cue(forwardOutstanding: true), .revokeAdvance)
        let person = pose(49)
        nav.pose(person); nav.risk(near(person, .unknown, person: true))
        XCTAssertEqual(nav.frontHazard, .person)
        XCTAssertEqual(nav.cue(), .obstacleStop)
        let empty = pose(50)
        nav.pose(empty); nav.risk(near(empty, .unknown)); XCTAssertNil(nav.cue())
        for i in 51...60 {
            let p = pose(i)
            nav.pose(p); nav.risk(near(p)); XCTAssertNotEqual(nav.cue()?.kind, .advance)
        }
        XCTAssertEqual(nav.cue()?.kind, .face)
        nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance)
        nav.recheck()
        XCTAssertEqual(nav.cue(forwardOutstanding: false), .lookAround)
    }

    func testStationNoticeSurvivesDoorLockAndRearmsOnNewStationOrExplicitRetry() {
        var nav = SpatialNavigator(doorTarget: true)
        var sequence = 0
        func sweep(at x: Double, consume: Bool = true) -> [LocalCue] {
            var cues: [LocalCue] = []
            for heading in 0..<24 {
                let p = pose(sequence, Double(heading) * 15, x: x)
                sequence += 1
                nav.pose(p); nav.risk(near(p, .unknown))
                if consume, let cue = nav.cue() { cues.append(cue) }
            }
            return cues
        }
        _ = sweep(at: 0, consume: false)
        XCTAssertTrue(nav.scan.exhausted)
        // The first local door lock refreshes angular samples. Keep the outstanding notice
        // across this update and the next frame, then announce the distant door exactly once.
        let door = V3(0, 1.4, -4)
        for _ in 0..<3 {
            let p = pose(sequence)
            sequence += 1
            nav.pose(p); nav.risk(near(p, .unknown))
            _ = nav.register([object(p, door, tag: 42)], at: p, local: true)
        }
        XCTAssertEqual(nav.cue(), .noConfirmedAisle)
        let found = LocalCue(kind: .found, text: "找到门了。")
        XCTAssertEqual(nav.cue(), found)
        nav.didDeliver(found)
        XCTAssertNil(nav.cue())
        XCTAssertTrue(sweep(at: 0.04).isEmpty)
        let relocated = sweep(at: 0.70)
        XCTAssertEqual(relocated.first, .lookAround)
        XCTAssertEqual(relocated.filter { $0 == .noConfirmedAisle }.count, 1)
        XCTAssertTrue(sweep(at: 0.73).isEmpty)
        nav.recheck()
        let retried = sweep(at: 0.70)
        XCTAssertEqual(retried.first, .lookAround)
        XCTAssertEqual(retried.filter { $0 == .noConfirmedAisle }.count, 1)
        XCTAssertTrue(sweep(at: 0.69).isEmpty)
    }

    func testPersonAcrossACompletedSweepAndTwoFrameGapRequiresFreshRecheck() {
        var nav = SpatialNavigator(doorTarget: true)
        var completionCount = 0
        for i in 0..<24 {
            let p = pose(i, Double(i) * 15)
            nav.pose(p); nav.risk(near(p, .unknown))
            if nav.cue() == .noConfirmedAisle { completionCount += 1 }
        }
        XCTAssertEqual(completionCount, 1)

        // Eight occupied frames, two apparently clear frames, then the person reappears.
        // Supply a free ground measurement and a route on the occupied frames to exercise priority.
        for i in 24..<40 {
            let p = pose(i)
            let person = i < 32 || i >= 34
            nav.pose(p); nav.risk(near(p, .free, person: person))
            nav.cloudHold = person ? .init(kind: .route, text: "路线提示") : nil
            nav.cloudHoldUntil = 10
            XCTAssertFalse(nav.hasFrontProof)
            XCTAssertFalse(nav.canAdvance)
            if person {
                XCTAssertEqual(nav.frontHazard, .person)
                XCTAssertEqual(nav.cue(), .obstacleStop)
            } else {
                XCTAssertNil(nav.frontHazard)
                XCTAssertNil(nav.cue())
            }
        }
        nav.cloudHold = nil
        for i in 40...49 {
            let p = pose(i)
            nav.pose(p); nav.risk(near(p, .free))
            XCTAssertEqual(nav.hasFrontProof, i >= 42)
            let cue = nav.cue()
            XCTAssertNotEqual(cue, .noConfirmedAisle)
            XCTAssertNotEqual(cue?.kind, .advance)
        }
        XCTAssertEqual(nav.cue()?.kind, .face)
        nav.faceForward()
        XCTAssertEqual(nav.cue()?.kind, .advance)
    }

    func testDistantDoorAnnouncementAndDoorFrameRecheckWording() throws {
        var nav = SpatialNavigator(doorTarget: true)
        let goal = V3(0, 1.4, -4)
        for i in 0...1 {
            let p = pose(i)
            nav.pose(p); nav.risk(near(p))
            _ = nav.register([object(p, goal, tag: 42)], at: p, local: true)
        }
        let door = try XCTUnwrap(nav.record(nav.door))
        let found = try XCTUnwrap(nav.cue())
        XCTAssertEqual(found, LocalCue(kind: .found, text: "找到门了。"))
        nav.didDeliver(found)
        XCTAssertFalse(nav.arrived)
        let moved = pose(2, x: 0.55)
        nav.pose(moved); nav.risk(near(moved))
        XCTAssertNil(door.bearing(at: moved))
        XCTAssertEqual(nav.cue(), LocalCue(kind: .scan, text: "请把镜头转向门框。"))
        XCTAssertFalse(nav.canAdvance)
    }

    func testDoorCanBeSeenAboveTheUnobservedFloor() throws {
        var nav = SpatialNavigator(doorTarget: true)
        let door = V3(0, 1.4, -4)
        for frame in 0...1 {
            let p = pose(frame)
            nav.pose(p); _ = nav.register([object(p, door, tag: 42)], at: p, local: true)
        }
        XCTAssertEqual(nav.cue()?.kind, .found)
        nav.pose(pose(2, 85))
        XCTAssertNotEqual(nav.cue()?.kind, .found)
        XCTAssertFalse(nav.arrived); XCTAssertFalse(nav.canAdvance)
    }

    func testDoorNoticeSurvivesOngoingSideTurnAndYieldsToNewPerson() throws {
        var nav = SpatialNavigator(doorTarget: true), delivery = CueDelivery()
        let goal = V3(0, 1.4, -4)
        var accepted: [LocalCue] = []
        for frame in 0..<30 {
            let p = pose(frame)
            nav.pose(p); nav.risk(near(p, .unknown, side: -30))
            _ = nav.register([object(p, goal, tag: 42)], at: p, local: true)
            let cue = try XCTUnwrap(nav.cue(forwardOutstanding: delivery.forwardOutstanding))
            if delivery.take(cue, at: p.time) { nav.didDeliver(cue); accepted.append(cue) }
        }
        XCTAssertEqual(accepted.map(\.kind), [.turn, .found])
        XCTAssertFalse(nav.arrived)
        let person = pose(30)
        nav.pose(person); nav.risk(near(person, .unknown, person: true))
        let stop = try XCTUnwrap(nav.cue())
        XCTAssertEqual(stop, .obstacleStop); XCTAssertTrue(delivery.take(stop, at: person.time, cause: "person"))
    }

    func testPersonInterruptsAPermittedStationaryBypassEvenWithUnknownFloor() {
        var nav = SpatialNavigator(doorTarget: true)
        let lip = V3(0, -0.19, -1.1)
        for i in 0...16 {
            let p = pose(i)
            nav.pose(p); nav.risk(near(p, .unknown, side: 45, drop: lip))
            if i == 0 { XCTAssertEqual(nav.cue(), .dropStop) }
        }
        XCTAssertEqual(nav.cue()?.kind, .turn)
        XCTAssertNil(nav.safetyCue(forwardOutstanding: false))
        let p = pose(17)
        nav.pose(p); nav.risk(near(p, .unknown, side: 45, person: true))
        XCTAssertEqual(nav.frontHazard, .person)
        XCTAssertEqual(nav.cue(), .obstacleStop)
        XCTAssertEqual(nav.safetyCue(forwardOutstanding: false), .obstacleStop)
        XCTAssertFalse(nav.canAdvance)
        let empty = pose(18)
        nav.pose(empty); nav.risk(near(empty, .unknown, side: 45))
        XCTAssertEqual(nav.cue(), .dropStop)
    }

    func testAlignmentHasDwellAndHysteresis() {
        var a=Alignment(); XCTAssertFalse(a.sample(error:7,time:0)); XCTAssertTrue(a.sample(error:3,time:0.4))
        for i in 0..<10 { XCTAssertFalse(a.sample(error:i%2==0 ? 9:4,time:0.6+Double(i)*0.1)) }
        XCTAssertFalse(a.sample(error:18,time:2)); XCTAssertFalse(a.sample(error:2,time:2.1)); XCTAssertTrue(a.sample(error:2,time:2.5))
    }
    func testNewPersonPreemptsForwardAndClearanceRequiresFreshFramesAndBody() {
        var nav=SpatialNavigator(doorTarget:true)
        for i in 1...6 { let p=pose(i); nav.pose(p); nav.risk(near(p)); _=nav.cue() }
        nav.faceForward(); XCTAssertEqual(nav.cue()?.kind,.advance)
        let old=DecisionTicket(pose:pose(6),generation:nav.generation,destination:"教室门口")
        let p=pose(7); nav.pose(p); nav.risk(near(p,.occupied,side:-30,person:true)); XCTAssertEqual(nav.cue()?.kind,.stop)
        XCTAssertFalse(old.current(at:p,generation:nav.generation,destination:"教室门口"))
        let u=pose(8);nav.pose(u);nav.risk(near(u,.unknown));XCTAssertNotEqual(nav.cue()?.kind,.advance)
        for i in 9...14 { let p=pose(i); nav.pose(p);nav.risk(near(p));_=nav.cue() }
        XCTAssertEqual(nav.cue()?.kind,.face);nav.faceForward(); XCTAssertEqual(nav.cue()?.kind,.advance)
        let interrupted=pose(20);nav.pose(interrupted); XCTAssertFalse(nav.hasFrontProof);XCTAssertEqual(nav.cue()?.kind,.wait)
    }
    func testStaticChairAllowsOnlyVerifiedStationaryTurnAndNewDropStopsImmediately() {
        for side in [-30,30] {
            var nav = SpatialNavigator(doorTarget: true)
            for i in 1...16 {
                let p = pose(i)
                nav.pose(p); nav.risk(near(p, .occupied, side: side))
                if i == 1 { XCTAssertEqual(nav.cue(), .obstacleStop) }
            }
            let pivot = nav.cue()
            XCTAssertEqual(pivot?.kind, .turn); XCTAssertTrue(pivot?.text.contains("原地") == true)
            XCTAssertTrue(pivot?.text.contains(side < 0 ? "左" : "右") == true)
            let next = pose(17)
            nav.pose(next); nav.risk(near(next, side: side, drop: V3(0,-0.18,-1.1)))
            XCTAssertEqual(nav.cue(), .dropStop); XCTAssertEqual(nav.frontHazard, .drop)
        }
    }

    func testDropMemoryIsLocalAndNeedsFreshSideProofEvenAfterRetry() {
        for side in [-45, 45] {
            var nav = SpatialNavigator(doorTarget: true)
            let hazard = V3(0, -0.19, -1.1), p = pose(1)
            nav.pose(p); nav.risk(near(p, drop: hazard)); XCTAssertEqual(nav.cue(), .dropStop)
            nav.recheck()
            // A timeout and one-frame flashes to alternate sides cannot clear the original strip.
            for i in 30..<40 {
                let p = pose(i); nav.pose(p); nav.risk(near(p, .free, side: i.isMultiple(of: 2) ? side : -side))
                XCTAssertEqual(nav.cue(forwardOutstanding: false), .dropStop); XCTAssertFalse(nav.canAdvance)
            }
            for i in 40...42 {
                let p = pose(i); nav.pose(p); nav.risk(near(p, .unknown, side: side))
            }
            let pivot = nav.cue()
            XCTAssertEqual(pivot?.kind, .turn); XCTAssertTrue(pivot?.text.contains("原地") == true)
            XCTAssertTrue(pivot?.text.contains(side < 0 ? "左" : "右") == true)
            let rotated = pose(43, Double(side)); nav.pose(rotated)
            XCTAssertEqual(nav.cue(), .lookAround); XCTAssertFalse(nav.hasFrontProof)
            for i in 44...52 {
                let p = pose(i, Double(side)); nav.pose(p); nav.risk(near(p))
                XCTAssertNotEqual(nav.cue()?.kind, .advance)
                if i < 46 { XCTAssertFalse(nav.hasFrontProof) }
            }
            XCTAssertEqual(nav.cue()?.kind, .face)
            nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance)
            let back = pose(53, -4); nav.pose(back)
            XCTAssertEqual(nav.cue(), .dropStop)
            let reset = pose(54, world: 2); nav.pose(reset)
            XCTAssertFalse(nav.emergency); XCTAssertFalse(nav.hasFrontProof); XCTAssertEqual(nav.cue(), .lookAround)
        }
    }

    func testClearanceNeedsDistinctCapturesInOneFreshWindow() {
        var nav = SpatialNavigator(doorTarget: true)
        for i in 0...5 {
            var duplicate = pose(i)
            duplicate.id.frame = 0
            nav.pose(duplicate); nav.risk(near(duplicate))
            XCTAssertFalse(nav.hasFrontProof)
        }
        for i in [10, 14, 18] {
            let p = pose(i)
            nav.pose(p); nav.risk(near(p))
            XCTAssertFalse(nav.hasFrontProof)
        }
        let fresh = pose(19)
        nav.pose(fresh); nav.risk(near(fresh))
        XCTAssertTrue(nav.hasFrontProof)
        XCTAssertFalse(nav.canAdvance)
    }

    func testActualAdvanceRevokesOnTheFirstUncertainSampleAndCannotResumeWithOldBody() {
        for cause in ["unknown", "camera tilt", "pose stale", "tracking", "camera loss", "world"] {
            var nav = SpatialNavigator(doorTarget: true)
            for i in 0..<7 {
                let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue()
            }
            nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance)
            var p = pose(cause == "pose stale" ? 15 : 7, world: cause == "world" ? 2 : 1)
            if cause == "camera tilt" {
                let a = 30.0 * .pi / 180
                p.transform[5] = cos(a); p.transform[6] = -sin(a); p.transform[9] = sin(a); p.transform[10] = cos(a)
            } else if cause == "tracking" { p.tracking = "limited" }
            nav.pose(p)
            if cause == "unknown" { nav.risk(near(p,.unknown)) }
            if cause == "camera loss" { nav.nearLost() }
            nav.cloudHold = .init(kind: .route, text: "原路线提示"); nav.cloudHoldUntil = 10
            XCTAssertEqual(nav.safetyCue(forwardOutstanding: true), .revokeAdvance, cause)
            XCTAssertEqual(nav.cue(), .revokeAdvance, cause)
            XCTAssertEqual(nav.cue(), .lookAround, cause)
            XCTAssertFalse(nav.canAdvance, cause)
            nav.cloudHold = nil
            for i in 20...28 {
                let next = pose(i, world: p.id.world); nav.pose(next); nav.risk(near(next))
                XCTAssertNotEqual(nav.cue()?.kind, .advance, cause)
            }
            XCTAssertEqual(nav.cue()?.kind, .face, cause)
            nav.faceForward(); XCTAssertTrue(nav.canAdvance, cause)
        }
    }

    func testUndeliveredAdvanceAndReplayedClassificationKeepObservationAmbient() {
        var nav = SpatialNavigator(doorTarget: true)
        for i in 0..<7 { let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue() }
        nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance)
        for i in 7...11 {
            let p = pose(i); nav.pose(p)
            var field = near(p)
            field.hazards = [.init(kind: .steps, box: .init(0.34,0.34,0.67,0.92), confidence: 0.99, label: "stairway")]
            nav.risk(field)
            XCTAssertFalse(nav.emergency); XCTAssertFalse(nav.hasFrontProof)
            XCTAssertEqual(nav.cue(forwardOutstanding: false), .lookAround)
        }
    }

    func testHardStopPrecedesBothPossibleArrivalAndAlreadyLatchedArrival() {
        var nav = SpatialNavigator(doorTarget: true)
        let door = V3(0,1.4,-2.8)
        for i in 0..<7 {
            let p = pose(i, x: Double(i)*0.10)
            nav.pose(p); nav.risk(near(p)); _ = nav.register([object(p,door,tag:3)], at:p,local:true); _ = nav.cue()
        }
        let close = pose(12,-8,x:0.12,z:-1.95)
        nav.pose(close); nav.risk(near(close, .occupied, person: true))
        _ = nav.register([object(close,door,tag:3)], at: close, local: true)
        nav.cloudHold = .init(kind: .route, text: "路线提示"); nav.cloudHoldUntil = 6
        XCTAssertEqual(nav.cue(), .obstacleStop); XCTAssertFalse(nav.arrived); XCTAssertFalse(nav.manualDoorArrival())
        let safe = pose(13,-8,x:0.12,z:-1.95); nav.pose(safe); nav.risk(near(safe))
        XCTAssertEqual(nav.cue()?.kind, .arrived); XCTAssertTrue(nav.arrived)
        let blocked = pose(14,-8,x:0.12,z:-1.95); nav.pose(blocked); nav.risk(near(blocked, drop: V3(0.1,-0.19,-2.75)))
        XCTAssertEqual(nav.cue(), .dropStop); XCTAssertEqual(nav.cueForSafety, .dropStop)
    }
    func testRoomSearchFollowsLocalAisleWhilePlannerIsSilentOrAsksToRescan() {
        var nav = SpatialNavigator(doorTarget: false)
        let advice = LocalCue(kind: .scan, text: "请慢慢转动手机，补扫周围。")
        let ticket = DecisionTicket(pose: pose(0), generation: 0, destination: "402")
        for i in 0...7 {
            let p = pose(i)
            nav.pose(p); nav.risk(near(p, .unknown, side: -30))
            if i == 6 { nav.cloudHold = advice; nav.cloudHoldUntil = p.time + 2 }
            let cue = nav.cue(forwardOutstanding: false)
            XCTAssertEqual(cue?.kind, .turn); XCTAssertTrue(cue?.text.contains("向左转约30度") == true)
        }
        for i in 8...18 {
            let p = pose(i, -30)
            nav.pose(p); nav.risk(near(p)); _ = nav.cue(forwardOutstanding: false)
        }
        XCTAssertEqual(nav.cue()?.kind, .face)
        nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance)
        nav.cloudHold = advice; nav.cloudHoldUntil = 5
        XCTAssertEqual(nav.cue(forwardOutstanding: true)?.kind, .advance)
        XCTAssertNil(nav.waypoint); XCTAssertNil(nav.door)
        let person = pose(19, -30)
        nav.pose(person); nav.risk(near(person, person: true))
        XCTAssertEqual(nav.cue(forwardOutstanding: true), .obstacleStop)
        XCTAssertFalse(ticket.current(at: person, generation: nav.generation, destination: "402"))
    }

    func testDelayedLocalInscriptionCanBeReadFromItsOriginalStationWithoutGrantingPassage() throws {
        var nav = SpatialNavigator(doorTarget: false)
        let capture = pose(0), current = pose(135, 2)
        nav.pose(capture); nav.pose(current)
        let label = Sighting(kind: .sign, box: ImageBox(0.46,0.30,0.57,0.42), confidence: 0.91, label: "BSG33")
        let ids = nav.register([label, object(capture, V3(0,1.4,-3))], at: capture, local: true)
        let sign = try XCTUnwrap(nav.record(ids[0]))
        XCTAssertEqual(sign.last.id, capture.id)
        XCTAssertTrue(sign.signReadout(at: current, target: "BSG33")?.contains("BSG33") == true)
        XCTAssertNil(ids[1]); XCTAssertNil(nav.waypoint); XCTAssertFalse(nav.canAdvance)
    }

    func testMeasuredDistantChairSuggestsSideAtRestButStopsAnOutstandingAdvance() {
        func scenario(moving: Bool) -> LocalCue? {
            var nav = SpatialNavigator(doorTarget: false)
            for i in 0...8 {
                let p = pose(i)
                nav.pose(p); nav.risk(near(p, .free, side: 30)); _ = nav.cue(forwardOutstanding: false)
            }
            if moving { nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance) }
            let p = pose(9); nav.pose(p)
            var field = near(p, .occupied, side: 30)
            let center = field.sectors.firstIndex { $0.angle == 0 }!
            field.sectors[center].nearest = 1.72
            nav.risk(field)
            return nav.cue(forwardOutstanding: moving)
        }
        XCTAssertEqual(scenario(moving: true), .obstacleStop)
        let turn = scenario(moving: false)
        XCTAssertTrue(turn?.isAvoidanceTurn == true); XCTAssertTrue(turn?.text.contains("向右") == true)
    }

    func testLocalAisleDoesNotWalkPastPendingDestinationConfirmation() {
        var nav = SpatialNavigator(doorTarget: false)
        for i in 0...8 {
            let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue(forwardOutstanding: false)
        }
        nav.faceForward(); XCTAssertEqual(nav.cue()?.kind, .advance)
        nav.verifyingRoute = true
        XCTAssertEqual(nav.cue(forwardOutstanding: true), .revokeAdvance)
        XCTAssertNil(nav.cue(forwardOutstanding: false)); XCTAssertFalse(nav.canAdvance)
    }

    func testLateReplyRotationSurvivesButPositionWorldOrTargetCancels() {
        let t=DecisionTicket(pose:pose(0),generation:3,destination:"门口")
        XCTAssertTrue(t.current(at:pose(12,60),generation:3,destination:"门口"))
        XCTAssertFalse(t.current(at:pose(12,x:0.8),generation:3,destination:"门口"))
        XCTAssertFalse(t.current(at:pose(12,world:2),generation:3,destination:"门口"))
        XCTAssertFalse(t.current(at:pose(12),generation:3,destination:"402"));XCTAssertFalse(t.current(at:pose(100),generation:3,destination:"门口"))
        var nav=SpatialNavigator(doorTarget:true);nav.pose(pose(0));_=nav.register([object(pose(0),V3(0,1.4,-3))],at:pose(0),local:true)
        nav.pose(pose(5,world:2));XCTAssertTrue(nav.book.records.isEmpty);XCTAssertNil(nav.door)
        XCTAssertNil(nav.register([object(pose(0),V3(0,1.4,-3))],at:pose(0),local:true)[0])
    }
    func testBlindStartDetourNearSameDoorOnlyThenArrival() throws {
        var nav=SpatialNavigator(doorTarget:true);let goal=V3(0,1.4,-3)
        let away=pose(0,180);nav.pose(away);nav.risk(near(away,.unknown));XCTAssertEqual(nav.cue()?.kind,.scan)
        let aisle=pose(4,90);nav.pose(aisle);nav.risk(near(aisle,.unknown,side:-30));XCTAssertTrue(nav.cue()?.text.contains("左")==true)
        for i in 5...11 {let p=pose(i,x:Double(i-5)*0.12);nav.pose(p);nav.risk(near(p)); _=nav.register([object(p,goal,tag:42)],at:p,local:true);XCTAssertNotEqual(nav.cue()?.kind,.arrived)}
        let id=try XCTUnwrap(nav.door); XCTAssertNotNil(nav.record(id)?.point)
        let block=pose(12,-20,x:0.7);nav.pose(block);nav.risk(near(block,.occupied,person:true));XCTAssertEqual(nav.cue()?.kind,.stop)
        let close=pose(21,-12,x:0.15,z:-2.10);nav.pose(close);nav.risk(near(close));XCTAssertNotEqual(nav.cue()?.kind,.arrived)
        _=nav.register([object(close,goal,tag:42)],at:close,local:true);XCTAssertEqual(nav.door,id);XCTAssertEqual(nav.cue()?.kind,.arrived)
    }
    func testCloudOnlyDoorCannotClaimPhysicalArrivalOrUpdateLastLocalSightTime() {
        var nav=SpatialNavigator(doorTarget:true);let goal=V3(0,1.4,-2)
        for i in 0...4 { let p=pose(i,x:Double(i)*0.16);nav.pose(p);nav.risk(near(p));let ids=nav.register([object(p,goal)],at:p,local:false); if let id=ids[0]{nav.select(id)} }
        XCTAssertTrue(nav.doorsSeen.isEmpty);XCTAssertFalse(nav.manualDoorArrival());XCTAssertNotEqual(nav.cue()?.kind,.arrived)
    }
    func testGridAndMovableObjectExpireToUnknown() {
        var grid=LocalGrid(), book=LandmarkBook(); let p=pose(1), place=V3(0,0,-1.2)
        grid.update(near(p));XCTAssertEqual(grid.state(at:place,time:0.2),.free)
        let n=pose(3);grid.update(near(n,.unknown));XCTAssertEqual(grid.state(at:place,time:0.31),.unknown)
        let id=book.observe(object(p,V3(0,1.4,-2),as:.chair),at:p); XCTAssertNotNil(id);book.expire(at:1);XCTAssertTrue(book.records.isEmpty)
        grid.update(near(n));XCTAssertEqual(grid.state(at:place,time:1.3),.unknown)
    }
    func testCloudReplyRejectsOldFrameDanglingRefsBoxesAndUnsafeSpeech() throws {
        let id=pose(1).id
        var json:[String:Any]=["frame_id":["session":session.uuidString,"world":1,"frame":1],"action":"target_waypoint","target_ref":"o1","observations":[["ref":"o1","kind":"aisle_entrance","box":[0.1,0.2,0.4,0.8]]],"hazards":[],"speech_zh":"先转向左侧过道。","uncertain":false]
        func data() throws -> Data {try JSONSerialization.data(withJSONObject:json)}
        let valid=try PlannerReply.parse(data(),for:id);XCTAssertNotNil(valid.turnSpeech(error:-30));XCTAssertNil(valid.turnSpeech(error:30))
        XCTAssertThrowsError(try PlannerReply.parse(data(),for:pose(2).id));json["speech_zh"]="向前跑五米！";XCTAssertNil(try PlannerReply.parse(data(),for:id).turnSpeech(error:-20))
        json["target_ref"]="notThere";XCTAssertThrowsError(try PlannerReply.parse(data(),for:id));json["target_ref"]="o1";json["observations"]=[["ref":"o1","kind":"door","box":[0.4,0.2,1.2,0.8]]];XCTAssertThrowsError(try PlannerReply.parse(data(),for:id))
    }
    func testCloudQueueOnlyKeepsLatest() { var q=LatestOnly<Int>();XCTAssertEqual(q.offer(1),1);XCTAssertNil(q.offer(2));XCTAssertNil(q.offer(3));XCTAssertEqual(q.finish(),3);XCTAssertNil(q.finish());XCTAssertFalse(q.busy) }
    func testMapRouteRequiresMatchingLiveAnchorsAndAccessibleEdges() throws {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/demo-floor.json")
        let map=try JSONDecoder().decode(PriorMap.self,from:Data(contentsOf:fixture))
        try map.validate();let p=pose(10);var anchors:[Landmark]=[]
        for (i,n) in map.nodes.prefix(2).enumerated() { let q=V3(n.x,1.4,n.z),ray=V3(0,0,-1);anchors.append(.init(id:i,kind:.sign,first:p,last:p,firstRay:ray,ray:ray,box:.init(0.2,0.2,0.4,0.4),confidence:0.9,label:n.label,appearance:nil,point:q,count:3)) }
        XCTAssertEqual(map.nextPoint(for:"402",from:p,anchors:anchors,level:"2F"),V3(3,0,0));XCTAssertNil(map.nextPoint(for:"402",from:p,anchors:anchors,level:"4F"));anchors[1].point=V3(7,0,0);XCTAssertNil(map.registration(anchors,at:p))
    }
    func testSpokenCorrectionsAndVenueQualifiers() {
        XCTAssertEqual(Destination(wayfinding:"带我去教室门口，不对，去四零二"), .room("402"))
        XCTAssertEqual(Destination(wayfinding:"找商场里的松间书屋"), .named("松间书屋"))
        XCTAssertEqual(Destination(wayfinding:"带我去医院的收费处"), .named("收费处"))
        XCTAssertEqual(Destination(wayfinding:"带我去教室门口")?.isClassroomDoor,true)
    }
    func testReversingTwoFullTurnsCountsSecondSweep() {
        var m=WalkMeasures(); m.start(0)
        for i in 0...24 {m.sample(pose(i,Double(i)*15),scanning:true)}
        for i in 1...24 {m.sample(pose(25+i,360-Double(i)*15),scanning:true)}
        XCTAssertEqual(m.peakSameStationSweeps,2)
    }

    func testGridVetoAfterMovingAChairRequiresNewEvidence() {
        var grid = LocalGrid()
        var blocked = near(pose(1), .occupied)
        let front = blocked.sectors.firstIndex { $0.angle == 0 }!
        blocked.sectors[front].nearest = 1.2
        XCTAssertEqual(grid.reconcile(blocked).front, .occupied)
        XCTAssertEqual(grid.reconcile(near(pose(2))).front, .unknown)
        XCTAssertEqual(grid.reconcile(near(pose(3))).front, .free)
        XCTAssertEqual(grid.reconcile(near(pose(4), .unknown)).front, .unknown)
        XCTAssertEqual(grid.reconcile(near(pose(5, world: 2), .unknown)).front, .unknown)
    }

    func testPauseAndTrackingResetPreserveTimingButInvalidateDoorIdentity() {
        var measures = WalkMeasures()
        measures.openSegment(at: 2)
        measures.lock(1, in: pose(1).id)
        measures.hazard(at: 3)
        measures.requested(at: 3.1)
        measures.speech(at: 3.3, ended: false)
        measures.closeSegment(at: 5)
        measures.openSegment(at: 10)
        measures.sample(pose(100, world: 2), scanning: true)
        measures.lock(1, in: pose(100, world: 2).id)
        measures.finish(12, door: 1, manual: true)
        XCTAssertEqual(measures.started, 2)
        XCTAssertEqual(measures.activeSeconds, 5)
        XCTAssertEqual(measures.segments, 2)
        XCTAssertEqual(measures.stops.first?.speechStarted, 3.3)
        XCTAssertFalse(measures.identityContinuous)
    }

}
