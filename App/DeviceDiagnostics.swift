#if DEBUG && !targetEnvironment(simulator)
import ARKit
import Combine
import Darwin
import Speech
import SwiftUI

/// Explicit Xcode device-check launch only; the file contains counters, never camera pixels or speech input.
@MainActor final class DeviceDiagnostics {
    private struct Report: Encodable {
        let runID = UUID(), startedAt = Date()
        var worldTracking = ARWorldTrackingConfiguration.isSupported
        var sceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        var cameraPermission = AVCaptureDevice.authorizationStatus(for:.video).rawValue
        var micPermission = AVAudioApplication.shared.recordPermission.rawValue
        var recognitionPermission = SFSpeechRecognizer.authorizationStatus().rawValue
        var localMandarin = SFSpeechRecognizer(locale:Locale(identifier:"zh-CN"))?.supportsOnDeviceRecognition ?? false
        var step = "starting", capture = "", voicedChinese = false, voiceFinished = false
        var poses = 0, normalPoses = 0, nearFields = 0, observations = 0, pausesClearCamera = false, freshSession = false
        var hapticPulses: [String] = []
        var trackingStates: [String:Int] = [:]
        var normalTrackingButSteep = 0
        var previewAtStart: CameraPreviewSnapshot?, previewAfterResume: CameraPreviewSnapshot?
    }
    private lazy var report = Report()
    private var began = false
    private var manualInputTask: Task<Void, Never>?
    private static let passageCheck = ProcessInfo.processInfo.arguments.contains("--pathsense-passage-check")
    private var passage: PassageReport?, passageFile: URL?
    private var passageObservers = Set<AnyCancellable>()
    private lazy var passageWrites = DispatchQueue(label: "PathSense.passage-check", qos: .utility)
    private static let watchButton = ProcessInfo.processInfo.arguments.contains("--pathsense-manual-input-check")
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pathsense-device-check")
    func observe(_ event:CameraEvent) {
        if Self.passageCheck {
            switch event {
            case .pose: passage?.sensorEvidence.poseFrames += 1
            case .near(let field): passage?.sensorEvidence.observe(field)
            case .state(let state): passage?.sensorEvidence.observe(state)
            default: break
            }
            return
        }
        guard Self.enabled else {return}
        switch event {
        case .pose(let pose):
            report.poses += 1
            report.trackingStates[pose.tracking, default: 0] += 1
            if pose.normal { report.normalPoses += 1 }
            else if pose.tracking == "normal" { report.normalTrackingButSteep += 1 }
        case .near: report.nearFields += 1
        case .key: report.observations += 1
        case .state(let state): report.capture = state.description
        default: break
        }
    }

    /// Scanner calls this after CueDelivery accepts the instruction, on the same main-actor turn.
    func observeCue(_ cue: LocalCue, hazard: FrontHazard?) {
        passage?.issuedCues.observe(cue, hazard: hazard)
    }

    private func startPassage(_ scanner: Scanner) {
        let snapshot = PassageReport()
        do {
            var folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent("PathSense-passage-check", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = true
            try folder.setResourceValues(flags)
            let file = folder.appendingPathComponent(snapshot.runID.uuidString.lowercased() + ".json")
            try snapshot.write(to: file)
            passageFile = file
            passage = snapshot
        } catch {
            NSLog("PathSense passage report could not be created (%ld)", (error as NSError).code)
            return
        }

        let preset = Destination.named("教室门口") // A named target stays in the active journey only.
        if scanner.cloudEnabled { scanner.configureCloud(enable: false) }
        scanner.clearPrior()
        scanner.entry = preset.text
        scanner.begin()
        guard scanner.target == preset else { checkpointPassage(ending: "preset_unavailable"); return }

        // Published values are synchronous. Close the collector before a subsequent journey can emit events.
        scanner.$journey.dropFirst().sink { [weak self] route in
            if route?.target != preset { self?.checkpointPassage(ending: "navigation_ended") }
            else if route?.stage == .arrived { self?.checkpointPassage(ending: "arrival_reported") }
        }.store(in: &passageObservers)
        scanner.$isPaused.filter { $0 }.sink { [weak self] _ in
            self?.checkpointPassage(ending: "paused")
        }.store(in: &passageObservers)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.checkpointPassage()
        }.store(in: &passageObservers)
    }

