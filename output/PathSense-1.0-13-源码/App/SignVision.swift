import Foundation
import Vision
import ImageIO
import CoreVideo
import CoreImage

/// Only Apple Vision observations and deterministic sign rules participate in navigation.
final class SignVision: @unchecked Sendable {
    func frame(_ image: CVPixelBuffer, orientation: CGImagePropertyOrientation, target: Destination) throws -> FrameResult {
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: orientation)
        return try wayfinding(handler, target: target, image: CIImage(cvPixelBuffer: image).oriented(orientation))
    }

    func wayfinding(_ handler: VNImageRequestHandler, target: Destination, image: CIImage) throws -> FrameResult {
        if case .room = target, let mention = roomMention(handler, image: image, target: target) { return mention }
        let primary = try strings(handler, languages: ["zh-Hans", "en-US"])
        var text = primary
        if primary.contains(where: { $0.confidence < 0.65 }) {
            var passes = [primary]
            for (scale, corrected) in [(0.73, true), (0.88, false)] {
                let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let bitmap = RouteVision.renderer.createCGImage(resized, from: resized.extent) else { continue }
                let alternate = VNImageRequestHandler(cgImage: bitmap)
                if let pass = try? strings(alternate, languages: ["zh-Hans", "en-US"], correcting: corrected) { passes.append(pass) }
            }
            text = Self.consensus(passes)
        }
        let icons = RouteVision.arrows(image)
        // A printed arrow can be merged into a word by OCR. Read the word again
        // without the graphic before trusting a weak result or associating direction.
        if !icons.isEmpty { text = corroborateLabels(text, beside: icons, using: handler) }
        var lines = text.filter { line in
            !icons.contains { icon in
                guard !line.bounds.isEmpty else { return false }
                let overlap = line.bounds.intersection(icon.bounds)
                return !overlap.isNull && overlap.width * overlap.height > 0.58 * line.bounds.width * line.bounds.height
            }
        }
        lines.append(contentsOf: icons)
        var result = classify(lines, target: target)
        if WayfindingParser.read(result, for: target) == WayfindingSigns() {
            result.scene = RouteVision.scene(handler, image: image)
        }
        return result
    }

    /// A room plaque may print the identifier twice. Check both rows with two different
    /// recognizers before returning a stationary mention. All route decisions, graphics,
    /// restrictions and uncertain layouts still take the full multilingual path.
    private func roomMention(_ handler: VNImageRequestHandler, image: CIImage, target: Destination) -> FrameResult? {
        guard let fast = try? strings(handler, languages: ["en-US"], level: .fast),
              let pair = WayfindingParser.printedRoomPair(in: fast),
              WayfindingParser.sameInscription(pair.number.text, target.text) else { return nil }
        let scale = min(1, 720 / max(image.extent.width, image.extent.height))
        let overview = image.transformed(by: .init(scaleX: scale, y: scale))
        guard let bitmap = RouteVision.renderer.createCGImage(overview, from: overview.extent.integral),
              let bilingual = try? strings(VNImageRequestHandler(cgImage: bitmap), languages: ["zh-Hans", "en-US"]),
              let checked = WayfindingParser.printedRoomPair(in: bilingual),
              WayfindingParser.sameInscription(checked.number.text, pair.number.text),
              checked.number.bounds.contains(CGPoint(x: pair.number.bounds.midX, y: pair.number.bounds.midY)),
              checked.caption.bounds.contains(CGPoint(x: pair.caption.bounds.midX, y: pair.caption.bounds.midY)),
              RouteVision.arrows(image).isEmpty else { return nil }
        let result = classify(Self.consensus([bilingual, fast]), target: target)
        var mention = WayfindingSigns()
        mention.target = .mention
        guard WayfindingParser.read(result, for: target) == mention else { return nil }
        return result
    }

    private func corroborateLabels(_ lines: [SignLine], beside icons: [SignLine], using handler: VNImageRequestHandler) -> [SignLine] {
        let glyphs = CharacterSet(charactersIn: "←→↑↓↖↗↙↘⬅➡⬆⬇⇦⇨⇧⇩ ")
        var result = lines
        for (i, line) in lines.enumerated() where line.confidence < 0.65 && !line.bounds.isEmpty {
            let label = SignParser.normalize(line.text).trimmingCharacters(in: glyphs)
            guard !label.isEmpty else { continue }
            for icon in icons where icon.bounds.intersects(line.bounds) {
                let padded = line.bounds.insetBy(dx: -0.012, dy: -0.02)
                let low = icon.bounds.midX < line.bounds.midX ? icon.bounds.maxX + 0.003 : padded.minX
                let high = icon.bounds.midX > line.bounds.midX ? icon.bounds.minX - 0.003 : padded.maxX
                guard high - low > 0.04 else { continue }
                let region = CGRect(x: low, y: padded.minY, width: high - low, height: padded.height)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let languages = label.unicodeScalars.allSatisfy(\.isASCII) ? ["en-US"] : ["zh-Hans", "en-US"]
                guard !region.isEmpty, let words = try? strings(handler, languages: languages, region: region),
                      words.contains(where: { SignParser.normalize($0.text) == label }) else { continue }
                result[i] = SignLine(label, confidence: Float(SignLine.corroboratedConfidence), bounds: region)
                break
            }
        }
        return result
    }

    /// Compare a whole OCR line with the same area at a second scale, including when
    /// one pass split a floor code and name into separate observations. Keep observed
    /// spellings. A different spelling at the same position cannot count as a vote.
    private static func consensus(_ passes: [[SignLine]]) -> [SignLine] {
        func key(_ text: String) -> String { SignParser.normalize(text).filter { !$0.isWhitespace } }
        func contained(_ item: CGRect, by box: CGRect) -> Bool {
            let area = item.intersection(box)
            return !area.isNull && area.width * area.height > 0.64 * item.width * item.height
        }
        var kept: [SignLine] = []
        // Prefer detailed, corroborated whole lines; add disjoint observations that
        // a prior pass missed. High-confidence sub-lines can replace a weak whole line.
        let tagged = passes.enumerated().flatMap { index, lines in lines.map { (index, $0) } }
        let candidates = tagged.map { index, item -> SignLine in
            let spelling = key(item.text)
            let repeated = passes.enumerated().contains { other, lines in
                guard index != other, !spelling.isEmpty else { return false }
                let sameArea = lines.filter { contained($0.bounds, by: item.bounds.insetBy(dx: -0.012, dy: -0.012)) }
                    .sorted { $0.bounds.minX < $1.bounds.minX }
                return key(sameArea.map(\.text).joined()) == spelling
            }
            return SignLine(item.text, confidence: repeated ? max(Float(SignLine.corroboratedConfidence), item.confidence) : item.confidence, bounds: item.bounds)
        }.sorted { lhs, rhs in
            if (lhs.confidence >= 0.65) != (rhs.confidence >= 0.65) { return lhs.confidence >= 0.65 }
            return lhs.bounds.width * lhs.bounds.height > rhs.bounds.width * rhs.bounds.height
        }
        for candidate in candidates where !kept.contains(where: { contained(candidate.bounds, by: $0.bounds) || contained($0.bounds, by: candidate.bounds) }) { kept.append(candidate) }
        return kept.sorted { $0.bounds.midY > $1.bounds.midY }
    }

    func classify(_ lines: [SignLine], target: Destination) -> FrameResult {
        FrameResult(lines: lines, reading: SignParser.analyze(lines, for: target))
    }
    func strings(_ handler: VNImageRequestHandler, languages: [String], correcting: Bool = false, region: CGRect? = nil, level: VNRequestTextRecognitionLevel = .accurate) throws -> [SignLine] {
        let request = VNRecognizeTextRequest()
        if let region { request.regionOfInterest = region }
        request.recognitionLevel = level
        request.usesLanguageCorrection = correcting
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
