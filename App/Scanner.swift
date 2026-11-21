import SwiftUI
import AVFAudio
import UIKit

enum ScanMode: String, CaseIterable, Identifiable {
    case live = "连续扫描", snapshot = "拍一次", photos = "照片"
    var id: Self { self }
}

enum PracticeCard: String, CaseIterable, Identifiable {
    case nearby, span, similar, target, index, facility, blank
    var id: Self { self }
    var label: String {
        switch self { case .nearby: return "303"; case .span: return "301–310"; case .similar: return "3050"; case .target: return "305"; case .index: return "楼层目录"; case .facility: return "电梯"; case .blank: return "空白墙面" }
    }
    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "png", subdirectory: "Practice") }
}

@MainActor final class Feedback {
    private let synthesizer = AVSpeechSynthesizer()
    private let haptic = UINotificationFeedbackGenerator()
    func say(_ message: String, sound: Bool, success: Bool = false) {
        if success { haptic.notificationOccurred(.success) }
        if UIAccessibility.isVoiceOverRunning {
            synthesizer.stopSpeaking(at: .immediate)
            UIAccessibility.post(notification: .announcement, argument: message)
            return
        }
        guard sound else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN"); utterance.rate = 0.48
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

@MainActor final class Scanner: ObservableObject {
    let camera = SignCamera()
    private let feedback = Feedback()
    private let worker = DispatchQueue(label: "PathSense.photo", qos: .userInitiated)
    private let photoReader = SignVision()
    @Published var entry = ""
    @Published private(set) var target: Destination?
    @Published private(set) var mode: ScanMode = .live
    @Published private(set) var capture: CaptureState = .starting
    @Published private(set) var isPaused = false
    @Published private(set) var reading: SignReading?
    @Published private(set) var message = ""
    @Published private(set) var raw = [SignLine]()
    @Published private(set) var source = ""
    @Published private(set) var photo: UIImage?
    @Published private(set) var isReading = false
    @Published private(set) var validation = ""
    @Published var sound: Bool { didSet { UserDefaults.standard.set(sound, forKey: "voice"); if !sound { feedback.stop() } } }
    @Published private(set) var history: [String]
    private var token = UUID()
    private var gate = ScanGate(now: ProcessInfo.processInfo.systemUptime)
    private var frame: UInt64 = 0
    private var photoRequest = UUID()
    private var backgrounded = false
    private var readyAnnounced = false

    init() {
        sound = UserDefaults.standard.object(forKey: "voice") as? Bool ?? true
        history = UserDefaults.standard.stringArray(forKey: "recentTargets") ?? []
    }
    func begin(mode: ScanMode) {
        guard let destination = Destination(entry) else { validation = "请说或输入一个完整房号，例如三零五、A305，或选择下方设施。"; feedback.say(validation, sound: sound); return }
        target = destination; self.mode = mode; entry = destination.text; validation = ""
        history = Array(([entry] + history.filter { $0 != entry }).prefix(4))
        UserDefaults.standard.set(history, forKey: "recentTargets")
        gate = ScanGate(now: ProcessInfo.processInfo.systemUptime)
        resetCapture(); openSource()
    }
    func selectMode(_ new: ScanMode) {
        guard new != mode else { return }
        resetCapture(); mode = new; openSource()
    }
    func pauseOrResume() {
        guard target != nil else { return }
        if isPaused { resetCapture(); openSource() }
        else {
            resetCapture(); isPaused = true; message = "扫描已暂停。"; feedback.say(message, sound: sound)
        }
    }
    func end() { resetCapture(); target = nil; validation = "" }
    func background() {
        guard target != nil else { return }
        backgrounded = true
        if !isPaused { resetCapture(); isPaused = true; message = "扫描已暂停，返回后可以继续。" }
    }
    func foreground() {
        if backgrounded { backgrounded = false; return }
        if target != nil, !isPaused, capture == .denied, AVCaptureDevice.authorizationStatus(for: .video) == .authorized { resetCapture(); openSource() }
    }
    func repeatLast() { if !message.isEmpty { feedback.say(message, sound: true) } }
    func shutter() { guard capture == .ready, !isReading, !isPaused else { return }; isReading = true; camera.snapshot() }
    func report(_ error: String) {
        isReading = false
        reading = nil
        raw = []
        photo = nil
        source = ""
        message = error
        feedback.say(error, sound: sound)
    }
    func startImport() -> UUID { photoRequest = UUID(); return photoRequest }
    func importError(for request: UUID) { guard request == photoRequest, mode == .photos, !isPaused else { return }; report("照片未能载入，请选择另一张图片。") }
    func practice(_ card: PracticeCard) {
        guard let url = card.url, let data = try? Data(contentsOf: url) else { report("练习图片未能载入。"); return }
        loadPhoto(data, from: "练习标牌", request: startImport())
    }
    func loadPhoto(_ data: Data, from name: String, request: UUID) {
        guard !isPaused, mode == .photos, let target, request == photoRequest else { return }
        isReading = true; reading = nil; raw = []; message = "正在读取图片…"; source = name
        let current = token
        worker.async { [weak self, photoReader] in
            let preview: UIImage? = ImageThumbnail.make(data)
            let result = Result { try photoReader.photo(data, target: target) }
            DispatchQueue.main.async {
                guard let self, self.token == current, self.photoRequest == request else { return }
                self.isReading = false; self.photo = preview
                switch result { case .success(let frame): self.acceptPhoto(frame); case .failure: self.report("无法读取这张图，请更换照片。") }
            }
        }
    }
    private func acceptPhoto(_ result: FrameResult) {
        raw = result.lines
        display(result.reading, single: true)
    }
    private func resetCapture() {
        token = UUID(); photoRequest = UUID(); gate.restartObservations(now: ProcessInfo.processInfo.systemUptime); frame = 0
        feedback.stop(); camera.stop(); isPaused = false; reading = nil; raw = []; photo = nil; source = ""; message = ""; isReading = false; readyAnnounced = false
    }
    private func openSource() {
        guard let target else { return }
        if mode == .photos {
            message = "选择一张标牌照片，或试用下方练习标牌。"; feedback.say("正在寻找\(SignReading.spoken(target.text))。\(message)", sound: sound); return
        }
        capture = .starting; message = "正在打开相机…"
        camera.updateOrientation(UIDevice.current.orientation)
        let current = token
        camera.start(id: current, target: target, single: mode == .snapshot) { [weak self] event in
            DispatchQueue.main.async { guard let self, self.token == current else { return }; self.handle(event) }
        }
    }
    private func handle(_ event: CameraEvent) {
        switch event {
        case .state(let state):
            capture = state
            if state == .ready {
                if !readyAnnounced, let target {
                    readyAnnounced = true; gate.restartObservations(now: ProcessInfo.processInfo.systemUptime)
                    message = mode == .live ? "请站定，缓慢移动手机寻找标牌。" : "请站定，对准标牌后点拍照识字。"
                    feedback.say("正在寻找\(SignReading.spoken(target.text))。\(message)", sound: sound)
                }
            } else {
                readyAnnounced = false
                reading = nil
                raw = []
                isReading = false
                message = state.description
                if state != .starting { feedback.say(message, sound: sound) }
            }
        case .frame(let result, let single, let sampledAt):
            guard capture == .ready else { return }; isReading = false; raw = result.lines
            if single { acceptPhoto(result) }
            else {
                frame &+= 1
                if let value = gate.ingest(result.reading, frame: frame, now: sampledAt) { display(value, single: false) }
            }
        case .error(let reason): report(reason)
        }
    }
    private func display(_ value: SignReading, single: Bool) {
        guard let target else { return }; reading = value
        message = (single ? "单张图片。" : "") + value.sentence(for: target)
        feedback.say(message, sound: sound, success: gate.shouldSignalSuccess(for: value))
    }
}

import AVFoundation
import ImageIO
private enum ImageThumbnail {
    static func make(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:900] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
