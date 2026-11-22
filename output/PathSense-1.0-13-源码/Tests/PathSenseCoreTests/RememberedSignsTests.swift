import XCTest
#if os(macOS) && canImport(Vision)
import Vision
#endif
@testable import PathSenseCore

/// Labels and directory rows transcribed in 照片/info.txt. Poses and boxes exercise geometry only.
final class RememberedSignsTests: XCTestCase {
    private let session = UUID()
    private let center = ImageBox(0.44, 0.46, 0.56, 0.54)
    // Upper BSG33 inscription in the original upright 720 × 1280 RTR1 frame at 01:10.2.
    private let rtr1RoomBox = ImageBox(402.0/720, 152.0/1280, 614.0/720, 213.0/1280)

    private func pose(_ index: Int, yaw: Double = 0, x: Double = 0, world: Int = 1, pitchDown: Double = 0,
                      width: Int = 1000, height: Int = 800) -> FramePose {
        let angle = yaw * Double.pi / 180, c = cos(angle), s = sin(angle)
        let pitch = pitchDown * Double.pi / 180, cp = cos(pitch), sp = sin(pitch)
        let w = Double(width), h = Double(height), focal = 0.55 * w
        return .init(id: .init(session: session, world: world, frame: index), time: Double(index),
                     transform: [c,0,s,0, s*sp,cp,-c*sp,0, -s*cp,sp,c*cp,0, x,1.4,0,1],
                     intrinsics: [focal,0,0, 0,focal,0, w/2,h/2,1], width: width, height: height, exif: 1, tracking: "normal")
    }
    private func sighting(_ box: ImageBox, label: String? = nil, meaning: SignMeaning? = nil) -> Sighting {
        .init(kind: .sign, box: box, confidence: 0.9, label: label, sign: meaning)
    }
    private func projected(_ point: V3, at pose: FramePose) throws -> ImageBox {
        let (u, v) = try XCTUnwrap(pose.project(point))
        return .init(u-0.04, v-0.02, u+0.04, v+0.02)
    }
    private func record(_ id: Int, in book: LandmarkBook) throws -> Landmark {
        try XCTUnwrap(book.records.first { $0.id == id })
    }

