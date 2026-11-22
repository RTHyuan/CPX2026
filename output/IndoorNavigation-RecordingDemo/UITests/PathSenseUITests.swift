import XCTest
import UIKit
import Network
import CryptoKit
import os
#if DEBUG && targetEnvironment(simulator)
import notify
#endif

final class PathSenseUITests: XCTestCase {
    private var app: XCUIApplication!
    #if DEBUG && targetEnvironment(simulator)
    private var stagedInputs: [[String:Any]] = []
    private var sourceIndex: [String:[String:Any]]?
    #endif
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDoorDemoHomeAndAuthorizationMessage() throws {
        app = XCUIApplication()
        app.launchArguments = ["--door-demo", "--demo-language", "zh-CN", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.textFields["demoDestination"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["demoDestination"].value as? String, "门口")
        XCTAssertTrue(app.buttons["startDoorDemo"].isHittable)
        XCTAssertTrue(app.navigationBars["室内寻路"].exists)
        XCTAssertTrue(app.buttons["demoSpeakDestination"].exists)
        XCTAssertTrue(app.buttons["demoFacility-0"].exists)
        assertVisibleInterfaceHasNoModelBranding()
        screenshot("室内寻路-中文首页")
        #if targetEnvironment(simulator)
        app.buttons["startDoorDemo"].tap()
        let status = app.staticTexts["demoStatus"]
        let unavailable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "授权不可用"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["startDoorDemo"].exists)
        assertVisibleInterfaceHasNoModelBranding()
        #endif
    }

