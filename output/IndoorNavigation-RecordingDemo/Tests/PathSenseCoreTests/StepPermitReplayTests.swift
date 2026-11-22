import XCTest
@testable import PathSenseCore

/// Pose timelines, people and checked regions are injected. RGB and measured sensors are exercised separately.
extension SpatialReplayTests {
    private func readyAtOrigin() -> SpatialNavigator {
        var nav = SpatialNavigator(doorTarget: false)
        nav.setStepTask(destination: "厕所", task: "接近侧过道", revision: 3)
        for i in 0...7 { let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue() }
        nav.faceForward()
        return nav
    }

    func testEveryPermitNeedsFootLandingAndBodyCoverageEvenWithADoorAndClearSector() {
        for partial in [StepCoverage?(nil), .init(source: .controlledReplay, nearGround: false, landing: true, body: true),
                        .init(source: .controlledReplay, nearGround: true, landing: false, body: true),
                        .init(source: .controlledReplay, nearGround: true, landing: true, body: false)] {
            var nav = SpatialNavigator(doorTarget: true)
            for i in 0...12 {
                let p = pose(i); nav.pose(p)
                var field = near(p); field.sectors[field.sectors.firstIndex { $0.angle == 0 }!].stepCoverage = partial
                nav.risk(field)
                _ = nav.register([object(p, V3(0, 1.4, -4))], at: p, local: true)
                nav.faceForward()
                if let cue = nav.cue() { nav.didDeliver(cue); XCTAssertNotEqual(cue.kind, .advance) }
                XCTAssertNil(nav.activeStep)
            }
            XCTAssertTrue(nav.hasFrontProof) // directional survey and step coverage are separate
        }
    }

    func testASinglePoseJumpCannotRelocateTheMeasuredFootprintWhenNothingHasBeenHeard() throws {
        var nav = readyAtOrigin()
        let p = pose(8, x: 0.15); nav.pose(p)
        XCTAssertTrue(nav.hasFrontProof)
        XCTAssertFalse(nav.canAdvance); XCTAssertNotEqual(nav.cue()?.kind, .advance)
        var rebound: LocalCue?
        for i in 9...12 {
            let fresh = pose(i, x: 0.15); nav.pose(fresh); nav.risk(near(fresh)); rebound = nav.cue()
            if let rebound, nav.permitsSpeech(rebound, at: fresh.time) { break }
        }
        let cue = try XCTUnwrap(rebound); XCTAssertEqual(cue.kind, .advance)
        let check = try XCTUnwrap(nav.activeStep?.check)
        XCTAssertTrue(check.frames.allSatisfy { $0.frame >= 9 })
        XCTAssertEqual(check.origin.position.x, 0.15, accuracy: 0.001)
    }

    func testOfferedAndSubmittedAdvanceExpireOrCancelBeforeActualSound() throws {
        for interruptedByPerson in [false, true] {
            var nav = readyAtOrigin()
            let cue = try XCTUnwrap(nav.cue()), id = try XCTUnwrap(cue.permitID)
            XCTAssertTrue(nav.permitsSpeech(cue, at: 0.72))
            nav.submittedStep(id, at: 0.72)
            XCTAssertNil(nav.cue())
            if interruptedByPerson {
                let p = pose(8); nav.pose(p); nav.risk(near(p, person: true))
                XCTAssertEqual(nav.cue(), .personAtRest)
                XCTAssertFalse(nav.stepSpeechStarted(id, at: 0.80))
            } else {
                XCTAssertFalse(nav.permitsSpeech(cue, at: 1.29)) // the device may deliver no new frame while audio is queued
                let p = pose(13); nav.pose(p)
                XCTAssertFalse(nav.stepSpeechStarted(id, at: 1.30))
            }
            XCTAssertNil(nav.activeStep)
            let events = nav.takeStepEvents().filter { $0.permit?.id == id }
            XCTAssertFalse(events.contains { $0.type == "speechStarted" })
            XCTAssertTrue(events.contains { ["revoked","expired"].contains($0.type) })
        }
    }

