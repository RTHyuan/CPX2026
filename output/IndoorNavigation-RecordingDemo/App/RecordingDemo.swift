import AVFoundation
import Foundation
import Darwin

/// A scripted player used only by the separate recording demonstration app.
/// Its narration is bundled demonstration material, not a live model response.
@MainActor final class ScriptedRecordingGuide: NSObject, AVAudioPlayerDelegate {
    struct Cue: Decodable {
        let id: Int
        let time: Double
        let scene: String
        let instruction: String
        let audio: String
    }

    let cues: [Cue]
    private let bundle: Bundle
    private var currentIndex: Int?
    private var player: AVAudioPlayer?
    private var activeCue: Cue?
    private var playbackStart: Task<Void, Never>?
    private var hasStarted = false
    private var completed = false
    private(set) var issue: String?

    static func load(bundle: Bundle = .main) -> ScriptedRecordingGuide? {
        do {
            guard let url = bundle.url(forResource: "cues", withExtension: "json", subdirectory: "RecordingDemo") else {
                throw RecordingError.missingManifest
            }
            let cues = try JSONDecoder().decode([Cue].self, from: Data(contentsOf: url))
                .sorted { $0.time < $1.time }
            guard !cues.isEmpty, Set(cues.map(\.id)).count == cues.count,
                  cues.allSatisfy({ $0.time.isFinite && $0.time >= 0 && !$0.audio.isEmpty
                      && URL(fileURLWithPath: $0.audio).lastPathComponent == $0.audio }),
                  zip(cues, cues.dropFirst()).allSatisfy({ $0.0.time < $0.1.time }) else {
                throw RecordingError.invalidManifest
            }
            return ScriptedRecordingGuide(cues: cues, bundle: bundle)
        } catch {
            emit(["event": "demo_audio_error", "wall_time": Date().timeIntervalSince1970,
                  "reason": "Could not load RecordingDemo/cues.json"])
            return nil
        }
    }

    private init(cues: [Cue], bundle: Bundle) {
        self.cues = cues
        self.bundle = bundle
        super.init()
    }

    /// Return text only when the video enters a different cue. Audio pause/resume
    /// follows the same player, so pausing the video never restarts its sentence.
    func update(position: Double, paused: Bool, sound: Bool) -> Cue? {
        guard position.isFinite else { return nil }
        let selected = cues.lastIndex { $0.time <= position }
        let changed = selected != currentIndex
        if changed {
            stopAudio(reason: "cue_change")
            currentIndex = selected
            activeCue = selected.map { cues[$0] }
            completed = false
        }
        guard let cue = activeCue else { return nil }
        if !sound {
            if player != nil { stopAudio(reason: "muted"); completed = false }
        } else {
            if player == nil, !completed { prepare(cue) }
            if let player, !completed {
                if paused {
                    if player.isPlaying {
                        playbackStart?.cancel(); playbackStart = nil
                        player.pause()
                        log("demo_audio_pause", cue: cue, player: player)
                    }
                } else if !player.isPlaying {
                    play(player, cue: cue)
                }
            }
        }
        return changed ? cue : nil
    }

    func stop() {
        stopAudio(reason: "stopped")
        currentIndex = nil; activeCue = nil; completed = false; issue = nil
    }

    private func prepare(_ cue: Cue) {
        do {
            guard let url = bundle.url(forResource: cue.audio, withExtension: nil, subdirectory: "RecordingDemo") else {
                throw RecordingError.missingAudio
            }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
            let candidate = try AVAudioPlayer(contentsOf: url)
            candidate.delegate = self
            guard candidate.duration > 0, candidate.prepareToPlay() else { throw RecordingError.emptyAudio }
            player = candidate; hasStarted = false; issue = nil
        } catch {
            completed = true
            issue = "The recording narration could not be played."
            Self.emit(["event": "demo_audio_error", "cue": cue.id, "audio": cue.audio,
                       "wall_time": Date().timeIntervalSince1970, "audio_time": 0,
                       "reason": issue!])
        }
    }

    private func play(_ candidate: AVAudioPlayer, cue: Cue) {
        guard candidate.play() else {
            completed = true; issue = "The recording narration did not start."
            return
        }
        let event = hasStarted ? "demo_audio_resume" : "demo_audio_start"
        playbackStart?.cancel()
        playbackStart = Task { [weak self, weak candidate] in
            // Log an advancing output cursor, rather than merely a queued play().
            while let self, let candidate, self.player === candidate, !Task.isCancelled {
                if candidate.isPlaying, candidate.currentTime > 0 {
                    self.hasStarted = true
                    self.log(event, cue: cue, player: candidate)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
    }

    private func stopAudio(reason: String) {
        playbackStart?.cancel(); playbackStart = nil
        guard let player else { return }
        if let cue = activeCue, hasStarted, !completed {
            log("demo_audio_end", cue: cue, player: player, extra: ["completed": false, "reason": reason])
        }
        player.delegate = nil; player.stop()
        self.player = nil; hasStarted = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity,
                  let cue = self.activeCue else { return }
            self.playbackStart?.cancel(); self.playbackStart = nil
            self.completed = true
            self.log("demo_audio_end", cue: cue, player: current, extra: ["completed": flag, "reason": "finished"])
        }
    }

    private func log(_ event: String, cue: Cue, player: AVAudioPlayer, extra: [String: Any] = [:]) {
        var entry: [String: Any] = ["event": event, "cue": cue.id, "wall_time": Date().timeIntervalSince1970,
                                    "audio": cue.audio, "audio_time": player.currentTime,
                                    "audio_duration": player.duration]
        extra.forEach { entry[$0.key] = $0.value }
        Self.emit(entry)
    }

    private static func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private enum RecordingError: Error { case missingManifest, invalidManifest, missingAudio, emptyAudio }
}