    func testIndoorNavigationEnglishHomeAndAuthorizationMessage() throws {
        app = XCUIApplication()
        app.launchArguments = ["--door-demo", "--demo-language", "en-US", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.textFields["demoDestination"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["demoDestination"].value as? String, "doorway")
        XCTAssertTrue(app.navigationBars["Indoor Navigation"].exists)
        XCTAssertEqual(app.buttons["demoSpeakDestination"].label, "Say your destination")
        app.buttons["demoFacility-3"].tap()
        XCTAssertEqual(app.textFields["demoDestination"].value as? String, "Restroom")
        assertVisibleInterfaceHasNoModelBranding()
        screenshot("Indoor Navigation-English home")
        #if targetEnvironment(simulator)
        app.buttons["startDoorDemo"].tap()
        let status = app.staticTexts["demoStatus"]
        let unavailable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Vision access is unavailable"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 8), .completed)
        assertVisibleInterfaceHasNoModelBranding()
        #endif
    }

    func testIndoorNavigationLanguageSwitchPersists() throws {
        app = XCUIApplication()
        app.launchArguments = ["--door-demo", "--demo-language", "zh-CN", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.textFields["demoDestination"].waitForExistence(timeout: 10))
        let languages = app.segmentedControls["demoLanguage"]
        if !languages.isHittable { app.swipeUp() }
        XCTAssertTrue(languages.waitForExistence(timeout: 3))
        languages.buttons["English"].tap()
        app.swipeDown()
        XCTAssertTrue(app.navigationBars["Indoor Navigation"].exists)
        XCTAssertEqual(app.textFields["demoDestination"].value as? String, "doorway")
        app.terminate()
        app.launchArguments = ["--door-demo", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.textFields["demoDestination"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Indoor Navigation"].exists)
        XCTAssertEqual(app.textFields["demoDestination"].value as? String, "doorway")
        assertVisibleInterfaceHasNoModelBranding()
        screenshot("Indoor Navigation-persisted language")
    }

    /// Inspect rendered labels and field values only; internal test identifiers are not UI copy.
    private func assertVisibleInterfaceHasNoModelBranding(file: StaticString = #filePath, line: UInt = #line) {
        let elements = app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
            + app.textFields.allElementsBoundByIndex + app.switches.allElementsBoundByIndex
        let copy = elements.filter { $0.exists && $0.isHittable }.flatMap { element in
            var visible = [element.label]
            if element.elementType == .textField, let value = element.value as? String { visible.append(value) }
            return visible
        }
        let branded = copy.filter { $0.range(of: "\\bDS\\b|DeepSeek", options: [.regularExpression, .caseInsensitive]) != nil }
        XCTAssertTrue(branded.isEmpty, "Visible model branding: \(branded)", file: file, line: line)
    }

    /// Only the test runner carries these assets. The app receives pixels without labels.
    private func launch(_ files: [String] = [], state: String = "replay", hold: Int = 6, largeType: Bool = false, voice: Bool = false, trace: Bool = false, englishLocale: Bool = false, evidence: [[String:Any]] = [], phaseName: String? = nil, fieldPixels: [Data] = []) throws {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", englishLocale ? "(en)" : "(zh-Hans)", "-AppleLocale", englishLocale ? "en_US" : "zh_CN", "-voice", voice ? "YES" : "NO"]
        if trace { app.launchEnvironment["PATHSENSE_TEST_FEEDBACK"] = "1" }
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if !evidence.isEmpty { app.launchEnvironment["PATHSENSE_TEST_EVIDENCE"] = String(decoding:try JSONSerialization.data(withJSONObject:evidence),as:UTF8.self) }
        app.launchEnvironment["PATHSENSE_TEST_PHASE"] = phaseName
        app.launchEnvironment["PATHSENSE_TEST_CAMERA"] = state
        app.launchEnvironment["PATHSENSE_TEST_HOLD"] = "\(hold)"
        #if DEBUG && targetEnvironment(simulator)
        if !evidence.isEmpty {
            let record: [String:Any] = ["imagesLoadedByRunner":stagedInputs, "practiceAssets":files,
                "injectedCaptureInputs":evidence,
                "meaning":"除注明的原始像素、视频 PTS 和源帧号外，位姿、内参、框、通行扇区、地面/落脚/身体空间、行人与深度均为受控输入。readSigns=true 运行系统 Vision。其他阶段不做像素识别。本地语义代理引用人工框。"]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "inputs-and-pixel-provenance.json"; attachment.lifetime = .keepAlways; add(attachment)
            stagedInputs = []
        }
        if !fieldPixels.isEmpty {
            // Keep the original camera resolution, filenames and private JPEGs out of launch arguments.
            // One local GET transfers anonymous pixels from the runner, including when its resource
            // bundle is the only process allowed to read the source files.
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(fieldPixels)
            let source = try LoopbackHTTP(method: "GET") { _, respond in respond(200, data) }
            addTeardownBlock { source.stop() }
            app.launchEnvironment["PATHSENSE_TEST_FRAME_SOURCE"] = source.address
        }
        #endif
        for (index, file) in files.enumerated() {
            app.launchEnvironment["PATHSENSE_TEST_PIXELS_\(index)"] = try practicePixels(file).base64EncodedString()
        }
        app.launch()
    }

    private func practicePixels(_ file: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: file, withExtension: file == "route-door" ? "jpg" : "png", subdirectory: "Practice"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let scale = min(1, 820 / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.68) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    private func begin(_ target: String) {
        let field = app.textFields["targetInput"]
        field.tap(); field.typeText(target + "\n")
        let feedback = app.staticTexts["feedbackText"]
        if !feedback.waitForExistence(timeout: 3), field.exists {
            // The Chinese simulator keyboard sometimes consumes Return to commit composition.
            // Use the same visible primary button that a traveler can press.
            let start = app.buttons["startLive"]
            if start.exists && !start.isHittable { app.swipeUp() }
            if start.isHittable { start.tap() }
        }
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
        app.buttons["publicArea"].tap(); waitForMessage("刚经过的门牌")
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
        app.buttons["help"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "查看路牌")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["完成"].tap(); app.buttons["end"].tap()
        XCTAssertTrue(app.textFields["targetInput"].exists)
    }
    func testLargeTypeAndAccessibleControls() throws {
        try launch(["route-402"], largeType: true)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription, .hitRegion])
        begin("402"); waitForMessage("独立标识写着四零二"); screenshot("live-largest-type")
        app.buttons["repeat"].tap(); app.buttons["end"].tap(); XCTAssertTrue(app.textFields["targetInput"].exists)
    }
    private func observation(heading: Double = 0, person: Bool = false, pitchDown: Double = 0, x: Double = 0,
                             sectors: [Int] = [-30,-15,0,15,30], offsets: [Double] = [], picture: Int = 0,
                             readSigns: Bool = false, checked: [Int] = [], door: Bool = false, aisle: Double? = nil) -> [String:Any] {
        var hazards:[[String:Any]] = person ? [["kind":"person","box":[0.34,0.28,0.62,0.94],"confidence":0.91]] : []
        if door { hazards.append(["kind":"door", "box":[0.43,0.16,0.57,0.60], "confidence":0.91, "appearance":42]) }
        if let aisle {
            // Controlled landmark projected into this portrait camera. The passage label alone has no target identity.
            let pitch = pitchDown * .pi / 180, delta = (aisle - heading) * .pi / 180
            let down = tan(35.0 * .pi / 180)
            let depth = cos(pitch) * cos(delta) + sin(pitch) * down
            let u = 0.5 + 0.55 * sin(delta) / depth
            let v = 0.5 - 0.55 * (sin(pitch) * cos(delta) - cos(pitch) * down) / depth / (1280.0 / 720.0)
            if depth > 0, (0.023...0.977).contains(u), (0.045...0.955).contains(v) {
                hazards.append(["kind":"aisle_entrance", "box":[u-0.022,v-0.04,u+0.022,v+0.04], "confidence":0.9])
            }
        }
        return ["checkedStepSectors":checked,"heading":heading, "pitchDown":pitchDown, "headingOffsets":offsets, "position":["x":x,"y":1.4,"z":0],
                "tracking":"normal", "world":1, "sectors":sectors, "occupied":person, "features":hazards,
                "picture":picture, "readSigns":readSigns]
    }
    func testSpatialStopInterruptsShortStepAndPauseClearsIt() throws {
        #if DEBUG && targetEnvironment(simulator)
        let phase = try ReplayPhase()
        let tape = [observation(pitchDown: 28, checked: [0], door: true), observation(person: true, pitchDown: 28, checked: [0], door: true)]
        try launch(["route-door"], voice: true, trace: true, evidence: tape, phaseName: phase.name)
        begin("教室门口")
        let face = app.buttons["bodyForward"]
        XCTAssertTrue(face.waitForExistence(timeout: 18)); face.tap()
        waitForOutput("开读/zh-CN/向前迈一步。")
        phase.select(1); waitForOutput("触觉/emergency"); waitForOutput("/先停一下。")
        XCTAssertFalse(face.exists)
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let metrics = try attachMetrics(button: "pause", name: "simulator-local-stop-and-revocation")
        let stops = try XCTUnwrap(metrics["stops"] as? [[String:Double]])
        XCTAssertTrue(stops.contains { $0["speechStarted"] != nil && $0["requestedAt"] != nil })
        phase.select(0); app.buttons["pause"].tap()
        XCTAssertTrue(face.waitForExistence(timeout: 18))
        XCTAssertFalse(events.suffix(2).contains { $0 == "开读/zh-CN/向前迈一步。" })
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let resumed = try attachMetrics(button: "pause", name: "air-simulator-resumed")
        XCTAssertEqual(resumed["started"] as? Double, metrics["started"] as? Double)
        XCTAssertEqual(resumed["segments"] as? Int, 2)
        XCTAssertGreaterThan(try XCTUnwrap(resumed["activeSeconds"] as? Double), try XCTUnwrap(metrics["activeSeconds"] as? Double))
        XCTAssertEqual((resumed["stops"] as? [[String:Double]])?.first, stops.first)
        #endif
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
            case 56..<70: x=0.6;z=0;yaw=0;item=observation(person:true); item["injectedFrontDistance"]=0.32
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
        waitForOutput("触觉/emergency"); waitForMessage("已到教室门口，请停下")
        let metrics=try attachMetrics(button:"finish",name:"air-simulator-door-route")
        XCTAssertEqual(metrics["changedDoor"] as? Bool,false);XCTAssertEqual(metrics["manuallyConfirmed"] as? Bool,false)
        XCTAssertEqual(try XCTUnwrap(metrics["firstDoor"] as? Int),try XCTUnwrap(metrics["arrivedDoor"] as? Int))
    }
    #if DEBUG && targetEnvironment(simulator)
    func testConsentAndDelayedProxyTurnUsesLatestCameraHeading() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "route-door", withExtension: "jpg", subdirectory: "Practice"))
        let photo = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertEqual(photo.width, 1440); XCTAssertEqual(photo.height, 1037)
        // Two native-pixel windows of the same CC0 photograph. The open passage is on the
        // right of the first window, on the left of the second. The yaw is a tape measurement.
        let pictures = try [0, 540].map { x in
            let window = try XCTUnwrap(photo.cropping(to: CGRect(x: x, y: 0, width: 900, height: 1037)))
            return try XCTUnwrap(UIImage(cgImage: window).jpegData(compressionQuality: 0.85))
        }
        let uploads = try pictures.map { try XCTUnwrap(UIImage(data: $0)?.jpegData(compressionQuality: 0.65)) }
        let phase = try ReplayPhase()
        let relay = try DelayedRelay(phase: phase, uploads: uploads)
        defer {
            let proof = XCTAttachment(string: relay.transcript); proof.name = "delayed-cloud-wire"; proof.lifetime = .keepAlways; add(proof)
            relay.stop()
        }
        var setup = observation(sectors: []); setup["tracking"] = "limited"
        // No local target or remembered aisle at 0°. At +60° the strips are symmetric,
        // so local clearance alone prefers straight ahead.
        let tape = [setup, observation(pitchDown: 0, sectors: []),
                    observation(heading: 60, pitchDown: 0, sectors: [-60,-30,0,30,60], picture: 1),
                    observation(heading: 60, pitchDown: 0, sectors: [-60,-30,0,30,60], picture: 0)]
        try launch(voice: true, trace: true, evidence: tape, phaseName: phase.name, fieldPixels: pictures)
        enableCloud(at: relay.address); begin("402")
        // Hold the limited-tracking phase while the long introduction is actually playing.
        // The aisle ray expires in three seconds; late speech must never revive that expired ray.
        waitForOutput("读完/开始导航，正在寻找四零二。", timeout: 25)
        phase.select(1)
        wait(for: [relay.firstReceived, relay.rotatedReceived], timeout: 20, enforceOrder: true)
        let expected = "请原地向左转约30度。"
        waitUntil("Current bearing is spoken on the phone", timeout: 20) {
            self.events.contains { SpeechCallback.started.matches($0, label: expected) }
        }
        phase.select(3) // A distinct visible frame requests a packet after actual speech started.
        wait(for: [relay.spokenInstructionReceived], timeout: 16)
        XCTAssertEqual(relay.instructionAfterReply, expected, relay.transcript)
        XCTAssertFalse(events.contains { $0.contains(DelayedRelay.originalSpeech) })
        attachFeedback("delayed-cloud-presented-cue", expected: expected)
        app.buttons["pause"].tap(); waitForMessage("已暂停")
    }
    #endif

    private func enableCloud(at url: String) {
        app.buttons["help"].tap(); let address=app.textFields["proxyAddress"]
        if !address.isHittable {app.swipeUp()}; address.tap()
        address.typeText(url + "\n")
        let enable=app.buttons["enableCloud"]; if !enable.isHittable {app.swipeUp()}; enable.tap()
        XCTAssertTrue(app.alerts.firstMatch.exists); app.buttons["允许关键帧"].tap(); app.buttons["完成"].tap()
    }

    #if DEBUG && targetEnvironment(simulator)
    private var cue: XCUIElement { app.staticTexts["feedbackText"] }
    private var events: [String] { (cue.value as? String ?? "").components(separatedBy: "\n") }

    private func waitUntil(_ description: String, timeout: TimeInterval = 20, file: StaticString = #filePath,
                           line: UInt = #line, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) != .completed else { return }
        let trace = attachFeedback("field-cue-timeout")
        XCTFail(description + "\n" + trace, file: file, line: line)
    }

    private typealias FeedbackSample = (label: String, events: [String])

    private func sampleFeedback() -> FeedbackSample? {
        guard let snapshot = try? cue.snapshot() else { return nil }
        return (snapshot.label, (snapshot.value as? String ?? "").components(separatedBy: "\n"))
    }

    @discardableResult private func attachFeedback(_ name: String, sample: FeedbackSample? = nil, expected: String? = nil) -> String {
        let observed = sample ?? sampleFeedback()
        var lines = ["cue.label = " + (observed?.label ?? "<missing>")]
        if let expected { lines.append("recognized label = " + expected) }
        lines += observed?.events ?? []
        let history = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: history)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return history
    }

    private func fieldFolder() throws -> URL {
        let bundle = Bundle(for: Self.self).resourceURL?.appendingPathComponent("FieldFrames")
        let path = Self.runnerSetting("PATHSENSE_REAL_FRAMES")
        let folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? bundle
        guard let folder, path != nil || FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("Set TEST_RUNNER_PATHSENSE_REAL_FRAMES or stage private JPEGs in the test bundle's FieldFrames folder")
        }
        return folder
    }

    private func fieldPhoto(_ filename: String) throws -> Data {
        let folder = try fieldFolder()
        let bytes = try Data(contentsOf: folder.appendingPathComponent(filename))
        if sourceIndex == nil {
            let old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [[String:Any]])
            var sources = Dictionary(uniqueKeysWithValues: old.compactMap { row in (row["frame"] as? String).map { ($0, row) } })
            let url = folder.appendingPathComponent("navigation-manifest.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
                for var row in (doc["captures"] as? [[String:Any]] ?? []) + (doc["photos"] as? [[String:Any]] ?? []) {
                    guard let name = row["frame"] as? String else { continue }
                    if row["sourceFrame"] != nil { row["source"] = doc["source"]; row["timescale"] = doc["timescale"] }
                    sources[name] = row
                }
            }
            sourceIndex = sources
        }
        let source = try XCTUnwrap(sourceIndex?[filename], "Missing source record for \(filename)")
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, source["sha256"] as? String, "Changed input pixels for \(filename)")
        stagedInputs.append(source)
        _ = try XCTUnwrap(UIImage(data: bytes)?.cgImage, "Unreadable private frame \(filename)")
        return bytes
    }

    private static func runnerSetting(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return [name, "TEST_RUNNER_" + name].compactMap { env[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    // The destination in the opening instruction is not an observation. Capture a label
    // that actually attributes the room to printed text, then bind both callbacks to it.
    private static func roomWords(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace }.replacingOccurrences(of: "BSG三三", with: "BSG33")
    }

    private static func identifiesFieldPlate(_ label: String) -> Bool {
        let words = roomWords(label)
        guard !words.contains("正在寻找") else { return false }
        // The camera can place the same readable plaque in front or to either side.
        // Require a phrase which attributes *this* number to a legend, in the same clause.
        let attribution = #"(?:牌(?:面)?(?:文字)?|目录|标识)(?:上)?(?:写着|写有|提到|列有|显示)「?BSG33(?![A-Z0-9])|(?:本机读到门牌|读到)「BSG33」"#
        return words.range(of: attribution, options: .regularExpression) != nil
    }

    private enum SpeechCallback: String {
        case started = "开读", finished = "读完"
        func matches(_ event: String, label: String) -> Bool {
            let fields = event.split(separator: "/", maxSplits: self == .started ? 2 : 1)
            guard fields.count == (self == .started ? 3 : 2), fields.first == Substring(rawValue), let words = fields.last else { return false }
            return PathSenseUITests.roomWords(String(words)) == PathSenseUITests.roomWords(label)
        }
    }

    private func waitForLookAround(file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("Show the stationary camera-survey cue", file: file, line: line) {
            let label = self.cue.label
            return ["手机", "环顾", "请原地观察", "镜头"].contains(where: label.contains)
        }
    }

    func testFieldPublicAreaRaisedPhoneReadsPlateAndPersonPreempts() throws {
        let phase = try ReplayPhase()
        let jitter = [-3.0, 2, -1, 3, 0, -2]
        let reading = observation(pitchDown: -12, sectors: [], offsets: jitter, picture: 1, readSigns: true)
        // The source contains no synchronized depth or person annotation. Inject a close person
        // during the repeated read; the view and camera station stay unchanged.
        var crossing = observation(person: true, pitchDown: -12, sectors: [], offsets: jitter, picture: 1, readSigns: true)
        crossing["injectedFrontDistance"] = 0.30
        let clear = reading
        let tape = [observation(pitchDown: -12, sectors: []), reading, crossing, clear]
        try launchFieldNavigation(["rtr2-51.5.jpg", "rtr1-70.2.jpg"], tape: tape, phase: phase)
        begin("BSG33")
        waitForLookAround()
        let button = app.buttons["publicArea"]
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
        XCTAssertTrue(app.buttons["relocalize"].waitForExistence(timeout: 8), "公共区域确认应持续反映在任务状态中")
        waitUntil("A spoken public-area confirmation") { self.events.contains { $0.hasPrefix("开读/") && $0.contains("公共区域") } }
        XCTAssertFalse(button.exists)
        phase.select(1)
        var observedLabel: String?
        waitUntil("Raised camera with unknown floor: read BSG33 from the captured plate", timeout: 40) {
            let label = self.cue.label
            guard Self.identifiesFieldPlate(label) else { return false }
            observedLabel = label
            return true
        }
        let plateLabel = try XCTUnwrap(observedLabel)
        func plateStarts(_ event: String) -> Bool { SpeechCallback.started.matches(event, label: plateLabel) }
        func plateFinishes(_ event: String) -> Bool { SpeechCallback.finished.matches(event, label: plateLabel) }
        var completed: FeedbackSample?
        waitUntil("Expected ordered didStart and didFinish for the displayed plaque: " + plateLabel, timeout: 35) {
            guard let sample = self.sampleFeedback(), let start = sample.events.firstIndex(where: plateStarts),
                  sample.events.dropFirst(start + 1).contains(where: plateFinishes) else { return false }
            completed = sample
            return true
        }
        let sample = try XCTUnwrap(completed), before = sample.events
        let completedTrace = attachFeedback("field-bsg33-after-did-finish", sample: sample, expected: plateLabel)
        XCTAssertEqual(Self.roomWords(sample.label), Self.roomWords(plateLabel), "Keep the recognized plate on screen through its actual speech callback\n" + completedTrace)
        XCTAssertFalse(before.contains("触觉/emergency"))
        XCTAssertFalse(before.contains { $0.hasPrefix("开读/") && $0.contains("先停一下") })
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        // Re-read the confirmed words so the person measurement arrives during real speech.
        let reads = before.filter(plateStarts).count
        app.buttons["repeat"].tap()
        waitUntil("Repeat started the plaque again") { self.events.filter(plateStarts).count > reads }
        phase.select(2)
        waitForMessage("先停一下")
        waitForOutput("触觉/emergency")
        waitUntil("An actual stop utterance after the last plaque") {
            let history = self.events
            guard let plate = history.lastIndex(where: plateStarts) else { return false }
            return history.dropFirst(plate + 1).contains { $0.hasPrefix("开读/") && $0.contains("先停一下") }
        }
        waitForOutput("读完/先停一下")
        let history = events
        let repeated = try XCTUnwrap(history.lastIndex(where: plateStarts))
        let stop = try XCTUnwrap(history[repeated...].firstIndex { $0.hasPrefix("开读/") && $0.contains("先停一下") })
        XCTAssertFalse(history[repeated..<stop].contains(where: plateFinishes), "Person interrupts the repeated plaque in flight")
        XCTAssertEqual(history.filter { $0 == "触觉/emergency" }.count, 1)
        phase.select(3)
        waitUntil("After danger clears the same visible sign is read again", timeout: 25) {
            let log = self.events
            guard let emergency = log.lastIndex(where: { $0.hasPrefix("读完/先停一下") }) else { return false }
            return log.dropFirst(emergency + 1).contains(where: plateStarts)
        }
        XCTAssertFalse(events.contains { $0.contains("向前迈一步") })
        attachFeedback("field-bsg33-jitter-person-speech")
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let metrics = try attachMetrics(button: "pause", name: "field-bsg33-jitter-person")
        try checkOneLocalStop(metrics)
    }

    private func checkOneLocalStop(_ metrics: [String:Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let stops = try XCTUnwrap(metrics["stops"] as? [[String:Double]], file: file, line: line)
        XCTAssertEqual(stops.count, 1, file: file, line: line)
        let stop = try XCTUnwrap(stops.first, file: file, line: line)
        let detected = try XCTUnwrap(stop["detectedAt"]), requested = try XCTUnwrap(stop["requestedAt"])
        XCTAssertGreaterThanOrEqual(requested, detected, file: file, line: line)
        XCTAssertLessThan(requested - detected, 0.55, "Dispatch within the near-field freshness window", file: file, line: line)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(stop["speechStarted"]), requested, file: file, line: line)
    }

    func testFieldStaffOnlySignWithUnknownGround() throws {
        let phase = try ReplayPhase()
        let tape = [observation(pitchDown: -12, sectors: [], readSigns: true),
                    observation(heading: 95, sectors: [], picture: 1),
                    observation(pitchDown: 22, sectors: [-15,0,15])]
        try launch(voice: true, trace: true, evidence: tape, phaseName: phase.name,
                   fieldPixels: [fieldPhoto("rtr2-51.5.jpg"), fieldPhoto("rtr1-32.0.jpg")])
        begin("BSG35")
        waitUntil("Read the Staff Only sign on first approach", timeout: 40) { self.cue.label.contains("限制") }
        waitUntil("The real Staff Only notice was spoken") { self.events.contains { $0.hasPrefix("读完/") && $0.contains("限制") } }
        XCTAssertEqual(events.filter { $0 == "触觉/emergency" }.count, 0)
        phase.select(1)
        waitForLookAround() // Left the entrance bearing and now looking at the seats.
        let spoken = events.filter { $0.hasPrefix("开读/") && $0.contains("限制") }.count
        phase.select(2) // Face the same entrance again with fresh floor evidence and OCR disabled.
        waitUntil("Show the restriction again on returning to its bearing") { self.cue.label.contains("限制") }
        waitUntil("Revisiting the bearing restores the remembered restriction without a new reading") {
            self.events.filter { $0.hasPrefix("开读/") && $0.contains("限制") }.count > spoken
        }
        XCTAssertEqual(events.filter { $0 == "触觉/emergency" }.count, 0)
        attachFeedback("field-staff-only-readings")
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        XCTAssertFalse(app.buttons["routeConfirm"].exists)
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let metrics = try attachMetrics(button: "pause", name: "field-staff-only-return-to-entrance")
        XCTAssertEqual((metrics["stops"] as? [[String:Double]])?.count, 0)
    }

    func testFieldMockRelayRemembersElevatorPictogram() throws {
        let offSign = try fieldPhoto("rtr2-51.5.jpg"), overhead = try fieldPhoto("rtr2-10.6.jpg")
        let mock = try FieldSignMock(offSign: offSign, overhead: overhead); defer { mock.server.stop() }
        let phase = try ReplayPhase()
        let tape = [observation(sectors: []), observation(sectors: [], picture: 1),
                    observation(heading: 65, sectors: []), observation(heading: 65, x: 2, sectors: [])]
        try launch(trace: true, evidence: tape, phaseName: phase.name, fieldPixels: [offSign, overhead])
        enableCloud(at: mock.server.address); begin("电梯")
        waitUntil("Loopback mock received the other photo with no local signs") { mock.sawBaseline }
        phase.select(1)
        waitUntil("A change in actual pixels at the same station triggered a new upload and an elevator readout") {
            mock.sawChangedSign && self.cue.label.contains("电梯") && self.cue.label.contains("图标")
        }
        phase.select(2)
        waitUntil("The captured sign is now to the left of the phone") { self.cue.label.contains("标牌") && self.cue.label.contains("左") }
        phase.select(3)
        waitUntil("After two metres the old bearing requires another look") {
            self.cue.label.contains("手机") && ["重新", "再看", "复核", "重看"].contains(where: self.cue.label.contains)
        }
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        let result = XCTAttachment(string: "loopback mock; rtr2 10.6 s elevator symbol; changed_view; left after +65 degrees; reacquisition after 2 m")
        result.name = "field-pictogram-mock-memory"; result.lifetime = .keepAlways; add(result)
    }

    func testFieldDoorDetourReacquisitionThroughArrival() throws {
        let phase = try ReplayPhase()
        let aisle = try fieldPhoto("rtr1-32.0.jpg"), far = try fieldPhoto("rtr1-12.0.jpg")
        let near = try XCTUnwrap(UIImage(data: fieldPhoto("rtr1-66.0.jpg"))?.cgImage)
        // Remove ceiling/upper plaque from this real close-up. These are upright pixel boxes of the
        // visible wood door in the two exposures. No ID, appearance hash or room name is supplied.
        let crop = try XCTUnwrap(near.cropping(to: CGRect(x: 0, y: 320, width: near.width, height: near.height - 320)))
        let close = try XCTUnwrap(UIImage(cgImage: crop).jpegData(compressionQuality: 0.88))
        let farBox = [305.0/720, 370.0/1280, 354.0/720, 450.0/1280]
        let closeBox = [0.0, (774.0-320)/960, 528.0/720, 1.0]
        func doorView(_ picture: Int, _ box: [Double], x: Double, z: Double, sectors: [Int], blocked: Bool = false) -> [String:Any] {
            // Simulated camera pans to keep the annotated door in view during lateral parallax.
            // The image ray meets (0, cameraHeight, -3). Navigation must triangulate that point itself.
            let aspect = picture == 1 ? 1280.0/720 : 960.0/720
            let dx = ((box[0] + box[2])/2 - 0.5)/0.55, dy = (0.5 - (box[1] + box[3])/2)*aspect/0.55
            let heading = (atan2(-x, 3+z) - atan2(dx, hypot(1,dy))) * 180 / .pi
            var item = observation(heading: heading, person: blocked, pitchDown: atan(dy)*180 / .pi,
                                   x: x, sectors: sectors, picture: picture, checked: sectors.contains(0) ? [0] : [])
            item["position"] = ["x":x, "y":1.4, "z":z]
            if !blocked { item["features"] = [["kind":"door", "box":box, "confidence":0.91]] }
            return item
        }
        var side = observation(heading: 70, x: 0.7, sectors: [], picture: 0)
        side["position"] = ["x":0.7, "y":1.4, "z": -0.85]
        let tape = [observation(heading: 165, sectors: []),
                    doorView(1, farBox, x: 0, z: 0, sectors: [-30]),
                    doorView(1, farBox, x: 0.45, z: 0, sectors: [-15,0,15]),
                    doorView(1, farBox, x: 0.45, z: 0, sectors: [], blocked: true), side,
                    doorView(2, closeBox, x: 0.12, z: -2.1, sectors: [])]
        try launch(voice: true, trace: true, evidence: tape, phaseName: phase.name, fieldPixels: [aisle, far, close])
        begin("教室门口"); waitForLookAround()
        phase.select(1); waitForMessage("找到门")
        phase.select(2)
        let forward = app.buttons["bodyForward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 16)); forward.tap(); waitForMessage("向前迈一步")
        phase.select(3); waitForOutput("触觉/emergency"); waitForOutput("读完/先停一下")
        phase.select(4)
        waitUntil("After the detour the remembered door is to the left, without a walking permit") {
            self.cue.label.contains("左转") && !self.cue.label.contains("向前迈一步")
        }
        XCTAssertFalse(forward.exists); XCTAssertFalse(app.staticTexts["已到教室门口，请停下。"].exists)
        phase.select(5); waitForMessage("已到教室门口，请停下")
        let metrics = try attachMetrics(button: "finish", name: "field-door-detour-auto-arrival")
        XCTAssertEqual(try XCTUnwrap(metrics["firstDoor"] as? Int), try XCTUnwrap(metrics["arrivedDoor"] as? Int))
        XCTAssertEqual(metrics["identityContinuous"] as? Bool, true)
        XCTAssertEqual(metrics["changedDoor"] as? Bool, false)
        XCTAssertEqual(metrics["manuallyConfirmed"] as? Bool, false)
        XCTAssertEqual(metrics["segments"] as? Int, 1)
        XCTAssertGreaterThan(try XCTUnwrap(metrics["activeSeconds"] as? Double), 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics["finished"] as? Double), try XCTUnwrap(metrics["started"] as? Double))
        XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["peakSameStationSweeps"] as? Int), 1)
        try checkOneLocalStop(metrics)
    }

    private func launchFieldNavigation(_ frames: [String], tape: [[String:Any]], phase: ReplayPhase) throws {
        let pixels = try frames.map(fieldPhoto)
        try launch(voice: true, trace: true, evidence: tape, phaseName: phase.name, fieldPixels: pixels)
    }

    private func waitForSpokenCue(_ phrases: [String], callback: SpeechCallback = .started,
                                  file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("Expected \(phrases) on screen and its \(callback.rawValue) callback", timeout: 35, file: file, line: line) {
            guard let sample = self.sampleFeedback(), phrases.allSatisfy(sample.label.contains) else { return false }
            return sample.events.contains { callback.matches($0, label: sample.label) }
        }
    }

    func testFieldPhoneTiltThenLeftAisleAndFrontConfirmation() throws {
        let phase = try ReplayPhase()
        let tape = [observation(heading: -30, pitchDown: -4, sectors: [], aisle: -30),
                    observation(heading: -30, pitchDown: 34, sectors: [], aisle: -30),
                    observation(pitchDown: 34, sectors: [-30], aisle: -30),
                    observation(heading: -30, pitchDown: 34, sectors: [0], checked: [0], aisle: -30)]
        try launchFieldNavigation(["rtr1-32.0.jpg"], tape: tape, phase: phase)
        begin("402")
        waitForSpokenCue(["手机朝前", "向下倾"], callback: .finished)
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        phase.select(1)
        waitForSpokenCue(["保持这个角度", "两侧"], callback: .finished)
        phase.select(2)
        waitForSpokenCue(["原地", "左转"], callback: .finished)
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        phase.select(3)
        waitForSpokenCue(["手机", "身体前方"])
        XCTAssertTrue(app.buttons["bodyForward"].exists)
        XCTAssertFalse(events.contains { $0 == "触觉/emergency" || $0.contains("向前迈一步") })
        attachFeedback("field-phone-tilt-left-aisle-confirmation")
    }

    func testFieldRoomTurnsToLocalSideAisleWithoutCloudTarget() throws {
        let phase = try ReplayPhase()
        let tape = [observation(pitchDown: 22, sectors: []), observation(pitchDown: 22, sectors: [-45], aisle: -45)]
        try launchFieldNavigation(["rtr2-33.7.jpg"], tape: tape, phase: phase)
        begin("402"); waitForLookAround()
        let local = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "仅本机")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 8))
        phase.select(1)
        waitForSpokenCue(["原地", "左转"], callback: .finished)
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        XCTAssertFalse(events.contains { $0 == "触觉/emergency" || $0 == "触觉/alignment" || $0.contains("向前迈一步") })
        attachFeedback("field-402-local-left-turn")
    }

    func testFieldMeasuredDropRightTurnBodyConfirmationAndPersonStop() throws {
        let phase = try ReplayPhase()
        // The step is visible in RTR1. Its world point, camera poses, free sectors and final person box are injected.
        // Alternating headings keep the lip in the forward strip but cannot establish three consistent side views.
        var lip = observation(pitchDown: 22, sectors: [45], offsets: [-16, 16])
        lip["measuredDrop"] = ["x": 0.0, "y": -0.18, "z": -1.1]
        let side = observation(pitchDown: 22, sectors: [0, 45], aisle: 45) // The remembered lip still vetoes straight ahead.
        let facing = observation(heading: 45, pitchDown: 22, sectors: [0, 60], picture: 1, checked: [0], aisle: 45)
        var crossing = facing
        crossing["features"] = (facing["features"] as? [[String:Any]] ?? []) + [["kind": "person", "box": [0.42, 0.28, 0.58, 0.9], "confidence": 0.91]]
        try launchFieldNavigation(["rtr1-32.0.jpg", "rtr2-33.7.jpg"], tape: [lip, side, facing, crossing], phase: phase)
        begin("402")
        let body = app.buttons["bodyForward"]
        waitForSpokenCue(["落差", "两侧"], callback: .finished)
        let stopped = events
        XCTAssertEqual(stopped.filter { $0 == "触觉/emergency" }.count, 0)
        XCTAssertFalse(stopped.contains { $0.contains("右转") || $0.contains("左转") || $0.contains("向前迈一步") })
        XCTAssertFalse(body.exists)

        phase.select(1)
        waitForSpokenCue(["原地", "右转"], callback: .finished)
        XCTAssertFalse(body.exists)
        XCTAssertFalse(events.contains("触觉/alignment"))
        phase.select(2)
        waitForOutput("触觉/alignment") // Alignment is a one-shot silent pulse.
        waitForSpokenCue(["身体前方", "再点"], callback: .finished)
        waitUntil("Body confirmation remains available after the completed face instruction", timeout: 12) { body.exists }
        XCTAssertFalse(events.contains { $0.contains("向前迈一步") }, "Fresh clearance and alignment still need the user's tap")
        body.tap()
        waitForSpokenCue(["向前迈一步"])

        phase.select(3) // Same pixels, pose and free sectors. Only the person enters the walking strip.
        waitForSpokenCue(["先停一下"], callback: .finished)
        XCTAssertFalse(body.exists)
        let trace = events
        let advance = try XCTUnwrap(trace.lastIndex { $0.hasPrefix("开读/") && $0.contains("向前迈一步") })
        XCTAssertEqual(trace.dropFirst(advance + 1).filter { $0 == "触觉/emergency" }.count, 1)
        attachFeedback("field-402-drop-turn-advance-person")
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let metrics = try attachMetrics(button: "pause", name: "field-402-drop-and-person-stops")
        let stops = try XCTUnwrap(metrics["stops"] as? [[String:Double]])
        XCTAssertEqual(stops.count, 1) // A fixed drop seen at rest only blocked starting.
        let person = try XCTUnwrap(stops.last)
        let delay = try XCTUnwrap(person["requestedAt"]) - XCTUnwrap(person["detectedAt"])
        XCTAssertTrue((0..<0.55).contains(delay), "Person stop dispatch took \(delay)s after detection")
    }

    func testOriginalRoomPhotoUsesSystemOCRWithoutGroundOrMovementPermission() throws {
        let phase = try ReplayPhase()
        try launchFieldNavigation(["photo-bsg33.jpg"], tape: [observation(pitchDown: -12, sectors: [], readSigns: true)], phase: phase)
        begin("带我去厕所")
        waitUntil("System Vision reads BSG33 from the original photograph", timeout: 40) {
            Self.identifiesFieldPlate(self.cue.label) || self.events.contains { $0.hasPrefix("开读/") && Self.identifiesFieldPlate($0) }
        }
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        XCTAssertFalse(events.contains { $0.contains("向前迈一步") || $0 == "触觉/emergency" })
        attachFeedback("original-room-photo-system-ocr")
    }

    func testRecordedStepLoopKeepsEachSpokenPermitTiedToNewVideoFrames() throws {
        let phase = try ReplayPhase()
        try phase.startGaitOnAcceptedAudio()
        let folder = try fieldFolder()
        let manifest = try Data(contentsOf: folder.appendingPathComponent("navigation-manifest.json"))
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String:Any])
        let rows = try XCTUnwrap(spec["captures"] as? [[String:Any]])
        let scale = try XCTUnwrap(spec["timescale"] as? Double)
        var names: [String] = [], still: [[String:Any]] = [], walking: [[String:Any]] = []
        for row in rows {
            let t = try XCTUnwrap(row["pts"] as? Double) / scale
            let shot: [String:Any] = ["picture":names.count, "sourceFrame":try XCTUnwrap(row["sourceFrame"] as? Int), "pts":t]
            names.append(try XCTUnwrap(row["frame"] as? String))
            if t < 104 { still.append(shot) } else { walking.append(shot) }
        }
        // Geometry, door identity, body pose, ground/landing/volume results and person are injected.
        // Images and their original frame numbers / PTS come from the actual ZHX stream.
        var room = observation(pitchDown: 28, sectors: [0], door: true)
        room["headingOffsets"] = [-1.0, 2, 0, -1]
        var checked = observation(pitchDown: 28, sectors: [0], checked: [0], door: true)
        checked["captures"] = still
        var move = checked
        move["captures"] = walking
        move["positionOffsets"] = [0.0, -0.045, -0.11, -0.18, -0.25, -0.31, -0.34, -0.34, -0.34].map { ["x":0.0, "y":0.0, "z":$0] }
        var freeze = observation(pitchDown: 28, sectors: [], picture: max(0,names.count - 1))
        freeze["freezeCapture"] = true
        freeze["position"] = ["x":0.0, "y":1.4, "z": -0.34]
        let proof = XCTAttachment(data: manifest, uniformTypeIdentifier: "public.json")
        proof.name = "original-recording-pts-and-hashes.json"; proof.lifetime = .keepAlways; add(proof)
        try launchFieldNavigation(names, tape: [room, checked, move, freeze], phase: phase)
        begin("教室门口")
        waitUntil("A door seen behind an unchecked foreground does not issue a walking instruction") {
            self.events.contains(where: { $0.contains("找到门") || $0.contains("脚前") })
        }
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        XCTAssertFalse(events.contains { $0.contains("向前迈一步") || $0 == "触觉/emergency" })
        waitForSpokenCue(["脚前", "落脚"], callback: .finished)
        phase.select(1)
        let forward = app.buttons["bodyForward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 15)); forward.tap()
        let step = "开读/zh-CN/向前迈一步。"
        func awaitSpeech(_ count: Int) throws -> Bool {
            let spoken = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.events.filter { $0 == step }.count >= count
            }, object: nil)
            guard XCTWaiter.wait(for: [spoken], timeout: 16) != .completed else { return true }
            let output = attachFeedback("recorded-step-\(count)-output")
            app.buttons["pause"].tap()
            let diagnostic = try attachMetrics(button: "pause", name: "recorded-step-before-speech-\(count).json")
            let changes = (diagnostic["stepEvents"] as? [[String:Any]] ?? []).map { "\($0["type"] ?? "?") \($0["reason"] ?? "")" }
            XCTFail("Missing walking instruction \(count). " + changes.joined(separator: ", ") + "\n" + output)
            return false
        }
        // Phase 1 → 2 is triggered by the validated AVAudioPlayer cursor, independent
        // of how long XCTRunner takes to read an accessibility snapshot.
        guard try awaitSpeech(1), try awaitSpeech(2) else { return }
        phase.select(3)
        waitUntil("With the camera frozen and the permit withdrawn, the displayed action expires", timeout: 8) {
            !self.cue.label.contains("向前迈一步")
        }
        app.buttons["repeat"].tap()
        waitUntil("Re-listening asks for another observation", timeout: 8) {
            self.events.contains { $0.hasPrefix("开读/") && ($0.contains("重新观察") || $0.contains("再观察") || $0.contains("相机画面")) }
        }
        XCTAssertEqual(events.filter { $0 == step }.count, 2)
        XCTAssertFalse(events.contains("触觉/emergency"), "Normal completion and a frozen camera at rest must not pulse danger")
        app.buttons["pause"].tap(); waitForMessage("已暂停")
        let metrics = try attachMetrics(button: "pause", name: "recorded-step-permit-events.json")
        let audit = try XCTUnwrap(metrics["stepEvents"] as? [[String:Any]])
        let starts = audit.filter { $0["type"] as? String == "speechStarted" }
        guard starts.count == 2 else { XCTFail("Expected two audited playback starts, received \(starts.count)"); return }
        let permits = try starts.map { try XCTUnwrap($0["permit"] as? [String:Any]) }
        XCTAssertNotEqual(permits[0]["id"] as? String, permits[1]["id"] as? String)
        let ids = Set(rows.compactMap { $0["sourceFrame"] as? Int })
        let observed = try zip(starts, permits).map { event, permit in
            let check = try XCTUnwrap(permit["spokenCheck"] as? [String:Any])
            let frames = try XCTUnwrap(check["frames"] as? [[String:Any]]).compactMap { $0["frame"] as? Int }
            XCTAssertEqual(Set(frames).count, 3)
            XCTAssertTrue(Set(frames).isSubset(of: ids))
            let actualStart = try XCTUnwrap(event["time"] as? Double)
            let lastCheck = try XCTUnwrap((check["times"] as? [Double])?.last)
            XCTAssertTrue((0...0.55).contains(actualStart - lastCheck))
            return Set(frames)
        }
        XCTAssertTrue(observed[0].isDisjoint(with: observed[1]))
        let firstID = try XCTUnwrap(permits[0]["id"] as? String)
        let ended = try XCTUnwrap(audit.first { $0["type"] as? String == "completed" && ($0["permit"] as? [String:Any])?["id"] as? String == firstID })
        XCTAssertTrue(ended["settled"] as? Bool == true)
        XCTAssertTrue(audit.contains { $0["type"] as? String == "motionStarted" && ($0["permit"] as? [String:Any])?["id"] as? String == firstID })
    }

    func testRealRelayRecognizesPublicDoorPhoto() throws {
        guard let pairing = Self.runnerSetting("PATHSENSE_LIVE_PROXY") else {
            throw XCTSkip("Set TEST_RUNNER_PATHSENSE_LIVE_PROXY to the Mac relay pairing URL to run the public-photo check")
        }
        let photo = try practicePixels("route-door") // The sole approved source, bundled CC0.
        let upload = try XCTUnwrap(UIImage(data: photo)?.jpegData(compressionQuality: 0.65))
        let witness = try LiveDoorWitness(pairing: pairing, approvedUpload: upload); defer { witness.stop() }
        try launch(trace: true, evidence: [observation(pitchDown: -12, sectors: [], readSigns: false)], fieldPixels: [photo])
        enableCloud(at: witness.server.address); begin("615")
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "云端已连接")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 55), "App must accept a real frame-matched response")
        waitUntil("The unmodified upstream response must identify a door in the approved photo", timeout: 35) { witness.verifiedDoor }
        XCTAssertFalse(app.buttons["bodyForward"].exists)
        let evidence: [String:Any] = ["source":"bundled CC0 route-door.jpg", "uploadMatchesApprovedBytes":true,
                                      "localFeatureCount":0, "ocrEnabled":false, "status":connected.label,
                                      "successfulResponses":witness.receipts]
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                  uniformTypeIdentifier: "public.json")
        proof.name = "live-relay-cc0-door"; proof.lifetime = .keepAlways; add(proof)
    }
    #endif
}

