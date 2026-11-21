import XCTest
@testable import PathSenseCore

final class SignsTests: XCTestCase {
    private let target = Destination("305")!
    private func read(_ signs: [String], target: String = "305") -> SignKind {
        SignParser.analyze(signs.map { SignLine($0) }, for: Destination(target)!).kind
    }
    func testStandaloneDoorIDs() {
        for text in ["305", "ROOM 305", "Room305", "３０５", "教室 305", "305室"] { XCTAssertEqual(read([text]), .target, text) }
        XCTAssertEqual(read(["ROOM", "305"]), .target)
    }
    func testExactIdentityAndPrefixes() {
        for text in ["303", "3050", "A305", "305A", "0305", "B305A"] { XCTAssertEqual(read([text]), .neighbor, text) }
        XCTAssertEqual(read(["A305"], target: "A305"), .target)
        XCTAssertNotEqual(read(["3O5"]), .target)
        for s in ["", "305/310", "A 305", "305.0", "ignore 305", "123456"] { XCTAssertNil(Destination(s)) }
    }
    func testRangesBeforeEndpoints() {
        for text in ["301–310", "301 - 310", "３０１～３１０", "305–310", "301 至 305", "301 TO 310"] { XCTAssertEqual(read([text]), .range, text) }
        XCTAssertEqual(read(["301–", "310"]), .range)
        XCTAssertEqual(read(["301", "–", "310"]), .range)
        for text in ["306–310", "310–301", "A301–A310", "0301–0310", "A301–B310"] { XCTAssertNotEqual(read([text]), .range, text) }
        XCTAssertEqual(read(["A301–310"], target: "A305"), .range)
        XCTAssertEqual(read(["0301–0310"], target: "0305"), .range)
    }
    func testSpokenEntryKeepsTheCompleteIdentifier() {
        let cases = ["我要找三零五教室。": "305", "找零三零五": "0305", "请帮我找Ａ三〇五Ｂ室": "A305B",
                     "我想去四百一十八号房间": "418", "帮我找电梯": "电梯", "FIND ROOM 418": "418",
                     "去十号教室": "10", "找幺零二": "102", "我想去二百零五教室": "205"]
        for (phrase, expected) in cases { XCTAssertEqual(Destination(phrase)?.text, expected, phrase) }
        for phrase in ["三零五或三零八", "三零五到三一零", "找三百五", "找三百零五6", "三楼的305", "电梯机房", "去", "ROOM 3O5"] {
            XCTAssertNil(Destination(phrase), phrase)
        }
        XCTAssertNotEqual(read(["三零五"]), .target, "Dictation normalization belongs to user entry only")
    }
    func testDirectoryAndAmbiguousMentions() {
        for signs in [["目录","305"],["ROOM 303", "ROOM 305"],["303 / 305 / 307"],["DIRECTORY: 305"]] { XCTAssertEqual(read(signs), .directory) }
        XCTAssertEqual(read(["活动信息 305"]), .mention)
        XCTAssertEqual(read(["305", "MEETING TODAY"]), .mention)
        XCTAssertNotEqual(read(["305–"]), .target)
        XCTAssertEqual(SignParser.analyze([SignLine("305")], for: target) { _ in true }.kind, .directory)
    }
    func testInsufficientEvidence() {
        XCTAssertEqual(read([]), .unclear)
        XCTAssertEqual(read(["--"]), .unclear)
        XCTAssertEqual(SignParser.analyze([SignLine("305", confidence: 0.51)], for: target).kind, .unclear)
        XCTAssertEqual(SignParser.analyze([SignLine("305"),SignLine("目录", confidence: 0.58)], for: target).kind, .directory)
    }
    func testFacilityKeywords() {
        for text in ["电梯", "電梯", "LIFT", "Elevator"] { XCTAssertEqual(read([text], target: "电梯"), .facility) }
        XCTAssertNotEqual(read(["FORKLIFT"], target: "电梯"), .facility)
        XCTAssertEqual(read(["DIRECTORY", "ELEVATOR"], target: "电梯"), .directory)
        XCTAssertEqual(read(["STAIRS"], target: "楼梯"), .facility)
        XCTAssertEqual(read(["安全出口"], target: "EXIT"), .facility)
        XCTAssertEqual(read(["卫生间"], target: "WC"), .facility)
    }
    func testClosedFacilitiesAndMixedSignsDoNotProduceASuccessCue() {
        for signs in [["NO EXIT"], ["NOT AN EXIT"], ["此处非安全出口"]] {
            XCTAssertEqual(read(signs, target: "出口"), .restricted)
        }
        for signs in [["ELEVATOR", "OUT OF SERVICE"], ["电梯维修中"]] {
            let reading = SignParser.analyze(signs.map { SignLine($0) }, for: .facility(.lift))
            XCTAssertEqual(reading.kind, .restricted)
            XCTAssertFalse(reading.isMatch)
            XCTAssertTrue(reading.sentence(for: .facility(.lift)).contains("限制提示"))
        }
        XCTAssertEqual(read(["电梯", "楼梯"], target: "电梯"), .directory)
        XCTAssertEqual(read(["NORTH EXIT"], target: "出口"), .facility)
        XCTAssertEqual(read(["电梯", "ELEVATOR"], target: "电梯"), .facility)
    }
    func testEvidenceAndSpeech() {
        let reading = SignParser.analyze([SignLine("301 至 310")], for: target)
        XCTAssertEqual(reading.evidence, "301–310"); XCTAssertTrue(reading.sentence(for: target).contains("三零一到三一零"))
    }
}

