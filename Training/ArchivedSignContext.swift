// Historical experiment, outside the iOS target, Swift package, and verification scripts.
import Foundation
import CoreML

final class ArchivedSignContext {
    private let predictionLock = NSLock()
    private let context: MLModel?
    var hasContextModel: Bool { context != nil }

    init(modelURL: URL? = Bundle.main.url(forResource: "SignContext", withExtension: "mlmodelc")) {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        context = modelURL.flatMap { try? MLModel(contentsOf: $0, configuration: configuration) }
    }

    func directoryLikelihood(_ features: LayoutFeatures) -> Double? {
        guard let context else { return nil }
        predictionLock.lock()
        defer { predictionLock.unlock() }
        let values = features.values.mapValues { MLFeatureValue(int64: Int64($0)) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: values), let output = try? context.prediction(from: input), let name = context.modelDescription.predictedProbabilitiesName else { return nil }
        return output.featureValue(for: name)?.dictionaryValue["list"]?.doubleValue
    }

    static func verifyLegacyCalibration(in root: URL) throws -> Int {
        let model = try MLModel.compileModel(at: root.appendingPathComponent("App/Resources/SignContext.mlmodel"))
        defer { try? FileManager.default.removeItem(at: model) }
        let reader = ArchivedSignContext(modelURL: model)
        var failures = 0
        let layouts: [(LayoutFeatures, Bool)] = [(.init(numbers: 1, lines: 1, separators: 0, directoryWords: 0),false),(.init(numbers: 4, lines: 7, separators: 1, directoryWords: 1),true),(.init(numbers: 1, lines: 2, separators: 0, directoryWords: 0),false),(.init(numbers: 5, lines: 4, separators: 3, directoryWords: 0),true)]
        for (layout, expected) in layouts {
            let probability = reader.directoryLikelihood(layout)
            let pass = probability.map { ($0 >= 0.85) == expected } ?? false
            if !pass { failures += 1 }; print("\(pass ? "PASS" : "FAIL") Core ML \(layout.values) → \(probability ?? -1)")
        }
        return failures
    }
}