#if DEBUG && targetEnvironment(simulator)
/// The runner owns the phase. Repeated sampling in the app keeps the camera clock live during UI actions.
private final class ReplayPhase {
    let name = "org.crosspointx.pathsense.replay.\(UUID().uuidString)"
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var acceptedAudio: Int32 = NOTIFY_TOKEN_INVALID
    init() throws {
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { throw NSError(domain: "ReplayPhase", code: 1) }
        select(0)
    }
    func select(_ index: UInt64) { XCTAssertEqual(notify_set_state(token, index), UInt32(NOTIFY_STATUS_OK)) }
    func startGaitOnAcceptedAudio() throws {
        let input = token, queue = DispatchQueue(label: name + ".gait")
        let status = notify_register_dispatch(name + ".accepted-step", &acceptedAudio, queue) { _ in
            var phase: UInt64 = 0
            if notify_get_state(input, &phase) == NOTIFY_STATUS_OK, phase == 1 {
                notify_set_state(input, 2)
            }
        }
        guard status == NOTIFY_STATUS_OK else { throw NSError(domain: "ReplayPhase", code: Int(status)) }
    }
    deinit {
        if acceptedAudio != NOTIFY_TOKEN_INVALID { notify_cancel(acceptedAudio) }
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }
}
#endif

