import AVFoundation
import SwiftUI
import UIKit

enum NavigationHaptic: String { case start, guidance, warning, arrival, alignment, emergency }

/// Speech buffers arrive off the main actor. Keep the file and cancellation on one lock.
private final class ModelStepAudioWriter: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var finished = false, ownsFile = true

    init(url: URL) { self.url = url }
    deinit { if ownsFile { try? FileManager.default.removeItem(at: url) } }

    /// nil means more PCM is expected. A zero-length buffer terminates the utterance.
    func append(_ buffer: AVAudioBuffer) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finished = true; file = nil; return false }
        if pcm.frameLength == 0 { finished = true; file = nil; return frames > 0 }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
            return nil
        } catch { finished = true; file = nil; return false }
    }

    func takeFile() -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard finished, frames > 0, ownsFile else { return nil }
        ownsFile = false
        return url
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        finished = true; file = nil
        if ownsFile { try? FileManager.default.removeItem(at: url); ownsFile = false }
    }
}

@MainActor final class Feedback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var issue: String?
    @Published var speechLanguage: GuidanceLanguage = .chinese {
        didSet {
            guard speechLanguage != oldValue else { return }
            stop()
            voice = nil
        }
    }
    private var synthesizer = AVSpeechSynthesizer()
    private let audio = AVAudioSession.sharedInstance()
    private var startImpact: UIImpactFeedbackGenerator?
    private var guidanceImpact: UIImpactFeedbackGenerator?
    #if DEBUG && !targetEnvironment(simulator)
    var devicePulse: ((String)->Void)?, deviceSpeech: ((String,Bool)->Void)?
    #endif
    var onSpeech: ((String,TimeInterval,Bool) -> Void)?
    private var light: UIImpactFeedbackGenerator?, doublePulse: Task<Void,Never>?
    private var notification: UINotificationFeedbackGenerator?
    private var voice: AVSpeechSynthesisVoice?
    private var ownsAudio = false
    private var speaking: AVSpeechUtterance?
    private var announcement: String?
    private struct Line {
        let text: String
        let valid: (() -> Bool)?
        var current: Bool { valid?() ?? true }
    }
    private var currentLine: Line?
    private var stepPlayer: AVAudioPlayer?
    private var stepPlayback: Task<Void, Never>?
    private var stepCompleted: ((Bool) -> Void)?
    private var stepText = ""
    private var stepTemporaryFile: URL?
    private var modelStepSynthesizer: AVSpeechSynthesizer?
    private var modelStepWriter: ModelStepAudioWriter?
    private var modelStepPreparation = UUID()
    private var modelStepCompletion: ((Bool) -> Void)?
    private var modelStepTimeout: Task<Void, Never>?
    private var preparedModelStep: (text: String, url: URL, language: String)?
    var isBusy: Bool { speaking != nil || announcement != nil || stepPlayer != nil }

    /// Render the exact model sentence silently, independently of live scene narration.
    func prepareModelStep(_ text: String, completion: @escaping (Bool) -> Void) {
        if let ready = preparedModelStep, ready.text == text, voiceRank(ready.language) != nil { completion(true); return }
        cancelModelStepPreparation()
        guard !text.isEmpty else { completion(false); return }
        guard let speaker = guidanceVoice() else { issue = missingVoiceIssue; completion(false); return }
        let id = modelStepPreparation
        let writer = ModelStepAudioWriter(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("PathSense-ModelStep-\(id.uuidString).caf"))
        let renderer = AVSpeechSynthesizer()
        renderer.usesApplicationAudioSession = true
        let words = AVSpeechUtterance(string: text)
        words.voice = speaker; words.prefersAssistiveTechnologySettings = false
        words.rate = 0.48; words.volume = 1
        modelStepSynthesizer = renderer; modelStepWriter = writer; modelStepCompletion = completion
        renderer.write(words) { [weak self, writer] buffer in
            guard let success = writer.append(buffer) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.finishModelStepPreparation(id, text: text, language: speaker.language, success: success)
            }
        }
        modelStepTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finishModelStepPreparation(id, text: text, language: speaker.language, success: false)
        }
    }

    private func finishModelStepPreparation(_ id: UUID, text: String, language: String, success: Bool) {
        guard modelStepPreparation == id, let writer = modelStepWriter else { return }
        modelStepPreparation = UUID()
        modelStepTimeout?.cancel(); modelStepTimeout = nil
        let completion = modelStepCompletion; modelStepCompletion = nil
        let renderer = modelStepSynthesizer
        modelStepSynthesizer = nil; modelStepWriter = nil
        if success, let url = writer.takeFile() {
            preparedModelStep = (text, url, language)
            issue = nil
            completion?(true)
        } else {
            renderer?.stopSpeaking(at: .immediate); writer.cancel()
            issue = speechLanguage.text("模型的一步语音暂时无法准备，请重新观察。",
                                        "The next step's speech could not be prepared. Please scan again.")
            completion?(false)
        }
    }

    /// Cancelled or superseded jobs deliberately discard their completion callback.
    func cancelModelStepPreparation() {
        modelStepPreparation = UUID()
        modelStepCompletion = nil
        modelStepTimeout?.cancel(); modelStepTimeout = nil
        modelStepSynthesizer?.stopSpeaking(at: .immediate); modelStepSynthesizer = nil
        modelStepWriter?.cancel(); modelStepWriter = nil
        if let ready = preparedModelStep { try? FileManager.default.removeItem(at: ready.url) }
        preparedModelStep = nil
    }

    func playModelStep(_ text: String, validate: () -> Bool, began: @escaping () -> Bool,
                       ended: @escaping (Bool) -> Void) -> Bool {
        guard let ready = preparedModelStep, ready.text == text, voiceRank(ready.language) != nil else { return false }
        guard playStep(url: ready.url, text: text, language: ready.language, temporary: true,
                       validate: validate, began: began, ended: ended) else { return false }
        preparedModelStep = nil
        return true
    }

    /// Use a pre-rendered Mandarin clip for the one command whose authority expires in the audio queue.
    /// Validate *after* audio activation and preparation, directly before play(). Never queue this clip in VoiceOver.
    func playStep(validate: () -> Bool, began: @escaping () -> Bool, ended: @escaping (Bool) -> Void) -> Bool {
        guard speechLanguage == .chinese,
              let url = Bundle.main.url(forResource: "advance-one-step", withExtension: "caf") else { return false }
        return playStep(url: url, text: "向前迈一步。", language: "zh-CN", temporary: false,
                        validate: validate, began: began, ended: ended)
    }
    private func playStep(url: URL, text: String, language: String, temporary: Bool,
                          validate: () -> Bool, began: @escaping () -> Bool, ended: @escaping (Bool) -> Void) -> Bool {
        guard !isBusy else { return false }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            try activateAudio()
            player.delegate = self
            guard player.prepareToPlay(), validate(), player.play() else { releaseAudio(); return false }
            stepPlayer = player
            stepCompleted = ended
            stepText = text; stepTemporaryFile = temporary ? url : nil
            stepPlayback = Task { [weak self, weak player] in
                // This is the audio player's advancing playback cursor, not the time a prompt was offered.
                while let self, let player, self.stepPlayer === player, !Task.isCancelled {
                    if player.isPlaying, player.currentTime > 0 {
                        guard began() else { self.cancelStep(); return }
                        #if DEBUG && targetEnvironment(simulator)
                        self.record("开读/\(language)/\(text)")
                        SimulatorEvidenceTape.signalAcceptedStepPlayback()
                        #endif
                        #if DEBUG && !targetEnvironment(simulator)
                        self.deviceSpeech?(text, false)
                        #endif
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
            return true
        } catch {
            releaseAudio()
            issue = speechLanguage.text("一步提示暂时无法播放，请检查声音输出后重新观察。",
                                        "The step instruction could not play. Check your audio output, then scan again.")
            return false
        }
    }
    func cancelStep() {
        guard let player = stepPlayer else { return }
        stepPlayback?.cancel(); stepPlayback = nil; stepPlayer = nil; player.delegate = nil; player.stop()
        cleanStepFile()
        let completion = stepCompleted; stepCompleted = nil; completion?(false)
        if !isBusy { releaseAudio() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, let active = self.stepPlayer, ObjectIdentifier(active) == identity else { return }
            let text = self.stepText
            self.stepPlayer = nil; self.stepPlayback?.cancel(); self.stepPlayback = nil
            self.cleanStepFile()
            let completion = self.stepCompleted; self.stepCompleted = nil; completion?(flag)
            #if DEBUG && targetEnvironment(simulator)
            self.record(flag ? "读完/\(text)" : "取消/\(text)")
            #endif
            #if DEBUG && !targetEnvironment(simulator)
            if flag { self.deviceSpeech?(text, true) }
            #endif
            self.advance()
        }
    }
    private func cleanStepFile() {
        if let url = stepTemporaryFile { try? FileManager.default.removeItem(at: url) }
        stepTemporaryFile = nil; stepText = ""
    }
    func isSpeaking(_ text: String) -> Bool { speaking?.speechString == text || announcement == text || stepPlayer != nil && stepText == text }
    private var pending: Line?
    private var startupTimeout: Task<Void, Never>?

    #if DEBUG && targetEnvironment(simulator)
    // In-memory observations of the real output adapters, enabled only for the UI test runner.
    private let tracing = ProcessInfo.processInfo.environment["PATHSENSE_TEST_FEEDBACK"] == "1"
    @Published private(set) var trace: [String] = []
    private func record(_ event: String) { if tracing { trace = Array((trace + [event]).suffix(40)) } }
    #endif

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(announcementEnded(_:)), name: UIAccessibility.announcementDidFinishNotification, object: nil)
        center.addObserver(self, selector: #selector(voiceOverChanged), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
    }

    fileprivate func attachHaptics(to view: UIView) {
        startImpact = UIImpactFeedbackGenerator(style: .medium, view: view)
        guidanceImpact = UIImpactFeedbackGenerator(style: .heavy, view: view)
        light = UIImpactFeedbackGenerator(style: .light, view:view)
        notification = UINotificationFeedbackGenerator(view: view)
    }

    func deliver(_ text: String, sound: Bool, haptic: NavigationHaptic? = nil, interrupt: Bool = false, valid: (() -> Bool)? = nil) {
        if let haptic, let startImpact, let guidanceImpact, let notification {
            switch haptic {
            case .start: startImpact.prepare(); startImpact.impactOccurred()
            case .guidance: guidanceImpact.prepare(); guidanceImpact.impactOccurred()
            case .warning: notification.prepare(); notification.notificationOccurred(.warning)
            case .alignment:
                light?.prepare(); light?.impactOccurred()
                #if DEBUG && !targetEnvironment(simulator)
                devicePulse?("alignment")
                #endif
            case .emergency:
                doublePulse?.cancel(); guidanceImpact.prepare(); guidanceImpact.impactOccurred(); guidanceImpact.prepare()
                #if DEBUG && !targetEnvironment(simulator)
                devicePulse?("stop-first")
                #endif
                doublePulse = Task {
                    do { try await Task.sleep(for:.milliseconds(150)) } catch {return}; guidanceImpact.impactOccurred()
                    #if DEBUG && !targetEnvironment(simulator)
                    devicePulse?("stop-second")
                    #endif
                }
            case .arrival: notification.prepare(); notification.notificationOccurred(.success)
            }
            #if DEBUG && targetEnvironment(simulator)
            record("触觉/\(haptic.rawValue)")
            #endif
        }
        if interrupt { cancelSpeech() }
        guard (sound || UIAccessibility.isVoiceOverRunning), !text.isEmpty else { return }
        let line = Line(text: text, valid: valid)
        guard line.current else { return }
        if !interrupt, isBusy {
            if speaking?.speechString != text && announcement != text { pending = line }
            return
        }
        speak(line, interrupt: interrupt)
    }

    private func voiceRank(_ language: String) -> Int? {
        if speechLanguage == .chinese { return Mandarin.voiceRank(language) }
        let parts = language.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")
        guard parts.first == "en" else { return nil }
        return parts.contains("us") ? 0 : 1
    }

    private var missingVoiceIssue: String {
        speechLanguage.text("这台设备缺少普通话声音。请在系统设置的辅助功能中下载普通话声音，然后点重听。",
                            "An English voice is missing. Download one in Settings > Accessibility, then tap Replay.")
    }

    private func guidanceVoice() -> AVSpeechSynthesisVoice? {
        if let voice { return voice }
        let installed = AVSpeechSynthesisVoice.speechVoices()
        // Prefer the selected locale, then another installed voice of the same language.
        let preferred = AVSpeechSynthesisVoice(language: speechLanguage.speechLocale)
        if let preferred, voiceRank(preferred.language) == 0,
           installed.contains(where: { $0.identifier == preferred.identifier }) { voice = preferred }
        else {
            var bestRank = Int.max
            for speaker in installed {
                guard let rank = voiceRank(speaker.language) else { continue }
                if rank < bestRank || (rank == bestRank && speaker.quality.rawValue > (voice?.quality.rawValue ?? 0)) {
                    voice = speaker
                    bestRank = rank
                }
            }
        }
        // Some installations can resolve a compact voice before it appears in the inventory.
        if voice == nil, let preferred, voiceRank(preferred.language) != nil { voice = preferred }
        return voice
    }

    private func activateAudio() throws {
        if !ownsAudio {
            try audio.setCategory(.playback, mode: .voicePrompt, options: .duckOthers)
            try audio.setActive(true); ownsAudio = true
        }
    }
    private func speak(_ line: Line, interrupt: Bool) {
        guard line.current else { releaseAudio(); return }
        currentLine = line
        let text = line.text
        if UIAccessibility.isVoiceOverRunning {
            releaseAudio()
            issue = nil
            announcement = text
            let priority: UIAccessibilityPriority = interrupt ? .high : .low
            let words = NSAttributedString(string: text, attributes: [.accessibilitySpeechLanguage: speechLanguage.speechLocale, .accessibilitySpeechAnnouncementPriority: priority.rawValue])
            UIAccessibility.post(notification: .announcement, argument: words)
            return
        }
        guard let speaker = guidanceVoice() else {
            issue = missingVoiceIssue
            releaseAudio()
            return
        }
        do {
            try activateAudio()
        } catch {
            issue = speechLanguage.text("声音输出暂时不可用。请检查音量和音频输出设备，然后点重听。",
                                        "Audio output is unavailable. Check the volume and output device, then tap Replay.")
            return
        }
        let words = AVSpeechUtterance(string: text)
        words.voice = speaker
        words.prefersAssistiveTechnologySettings = false
        words.rate = 0.48
        words.volume = 1
        speaking = words
        issue = nil
        guard line.current else { speaking = nil; releaseAudio(); return }
        synthesizer.speak(words)
        startupTimeout = Task { [weak self, weak words] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, let words, self.speaking === words else { return }
            self.stop()
            self.voice = nil
            self.issue = self.speechLanguage.text("普通话播报未能启动。请检查普通话声音和音频输出，然后点重听。",
                                                 "English speech did not start. Check the English voice and audio output, then tap Replay.")
        }
    }

    func stop() {
        cancelModelStepPreparation()
        doublePulse?.cancel()
        if announcement != nil && UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification:.announcement,argument: "") }
        cancelSpeech()
        releaseAudio()
        issue = nil
    }
    private func cancelSpeech() {
        cancelStep(); currentLine = nil
        startupTimeout?.cancel()
        pending = nil
        let hadUtterance = speaking != nil
        speaking = nil
        announcement = nil
        if hadUtterance || synthesizer.isSpeaking {
            // A pending cancel on the old engine must not also cancel the new stop utterance.
            let old = synthesizer
            old.delegate = nil
            old.stopSpeaking(at: .immediate)
            synthesizer = AVSpeechSynthesizer()
            synthesizer.usesApplicationAudioSession = true
            synthesizer.delegate = self
        }
    }
    private func releaseAudio() {
        guard ownsAudio else { return }
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        ownsAudio = false
    }
    private func advance() {
        currentLine = nil
        startupTimeout?.cancel()
        speaking = nil
        announcement = nil
        if let next = pending {
            pending = nil
            speak(next, interrupt: false)
        } else { releaseAudio() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let timestamp=ProcessInfo.processInfo.systemUptime
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.speaking, ObjectIdentifier(current) == id else { return }
            guard self.currentLine?.current == true else { self.cancelSpeech(); self.releaseAudio(); return }
            self.startupTimeout?.cancel()
            #if DEBUG && !targetEnvironment(simulator)
            self.deviceSpeech?(current.speechString,false)
            #endif
            self.onSpeech?(current.speechString,timestamp,false)
            #if DEBUG && targetEnvironment(simulator)
            self.record("开读/\(current.voice?.language ?? "?")/\(current.speechString)")
            #endif
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let timestamp=ProcessInfo.processInfo.systemUptime
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.speaking, ObjectIdentifier(current) == id else { return }
            #if DEBUG && targetEnvironment(simulator)
            self.record("读完/\(current.speechString)")
            #endif
            #if DEBUG && !targetEnvironment(simulator)
            self.deviceSpeech?(current.speechString,true)
            #endif
            self.onSpeech?(current.speechString,timestamp,true)
            self.advance()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.speaking, ObjectIdentifier(current) == id else { return }
            self.advance()
        }
    }
    @objc nonisolated private func announcementEnded(_ note: Notification) {
        guard let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.announcement == text else { return }
            self.advance()
        }
    }
    @objc nonisolated private func voiceOverChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let latest = self.pending ?? self.currentLine, latest.current else { return }
            self.deliver(latest.text, sound: true, interrupt: true, valid: latest.valid)
        }
    }
}

/// Bind UIKit feedback to a view that stays attached across the entire navigation stack.
struct HapticAnchor: UIViewRepresentable {
    let feedback: Feedback
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        feedback.attachHaptics(to: view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
