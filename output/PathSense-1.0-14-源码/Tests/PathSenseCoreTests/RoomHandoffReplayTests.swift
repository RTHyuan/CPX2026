import XCTest
@testable import PathSenseCore

/// All poses, boxes, semantic choices and clear footprints here are controlled inputs.
/// This exercises the production planner/executor handoff, not door or person recognition.
extension SpatialReplayTests {
    func testRoomHandoffFromOccludedExitThroughSameDoorWithTwoIndependentPermits() throws {
        let goal = Destination.facility(.restroom), chosen = V3(0,1.4,-3.1), neighbor = V3(1.1,1.4,-3.1)
        let entrance = V3(-0.8,1.4,-1.85), seat = V3(0,1.4,-1.6)
        var journey = WayfindingJourney(target: goal); journey.confirmedInsideRoom()
        var nav = SpatialNavigator(doorTarget: true, requiresPlannedTarget: true)
        func updateTask() { nav.setStepTask(destination: goal.text, task: journey.plannerTask.rawValue, revision: journey.taskVersion) }
        updateTask()
        var goalID: Int?, otherID: Int?, aisleID: Int?
        for i in 0...8 {
            let p = pose(i, x: Double(i) * 0.07); nav.pose(p); nav.risk(near(p))
            var features = [object(p, neighbor, tag:0x0000FFFF0000FFFF)]
            if i >= 2 { features += [object(p, chosen, tag:0xFFFF0000FFFF0000), object(p, entrance, as:.aisle_entrance, tag:3)] }
            let ids = nav.register(features,at:p,local:true); otherID = ids[0]
            if i >= 2 { goalID = ids[1]; aisleID = ids[2] }
        }
        let selected = try XCTUnwrap(goalID), other = try XCTUnwrap(otherID), aisle = try XCTUnwrap(aisleID)
        XCTAssertEqual(nav.door,other) // This neighboring door was locally acquired first.
        XCTAssertTrue(nav.selectRoomTarget(selected)); XCTAssertEqual(nav.door,selected)
        XCTAssertNotNil(nav.record(selected)?.point); XCTAssertNotNil(nav.record(aisle)?.point)
        let blocked = pose(9,x:0.50); nav.pose(blocked); nav.risk(near(blocked,.occupied,side:-30))
        let items = [object(blocked,chosen,tag:0xFFFF0000FFFF0000),object(blocked,entrance,as:.aisle_entrance,tag:3),object(blocked,seat,as:.chair)]
        _ = nav.register(items,at:blocked,local:true)
        let side = try XCTUnwrap(nav.roomWaypoint(for:&journey,capture:blocked,features:items))
        XCTAssertEqual(side,aisle); XCTAssertEqual(journey.plannerTask,.approachAisle); updateTask(); nav.select(side)
        XCTAssertFalse(nav.selectRoomTarget(other)); XCTAssertEqual(nav.waypoint,aisle)
        let reached = pose(22,x:-0.65,z:-1.15); nav.pose(reached); nav.risk(near(reached))
        let here = [object(reached,entrance,as:.aisle_entrance,tag:3)]
        _ = nav.register(here,at:reached,local:true)
        let regained = try XCTUnwrap(nav.roomWaypoint(for:&journey,capture:reached,features:here))
        XCTAssertEqual(journey.plannerTask,.approachExit); XCTAssertEqual(regained,selected)
        updateTask(); nav.select(regained)
        XCTAssertFalse(nav.selectRoomTarget(aisle)); XCTAssertFalse(nav.selectRoomTarget(other))
        XCTAssertEqual(nav.roomWaypoint(for:&journey,capture:reached,features:items),selected)
        // The earlier survey translated the synthetic camera, so the executor must see
        // it stand still before this independent, locally measured approach handoff.
        for i in 36...42 {
            let p = pose(i,z:-2.70); nav.pose(p); nav.risk(near(p))
            _ = nav.register([object(p,chosen,tag:0xFFFF0000FFFF0000)],at:p,local:true)
        }
        let doorStation = try XCTUnwrap(nav.current)
        XCTAssertEqual(nav.cue()?.kind,.arrived)
        journey.reachedWaypoint(.door); nav.beginCrossing(); updateTask(); nav.select(selected)
        XCTAssertEqual(nav.crossing?.id,selected); XCTAssertEqual(journey.plannerTask,.verifyCrossing)
        XCTAssertFalse(try XCTUnwrap(nav.crossing).confirms(doorStation)) // Looking out from inside is insufficient.
        var index = 42, z = -2.70, permits: [StepPermit] = []
        nav.faceForward()
        for step in [0.34,0.39] {
            var offered: LocalCue?
            for _ in 0..<16 {
                index += 1; let p = pose(index,z:z); nav.pose(p); nav.risk(near(p))
                if let cue = nav.cue() {
                    nav.didDeliver(cue)
                    if cue.kind == .advance { offered = cue; break }
                }
            }
            let cue = try XCTUnwrap(offered)
            let id = try XCTUnwrap(cue.permitID)
            let at = try XCTUnwrap(nav.current).time
            nav.submittedStep(id, at: at)
            XCTAssertTrue(nav.stepSpeechStarted(id, at: at))
            XCTAssertEqual(nav.activeStep?.target.landmarkID,selected)
            for delta in [0.04,0.11,0.20,0.27,step] {
                index += 1; let p = pose(index,z:z-delta); nav.pose(p); nav.risk(near(p))
            }
            z -= step
            for _ in 0..<6 { index += 1; let p = pose(index,z:z); nav.pose(p); nav.risk(near(p)) }
            let completed = try XCTUnwrap(nav.takeStepEvents().last { $0.type == "completed" && $0.permit?.id == id }?.permit)
            permits.append(completed)
        }
        XCTAssertNotEqual(permits[0].id,permits[1].id)
        XCTAssertGreaterThan(permits[1].check.times.first!,permits[0].endedAt!)
        XCTAssertEqual(nav.cue(),.verifyCrossingView); XCTAssertFalse(nav.canAdvance)
        let outer = try XCTUnwrap(nav.current); XCTAssertTrue(try XCTUnwrap(nav.crossing).confirms(outer))
        XCTAssertFalse(try XCTUnwrap(nav.crossing).confirms(doorStation))
        journey.observe(.init(scene:.init(setting:.publicCorridor))); XCTAssertTrue(journey.requiresExit)
        journey.observedCrossing(); nav.clearRoomTargets(); updateTask()
        XCTAssertNil(nav.crossing); XCTAssertEqual(journey.plannerTask,.findSigns); XCTAssertEqual(journey.target,goal)
        XCTAssertNotEqual(journey.stage,.arrived)
    }

