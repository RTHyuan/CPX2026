import Foundation
import Vision
import ImageIO
import CoreImage

// This file is linked only into the macOS verification executable.
extension SignVision {
    /// Offline OCR calibration using source-resolution fixtures.
    func fixture(_ data: Data, target: Destination, guiding: Bool = false) throws -> FrameResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1800] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        if guiding { return try wayfinding(handler, target: target, image: CIImage(cgImage: image)) }
        return try recognize(handler, target: target)
    }

    func baselineFrame(_ image: CVPixelBuffer, orientation: CGImagePropertyOrientation, target: Destination) throws -> FrameResult {
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
}