    func testTwoDifferentStepLengthsConsumePermitOnlyAfterContinuousMotionThenSettling() throws {
        for displacements in [[0.05, 0.12, 0.19, 0.26], [0.06, 0.16, 0.25, 0.37, 0.49, 0.61]] {
            var nav = readyAtOrigin()
            let spoken = try XCTUnwrap(startStep(&nav)), id = try XCTUnwrap(spoken.permitID)
            XCTAssertFalse(nav.permitsSpeech(spoken, at: 0.71)) // no second reading of the same action
            var i = 7
            for d in displacements {
                i += 1; let p = pose(i, z: -d); nav.pose(p); nav.risk(near(p))
                XCTAssertNil(nav.cue()); XCTAssertEqual(nav.activeStep?.id, id)
            }
            XCTAssertEqual(nav.stepPhase, .executing)
            let final = try XCTUnwrap(displacements.last)
            for _ in 0..<7 {
                i += 1; let p = pose(i, z: -final); nav.pose(p); nav.risk(near(p))
                if nav.activeStep == nil { break }
            }
            XCTAssertNil(nav.activeStep)
            XCTAssertNotEqual(nav.cue()?.kind, .advance)
            let events = nav.takeStepEvents().filter { $0.permit?.id == id }
            XCTAssertEqual(events.map(\.type), ["offered", "submitted", "speechStarted", "motionStarted", "completed"])
            let finished = try XCTUnwrap(events.last?.permit)
            XCTAssertEqual(finished.spokenCheck?.frames.count, 3)
            XCTAssertEqual(finished.target.destination, "厕所"); XCTAssertEqual(finished.target.task, "接近侧过道")
            XCTAssertEqual(finished.target.revision, 3); XCTAssertNotNil(finished.startedMovingAt)
            let boundary = try XCTUnwrap(finished.endedAt)
            for index in 0..<3 {
                i += 1; let p = pose(i, z: -final); nav.pose(p); nav.risk(near(p))
                if index < 2 { XCTAssertNil(nav.cue(), "Give the fresh, fully framed observations time to accumulate after settling") }
            }
            let second = try XCTUnwrap(nav.cue()), nextID = try XCTUnwrap(second.permitID)
            XCTAssertNotEqual(id, nextID); XCTAssertEqual(second.kind, .advance) // no second body-facing tap
            XCTAssertTrue(try XCTUnwrap(nav.activeStep).check.times.allSatisfy { $0 > boundary })
            XCTAssertFalse(nav.stepSpeechStarted(id, at: Double(i)/10)); nav.cancelStepSpeech(id, at: Double(i)/10)
            XCTAssertEqual(nav.activeStep?.id, nextID)
        }
    }

    func testWaitingJitterAndPanningAreNotStepsAndUncertainStartRequiresReview() throws {
        var nav = readyAtOrigin()
        _ = try XCTUnwrap(startStep(&nav))
        for i in 8...52 {
            let p = pose(i, Double(i % 3 - 1), x: i.isMultiple(of: 2) ? 0.018 : -0.018)
            nav.pose(p); nav.risk(near(p)); XCTAssertNotEqual(nav.cue()?.kind, .stop)
        }
        XCTAssertTrue(nav.stepNeedsReview); XCTAssertNil(nav.activeStep)
        XCTAssertEqual(nav.cue(), .stepReview)
        let events = nav.takeStepEvents()
        XCTAssertFalse(events.contains { ["motionStarted", "completed", "movingWithoutPermit"].contains($0.type) })
        nav.confirmStepReview()
        XCTAssertNotEqual(nav.cue()?.kind, .advance)
        for i in 53...56 { let p = pose(i); nav.pose(p); nav.risk(near(p)) }
        XCTAssertEqual(nav.cue()?.kind, .advance)
        var looking = SpatialNavigator(doorTarget: false)
        for i in 0..<35 { let p = pose(i, Double(i*8), x: Double(i%3)*0.012); looking.pose(p); XCTAssertNotEqual(looking.cue()?.kind, .stop) }
        XCTAssertFalse(looking.stepIsMoving)
    }