    func testHistoricCloudOnlyExitDoesNotAdoptTheAdjacentLocalDoorAndJumpIsNotACrossing() throws {
        let chosen = V3(0,1.4,-3), neighbor = V3(0.95,1.4,-3)
        var nav = SpatialNavigator(doorTarget:true,requiresPlannedTarget:true)
        let original = pose(0); nav.pose(original)
        let historic = try XCTUnwrap(nav.register([object(original,chosen)],at:original,local:false)[0]); XCTAssertLessThan(historic,0)
        XCTAssertTrue(nav.selectRoomTarget(historic)); XCTAssertEqual(nav.waypoint,historic)
        var adjacent:Int?
        for i in 1...8 {
            let p=pose(i,x:Double(i)*0.07); nav.pose(p); adjacent=nav.register([object(p,neighbor,tag:10)],at:p,local:true)[0]
        }
        XCTAssertFalse(nav.selectRoomTarget(try XCTUnwrap(adjacent))); XCTAssertNil(nav.record(historic)?.point)
        var actual:Int?
        for i in 9...17 {
            let p=pose(i,x:Double(i-9)*0.07); nav.pose(p)
            actual=nav.register([object(p,chosen,tag:3),object(p,neighbor,tag:10)],at:p,local:true)[0]
        }
        XCTAssertEqual(nav.record(historic)?.id,actual); XCTAssertNotEqual(nav.record(historic)?.id,adjacent)
        XCTAssertTrue(nav.selectRoomTarget(try XCTUnwrap(actual))); XCTAssertEqual(nav.waypoint,historic)
        let close = pose(30,z:-2.5); nav.pose(close); _ = nav.register([object(close,chosen,tag:3)],at:close,local:true)
        nav.beginCrossing(); let before = try XCTUnwrap(nav.crossing)
        var jumped=before; let beyond = pose(40,z:-3.4); jumped.sample(beyond); XCTAssertFalse(jumped.confirms(beyond))
        var nextDoor=before
        for i in 1...6 { nextDoor.sample(pose(30+i,x:Double(i)*0.14,z:-2.5)) }
        for i in 1...9 { nextDoor.sample(pose(36+i,x:0.84,z:-2.5-Double(i)*0.1)) }
        XCTAssertFalse(nextDoor.confirms(pose(45,x:0.84,z:-3.4)))
        nav.pose(pose(46,world:2)); XCTAssertNil(nav.crossing); XCTAssertNil(nav.plannedExit)
    }