    func testLegacySightingAndUnicodeContract() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let old = Data(#"{"kind":"sign","box":[0.1,0.1,0.4,0.4],"confidence":0.9,"label":"BSG33"}"#.utf8)
        XCTAssertNil(try decoder.decode(Sighting.self, from: old).sign)
        XCTAssertEqual(Set(SignSymbol.allCases.map(\.rawValue)), Set(["room","elevator","exit","restroom","accessible","directory","clinic","shop","stairs","unknown"]))
        for direction in SignArrow.allCases {
            let sign = SignMeaning(symbol: .room, text: "BSG35", arrow: direction)
            let item = sighting(center, meaning: sign)
            XCTAssertEqual(try decoder.decode(Sighting.self, from: encoder.encode(item)), item)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(sign)) as? [String: String])
            XCTAssertEqual(json["arrow"], direction.rawValue)
        }
        XCTAssertEqual(try decoder.decode(SignMeaning.self, from: Data(#"{"symbol":"elevator"}"#.utf8)), SignMeaning(symbol: .elevator))
    }

    func testLateBackfillOfMiddleFrameKeepsNewestGeometryAndBothIdentities() throws {
        var book = LandmarkBook()
        let a = V3(-0.15,1.4,-3), b = V3(0.15,1.4,-3)
        func observePair(_ p: FramePose) throws -> [Int] {
            let left = try XCTUnwrap(book.observe(sighting(try projected(a, at: p), label: "BSG33"), at: p))
            let right = try XCTUnwrap(book.observe(sighting(try projected(b, at: p), label: "BSG35"), at: p, excluding: [left]))
            return [left, right]
        }
        let ids = try observePair(pose(1)), capture = pose(2, yaw: 8, x: 0.18), live = pose(3, yaw: -12, x: 0.55)
        XCTAssertEqual(try observePair(capture), ids)
        XCTAssertEqual(try observePair(live), ids)
        let before = try record(ids[0], in: book), other = try record(ids[1], in: book)
        XCTAssertNotNil(before.point)
        let printed = SignMeaning(symbol: .room, text: "BSG33")
        let oldObservation = sighting(try projected(a, at: capture), meaning: printed)
        XCTAssertNil(book.registerSemanticSign(oldObservation, at: capture, localMatch: ids[1]))
        XCTAssertNil(book.registerSemanticSign(oldObservation, at: pose(4), localMatch: ids[0]))
        XCTAssertNil(book.registerSemanticSign(oldObservation, at: pose(2, world: 2), localMatch: ids[0]))
        for _ in 0..<2 { XCTAssertEqual(book.registerSemanticSign(oldObservation, at: capture, localMatch: ids[0]), ids[0]) }
        let after = try record(ids[0], in: book)
        XCTAssertEqual(after.sign, printed)
        XCTAssertEqual(after.last, before.last); XCTAssertEqual(after.first, before.first)
        XCTAssertEqual(after.ray, before.ray); XCTAssertEqual(after.firstRay, before.firstRay)
        XCTAssertEqual(after.point, before.point); XCTAssertEqual(after.box, before.box)
        XCTAssertEqual(after.count, before.count); XCTAssertEqual(after.confidence, before.confidence)
        XCTAssertEqual(after.label, "BSG33"); XCTAssertEqual(try record(ids[1], in: book), other)
    }

    func testUnmatchedRowsShareTheMapAndRetainSeparateIDs() throws {
        var book = LandmarkBook(); let p = pose(1)
        let rowA = ImageBox(0.45,0.46,0.55,0.48), rowB = ImageBox(0.45,0.49,0.55,0.51)
        let a = sighting(rowA, meaning: .init(symbol: .room, text: "BSG33"))
        let b = sighting(rowB, meaning: .init(symbol: .room, text: "BSG35"))
        let left = try XCTUnwrap(book.registerSemanticSign(a, at: p, localMatch: nil))
        let right = try XCTUnwrap(book.registerSemanticSign(b, at: p, localMatch: nil))
        XCTAssertNotEqual(left, right); XCTAssertGreaterThan(left, 0); XCTAssertGreaterThan(right, 0)
        XCTAssertEqual(book.registerSemanticSign(a, at: p, localMatch: nil), left)
        XCTAssertEqual(book.records.count, 2)
        XCTAssertNil(try record(left, in: book).label)
        XCTAssertEqual(book.observe(sighting(rowB, label: "BSG35"), at: pose(2)), right)
        XCTAssertEqual(try record(right, in: book).label, "BSG35")
        XCTAssertEqual(book.records.count, 2)
    }

    func testDisplayAndSpeechUsePrintedRoomAndIndividualMandarinDigits() throws {
        var book = LandmarkBook(); let p = pose(1)
        let id = try XCTUnwrap(book.observe(sighting(center, label: "BSG33"), at: p))
        let label = try XCTUnwrap(record(id, in: book).signReadout(at: p, target: "BSG33"))
        XCTAssertTrue(label.contains("BSG33")); XCTAssertFalse(label.contains("三三"))
        XCTAssertTrue(SignReading.spoken(label).contains("BSG三三"))
        XCTAssertFalse(label.contains("到达"))
    }

    func testVisibleBSG33InRightOfRTRFrameKeepsItsTextThroughPoseJitter() throws {
        let right = "手机右侧有标牌。牌面文字提到「BSG33」。"
        for pitch in [0.0, -12.0] {
            var book = LandmarkBook()
            let capture = pose(1, pitchDown: pitch, width: 720, height: 1280)
            let id = try XCTUnwrap(book.observe(sighting(rtr1RoomBox, label: "BSG33"), at: capture))
            let sign = try record(id, in: book)
            if pitch == 0 { XCTAssertEqual(try XCTUnwrap(sign.bearing(at: capture)), 20, accuracy: 1) }
            XCTAssertEqual(sign.signReadout(at: capture, target: "BSG33"), right)
            for yaw in [-3.0, 3.0] {
                let current = pose(2, yaw: yaw, pitchDown: pitch, width: 720, height: 1280)
                XCTAssertEqual(sign.signReadout(at: current, target: "BSG33"), right)
            }
            let away = pose(2, yaw: -65, pitchDown: pitch, width: 720, height: 1280)
            XCTAssertEqual(sign.signReadout(at: away, target: "BSG33"), "请转动手机，查看右侧的标牌。")
            let moved = pose(2, x: 2, pitchDown: pitch, width: 720, height: 1280)
            XCTAssertEqual(sign.signReadout(at: moved, target: "BSG33"), "位置已变化，请转动手机重新查看标牌。")
        }
    }

    func testDelayedBSG33ReadoutAtOriginalViewAndAfterMoving() throws {
        var book = LandmarkBook()
        func frame(_ time: Int, yaw: Double = 0, x: Double = 0, pitch: Double = 0) -> FramePose {
            pose(time, yaw: yaw, x: x, pitchDown: pitch, width: 720, height: 1280)
        }
        let capture = frame(1)
        let id = try XCTUnwrap(book.observe(sighting(rtr1RoomBox, label: "BSG33"), at: capture))
        let sign = try record(id, in: book)
        XCTAssertEqual(sign.signReadout(at: frame(3), target: "BSG33"), "手机右侧有标牌。牌面文字提到「BSG33」。")
        for receipt in [frame(5), frame(7, yaw: -3, x: 0.05), frame(9, yaw: 3, x: -0.06)] {
            XCTAssertEqual(sign.signReadout(at: receipt, target: "BSG33"), "刚才在手机右侧读到标牌。牌面文字提到「BSG33」。")
        }
        let recentered = frame(7, yaw: 20)
        XCTAssertTrue(try XCTUnwrap(sign.projectedBox(at: recentered)).valid)
        XCTAssertEqual(sign.signReadout(at: recentered, target: "BSG33"), "请转动手机重新查看标牌。")
        XCTAssertEqual(sign.signReadout(at: frame(7, yaw: -65), target: "BSG33"), "请转动手机，查看右侧的标牌。")
        XCTAssertEqual(sign.signReadout(at: frame(7, x: 2), target: "BSG33"), "位置已变化，请转动手机重新查看标牌。")

        // The phone tilts only 8° and the text centre still projects inside, but its top is clipped.
        let clipped = frame(7, pitch: 8)
        let footprint = try XCTUnwrap(sign.projectedBox(at: clipped))
        XCTAssertTrue(clipped.sameView(as: capture, within: 12))
        XCTAssertTrue((0...1).contains(footprint.center.1))
        XCTAssertLessThan(footprint.top, 0)
        XCTAssertEqual(sign.signReadout(at: clipped, target: "BSG33"), "请转动手机，查看右侧的标牌。")
        XCTAssertNil(sign.signReadout(at: frame(121), target: "BSG33"))
    }

    func testLeftReadoutRequiresWholeTextToRemainInView() throws {
        var book = LandmarkBook(); let capture = pose(1)
        let id = try XCTUnwrap(book.observe(sighting(center, label: "BSG33"), at: capture))
        let sign = try record(id, in: book)
        XCTAssertEqual(sign.signReadout(at: pose(2, yaw: 24), target: "BSG33"), "手机左侧有标牌。牌面文字提到「BSG33」。")
        // The centre remains inside at 40°, but the beginning of the inscription has left the image.
        XCTAssertEqual(sign.signReadout(at: pose(2, yaw: 40), target: "BSG33"), "请转动手机，查看左侧的标牌。")
        let lookingDown = pose(2, pitchDown: 55)
        XCTAssertEqual(sign.signReadout(at: lookingDown, target: "BSG33"), "请转动手机重新查看标牌。")
    }

    func testRotationTranslationTrackingWorldAndExpiry() throws {
        var book = LandmarkBook(); let capture = pose(1)
        let meaning = SignMeaning(symbol: .elevator, text: "LEVEL G", arrow: .left)
        let id = try XCTUnwrap(book.registerSemanticSign(sighting(center, meaning: meaning), at: capture, localMatch: nil))
        let sign = try record(id, in: book)
        let face = try XCTUnwrap(sign.signReadout(at: capture, target: "电梯"))
        XCTAssertTrue(face.contains("电梯")); XCTAssertTrue(face.contains("牌上箭头向左"))
        XCTAssertNil(sign.signReadout(at: capture, target: "洗手间"))
        let lookingLeft = try XCTUnwrap(sign.signReadout(at: pose(2, yaw: -48), target: "电梯"))
        XCTAssertEqual(lookingLeft, "请转动手机，查看右侧的标牌。")
        XCTAssertEqual(sign.signReadout(at: pose(2, yaw: 65), target: "电梯"), "请转动手机，查看左侧的标牌。")
        let shifted = try XCTUnwrap(sign.signReadout(at: pose(3, x: 2), target: "电梯"))
        XCTAssertEqual(shifted, "位置已变化，请转动手机重新查看标牌。")
        var lost = pose(4); lost.tracking = "limited"
        for invalid in [lost, pose(2, world: 2), pose(0), pose(121)] { XCTAssertNil(sign.signReadout(at: invalid, target: "电梯")) }
        book.expire(at: 122)
        XCTAssertTrue(book.records.isEmpty)
        XCTAssertNil(book.registerSemanticSign(sighting(center, meaning: meaning), at: capture, localMatch: nil))
    }

    func testRangeDirectoryReadsOnlyTheTargetRow() throws {
        // Lines from rtr2 00:25.5. The ↓ and ↑ are printed on different rows.
        var book = LandmarkBook(); let p = pose(1)
        let board = "GF\n↓ BSG01 - BSG34\n↑ BSG35 - BSG58"
        let id = try XCTUnwrap(book.observe(sighting(center, label: board), at: p))
        let sign = try record(id, in: book)
        let first = try XCTUnwrap(sign.signReadout(at: p, target: "BSG33"))
        let next = try XCTUnwrap(sign.signReadout(at: p, target: "BSG35"))
        XCTAssertTrue(first.contains("BSG01–BSG34")); XCTAssertTrue(first.contains("箭头向下方")); XCTAssertFalse(first.contains("向前方"))
        XCTAssertTrue(next.contains("BSG35–BSG58")); XCTAssertTrue(next.contains("箭头向前方")); XCTAssertFalse(next.contains("向下方"))
    }

    func testKnownReferenceConflictAndOutOfOrderReplay() throws {
        var book = LandmarkBook(); let a = pose(1), b = pose(2)
        let local = sighting(center, label: "LEVEL G")
        let id = try XCTUnwrap(book.observe(local, at: a)); XCTAssertEqual(book.observe(local, at: b), id)
        let left = sighting(center, meaning: .init(symbol: .elevator, text: "LEVEL G", arrow: .left))
        let down = sighting(center, meaning: .init(symbol: .elevator, text: "LEVEL G", arrow: .down))
        XCTAssertEqual(book.registerSemanticSign(down, at: b, localMatch: id), id)
        XCTAssertEqual(book.registerSemanticSign(left, at: a, localMatch: id), id)
        XCTAssertEqual(try record(id, in: book).sign?.arrow, .down)
        XCTAssertEqual(book.registerSemanticSign(left, at: b, localMatch: id), id)
        XCTAssertEqual(book.registerSemanticSign(down, at: b, localMatch: id), id)
        let conflict = try record(id, in: book)
        XCTAssertNil(conflict.sign)
        let cue = try XCTUnwrap(conflict.signReadout(at: b, target: "电梯")); XCTAssertTrue(cue.contains("核对")); XCTAssertFalse(cue.contains("箭头"))
    }

    func testSemanticAgeDoesNotResetWhenOnlyGeometryIsRefreshed() throws {
        var book = LandmarkBook(); let a = pose(1)
        let local = sighting(center, label: "LEVEL G")
        let id = try XCTUnwrap(book.observe(local, at: a))
        let cloud = sighting(center, meaning: .init(symbol: .elevator, text: "LEVEL G", arrow: .left))
        XCTAssertEqual(book.registerSemanticSign(cloud, at: a, localMatch: id), id)
        XCTAssertEqual(book.observe(local, at: pose(100)), id)
        XCTAssertNil(try record(id, in: book).signReadout(at: pose(122), target: "电梯"))
    }

    func testDirectoryArrowRequiresTheTargetRowAndAgreesWithLocalPrint() throws {
        var book = LandmarkBook(); let p = pose(1)
        let upper = ImageBox(0.4, 0.42, 0.6, 0.46), lower = ImageBox(0.4, 0.48, 0.6, 0.52)
        let first = try XCTUnwrap(book.observe(sighting(upper, label: "↓ BSG01 - BSG34"), at: p))
        let second = try XCTUnwrap(book.observe(sighting(lower, label: "BSG35 - BSG58"), at: p, excluding: [first]))
        let row = SignMeaning(symbol: .directory, text: "BSG35 - BSG58", arrow: .ahead)
        for _ in 0..<2 { XCTAssertEqual(book.registerSemanticSign(sighting(lower, meaning: row), at: p, localMatch: second), second) }
        let detail = try XCTUnwrap(record(second, in: book).signReadout(at: p, target: "BSG35"))
        XCTAssertTrue(detail.contains("BSG35–BSG58")); XCTAssertTrue(detail.contains("牌上箭头向前方"))

        let large = sighting(.init(0.38, 0.40, 0.62, 0.55), meaning: row)
        XCTAssertNil(book.registerSemanticSign(large, at: p, localMatch: second))
        let board = try XCTUnwrap(book.registerSemanticSign(large, at: p, localMatch: nil))
        XCTAssertEqual(book.registerSemanticSign(large, at: p, localMatch: nil), board)
        XCTAssertEqual(Set([first, second, board]).count, 3)
        XCTAssertNil(try record(board, in: book).sign?.arrow)
        XCTAssertFalse(try XCTUnwrap(record(board, in: book).signReadout(at: p, target: "BSG35")).contains("箭头"))

        // Give the second row's direction to the first to exercise conflicting evidence.
        let conflicting = SignMeaning(symbol: .directory, text: "BSG01 - BSG34", arrow: .ahead)
        XCTAssertEqual(book.registerSemanticSign(sighting(upper, meaning: conflicting), at: p, localMatch: first), first)
        let disputed = try record(first, in: book)
        XCTAssertNil(disputed.sign)
        let recheck = try XCTUnwrap(disputed.signReadout(at: p, target: "BSG33"))
        XCTAssertTrue(recheck.contains("核对")); XCTAssertFalse(recheck.contains("箭头"))

        var earlyCloud = LandmarkBook()
        let earlyID = try XCTUnwrap(earlyCloud.registerSemanticSign(sighting(upper, meaning: conflicting), at: p, localMatch: nil))
        XCTAssertEqual(earlyCloud.observe(sighting(upper, label: "↓ BSG01 - BSG34"), at: pose(2)), earlyID)
        XCTAssertNil(try record(earlyID, in: earlyCloud).sign)
    }

    func testExactLocalPlateWinsConflictingCloudRoom() throws {
        var book = LandmarkBook(); let p = pose(1)
        let id = try XCTUnwrap(book.observe(sighting(center, label: "BSG33"), at: p))
        let other = sighting(center, meaning: .init(symbol: .room, text: "BSG35"))
        XCTAssertEqual(book.registerSemanticSign(other, at: p, localMatch: id), id)
        let sign = try record(id, in: book)
        XCTAssertEqual(sign.label, "BSG33"); XCTAssertNil(sign.sign)
        for target in ["BSG33", "BSG35"] {
            let cue = try XCTUnwrap(sign.signReadout(at: p, target: target))
            XCTAssertTrue(cue.contains("BSG33")); XCTAssertTrue(cue.contains("核对"))
            XCTAssertFalse(cue.contains("BSG35")); XCTAssertFalse(cue.contains("到达"))
        }
    }

    func testGeometryOnlyUpdateCannotExtendLocalPlateReading() throws {
        var book = LandmarkBook(); let id = try XCTUnwrap(book.observe(sighting(center, label: "BSG33"), at: pose(1)))
        XCTAssertEqual(book.observe(sighting(center), at: pose(100)), id)
        let landmark = try record(id, in: book)
        XCTAssertNotNil(landmark.signReadout(at: pose(120), target: "BSG33"))
        XCTAssertNil(landmark.signReadout(at: pose(121), target: "BSG33"))
    }

    func testBoxRefreshKeepsOriginalReadingTimeAndViewForLocalOCRAndBackfill() throws {
        for backfill in [false, true] {
            var book = LandmarkBook()
            let capture = pose(1), receipt = pose(7)
            let row = sighting(center, label: backfill ? nil : "BSG33")
            let id = try XCTUnwrap(book.observe(row, at: capture))
            XCTAssertEqual(book.observe(sighting(center), at: receipt), id)
            if backfill {
                let sign = sighting(center, meaning: .init(symbol: .room, text: "BSG33"))
                XCTAssertEqual(book.registerSemanticSign(sign, at: capture, localMatch: id), id)
            }
            let sign = try record(id, in: book)
            XCTAssertEqual(sign.last, receipt)
            XCTAssertEqual(sign.signReadout(at: receipt, target: "BSG33"), "刚才在手机前方读到标牌。牌面文字提到「BSG33」。")

            let turned = pose(8, yaw: 16)
            let box = try XCTUnwrap(sign.projectedBox(at: turned))
            XCTAssertEqual(book.observe(sighting(box), at: turned), id)
            XCTAssertEqual(try record(id, in: book).signReadout(at: turned, target: "BSG33"), "请转动手机重新查看标牌。")
            XCTAssertEqual(book.observe(sighting(box, label: "BSG33"), at: turned), id)
            XCTAssertEqual(try record(id, in: book).signReadout(at: turned, target: "BSG33"), "手机左侧有标牌。牌面文字提到「BSG33」。")
        }
    }

    func testTriangulatedSignUsesCurrentBearingAfterLateralMotion() throws {
        var book = LandmarkBook(); let physical = V3(0, 1.4, -3)
        let a = pose(1), b = pose(2, x: 0.6), now = pose(3, x: 2)
        let id = try XCTUnwrap(book.observe(sighting(try projected(physical, at: a), label: "BSG33"), at: a))
        XCTAssertEqual(book.observe(sighting(try projected(physical, at: b), label: "BSG33"), at: b), id)
        let sign = try record(id, in: book)
        XCTAssertLessThan((try XCTUnwrap(sign.point) - physical).length, 0.01)
        XCTAssertEqual(sign.signReadout(at: now, target: "BSG33"), "请转动手机，查看左侧的标牌。")
        let bearing = try XCTUnwrap(sign.bearing(at: now))
        XCTAssertTrue(try XCTUnwrap(sign.signReadout(at: pose(4, yaw: bearing, x: 2), target: "BSG33")).contains("BSG33"))
    }

    func testRestrictionPredicateSelectsOnlyItsOwnTextBox() throws {
        // Approximate Vision bounds of the room plate and notice in the 720 × 1280 RTR2 still at 00:51.5.
        let room = SignLine("BSG35", bounds: CGRect(x: 0.22, y: 0.82, width: 0.18, height: 0.03))
        let notice = SignLine("Staff Only", bounds: CGRect(x: 0.31, y: 0.625, width: 0.125, height: 0.019))
        let lines = [room, notice], goal = Destination.room("BSG35")
        XCTAssertEqual(lines.filter { WayfindingParser.isRestriction($0.text) }.map(\.bounds), [notice.bounds])
        for label in ["BSG33", "BSG35", "LEVEL G"] { XCTAssertFalse(WayfindingParser.isRestriction(label)) }
        XCTAssertTrue(WayfindingParser.isRestriction(notice.text.lowercased()))
        for (inputs, restricted) in [([room], false), (lines, true), ([SignLine(notice.text, confidence: 0.4)], false)] {
            let frame = FrameResult(lines: inputs, reading: SignParser.analyze(inputs, for: goal))
            XCTAssertEqual(WayfindingParser.read(frame, for: goal).restricted, restricted)
        }
        var book = LandmarkBook(); let p = pose(1)
        let id = try XCTUnwrap(book.registerSemanticSign(sighting(center, meaning: .init(symbol: .room, text: notice.text)), at: p, localMatch: nil))
        XCTAssertEqual(try record(id, in: book).signReadout(at: p, target: "BSG35"), "手机前方有标牌。牌上有限制提示，请核对现场原文。")
    }

    #if os(macOS) && canImport(Vision)
    func testReadoutFromRealRTRRoomPhotoAfterTurningAndMoving() throws {
        guard let dir = ProcessInfo.processInfo.environment["PATHSENSE_REAL_FRAMES_DIR"] else {
            throw XCTSkip("Set PATHSENSE_REAL_FRAMES_DIR to the original RTR video stills for pixel replay.")
        }
        for (filename, room, side) in [("rtr1-70.2.jpg", "BSG33", "右侧"), ("rtr2-51.5.jpg", "BSG35", "左侧")] {
            let jpeg = URL(fileURLWithPath: dir).appendingPathComponent(filename)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(url: jpeg).perform([request])
            let hit = try XCTUnwrap(request.results?.first { observation in
                let tokens = observation.topCandidates(1).first?.string.uppercased().components(separatedBy: .alphanumerics.inverted)
                return tokens?.contains(room) == true
            }, filename)
            let text = try XCTUnwrap(hit.topCandidates(1).first)
            let bounds = hit.boundingBox
            let box = ImageBox(bounds.minX, 1-bounds.maxY, bounds.maxX, 1-bounds.minY)
            var nav = SpatialNavigator(doorTarget: true)
            func frame(_ index: Int, yaw: Double = 0, x: Double = 0) -> FramePose { pose(index, yaw: yaw, x: x, width: 720, height: 1280) }
            let capture = frame(1)
            nav.pose(capture)
            // The phone has already delivered newer poses when OCR of the original JPEG returns.
            let receipt = frame(7, yaw: 2, x: 0.04)
            nav.pose(receipt)
            // Keep Vision's measured confidence. Supply the independently transcribed meaning as a relay reply.
            let local = Sighting(kind: .sign, box: box, confidence: Double(text.confidence), label: text.string)
            let localID = nav.register([local], at: capture, local: true)[0]
            let backfill = sighting(box, meaning: .init(symbol: .room, text: room))
            let id = try XCTUnwrap(nav.register([backfill], at: capture, local: false, capturedSigns: localID.map { [(local, $0)] } ?? [])[0])
            let sign = try XCTUnwrap(nav.record(id)), toward = try XCTUnwrap(sign.bearing(at: capture))
            if room == "BSG33" {
                XCTAssertEqual(box.center.0, 0.70, accuracy: 0.03)
                XCTAssertEqual(toward, 20, accuracy: 3)
            }
            XCTAssertEqual(sign.signReadout(at: capture, target: room), "手机\(side)有标牌。牌面文字提到「\(room)」。")
            XCTAssertEqual(sign.signReadout(at: receipt, target: room), "刚才在手机\(side)读到标牌。牌面文字提到「\(room)」。")
            XCTAssertEqual(sign.signReadout(at: frame(2, yaw: toward), target: room), "手机前方有标牌。牌面文字提到「\(room)」。")
            XCTAssertEqual(sign.signReadout(at: frame(3, yaw: toward+65), target: room), "请转动手机，查看左侧的标牌。")
            let moved = frame(9, yaw: toward+65, x: 2)
            nav.pose(moved)
            XCTAssertEqual(sign.signReadout(at: moved, target: room), "位置已变化，请转动手机重新查看标牌。")
            XCTAssertNotEqual(nav.cue()?.kind, .advance)
            XCTAssertFalse(nav.manualDoorArrival()); XCTAssertFalse(nav.arrived)
        }
    }
    #endif
}
