import Foundation

@main enum VerifyVision {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let reader = SignVision()
        let examples: [(String, String, SignKind)] = [("nearby", "305", .neighbor), ("span", "305", .range), ("similar", "305", .neighbor), ("target", "305", .target), ("index", "305", .directory), ("facility", "电梯", .facility), ("blank", "305", .unclear)]
        var failures = 0
        for (name, target, expected) in examples {
            let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Practice/\(name).png"))
            let result = try reader.fixture(data, target: Destination(target)!)
            let pass = result.reading.kind == expected
            if !pass { failures += 1 }
            print("\(pass ? "PASS" : "FAIL") \(name) → \(result.reading.kind.rawValue) \(result.lines.map { "\($0.text) (\($0.confidence))" }.joined(separator: " | "))")
        }
        failures += try verifyCameraFrames(root: root, reader: reader)
        let external = ProcessInfo.processInfo.environment["PATHSENSE_EXTERNAL_SIGNS"].map { URL(fileURLWithPath: $0) }
        failures += try verifyWayfinding(root: root, reader: reader, novel: external)
        if CommandLine.arguments.count > 1 {
            guard CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--printable-signs" else {
                print("Usage: Scripts/verify-vision.sh [--printable-signs DIRECTORY_WITH_RENDERED_PAGES]")
                exit(2)
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            func pageURL(_ number: Int) -> URL {
                let padded = directory.appendingPathComponent(String(format: "page-%02d.png", number))
                return FileManager.default.fileExists(atPath: padded.path) ? padded : directory.appendingPathComponent("page-\(number).png")
            }
            let cases: [(Int, String, SignKind, String)] = [(1, "305", .target, "305"), (2, "305", .neighbor, "3050"),
                (3, "305", .range, "301–310"), (4, "305", .directory, "305"), (5, "305", .neighbor, "0305"),
                (5, "0305", .target, "0305"), (6, "B217", .target, "B217"), (6, "217", .neighbor, "B217")]
            for (page, goal, kind, evidence) in cases {
                let data = try Data(contentsOf: pageURL(page))
                let result = try reader.fixture(data, target: Destination(goal)!)
                let passed = result.reading == SignReading(kind: kind, evidence: evidence)
                if !passed { failures += 1 }
                print("\(passed ? "PASS" : "FAIL") printed page \(page), target \(goal) → \(result.reading.kind.rawValue) \(result.reading.evidence); OCR: \(result.lines.map(\.text))")
            }
            if FileManager.default.fileExists(atPath: pageURL(7).path) {
                let exhibits: [(String, [JourneyStage])] = [
                    ("402", [.doorway, .directory, .transfer, .transfer, .corridor, .corridor, .verify]),
                    ("眼科", [.doorway, .transfer, .transfer, .corridor, .corridor, .verify]),
                    ("松间书屋", [.doorway, .transfer, .transfer, .corridor, .corridor, .verify])
                ]
                var page = 7
                for (name, stages) in exhibits {
                    let target = Destination(wayfinding: name)!
                    var route = WayfindingJourney(target: target)
                    for expected in stages {
                        let frame = try reader.fixture(Data(contentsOf: pageURL(page)), target: target, guiding: true)
                        route.observe(WayfindingParser.read(frame, for: target, landmark: route.site.landmark))
                        let passed = route.stage == expected
                        if !passed { failures += 1 }
                        print("\(passed ? "PASS" : "FAIL") exhibit page \(page) / \(name): \(route.stage.rawValue) · \(route.cue)")
                        if route.action != nil { route.confirm() }
                        page += 1
                    }
                    if route.stage != .arrived { failures += 1 }
                }
            }
        }
        if failures != 0 { exit(1) }
    }
}
