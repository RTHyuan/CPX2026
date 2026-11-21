import Foundation
import CoreML

@main enum VerifyVision {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let model = try MLModel.compileModel(at: root.appendingPathComponent("App/Resources/SignContext.mlmodel"))
        defer { try? FileManager.default.removeItem(at: model) }
        let reader = SignVision(modelURL: model)
        let examples: [(String, String, SignKind)] = [("nearby", "305", .neighbor), ("span", "305", .range), ("similar", "305", .neighbor), ("target", "305", .target), ("index", "305", .directory), ("facility", "电梯", .facility), ("blank", "305", .unclear)]
        var failures = 0
        for (name, target, expected) in examples {
            let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Practice/\(name).png"))
            let result = try reader.photo(data, target: Destination(target)!)
            let pass = result.reading.kind == expected
            if !pass { failures += 1 }
            print("\(pass ? "PASS" : "FAIL") \(name) → \(result.reading.kind.rawValue) \(result.lines.map { "\($0.text) (\($0.confidence))" }.joined(separator: " | "))")
        }
        let layouts: [(LayoutFeatures, Bool)] = [(.init(numbers: 1, lines: 1, separators: 0, directoryWords: 0),false),(.init(numbers: 4, lines: 7, separators: 1, directoryWords: 1),true),(.init(numbers: 1, lines: 2, separators: 0, directoryWords: 0),false),(.init(numbers: 5, lines: 4, separators: 3, directoryWords: 0),true)]
        for (layout, expected) in layouts {
            let probability = reader.directoryLikelihood(layout)
            let pass = probability.map { ($0 >= 0.85) == expected } ?? false
            if !pass { failures += 1 }; print("\(pass ? "PASS" : "FAIL") Core ML \(layout.values) → \(probability ?? -1)")
        }
        failures += try verifyCameraFrames(root: root, reader: reader)
        if CommandLine.arguments.count > 1 {
            guard CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--printable-signs" else {
                print("Usage: Scripts/verify-vision.sh [--printable-signs DIRECTORY_WITH_page-1.png_TO_page-6.png]")
                exit(2)
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let cases: [(Int, String, SignKind, String)] = [(1, "305", .target, "305"), (2, "305", .neighbor, "3050"),
                (3, "305", .range, "301–310"), (4, "305", .directory, "305"), (5, "305", .neighbor, "0305"),
                (5, "0305", .target, "0305"), (6, "B217", .target, "B217"), (6, "217", .neighbor, "B217")]
            for (page, goal, kind, evidence) in cases {
                let data = try Data(contentsOf: directory.appendingPathComponent("page-\(page).png"))
                let result = try reader.photo(data, target: Destination(goal)!)
                let passed = result.reading == SignReading(kind: kind, evidence: evidence)
                if !passed { failures += 1 }
                print("\(passed ? "PASS" : "FAIL") printed page \(page), target \(goal) → \(result.reading.kind.rawValue) \(result.reading.evidence); OCR: \(result.lines.map(\.text))")
            }
        }
        if failures != 0 { exit(1) }
    }
}
