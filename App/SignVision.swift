import Foundation
import Vision
import CoreML
import ImageIO
import CoreVideo

struct FrameResult {
    let lines: [SignLine]
    let reading: SignReading
}

enum SignVisionError: LocalizedError {
    case unreadableImage
    var errorDescription: String? { "无法打开这张图片。请换一张清晰的门牌照片。" }
}

/// Requests are per-frame. The shared model is protected across prediction calls.
final class SignVision: @unchecked Sendable {
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

    /// Downsampling applies EXIF orientation exactly once, also for imported HEIC photographs.
    func photo(_ data: Data, target: Destination) throws -> FrameResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1800] as CFDictionary) else { throw SignVisionError.unreadableImage }
        return try recognize(VNImageRequestHandler(cgImage: image, orientation: .up), target: target)
    }

    func frame(_ image: CVPixelBuffer, orientation: CGImagePropertyOrientation, target: Destination) throws -> FrameResult {
        try recognize(VNImageRequestHandler(cvPixelBuffer: image, orientation: orientation), target: target)
    }

    private func recognize(_ handler: VNImageRequestHandler, target: Destination) throws -> FrameResult {
        let initial = try strings(handler, languages: ["zh-Hans", "en-US"])
        let first = classify(initial, target: target)
        // A Latin pass helps distinguish digits and dashes on mixed-language signs. It cannot
        // remove directory context from the first pass or replace conflicting strong evidence.
        guard first.reading.kind == .unclear || initial.contains(where: { $0.confidence < 0.65 }) else { return first }
        let alternate = try strings(handler, languages: ["en-US"])
        var fused = initial
        for candidate in alternate where candidate.confidence >= 0.65 {
            guard candidate.text.range(of: #"[0-9]|\b(ROOM|DIRECTORY|LIFT|ELEVATOR|EXIT|STAIRS|RESTROOM)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            if let i = fused.firstIndex(where: { line in
                let intersection = line.bounds.intersection(candidate.bounds)
                guard !intersection.isNull else { return false }
                return intersection.width * intersection.height > 0.55 * min(line.bounds.width * line.bounds.height, candidate.bounds.width * candidate.bounds.height)
            }) {
                if fused[i].confidence < 0.65 || SignParser.normalize(fused[i].text) == SignParser.normalize(candidate.text) && candidate.confidence > fused[i].confidence { fused[i] = candidate }
            } else { fused.append(candidate) }
        }
        return classify(fused, target: target)
    }
    private func classify(_ lines: [SignLine], target: Destination) -> FrameResult {
        FrameResult(lines: lines, reading: SignParser.analyze(lines, for: target) { (self.directoryLikelihood($0) ?? 0) >= 0.85 })
    }
    private func strings(_ handler: VNImageRequestHandler, languages: [String]) throws -> [SignLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = languages.filter(supported.contains)
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return SignLine(candidate.string, confidence: candidate.confidence, bounds: observation.boundingBox)
        }
    }
}
