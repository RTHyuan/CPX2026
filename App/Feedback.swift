import AVFoundation
import SwiftUI
import UIKit

enum NavigationHaptic: String { case start, guidance, warning, arrival, alignment, emergency }

@MainActor final class Feedback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var issue: String?
    private let synthesizer = AVSpeechSynthesizer()
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
    func isSpeaking(_ text: String) -> Bool { speaking?.speechString == text || announcement == text }
    private var pending: String?
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

    func deliver(_ text: String, sound: Bool, haptic: NavigationHaptic? = nil, interrupt: Bool = false) {
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
        if !interrupt, let current = speaking?.speechString ?? announcement {
            // One utterance in progress, at most one pending. Never build up old directions.
            pending = current == text ? nil : text
            return
        }
        speak(text, interrupt: interrupt)
    }

    private func mandarinVoice() -> AVSpeechSynthesisVoice? {
        if let voice { return voice }
        let installed = AVSpeechSynthesisVoice.speechVoices()
        // Prefer the user's default Mandarin speaker when it is available locally.
        let preferred = AVSpeechSynthesisVoice(language: "zh-CN")
        if let preferred, Mandarin.voiceRank(preferred.language) == 0,
           installed.contains(where: { $0.identifier == preferred.identifier }) { voice = preferred }
        else {
            var bestRank = Int.max
            for speaker in installed {
                guard let rank = Mandarin.voiceRank(speaker.language) else { continue }
                if rank < bestRank || (rank == bestRank && speaker.quality.rawValue > (voice?.quality.rawValue ?? 0)) {
                    voice = speaker
                    bestRank = rank
                }
            }
        }
        // Some installations can resolve a compact voice before it appears in the inventory.
        if voice == nil, let preferred, Mandarin.voiceRank(preferred.language) != nil { voice = preferred }
        return voice
    }

    private func speak(_ text: String, interrupt: Bool) {
        if UIAccessibility.isVoiceOverRunning {
            releaseAudio()
            issue = nil
            announcement = text
            let priority: UIAccessibilityPriority = interrupt ? .high : .low
            let words = NSAttributedString(string: text, attributes: [.accessibilitySpeechLanguage: "zh-CN", .accessibilitySpeechAnnouncementPriority: priority.rawValue])
            UIAccessibility.post(notification: .announcement, argument: words)
            return
        }
        guard let speaker = mandarinVoice() else {
            issue = "这台设备缺少普通话声音。请在系统设置的辅助功能中下载普通话声音，然后点重听。"
            releaseAudio()
            return
        }
        do {
            if !ownsAudio {
                try audio.setCategory(.playback, mode: .voicePrompt, options: .duckOthers)
                try audio.setActive(true)
                ownsAudio = true
            }
        } catch {
            issue = "声音输出暂时不可用。请检查音量和音频输出设备，然后点重听。"
            return
        }
        let words = AVSpeechUtterance(string: text)
        words.voice = speaker
        words.prefersAssistiveTechnologySettings = false
        words.rate = 0.48
        words.volume = 1
        speaking = words
        issue = nil
        synthesizer.speak(words)
        startupTimeout = Task { [weak self, weak words] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, let words, self.speaking === words else { return }
            self.stop()
            self.voice = nil
            self.issue = "普通话播报未能启动。请检查普通话声音和音频输出，然后点重听。"
        }
    }

    func stop() {
        doublePulse?.cancel()
        if announcement != nil && UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification:.announcement,argument: "") }
        cancelSpeech()
        releaseAudio()
        issue = nil
    }
    private func cancelSpeech() {
        startupTimeout?.cancel()
        pending = nil
        let hadUtterance = speaking != nil
        speaking = nil
        announcement = nil
        if hadUtterance || synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
    private func releaseAudio() {
        guard ownsAudio else { return }
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        ownsAudio = false
    }
    private func advance() {
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
            guard let self, let latest = self.pending ?? self.speaking?.speechString ?? self.announcement else { return }
            self.deliver(latest, sound: true, interrupt: true)
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
