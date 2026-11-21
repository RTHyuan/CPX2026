import XCTest

final class PathSenseUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }
    private func waitForMessage(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) {
        let message = app.staticTexts["feedbackText"]
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", phrase), object: message)], timeout: 18)
        if result != .completed, app.descendants(matching: .any)["ocrDetails"].firstMatch.exists { app.descendants(matching: .any)["ocrDetails"].firstMatch.tap(); print(app.debugDescription) }
        XCTAssertEqual(result, .completed, "Wanted \(phrase), UI: \(message.exists ? message.label : "missing")", file: file, line: line)
    }
    func testPhotoJourneyReadsSevenRealImages() {
        app.buttons["startPhotos"].tap()
        let rows = [("nearby", "三零三"), ("span", "范围包含"), ("similar", "三零五零"), ("target", "请确认门牌"), ("index", "目录提到"), ("blank", "暂未读清")]
        for (card, message) in rows { app.buttons["practice-\(card)"].tap(); waitForMessage(message) }
        app.buttons["pause"].tap(); waitForMessage("暂停"); XCTAssertFalse(app.buttons["practice-target"].isEnabled)
        app.buttons["pause"].tap(); app.buttons["practice-target"].tap(); waitForMessage("请确认门牌")
        app.buttons["repeat"].tap()
        app.buttons["end"].tap(); app.buttons["facility-电梯"].tap(); app.buttons["startPhotos"].tap()
        app.buttons["practice-facility"].tap(); waitForMessage("读到电梯")
    }
    func testSpokenPhraseInTargetFieldPreservesLeadingZero() {
        let input = app.textFields["targetInput"]
        input.tap()
        input.typeText("我要找零三零五教室")
        app.buttons["startPhotos"].tap()
        app.buttons["practice-target"].tap()
        waitForMessage("读到三零五，正在找零三零五")
        app.buttons["end"].tap()
        XCTAssertTrue(app.buttons["recent-0305"].exists)
    }
    func testSystemPhotoPickerReadsANewRoomForTwoTargets() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PATHSENSE_PICKER_SIMULATOR"] != nil &&
                          environment["PATHSENSE_PICKER_SIMULATOR"] == environment["SIMULATOR_UDID"],
                          "Run Scripts/verify-photo-import.py to prepare an isolated simulator with the 418 sign.")
        func pickRoomSign() {
            app.buttons["photoPicker"].tap()
            // Photos exposes thumbnails as images on this runtime. The generated sign is
            // the most recent asset in the new simulator, ahead of the stock photos.
            let item = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 15), "Expected the imported sign in Photos: \(app.debugDescription)")
            item.tap()
            XCTAssertTrue(app.staticTexts["选取的照片"].waitForExistence(timeout: 12))
        }
        let input = app.textFields["targetInput"]
        input.tap()
        input.typeText("418\n")
        app.buttons["fallback"].tap()
        pickRoomSign()
        waitForMessage("四一八，请确认门牌")
        app.buttons["end"].tap()
        let homeInput = app.textFields["targetInput"]
        homeInput.tap()
        homeInput.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "419\n")
        app.buttons["fallback"].tap()
        pickRoomSign()
        waitForMessage("读到四一八，正在找四一九")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Photos picker · external 418 sign · target 419"
        capture.lifetime = .keepAlways
        add(capture)
    }
    /// Captures the actual review journey and timestamped evidence for the offline exhibit page.
    func testExhibitWalkthrough() throws {
        var markers = [[String: Any]]()
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            markers.append(["name": name, "time": Date().timeIntervalSince1970])
        }
        capture("01-home")
        app.buttons["startPhotos"].tap()
        for (card, phrase) in [("nearby", "三零三"), ("span", "范围包含"), ("similar", "三零五零"), ("target", "请确认门牌"), ("index", "目录提到")] {
            app.buttons["practice-\(card)"].tap()
            waitForMessage(phrase)
            capture(card)
            // Give a viewer time to read each result during the single-take screen recording.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.4))
        }
        markers.append(["name": "end", "time": Date().timeIntervalSince1970])
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: markers), uniformTypeIdentifier: "public.json")
        attachment.name = "walkthrough-times"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLargeTypeAndAccessibleControls() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.textFields["targetInput"].exists)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription, .hitRegion])
        app.buttons["startPhotos"].tap()
        app.buttons["practice-target"].tap()
        waitForMessage("请确认门牌")
        app.buttons["repeat"].tap(); app.buttons["end"].tap()
        XCTAssertTrue(app.textFields["targetInput"].exists)
    }
    func testValidationAndCameraFallback() {
        app.buttons["startLive"].tap(); XCTAssertTrue(app.staticTexts["validation"].exists)
        app.buttons["facility-出口"].tap(); app.buttons["startLive"].tap()
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.buttons["fallback"].waitForExistence(timeout: 8)); app.buttons["fallback"].tap()
        app.buttons["practice-target"].tap(); waitForMessage("暂未读清")
        #endif
    }
}
