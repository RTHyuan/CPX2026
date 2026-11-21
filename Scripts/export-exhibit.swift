import AVFoundation
import CoreImage
import Foundation

// Native screen recordings can hold one sample for seconds while a view is still.
// Sample the source display timeline explicitly so browsers retain the first and last holds.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let arguments = CommandLine.arguments
guard arguments.count == 5, let start = Double(arguments[3]), let length = Double(arguments[4]),
      start.isFinite, length.isFinite, start >= 0, length > 0 else {
    fail("Usage: swift export-exhibit.swift INPUT.mp4 OUTPUT.mp4 START_SECONDS DURATION_SECONDS")
}
let source = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
let destination = URL(fileURLWithPath: arguments[2])
guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first,
      start + length <= (try await source.load(.duration)).seconds else { fail("The range is outside the recording.") }
let transform = try await sourceTrack.load(.preferredTransform)
let size = try await sourceTrack.load(.naturalSize)
let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
let scale = min(1, 1280 / max(bounds.width, bounds.height), 720 / min(bounds.width, bounds.height))
let width = 2 * Int((bounds.width * scale / 2).rounded())
let height = 2 * Int((bounds.height * scale / 2).rounded())
let pixels = kCVPixelFormatType_32BGRA
let reader = try AVAssetReader(asset: source)
let decoded = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixels])
decoded.alwaysCopiesSampleData = false
reader.add(decoded)
let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_400_000, AVVideoAllowFrameReorderingKey: false]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: pixels, kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]
])
writer.add(input)
guard reader.startReading(), writer.startWriting() else { fail("Could not start the video decoder or encoder.") }
writer.startSession(atSourceTime: .zero)
guard let pool = adaptor.pixelBufferPool else { fail("Could not allocate video buffers.") }
let renderer = CIContext(options: [.cacheIntermediates: false])
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let frameRate: Int32 = 24
var upcoming = decoded.copyNextSampleBuffer()
var previous: CMSampleBuffer?
var cachedTime = CMTime.invalid
var cachedPixels: CVPixelBuffer?
let startTime = CMTime(seconds: start, preferredTimescale: 6000)
for index in 0..<Int(ceil(length * Double(frameRate))) {
    let time = CMTime(value: Int64(index), timescale: frameRate)
    let sourceTime = startTime + time
    while let frame = upcoming, frame.presentationTimeStamp <= sourceTime {
        previous = frame
        upcoming = decoded.copyNextSampleBuffer()
    }
    guard reader.status != .failed, let frame = previous ?? upcoming, let image = frame.imageBuffer else {
        fail(reader.error?.localizedDescription ?? "No frame at the requested time.")
    }
    while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { fail(writer.error?.localizedDescription ?? "Encoding stopped.") }
        try await Task.sleep(for: .milliseconds(3))
    }
    if cachedTime != frame.presentationTimeStamp {
        var resized: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &resized) == kCVReturnSuccess, let resized else {
            fail("Could not allocate an output frame.")
        }
        autoreleasepool {
            let oriented = CIImage(cvPixelBuffer: image).transformed(by: transform)
            let atOrigin = oriented.transformed(by: .init(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
            let scaled = atOrigin.transformed(by: .init(scaleX: CGFloat(width) / atOrigin.extent.width,
                                                         y: CGFloat(height) / atOrigin.extent.height))
            renderer.render(scaled, to: resized, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        }
        cachedTime = frame.presentationTimeStamp
        cachedPixels = resized
    }
    guard let cachedPixels, adaptor.append(cachedPixels, withPresentationTime: time) else {
        fail(writer.error?.localizedDescription ?? "Could not append a video frame.")
    }
}
reader.cancelReading()
writer.endSession(atSourceTime: CMTime(seconds: length, preferredTimescale: 6000))
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { fail(writer.error?.localizedDescription ?? "Export failed.") }
let movie = AVURLAsset(url: destination)
guard let track = try await movie.loadTracks(withMediaType: .video).first else { fail("Export has no video track.") }
let actual = try await track.load(.timeRange)
guard abs(actual.start.seconds) < 0.05, abs(actual.duration.seconds - length) < 0.06 else {
    fail("Encoded track starts at \(actual.start.seconds) and lasts \(actual.duration.seconds) seconds. Expected 0 and \(length).")
}
