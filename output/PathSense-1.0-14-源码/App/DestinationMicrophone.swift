import Accelerate
import AVFoundation
import os
import Speech

/// One input bus and one on-device Speech request per dictation.
@MainActor final class DestinationMicrophone {
    struct Diagnostics: Encodable, Equatable, Sendable {
        var phase = "idle", tapAPI = "none"
        var inputChannels = 0, sampleRate = 0.0
        var bufferCount = 0, appendedFrameCount = 0, signalBufferCount = 0, droppedBufferCount = 0
        var partialCount = 0, finalCount = 0
        var stopReason: String?, outcome: String?, errorDomain: String?, errorCode: Int?
    }

    /// Poll on the main actor. The completed snapshot survives Scanner.begin() -> cancelDictation().
    var diagnostics: Diagnostics {
        var snapshot = report
        if let meter = feed?.meter {
            snapshot.bufferCount = meter.bufferCount
            snapshot.appendedFrameCount = meter.appendedFrameCount
            snapshot.signalBufferCount = meter.signalBufferCount
            snapshot.droppedBufferCount = meter.droppedBufferCount
            if snapshot.errorCode == nil {
                snapshot.errorDomain = meter.errorDomain
                snapshot.errorCode = meter.errorCode
            }
        }
        return snapshot
    }

    private var report = Diagnostics()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audio = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?, tappedInput: AVAudioInputNode?, feed: DestinationAudioFeed?
    private var task: SFSpeechRecognitionTask?, timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var epoch = UUID(), ownsAudio = false
    private var candidate: String?, lastTextAt: TimeInterval = 0
    private var completion: ((String?, String?) -> Void)?

