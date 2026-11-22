import XCTest
@testable import PathSenseCore

/// Semantic inputs and poses in these tests are controlled. No visual recognition or walking is implied.
final class PlannerTaskTests: XCTestCase {
    private let destination = Destination(wayfinding: "带我去厕所")!
    private func directive(_ scene: PlannerScene, _ task: PlannerTask, uncertain: Bool = false) -> PlannerDirective {
        .init(scene: scene, scene_uncertain: uncertain, task: task, reason: "核对同一目标的现场线索。", completion: task.completion)
    }

    func testClassroomAisleExitAndCorridorKeepTheFinalGoal() {
        XCTAssertEqual(destination, .facility(.restroom))
        var j = WayfindingJourney(target: destination)
        j.observe(.init(nearbyRoom: "BSG21", scene: .init(setting: .room)))
        XCTAssertTrue(j.requiresExit); XCTAssertEqual(j.plannerTask, .findExit)
        XCTAssertTrue(j.applyPlan(directive(.room, .approachAisle), targetKind: .aisle_entrance))
        XCTAssertFalse(j.applyPlan(directive(.room, .approachAisle), targetKind: .door))
        let revision = j.taskVersion
        j.observe(.init(target: .plate, nearbyRoom: "BSG21", scene: .init(setting: .publicCorridor, door: "右侧")))
        XCTAssertEqual(j.plannerTask, .approachAisle); XCTAssertEqual(j.taskVersion, revision)
        XCTAssertNotEqual(j.action, .atDestination)
        XCTAssertFalse(j.applyPlan(directive(.publicCorridor, .findSigns), targetKind: .sign))
        XCTAssertFalse(j.applyPlan(directive(.doorway, .verifyCrossing), targetKind: .door))
        j.observedCrossing(); XCTAssertTrue(j.requiresExit)
        j.reachedWaypoint(.aisle_entrance); XCTAssertEqual(j.plannerTask, .approachExit); XCTAssertGreaterThan(j.taskVersion, revision)
        j.reachedWaypoint(.door); XCTAssertEqual(j.plannerTask, .verifyCrossing)
        j.observedCrossing(); XCTAssertFalse(j.requiresExit); XCTAssertEqual(j.plannerTask, .findSigns)
        XCTAssertEqual(j.plannerScene, .publicCorridor); XCTAssertEqual(j.target, .facility(.restroom)); XCTAssertNotEqual(j.stage, .arrived)
        j.observe(.init(target: .listed(.init(arrow: .left))))
        XCTAssertEqual(j.stage, .corridor); XCTAssertEqual(j.action, nil)
        j.observe(.init(target: .plate)); XCTAssertEqual(j.stage, .verify)
        j.confirm(); XCTAssertEqual(j.stage, .arrived)
    }

    func testPublicCorridorAndBareRoomNumbersDoNotImposeAnExit() {
        var j = WayfindingJourney(target: destination)
        j.observe(.init(nearbyRoom: "BSG21"))
        XCTAssertEqual(j.originRoom, "BSG21"); XCTAssertEqual(j.plannerScene, .unknown); XCTAssertFalse(j.requiresExit)
        j.observe(.init(scene:.init(setting: .publicCorridor, door: "右侧")))
        XCTAssertEqual(j.plannerTask, .findSigns); XCTAssertEqual(j.plannerScene, .publicCorridor); XCTAssertFalse(j.requiresExit)
        XCTAssertFalse(j.applyPlan(directive(.room, .approachExit), targetKind: .door))
        XCTAssertNotEqual(j.stage, .doorway)
        var undecided = WayfindingJourney(target: destination)
        undecided.observe(.init(scene:.init(door: "左侧")))
        XCTAssertEqual(undecided.plannerScene, .unknown); XCTAssertFalse(undecided.requiresExit)
        XCTAssertNil(undecided.action)
    }