    func testNewFloorTripletCannotReuseItsUpperWitnessFromBeforeAnExplicitRescan() throws {
        var nav = readyAtOrigin(); nav.recheck()
        for i in 8...19 {
            let p = pose(i); nav.pose(p)
            let witness = i < 15 ? pose(7) : pose(15)
            var field = near(p)
            let index = try XCTUnwrap(field.sectors.firstIndex { $0.angle == 0 })
            // Inject a depth adapter's provenance, not a depth image or measured clearance.
            field.sectors[index].stepCoverage = .init(source: .lidar, nearGround: true, landing: true, body: true,
                bodyFrame: witness.id, bodyTime: witness.time, bodyFrames: [witness.id, p.id])
            nav.risk(field); nav.faceForward(); _ = nav.cue()
            if i < 17 { XCTAssertNil(nav.activeStep, "frame \(i)") }
        }
        XCTAssertEqual(nav.activeStep?.check.coverage.first?.bodyFrame, pose(15).id)
    }

    func testMissingForwardRegionRevokesEvenWhenTheSideSectorsAreStillVisible() throws {
        var nav = readyAtOrigin(); let issued = try XCTUnwrap(startStep(&nav))
        let p = pose(8); nav.pose(p)
        var partial = near(p, side: 30); partial.sectors.removeAll { $0.angle == 0 }; nav.risk(partial)
        XCTAssertNil(nav.activeStep); XCTAssertFalse(nav.permitsSpeech(issued, at: p.time))
        XCTAssertTrue(nav.takeStepEvents().contains { $0.type == "revoked" && $0.reason == "stepEvidenceLost" })
    }

    func testMovingPersonIntrusionPreemptsAndContinuedUnpermittedTravelStops() throws {
        var nav = readyAtOrigin(); let cue = try XCTUnwrap(startStep(&nav))
        for (i, d) in [(8,0.06), (9,0.13), (10,0.21)] {
            let p = pose(i, z: -d); nav.pose(p); nav.risk(near(p))
        }
        XCTAssertEqual(nav.stepPhase, .executing)
        let p = pose(11, z: -0.29); nav.pose(p); nav.risk(near(p, person: true))
        XCTAssertEqual(nav.cue(), .obstacleStop); XCTAssertNil(nav.activeStep)
        XCTAssertFalse(nav.permitsSpeech(cue, at: p.time)); XCTAssertFalse(nav.stepSpeechStarted(cue.permitID!, at: p.time))
        let moving = pose(12, z: -0.36); nav.pose(moving); nav.risk(near(moving)); XCTAssertEqual(nav.cue(), .uncheckedMotion)
        let events = nav.takeStepEvents()
        XCTAssertTrue(events.contains { $0.type == "revoked" && $0.reason == "person" })
        XCTAssertTrue(events.contains { $0.type == "movingWithoutPermit" })
    }

    func testOldPermitDoesNotReturnAfterNewLandmarkTaskWorldPauseOrScan() throws {
        for reason in ["task", "world", "pause", "scan", "landmark", "rotation", "lateral"] {
            var nav = readyAtOrigin(); let cue = try XCTUnwrap(nav.cue()), id = try XCTUnwrap(cue.permitID)
            nav.submittedStep(id, at: 0.71)
            switch reason {
            case "task": nav.setStepTask(destination: "厕所", task: "核对走廊", revision: 4)
            case "world": nav.pose(pose(8, world: 2))
            case "pause": nav.revokeStep("paused", at: 0.8)
            case "scan": nav.recheck()
            case "landmark":
                let p = pose(7), target = object(p, V3(0.3,1.4,-3), as: .aisle_entrance)
                let ref = try XCTUnwrap(nav.register([target], at: p, local: true)[0]); nav.select(ref)
            case "rotation": nav.pose(pose(8, 27))
            default: nav.pose(pose(8, x: 0.28))
            }
            XCTAssertNil(nav.activeStep, reason)
            XCTAssertFalse(nav.permitsSpeech(cue, at: 0.81), reason); XCTAssertFalse(nav.stepSpeechStarted(id, at: 0.81), reason)
            nav.stepSpeechEnded(id, at: 0.9); XCTAssertNil(nav.activeStep, reason)
        }
    }