/// One bounded HTTP request per connection. Only the runner's random loopback path is served.
private final class LoopbackHTTP: @unchecked Sendable {
    private static let bodyLimit = 3 * (4 * ((8 * 1024 * 1024 + 2) / 3)) + 256 * 1024
    typealias Reply = (Int, Data) -> Void
    private let listener: NWListener
    private let path = "/" + UUID().uuidString
    private let queue = DispatchQueue(label: "PathSense.tests.loopback")
    private let method: String, handle: (Data, @escaping Reply) -> Void
    var address: String { "http://127.0.0.1:\(listener.port!.rawValue)\(path)" }

    init(method: String = "POST", handle: @escaping (Data, @escaping Reply) -> Void) throws {
        self.method = method; self.handle = handle
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue); self.receive(connection, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now()+5) == .success else { listener.cancel(); throw NSError(domain: "LoopbackHTTP", code: 1) }
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, _ prior: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 96_000) { [weak self] chunk, _, closed, error in
            guard let self, let chunk, error == nil else { connection.cancel(); return }
            let buffer = prior + chunk
            guard buffer.count <= Self.bodyLimit + 12_000 else { connection.cancel(); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)), let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
                let headers = head.components(separatedBy: "\r\n"), route = self.method == "POST" ? self.path + "/next" : self.path
                guard headers.first == "\(self.method) \(route) HTTP/1.1" else { connection.cancel(); return }
                let length = headers.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard (0...Self.bodyLimit).contains(length) else { connection.cancel(); return }
                if buffer.count-end.upperBound >= length {
                    self.handle(Data(buffer[end.upperBound...].prefix(length))) { status, response in
                        let type = self.method == "GET" ? "application/octet-stream" : "application/json"
                        let header = Data("HTTP/1.1 \(status) Reply\r\nContent-Type: \(type)\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n".utf8)
                        connection.send(content: header + response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
            }
            if closed { connection.cancel() } else { self.receive(connection, buffer) }
        }
    }
}

