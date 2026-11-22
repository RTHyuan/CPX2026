import XCTest
@testable import PathSenseCore

final class WayfindingTests: XCTestCase {
    private func frame(_ lines: [SignLine], _ target: Destination) -> FrameResult {
        FrameResult(lines: lines, reading: SignParser.analyze(lines, for: target))
    }
    private func sign(_ lines: [String], _ target: Destination) -> WayfindingSigns {
        WayfindingParser.read(frame(lines.map { SignLine($0) }, target), for: target)
    }
    private let clinic = Destination(wayfinding: "屈光检查室")!
    func testRepeatedPrintedRoomUsesItsCaptionAndPreservesTheVotingBoundary() throws {
        // Fast Vision rectangles from the two printed rows in rtr1 at 70.2 s.
        let box = CGRect(x: 0.557, y: 0.829, width: 0.296, height: 0.055)
        let caption = CGRect(x: 0.542, y: 0.708, width: 0.338, height: 0.026)
        let row = SignLine("BSG33", confidence: 0.5, bounds: box)
        let second = SignLine("ROOM- BSG33", confidence: 0.5, bounds: caption)
        XCTAssertEqual(try XCTUnwrap(WayfindingParser.printedRoomPair(in: [row, second])).number.text, row.text)
        for invalid in [[row], [row, SignLine("ROOM- BSG35", bounds: caption)],
                        [row, SignLine(second.text, bounds: box)], [row, second, SignLine("Staff Only")]] {
            XCTAssertNil(WayfindingParser.printedRoomPair(in: invalid))
        }
        let boundary = SignLine("BSG33", confidence: Float(0.78))
        XCTAssertEqual(boundary.landmarkConfidence, 0.78)
        XCTAssertLessThan(SignLine("BSG33", confidence: Float(0.78).nextDown).landmarkConfidence, 0.78)
    }

