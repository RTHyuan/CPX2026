import XCTest
@testable import PathSenseCore

/// Synthetic semantic equivalents of a corridor reply. No private pixels, live inference,
/// depth measurements, physical motion or phone playback are represented here.
final class CloudGuidanceRegressionTests: XCTestCase {
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let destination = Destination.facility(.restroom)
    private let reason = "悬挂标牌有卫生间图标，共享通道向前延伸，可继续核对目的地方向。"

    private var capture: FrameID { .init(session: session, world: 1, frame: 18) }

    private func stamp(_ frame: FrameID) -> [String: Any] {
        ["session": frame.session.uuidString, "world": frame.world, "frame": frame.frame]
    }

    private func item(_ ref: String, kind: String = "sign", box: [Double], sign: [String: Any]? = nil) -> [String: Any] {
        var result: [String: Any] = ["source_frame": stamp(capture), "ref": ref, "kind": kind, "box": box]
        if let sign { result["sign"] = sign }
        return result
    }

    private func replyObject() -> [String: Any] {
        [
            "frame_id": stamp(capture),
            "observations": [
                item("ceiling_restroom", box: [0.00, 0.34, 0.34, 0.405], sign: ["symbol": "restroom"]),
                item("ceiling_elevator", box: [0.19, 0.35, 0.30, 0.405], sign: ["symbol": "elevator"]),
                item("ceiling_arrow", box: [0.26, 0.35, 0.33, 0.405], sign: ["symbol": "unknown", "arrow": "↑"]),
                item("wall_restroom", box: [0.50, 0.425, 0.575, 0.465], sign: ["symbol": "restroom"]),
                item("corridor", kind: "aisle_entrance", box: [0.00, 0.45, 0.42, 0.66])
            ],
            "hazards": [],
            "action": "verify_destination",
            "target_ref": "ceiling_restroom",
            "speech_zh": "转动手机，看看目的地的标识。",
            "uncertain": false,
            "plan": [
                "scene": "public_corridor", "scene_uncertain": false,
                "task": "verify_destination", "reason": reason, "completion": "destination_verified",
                "layout": ["kind": "corridor_layout", "source_frame": stamp(capture), "box": [0.0, 0.4, 1.0, 0.7]]
            ]
        ]
    }

    private func corridorRescanObject() -> [String: Any] {
        [
            "frame_id": stamp(capture),
            "observations": [
                item("ceiling_restroom", box: [0.06, 0.34, 0.30, 0.40], sign: ["symbol": "restroom", "arrow": "↑"]),
                item("wall_restroom", box: [0.51, 0.42, 0.58, 0.46], sign: ["symbol": "restroom"]),
                item("corridor", kind: "junction", box: [0.00, 0.40, 0.35, 0.65])
            ],
            "hazards": [], "action": "rescan", "target_ref": NSNull(),
            "speech_zh": "悬挂标牌有洗手间图标并指向前方，请转动手机再核对。", "uncertain": false,
            "plan": ["scene": "public_corridor", "scene_uncertain": false, "task": "find_signs",
                     "reason": reason, "completion": "sign_identified"]
        ]
    }

    private func mixedPanelWaitObject() -> [String: Any] {
        [
            "frame_id": stamp(capture),
            "observations": [
                item("mixed_panel", box: [0.00, 0.337, 0.348, 0.402],
                     sign: ["symbol": "restroom", "text": "洗手间 电梯 | 直行 ↑", "arrow": "↑"]),
                item("wall_restroom", box: [0.508, 0.423, 0.565, 0.449], sign: ["symbol": "restroom"]),
                item("corridor", kind: "aisle_entrance", box: [0.00, 0.40, 0.30, 0.60])
            ],
            "hazards": [], "action": "wait", "target_ref": NSNull(),
            "speech_zh": "可以慢慢转动手机，看看周围。", "uncertain": false,
            "plan": ["scene": "public_corridor", "scene_uncertain": false, "task": "find_signs",
                     "reason": reason, "completion": "sign_identified"]
        ]
    }