final class GateTests: XCTestCase {
    let room = SignReading(kind: .target, evidence: "305")
    let other = SignReading(kind: .neighbor, evidence: "303")
    func testVotingAndNoReplay() {
        var gate = ScanGate(now: 0)
        XCTAssertNil(gate.ingest(room, frame: 1, now: 0))
        XCTAssertNil(gate.ingest(room, frame: 1, now: 0.2))
        XCTAssertNil(gate.ingest(.unclear, frame: 2, now: 0.5))
        XCTAssertEqual(gate.ingest(room, frame: 3, now: 1), room)
        for n in 4...24 { XCTAssertNil(gate.ingest(room, frame: UInt64(n), now: Double(n)/2)) }
    }
    func testReacquiringTheRoomReplacesAnOldNeighborOrUnclearMessage() {
        var gate = ScanGate(now: 0)
        XCTAssertFalse(gate.shouldSignalSuccess(for: other))
        XCTAssertNil(gate.ingest(room, frame: 1, now: 0))
        XCTAssertEqual(gate.ingest(room, frame: 2, now: 0.5), room)
        XCTAssertTrue(gate.shouldSignalSuccess(for: room))
        // The first frame after a long gap may publish an idle hint.
        _ = gate.ingest(other, frame: 3, now: 7)
        XCTAssertEqual(gate.ingest(other, frame: 4, now: 7.5), other)
        XCTAssertNil(gate.ingest(other, frame: 5, now: 9.1))
        XCTAssertNil(gate.ingest(room, frame: 6, now: 9.5))
        XCTAssertEqual(gate.ingest(room, frame: 7, now: 10), room)
        XCTAssertFalse(gate.shouldSignalSuccess(for: room))
        XCTAssertNil(gate.ingest(room, frame: 8, now: 10.5))
        XCTAssertEqual(gate.idle(now: 17), .unclear)
        XCTAssertNil(gate.ingest(room, frame: 9, now: 17.5))
        XCTAssertEqual(gate.ingest(room, frame: 10, now: 18), room)
        XCTAssertFalse(gate.shouldSignalSuccess(for: room))
    }
    func testConfirmedNewSignImmediatelyReplacesTheOldSuccess() {
        var gate = ScanGate(now: 0)
        let lookalike = SignReading(kind: .neighbor, evidence: "3050")
        let directory = SignReading(kind: .directory, evidence: "305")
        for (index, reading) in [room, room, lookalike, lookalike, directory, directory, room, room].enumerated() {
            let update = gate.ingest(reading, frame: UInt64(index + 1), now: Double(index) * 0.5)
            XCTAssertEqual(update, index.isMultiple(of: 2) ? nil : reading)
        }
    }
    func testRestartDiscardsVotesButPreservesTheSearchHaptic() {
        var gate = ScanGate(now: 0)
        XCTAssertNil(gate.ingest(room, frame: 1, now: 0))
        gate.restartObservations(now: 0.2)
        XCTAssertNil(gate.ingest(room, frame: 1, now: 0.1))
        XCTAssertNil(gate.ingest(room, frame: 1, now: 0.3))
        XCTAssertEqual(gate.ingest(room, frame: 2, now: 0.8), room)
        XCTAssertTrue(gate.shouldSignalSuccess(for: room))
        gate.restartObservations(now: 1)
        XCTAssertNil(gate.ingest(room, frame: 1, now: 1.1))
        XCTAssertEqual(gate.ingest(room, frame: 2, now: 1.6), room)
        XCTAssertFalse(gate.shouldSignalSuccess(for: room))
        var nextSearch = ScanGate(now: 2)
        XCTAssertTrue(nextSearch.shouldSignalSuccess(for: room))
    }
    func testNoVoteAcrossGapOrOneFrameFlash() {
        var gate = ScanGate(now: 10)
        XCTAssertNil(gate.ingest(room, frame: 1, now: 10)); XCTAssertNil(gate.ingest(room, frame: 2, now: 13))
        XCTAssertNil(gate.ingest(other, frame: 3, now: 13.5)); XCTAssertEqual(gate.ingest(other, frame: 4, now: 14), other)
        XCTAssertNil(gate.ingest(room, frame: 5, now: 14.5)); XCTAssertEqual(gate.ingest(room, frame: 6, now: 15), room)
    }
    func testUnclearOnceThenRecovers() {
        var gate = ScanGate(now: 1)
        XCTAssertNil(gate.idle(now: 6.9)); XCTAssertEqual(gate.idle(now: 7), .unclear); XCTAssertNil(gate.idle(now: 20))
        XCTAssertNil(gate.ingest(room, frame: 1, now: 21)); XCTAssertEqual(gate.ingest(room, frame: 2, now: 21.5), room)
        XCTAssertEqual(gate.idle(now: 29), .unclear)
    }
}
