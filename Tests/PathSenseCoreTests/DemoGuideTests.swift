import XCTest
@testable import PathSenseCore

final class DemoGuideTests: XCTestCase {
    private let session = UUID()
    private var frame: FrameID { .init(session: session, world: 1, frame: 7) }

    private func object(action: DemoGuideAction = .look, scene: String = "前方是走廊，左转有厕所。", speech: String = "请看左侧路牌。", target: Bool = false) -> [String: Any] {
        ["frame_id": ["session": session.uuidString, "world": 1, "frame": 7],
         "scene_zh": scene, "speech_zh": speech, "action": action.rawValue,
         "target_kind": target ? "aisle_entrance" : NSNull(),
         "target_box": target ? [0.3, 0.2, 0.7, 0.9] : NSNull()]
    }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func parse(_ object: [String: Any]) throws -> DemoGuideReply { try DemoGuideReply.parse(data(object), for: frame) }

    func testModelTextIsPreservedAndAllSixFieldsRoundTripIncludingNullTargets() throws {
        let scene = "前方是明亮走廊，左转有厕所。", speech = "请向左转，观察蓝色路牌。"
        let reply = try parse(object(action: .turn_left, scene: scene, speech: speech))
        XCTAssertEqual(reply.scene_zh, scene)
        XCTAssertEqual(reply.speech_zh, speech)
        XCTAssertEqual(reply.action, .turn_left)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["frame_id", "scene_zh", "speech_zh", "action", "target_kind", "target_box"])
        XCTAssertTrue(encoded["target_kind"] is NSNull)
        XCTAssertTrue(encoded["target_box"] is NSNull)
        XCTAssertEqual(try parse(encoded).speech_zh, speech)
    }

    func testOnlyAnExplicitSingleForwardStepWithAVisibleTargetIsAccepted() throws {
        for speech in ["请向前迈一步。", "朝门口方向向前一小步。", "沿路牌方向走一步，随后站稳。"] {
            let reply = try parse(object(action: .forward, speech: speech, target: true))
            XCTAssertEqual(reply.speech_zh, speech)
            XCTAssertEqual(reply.target_kind, .aisle_entrance)
        }
        XCTAssertThrowsError(try parse(object(action: .forward, speech: "请向前迈一步。")))
        var sign = object(action: .forward, speech: "请向前迈一步。", target: true)
        sign["target_kind"] = "sign"
        XCTAssertThrowsError(try parse(sign), "A route sign is an observation target, not a forward opening")
        for kind in ["door", "aisle_entrance", "junction"] {
            var opening = object(action: .forward, speech: "请向前迈一步。", target: true)
            opening["target_kind"] = kind
            XCTAssertNoThrow(try parse(opening), kind)
        }
        for speech in ["向前走。", "请向前走两步。", "向前迈十一步。", "向前迈一百步。", "向前迈二十一步。", "向前迈一步再走一步。", "一直向前迈一步。",
                       "向前一小步，然后进门。", "向前一步，到达厕所。", "向前一步，再上楼。", "向右走一步。", "后退一步。",
                       "先左转，再向前走一步。", "向前走一步约两米。", "向前跑一步。", "向前走一步，缓慢前进。", "原地迈一步。", "侧着走一步。", "不要向前走一步。"] {
            XCTAssertThrowsError(try parse(object(action: .forward, speech: speech, target: true)), speech)
        }
    }

    func testObservationTurnAndStopCannotSmuggleForwardOrUnboundedActions() throws {
        for action in [DemoGuideAction.look, .turn_left, .turn_right, .stop] {
            for speech in ["请向前走。", "往前走到门口。", "向前迈一步。", "前进一点。", "朝前慢走。", "请靠近门口。", "前 进一点。", "一直往右走。", "请上楼。", "已经到达厕所。"] {
                XCTAssertThrowsError(try parse(object(action: action, speech: speech)), "\(action): \(speech)")
            }
        }
        XCTAssertEqual(try parse(object(action: .look, speech: "请把镜头向前对准路牌。")).speech_zh, "请把镜头向前对准路牌。")
        XCTAssertEqual(try parse(object(action: .stop, speech: "请停步，前方有人。")).action, .stop)
    }

    func testSceneMayDescribeDirectionsButCannotIssueMovementCommands() throws {
        for scene in ["路牌提示左转有厕所，前方是走廊。", "路牌上直行箭头指向厕所。", "路牌指示直行", "左转有厕所"] {
            XCTAssertNoThrow(try parse(object(scene: scene)), scene)
        }
        for scene in ["请向前走。", "先左转。", "现在进门。", "向前迈一步。", "走一步到门口。"] {
            XCTAssertThrowsError(try parse(object(scene: scene)), scene)
        }
    }

    func testExactFrameShapeAndJSONIntegerCountersAreRequired() throws {
        var changed = object()
        changed["extra"] = false
        XCTAssertThrowsError(try parse(changed))
        for key in ["target_kind", "target_box", "scene_zh", "speech_zh", "action", "frame_id"] {
            var missing = object(); missing.removeValue(forKey: key)
            XCTAssertThrowsError(try parse(missing), key)
        }
        for stamp: [String: Any] in [
            ["session": session.uuidString, "world": 2, "frame": 7],
            ["session": session.uuidString, "world": 1, "frame": 8],
            ["session": UUID().uuidString, "world": 1, "frame": 7],
            ["session": session.uuidString, "world": true, "frame": 7],
            ["session": session.uuidString, "world": -1, "frame": 7],
            ["session": session.uuidString, "world": 1, "frame": 7, "extra": 0]
        ] {
            changed = object(); changed["frame_id"] = stamp
            XCTAssertThrowsError(try parse(changed))
        }
        let json = String(decoding: try data(object()), as: UTF8.self)
        for invalid in [json.replacingOccurrences(of: "\"world\":1", with: "\"world\":1.0"),
                        json.replacingOccurrences(of: "\"frame\":7", with: "\"frame\":7e0")] {
            XCTAssertThrowsError(try DemoGuideReply.parse(Data(invalid.utf8), for: frame))
        }
    }

    func testTargetsMustBePairedAllowedAndValidNormalizedBoxes() throws {
        for kind in ["door", "aisle_entrance", "sign", "junction"] {
            var valid = object(target: true); valid["target_kind"] = kind
            XCTAssertNoThrow(try parse(valid))
        }
        for kind in ["person", "chair", "steps", "obstacle", "unknown"] {
            var invalid = object(target: true); invalid["target_kind"] = kind
            XCTAssertThrowsError(try parse(invalid))
        }
        for box in [[0.2, 0.3, 0.8], [-0.1, 0.2, 0.8, 0.9], [0.2, 0.3, 1.1, 0.9], [0.7, 0.2, 0.3, 0.9], [0.2, 0.3, 0.8, 0.3]] {
            var invalid = object(target: true); invalid["target_box"] = box
            XCTAssertThrowsError(try parse(invalid))
        }
        for key in ["target_kind", "target_box"] {
            var unpaired = object(target: true); unpaired[key] = NSNull()
            XCTAssertThrowsError(try parse(unpaired))
        }
    }

    func testTextLengthBlankAndInvisibleControlValidation() throws {
        for key in ["scene_zh", "speech_zh"] {
            for text in ["", "  ", "请看\n路牌", "请看\u{200B}路牌", String(repeating: "字", count: key == "scene_zh" ? 33 : 25)] {
                var invalid = object(); invalid[key] = text
                XCTAssertThrowsError(try parse(invalid), "\(key): \(text)")
            }
        }
    }

    private func parseEnglish(_ object: [String: Any]) throws -> DemoGuideReply {
        try DemoGuideReply.parse(data(object), for: frame, language: .english)
    }

    private func englishObject(action: DemoGuideAction = .look, scene: String = "A bright corridor is ahead. The sign points left to the toilets.", speech: String = "Please look toward the blue sign.", target: Bool = false) -> [String: Any] {
        object(action: action, scene: scene, speech: speech, target: target)
    }

    func testGuidanceLanguageProvidesExactLocaleAndSelectedText() throws {
        XCTAssertEqual(GuidanceLanguage.allCases, [.chinese, .english])
        XCTAssertEqual(GuidanceLanguage.chinese.speechLocale, "zh-CN")
        XCTAssertEqual(GuidanceLanguage.english.speechLocale, "en-US")
        XCTAssertEqual(GuidanceLanguage.chinese.text("室内寻路", "Indoor Wayfinding"), "室内寻路")
        XCTAssertEqual(GuidanceLanguage.english.text("室内寻路", "Indoor Wayfinding"), "Indoor Wayfinding")
        XCTAssertEqual(try JSONDecoder().decode(GuidanceLanguage.self, from: Data("\"en-US\"".utf8)), .english)
    }

    func testEnglishModelOriginalTextAndCompatibleWireKeysArePreserved() throws {
        let scene = "The corridor continues straight ahead; a blue sign points left to the toilets."
        let speech = "Please turn your head left, toward the blue sign."
        let reply = try parseEnglish(englishObject(action: .turn_left, scene: scene, speech: speech))
        XCTAssertEqual(reply.scene_zh, scene)
        XCTAssertEqual(reply.speech_zh, speech)
        XCTAssertEqual(reply.action, .turn_left)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["frame_id", "scene_zh", "speech_zh", "action", "target_kind", "target_box"])
        XCTAssertEqual(try parseEnglish(encoded).speech_zh, speech)
        XCTAssertTrue(encoded["target_kind"] is NSNull)
        XCTAssertTrue(encoded["target_box"] is NSNull)
    }

    func testEnglishForwardNeedsOneCountedStepMovementDirectionAndOpeningTarget() throws {
        for speech in ["Take one small step toward the doorway, then stop.", "Carefully walk one step forward.",
                       "Please move forward by one step.", "Step forward by one small step.",
                       "Take just one step towards the open door.", "Take one step toward the doorway on your right.",
                       "Take one step toward the door to your right."] {
            let reply = try parseEnglish(englishObject(action: .forward, speech: speech, target: true))
            XCTAssertEqual(reply.speech_zh, speech)
        }
        let speech = "Take one step forward."
        XCTAssertThrowsError(try parseEnglish(englishObject(action: .forward, speech: speech)))
        for kind in ["door", "aisle_entrance", "junction", "sign"] {
            var target = englishObject(action: .forward, speech: speech, target: true)
            target["target_kind"] = kind
            if kind == "sign" { XCTAssertThrowsError(try parseEnglish(target), kind) }
            else { XCTAssertNoThrow(try parseEnglish(target), kind) }
        }
        for speech in ["Walk forward.", "Take one step.", "Take a step forward.", "One step forward is clear.",
                       "There is room to take one step forward.", "The sign says take one step forward.",
                       "Take one step forward twice.", "Take one step forward and another small step.",
                       "Take one step forward, then keep walking.", "Take one step forward and move ahead.",
                       "Take one step forward, then follow the corridor.", "Take one step forward and exit.",
                       "Take one step forward, then carry on.", "Take one step forward, then continue.",
                       "Take one step forward, then two more.", "Take one step forward by backing up.",
                       "Take one step in the left direction, looking forward.",
                       "Take one step at a time toward the doorway.", "Walk forward one step at a time.",
                       "Take one step away from the doorway ahead.", "Take one step to the side toward the open door.",
                       "Walk forward and take one step.", "Take one step forward and turn right.",
                       "Take one step backward.", "Take one step to your left.", "Move sideways one step forward.",
                       "Take two steps forward.", "Take one step forward for two meters.", "Take one step forward for 0.5 m.",
                       "Take one step toward the stairs.", "Take one step forward and climb upstairs.",
                       "Take one step forward to reach the toilet.", "Take one step forward; you have arrived.",
                       "Take one step forward and enter the doorway.", "Take one step forward through the door.",
                       "Do not take one step forward.", "You don't need to take one step forward.",
                       "If the path is clear, take one step forward."] {
            XCTAssertThrowsError(try parseEnglish(englishObject(action: .forward, speech: speech, target: true)), speech)
        }
    }

    func testEnglishObservationAllowsCameraAndHeadMotionButNeverWalking() throws {
        for action in [DemoGuideAction.look, .turn_left, .turn_right, .stop] {
            for speech in ["Look left, then move forward.", "Please walk toward the doorway.", "Take one step forward.",
                           "Step back.", "Step slowly forward.", "Head slowly toward the doorway.", "Sidestep right.",
                           "Turn left and go ahead.", "Keep walking.", "You have arrived.", "Please climb the stairs."] {
                XCTAssertThrowsError(try parseEnglish(englishObject(action: action, speech: speech)), "\(action): \(speech)")
            }
        }
        for speech in ["Move the camera toward the sign.", "Turn your head left.", "Keep your head still and look at the sign.",
                       "Look forward at the open doorway.", "Please stop. There are stairs ahead."] {
            XCTAssertNoThrow(try parseEnglish(englishObject(speech: speech)), speech)
        }
        XCTAssertThrowsError(try parseEnglish(englishObject(speech: "Move the camera left, then walk forward.")))
        for speech in ["Stop walking; a person is ahead.", "Do not move. A person is ahead.", "Don't walk forward."] {
            XCTAssertNoThrow(try parseEnglish(englishObject(action: .stop, speech: speech)), speech)
        }
        for speech in ["Stop walking, then move forward.", "Do not move; take one step toward the door."] {
            XCTAssertThrowsError(try parseEnglish(englishObject(action: .stop, speech: speech)), speech)
        }
    }

    func testEnglishSceneAllowsAttributedDirectionsAndRejectsInstructionsInLaterClauses() throws {
        for scene in ["The sign points left to the toilets.", "The sign says \"Turn left for toilets\".",
                      "The sign reads: Go straight to the toilets.", "The sign indicates to turn right for the exit.",
                      "The corridor continues straight ahead.", "A staircase is visible ahead."] {
            XCTAssertNoThrow(try parseEnglish(englishObject(scene: scene)), scene)
        }
        for scene in ["Please walk forward.", "Turn left for toilets.", "A sign is visible. Please walk forward.",
                      "The sign says \"Turn left\". Now walk forward.", "The sign says turn left, then move forward.",
                      "A door is ahead; take one step toward it.", "You should turn right.", "Look at the sign.",
                      "You can safely walk forward.", "You should carefully take one step forward.", "You may slowly turn left."] {
            XCTAssertThrowsError(try parseEnglish(englishObject(scene: scene)), scene)
        }
    }

    func testEnglishModeRejectsChineseAndMixedTextAndEnforcesItsOwnLengths() throws {
        for key in ["scene_zh", "speech_zh"] {
            for text in ["请看左侧路牌。", "Look at 左侧 sign.", "", "  ", "Look\nat the sign.", "Look\u{200B} at the sign.",
                         String(repeating: "a", count: key == "scene_zh" ? 121 : 91)] {
                var invalid = englishObject(); invalid[key] = text
                XCTAssertThrowsError(try parseEnglish(invalid), "\(key): \(text)")
            }
        }
        var maximum = englishObject()
        maximum["scene_zh"] = String(repeating: "a", count: 120)
        maximum["speech_zh"] = String(repeating: "a", count: 90)
        XCTAssertNoThrow(try parseEnglish(maximum))
        // The default call still uses the existing Chinese limits and rules.
        XCTAssertThrowsError(try parse(maximum))
    }

    private func pose(_ frame: Int, heading: Double = 0, x: Double = 0, z: Double = 0, world: Int = 1) -> FramePose {
        let a = heading * .pi / 180, c = cos(a), s = sin(a)
        return .init(id: .init(session: session, world: world, frame: frame), time: Double(frame) / 10,
                     transform: [c,0,s,0, 0,1,0,0, -s,0,c,0, x,1.4,z,1], intrinsics: [550,0,0,0,550,0,500,400,1],
                     width: 1000, height: 800, exif: 1, tracking: "normal")
    }
    /// Injected passage evidence tests heading/execution only; it does not validate RGB or a physical sensor.
    private func controlledNear(_ p: FramePose, side: Int? = nil) -> NearField {
        let sectors = stride(from: -60, through: 60, by: 15).map { angle -> Sector in
            var sector = Sector(angle: angle, state: angle == 0 || angle == side ? .free : .unknown)
            if sector.state == .free { sector.stepCoverage = .controlled }
            return sector
        }
        return .init(pose: p, visible: true, sectors: sectors, hazards: [])
    }
    private func readyInDemoDirection() throws -> SpatialNavigator {
        var nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: false)
        nav.setStepTask(destination: "厕所", task: "按路牌方向接近过道", revision: 1)
        let origin = pose(0); nav.pose(origin)
        XCTAssertTrue(nav.aimDemo(toward: 30, from: origin))
        for i in 1...3 {
            let p = pose(i); nav.pose(p); nav.risk(controlledNear(p, side: 30))
            XCTAssertEqual(nav.cue()?.kind, .turn)
            XCTAssertFalse(nav.canAdvance)
        }
        for i in 4...10 {
            let p = pose(i, heading: 30); nav.pose(p); nav.risk(controlledNear(p)); _ = nav.cue()
        }
        nav.faceForward()
        XCTAssertEqual(nav.cue()?.kind, .advance)
        return nav
    }

    func testDemoHeadingProducesARealPermitAfterIndependentPassageAndFacingChecks() throws {
        var nav = try readyInDemoDirection()
        let cue = try XCTUnwrap(nav.cue()), id = try XCTUnwrap(cue.permitID), p = try XCTUnwrap(nav.current)
        XCTAssertEqual(nav.activeStep?.target.localOpeningHeading, 30)
        XCTAssertEqual(nav.activeStep?.target.destination, "厕所")
        XCTAssertTrue(nav.permitsSpeech(cue, at: p.time))
        nav.submittedStep(id, at: p.time)
        XCTAssertTrue(nav.stepSpeechStarted(id, at: p.time))
        XCTAssertTrue(nav.takeStepEvents().contains { $0.type == "speechStarted" && $0.permit?.id == id })
    }

    func testRepeatedHeadingPreservesPermitAndChangedHeadingRevokesWithoutClearingBodyConfirmation() throws {
        var nav = try readyInDemoDirection()
        let id = try XCTUnwrap(nav.activeStep?.id), origin = try XCTUnwrap(nav.current)
        XCTAssertTrue(nav.aimDemo(toward: 390, from: origin))
        XCTAssertEqual(nav.activeStep?.id, id)
        XCTAssertTrue(nav.canAdvance)
        XCTAssertTrue(nav.aimDemo(toward: 35, from: origin))
        XCTAssertNil(nav.activeStep)
        XCTAssertTrue(nav.takeStepEvents().contains { $0.type == "revoked" && $0.reason == "demoHeadingChanged" })
        // New proof is required after the changed-heading barrier. A five-degree intent
        // adjustment itself does not erase the independent user-facing confirmation.
        for i in 11...14 {
            let p = pose(i, heading: 30); nav.pose(p); nav.risk(controlledNear(p)); _ = nav.cue()
        }
        XCTAssertEqual(nav.cue()?.kind, .advance)
        XCTAssertNotEqual(nav.activeStep?.id, id)
        XCTAssertEqual(nav.activeStep?.target.localOpeningHeading, 35)
    }

    func testPhotoOrModelHeadingAloneNeverCreatesAPassagePermit() {
        var nav = SpatialNavigator(doorTarget: false)
        let origin = pose(0); nav.pose(origin)
        XCTAssertTrue(nav.aimDemo(toward: 0, from: origin))
        nav.faceForward()
        for i in 1...20 {
            nav.pose(pose(i))
            XCTAssertNotEqual(nav.cue()?.kind, .advance)
            XCTAssertNil(nav.activeStep)
            XCTAssertFalse(nav.canAdvance)
        }
    }

    func testDemoHeadingRejectsWrongWorldOldCaptureDistanceAndNonfiniteHeading() throws {
        var nav = try readyInDemoDirection()
        let id = try XCTUnwrap(nav.activeStep?.id)
        var old = pose(0); old.time = -8
        var future = pose(11); future.time = 1.1
        for capture in [pose(0, world: 2), old, future, pose(0, x: 0.39)] {
            XCTAssertFalse(nav.aimDemo(toward: 0, from: capture))
            XCTAssertEqual(nav.activeStep?.id, id)
        }
        XCTAssertFalse(nav.aimDemo(toward: .nan, from: pose(0)))
        XCTAssertFalse(nav.aimDemo(toward: .infinity, from: pose(0)))
        XCTAssertEqual(nav.activeStep?.id, id)
    }
}
