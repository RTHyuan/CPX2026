import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Render a synthetic sign on a neutral background. The buffer stays in the native rear
/// sensor's landscape dimensions, including for portrait UI orientations.
func sensorBuffer(image: CIImage, orientation: CGImagePropertyOrientation, context: CIContext) throws -> CVPixelBuffer {
    let isPortrait = orientation == .left || orientation == .right
    let displaySize = isPortrait ? CGSize(width: 720, height: 1280) : CGSize(width: 1280, height: 720)
    let scale = min(displaySize.width / image.extent.width, displaySize.height / image.extent.height) * 0.86
    let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let centered = resized.transformed(by: CGAffineTransform(translationX: displaySize.width / 2 - resized.extent.midX,
                                                             y: displaySize.height / 2 - resized.extent.midY))
    let wall = CIImage(color: CIColor(red: 0.56, green: 0.55, blue: 0.50)).cropped(to: CGRect(origin: .zero, size: displaySize))
    let inverse: CGImagePropertyOrientation = orientation == .right ? .left : orientation == .left ? .right : orientation
    let sensor = centered.composited(over: wall).oriented(inverse)
    let pixels = sensor.transformed(by: CGAffineTransform(translationX: -sensor.extent.minX, y: -sensor.extent.minY))
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    let result = CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &buffer)
    guard result == kCVReturnSuccess, let buffer else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    context.render(pixels, to: buffer, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return buffer
}

/// Exercise the isolated pixel-buffer reader and its historical voting baseline.
/// Test timestamps model independent frames. They do not measure hardware response time.
func verifyCameraFrames(root: URL, reader: SignVision) throws -> Int {
    typealias Sample = (asset: String, time: Double, orientation: CGImagePropertyOrientation, reading: SignKind, delivery: SignKind?)
    let samples: [Sample] = [
        ("nearby", 0.0, .right, .neighbor, nil), ("nearby", 0.5, .right, .neighbor, .neighbor),
        ("target", 1.0, .right, .target, nil),
        ("span", 2.5, .up, .range, nil), ("span", 3.0, .up, .range, .range),
        ("similar", 5.0, .down, .neighbor, nil), ("similar", 5.5, .down, .neighbor, .neighbor),
        ("target", 6.0, .left, .target, nil), ("target", 6.5, .left, .target, .target),
        ("similar", 7.0, .right, .neighbor, nil), ("similar", 7.5, .right, .neighbor, .neighbor),
        ("target", 8.0, .right, .target, nil), ("target", 8.5, .right, .target, .target),
        ("blank", 15.0, .right, .unclear, .unclear), ("blank", 15.5, .right, .unclear, nil),
        ("target", 16.0, .right, .target, nil), ("target", 16.5, .right, .target, .target)
    ]
    let target = Destination("305")!
    let context = CIContext()
    var gate = ScanGate(now: 0)
    var hapticCount = 0
    var failures = 0
    for (index, sample) in samples.enumerated() {
        let file = root.appendingPathComponent("App/Resources/Practice/\(sample.asset).png")
        guard let image = CIImage(contentsOf: file) else { throw CocoaError(.fileReadCorruptFile) }
        let buffer = try sensorBuffer(image: image, orientation: sample.orientation, context: context)
        let frame = try reader.baselineFrame(buffer, orientation: sample.orientation, target: target)
        let confirmed = gate.confirmedFrame(frame, frame: UInt64(index + 1), now: sample.time)
        let delivery = confirmed?.reading
        if let confirmed, confirmed.reading == frame.reading, confirmed.lines != frame.lines { failures += 1 }
        if let delivery, gate.shouldSignalSuccess(for: delivery) { hapticCount += 1 }
        let passed = frame.reading.kind == sample.reading && delivery?.kind == sample.delivery
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") frame \(index + 1): \(sample.asset) → \(frame.reading.kind.rawValue), feedback \(delivery?.kind.rawValue ?? "quiet")")
        if !passed { print("  OCR: \(frame.lines.map(\.text)), expected \(sample.reading), feedback \(String(describing: sample.delivery))") }
    }
    if hapticCount != 1 { failures += 1 }
    print("\(hapticCount == 1 ? "PASS" : "FAIL") requested success haptics in frame sequence: \(hapticCount)")
    return failures
}