    func testBoxBearingSteersWithoutGroundAndAnExpiredRayCannotFallBackToStraight() throws {
        var nav = SpatialNavigator(doorTarget: false)
        let initial = pose(0); nav.pose(initial)
        let object = object(initial, V3(3*tan(.pi/6), 1.4, -3), as: .aisle_entrance)
        let id = try XCTUnwrap(nav.register([object], at: initial, local: true)[0]); nav.select(id)
        XCTAssertTrue(nav.cue()?.text.contains("向右转约30度") == true)
        nav.pose(pose(1,60)); XCTAssertTrue(nav.cue()?.text.contains("向左转约30度") == true)
        for i in 2...12 { let p=pose(i,60,x:0.61); nav.pose(p); nav.risk(near(p)); nav.faceForward(); XCTAssertNotEqual(nav.cue()?.kind,.advance) }
        XCTAssertEqual(nav.waypoint, id); XCTAssertEqual(nav.cue()?.kind, .scan)
    }

    func testSelectedLocalOrRemoteAisleSurvivesSpeechDelayForLookingAndNeedsFreshIdentityForAnotherStep() throws {
        let opening = V3(3 * tan(.pi/6), 1.4, -3)
        for local in [true, false] {
            var nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: true)
            let first = pose(0); nav.pose(first)
            let id = try XCTUnwrap(nav.register([object(first, opening, as: .aisle_entrance)], at: first, local: local)[0]); nav.select(id)
            let turned = pose(96, 60); nav.pose(turned)
            XCTAssertEqual(nav.record(id)?.last.id, first.id)
            XCTAssertTrue(try XCTUnwrap(nav.cue()).text.contains("向左转约30度"))
            for i in 97...103 {
                let p = pose(i, 30); nav.pose(p); nav.risk(near(p)); nav.faceForward()
                XCTAssertNotEqual(nav.cue()?.kind, .advance); XCTAssertFalse(nav.canAdvance)
            }
            let current = pose(104, 30); nav.pose(current)
            let reacquired = try XCTUnwrap(nav.register([object(current, opening, as: .aisle_entrance)], at: current, local: local)[0])
            XCTAssertEqual(reacquired, id)
            for i in 104...109 { let p = pose(i, 30); nav.pose(p); nav.risk(near(p)); _ = nav.cue() }
            let next = try XCTUnwrap(nav.cue()); XCTAssertTrue(nav.permitsSpeech(next, at: 10.9))
            let sideways = pose(110, 30, x: 0.58); nav.pose(sideways)
            XCTAssertEqual(nav.waypoint, id); XCTAssertEqual(nav.cue()?.kind, .scan)
            XCTAssertFalse(nav.permitsSpeech(next, at: sideways.time)); XCTAssertNil(nav.activeStep)
        }
    }

    func testFinishingAnIssuedStraightStepCanOutlastTheSingleViewButANewStepMustReacquireIt() throws {
        var nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: true)
        let origin = pose(0); nav.pose(origin)
        let landmark = try XCTUnwrap(nav.register([object(origin, V3(0,1.4,-4), as: .aisle_entrance)], at: origin, local: true)[0]); nav.select(landmark)
        for i in 0...7 { let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue() }
        let cue = try XCTUnwrap(startStep(&nav))
        for (i,d) in [(8,0.06),(9,0.14),(10,0.22),(11,0.32),(12,0.42),(13,0.53),(14,0.56),(15,0.56),(16,0.56),(17,0.56),(18,0.56)] {
            let p = pose(i, z: -d); nav.pose(p); nav.risk(near(p))
            XCTAssertNotEqual(nav.cue()?.kind, .stop)
        }
        XCTAssertTrue(nav.takeStepEvents().contains { $0.permit?.id == cue.permitID && $0.type == "completed" })
        for i in 19...24 {
            let p = pose(i, z: -0.56); nav.pose(p); nav.risk(near(p)); XCTAssertEqual(nav.cue()?.kind, .scan)
        }
        XCTAssertNil(nav.activeStep); XCTAssertFalse(nav.canAdvance)
    }

    func testAStationaryObserverGetsOneUrgentWarningForAnApproachingPersonOrVeryCloseDepth() {
        var nav = SpatialNavigator(doorTarget: false), voice = CueDelivery()
        for i in 0..<7 {
            let p = pose(i); nav.pose(p)
            var field = near(p, .unknown, person: true)
            field.hazards[0].box = i < 3 ? .init(0.44,0.45,0.58,0.73) : .init(0.37,0.26,0.64,0.91)
            nav.risk(field)
            let cue = nav.cue()!
            XCTAssertEqual(cue, i < 3 ? .personAtRest : .obstacleStop)
            XCTAssertEqual(voice.take(cue, at: p.time, cause: "person"), i == 0 || i == 3)
        }
        var close = SpatialNavigator(doorTarget: false); let p = pose(1); close.pose(p)
        var n = near(p,.occupied); let j = n.sectors.firstIndex { $0.angle == 0 }!; n.sectors[j].nearest = 0.24
        close.risk(n); XCTAssertEqual(close.cue(), .obstacleStop); XCTAssertNil(close.activeStep)
    }

    func testMeasuredDropSurvivesDetourBeyondImmediateGridAndStillVetoesAfterRescan() {
        var nav = SpatialNavigator(doorTarget: false)
        let first = pose(0); nav.pose(first); nav.risk(near(first,drop:V3(0,-0.18,-1.05)))
        XCTAssertEqual(nav.cue(),.dropAtRest)
        let away = pose(10,90,x:4.2); nav.pose(away); nav.risk(near(away)); nav.recheck()
        for i in 20...25 { let p = pose(i); nav.pose(p); nav.risk(near(p)); XCTAssertEqual(nav.cue(),.dropAtRest) }
        XCTAssertNil(nav.activeStep)
    }

    func testOnceADoorIsSeenItStillNeedsSelectionBeforeTheProductionExecutorCanUseIt() throws {
        var nav = SpatialNavigator(doorTarget: true, requiresPlannedTarget: true)
        nav.setStepTask(destination: "厕所", task: "寻找出口", revision: 2)
        let point = V3(0,1.4,-4)
        for i in 0...10 {
            let p = pose(i); nav.pose(p); nav.risk(near(p))
            _ = nav.register([object(p, point)], at: p, local: true)
            nav.faceForward()
            if let cue = nav.cue() { XCTAssertNotEqual(cue.kind, .advance); nav.didDeliver(cue) }
        }
        let door = try XCTUnwrap(nav.door); XCTAssertNil(nav.waypoint); XCTAssertFalse(nav.canAdvance)
        nav.select(door)
        for i in 11...18 { let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue() }
        XCTAssertEqual(nav.activeStep?.target.landmarkID, door)
    }

    func testProductionGateNeedsAFrameBoundPlannedLandmarkEvenWhenTheWholeStepIsClear() throws {
        var nav = SpatialNavigator(doorTarget:false,requiresPlannedTarget:true)
        nav.setStepTask(destination:"厕所",task:"接近过道",revision:2)
        for i in 0...8 { let p = pose(i); nav.pose(p); nav.risk(near(p)); nav.faceForward(); XCTAssertEqual(nav.cue(),.findStepTarget) }
        XCTAssertNil(nav.activeStep); XCTAssertFalse(nav.canAdvance)
        let source = pose(8), sighting = object(source,V3(0,1.4,-3),as:.aisle_entrance)
        let id = try XCTUnwrap(nav.register([sighting],at:source,local:true)[0]); nav.select(id)
        for i in 9...18 { let p = pose(i); nav.pose(p); nav.risk(near(p)); _ = nav.cue() }
        let cue = try XCTUnwrap(nav.cue()); XCTAssertEqual(cue.kind,.advance)
        XCTAssertEqual(nav.activeStep?.target.landmarkID,id); XCTAssertEqual(nav.record(id)?.last.id,source.id)
        nav.pose(pose(19,world:2)); XCTAssertTrue(nav.requiresPlannedTarget)
        XCTAssertNil(nav.activeStep); XCTAssertFalse(nav.permitsSpeech(cue,at:1.9))
    }
}
