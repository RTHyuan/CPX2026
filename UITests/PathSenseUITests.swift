import XCTest
import UIKit
import Network

final class PathSenseUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Only the test runner carries these assets. The app receives pixels without labels.
    private func launch(_ files: [String] = [], state: String = "replay", hold: Int = 6, largeType: Bool = false, voice: Bool = false, trace: Bool = false, englishLocale: Bool = false, evidence: [[String:Any]] = []) throws {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", englishLocale ? "(en)" : "(zh-Hans)", "-AppleLocale", englishLocale ? "en_US" : "zh_CN", "-voice", voice ? "YES" : "NO"]
        if trace { app.launchEnvironment["PATHSENSE_TEST_FEEDBACK"] = "1" }
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if !evidence.isEmpty { app.launchEnvironment["PATHSENSE_TEST_EVIDENCE"] = String(decoding:try JSONSerialization.data(withJSONObject:evidence),as:UTF8.self) }
        app.launchEnvironment["PATHSENSE_TEST_CAMERA"] = state
        app.launchEnvironment["PATHSENSE_TEST_HOLD"] = "\(hold)"
        for (index, file) in files.enumerated() {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: file, withExtension: file == "route-door" ? "jpg" : "png", subdirectory: "Practice"))
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            let scale = min(1, 820 / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.68) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            app.launchEnvironment["PATHSENSE_TEST_PIXELS_\(index)"] = jpeg.base64EncodedString()
        }
        app.launch()
    }
    private func begin(_ target: String) {
        let field = app.textFields["targetInput"]
        field.tap(); field.typeText(target + "\n")
    }
    private func waitForMessage(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) {
        let message = app.staticTexts["feedbackText"]
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", phrase), object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 40), .completed, "Expected \(phrase), saw \(message.exists ? message.label : "no cue")", file: file, line: line)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func waitForOutput(_ phrase: String, timeout: TimeInterval = 24, file: StaticString = #filePath, line: UInt = #line) {
        let cue = app.staticTexts["feedbackText"]
        let heard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", phrase), object: cue)
        XCTAssertEqual(XCTWaiter.wait(for: [heard], timeout: timeout), .completed,
                       "Expected \(phrase). Events: \(String(describing: cue.value)). Status: \(app.staticTexts.matching(identifier: "voiceIssue").allElementsBoundByIndex.map(\.label))", file: file, line: line)
    }

    func testAutomaticMandarinAndHapticsFromStartButton() throws {
        try launch(["route-402"], voice: true, trace: true, englishLocale: true)
        let field = app.textFields["targetInput"]
        field.tap(); field.typeText("402")
        app.buttons["startLive"].tap()
        // No tap on Repeat. Require the synthesizer's real start AND finish callbacks.
        waitForOutput("触觉/start")
        waitForOutput("/开始导航，正在寻找四零二。")
        let opening = try XCTUnwrap((app.staticTexts["feedbackText"].value as? String)?.components(separatedBy: "\n").first { $0.hasPrefix("开读/") })
        let language = String(opening.split(separator: "/")[1]).lowercased()
        XCTAssertTrue(language.hasPrefix("zh") || language.hasPrefix("cmn"), opening)
        XCTAssertFalse(language.contains("-hk") || language.contains("yue"), opening)
        waitForMessage("独立标识写着四零二")
        waitForOutput("读完/开始导航")
        waitForOutput("读完/面前的独立标识写着四零二")
        let trace = app.staticTexts["feedbackText"].value as? String ?? ""
        XCTAssertEqual(trace.components(separatedBy: "触觉/guidance").count - 1, 1)
        XCTAssertFalse(app.descendants(matching: .any)["ocrDetails"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["识别原文"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["rawText"].exists)
        app.buttons["routeConfirm"].tap()
        waitForOutput("触觉/arrival")
        waitForOutput("读完/已确认到达四零二。")
        let proof = XCTAttachment(string: app.staticTexts["feedbackText"].value as? String ?? "")
        proof.name = "Automatic Mandarin and haptic events"; proof.lifetime = .keepAlways; add(proof)
    }

    func testMutedJourneyStillGivesHapticsAndExplicitRepeatSpeaks() throws {
        try launch(["route-campus-dir"], trace: true)
        begin("402"); waitForMessage("4F")
        waitForOutput("触觉/guidance")
        let events = app.staticTexts["feedbackText"].value as? String ?? ""
        XCTAssertFalse(events.contains("开读/"))
        app.buttons["repeat"].tap()
        waitForOutput("读完/导览牌把四零二列在四楼")
    }

    func testExhibitWalkthrough() throws {
        try launch(["route-door", "route-208", "route-campus-dir", "route-lift", "route-4f", "route-campus-turn", "route-402"], hold: 5)
        var markers = [[String: Any]]()
        func mark(_ name: String) { screenshot(name); markers.append(["name": name, "time": Date().timeIntervalSince1970]) }
        mark("01-home")
        XCTAssertFalse(app.buttons["startPhotos"].exists)
        begin("402")
        waitForMessage("疑似门"); mark("route-01-door")
        app.buttons["routeConfirm"].tap(); waitForMessage("刚经过的门牌")
        waitForMessage("记下门牌208"); mark("route-origin")
        waitForMessage("4F"); mark("route-02-directory")
        waitForMessage("箭头指向右"); app.buttons["routeConfirm"].tap(); waitForMessage("离开后")
        waitForMessage("目标楼层一致"); mark("route-floor")
        waitForMessage("箭头指向左")
        waitForMessage("独立标识写着四零二"); mark("route-verify")
        app.buttons["routeConfirm"].tap(); waitForMessage("已确认到达402"); mark("route-03-arrived")
        XCTAssertFalse(app.buttons["pause"].exists)
        let timing = XCTAttachment(data: try JSONSerialization.data(withJSONObject: markers), uniformTypeIdentifier: "public.json")
        timing.name = "walkthrough-times"; timing.lifetime = .keepAlways; add(timing)
        // Leave the final cue visible for the screen recording before XCTest closes the app.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 4))
    }
    func testMallChangesSignsWithoutInteraction() throws {
        try launch(["route-mall-dir", "route-b1", "route-mall-turn", "route-mall-plate"], trace: true)
        begin("松间书屋")
        waitForMessage("B1"); XCTAssertFalse(app.buttons["routeConfirm"].exists)
        waitForMessage("目标楼层一致"); waitForMessage("箭头指向左"); waitForMessage("独立标识写着松间书屋")
        let events = app.staticTexts["feedbackText"].value as? String ?? ""
        XCTAssertEqual(events.components(separatedBy: "触觉/guidance").count - 1, 4)
        app.buttons["routeConfirm"].tap(); waitForMessage("已确认到达松间书屋")
    }
    func testPauseResumeAndChangeTargetWithCameraStillOnTheSamePlate() throws {
        try launch(["route-402"])
        begin("402"); waitForMessage("独立标识写着四零二")
        app.buttons["pause"].tap(); waitForMessage("扫描已暂停")
        XCTAssertFalse(app.buttons["routeConfirm"].exists)
        app.buttons["pause"].tap(); waitForMessage("独立标识写着四零二")
        app.buttons["repeat"].tap(); app.buttons["end"].tap()
        app.buttons["facility-电梯"].tap(); app.buttons["startLive"].tap(); waitForMessage("记下门牌402")
        XCTAssertFalse(app.buttons["routeConfirm"].exists)
        app.buttons["relocalize"].tap(); waitForMessage("记下门牌402")
    }
    func testBackgroundRequiresFreshEvidence() throws {
        try launch(["route-402"])
        begin("402"); waitForMessage("独立标识写着四零二")
        XCUIDevice.shared.press(.home); app.activate(); waitForMessage("已暂停")
        XCTAssertFalse(app.buttons["routeConfirm"].exists)
        app.buttons["pause"].tap(); waitForMessage("独立标识写着四零二")
    }
    func testPermissionAndUnavailableCamera() throws {
        try launch(state: "denied")
        app.buttons["startLive"].tap(); XCTAssertTrue(app.staticTexts["validation"].exists)
        app.buttons["facility-出口"].tap(); app.buttons["startLive"].tap()
        waitForMessage("相机权限未开启"); XCTAssertTrue(app.buttons["cameraSettings"].exists)
        XCTAssertFalse(app.buttons["publicArea"].exists); XCTAssertFalse(app.buttons["shutter"].exists)
        app.terminate(); try launch(state: "unavailable")
        begin("418"); waitForMessage("没有可用的后置相机")
        app.buttons["retryCamera"].tap(); waitForMessage("没有可用的后置相机")
        XCTAssertFalse(app.buttons["fallback"].exists); XCTAssertFalse(app.buttons["photoPicker"].exists)
        app.buttons["end"].tap(); XCTAssertTrue(app.textFields["targetInput"].exists)
    }
    func testSystemAppearanceAndBareToolbarActions() throws {
        let device = XCUIDevice.shared
        let saved = device.appearance
        defer { device.appearance = saved }
        device.appearance = .dark
        try launch(["route-402"])
        screenshot("home-dark")
        begin("402"); waitForMessage("独立标识写着四零二")
        for name in ["end", "help"] {
            let icon = app.buttons[name]
            XCTAssertTrue(icon.isHittable)
            XCTAssertGreaterThanOrEqual(icon.frame.width, 44)
            XCTAssertGreaterThanOrEqual(icon.frame.height, 44)
        }
        screenshot("navigation-dark")
        app.buttons["help"].tap(); XCTAssertTrue(app.staticTexts["站定读牌"].waitForExistence(timeout: 8))
        app.buttons["完成"].tap(); app.buttons["end"].tap()
        XCTAssertTrue(app.textFields["targetInput"].exists)
    }
    func testLargeTypeAndAccessibleControls() throws {
        try launch(["route-402"], largeType: true)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription, .hitRegion])
        begin("402"); waitForMessage("独立标识写着四零二"); screenshot("live-largest-type")
        app.buttons["repeat"].tap(); app.buttons["end"].tap(); XCTAssertTrue(app.textFields["targetInput"].exists)
    }
    private func observation(heading:Double=0, person:Bool=false) -> [String:Any] {
        let hazards:[[String:Any]] = person ? [["kind":"person","box":[0.34,0.28,0.62,0.94],"confidence":0.91]] : []
        return ["heading":heading,"position":["x":0,"y":1.4,"z":0],"tracking":"normal","world":1,"sectors":[-30,-15,0,15,30],"occupied":person,"features":hazards]
    }
    func testSpatialStopInterruptsShortStepAndPauseClearsIt() throws {
        let stream=Array(repeating:observation(),count:60)+Array(repeating:observation(person:true),count:15)
        try launch(["route-door"],voice:true,trace:true,evidence:stream)
        begin("教室门口"); let face=app.buttons["bodyForward"]; XCTAssertTrue(face.waitForExistence(timeout:12)); face.tap()
        waitForMessage("慢行一小段"); waitForMessage("先停一下"); waitForOutput("触觉/emergency")
        waitForOutput("/先停一下。"); XCTAssertFalse(app.buttons["bodyForward"].exists)
        app.buttons["pause"].tap();waitForMessage("已暂停")
        let metrics=try attachMetrics(button:"pause",name:"air-simulator-stop")
        let stops=try XCTUnwrap(metrics["stops"] as? [[String:Double]])
        XCTAssertTrue(stops.contains { $0["speechStarted"] != nil && $0["requestedAt"] != nil })
        app.buttons["pause"].tap();XCTAssertTrue(face.waitForExistence(timeout:12))
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let resumed = try attachMetrics(button: "pause", name: "air-simulator-resumed")
        XCTAssertEqual(resumed["started"] as? Double, metrics["started"] as? Double)
        XCTAssertEqual(resumed["segments"] as? Int, 2)
        XCTAssertGreaterThan(try XCTUnwrap(resumed["activeSeconds"] as? Double), try XCTUnwrap(metrics["activeSeconds"] as? Double))
        XCTAssertEqual((resumed["stops"] as? [[String:Double]])?.first, stops.first)
    }
    private func attachMetrics(button:String,name:String) throws -> [String:Any] {
        let json=try XCTUnwrap(app.buttons[button].value as? String), data=Data(json.utf8)
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    }
    func testDoorDetourReacquisitionFromHomeThroughArrival() throws {
        var stream:[[String:Any]]=[]
        for i in 0..<135 {
            var item=observation(); let x:Double, z:Double, yaw:Double
            switch i {
            case 0..<14: x=0;z=0;yaw=180;item["sectors"]=[]
            case 14..<30: x=0;z=0;yaw=0;item["sectors"]=[-30]
            case 30..<56: x=Double(i-30)*0.024;z=0;yaw=0
            case 56..<70: x=0.6;z=0;yaw=0;item=observation(person:true)
            case 70..<92: x=0.7;z = -Double(i-70)*0.04;yaw=80
            default: x=0.15;z = -min(2.15,0.88+Double(i-92)*0.05);yaw = -9
            }
            item["position"]=["x":x,"y":1.4,"z":z];item["heading"]=yaw
            if (14..<56).contains(i) || i>=92 {
                let delta=atan2(-x,3+z)-yaw*Double.pi/180
                let u=0.5+0.55*tan(delta), height=i<56 ? 0.30:0.58
                item["features"]=[["kind":"door","box":[u-0.045,0.5-height/2,u+0.045,0.5+height/2],"confidence":0.91,"appearance":42]]
            }
            stream.append(item)
        }
        try launch(["route-door"],trace:true,evidence:stream); begin("教室门口")
        waitForMessage("先停一下。"); waitForOutput("触觉/emergency"); waitForMessage("已到教室门口，请停下")
        let metrics=try attachMetrics(button:"finish",name:"air-simulator-door-route")
        XCTAssertEqual(metrics["changedDoor"] as? Bool,false);XCTAssertEqual(metrics["manuallyConfirmed"] as? Bool,false)
        XCTAssertEqual(try XCTUnwrap(metrics["firstDoor"] as? Int),try XCTUnwrap(metrics["arrivedDoor"] as? Int))
    }
    func testConsentAndDelayedProxyTurnUsesLatestCameraHeading() throws {
        let relay=try DelayedRelay(); defer {relay.stop()}
        let stream=Array(repeating:observation(),count:6)+Array(repeating:observation(heading:60),count:18)
        try launch(["route-door"],trace:true,evidence:stream)
        app.buttons["help"].tap(); let address=app.textFields["proxyAddress"]
        if !address.isHittable {app.swipeUp()}; address.tap();address.typeText(relay.address + "\n")
        let enable=app.buttons["enableCloud"]; if !enable.isHittable {app.swipeUp()}; enable.tap()
        XCTAssertTrue(app.alerts.firstMatch.exists); app.buttons["允许关键帧"].tap(); app.buttons["完成"].tap()
        begin("402"); waitForMessage("向左转约30度"); XCTAssertTrue(relay.validImageAndContext)
        app.buttons["pause"].tap();waitForMessage("已暂停")
    }

}