    func testReadingCurrentPlaqueAndDirectoryDoesNotDischargeRoomObligation() {
        var j = WayfindingJourney(target: destination)
        j.observe(.init(scene:.init(setting:.room)))
        j.observe(.init(nearbyRoom:"BSG21")); XCTAssertEqual(j.plannerTask, .findExit)
        j.observe(.init(target:.listed(.init(level:"2F",arrow:.right)))); XCTAssertEqual(j.site.level, "2F")
        XCTAssertEqual(j.stage, .doorway); XCTAssertNil(j.action)
        j.observe(.init(target:.plate)); j.confirm(); XCTAssertTrue(j.requiresExit); XCTAssertNotEqual(j.stage, .arrived)
        j.enteredPublicArea(); XCTAssertEqual(j.stage, .orient); XCTAssertEqual(j.plannerTask, .findSigns)
        XCTAssertEqual(j.target, .facility(.restroom))
    }

    func testLocationEvidenceAndPlaqueRemainIndependentInTheParser() throws {
        // Layout/text are injected at the system Vision adapter's boundary, including one print-only view.
        func parse(_ lines: [String], scene: SceneClues = .init()) -> WayfindingSigns {
            let text = lines.map { SignLine($0) }
            return WayfindingParser.read(.init(lines: text, reading: SignParser.analyze(text, for: destination), scene: scene), for: destination)
        }
        let withRoom = parse(["ROOM BSG21"], scene: .init(setting: .room))
        XCTAssertEqual(withRoom.nearbyRoom, "BSG21"); XCTAssertEqual(withRoom.scene.setting, .room)
        var inside = WayfindingJourney(target: destination); inside.observe(withRoom)
        XCTAssertTrue(inside.requiresExit)
        let roomNumber = parse(["ROOM BSG21"])
        XCTAssertNil(roomNumber.scene.setting)
        var confirmed = WayfindingJourney(target: destination); confirmed.observe(roomNumber); confirmed.confirmedInsideRoom()
        XCTAssertEqual(confirmed.plannerTask, .findExit)
        XCTAssertEqual(parse(["CURRENT LOCATION MAIN CORRIDOR"]).scene.setting, .publicCorridor)
        XCTAssertNil(parse(["MAIN CORRIDOR →"]).scene.setting)
        XCTAssertNil(parse(["CURRENT LOCATION MAIN CORRIDOR"], scene: .init(setting:.room)).scene.setting)
    }

    func testUncertainWaitLeavesAnExistingTargetAndItsTaskRevisionAlone() {
        var j = WayfindingJourney(target: destination)
        j.enteredPublicArea(); XCTAssertTrue(j.applyPlan(directive(.publicCorridor, .approachDestination), targetKind: .sign))
        let before = j.taskVersion
        XCTAssertTrue(j.applyPlan(directive(.unknown, .observe, uncertain:true), targetKind:nil))
        XCTAssertEqual(j.plannerTask, .approachDestination); XCTAssertEqual(j.taskVersion, before)
    }