private struct RelayFrame {
    let context: [String:Any], stamp: NSDictionary, image: UIImage, jpeg: Data
    let history: [[String:Any]], planning: [String:Any], execution: String
    init?(_ body: Data) {
        guard let packet = (try? JSONSerialization.jsonObject(with: body)) as? [String:Any],
              let context = packet["context"] as? [String:Any], let capture = context["capture"] as? [String:Any],
              let sample = capture["sample"] as? [String:Any], let stamp = sample["id"] as? NSDictionary,
              let b64 = packet["image"] as? String, let data = Data(base64Encoded: b64), let image = UIImage(data: data),
              let cg = image.cgImage, context["image_width"] as? Int == cg.width, context["image_height"] as? Int == cg.height else { return nil }
        guard packet["version"] as? Int == 2, let history = packet["historical_frames"] as? [[String:Any]], history.count <= 2,
              let planning = packet["planning"] as? [String:Any], planning["task"] is String, planning["version"] is Int,
              let execution = packet["execution_state"] as? String, !execution.isEmpty else { return nil }
        self.context = context; self.stamp = stamp; self.image = image; self.jpeg = data
        self.history = history; self.planning = planning; self.execution = execution
    }
    var blind: Bool { (context["features"] as? [[String:Any]])?.isEmpty == true && context["request"] != nil }
}

