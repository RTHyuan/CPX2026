import AVFoundation
import Speech

/// Owns the audio input only while the user is dictating a destination.
@MainActor final class DestinationMicrophone {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var silence: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var epoch = UUID(), tapped = false, ownsAudio = false
    private var words = ""
    private var completion: ((String?, String?) -> Void)?

    func start(partial: @escaping (String) -> Void, finish: @escaping (String?, String?) -> Void) {
        cancel(); completion = finish
        let id = epoch
        Task { [weak self] in
            let speech = await withCheckedContinuation { reply in SFSpeechRecognizer.requestAuthorization { reply.resume(returning: $0) } }
            guard let self, self.epoch == id else { return }
            guard speech == .authorized else { self.finish(error: "请在设置中允许语音识别，或输入目的地。"); return }
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard self.epoch == id else { return }
            guard allowed else { self.finish(error: "请在设置中允许麦克风，或输入目的地。"); return }
            guard let recognizer = self.recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                self.finish(error: "这台设备暂时无法使用本机中文听写，请输入目的地。"); return
            }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.record, mode: .measurement); try audio.setActive(true); self.ownsAudio = true
                let input = self.engine.inputNode, format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw SpatialError.invalid }
                let req = SFSpeechAudioBufferRecognitionRequest(); req.shouldReportPartialResults = true
                req.requiresOnDeviceRecognition = true; req.taskHint = .search; self.request = req
                try input.installAudioTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(AVAudioPCMBuffer(copying:buffer)) }; self.tapped = true
                self.engine.prepare(); try self.engine.start()
                self.task = recognizer.recognitionTask(with: req) { result, error in
                    let text = result?.bestTranscription.formattedString, final = result?.isFinal == true
                    Task { @MainActor in
                        guard self.epoch == id else { return }
                        if let text, !text.isEmpty {
                            self.words = text; partial(text); self.silence?.cancel()
                            self.silence = Task {
                                do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
                                guard self.epoch == id else { return }; self.finish()
                            }
                        }
                        if final { self.finish() } else if error != nil { self.finish(error: "没有听清，请重试或输入目的地。") }
                    }
                }
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(18)) } catch { return }
                    guard let self, self.epoch == id else { return }; self.finish()
                }
            } catch { self.finish(error: "麦克风暂不可用，请输入目的地。") }
        }
    }
    func finish(error: String? = nil) {
        guard let completion else { return }
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines); cancel()
        completion(error == nil && !text.isEmpty ? text : nil, error ?? (text.isEmpty ? "没有听清，请重试或输入目的地。" : nil))
    }
    func cancel() {
        epoch = UUID(); silence?.cancel(); timeout?.cancel(); completion = nil
        if engine.isRunning { engine.stop() }; if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; words = ""
        if ownsAudio { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); ownsAudio = false }
    }
}
