import Foundation
import AVFoundation

// Recording-only narration is reconstructed from the app's actual playback
// cursor events. This is an offline audio merge, not a system-audio capture.
// Usage: merge-recording-audio raw.mp4 events.jsonl metadata.json resourceDir output.mp4

struct MergeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AudioEvent: Decodable {
    let event: String
    let wall_time: Double
    let audio: String?
    let cue: Int?
    let audio_time: Double?
    let audio_duration: Double?
    let completed: Bool?
    let reason: String?
}

struct Segment: Encodable {
    let audio: String
    let cue: Int?
    var recordingStart: Double
    var sourceStart: Double
    var duration: Double
}

struct Active {
    let audio: String
    let cue: Int?
    let wallStart: Double
    let sourceStart: Double
    let audioDuration: Double
}

func number(_ input: Any?) -> Double? {
    guard let value = input as? NSNumber, value.doubleValue.isFinite else { return nil }
    return value.doubleValue
}

func readEvents(_ path: String) throws -> [AudioEvent] {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    var result: [AudioEvent] = []
    for (index, line) in source.components(separatedBy: .newlines).enumerated() {
        // simctl's launch output may include a process line before the JSON logs.
        guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"), start <= end else { continue }
        let data = Data(line[start...end].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["event"] as? String, kind.hasPrefix("demo_audio_") else { continue }
        do {
            let event = try JSONDecoder().decode(AudioEvent.self, from: data)
            guard event.wall_time.isFinite, event.wall_time > 0 else { throw MergeFailure(message: "Invalid event wall_time") }
            result.append(event)
        } catch { throw MergeFailure(message: "Invalid audio event at line \(index + 1): \(error.localizedDescription)") }
    }
    guard !result.isEmpty else { throw MergeFailure(message: "No demo_audio events were found") }
    return result.enumerated().sorted {
        $0.element.wall_time == $1.element.wall_time ? $0.offset < $1.offset : $0.element.wall_time < $1.element.wall_time
    }.map(\.element)
}

func timeline(_ events: [AudioEvent], captureStart: Double, videoDuration: Double) throws -> [Segment] {
    var active: Active?
    var paused: [String: Double] = [:]
    var segments: [Segment] = []
    func key(_ audio: String, _ cue: Int?) -> String { audio + ":" + (cue.map(String.init) ?? "") }
    func close(at wall: Double, sourceEnd: Double?) {
        guard let current = active else { return }
        let inferred = current.sourceStart + max(0, wall - current.wallStart)
        let end = max(current.sourceStart, min(current.audioDuration, sourceEnd ?? inferred))
        var segment = Segment(audio: current.audio, cue: current.cue,
                              recordingStart: current.wallStart - captureStart,
                              sourceStart: current.sourceStart, duration: end - current.sourceStart)
        if segment.recordingStart < 0 {
            let cut = -segment.recordingStart
            segment.sourceStart += cut; segment.duration -= cut; segment.recordingStart = 0
        }
        segment.duration = min(segment.duration, videoDuration - segment.recordingStart)
        if segment.duration > 0.001, segment.recordingStart < videoDuration { segments.append(segment) }
        active = nil
    }
    for event in events {
        guard let audio = event.audio, !audio.isEmpty,
              URL(fileURLWithPath: audio).lastPathComponent == audio else {
            if event.event == "demo_audio_error" { continue }
            throw MergeFailure(message: "An audio event has no safe resource filename")
        }
        let identity = key(audio, event.cue)
        let cursor = event.audio_time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        let duration = event.audio_duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        switch event.event {
        case "demo_audio_start":
            close(at: event.wall_time, sourceEnd: nil)
            guard let duration, cursor <= duration + 0.1 else { throw MergeFailure(message: "Invalid start cursor for \(audio)") }
            active = Active(audio: audio, cue: event.cue, wallStart: event.wall_time - cursor,
                            sourceStart: 0, audioDuration: duration)
            paused.removeValue(forKey: identity)
        case "demo_audio_resume":
            close(at: event.wall_time, sourceEnd: nil)
            guard let duration else { throw MergeFailure(message: "No audio_duration for resumed \(audio)") }
            let offset = paused.removeValue(forKey: identity) ?? cursor
            guard offset <= cursor + 0.1, cursor <= duration + 0.1 else { throw MergeFailure(message: "Invalid resume cursor for \(audio)") }
            active = Active(audio: audio, cue: event.cue,
                            wallStart: event.wall_time - max(0, cursor - offset),
                            sourceStart: offset, audioDuration: duration)
        case "demo_audio_pause":
            if active?.audio == audio, active?.cue == event.cue { close(at: event.wall_time, sourceEnd: cursor) }
            paused[identity] = cursor
        case "demo_audio_end":
            if let current = active, current.audio == audio, current.cue == event.cue {
                // AVAudioPlayer resets currentTime to zero at a successful end.
                let end = event.completed == true ? (duration ?? current.audioDuration)
                    : (cursor >= current.sourceStart && cursor > 0 ? cursor : nil)
                close(at: event.wall_time, sourceEnd: end)
            }
            paused.removeValue(forKey: identity)
        case "demo_audio_error": break
        default: break
        }
    }
    close(at: captureStart + videoDuration, sourceEnd: nil)
    guard !segments.isEmpty else { throw MergeFailure(message: "No audible playback intervals overlap the recording") }
    return segments.sorted { $0.recordingStart < $1.recordingStart }
}

func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 60_000) }