private func thumbnail(_ image: UIImage) throws -> [UInt8] {
    let cg = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: 32*32)
    try pixels.withUnsafeMutableBytes { raw in
        let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        ctx.interpolationQuality = .medium; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    }
    return pixels
}
private func matchesPhoto(_ pixels: [UInt8], _ reference: [UInt8]) -> Bool {
    zip(pixels, reference).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } < reference.count * 6
}

#if DEBUG && targetEnvironment(simulator)
private final class DelayedRelay: @unchecked Sendable {
    // Annotated jambs and threshold in the first 900 × 1037 sensor window.
    private static let opening = [560.0/900, 144.0/1037, 896.0/900, 843.0/1037]
    static let originalSpeech = "先转向右侧过道。"
    let spokenInstructionReceived = XCTestExpectation(description: "received an actual spoken left turn on a subsequent POST")
    let firstReceived = XCTestExpectation(description: "received the first 0° JPEG")
    let rotatedReceived = XCTestExpectation(description: "received the newer +60° JPEG after releasing the first reply")
    private let queue = DispatchQueue(label: "PathSense.tests.delayed-cloud")
    private var token = Int32(NOTIFY_TOKEN_INVALID)
    private var server: LoopbackHTTP!
    private var firstStamp: NSDictionary?, firstTime = 0.0, pending: (() -> Void)?, lastInstruction: String?
    private var sawRotated = false
    private var log = ["CC0 route-door.jpg; original 1440x1037; sensor windows x=0,540 width=900; heading and ground strips injected"]
    var address: String { server.address }
    var transcript: String { queue.sync { log.joined(separator: "\n") } }
    var instructionAfterReply: String? { queue.sync { lastInstruction } }

