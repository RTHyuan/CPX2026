import CoreImage
import Vision

/// The scene classifier is independent of the requested place. A localized door requires
/// either a door label in a crop, or frame edges that meet a wall/floor boundary on both sides.
enum RouteVision {
    static func scene(_ handler: VNImageRequestHandler, image: CIImage) -> SceneClues {
        let size = image.extent.size
        let classification = VNClassifyImageRequest(), rectangles = VNDetectRectanglesRequest()
        rectangles.minimumSize = 0.18; rectangles.minimumAspectRatio = 0.18
        rectangles.maximumObservations = 6; rectangles.minimumConfidence = 0.55
        try? handler.perform([rectangles])
        // Some runtimes lack an inference backend. Geometry is evaluated independently.
        let classified = (try? handler.perform([classification])) != nil
        let scores = classified ? classification.results ?? [] : []
        func best(_ names: Set<String>) -> Float { scores.filter { names.contains($0.identifier) }.map(\.confidence).max() ?? 0 }
        var result = SceneClues()
        let room = best(["interior_room","bedroom","classroom","living_room","dining_room","kitchen_room","bathroom_room"])
        let shop = best(["interior_shop"]), outside = best(["outdoor"])
        if max(room, shop, outside) >= 0.58 { result.setting = outside > max(room, shop) ? .outside : (shop > room ? .shop : .room) }
        if best(["door"]) >= 0.58 { result.door = "画面中" }
        var regions = rectangles.results ?? []
        if regions.isEmpty {
            let strongest = VNDetectRectanglesRequest()
            try? handler.perform([strongest]); regions = strongest.results ?? []
        }
        let boxes = regions.map(\.boundingBox).filter { rect in
            let aspect = rect.width * size.width / max(1, rect.height * size.height)
            return (0.25...0.85).contains(aspect) && rect.height > 0.36
        }
        var luminance: GrayFrame?
        for box in boxes.prefix(3) {
            let location = box.midX < 0.38 ? "左侧" : (box.midX > 0.62 ? "右侧" : "中央")
            if classified {
                let crop = VNClassifyImageRequest(); crop.regionOfInterest = box.insetBy(dx: -0.035, dy: -0.035).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if (try? handler.perform([crop])) != nil, crop.results?.contains(where: { $0.identifier == "door" && $0.confidence >= 0.67 }) == true {
                    result.door = location; result.doorBoxes.append(box); continue
                }
            }
            if luminance == nil { luminance = gray(image, maxSide: 320) }
            if let luminance, hasFloorAndJambs(box, in: luminance) { result.door = location; result.geometricDoor = true; result.doorBoxes.append(box) }
        }
        // Scale-sensitive rectangle detection can miss a distant jamb at native resolution.
        // Confirm the same floor and vertical-edge geometry on a camera-sized overview.
        if result.doorBoxes.isEmpty, max(size.width, size.height) > 720 {
            let scale = 720 / max(size.width, size.height)
            let overview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let bitmap = renderer.createCGImage(overview, from: overview.extent) {
                let request = VNDetectRectanglesRequest()
                request.minimumAspectRatio = 0.18
                request.maximumObservations = 4
                let thumbnail = VNImageRequestHandler(cgImage: bitmap)
                if (try? thumbnail.perform([request])) != nil, let gray = gray(overview, maxSide: 320) {
                    for box in (request.results ?? []).map(\.boundingBox) {
                        let aspect = box.width * size.width / max(1, box.height * size.height)
                        if (0.25...0.85).contains(aspect), box.height > 0.36, hasFloorAndJambs(box, in: gray) {
                            result.door = box.midX < 0.38 ? "左侧" : (box.midX > 0.62 ? "右侧" : "中央")
                            result.geometricDoor = true
                            result.doorBoxes.append(box)
                        }
                    }
                }
            }
        }
        return result
    }
    #if targetEnvironment(simulator)
    static let renderer = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    #else
    static let renderer = CIContext(options: [.cacheIntermediates: false])
    #endif
    private struct GrayFrame { let pixels: [UInt8]; let w: Int; let h: Int }
    private static func gray(_ image: CIImage, maxSide: CGFloat) -> GrayFrame? {
        let scale = maxSide / max(image.extent.width, image.extent.height)
        guard scale.isFinite && scale > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let bitmap = renderer.createCGImage(scaled, from: scaled.extent) else { return nil }
        let w = bitmap.width, h = bitmap.height
        var pixels = [UInt8](repeating: 0, count: w*h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(bitmap, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return drawn ? GrayFrame(pixels: pixels, w: w, h: h) : nil
    }
    /// Require a wall/floor transition on BOTH sides and two vertical edges that can
    /// be followed nearly to this transition. A floating picture frame alone fails.
    private static func hasFloorAndJambs(_ box: CGRect, in frame: GrayFrame) -> Bool {
        let w = frame.w, h = frame.h, pixels = frame.pixels
        guard w >= 60 && h >= 80, box.minX > 0.1, box.maxX < 0.9, box.maxY > 0.55 else { return false }
        let left = Int(box.minX * CGFloat(w)), right = Int(box.maxX * CGFloat(w))
        let margin = max(3, w/32), leftRange = margin..<max(margin,left-margin), rightRange = min(w-margin,right+margin)..<(w-margin)
        guard leftRange.count > w/20, rightRange.count > w/20 else { return false }
        func strongHorizontal(_ xs: Range<Int>, at y: Int) -> Bool {
            let count = xs.reduce(0) { $0 + (abs(Int(pixels[(y-3)*w+$1])-Int(pixels[(y+3)*w+$1])) >= 10 ? 1 : 0) }
            return Double(count)/Double(xs.count) > 0.58
        }
        let yStart = max(Int(0.63*Double(h)),Int((1-box.midY)*CGFloat(h))+5)
        let yEnd = Int(0.94*Double(h)); guard yStart < yEnd else { return false }
        let top = Int((1-box.maxY+box.height*0.16)*CGFloat(h))
        func vertical(_ x: Int, to bottom: Int) -> Bool {
            let radius = max(2, Int(Double(w)*0.018)); guard bottom-top > h/3 else { return false }
            for column in max(2,x-radius)...min(w-3,x+radius) {
                var good = 0, nearFloor = 0
                for y in top..<bottom where abs(Int(pixels[y*w+column-1])-Int(pixels[y*w+column+1])) >= 5 {
                    good += 1; if y >= bottom-10 { nearFloor += 1 }
                }
                if Double(good)/Double(bottom-top) >= 0.74 && nearFloor >= 6 { return true }
            }
            return false
        }
        for y in stride(from: yEnd-1, through: yStart, by: -2) where strongHorizontal(leftRange,at:y) && strongHorizontal(rightRange,at:y) {
            if vertical(left,to:y-2) && vertical(right,to:y-2) { return true }
        }
        return false
    }
    /// Find filled, straight cardinal sign arrows even when the OCR engine drops their glyphs.
    /// Both polarities are checked. A high mask overlap rejects triangles, letters and rectangles.
    static func arrows(_ image: CIImage) -> [SignLine] {
        guard let frame = gray(image, maxSide: 420) else { return [] }
        let pixels = frame.pixels, w = frame.w, h = frame.h
        guard let lo = pixels.min(), let hi = pixels.max(), Int(hi) - Int(lo) >= 48 else { return [] }
        let threshold = (Int(lo) + Int(hi)) / 2
        var visited = [Bool](repeating: false, count: w*h), result: [SignLine] = []
        for start in pixels.indices where !visited[start] {
            let bright = Int(pixels[start]) > threshold
            var work = [start], offset = 0, minX = start % w, maxX = minX, minY = start / w, maxY = minY
            visited[start] = true
            while offset < work.count {
                let point = work[offset], x = point % w, y = point / w; offset += 1
                minX = min(x,minX); maxX = max(x,maxX); minY = min(y,minY); maxY = max(y,maxY)
                func visit(_ i: Int) { if !visited[i] && (Int(pixels[i]) > threshold) == bright { visited[i] = true; work.append(i) } }
                if x > 0 { visit(point-1) }; if x+1 < w { visit(point+1) }; if y > 0 { visit(point-w) }; if y+1 < h { visit(point+w) }
            }
            let width = maxX-minX+1, height = maxY-minY+1
            guard min(width,height) >= 9, max(width,height) <= max(w,h)/2,
                  minX > 0, minY > 0, maxX+1 < w, maxY+1 < h,
                  (0.33...0.72).contains(Double(work.count)/Double(width*height)) else { continue }
            let horizontal = width >= height
            let aspect = Double(max(width,height))/Double(min(width,height))
            guard (1.03...3.1).contains(aspect) else { continue }
            var best: (SignArrow, Double)?
            for reversed in [false,true] {
                let orientation: SignArrow = horizontal ? (reversed ? .left : .right) : (reversed ? .ahead : .down)
                var hits = 0, union = work.count
                for y in minY...maxY { for x in minX...maxX {
                    let px = (Double(x-minX)+0.5)/Double(width), py = (Double(y-minY)+0.5)/Double(height)
                    var t = horizontal ? px : py; if reversed { t = 1-t }
                    let side = abs((horizontal ? py : px)-0.5)
                    let halfWidth = t < 0.53 ? 0.175 : (1-t)/0.47*0.5
                    if side <= halfWidth { if (Int(pixels[y*w+x]) > threshold) == bright { hits += 1 } else { union += 1 } }
                } }
                let score = Double(hits)/Double(union)
                if score > 0.82 && score > (best?.1 ?? 0) { best = (orientation,score) }
            }
            if let (arrow, confidence) = best {
                let box = CGRect(x: Double(minX)/Double(w), y: 1-Double(maxY+1)/Double(h), width: Double(width)/Double(w), height: Double(height)/Double(h))
                result.append(SignLine(arrow.rawValue,confidence: Float(min(confidence, 1)),bounds: box))
            }
        }
        return result
    }
}