func testTimeline() throws {
    func event(_ name: String, _ wall: Double, _ cursor: Double, _ completed: Bool? = nil) -> AudioEvent {
        AudioEvent(event: "demo_audio_" + name, wall_time: wall, audio: "cue-001.caf", cue: 1,
                   audio_time: cursor, audio_duration: 10, completed: completed, reason: nil)
    }
    let result = try timeline([event("start", 1002.4, 0.4), event("pause", 1004, 2),
                               event("resume", 1006.2, 2.2), event("end", 1014.1, 0, true)],
                              captureStart: 1000, videoDuration: 30)
    guard result.count == 2, abs(result[0].recordingStart - 2) < 0.0001,
          abs(result[0].duration - 2) < 0.0001, abs(result[1].recordingStart - 6) < 0.0001,
          abs(result[1].sourceStart - 2) < 0.0001, abs(result[1].duration - 8) < 0.0001 else {
        throw MergeFailure(message: "Timeline self-test failed")
    }
    let clipped = try timeline([event("start", 999.4, 0.4), event("end", 1009, 0, true)],
                               captureStart: 1000, videoDuration: 5)
    guard clipped.count == 1, clipped[0].recordingStart == 0,
          abs(clipped[0].sourceStart - 1) < 0.0001, abs(clipped[0].duration - 5) < 0.0001 else {
        throw MergeFailure(message: "Timeline clipping self-test failed")
    }
    print("Timeline self-test passed: start correction, pause, resume correction, completed cursor reset, video clipping")
}

func export(_ session: AVAssetExportSession, to destination: URL, type: AVFileType) async throws {
    guard #available(macOS 15.0, *) else { throw MergeFailure(message: "This export helper requires macOS 15 or later") }
    session.shouldOptimizeForNetworkUse = true
    try await session.export(to: destination, as: type)
}