    init(phase: ReplayPhase, uploads: [Data]) throws {
        guard notify_register_dispatch(phase.name + ".queued.60", &token, queue, { [weak self] _ in
            guard let self, let release = self.pending else { return }
            self.pending = nil
            self.log.append("App queued its +60° key. Releasing only the held 0° observation, box=\(Self.opening).")
            release()
        }) == NOTIFY_STATUS_OK else { throw NSError(domain: "DelayedRelay.queueNotification", code: 1) }
        server = try LoopbackHTTP { [weak self] body, respond in
            self?.queue.async { [weak self] in self?.receive(body, respond: respond, phase: phase, uploads: uploads) }
        }
    }

    private func receive(_ body: Data, respond: @escaping LoopbackHTTP.Reply, phase: ReplayPhase, uploads: [Data]) {
        guard let frame = RelayFrame(body), frame.blind, frame.context["destination"] as? String == "402",
              let capture = frame.context["capture"] as? [String:Any], let request = frame.context["request"] as? [String:Any],
              let sample = capture["sample"] as? [String:Any], let time = sample["time"] as? Double,
              let captureYaw = capture["heading"] as? Double, let requestYaw = request["heading"] as? Double,
              let number = frame.stamp["frame"] as? Int, let trigger = frame.context["trigger"] as? String,
              let instruction = frame.context["last_instruction"] as? String else {
            log.append("Rejected malformed packet, local features or wrong destination"); respond(422, Data()); return
        }
        let first = firstStamp == nil
        let freshWindow = frame.jpeg == uploads[1]
        let photoMatched = first ? frame.jpeg == uploads[0] : (freshWindow || frame.jpeg == uploads[0])
        if log.count < 14 { log.append("POST \(frame.stamp) t=\(time) capture=\(captureYaw) request=\(requestYaw) trigger=\(trigger) photoMatched=\(photoMatched) last_instruction=\(instruction)") }
        guard photoMatched else { respond(422, Data()); return }
        if first {
            guard trigger == "first_observation", abs(captureYaw) < 0.01, abs(requestYaw) < 0.01,
                  let k = sample["intrinsics"] as? [Double], k.count == 9, let width = sample["width"] as? Int else { respond(422, Data()); return }
            let centerX = (Self.opening[0] + Self.opening[2]) * 0.5 * Double(width)
            let ray = atan2(centerX - k[6], k[0]) * 180 / .pi
            log.append("Capture ray from transmitted intrinsics: \(ray)°")
            guard abs(ray - 30) < 1 else { respond(422, Data()); return }
        } else {
            guard pending == nil, let stamp = firstStamp, let prior = stamp["frame"] as? Int, number > prior, time > firstTime,
                  frame.stamp["session"] as? String == stamp["session"] as? String, frame.stamp["world"] as? Int == stamp["world"] as? Int,
                  abs(captureYaw - 60) < 0.01, abs(requestYaw - 60) < 0.01 else { respond(422, Data()); return }
        }
        let opening: [String:Any] = ["ref":"opening", "kind":"aisle_entrance", "box":Self.opening, "source_frame":frame.stamp]
        let reply: [String:Any] = ["frame_id":frame.stamp, "action":first ? "target_waypoint" : "wait",
                                  "target_ref":first ? "opening" as Any : NSNull(), "speech_zh":first ? Self.originalSpeech : "可以慢慢转动手机，看看周围。",
                                  "uncertain":!first, "hazards":[], "observations":first ? [opening] : [],
                                  "plan":["scene":"unknown", "scene_uncertain":true, "task":"approach_destination", "reason":"可见入口，可复核。", "completion":"entrance_reached"]]
        guard let bytes = try? JSONSerialization.data(withJSONObject: reply) else { respond(500, Data()); return }
        if first {
            firstStamp = frame.stamp; firstTime = time
            pending = { respond(200, bytes) }
            firstReceived.fulfill(); phase.select(2)
        } else {
            if !sawRotated && freshWindow { sawRotated = true; rotatedReceived.fulfill() }
            if lastInstruction == nil, instruction == "请原地向左转约30度。" { lastInstruction = instruction; spokenInstructionReceived.fulfill() }
            respond(200, bytes)
        }
    }
    func stop() { notify_cancel(token); server.stop(); queue.sync { pending = nil } }
}

