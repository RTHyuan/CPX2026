import Foundation
import CoreImage

/// Replay continuously sampled camera buffers through the same reader, evidence gate and journey as iOS.
func verifyWayfinding(root: URL, reader: SignVision, novel: URL?) throws -> Int {
    let bundled = root.appendingPathComponent("App/Resources/Practice")
    var failures = 0
    let context = CIContext()
    func run(_ name: String, goal: String, stages: [(String, JourneyStage, String)], directory: URL) throws {
        let target = Destination(wayfinding: goal)!
        var route = WayfindingJourney(target: target)
        var gate = RouteEvidenceGate(now: 0), time: TimeInterval = 0
        for (asset, stage, expected) in stages {
            let url = directory.appendingPathComponent(asset + ".png")
            guard let image = CIImage(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
            let buffer = try sensorBuffer(image: image, orientation: .right, context: context)
            var observed = 0
            // The third frame keeps the same sign visible after a manual transition.
            for sample in 1...3 {
                let frame = try reader.frame(buffer, orientation: .right, target: target)
                let evidence = WayfindingParser.read(frame, for: target, landmark: route.site.landmark)
                if gate.accept(evidence, at: time) {
                    observed += 1
                    route.observe(evidence)
                    let passed = sample == 2 && route.stage == stage && route.cue.contains(expected)
                    print("\(passed ? "PASS" : "FAIL") stream \(name) / \(asset): \(route.cue)")
                    if !passed { failures += 1; print("  OCR \(frame.lines.map(\.text)); evidence \(evidence)") }
                    if route.action == .crossed || route.action == .atTransfer { route.confirm() }
                }
                time += 0.7
            }
            if observed != 1 { failures += 1; print("FAIL stream \(name) / \(asset) delivered \(observed) times") }
        }
        route.confirm()
        if route.stage != .arrived { failures += 1; print("FAIL \(name) did not arrive") }
    }
    let doorTarget = Destination(wayfinding: "402")!
    for (name, expected) in [("route-door.jpg",true),("blank.png",false)] {
        let frame = try reader.fixture(Data(contentsOf: bundled.appendingPathComponent(name)), target: doorTarget, guiding: true)
        let detected = WayfindingParser.read(frame, for: doorTarget).scene.door != nil
        if detected != expected { failures += 1 }
        print("\(detected == expected ? "PASS" : "FAIL") scene \(name) door candidate: \(detected)")
    }
    try run("campus",goal:"我要去402",stages:[("route-exit",.doorway,"出口"),("route-208",.directory,"208"),("route-campus-dir",.transfer,"4F"),("route-lift",.transfer,"右"),("route-4f",.corridor,"4F"),("route-campus-turn",.corridor,"左"),("route-402",.verify,"四零二")],directory: bundled)
    try run("hospital",goal:"眼科",stages:[("route-entrance",.doorway,"入口"),("route-med-dir",.transfer,"3F"),("route-lift",.transfer,"右"),("route-3f",.corridor,"3F"),("route-med-turn",.corridor,"右"),("route-med-plate",.verify,"眼科")],directory: bundled)
    try run("mall",goal:"松间书屋",stages:[("route-entrance",.doorway,"入口"),("route-mall-dir",.transfer,"B1"),("route-lift",.transfer,"右"),("route-b1",.corridor,"B1"),("route-mall-turn",.corridor,"左"),("route-mall-plate",.verify,"松间书屋")],directory: bundled)
    if let novel {
        let target = Destination(wayfinding:"水杉琴房")!
        for (file, expected) in [("unseen-index", TargetSign.listed(RouteSite(level:"6F"))),("unseen-turn", .listed(RouteSite(arrow:.left))),("unseen-front", .plate)] {
            let image = try reader.fixture(Data(contentsOf: novel.appendingPathComponent(file+".png")),target:target,guiding:true)
            let result = WayfindingParser.read(image,for:target)
            if result.target != expected { failures += 1 }
            print("\(result.target == expected ? "PASS" : "FAIL") external \(file): \(String(describing:result.target)); OCR: \(image.lines.map(\.text))")
        }
    }
    if let photo = ProcessInfo.processInfo.environment["PATHSENSE_HOSPITAL_DIRECTORY"] {
        let url = URL(fileURLWithPath: photo)
        // The full sign lets us verify perspective and identical service names printed on two floors.
        for (name, expectedFloors) in [("Administration Office", Set(["2F"])), ("Operating Theatres", Set(["2F", "3F"])), ("手术室", Set(["2F", "3F"]))] {
            let goal = Destination(wayfinding: name)!
            let frame = try reader.fixture(Data(contentsOf: url), target: goal, guiding: true)
            let facts = WayfindingParser.read(frame, for: goal)
            let correct = expectedFloors.count == 1 ? facts.target == .listed(RouteSite(level: expectedFloors.first)) :
                facts.target == .ambiguous && Set(facts.choices.compactMap(\.site.level)) == expectedFloors
            print("\(correct && facts.currentLevel == nil ? "PASS" : "FAIL") photographed directory: \(name) → \(String(describing: facts.target)), \(facts.choices.map(\.site))")
            if !correct || facts.currentLevel != nil { failures += 1 }
        }
    }
    return failures
}
