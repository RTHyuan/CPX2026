import XCTest
@testable import PathSenseCore

final class GuidancePromptTests: XCTestCase {
    func testRoomNumbersAndRealFloorsSoundDifferent() {
        var route = WayfindingJourney(target: .room("0402"))
        route.observe(WayfindingSigns(nearbyRoom: "208"))
        XCTAssertTrue(route.cue.contains("门牌208"))
        XCTAssertEqual(route.prompt.speech, "记下门牌二零八。目的地是零四零二。请观察两侧，核对现在是在房间内还是走廊。")
        route.observe(WayfindingSigns(target: .listed(RouteSite(level: "4F"))))
        XCTAssertTrue(route.prompt.speech.contains("零四零二列在四楼"))
        route.observe(WayfindingSigns(currentLevel: "B1"))
        XCTAssertTrue(route.prompt.speech.contains("楼层牌是地下一层，目标在四楼"))
        let homograph: GuidancePrompt = "房号\("B1")在\(floor: "B1")。"
        XCTAssertEqual(homograph.speech, "房号B一在地下一层。")
    }
    func testHighFloorsGroundFloorAndBasements() {
        for (label, speech) in [("10F", "十楼"), ("12F", "十二楼"), ("20F", "二十楼"), ("31F", "三十一楼"), ("B12", "地下十二层"), ("GF", "地面层"), ("LG", "地面下层")] {
            XCTAssertEqual(Mandarin.floor(label), speech)
        }
    }
    func testVoiceSelectionExcludesNonMandarinFallbacks() {
        for language in ["en-US", "ja-JP", "yue-HK", "zh-HK", "zh-yue-CN"] { XCTAssertNil(Mandarin.voiceRank(language)) }
        XCTAssertEqual(Mandarin.voiceRank("zh_Hans_CN"), 0)
        XCTAssertEqual(Mandarin.voiceRank("zh-SG"), 1)
        XCTAssertEqual(Mandarin.voiceRank("zh-Hant-TW"), 2)
        XCTAssertNotNil(Mandarin.voiceRank("cmn"))
    }
}