    func start(ready: @escaping () -> Void = {}, partial: @escaping (String) -> Void,
               finish: @escaping (String?, String?) -> Void) {
        cancel()
        let id = UUID()
        epoch = id
        feed = nil
        report = Diagnostics()
        report.phase = "preparing"
        completion = finish
        Task { [weak self] in
            var speech = SFSpeechRecognizer.authorizationStatus()
            if speech == .notDetermined {
                speech = await withCheckedContinuation { reply in
                    SFSpeechRecognizer.requestAuthorization { @Sendable status in reply.resume(returning: status) }
                }
            }
            guard let self, self.epoch == id else { return }
            guard speech == .authorized else {
                self.complete("speechPermission", message: "请在设置中允许语音识别，或输入目的地。")
                return
            }
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard self.epoch == id else { return }
            guard allowed else {
                self.complete("microphonePermission", message: "请在设置中允许麦克风，或输入目的地。")
                return
            }
            guard let recognizer = self.recognizer, recognizer.locale.language.languageCode == .chinese,
                  recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
                self.complete("localRecognizerUnavailable", message: "本机中文听写暂不可用，请输入目的地。")
                return
            }
            self.open(recognizer, id: id, ready: ready, partial: partial)
        }
    }

    private func open(_ recognizer: SFSpeechRecognizer, id: UUID, ready: () -> Void,
                      partial: @escaping (String) -> Void) {
        var stage = "audioSession"
        do {
            // Scanner has stopped and released spoken feedback before calling start().
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            ownsAudio = true
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode, hardware = input.inputFormat(forBus: 0), format = input.outputFormat(forBus: 0)
            report.inputChannels = Int(format.channelCount)
            report.sampleRate = format.sampleRate
            guard hardware.sampleRate > 0, hardware.channelCount > 0, format.sampleRate > 0, format.channelCount > 0 else {
                complete("invalidInputFormat", message: "没有可用的麦克风输入，请检查音频设备。")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .search
            let feed = DestinationAudioFeed(request)
            self.feed = feed
            stage = "installAudioTap"
            report.tapAPI = "installAudioTap"
            try feed.install(on: input)
            tappedInput = input
            // A serial main queue preserves Speech's callback order relative to finish/cancel.
            recognizer.queue = .main
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self, self.epoch == id else { return }
                self.receive(result, error: error, id: id, partial: partial)
            }
            observeInterruptions(engine, id: id)
            stage = "engineStart"
            engine.prepare()
            try engine.start()
            report.phase = "listening"
            startWatchdog(id: id, feed: feed)
            ready()
        } catch {
            record(error)
            complete(stage, message: "麦克风暂不可用，请检查音频设备或输入目的地。")
        }
    }

    private func receive(_ result: SFSpeechRecognitionResult?, error: Error?, id: UUID,
                         partial: (String) -> Void) {
        let final = result?.isFinal == true
        if final { report.finalCount += 1 }
        if let error { record(error) }
        var usableFinal = false
        if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if !final { report.partialCount += 1 }
            // Partials are revisions, not suffixes. Keep the latest usable destination even if
            // a later empty/invalid final or an assistant error arrives on the same callback.
            if Destination(wayfinding: text) != nil {
                candidate = text
                usableFinal = final
            }
            lastTextAt = ProcessInfo.processInfo.systemUptime
            partial(text)
            guard epoch == id else { return } // the UI can cancel or replace this session
        }
        if final || error != nil {
            complete(error == nil ? "finalResult" : "recognitionError", usableFinal: usableFinal)
        }
    }

    private func startWatchdog(id: UUID, feed: DestinationAudioFeed) {
        let began = ProcessInfo.processInfo.systemUptime
        lastTextAt = began
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.epoch == id else { return }
                let now = ProcessInfo.processInfo.systemUptime, meter = feed.meter
                if now - began >= 18 { self.drain("timeLimit"); return }
                if now - began >= 4 && meter.appendedFrameCount == 0 { self.drain("noInput"); return }
                // Let Speech flush even if it has received audible PCM but has emitted no words.
                let rate = self.report.sampleRate
                let quietFrames = meter.appendedFrameCount - meter.lastSignalFrame
                if (self.candidate != nil || Double(meter.signalFrames) >= 0.3 * rate),
                   Double(quietFrames) >= 1.8 * rate, now - self.lastTextAt >= 1.8 {
                    self.drain("silence")
                    return
                }
            }
        }
    }

    func finish(error: String? = nil) {
        guard completion != nil else { return }
        if let error { complete("explicitError", message: error) } else { drain("userEnd") }
    }

    private func drain(_ reason: String) {
        guard completion != nil, report.phase != "draining" else { return }
        report.stopReason = reason
        guard task != nil else { complete(reason); return }
        report.phase = "draining"
        timer?.cancel()
        stopInput() // End the PCM stream. Keep accepting Speech results for this epoch.
        let id = epoch
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.epoch == id else { return }
            self.complete("drainTimeout")
        }
    }

    private func observeInterruptions(_ engine: AVAudioEngine, id: UUID) {
        let center = NotificationCenter.default
        let interrupted: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == id else { return }
                self.drain("interruption")
            }
        }
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: audio, queue: nil) { @Sendable _ in interrupted() })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == id, let input = self.tappedInput else { return }
                let format = input.outputFormat(forBus: 0)
                if self.engine?.isRunning != true || format.sampleRate != self.report.sampleRate || Int(format.channelCount) != self.report.inputChannels {
                    self.drain("inputChanged")
                }
            }
        })
    }

    private func record(_ error: Error) {
        let error = error as NSError
        report.errorDomain = error.domain
        report.errorCode = error.code
    }

    private func stopInput() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if engine?.isRunning == true { engine?.stop() }
        tappedInput?.removeTap(onBus: 0)
        tappedInput = nil
        engine = nil
        feed?.endAudio()
        if ownsAudio {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudio = false
        }
    }

    private func complete(_ reason: String, message: String? = nil, usableFinal: Bool = false) {
        guard let callback = completion else { return }
        let text = candidate
        let needsCancel = reason != "finalResult" && reason != "recognitionError"
        close(cancelTask: needsCancel)
        report.phase = "finished"
        if report.stopReason == nil { report.stopReason = reason }
        if let text {
            report.outcome = usableFinal ? "final" : "partial"
            callback(text, nil)
            return
        }
        let snapshot = diagnostics
        if let message {
            report.outcome = "failed"
            callback(nil, message)
        } else if snapshot.appendedFrameCount == 0 {
            report.outcome = snapshot.bufferCount == 0 ? "noBuffers" : "noAppendedAudio"
            callback(nil, "没有收到可识别的麦克风音频，请重试或输入目的地。")
        } else if snapshot.signalBufferCount == 0 {
            report.outcome = "lowSignal"
            callback(nil, "麦克风输入声音很轻，请靠近麦克风重试。")
        } else {
            report.outcome = "noUsableWords"
            callback(nil, "已收到声音，未识别出目的地，请重试或输入目的地。")
        }
    }

    func cancel() {
        guard completion != nil else { return }
        close(cancelTask: true)
        report.phase = "cancelled"
        report.stopReason = "cancel"
        report.outcome = "cancelled"
    }

    private func close(cancelTask: Bool) {
        epoch = UUID()
        completion = nil
        timer?.cancel()
        timer = nil
        stopInput()
        if cancelTask { task?.cancel() }
        task = nil
        candidate = nil
    }
}