@main struct MergeRecordingAudio {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("merge-recording-audio: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--self-test" { return try testTimeline() }
        guard args.count == 6 else {
            throw MergeFailure(message: "Usage: merge-recording-audio raw.mp4 events.jsonl metadata.json resourceDir output.mp4")
        }
        let rawURL = URL(fileURLWithPath: args[1]).standardizedFileURL
        let resourceDirectory = URL(fileURLWithPath: args[4], isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: args[5]).standardizedFileURL
        guard output != rawURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw MergeFailure(message: "Output must be a new file, distinct from the original recording")
        }
        let metadataData = try Data(contentsOf: URL(fileURLWithPath: args[3]))
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let captureStart = number(metadata["capture_start_walltime"]), captureStart > 0 else {
            throw MergeFailure(message: "metadata.json needs numeric capture_start_walltime")
        }
        let raw = AVURLAsset(url: rawURL)
        let rawVideoDuration = try await raw.load(.duration).seconds
        guard rawVideoDuration.isFinite, rawVideoDuration > 0,
              let rawVideo = try await raw.loadTracks(withMediaType: .video).first else {
            throw MergeFailure(message: "The raw recording has no usable video")
        }
        let trimStart = number(metadata["trim_start_seconds"]) ?? 0
        let trimEnd = number(metadata["trim_end_seconds"]) ?? rawVideoDuration
        guard trimStart >= 0, trimStart < trimEnd, trimEnd <= rawVideoDuration + 0.02 else {
            throw MergeFailure(message: "Trim bounds must satisfy 0 <= trim_start_seconds < trim_end_seconds <= raw video duration")
        }
        let videoDuration = min(trimEnd, rawVideoDuration) - trimStart
        var segments = try timeline(readEvents(args[2]), captureStart: captureStart, videoDuration: rawVideoDuration)
            .compactMap { original -> Segment? in
                var result = original
                result.recordingStart -= trimStart
                if result.recordingStart < 0 {
                    let cut = -result.recordingStart
                    result.sourceStart += cut; result.duration -= cut; result.recordingStart = 0
                }
                result.duration = min(result.duration, videoDuration - result.recordingStart)
                return result.duration > 0.001 && result.recordingStart < videoDuration ? result : nil
            }
        guard !segments.isEmpty else { throw MergeFailure(message: "No narration overlaps the requested trim range") }
        // The app uses one player: an earlier sentence ends when the next one
        // starts. Trim cursor/log scheduling jitter rather than overlapping speech.
        if segments.count > 1 {
            for index in 0..<(segments.count - 1) {
                segments[index].duration = min(segments[index].duration,
                    max(0, segments[index + 1].recordingStart - segments[index].recordingStart))
            }
        }
        let cache = output.deletingLastPathComponent().appendingPathComponent(".merge-audio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        var audioAssets: [String: AVURLAsset] = [:]
        for name in Set(segments.map(\.audio)).sorted() {
            let source = AVURLAsset(url: resourceDirectory.appendingPathComponent(name))
            guard !(try await source.loadTracks(withMediaType: .audio)).isEmpty,
                  let converter = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetAppleM4A) else {
                throw MergeFailure(message: "Cannot read narration resource \(name)")
            }
            let target = cache.appendingPathComponent(name + ".m4a")
            try await export(converter, to: target, type: .m4a)
            audioAssets[name] = AVURLAsset(url: target)
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeFailure(message: "Could not create the output video track")
        }
        let videoRange = try await rawVideo.load(.timeRange)
        try video.insertTimeRange(CMTimeRange(start: CMTimeAdd(videoRange.start, seconds(trimStart)),
                                             duration: seconds(videoDuration)), of: rawVideo, at: .zero)
        video.preferredTransform = try await rawVideo.load(.preferredTransform)
        var mergedSegments: [Segment] = []
        guard let narration = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeFailure(message: "Could not create the narration track")
        }
        // One output audio track ensures every sentence plays in ordinary players.
        for original in segments {
            guard let asset = audioAssets[original.audio],
                  let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MergeFailure(message: "Could not create narration track for \(original.audio)")
            }
            var segment = original
            let duration = try await asset.load(.duration).seconds
            segment.duration = min(segment.duration, duration - segment.sourceStart)
            guard segment.duration > 0 else { continue }
            try narration.insertTimeRange(CMTimeRange(start: seconds(segment.sourceStart), duration: seconds(segment.duration)),
                                          of: source, at: seconds(segment.recordingStart))
            mergedSegments.append(segment)
        }
        guard !mergedSegments.isEmpty else { throw MergeFailure(message: "No narration intervals could be inserted") }
        var mode = "passthrough"
        do {
            guard let writer = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw MergeFailure(message: "Passthrough unavailable")
            }
            try await export(writer, to: output, type: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: output)
            mode = "highest-quality-transcode"
            guard let writer = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw error }
            try await export(writer, to: output, type: .mp4)
        }
        let final = AVURLAsset(url: output)
        let finalVideo = try await final.loadTracks(withMediaType: .video)
        let finalAudio = try await final.loadTracks(withMediaType: .audio)
        let finalDuration = try await final.load(.duration).seconds
        guard finalVideo.count == 1, !finalAudio.isEmpty, abs(finalDuration - videoDuration) <= 0.2 else {
            throw MergeFailure(message: "Export QA failed: missing tracks or changed duration")
        }
        let report: [String: Any] = [
            "output": output.path, "raw_video_duration": rawVideoDuration,
            "trim_start_seconds": trimStart, "trim_end_seconds": min(trimEnd, rawVideoDuration),
            "video_duration": videoDuration, "output_duration": finalDuration,
            "video_tracks": finalVideo.count, "audio_tracks": finalAudio.count,
            "segment_count": mergedSegments.count, "audio_resources": audioAssets.keys.sorted(),
            "export_mode": mode, "capture_start_walltime": captureStart,
            "output_start_walltime": captureStart + trimStart,
            "audio_provenance": "Recording-only bundled English narration, merged offline using actual app playback cursor events; not recorded system audio.",
            "segments": try JSONSerialization.jsonObject(with: JSONEncoder().encode(mergedSegments))
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = output.deletingPathExtension().appendingPathExtension("audio-qa.json")
        try reportData.write(to: reportURL, options: .atomic)
        print(String(decoding: reportData, as: UTF8.self))
    }
}