    private func parse(_ object: [String: Any]) throws -> PlannerReply {
        try PlannerReply.parse(JSONSerialization.data(withJSONObject: object), for: capture, sources: [capture])
    }

    private func pose(_ frame: Int) -> FramePose {
        .init(id: .init(session: session, world: 1, frame: frame), time: Double(frame) * 0.1,
              transform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1.4,0,1],
              intrinsics: [550,0,0,0,550,0,640,1138,1], width: 1280, height: 2276, exif: 1, tracking: "normal")
    }

    func testArrowOnlyUnknownSignDoesNotDiscardTheRestOfTheCorridorReply() throws {
        let reply = try parse(replyObject())
        XCTAssertEqual(reply.frame_id, capture)
        XCTAssertEqual(reply.observations.count, 5)
        XCTAssertEqual(reply.observations.map(\.ref), ["ceiling_restroom", "ceiling_elevator", "ceiling_arrow", "wall_restroom", "corridor"])
        XCTAssertEqual(reply.observations[0].sign?.symbol, .restroom)
        XCTAssertEqual(reply.observations[1].sign?.symbol, .elevator)
        XCTAssertEqual(reply.observations[2].kind, .sign)
        XCTAssertNil(reply.observations[2].sign, "An isolated arrow must not acquire destination or entrance semantics")
        XCTAssertEqual(reply.observations[3].sign?.symbol, .restroom)
        XCTAssertEqual(reply.observations[4].kind, .aisle_entrance)
        XCTAssertTrue(reply.observations.allSatisfy { $0.source_frame == capture })
        XCTAssertEqual(reply.target_ref, "ceiling_restroom")
        XCTAssertEqual(reply.action, .verify_destination)
        XCTAssertEqual(reply.plan?.reason, reason)
        XCTAssertEqual(reply.plan?.layout?.kind, .corridor)
        for arrow in SignArrow.allCases {
            var object = replyObject(), items = object["observations"] as! [[String: Any]]
            items[2]["sign"] = ["symbol": "unknown", "arrow": arrow.rawValue]
            object["observations"] = items
            let directional = try parse(object)
            XCTAssertNil(directional.observations[2].sign, "A standalone \(arrow.rawValue) must remain unassociated")
            XCTAssertEqual(directional.plan?.reason, reason)
        }
    }

    func testCorridorDestinationProposalAdvancesSurveyWhileKeepingTheFinalDestination() throws {
        let reply = try parse(replyObject())
        let plan = try XCTUnwrap(reply.plan)
        let selected = try XCTUnwrap(reply.observations.first { $0.ref == reply.target_ref })
        var journey = WayfindingJourney(target: destination)
        XCTAssertEqual(journey.stage, .survey)
        let originalPrompt = journey.prompt
        XCTAssertTrue(journey.applyPlan(plan, targetKind: selected.kind))
        XCTAssertEqual(journey.target, destination)
        XCTAssertEqual(journey.searchTarget, destination)
        XCTAssertEqual(journey.plannerScene, .publicCorridor)
        XCTAssertEqual(journey.stage, .corridor)
        XCTAssertEqual(journey.plannerTask, .approachDestination)
        XCTAssertFalse(journey.requiresExit)
        XCTAssertNil(journey.action, "Recognizing a sign cannot confirm arrival")
        XCTAssertNotEqual(journey.prompt, originalPrompt, "The task card must describe the accepted corridor task")
    }

    func testCorridorRescanUsesUniqueCurrentGeometryAndNormalizesOnlyTheSpokenProposal() throws {
        for kind in ["junction", "aisle_entrance"] {
            var object = corridorRescanObject(), items = object["observations"] as! [[String: Any]]
            items[2]["kind"] = kind
            object["observations"] = items
            let reply = try parse(object)
            XCTAssertEqual(reply.observations.count, 3)
            XCTAssertEqual(reply.observations[0].sign, SignMeaning(symbol: .restroom, arrow: .ahead))
            XCTAssertEqual(reply.observations[1].sign?.symbol, .restroom)
            XCTAssertEqual(reply.action, .rescan)
            XCTAssertNil(reply.target_ref)
            XCTAssertEqual(reply.speech_zh, "请慢慢转动手机，补扫周围。")
            XCTAssertEqual(reply.stationarySpeech, "请慢慢转动手机，补扫周围。")
            let plan = try XCTUnwrap(reply.plan)
            XCTAssertEqual(plan.reason, reason)
            XCTAssertEqual(plan.layout?.kind, .corridor)
            XCTAssertEqual(plan.layout?.source_frame, capture)
            XCTAssertEqual(plan.layout?.box, reply.observations[2].box)
            var journey = WayfindingJourney(target: destination)
            let initialPrompt = journey.prompt
            XCTAssertTrue(journey.applyPlan(plan, targetKind: nil))
            XCTAssertEqual(journey.plannerScene, .publicCorridor)
            XCTAssertEqual(journey.plannerTask, .findSigns)
            XCTAssertEqual(journey.stage, .corridor)
            XCTAssertEqual(journey.target, destination)
            XCTAssertNotEqual(journey.prompt, initialPrompt)
            XCTAssertNil(journey.action)
        }
    }

    func testProviderMotionSpeechIsReplacedBeforeItCanBecomePlayable() throws {
        let unsafe = "道路安全，向前跑五米，到达洗手间。"
        let cases: [(String, String?, String, String, String)] = [
            ("wait", nil, "find_signs", "sign_identified", "可以慢慢转动手机，看看周围。"),
            ("rescan", nil, "find_signs", "sign_identified", "请慢慢转动手机，补扫周围。"),
            ("target_waypoint", "ceiling_restroom", "find_signs", "sign_identified", "请观察选定目标。"),
            ("verify_destination", "wall_restroom", "verify_destination", "destination_verified", "转动手机，看看目的地的标识。")
        ]
        for (action, target, task, completion, safe) in cases {
            var object = corridorRescanObject(), plan = object["plan"] as! [String: Any]
            object["action"] = action
            object["target_ref"] = target.map { $0 as Any } ?? NSNull()
            object["speech_zh"] = unsafe
            plan["task"] = task; plan["completion"] = completion
            object["plan"] = plan
            let reply = try parse(object)
            XCTAssertEqual(reply.speech_zh, safe, action)
            XCTAssertNotEqual(reply.stationarySpeech, unsafe)
            XCTAssertNotEqual(reply.turnSpeech(error: -30), unsafe)
            XCTAssertNotEqual(reply.turnSpeech(error: 30), unsafe)
            let encoded = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
            XCTAssertFalse(encoded.contains(unsafe), "Untrusted provider commands must not survive the parsed response")
        }
    }

    func testMixedFacilityPanelDoesNotDiscardAnIndependentRestroomOrTheCorridorTask() throws {
        let reply = try parse(mixedPanelWaitObject())
        XCTAssertEqual(reply.observations.count, 3)
        XCTAssertEqual(reply.observations[0].kind, .sign)
        XCTAssertNil(reply.observations[0].sign, "The whole panel cannot associate a shared arrow with either facility")
        XCTAssertEqual(reply.observations[1].sign, SignMeaning(symbol: .restroom))
        XCTAssertEqual(reply.action, .wait)
        XCTAssertNil(reply.target_ref)
        XCTAssertEqual(reply.stationarySpeech, "可以慢慢转动手机，看看周围。")
        let plan = try XCTUnwrap(reply.plan)
        XCTAssertEqual(plan.reason, reason)
        XCTAssertEqual(plan.layout?.kind, .corridor)
        XCTAssertEqual(plan.layout?.source_frame, capture)
        XCTAssertEqual(plan.layout?.box, reply.observations[2].box)
        var journey = WayfindingJourney(target: destination)
        XCTAssertTrue(journey.applyPlan(plan, targetKind: nil))
        XCTAssertEqual(journey.stage, .corridor)
        XCTAssertEqual(journey.plannerTask, .findSigns)
        XCTAssertEqual(journey.target, destination)
        XCTAssertNil(journey.action)

        let initial = pose(capture.frame)
        var nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: true)
        nav.setStepTask(destination: destination.text, task: journey.plannerTask.rawValue, revision: journey.taskVersion)
        nav.pose(initial)
        let sightings = reply.observations.map { Sighting(kind: $0.kind, box: $0.box, confidence: 0.64, sign: $0.sign) }
        let ids = nav.register(sightings, at: initial, local: false)
        let panel = try XCTUnwrap(nav.record(try XCTUnwrap(ids[0])))
        let wall = try XCTUnwrap(nav.record(try XCTUnwrap(ids[1])))
        XCTAssertNil(panel.signReadout(at: initial, target: destination.text))
        let readout = try XCTUnwrap(wall.signReadout(at: initial, target: destination.text))
        XCTAssertTrue(readout.contains("洗手间图标"))
        XCTAssertFalse(readout.contains("箭头"), "An independent icon must not inherit the shared panel direction")
        nav.risk(.init(pose: initial, visible: false, sectors: [Sector(angle: 0, state: .unknown)], hazards: [], reason: "noDepth"))
        XCTAssertNil(nav.waypoint, "A wait reply with no target only supplies observation facts")
        XCTAssertNotEqual(nav.cue()?.kind, .advance)
        XCTAssertNil(nav.activeStep)
        XCTAssertFalse(nav.canAdvance)
        XCTAssertFalse(nav.arrived)
    }

    func testEmbeddedArrowPanelFallbackIsLimitedToOtherwiseValidLabels() throws {
        let base = mixedPanelWaitObject(), items = base["observations"] as! [[String: Any]]
        func withMeaning(_ sign: [String: Any]) -> [String: Any] {
            var changed = base, detections = items
            detections[0]["sign"] = sign; changed["observations"] = detections
            return changed
        }
        for arrow in SignArrow.allCases {
            for hasArrowField in [false, true] {
                var sign: [String: Any] = ["symbol": "restroom", "text": "洗手间 电梯 " + arrow.rawValue]
                if hasArrowField { sign["arrow"] = arrow.rawValue }
                let reply = try parse(withMeaning(sign))
                XCTAssertNil(reply.observations[0].sign)
                XCTAssertEqual(reply.observations[1].sign?.symbol, .restroom)
                XCTAssertEqual(reply.plan?.task, .findSigns)
            }
        }
        let invalid: [[String: Any]] = [
            ["symbol": "restroom", "text": "↑", "arrow": "↑"],
            ["symbol": "unknown", "text": "←→↑↓↖↗↙↘"],
            ["symbol": "restroom", "text": "洗手间 ↑", "arrow": "straight_ahead"],
            ["symbol": "restroom", "text": "洗手间 ↑", "arrow": "↑", "distance": 3],
            ["symbol": "restroom", "text": String(repeating: "厕", count: 48) + "↑", "arrow": "↑"],
            ["symbol": "restroom", "text": "洗手间\n↑", "arrow": "↑"],
            ["symbol": "restroom", "text": "洗手间\u{0000}↑", "arrow": "↑"],
            ["symbol": "restroom", "text": 42, "arrow": "↑"]
        ]
        for sign in invalid { XCTAssertThrowsError(try parse(withMeaning(sign)), String(describing: sign)) }
    }

    func testMissingCorridorLayoutCannotBorrowAmbiguousStaleOrInvalidGeometry() throws {
        let base = corridorRescanObject(), observations = base["observations"] as! [[String: Any]]
        func withItems(_ items: [[String: Any]]) -> [String: Any] {
            var changed = base; changed["observations"] = items; return changed
        }
        let noCandidate = withItems(Array(observations.prefix(2)))
        let anotherCandidate = item("other_corridor", kind: "aisle_entrance", box: [0.5, 0.4, 0.8, 0.7])
        let ambiguous = withItems(observations + [anotherCandidate])
        var invalidBoxItems = observations
        invalidBoxItems[2]["box"] = [0.0, 0.4, 1.1, 0.65]
        var wrongFrame = base
        wrongFrame["frame_id"] = stamp(.init(session: session, world: 1, frame: capture.frame + 1))
        var wrongSourceItems = observations
        wrongSourceItems[2]["source_frame"] = stamp(.init(session: session, world: 2, frame: capture.frame))
        for object in [noCandidate, ambiguous, withItems(invalidBoxItems), wrongFrame, withItems(wrongSourceItems)] {
            XCTAssertThrowsError(try parse(object))
        }
        let previous = FrameID(session: session, world: 1, frame: capture.frame - 1)
        var historicalItems = observations
        historicalItems[2]["source_frame"] = stamp(previous)
        let historical = try JSONSerialization.data(withJSONObject: withItems(historicalItems))
        XCTAssertThrowsError(try PlannerReply.parse(historical, for: capture, sources: [capture, previous]),
                             "A historical corridor detection cannot establish the current scene without a layout")
    }

    func testSpeechTypeLengthAndControlCharacterValidationIsNotBypassedByNormalization() throws {
        let invalid: [Any] = [42, NSNull(), "", String(repeating: "长", count: 65), "请观察。\n向前走。", "请观察。\u{0000}"]
        for speech in invalid {
            var object = corridorRescanObject(); object["speech_zh"] = speech
            XCTAssertThrowsError(try parse(object), String(describing: speech))
        }
    }

    func testTaskPromptRefreshPreservesPhysicalConfirmationAndKnownFloorInstructions() {
        var crossing = WayfindingJourney(target: destination)
        crossing.confirmedInsideRoom()
        crossing.reachedWaypoint(.door)
        let crossingPrompt = crossing.prompt
        XCTAssertEqual(crossing.action, .crossed)
        XCTAssertTrue(crossing.applyPlan(.init(scene: .doorway, scene_uncertain: false, task: .verifyCrossing,
                                               reason: reason, completion: .crossingVerified), targetKind: .door))
        XCTAssertEqual(crossing.prompt, crossingPrompt)
        XCTAssertEqual(crossing.action, .crossed)
        XCTAssertTrue(crossing.requiresExit)

        var entrance = WayfindingJourney(target: destination)
        entrance.enteredPublicArea()
        entrance.observe(.init(target: .plate), entrance: .nearby(1))
        let entrancePrompt = entrance.prompt
        XCTAssertEqual(entrance.action, .atDestination)
        XCTAssertTrue(entrance.applyPlan(.init(scene: .doorway, scene_uncertain: false, task: .verifyDestination,
                                               reason: reason, completion: .destinationVerified), targetKind: .sign))
        XCTAssertEqual(entrance.prompt, entrancePrompt)
        XCTAssertEqual(entrance.action, .atDestination)
        XCTAssertEqual(entrance.stage, .verify)

        var changingFloor = WayfindingJourney(target: destination)
        changingFloor.enteredPublicArea()
        changingFloor.observe(.init(target: .listed(.init(level: "3F", arrow: .left))))
        let floorPrompt = changingFloor.prompt
        XCTAssertEqual(changingFloor.stage, .transfer)
        XCTAssertTrue(changingFloor.applyPlan(.init(scene: .publicCorridor, scene_uncertain: false, task: .approachDestination,
                                                    reason: reason, completion: .entranceReached), targetKind: .sign))
        XCTAssertEqual(changingFloor.prompt, floorPrompt)
        XCTAssertEqual(changingFloor.site.level, "3F")
        XCTAssertEqual(changingFloor.stage, .transfer)
    }

    func testStaticCloudSignsWithoutPassageEvidenceCannotOfferAStepOrArrive() throws {
        let reply = try parse(replyObject())
        let plan = try XCTUnwrap(reply.plan)
        let selectedIndex = try XCTUnwrap(reply.observations.firstIndex { $0.ref == reply.target_ref })
        var journey = WayfindingJourney(target: destination)
        XCTAssertTrue(journey.applyPlan(plan, targetKind: reply.observations[selectedIndex].kind))
        var nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: true)
        nav.setStepTask(destination: destination.text, task: journey.plannerTask.rawValue, revision: journey.taskVersion)
        let initial = pose(capture.frame)
        nav.pose(initial)
        let sightings = reply.observations.map { Sighting(kind: $0.kind, box: $0.box, confidence: 0.64, sign: $0.sign) }
        let ids = nav.register(sightings, at: initial, local: false)
        let selectedID = try XCTUnwrap(ids[selectedIndex])
        nav.select(selectedID)
        XCTAssertEqual(nav.record(selectedID)?.sign?.symbol, .restroom)
        XCTAssertNil(nav.record(selectedID)?.point, "One stationary camera ray provides no measured distance")
        var symbolGate = EntranceSymbolGate()
        XCTAssertFalse(symbolGate.accept(id: selectedID, capture: initial))
        XCTAssertFalse(symbolGate.accept(id: selectedID, capture: initial), "The same capture is not an independent verification")
        XCTAssertEqual(nav.book.entrance(for: destination, captured: initial, at: initial), .unseen)
        for frame in capture.frame ... capture.frame + 12 {
            let current = pose(frame)
            nav.pose(current)
            nav.risk(.init(pose: current, visible: false,
                           sectors: [Sector(angle: 0, state: .unknown)], hazards: [], reason: "noDepth"))
            nav.faceForward()
            XCTAssertNotEqual(nav.cue()?.kind, .advance)
            XCTAssertNil(nav.activeStep)
            XCTAssertFalse(nav.canAdvance)
            XCTAssertFalse(nav.arrived)
        }
        XCTAssertNotEqual(journey.stage, .arrived)
        XCTAssertNil(journey.action)
        XCTAssertFalse(nav.takeStepEvents().contains { $0.type == "offered" || $0.type == "speechStarted" })
    }

    func testFrameBoxesTasksAndOtherMalformedSemanticsStillFailClosed() throws {
        let valid = replyObject()
        let observations = valid["observations"] as! [[String: Any]]
        func replacingItem(_ index: Int, key: String, value: Any) -> [String: Any] {
            var changed = valid, changedItems = observations
            changedItems[index][key] = value
            changed["observations"] = changedItems
            return changed
        }
        var wrongFrame = valid
        wrongFrame["frame_id"] = stamp(.init(session: session, world: 1, frame: 19))
        var wrongTask = valid, plan = valid["plan"] as! [String: Any]
        plan["task"] = "walk_to_destination"
        wrongTask["plan"] = plan
        let invalid: [(String, [String: Any])] = [
            ("wrong reply frame", wrongFrame),
            ("source frame absent from request", replacingItem(0, key: "source_frame", value: stamp(.init(session: session, world: 1, frame: 17)))),
            ("out of range box", replacingItem(0, key: "box", value: [-0.1, 0.34, 0.34, 0.405])),
            ("unknown task", wrongTask),
            ("unknown symbol without an arrow", replacingItem(2, key: "sign", value: ["symbol": "unknown"])),
            ("invalid arrow", replacingItem(2, key: "sign", value: ["symbol": "unknown", "arrow": "sideways"])),
            ("null arrow", replacingItem(2, key: "sign", value: ["symbol": "unknown", "arrow": NSNull()])),
            ("extra semantic key", replacingItem(2, key: "sign", value: ["symbol": "unknown", "arrow": "↑", "safe": true])),
            ("explicit null inscription", replacingItem(2, key: "sign", value: ["symbol": "unknown", "arrow": "↑", "text": NSNull()])),
            ("blank inscription", replacingItem(2, key: "sign", value: ["symbol": "unknown", "arrow": "↑", "text": ""]))
        ]
        for (label, object) in invalid { XCTAssertThrowsError(try parse(object), label) }
    }
}