    func testDistantAndRayOnlyPlateAllowApproachAndNearPlateAllowsVerification() throws {
        let session = UUID()
        func pose(_ frame: Int, _ x: Double, _ z: Double) -> FramePose {
            .init(id:.init(session:session,world:1,frame:frame), time:Double(frame) * 0.2,
                  transform:[1,0,0,0,0,1,0,0,0,0,1,0,x,1.4,z,1], intrinsics:[580,0,0,0,580,0,500,400,1],
                  width:1000,height:800,exif:1,tracking:"normal")
        }
        let point = V3(0,1.4,-3.8), target = Destination.facility(.restroom)
        var book = LandmarkBook(), j = WayfindingJourney(target: target)
        j.enteredPublicArea()
        func observe(_ p: FramePose) throws -> Int {
            let left = try XCTUnwrap(p.project(point + V3(-0.35,0.07,0)))
            let right = try XCTUnwrap(p.project(point + V3(0.35,-0.07,0)))
            return try XCTUnwrap(book.observe(.init(kind:.sign,box:.init(left.0,left.1,right.0,right.1),confidence:0.94,label:"洗手间"),at:p))
        }
        let a = pose(1,0,0), id = try observe(a)
        let rayOnly = book.entrance(for:target,captured:a,at:a)
        XCTAssertEqual(rayOnly,.unmeasured(id)) // Even a large sign in one frame supplies no length.
        j.observe(.init(target:.plate),entrance:rayOnly)
        XCTAssertEqual(j.stage,.corridor); XCTAssertEqual(j.plannerTask,.approachDestination)
        XCTAssertEqual(j.action,.confirmUnmeasuredEntrance)
        var manuallyVerified = j; manuallyVerified.confirm(); XCTAssertEqual(manuallyVerified.stage,.arrived)
        j.observe(.init(target:.plate),entrance:.distant(id)); XCTAssertNil(j.action); j.confirm(); XCTAssertNotEqual(j.stage,.arrived)
        let b = pose(2,0.40,0), c = pose(3,0.45,0); XCTAssertEqual(try observe(b),id); XCTAssertEqual(try observe(c),id)
        XCTAssertEqual(book.entrance(for:target,captured:c,at:c),.distant(id))
        let close = pose(4,0,-2.9); XCTAssertEqual(try observe(close),id)
        let measured = book.entrance(for:target,captured:close,at:close)
        XCTAssertEqual(measured,.nearby(id)); j.observe(.init(target:.plate),entrance:measured)
        XCTAssertEqual(j.stage,.verify); XCTAssertEqual(j.action,.atDestination)
        j.expireConfirmation(); XCTAssertNil(j.action); XCTAssertEqual(j.plannerTask,.approachDestination)
        var reset = close; reset.id.world += 1
        XCTAssertEqual(book.entrance(for:target,captured:close,at:reset),.unseen)
        XCTAssertEqual(book.entrance(for:.facility(.lift),captured:close,at:close),.unseen)
        // Identical letters on different landmarks still require two independent agreeing captures.
        var gate = RouteEvidenceGate(now:0); let sign = WayfindingSigns(target:.plate)
        XCTAssertFalse(gate.accept(sign,at:1,landmarkID:id)); XCTAssertTrue(gate.accept(sign,at:1.4,landmarkID:id))
        XCTAssertFalse(gate.accept(sign,at:1.8,landmarkID:id+1)); XCTAssertFalse(gate.stillConfirmed(sign,landmarkID:id+1))
        XCTAssertTrue(gate.accept(sign,at:2.2,landmarkID:id+1))
    }

    func testOnlyRepeatedUnletteredEntranceSymbolsCanRequestLocalProximityVerification() throws {
        let target = Destination.facility(.restroom), session = UUID()
        let entrance = SignMeaning(symbol:.restroom)
        XCTAssertTrue(entrance.representsEntrance(for:target))
        XCTAssertFalse(SignMeaning(symbol:.restroom,arrow:.left).representsEntrance(for:target))
        XCTAssertFalse(SignMeaning(symbol:.restroom,text:"电梯").representsEntrance(for:target))
        XCTAssertFalse(SignMeaning(symbol:.elevator).representsEntrance(for:target))
        var p = FramePose(id:.init(session:session,world:1,frame:1),time:1,transform:[1,0,0,0,0,1,0,0,0,0,1,0,0,1.4,0,1],
                          intrinsics:[580,0,0,0,580,0,500,400,1],width:1000,height:800,exif:1,tracking:"normal")
        let item = Sighting(kind:.sign,box:.init(0.42,0.4,0.58,0.6),confidence:0.64,sign:entrance)
        var book = LandmarkBook(), vote = EntranceSymbolGate()
        let id = try XCTUnwrap(book.registerSemanticSign(item, at:p, localMatch:nil))
        XCTAssertFalse(vote.accept(id:id,capture:p)); XCTAssertFalse(vote.accept(id:id,capture:p))
        p.id.frame += 1; p.time += 1; XCTAssertEqual(book.registerSemanticSign(item,at:p,localMatch:nil),id)
        XCTAssertTrue(vote.accept(id:id,capture:p)); XCTAssertEqual(book.entrance(for:target,captured:p,at:p),.unseen)
        XCTAssertEqual(book.entrance(for:target,captured:p,at:p,confirmedSymbolID:id),.unmeasured(id))
        var j = WayfindingJourney(target:target); j.enteredPublicArea()
        XCTAssertTrue(j.applyPlan(directive(.publicCorridor,.verifyDestination),targetKind:.sign)); XCTAssertEqual(j.plannerTask,.approachDestination)
        j.observe(.init(target:.plate),entrance:.unmeasured(id),symbolOnly:true); XCTAssertEqual(j.action,.confirmUnmeasuredEntrance)
        var reset = p; reset.id.world += 1; reset.id.frame += 1; reset.time += 1
        XCTAssertFalse(vote.accept(id:id,capture:reset)); XCTAssertEqual(book.entrance(for:target,captured:p,at:reset,confirmedSymbolID:id),.unseen)
    }