    func testLocalSurveyedAisleHandsOffAfterOneCheckedStepAndDoesNotChooseItAgain() throws {
        var nav = SpatialNavigator(doorTarget:true,requiresPlannedTarget:true)
        var journey = WayfindingJourney(target:.facility(.restroom)); journey.confirmedInsideRoom()
        let opening=Sighting(kind:.aisle_entrance,box:.init(0.45,0.4,0.55,0.6),confidence:0.8)
        let initial=pose(0); nav.pose(initial); nav.risk(near(initial))
        let id=try XCTUnwrap(nav.register([opening],at:initial,local:true)[0]); XCTAssertNil(nav.record(id)?.point)
        XCTAssertEqual(nav.roomWaypoint(for:&journey,capture:initial,features:[opening]),id)
        nav.setStepTask(destination:journey.target.text,task:journey.plannerTask.rawValue,revision:journey.taskVersion); nav.select(id)
        for i in 1...8 { let p=pose(i);nav.pose(p);nav.risk(near(p)); nav.faceForward(); _=nav.cue() }
        XCTAssertNotNil(startStep(&nav)); var i=8
        for distance in [0.05,0.12,0.20,0.28,0.34,0.34,0.34,0.34,0.34,0.34,0.34] {
            i+=1; let p=pose(i,z:-distance);nav.pose(p);nav.risk(near(p))
        }
        let reached=try XCTUnwrap(nav.current)
        XCTAssertNil(nav.roomWaypoint(for:&journey,capture:reached,features:[opening])); XCTAssertEqual(journey.plannerTask,.approachExit)
        XCTAssertFalse(nav.acceptsRoomTarget(id)); nav.setStepTask(destination:journey.target.text,task:journey.plannerTask.rawValue,revision:journey.taskVersion)
        XCTAssertNil(nav.roomWaypoint(for:&journey,capture:reached,features:[opening])); XCTAssertNil(nav.waypoint)
    }

    func testUnletteredDoorAndNeighboringOrDirectionalPlaqueCannotEstablishTheRestroomDestination() throws {
        let p=pose(0), target=Destination.facility(.restroom)
        var nav=SpatialNavigator(doorTarget:false,requiresPlannedTarget:true); nav.pose(p)
        let door=Sighting(kind:.door,box:.init(0.1,0.2,0.45,0.9),confidence:0.8)
        let nextDoor=Sighting(kind:.door,box:.init(0.53,0.2,0.92,0.9),confidence:0.8)
        let inscription=Sighting(kind:.sign,box:.init(0.62,0.4,0.78,0.51),confidence:0.98,label:"RESTROOM")
        let arrow=Sighting(kind:.sign,box:.init(0.16,0.37,0.36,0.49),confidence:0.98,label:"RESTROOM →")
        let ids=nav.register([door,nextDoor,inscription,arrow],at:p,local:true)
        let first=try XCTUnwrap(ids[0]), second=try XCTUnwrap(ids[1]), plate=try XCTUnwrap(ids[2]), pointer=try XCTUnwrap(ids[3])
        XCTAssertFalse(nav.supportsDestination(target,id:first,box:door.box,signsInImage:[]))
        let local=[(inscription,plate),(arrow,pointer)]
        XCTAssertFalse(nav.supportsDestination(target,id:first,box:door.box,signsInImage:local))
        XCTAssertTrue(nav.supportsDestination(target,id:second,box:nextDoor.box,signsInImage:local))
        XCTAssertFalse(nav.supportsDestination(target,id:second,box:nextDoor.box,signsInImage:local,otherDoorBoxes:[.init(0.51,0.25,0.77,0.75)]))
        XCTAssertTrue(nav.supportsDestination(target,id:plate,box:inscription.box,signsInImage:local))
        XCTAssertFalse(nav.supportsDestination(target,id:pointer,box:arrow.box,signsInImage:local))
    }
}