/// Only this loopback mock interprets the field-video pictogram. It has no upstream connection.
private final class FieldSignMock {
    private let seen = OSAllocatedUnfairLock(initialState: (baseline: false, changed: false))
    private(set) var server: LoopbackHTTP!
    var sawBaseline: Bool { seen.withLock { $0.baseline } }
    var sawChangedSign: Bool { seen.withLock { $0.changed } }
    init(offSign: Data, overhead: Data) throws {
        let baseline = try thumbnail(XCTUnwrap(UIImage(data: offSign)))
        let sign = try thumbnail(XCTUnwrap(UIImage(data: overhead)))
        server = try LoopbackHTTP { [seen] body, respond in
            guard let frame = RelayFrame(body), frame.blind, frame.context["destination"] as? String == "电梯",
                  let pixels = try? thumbnail(frame.image) else { respond(422, Data()); return }
            // The off-sign photo shows a different plaque. Leave it unclassified on subsequent views
            // so a turn must use the remembered elevator instead of getting a fresh semantic answer.
            let isPanel = matchesPhoto(pixels, sign), isBaseline = matchesPhoto(pixels, baseline)
            guard isPanel || isBaseline else { respond(422, Data()); return }
            let first = seen.withLock { state in
                let first = !state.baseline
                if isBaseline { state.baseline = true }
                if isPanel && !first && frame.context["trigger"] as? String == "changed_view" { state.changed = true }
                return first
            }
            // The elevator glyph occupies x=334...426, y=426...519 of the 720x1280 frame.
            // No board-wide arrow is attached to this single-glyph observation.
            let item: [String:Any] = ["ref":"panel", "kind":"sign", "source_frame":frame.stamp, "box":isPanel ? [334.0/720,426.0/1280,426.0/720,519.0/1280] : [0.18,0.09,0.56,0.22]]
            var glyph = item; glyph["sign"] = ["symbol":"elevator"]
            let items = isPanel ? [glyph] : (first ? [item] : [])
            let active = !items.isEmpty
            let reply: [String:Any] = ["frame_id":frame.stamp, "action":active ? "target_waypoint":"wait", "target_ref":active ? "panel" as Any:NSNull(),
                                       "speech_zh":"可以慢慢转动手机，看看周围。", "uncertain":!active, "hazards":[], "observations":items,
                                       "plan":["scene":"unknown", "scene_uncertain":true, "task":"find_signs", "reason":"核对牌面条目。", "completion":"sign_identified"]]
            guard let data = try? JSONSerialization.data(withJSONObject: reply) else { respond(500, Data()); return }
            respond(200, data)
        }
    }
}

/// A read-through witness, distinct from the mock. It forwards the app's public photo and the
/// operator's actual relay response verbatim, and records only a frame-matched door observation.
private final class LiveDoorWitness: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let responses = OSAllocatedUnfairLock(initialState: [[String:Any]]())
    private var transport: URLSession!
    private(set) var server: LoopbackHTTP!
    var receipts: [[String:Any]] { responses.withLockUnchecked { $0 } }
    var verifiedDoor: Bool {
        let all = receipts
        // The UI connection status can only come from a valid 200. Every such response must
        // refer to the uploaded frame and identify a door, including any retries.
        return !all.isEmpty && all.allSatisfy { $0["frameMatched"] as? Bool == true && ($0["doorBoxes"] as? [[Double]])?.isEmpty == false }
    }
    init(pairing: String, approvedUpload: Data) throws {
        guard let pair = URL(string: pairing), ["http", "https"].contains(pair.scheme), pair.host != nil, pair.user == nil,
              pair.password == nil, pair.query == nil, pair.fragment == nil, pair.path.split(separator:"/").count == 1 else {
            throw NSError(domain: "Supply the Mac pairing URL ending with its pairing token", code: 1)
        }
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.timeoutIntervalForRequest = 12
        transport = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        server = try LoopbackHTTP { [transport, responses] body, respond in
            guard let frame = RelayFrame(body), frame.blind, frame.context["destination"] as? String == "615",
                  frame.jpeg == approvedUpload, frame.history.allSatisfy({ ($0["image"] as? String).flatMap { Data(base64Encoded: $0) } == approvedUpload }) else { respond(422, Data()); return }
            var request = URLRequest(url: pair.appendingPathComponent("next")); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
            transport!.dataTask(with: request) { bytes, response, error in
                guard error == nil, let code = (response as? HTTPURLResponse)?.statusCode, let bytes, bytes.count <= 24_576 else { respond(502, Data()); return }
                if code == 200 {
                    let json = (try? JSONSerialization.jsonObject(with: bytes)) as? [String:Any]
                    let observations = json?["observations"] as? [[String:Any]] ?? []
                    let boxes = observations.filter { $0["kind"] as? String == "door" }.compactMap { $0["box"] as? [Double] }
                    let receipt: [String:Any] = ["frame":frame.stamp["frame"] as? Int ?? -1,
                                                "frameMatched":json?["frame_id"] as? NSDictionary == frame.stamp, "doorBoxes":boxes]
                    responses.withLockUnchecked { $0.append(receipt) }
                }
                respond(code, bytes)
            }.resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func stop() { server.stop(); transport.invalidateAndCancel() }
}
#endif