    private func checkpointPassage(ending: String? = nil) {
        guard var current = passage, let file = passageFile else { return }
        current.updatedAt = Date()
        if let ending {
            current.status = ending
            passage = nil
            passageFile = nil
            passageObservers.removeAll()
        }
        let snapshot = current
        let write: @Sendable () -> Void = {
            do { try snapshot.write(to: file) }
            catch { NSLog("PathSense passage checkpoint write failed (%ld)", (error as NSError).code) }
        }
        // Periodic IO stays off the cue path. Drain earlier writes before returning a final checkpoint.
        if ending == nil { passageWrites.async(execute: write) }
        else { passageWrites.sync(execute: write) }
    }

    /// This opt-in physical test uses the same entry point as the microphone button.
    /// Retain the permission states and the match result, never the transcript or audio.
    func observeManualDictation(_ scanner: Scanner) {
        guard Self.watchButton else { return }
        manualInputTask?.cancel()
        manualInputTask = Task { [weak self, weak scanner] in
            guard let self, let scanner else { return }
            await self.checkDictation(scanner, automatic: false)
        }
    }

    private func checkDictation(_ scanner: Scanner, automatic: Bool) async {
        struct Sample: Encodable, Equatable {
            let runID: UUID, startedAt: Date, step: String, trigger: String
            let speechPermission: Int, microphonePermission: Int
            let partialObserved: Bool, doorWordsObserved: Bool
            let input: DestinationMicrophone.Diagnostics
            let userFacingError: String?
        }
        let runID = UUID(), startedAt = Date()
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var last: Sample?, partialObserved = false, doorWordsObserved = false
        if automatic { scanner.dictate() }
        while !Task.isCancelled {
            let speech = SFSpeechRecognizer.authorizationStatus()
            let mic = AVAudioApplication.shared.recordPermission
            let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            if scanner.listening && !scanner.entry.isEmpty {
                partialObserved = true
                doorWordsObserved = doorWordsObserved || Destination(wayfinding: scanner.entry)?.isClassroomDoor == true
            }
            let step: String
            if let target = scanner.target {
                step = target.isClassroomDoor ? "recognized_classroom_door" : "recognized_other_destination"
            } else if !scanner.listening {
                step = "ended_without_destination"
            } else if timedOut {
                step = "timed_out"
            } else if speech == .notDetermined {
                step = "awaiting_speech_permission"
            } else if mic == .undetermined {
                step = "awaiting_microphone_permission"
            } else if scanner.dictationPhase == .preparing {
                step = "preparing_microphone"
            } else if scanner.dictationPhase == .finishing {
                step = "finalizing_recognition"
            } else {
                step = "awaiting_recognition"
            }
            let sample = Sample(runID: runID, startedAt: startedAt, step: step,
                                trigger: automatic ? "diagnostic" : "button",
                                speechPermission: speech.rawValue, microphonePermission: Int(mic.rawValue),
                                partialObserved: partialObserved, doorWordsObserved: doorWordsObserved,
                                input: scanner.dictationMetrics,
                                userFacingError: scanner.validation.isEmpty ? nil : scanner.validation)
            if sample != last {
                saveReport(sample, named: "PathSense-dictation-check.json")
                last = sample
            }
            if scanner.target != nil || !scanner.listening { return }
            if timedOut { break }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
        }
        if !Task.isCancelled && automatic && scanner.listening { scanner.cancelDictation() }
    }