    func testNewProtocolRequiresExactSourceAndTypedCompletion() throws {
        let session = UUID(), current = FrameID(session:session, world:3, frame:24), old = FrameID(session:session, world:3, frame:12)
        func stamp(_ id: FrameID) -> [String:Any] { ["world":id.world, "frame":id.frame, "session":id.session.uuidString] }
        let source = stamp(old), item: [String:Any] = ["ref":"a", "kind":"aisle_entrance", "source_frame":source, "box":[0.1,0.3,0.4,0.8]]
        let plan: [String:Any] = ["scene":"room", "scene_uncertain":false, "task":"approach_aisle", "reason":"座椅挡住门前，左侧另有过道入口。", "completion":"aisle_reached"]
        let chair: [String:Any] = ["ref":"seat", "kind":"chair", "source_frame":stamp(current), "box":[0.52,0.45,0.75,0.81]]
        let base: [String:Any] = ["frame_id":stamp(current), "action":"target_waypoint", "observations":[item], "hazards":[chair], "target_ref":"a", "speech_zh":"先转向左侧过道。", "uncertain":false, "plan":plan]
        func parse(_ raw: [String:Any]) throws -> PlannerReply {
            try PlannerReply.parse(JSONSerialization.data(withJSONObject:raw), for:current, sources:[current,old])
        }
        let accepted = try parse(base)
        XCTAssertEqual(accepted.observations.first?.source_frame, old); XCTAssertEqual(accepted.plan?.task, .approachAisle)
        func changed(_ original: [String:Any], _ key: String, _ value: Any) -> [String:Any] { var c=original; c[key]=value; return c }
        let invalid: [[String:Any]] = [
            changed(base,"observations",[changed(item,"source_frame",stamp(.init(session:session,world:3,frame:16)))]),
            changed(base,"observations",[changed(item,"source_frame",stamp(.init(session:session,world:4,frame:12)))]),
            changed(base,"observations",[changed(item,"source_frame",changed(source,"frame",true))]),
            changed(base,"hazards",[changed(chair,"source_frame",source)]),
            changed(base,"plan",changed(plan,"completion","destination_verified")),
            changed(base,"plan",changed(plan,"scene","public_corridor")),
            changed(base,"plan",changed(plan,"safe_to_walk",true)),
            changed(base,"observations",[changed(item,"point",[0,0,-2])]),
            changed(base,"action","walk_forward"), changed(base,"speech_zh","道路安全，向前走。"),
            changed(base,"hazards",[]), changed(base,"target_ref","seat"),
            base.filter{ $0.key != "plan" }
        ]
        for raw in invalid { XCTAssertThrowsError(try parse(raw)) }
        XCTAssertThrowsError(try PlannerReply.parse(JSONSerialization.data(withJSONObject:base),for:current))
    }
}