/// The audio tap delivers buffers outside MainActor.
/// All conversion, metering, append and endAudio calls run on a single serial worker.
nonisolated private final class DestinationAudioFeed: @unchecked Sendable {
    struct Meter: Sendable {
        var bufferCount = 0, appendedFrameCount = 0, signalBufferCount = 0, droppedBufferCount = 0
        var signalFrames = 0, lastSignalFrame = 0
        var errorDomain: String?, errorCode: Int?
    }
    private let counters = OSAllocatedUnfairLock(initialState: Meter())
    var meter: Meter { counters.withLock { $0 } }
    private let queue = DispatchQueue(label: "PathSense.destination.pcm", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 12)
    private var request: SFSpeechAudioBufferRecognitionRequest?, converter: AVAudioConverter?
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func install(on input: AVAudioInputNode) throws {
        try input.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buffer, _ in
            guard reserve() else { return }
            queue.async {
                let owned = buffer.withUnsafeAudioBufferList {
                    Self.copyPCM($0, format: buffer.format, frames: buffer.frameLength)
                }
                self.consume(owned?.pcm)
            }
        }
    }

    private func reserve() -> Bool {
        guard slots.wait(timeout: .now()) == .success else {
            counters.withLock { $0.bufferCount += 1; $0.droppedBufferCount += 1 }
            return false
        }
        return true
    }

    /// engine.stop()/removeTap precede the barrier, so accepted buffers reach Speech before EOF.
    func endAudio() {
        queue.sync {
            request?.endAudio()
            request = nil
            converter = nil
        }
    }

    private struct OwnedPCM: @unchecked Sendable { let pcm: AVAudioPCMBuffer }
    private static func copyPCM(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, frames: Int) -> OwnedPCM? {
        guard frames > 0, let length = AVAudioFrameCount(exactly: frames),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { return nil }
        copy.frameLength = length
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        // mBytesPerFrame includes every interleaved channel, or one plane for planar PCM.
        let bytes = frames * Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytes > 0, src.count == dst.count else { return nil }
        for i in src.indices {
            guard bytes <= src[i].mDataByteSize, bytes <= dst[i].mDataByteSize,
                  let from = src[i].mData, let to = dst[i].mData else { return nil }
            memcpy(to, from, bytes)
        }
        return OwnedPCM(pcm: copy)
    }

    private func consume(_ buffer: AVAudioPCMBuffer?) {
        defer { slots.signal() }
        guard let request else { return }
        do {
            guard let buffer, buffer.frameLength > 0 else { throw PCMError.emptyBuffer }
            let (mono, rms) = try speechPCM(buffer)
            request.append(mono) // Send quiet frames too. The meter is never a recognition gate.
            let frames = Int(mono.frameLength)
            counters.withLock {
                $0.bufferCount += 1
                $0.appendedFrameCount += frames
                if rms >= 0.002 { // about -54 dBFS; indicates signal, not necessarily speech
                    $0.signalBufferCount += 1
                    $0.signalFrames += frames
                    $0.lastSignalFrame = $0.appendedFrameCount
                }
            }
        } catch {
            let error = error as NSError
            counters.withLock {
                $0.bufferCount += 1
                $0.droppedBufferCount += 1
                $0.errorDomain = error.domain
                $0.errorCode = error.code
            }
        }
    }

    private enum PCMError: Int, CustomNSError {
        case emptyBuffer = 1, invalidFormat
        static let errorDomain = "PathSense.DestinationMicrophone.PCM"
        var errorCode: Int { rawValue }
    }

    /// Preserve the hardware clock. A quiet channel zero or opposite-phase microphones must
    /// not silence a multichannel route. Select the strongest channel of each real buffer.
    private func speechPCM(_ source: AVAudioPCMBuffer) throws -> (AVAudioPCMBuffer, Float) {
        let buffer: AVAudioPCMBuffer
        if source.format.commonFormat == .pcmFormatFloat32 {
            buffer = source
        } else {
            if converter?.inputFormat != source.format {
                guard let float = AVAudioFormat(standardFormatWithSampleRate: source.format.sampleRate, channels: source.format.channelCount) else { throw PCMError.invalidFormat }
                converter = AVAudioConverter(from: source.format, to: float)
            }
            guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: source.frameLength) else { throw PCMError.invalidFormat }
            try converter.convert(to: converted, from: source)
            buffer = converted
        }
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { throw PCMError.invalidFormat }
        let length = vDSP_Length(buffer.frameLength), stride = vDSP_Stride(buffer.stride)
        var best = 0, rms: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var level: Float = 0
            vDSP_rmsqv(samples[channel], stride, &level, length)
            if level > rms { rms = level; best = channel }
        }
        if buffer.format.channelCount == 1 { return (buffer, rms) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength), let out = mono.floatChannelData else { throw PCMError.invalidFormat }
        mono.frameLength = buffer.frameLength
        let channel = samples[best], output = out[0]
        for frame in 0..<Int(length) { output[frame] = channel[frame * stride] }
        return (mono, rms)
    }
}
