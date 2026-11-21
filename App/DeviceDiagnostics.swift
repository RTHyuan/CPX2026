#if DEBUG && !targetEnvironment(simulator)
import ARKit
import Speech
import SwiftUI

/// Explicit Xcode device-check launch only; the file contains counters, never camera pixels or speech input.
@MainActor final class DeviceDiagnostics {
    private struct Report: Encodable {
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
        save("opened"); scanner.entry="带我去教室门口"; scanner.begin()
        try? await Task.sleep(for:.seconds(10)); save("camera")
        let original=scanner.camera.latestPose()?.id
        if scanner.canGuide {scanner.pauseOrResume()}
        try? await Task.sleep(for:.milliseconds(300)); report.pausesClearCamera=scanner.isPaused && scanner.camera.latestPose()==nil
        scanner.feedback.deviceSpeech={ [weak self] text, ended in
            guard text=="请站定。" else {return}; if ended {self?.report.voiceFinished=true} else {self?.report.voicedChinese=true}
        }
        scanner.feedback.devicePulse={ [weak self] pulse in self?.report.hapticPulses.append(pulse) }
        scanner.feedback.deliver("请站定。",sound:true,haptic:.alignment,interrupt:true)
        try? await Task.sleep(for:.seconds(2)); scanner.feedback.deliver("",sound:false,haptic:.emergency)
        try? await Task.sleep(for:.milliseconds(400)); save("feedback")
        if scanner.isPaused {scanner.pauseOrResume()}
        try? await Task.sleep(for:.seconds(5)); if let original, let revised=scanner.camera.latestPose()?.id {report.freshSession = !original.sameWorld(revised)}
        scanner.end(); scanner.feedback.devicePulse=nil;scanner.feedback.deviceSpeech=nil;save("finished")
    }
}
#endif