    func testFreeInputKeepsNamesAndRoomIdentity() {
        XCTAssertEqual(Destination(wayfinding:"带我去纸舟咖啡")?.text,"纸舟咖啡")
        XCTAssertEqual(Destination(wayfinding:"FIND Oak & Iris")?.text,"Oak & Iris")
        XCTAssertEqual(Destination(wayfinding:"我要去零四零二教室")?.text,"0402")
        XCTAssertNil(Destination(wayfinding:"   ")); XCTAssertNil(Destination(wayfinding:"///"))
    }
    func testRowsUseGeometryAndDoNotBorrowArrowsOrFloors() {
        func line(_ text: String, x: Double, y: Double, width: Double) -> SignLine { SignLine(text, bounds:CGRect(x:x,y:y,width:width,height:0.08)) }
        let pieces = [line("导览",x:0.12,y:0.8,width:0.28),line("→",x:0.68,y:0.40,width:0.08),line("←",x:0.68,y:0.58,width:0.08),
                      line("3F",x:0.12,y:0.59,width:0.12),line("屈光检查室",x:0.31,y:0.58,width:0.27),
                      line("B2",x:0.12,y:0.40,width:0.12),line("配镜中心",x:0.31,y:0.40,width:0.27)]
        let facts = WayfindingParser.read(frame(pieces,clinic),for:clinic)
        XCTAssertEqual(facts.target,.listed(RouteSite(level:"3F",arrow:.left))); XCTAssertNil(facts.currentLevel)
    }
    func testStandaloneFloorAndGroupedDirectories() {
        let signs = sign(["门诊目录","二层","皮肤科","地下二层","屈光检查室"],clinic)
        XCTAssertEqual(signs.target,.listed(RouteSite(level:"B2"))); XCTAssertNil(signs.currentLevel)
        XCTAssertEqual(sign(["您在此 一层","门诊目录","地下二层 屈光检查室"],clinic).currentLevel,"1F")
        XCTAssertEqual(sign(["十六楼"],clinic).currentLevel,"16F")
        XCTAssertEqual(sign(["LEVEL B2"],clinic).currentLevel,"B2")
    }
    func testRoomBookingPlaqueWithUnrelatedCopyOnlyRecordsAnUnambiguousInscription() {
        let goal = Destination.facility(.restroom)
        let wording = ["BSG 33", "ROOM - BSG33", "Please Scan the Code to Check Room Availability"]
        let facts = sign(wording, goal)
        XCTAssertEqual(facts.nearbyRoom, "BSG33")
        XCTAssertNil(facts.target)
        var journey = WayfindingJourney(target: goal)
        journey.observe(facts)
        XCTAssertEqual(journey.plannerScene, .unknown)
        XCTAssertEqual(journey.target, goal)
        XCTAssertNil(journey.action)
        XCTAssertNil(sign(["BSG 34", "ROOM - BSG33", "Check room availability"], goal).nearbyRoom)
        XCTAssertNil(sign(wording + ["ROOM - BSG32"], goal).nearbyRoom)
    }
    func testSparseObservationsCanStartInTheMiddleOnTheSameFloor() {
        var journey = WayfindingJourney(target:clinic)
        journey.observe(sign(["L7"],clinic)); journey.observe(sign(["导览","7F 屈光检查室 →"],clinic))
        XCTAssertEqual(journey.stage,.corridor); XCTAssertTrue(journey.cue.contains("右"))
        journey.observe(sign(["屈光检查室"],clinic)); XCTAssertEqual(journey.stage,.verify)
        journey.confirm(); XCTAssertEqual(journey.stage,.arrived)
    }
    func testWrongFloorConflictsAndUserConfirmation() {
        var j = WayfindingJourney(target:clinic)
        j.observe(sign(["楼层目录","6F 屈光检查室"],clinic)); XCTAssertEqual(j.stage,.transfer)
        j.observe(sign(["3F"],clinic)); XCTAssertEqual(j.stage,.transfer)
        j.observe(sign(["屈光检查室"],clinic)); XCTAssertNil(j.action); XCTAssertEqual(j.stage,.transfer)
        j.observe(sign(["6F"],clinic)); j.observe(sign(["屈光检查室"],clinic)); XCTAssertEqual(j.action,.atDestination)
        j.observe(sign(["禁止进入","屈光检查室"],clinic)); j.confirm(); XCTAssertNotEqual(j.stage,.arrived)
        j.observe(sign(["屈光检查室"],clinic)); j.confirm(); XCTAssertEqual(j.stage,.arrived)
    }
    func testAmbiguousSitesAndSpuriousSubstrings() {
        XCTAssertEqual(sign(["目录","3F 屈光检查室","5F 屈光检查室"],clinic).target,.ambiguous)
        XCTAssertEqual(sign(["目录","3F 屈光检查室 ← →"],clinic).target,.ambiguous)
        XCTAssertNil(sign(["屈光检查室培训海报"],clinic).target)
        let room = Destination(wayfinding:"402")!
        XCTAssertNil(sign(["ROOM 4020"],room).target); XCTAssertNil(sign(["ROOM 208"],room).currentLevel)
    }
    func testPlaceChoiceGroundedInTheObservedDirectory() {
        let target = Destination(wayfinding:"咖啡")!; var j = WayfindingJourney(target:target)
        j.observe(sign(["商场导览","B1 纸舟咖啡","L3 山林咖啡"],target)); XCTAssertEqual(j.choices.count,2); XCTAssertNil(j.site.level)
        j.choose(RouteChoice(name:"虚构咖啡",site:RouteSite(level:"99F"))); XCTAssertNil(j.resolvedName)
        j.choose(j.choices[0]); XCTAssertEqual(j.searchTarget.text,"纸舟咖啡"); XCTAssertEqual(j.site.level,"B1")
        j.observe(sign(["B1"],j.searchTarget)); j.observe(sign(["山林咖啡"],j.searchTarget)); XCTAssertNil(j.action)
        j.observe(sign(["纸舟咖啡"],j.searchTarget)); XCTAssertEqual(j.action,.atDestination)
    }
    func testDoorRequiresConfirmationAndRelocalizationClearsOldDestinationFloor() {
        var j = WayfindingJourney(target:clinic); j.observe(WayfindingSigns(scene:SceneClues(setting:.room,door:"左侧")))
        XCTAssertEqual(j.stage,.doorway); XCTAssertEqual(j.action,.crossed); j.confirm(); XCTAssertEqual(j.stage,.orient)
        j.observe(sign(["ROOM 208"],clinic)); XCTAssertEqual(j.originRoom,"208"); XCTAssertNil(j.currentLevel)
        j.observe(sign(["目录","5F 屈光检查室"],clinic)); j.relocalize(); XCTAssertNil(j.site.level); XCTAssertNil(j.currentLevel)
    }
    func testOffsetBilingualHeadingsWithoutDirectoryTitle() {
        let name = Destination(wayfinding: "Radiology")!
        func line(_ text: String, _ x: Double, _ y: Double) -> SignLine {
            SignLine(text, bounds: CGRect(x: x, y: y, width: 0.20, height: 0.025))
        }
        let lines = [line("三樓", 0.1, 0.90), line("3rd Floor", 0.56, 0.81),
                     line("二樓", 0.1, 0.71), line("Radiology", 0.56, 0.68),
                     line("2nd Floor", 0.56, 0.56), line("Billing", 0.56, 0.41)]
        let facts = WayfindingParser.read(frame(lines, name), for: name)
        XCTAssertEqual(facts.target, .listed(RouteSite(level: "3F")))
        XCTAssertNil(facts.currentLevel)
        XCTAssertEqual(sign(["Ground Floor"], name).currentLevel, "GF")
        XCTAssertEqual(sign(["Lower Ground Floor"], name).currentLevel, "LG")
        XCTAssertEqual(sign(["1st Floor"], name).currentLevel, "1F")
    }
    func testDestinationConfirmationNeedsFreshPlateAndKnownDirectoryFloor() {
        var route = WayfindingJourney(target: clinic)
        route.observe(sign(["目录", "5F 屈光检查室"], clinic))
        route.observe(sign(["屈光检查室"], clinic)); XCTAssertNil(route.action)
        route.observe(sign(["5F"], clinic)); route.observe(sign(["屈光检查室"], clinic))
        XCTAssertEqual(route.action, .atDestination)
        route.expireConfirmation(); route.confirm(); XCTAssertNotEqual(route.stage, .arrived)
    }
    func testBilingualNamesAndFloorPlatesKeepTheirMeaning() {
        let room = Destination(wayfinding: "手术室")!
        XCTAssertEqual(sign(["2nd Floor", "二樓"], room).currentLevel, "2F")
        XCTAssertNil(sign(["2F", "3F"], room).currentLevel)
        XCTAssertEqual(sign(["2F 手術室 Operating Theatres →"], room).target, .listed(RouteSite(level: "2F", arrow: .right)))
        XCTAssertEqual(sign(["手術室 Operating Theatres"], room).target, .plate)
        XCTAssertEqual(sign(["Operating Theatres / 手術室"], .named("Operating Theatres")).target, .plate)
        XCTAssertNil(sign(["手術室培訓中心 Training Centre"], room).target)
        let lift = sign(["電梯 LIFT →"], room)
        XCTAssertEqual(lift.transfer, "电梯"); XCTAssertEqual(lift.transferArrow, .right)
    }
    func testSameNameKeepsChosenBranchWhenPassingOtherDirectories() {
        let board = sign(["目录", "您在此 2F", "2F 屈光检查室", "4F 屈光检查室"], clinic)
        var route = WayfindingJourney(target: clinic)
        route.observe(board)
        XCTAssertEqual(route.currentLevel, "2F")
        let choice = route.choices.first { $0.site.level == "4F" }!
        route.choose(choice); route.observe(board)
        XCTAssertTrue(route.choices.isEmpty); XCTAssertEqual(route.site.level, "4F")
        route.observe(sign(["2F 屈光检查室 →"], clinic)); XCTAssertEqual(route.site.level, "4F")
        route.relocalize(); route.observe(board); XCTAssertEqual(route.choices.count, 2)
        let options = sign(["目录", "屈光检查室 ←", "屈光检查室 →"], clinic).choices
        XCTAssertEqual(Set(options.map(\.label)).count, 2)
    }
    func testContinuousVotingUsesResolvedRouteSemantics() {
        let left = sign(["屈光检查室 ←"],clinic), right = sign(["屈光检查室 →"],clinic)
        var gate = RouteEvidenceGate(now:0); XCTAssertFalse(gate.accept(left,at:0)); XCTAssertFalse(gate.accept(right,at:0.5)); XCTAssertTrue(gate.accept(right,at:1)); XCTAssertFalse(gate.accept(right,at:1.5))
        XCTAssertFalse(gate.accept(left,at:2)); XCTAssertFalse(gate.accept(left,at:8)); XCTAssertTrue(gate.accept(left,at:8.5))
        XCTAssertTrue(gate.accept(WayfindingSigns(),at:14)); XCTAssertFalse(gate.accept(WayfindingSigns(),at:15))
    }
}