    private func saveReport(_ value: some Encodable, named filename: String) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    func run(_ scanner:Scanner) async {
        guard !began else { return }
        if Self.passageCheck {
            began = true
            startPassage(scanner)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--pathsense-dictation-check") {
            began = true
            await checkDictation(scanner, automatic: true)
            return
        }
        guard Self.enabled else { return }
        began = true
        func save(_ step:String) {
            report.step=step; report.cameraPermission=AVCaptureDevice.authorizationStatus(for:.video).rawValue
            saveReport(report, named: "PathSense-device-check.json")
        }
        func waitFor(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition() {
                if ProcessInfo.processInfo.systemUptime >= deadline { return false }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
            return !Task.isCancelled
        }
        func samplePreview() async -> CameraPreviewSnapshot {
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            var sample = scanner.camera.debugPreviewSnapshot()
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                if sample.state == "sampled", sample.presentedCount >= 2 { break }
                do { try await Task.sleep(for: .milliseconds(240)) } catch { break }
                sample = scanner.camera.debugPreviewSnapshot()
            }
            return sample
        }
        save("opened"); scanner.entry="带我去教室门口"; scanner.begin()
        defer { scanner.feedback.devicePulse=nil; scanner.feedback.deviceSpeech=nil; scanner.end() }
        let ready = await waitFor(35) { scanner.canGuide && self.report.observations > 0 && self.report.nearFields > 0 }
        guard ready, let original=scanner.camera.latestPose()?.id else { save("waiting_for_camera_or_permission"); return }
        // Initial camera frames can all be limited while ARKit is still initializing.
        _ = await waitFor(10) { self.report.normalPoses > 0 }
        report.previewAtStart = await samplePreview()
        save("camera"); scanner.pauseOrResume()
        report.pausesClearCamera = await waitFor(5) { scanner.isPaused && scanner.camera.session == nil && scanner.camera.latestPose() == nil }
        guard report.pausesClearCamera else { save("pause_incomplete"); return }
        scanner.feedback.deviceSpeech={ [weak self] text, ended in
            guard text=="请站定。" else {return}; if ended {self?.report.voiceFinished=true} else {self?.report.voicedChinese=true}
        }
        scanner.feedback.devicePulse={ [weak self] pulse in self?.report.hapticPulses.append(pulse) }
        scanner.feedback.deliver("请站定。",sound:true,haptic:.alignment,interrupt:true)
        _ = await waitFor(10) { self.report.voiceFinished }
        scanner.feedback.deliver("",sound:false,haptic:.emergency)
        _ = await waitFor(2) { self.report.hapticPulses.contains("stop-second") }
        save("feedback")
        let observedBeforeResume = report.observations
        scanner.pauseOrResume()
        report.freshSession = await waitFor(20) {
            guard scanner.canGuide, let next = scanner.camera.latestPose()?.id else { return false }
            return !original.sameWorld(next) && self.report.observations > observedBeforeResume
        }
        if report.freshSession { report.previewAfterResume = await samplePreview() }
        save(report.freshSession ? "finished" : "resume_incomplete")
    }
}

private struct PassageReport: Encodable, Sendable {
    let schemaVersion = 1, runID = UUID(), startedAt = Date()
    let modelIdentifier: String = {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }()
    var status = "observing", updatedAt = Date()
    var sensorEvidence = PassageSensors(), issuedCues = PassageCues()
    let walkAcceptance = ["status": "not_assessed", "method": "separate_accompanied_walk"]

    func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

private struct PassageSensors: Encodable, Sendable {
    var captureState = "starting", poseFrames = 0
    // All remaining frame counters use the pose and maps of the same delivered near assessment.
    var nearFrames = 0, depthMapFrames = 0, confidenceMapFrames = 0, visibleFrames = 0
    var trackingStates: [String: Int] = [:]
    var usablePoseFrames = 0, groundPitchFrames = 0, usableGroundPitchFrames = 0
    var minPitchDownDegrees: Int?, maxPitchDownDegrees: Int?
    var frontFrames = ["occupied": 0, "free": 0, "unknown": 0]
    var sectorSamples = ["occupied": 0, "free": 0, "unknown": 0]

