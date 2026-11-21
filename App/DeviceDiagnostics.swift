#if DEBUG && !targetEnvironment(simulator)
import ARKit
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
    }
    private var report = Report(), began = false
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pathsense-device-check")
    func observe(_ event:CameraEvent) {
        guard Self.enabled else {return}
        switch event {
        case .pose(let pose): report.poses += 1; if pose.normal {report.normalPoses += 1}
        case .near: report.nearFields += 1
        case .key: report.observations += 1
        case .state(let state): report.capture = state.description
        default: break
        }
    }
    func run(_ scanner:Scanner) async {
        guard Self.enabled, !began else {return}; began=true
        func save(_ step:String) {
            report.step=step; report.cameraPermission=AVCaptureDevice.authorizationStatus(for:.video).rawValue
            if let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first, let data=try? JSONEncoder().encode(report) {
                try? data.write(to:directory.appendingPathComponent("PathSense-device-check.json"),options:.atomic)
            }
        }
        func waitFor(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition() {
                if ProcessInfo.processInfo.systemUptime >= deadline { return false }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
            return !Task.isCancelled
        }
        save("opened"); scanner.entry="带我去教室门口"; scanner.begin()
        defer { scanner.feedback.devicePulse=nil; scanner.feedback.deviceSpeech=nil; scanner.end() }
        let ready = await waitFor(35) { scanner.canGuide && self.report.observations > 0 && self.report.nearFields > 0 }
        guard ready, let original=scanner.camera.latestPose()?.id else { save("waiting_for_camera_or_permission"); return }
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
        save(report.freshSession ? "finished" : "resume_incomplete")
    }
}
#endif