/// Loopback proxy at the URLSession boundary. The first frame sees the reference at +30°.
private final class DelayedRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label:"PathSense.test.relay")
    private var accepted = false
    var validImageAndContext:Bool { queue.sync {accepted} }
    var address:String { "http://127.0.0.1:\(listener.port!.rawValue)/integration-fixture" }
    init() throws {
        let parameters=NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener=try NWListener(using:parameters); let ready=DispatchSemaphore(value:0)
        listener.stateUpdateHandler={ state in if case .ready=state { ready.signal() } }
        listener.newConnectionHandler={ [weak self] connection in
            guard let self else {return}; connection.start(queue:self.queue); self.receive(connection,Data())
        }; listener.start(queue:queue)
        guard ready.wait(timeout:.now()+5) == .success else {throw NSError(domain:"fixture",code:1)}
    }
    func stop() { listener.cancel() }
    private func receive(_ connection:NWConnection,_ buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:96_000) { [weak self] data,_,closed,error in
            guard let self, let data, error == nil else {connection.cancel();return}
            var all=buffer;all.append(data);guard all.count<700_000 else {connection.cancel();return}
            if let split=all.range(of:Data("\r\n\r\n".utf8)), let head=String(data:all[..<split.lowerBound],encoding:.utf8),
               let length=head.components(separatedBy:"\r\n").first(where:{$0.lowercased().hasPrefix("content-length:")}).flatMap({Int($0.dropFirst(15).trimmingCharacters(in:.whitespaces))}), all.count-split.upperBound>=length,
               let packet=(try? JSONSerialization.jsonObject(with:all[split.upperBound...])) as? [String:Any],
               let ctx=packet["context"] as? [String:Any],let capture=ctx["capture"] as? [String:Any],let sample=capture["sample"] as? [String:Any],let stamp=sample["id"] as? [String:Any] {
                let image=(packet["image"] as? String).flatMap {Data(base64Encoded:$0)}
                self.accepted = self.accepted || (image.flatMap(UIImage.init(data:)) != nil && ctx["request"] != nil && ctx["destination"] as? String == "402")
                let result:[String:Any]=["frame_id":stamp,"action":"target_waypoint","target_ref":"o1","speech_zh":"先转向右侧过道。","uncertain":false,"hazards":[],"observations":[["ref":"o1","kind":"aisle_entrance","box":[0.78,0.3,0.856,0.7]]]]
                guard let json=try? JSONSerialization.data(withJSONObject:result) else {connection.cancel();return}
                let header=Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
                self.queue.asyncAfter(deadline:.now()+1.8) {connection.send(content:header+json,completion:.contentProcessed {_ in connection.cancel()})};return
            }
            if closed {connection.cancel()} else {self.receive(connection,all)}
        }
    }
}