    mutating func observe(_ field: NearField) {
        nearFrames += 1
        if field.hasDepthMap { depthMapFrames += 1 }
        if field.hasConfidenceMap { confidenceMapFrames += 1 }
        if field.visible { visibleFrames += 1 }
        let pose = field.pose
        let tracking: String
        switch pose.tracking {
        case "normal", "unavailable", "limited_initializing", "limited_excessiveMotion",
             "limited_insufficientFeatures", "limited_relocalizing": tracking = pose.tracking
        default: tracking = pose.tracking.hasPrefix("limited_") ? "limited_other" : "other"
        }
        trackingStates[tracking, default: 0] += 1
        if pose.normal { usablePoseFrames += 1 }
        if pose.observesGround {
            groundPitchFrames += 1
            if pose.normal { usableGroundPitchFrames += 1 }
        }
        let pitch = pose.pitchDown
        if pitch.isFinite {
            let degrees = Int(pitch.rounded())
            minPitchDownDegrees = min(minPitchDownDegrees ?? degrees, degrees)
            maxPitchDownDegrees = max(maxPitchDownDegrees ?? degrees, degrees)
        }
        frontFrames[field.front.rawValue, default: 0] += 1
        for sector in field.sectors { sectorSamples[sector.state.rawValue, default: 0] += 1 }
    }

    mutating func observe(_ state: CaptureState) {
        switch state {
        case .starting: captureState = "starting"
        case .ready: captureState = "ready"
        case .denied: captureState = "denied"
        case .restricted: captureState = "restricted"
        case .unavailable: captureState = "unavailable"
        case .interrupted: captureState = "interrupted"
        case .failed: captureState = "failed"
        }
    }
}

private struct PassageCues: Encodable, Sendable {
    var directions: [String: Int] = [:], emergencyStops: [String: Int] = [:], otherHolds: [String: Int] = [:]
    var recentActions: [String] = [] // Last 32 in issue order. Totals above cover the entire run.

    mutating func observe(_ cue: LocalCue, hazard: FrontHazard?) {
        let code: String
        switch cue.kind {
        case .turn, .advance:
            code = cue.kind == .advance ? "forward" : Self.turnCode(cue.text)
            directions[code, default: 0] += 1
        case .stop:
            if cue == .dropStop { code = "drop" }
            else if cue.text == "先停一下，标牌写有通行限制。请核对这个入口。" { code = "restriction" }
            else { code = hazard?.rawValue ?? "unattributed_stop" }
            emergencyStops[code, default: 0] += 1
        case .wait, .arrived:
            if cue == .revokeAdvance { code = "advance_revoked" }
            else if cue == .noConfirmedAisle { code = "no_confirmed_aisle" }
            else if cue.kind == .arrived { code = "arrival_cue" }
            else if cue.text == "先停一下，相机画面已中断。" { code = "camera_interruption_revoke" }
            else { return }
            otherHolds[code, default: 0] += 1
        default: return // Readouts can contain OCR, signs or a destination name.
        }
        if recentActions.count == 32 { recentActions.removeFirst() }
        recentActions.append(code)
    }

    // LocalCue carries the final wording, including in-place turns. Store only known relative directions.
    private static func turnCode(_ text: String) -> String {
        for (side, code) in [("左", "left"), ("右", "right")] {
            for degrees in [15, 30, 45, 60] {
                let words = "向\(side)转约\(degrees)度。"
                if text == words || text == "请原地" + words { return "\(code)_\(degrees)" }
            }
            if ["先转向\(side)侧过道。", "请转向\(side)侧门口。", "先朝\(side)侧转动手机。"].contains(text) { return code }
        }
        return "unclassified_turn"
    }
}
#endif
