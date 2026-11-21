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
    func near(_ p:FramePose,_ front:CellState = .free,side:Int?=nil,person:Bool=false,steps:Bool=false) -> NearField {
        let bins=stride(from:-60,through:60,by:15).map { Sector(angle:$0,state:$0==0 ? front:($0==side ? .free:.unknown)) }
        let hz:[Sighting]=person || steps ? [.init(kind:steps ? .steps:.person,box:.init(0.36,0.3,0.7,0.9),confidence:0.92)] : []
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
    func testStaticChairAllowsOnlyStationaryTurnToNewSideAndStepsStayLatched() {
        for side in [-30,30] {
            var nav=SpatialNavigator(doorTarget:true)
            for i in 1...16 { let p=pose(i); nav.pose(p); nav.risk(near(p,.occupied,side:side)); if i==1 { XCTAssertEqual(nav.cue()?.kind,.stop) } }
            let cue=nav.cue(); XCTAssertEqual(cue?.kind,.turn); XCTAssertTrue(cue?.text.contains(side<0 ? "左":"右")==true)
            let next=pose(17);nav.pose(next);nav.risk(near(next,.occupied,steps:true));XCTAssertTrue(nav.cue()?.text.contains("台阶")==true)
            let clear=pose(18);nav.pose(clear);nav.risk(near(clear));XCTAssertEqual(nav.cue()?.kind,.stop)
            nav.recheck();XCTAssertFalse(nav.hasFrontProof)
        }
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

}
