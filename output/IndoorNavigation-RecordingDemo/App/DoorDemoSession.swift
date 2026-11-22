import Foundation
import SwiftUI
import UIKit

/// A short, current-view demonstration: DS supplies the words and the next direction;
/// the existing near-field executor checks each individual step before it is spoken.
@MainActor final class DoorDemoSession: ObservableObject {
    let camera = SignCamera()
    let feedback = Feedback()
    @Published private(set) var language: GuidanceLanguage = .chinese
    @Published var destination = "门口"
    @Published var sound = true {
        didSet {
            UserDefaults.standard.set(sound, forKey: "PathSense.demoVoice")
            if !sound { feedback.stop(); clearPreparation() }
        }
    }
    @Published private(set) var history: [String] = []
    @Published private(set) var dictationPhase: DictationPhase = .idle
    enum DictationPhase { case idle, preparing, listening, finishing }
    var listening: Bool { dictationPhase != .idle }
    private let microphone = DestinationMicrophone()
    private var playNextStepOnRequest = false
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var arrived = false
    @Published private(set) var capture: CaptureState = .starting
    @Published private(set) var scene = ""
    @Published private(set) var instruction = ""
    @Published private(set) var status = "实时描述，一次提示一个动作。"
    @Published private(set) var sensorNote = ""
    @Published private(set) var localMap = LocalMappingRecorder().snapshot
    @Published private(set) var mapExportURL: URL?
    private var mapping = LocalMappingRecorder()
    private var mapBook = LandmarkBook()
    private var lastMapPublishAt = 0.0
    private var lastLiveMapAt = 0.0
    @Published private(set) var needsFacing = false
    @Published private(set) var needsReview = false
    @Published private(set) var responses = 0
    @Published private(set) var spokenSteps = 0
    @Published private(set) var recentReplies: [String] = []
    #if DEBUG && targetEnvironment(simulator)
    @Published private(set) var preview: UIImage?
    @Published private(set) var videoPlayback: SimulatorVideoPlayback?
    @Published private(set) var videoAnalyzing = false
    private var videoRelease: Task<Void, Never>?
    private var recordingGuide: ScriptedRecordingGuide? = ScriptedRecordingGuide.load(bundle: .main)
    #endif

    private let client = CloudClient()
    private var nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: false)
    private var epoch = UUID(), request: Task<Void, Never>?, watchdog: Task<Void, Never>?
    private var latestKey: KeyObservation?
    private var accepted: (reply: DemoGuideReply, pose: FramePose)?
    private var preparedText: String?, consumedForward: FrameID?
    private var preparingText: String?, preparationID = UUID()
    private var confirmOnFirstPose = false
    private var nextRequestAt = 0.0, lastPoseAt = 0.0, waitingSince = 0.0
    private var lastScene = "", lastOrdinary = "", lastSafety = "", lastCoaching = ""
    private var doorBook = LandmarkBook(), doorID: Int?
    private var sawActiveStep = false
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private static let languageKey = "PathSense.demoLanguage"

    init() {
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--demo-language").flatMap { index in
            args.indices.contains(index + 1) ? GuidanceLanguage(rawValue: args[index + 1]) : nil
        }
        language = override ?? UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(GuidanceLanguage.init(rawValue:)) ?? .chinese
        destination = isScriptedRecording ? "BSG33 doorway" : text("门口", "doorway")
        status = text("实时描述，一次提示一个动作。", "Describes the view and gives one action at a time.")
        feedback.speechLanguage = language
        sound = UserDefaults.standard.object(forKey: "PathSense.demoVoice") as? Bool ?? true
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private var historyKey: String { "PathSense.demoRecent." + language.rawValue }

    func dictate() {
        switch dictationPhase {
        case .preparing, .finishing: return
        case .listening:
            dictationPhase = .finishing; microphone.finish(); return
        case .idle: break
        }
        guard !running else { return }
        feedback.stop(); destination = ""; dictationPhase = .preparing
        microphone.start(language: language, ready: { [weak self] in
            guard let self, self.dictationPhase == .preparing else { return }
            self.dictationPhase = .listening
        }, partial: { [weak self] value in self?.destination = value }, finish: { [weak self] value, error in
            guard let self else { return }
            self.dictationPhase = .idle
            if let value { self.destination = value; self.start() }
            else {
                self.status = error ?? self.text("请重新说出目的地。", "Please say the destination again.")
                self.feedback.deliver(self.status, sound: self.sound, interrupt: true)
            }
        })
    }

    func cancelDictation() { microphone.cancel(); dictationPhase = .idle }

    func text(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }

    func setLanguage(_ value: GuidanceLanguage) {
        guard !running, value != language else { return }
        stop()
        let knownDestinations = [("门口", "doorway"), ("电梯", "Lift"), ("出口", "Exit"), ("楼梯", "Stairs"), ("厕所", "Restroom")]
        let previousDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownDestination = knownDestinations.first { $0.0 == previousDestination || $0.1 == previousDestination }
        language = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.languageKey)
        feedback.speechLanguage = value
        if let knownDestination { destination = text(knownDestination.0, knownDestination.1) }
        else if previousDestination.isEmpty { destination = text("门口", "doorway") }
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        arrived = false; scene = ""; instruction = ""; sensorNote = ""
        needsFacing = false; needsReview = false; recentReplies = []
        status = text("实时描述，一次提示一个动作。", "Describes the view and gives one action at a time.")
    }

    var captureDescription: String { captureText(capture) }

    var isVideoReplay: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return isScriptedRecording || ProcessInfo.processInfo.environment["PATHSENSE_TEST_VIDEO"] != nil
        #else
        return false
        #endif
    }

    var isScriptedRecording: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--scripted-recording-demo")
        #else
        return false
        #endif
    }

    var videoReplayNotice: String {
        if isScriptedRecording { return text("录制专用版 · 预编排英文引导", "Scripted demo · English guidance") }
        return text("视频回放 · 实时云端识图；没有实测姿态或深度。",
             "Video replay · Live cloud vision; no measured pose or depth.")
    }

    private func captureText(_ state: CaptureState) -> String {
        if language == .chinese { return state.description }
        switch state {
        case .starting: return "Opening the camera…"
        case .ready: return "Camera ready"
        case .denied: return "Camera access is off. Allow camera access in Settings."
        case .restricted: return "Camera access is restricted on this device."
        case .unavailable: return "A rear camera and AR tracking are required."
        case .interrupted: return "Camera interrupted. Stop and wait for it to resume."
        case .failed: return "Camera tracking failed. Stop and try again."
        }
    }

    private func modelWords(_ reply: DemoGuideReply) -> String {
        reply.scene_zh + text("", " ") + reply.speech_zh
    }

    func start() {
        stop()
        feedback.speechLanguage = language
        if !isScriptedRecording && !CloudClient.hasSimulatorDemoRelay {
            try? DeviceCloudCredential.importEnrollmentIfPresent()
        }
        guard isScriptedRecording || CloudClient.hasSimulatorDemoRelay || (try? DeviceCloudCredential.read()) != nil else {
            status = text("手机识图授权不可用，请解锁手机后重试。", "Vision access is unavailable. Unlock this phone and try again.")
            feedback.deliver(status, sound: sound, interrupt: true)
            return
        }
        destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.isEmpty { destination = text("门口", "doorway") }
        destination = String(destination.prefix(40))
        history = Array(([destination] + history.filter { $0 != destination }).prefix(4))
        UserDefaults.standard.set(history, forKey: historyKey)
        playNextStepOnRequest = false
        running = true; paused = false; arrived = false
        scene = ""; instruction = ""; sensorNote = ""; needsFacing = false; needsReview = false
        responses = 0; spokenSteps = 0; recentReplies = []
        lastScene = ""; lastOrdinary = ""; lastSafety = ""; lastCoaching = ""
        doorBook = LandmarkBook(); doorID = nil
        launchCamera()
    }

    private func launchCamera() {
        mapping = LocalMappingRecorder(); mapBook = LandmarkBook()
        localMap = mapping.snapshot; mapExportURL = nil; lastMapPublishAt = 0; lastLiveMapAt = 0
        epoch = UUID(); let token = epoch
        nav = SpatialNavigator(doorTarget: false, requiresPlannedTarget: false)
        nav.setStepTask(destination: destination, task: "DS门口演示", revision: 1)
        confirmOnFirstPose = true
        accepted = nil; consumedForward = nil; clearPreparation(); latestKey = nil
        nextRequestAt = 0; sawActiveStep = false; lastPoseAt = now
        capture = .starting; status = text("正在打开相机…", "Opening the camera…")
        feedback.onSpeech = { [weak self] _, _, ended in if ended { self?.tick() } }
        camera.updateOrientation(UIDevice.current.orientation)
        camera.start(id: token, target: .named(destination), cloud: !isScriptedRecording) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.epoch == token, self.running, !self.paused else { return }
                self.handle(event)
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.running, !self.paused else { return }
                if self.now - self.lastPoseAt > 0.8, self.nav.current != nil {
                    self.nav.revokeStep("demoCameraTimeout", at: self.now)
                    self.nav.nearLost()
                    self.mapping.clearNearField(); self.localMap = self.mapping.snapshot
                    self.safety(text("画面已中断，请先停下。", "Camera view lost. Please stop."))
                }
            }
        }
        if !isScriptedRecording {
            feedback.deliver(text("手机朝身体前方，听一句，做一步。", "Point the phone straight ahead. Follow one instruction at a time."), sound: sound, interrupt: true)
        }
    }

    func exportLocalMap() {
        guard !localMap.path.isEmpty else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let directory = URL.documentsDirectory.appendingPathComponent("LocalMaps", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = localMap.pose?.id.session.uuidString ?? "session"
            let world = localMap.pose?.id.world ?? 0
            let url = directory.appendingPathComponent("PathSense-local-map-\(session)-\(world).json")
            try encoder.encode(localMap).write(to: url, options: .atomic)
            mapExportURL = url
        } catch {
            sensorNote = text("局部地图暂时无法导出，请稍后重试。", "The local map could not be exported. Please try again.")
        }
    }

    private func publishMap(at time: Double, force: Bool = false) {
        guard force || time - lastMapPublishAt >= 0.25 else { return }
        localMap = mapping.snapshot; lastMapPublishAt = time
        if time - lastLiveMapAt >= 3 {
            lastLiveMapAt = time
            saveLiveMap()
        }
    }

    private func saveLiveMap() {
        let directory = URL.documentsDirectory.appendingPathComponent("LocalMaps", isDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(localMap).write(to: directory.appendingPathComponent("PathSense-live-map.json"), options: .atomic)
        } catch { /* Explicit export reports a user-facing error if storage remains unavailable. */ }
    }

    func stop() {
        #if DEBUG && targetEnvironment(simulator)
        videoRelease?.cancel(); videoRelease = nil; videoAnalyzing = false
        videoPlayback = nil; preview = nil
        recordingGuide?.stop()
        #endif
        mapping.clearNearField(); localMap = mapping.snapshot
        saveLiveMap()
        exportLocalMap()
        cancelDictation(); playNextStepOnRequest = false
        epoch = UUID(); request?.cancel(); request = nil
        watchdog?.cancel(); watchdog = nil
        client.close(); camera.stop(); feedback.onSpeech = nil; feedback.stop()
        clearPreparation()
        accepted = nil; preparedText = nil; latestKey = nil
        running = false; paused = false
    }

    func returnHome() {
        stop(); arrived = false; scene = ""; instruction = ""; sensorNote = ""
        status = text("实时描述，一次提示一个动作。", "Describes the view and gives one action at a time.")
    }

    func pauseOrResume() {
        guard running else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay {
            camera.setVideoPlaybackPaused(!(videoPlayback?.isPaused ?? false))
            return
        }
        #endif
        if paused {
            paused = false; needsFacing = false; needsReview = false
            launchCamera()
        } else {
            epoch = UUID(); request?.cancel(); request = nil; watchdog?.cancel(); watchdog = nil
            client.close(); camera.stop(); feedback.stop(); clearPreparation()
            nav.revokeStep("demoPaused", at: now)
            mapping.clearNearField(); localMap = mapping.snapshot; saveLiveMap(); exportLocalMap()
            accepted = nil; preparedText = nil; paused = true
            status = text("已暂停", "Paused")
        }
    }

    func background() {
        cancelDictation()
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay, running { camera.setVideoPlaybackPaused(true); feedback.stop(); return }
        #endif
        if running && !paused { pauseOrResume() } else { feedback.stop() }
    }

    #if DEBUG && targetEnvironment(simulator)
    func seekVideo(to seconds: Double) {
        guard isVideoReplay, running else { return }
        videoRelease?.cancel(); videoRelease = nil
        request?.cancel(); request = nil; client.close(); feedback.stop()
        accepted = nil; latestKey = nil; nextRequestAt = 0; videoAnalyzing = false
        scene = ""; instruction = ""; sensorNote = ""
        recordingGuide?.stop(); arrived = false
        status = text("正在读取视频画面…", "Reading the selected video frame…")
        camera.seekVideo(to: seconds)
    }

    private func releaseVideo(after origin: FrameID, delay: Double = 4) {
        videoRelease?.cancel()
        let token = epoch
        videoRelease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let deadline = self.now + 25
            while self.feedback.isBusy && self.now < deadline {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard !Task.isCancelled, self.epoch == token, self.running,
                  self.camera.isCurrentVideoFrame(origin) else { return }
            self.videoAnalyzing = false; self.nextRequestAt = 0
            self.camera.setVideoAnalysisHolding(false)
            self.videoRelease = nil
        }
    }
    #endif

    func confirmFacing() {
        guard running, !paused, nav.current?.normal == true else { return }
        nav.faceForward(); needsFacing = false; lastCoaching = ""
        camera.requestKey(); tick()
    }

    func confirmStationary() {
        nav.confirmStepReview(); needsReview = nav.stepNeedsReview
        if !needsReview { confirmFacing(); nextRequestAt = 0; camera.requestKey() }
    }

    func finish() {
        stop(); arrived = true; scene = ""; instruction = text("已到门口，演示结束。", "You are at the doorway. Demo complete."); status = text("演示完成", "Demo complete")
        feedback.deliver(instruction, sound: sound, haptic: .arrival, interrupt: true)
    }

    func repeatLast() {
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay {
            if isScriptedRecording, let playback = videoPlayback {
                recordingGuide?.stop()
                if let cue = recordingGuide?.update(position: playback.position, paused: playback.isPaused, sound: true) {
                    scene = cue.scene; instruction = cue.instruction
                }
            } else if let value = accepted { feedback.deliver(modelWords(value.reply), sound: true, interrupt: true) }
            return
        }
        #endif
        guard running, !paused, let value = accepted, valid(value.pose) else {
            if !instruction.isEmpty && arrived { feedback.deliver(instruction, sound: true) }
            return
        }
        if value.reply.action == .forward {
            if consumedForward != value.reply.frame_id {
                playNextStepOnRequest = true
                tick()
            } else {
                // A completed movement sentence needs a new decision and permit.
                nextRequestAt = 0; camera.requestKey()
                feedback.deliver(value.reply.scene_zh, sound: true)
            }
        } else {
            feedback.deliver(modelWords(value.reply), sound: true)
        }
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case .state(let state):
            capture = state
            if state == .ready { status = text("正在观察前方…", "Looking ahead…") }
            else if state != .starting {
                nav.nearLost(); mapping.clearNearField(); localMap = mapping.snapshot
                safety(captureText(state))
            }
        case .pose(let p):
            let previous = nav.current
            nav.pose(p)
            guard nav.current?.id == p.id else { return }
            lastPoseAt = now
            #if DEBUG && targetEnvironment(simulator)
            if isVideoReplay {
                if let previous, !previous.id.sameWorld(p.id) {
                    videoRelease?.cancel(); videoRelease = nil
                    request?.cancel(); request = nil; client.close(); feedback.stop()
                    accepted = nil; latestKey = nil; nextRequestAt = 0; videoAnalyzing = false
                    scene = ""; instruction = ""
                }
                tick(); return
            }
            #endif
            let changedWorld = previous?.id.sameWorld(p.id) != true
            if changedWorld { mapBook = LandmarkBook(); mapExportURL = nil }
            mapping.record(pose: p)
            if let points = camera.latestMappingPoints() { mapping.record(points: points) }
            mapBook.expire(at: p.time)
            mapping.record(landmarks: mapBook.records)
            publishMap(at: p.time, force: changedWorld)
            if let previous, !previous.id.sameWorld(p.id) || (previous.normal && !p.normal) {
                request?.cancel(); request = nil; client.close()
                accepted = nil; latestKey = nil; preparedText = nil; consumedForward = nil
                feedback.stop(); clearPreparation()
                doorBook = LandmarkBook(); doorID = nil
                confirmOnFirstPose = false; needsFacing = true; nextRequestAt = 0
                status = text("画面位置已更新，请让手机朝身体前方。", "Tracking has reset. Point the phone straight ahead.")
                camera.requestKey()
            }
            if confirmOnFirstPose, p.normal { nav.faceForward(); confirmOnFirstPose = false }
            tick()
        case .near(let field):
            #if DEBUG && targetEnvironment(simulator)
            if isVideoReplay { tick(); return }
            #endif
            nav.risk(field); mapping.record(field: field)
            if let points = camera.latestMappingPoints() { mapping.record(points: points) }
            publishMap(at: field.pose.time); tick()
        case .key(let key):
            latestKey = key
            #if DEBUG && targetEnvironment(simulator)
            if isVideoReplay { requestLatest(); return }
            #endif
            _ = nav.register(key.features, at: key.pose, local: true)
            if let current = nav.current, key.pose.id.sameWorld(current.id), key.pose.normal,
               (0...1.5).contains(current.time - key.pose.time) {
                for feature in key.features { _ = mapBook.observe(feature, at: key.pose) }
                mapping.record(landmarks: mapBook.records); publishMap(at: current.time, force: true)
            }
            requestLatest()
        case .error(let message): status = text(message, "The camera could not read the view. Hold the phone steady and try again.")
        case .frame: break
        #if DEBUG && targetEnvironment(simulator)
        case .preview(let image): preview = image
        case .videoPlayback(let state):
            videoPlayback = state
            if isScriptedRecording {
                if let cue = recordingGuide?.update(position: state.position, paused: state.isPaused && !arrived, sound: sound) {
                    scene = cue.scene; instruction = cue.instruction; responses += 1
                    status = text("正在引导至 BSG33", "Guiding to BSG33")
                }
                if state.position >= 136.5, !arrived {
                    arrived = true; camera.setVideoPlaybackPaused(true)
                    status = text("已到 BSG33 门口，演示完成", "At the BSG33 doorway · Demo complete")
                }
            }
        #endif
        }
    }

    private func requestLatest() {
        if isScriptedRecording { return }
        guard running, !paused, capture == .ready, request == nil, now >= nextRequestAt,
              nav.activeStep == nil, !nav.stepIsMoving,
              let key = latestKey, let jpeg = key.jpeg, let p = nav.current,
              key.pose.normal, key.pose.id.sameWorld(p.id), keyIsFresh(key, at: p) else { return }
        let token = epoch
        status = text("正在识图…", "Reading the view…"); nextRequestAt = now + 2
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay { videoAnalyzing = true; nextRequestAt = .infinity }
        #endif
        let prior = Array((recentReplies + (sensorNote.isEmpty ? [] : [text("本机检查：", "Phone check: ") + sensorNote])).suffix(3))
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await client.guideDemo(endpoint: CloudClient.directEndpoint, pose: key.pose, jpeg: jpeg,
                    width: key.sentWidth, height: key.sentHeight, destination: destination,
                    previous: prior, walkingReady: nav.hasFrontProof && !needsFacing && !needsReview, language: language)
                guard !Task.isCancelled, epoch == token, running, !paused else { return }
                request = nil
                // A request issued while waiting for ground evidence may finish after
                // that step was submitted. Its older image cannot replace an active step.
                guard nav.activeStep == nil, !nav.stepIsMoving else {
                    nextRequestAt = 0; camera.requestKey(); return
                }
                guard valid(key.pose) else { status = text("视角已变化，正在重新识图。", "The view has changed. Checking again."); nextRequestAt = 0; camera.requestKey(); return }
                accept(reply, at: key.pose)
            } catch {
                guard !Task.isCancelled, epoch == token, running, !paused else { return }
                request = nil; nextRequestAt = now + 2
                status = text("暂未获得有效识图结果，请保持手机稳定。", "Waiting for a valid view. Hold the phone steady.")
                #if DEBUG && targetEnvironment(simulator)
                if isVideoReplay {
                    latestKey = nil; releaseVideo(after: key.pose.id, delay: 2)
                    return
                }
                #endif
                if accepted == nil { coach(status) }
            }
        }
    }

    private func keyIsFresh(_ key: KeyObservation, at pose: FramePose) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay { return camera.isCurrentVideoFrame(key.pose.id) }
        #endif
        return (0...1.5).contains(pose.time - key.pose.time)
    }

    private func valid(_ origin: FramePose) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay {
            return running && !paused && camera.isCurrentVideoFrame(origin.id)
                && nav.current?.id.sameWorld(origin.id) == true
        }
        #endif
        guard running, !paused, let p = nav.current, p.normal, origin.id.sameWorld(p.id),
              (0...8).contains(p.time - origin.time), (0...0.8).contains(now - p.time),
              p.position.groundDistance(origin.position) <= 0.38,
              abs(turnAngle(p.heading - origin.heading)) <= 22 else { return false }
        // Tilting down to check the feet must not discard an otherwise current door
        // decision. Ground/body coverage and body-facing are checked independently.
        return true
    }

    private func accept(_ reply: DemoGuideReply, at origin: FramePose) {
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay {
            // Ordinary video has no measured motion or ground clearance. Replay the
            // model's words without issuing a physical walking permit or recording a path.
            accepted = (reply, origin); responses += 1; latestKey = nil
            scene = reply.scene_zh; instruction = reply.speech_zh; sensorNote = ""
            status = text("DS 实时识图结果", "Live DS guidance")
            recentReplies = Array((recentReplies + [modelWords(reply)]).suffix(3))
            feedback.deliver(modelWords(reply), sound: sound, interrupt: true,
                valid: { [weak self] in self?.valid(origin) == true })
            NSLog("PathSense video demo accepted action=%@ scene=%@ speech=%@", reply.action.rawValue, reply.scene_zh, reply.speech_zh)
            releaseVideo(after: origin.id)
            return
        }
        #endif
        let continuingForward = reply.action == .forward && accepted?.reply.action == .forward
            && consumedForward != accepted?.reply.frame_id
        accepted = (reply, origin); responses += 1
        if !continuingForward { waitingSince = now }
        scene = reply.scene_zh; instruction = reply.action == .forward ? "" : reply.speech_zh
        status = text("已识别前方景象", "View recognized"); sensorNote = ""; lastCoaching = ""
        recentReplies = Array((recentReplies + [modelWords(reply)]).suffix(3))
        if reply.action != .forward { clearPreparation() }
        if let box = reply.target_box, let kind = reply.target_kind {
            _ = mapBook.observe(.init(kind: kind, box: box, confidence: 0.75), at: origin)
            mapping.record(landmarks: mapBook.records); publishMap(at: nav.current?.time ?? origin.time, force: true)
        }
        if let box = reply.target_box, reply.target_kind == .door {
            doorID = doorBook.observe(.init(kind: .door, box: box, confidence: 0.75), at: origin)
        }
        if reply.action == .forward, let box = reply.target_box {
            let heading = origin.ray(box.center.0, box.center.1).heading
            _ = nav.aimDemo(toward: heading, from: origin)
            if reply.scene_zh != lastScene {
                lastScene = reply.scene_zh
                feedback.deliver(reply.scene_zh, sound: sound, valid: { [weak self] in self?.valid(origin) == true })
            }
            prepareStepIfNeeded(reply.speech_zh)
        } else {
            if nav.activeStep?.spokenAt == nil { nav.revokeStep("demoNewObservation", at: now) }
            if reply.action == .turn_left || reply.action == .turn_right { needsFacing = true }
            let text = modelWords(reply)
            if text != lastOrdinary || now - origin.time > 6 {
                lastOrdinary = text
                feedback.deliver(text, sound: sound, interrupt: reply.action == .stop,
                    valid: { [weak self] in self?.valid(origin) == true })
            }
        }
        checkArrival(); tick()
    }

    private func clearPreparation() {
        preparationID = UUID(); preparedText = nil; preparingText = nil
        feedback.cancelModelStepPreparation()
    }

    private func prepareStepIfNeeded(_ text: String) {
        guard preparedText != text, preparingText != text else { return }
        clearPreparation()
        let token = epoch, attempt = preparationID
        preparingText = text
        feedback.prepareModelStep(text) { [weak self] okay in
            guard let self, self.epoch == token, self.preparationID == attempt,
                  self.accepted?.reply.action == .forward, self.accepted?.reply.speech_zh == text else { return }
            self.preparingText = nil
            if okay { self.preparedText = text; self.tick() }
            else { self.sensorNote = self.text("普通话声音暂时不可用，请检查声音设置。", "English speech is unavailable. Check the voice settings.") }
        }
    }

    private func tick() {
        guard running, !paused, capture == .ready, let p = nav.current else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isVideoReplay { requestLatest(); return }
        #endif
        needsReview = nav.stepNeedsReview
        if let hazard = nav.frontHazard {
            nav.revokeStep("demoHazard", at: now)
            safety(hazard == .drop ? text("前方有落差，请停下。", "Drop ahead. Please stop.") : (hazard == .person ? text("前方有人，请先停下。", "Person ahead. Please stop.") : text("前方有障碍，请停下。", "Obstacle ahead. Please stop.")))
            sensorNote = text("前方通道受阻", "The path ahead is blocked"); return
        }
        if let safetyCue = nav.safetyCue(forwardOutstanding: nav.activeStep?.spokenAt != nil), safetyCue.kind == .stop {
            safety(text("先停下，站稳后再继续。", "Stop and stand still before continuing."))
            sensorNote = text("请先站稳", "Please stand still first"); needsReview = true; return
        }
        lastSafety = ""
        if nav.activeStep != nil { sawActiveStep = true }
        else if sawActiveStep {
            sawActiveStep = false; nextRequestAt = 0; camera.requestKey()
        }
        checkArrival()
        guard running, let value = accepted, value.reply.action == .forward,
              consumedForward != value.reply.frame_id else { requestLatest(); return }
        guard valid(value.pose) else {
            clearPreparation(); nextRequestAt = 0; camera.requestKey(); requestLatest(); return
        }
        if needsFacing { sensorNote = text("转好后，让手机朝身体前方，点下方继续。", "After turning, point the phone straight ahead and tap Continue below."); return }
        if needsReview { sensorNote = text("请站稳后点继续。", "Stand still, then tap Continue."); return }
        if let active = nav.activeStep, active.status != .offered { return }
        guard sound || UIAccessibility.isVoiceOverRunning || playNextStepOnRequest else {
            sensorNote = text("语音已关闭，点重听听取下一步。", "Speech is off. Tap Repeat to hear the next step.")
            return
        }
        prepareStepIfNeeded(value.reply.speech_zh)
        guard nav.activeStep?.spokenAt == nil, preparedText == value.reply.speech_zh, !feedback.isBusy else { return }
        // Local hazard handling can clear its desired bearing. Reapply this still-current
        // DS target before asking for a permit, so a free side strip cannot replace it.
        guard let box = value.reply.target_box else { return }
        let heading = value.pose.ray(box.center.0, box.center.1).heading
        guard nav.aimDemo(toward: heading, from: value.pose) else {
            nav.revokeStep("demoTargetExpired", at: now)
            accepted = nil; preparedText = nil; nextRequestAt = 0
            camera.requestKey(); requestLatest(); return
        }
        let bearing = turnAngle(heading - p.heading)
        if abs(bearing) > 8 {
            sensorNote = bearing < 0 ? text("本机尚未对准目标，目标在左侧。", "The target is to the left. Waiting for turn guidance.") : text("本机尚未对准目标，目标在右侧。", "The target is to the right. Waiting for turn guidance.")
            status = text("正在判断转向。", "Checking which way to turn.")
            camera.requestKey(); requestLatest(); return
        }
        let candidate = nav.cue(canAnnounceSweep: false)
        guard let cue = candidate, cue.kind == .advance, let permit = cue.permitID else {
            if candidate?.kind == .face {
                needsFacing = true
                sensorNote = text("让手机朝身体前方，点下方继续。", "Point the phone straight ahead and tap Continue below.")
            } else if candidate == .stepReview {
                needsReview = true; sensorNote = text("请站稳后点继续。", "Stand still, then tap Continue.")
            } else if candidate == .inspectBody || candidate == .liftPhone {
                sensorNote = text("请稍抬手机，照到身体前方。", "Raise the phone slightly to show the space ahead.")
            } else if candidate?.kind == .turn {
                sensorNote = text("门口还没对准，正在判断转向。", "The doorway is off to one side. Checking the turn.")
                nextRequestAt = 0; camera.requestKey()
            } else {
                sensorNote = nav.hasFrontProof ? text("正在核对下一步落脚区域", "Checking the landing area for the next step") : text("请将手机略向下，照到脚前地面。", "Tilt the phone down slightly to show the ground ahead of your feet.")
            }
            if now - waitingSince > 3 { coach(sensorNote) }
            requestLatest(); return
        }
        let text = value.reply.speech_zh, token = epoch
        let played = feedback.playModelStep(text, validate: { [weak self] in
            guard let self, self.epoch == token, self.valid(value.pose),
                  self.nav.permitsSpeech(cue, at: self.now) else { return false }
            self.nav.submittedStep(permit, at: self.now)
            return self.nav.permitsSpeech(cue, at: self.now)
        }, began: { [weak self] in
            guard let self, self.epoch == token, self.valid(value.pose),
                  self.nav.stepSpeechStarted(permit, at: self.now) else { return false }
            self.consumedForward = value.reply.frame_id; self.spokenSteps += 1; self.playNextStepOnRequest = false
            self.preparedText = nil
            self.instruction = text; self.sensorNote = ""; self.status = self.text("朝门口前进", "Moving toward the doorway")
            return true
        }, ended: { [weak self] finished in
            guard let self, self.epoch == token else { return }
            if finished { self.nav.stepSpeechEnded(permit, at: self.now) }
            else { self.nav.cancelStepSpeech(permit, at: self.now); self.clearPreparation() }
            self.camera.requestKey()
        })
        // The player takes ownership of the prepared clip before its asynchronous
        // cursor callback. Even a rejected start must prepare a new clip next time.
        preparedText = nil
        if !played { clearPreparation(); nav.cancelStepSpeech(permit, at: p.time) }
    }

    private func checkArrival() {
        guard running, !nav.stepIsMoving, let p = nav.current, let id = doorID,
              let door = doorBook.records.first(where: { $0.id == id }), door.count >= 3,
              let point = door.point, (0...6).contains(p.time - door.last.time),
              door.box.bottom > 0.58, door.box.bottom - door.box.top > 0.43,
              abs(door.bearing(at: p) ?? 180) < 18,
              p.position.groundDistance(point) < 1.15,
              door.first.position.groundDistance(point) - p.position.groundDistance(point) > 0.25 else { return }
        finish()
    }

    private func safety(_ text: String) {
        guard lastSafety != text else { return }
        lastSafety = text; instruction = text
        clearPreparation()
        feedback.deliver(text, sound: sound, haptic: .emergency, interrupt: true)
    }

    private func coach(_ text: String) {
        guard !feedback.isBusy, lastCoaching != text else { return }
        lastCoaching = text
        feedback.deliver(text, sound: sound)
    }
}

#if DEBUG
/// A short sensor-only capture for verifying export on the connected phone.
/// It makes no model request and emits no movement instruction.
@MainActor enum LocalMapDeviceCheck {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--check-local-map") else { return }
        let capture = Capture()
        capture.camera.start(id: UUID(), target: .named("mapping"), cloud: false) { event in
            DispatchQueue.main.async { capture.accept(event) }
        }
        try? await Task.sleep(for: .seconds(8))
        capture.camera.stop()
        capture.recorder.clearNearField()
        let snapshot = capture.recorder.snapshot
        let directory = URL.documentsDirectory.appendingPathComponent("LocalMaps", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent("PathSense-device-capture.json"), options: .atomic)
            let report: [String: Any] = ["normalFrames": capture.normalFrames, "pathCount": snapshot.path.count,
                "pointCount": snapshot.points.count, "pointSource": snapshot.pointSource ?? "none",
                "landmarkCount": snapshot.landmarks.count, "cameraState": capture.state,
                "coordinateFrame": "ARKit session, metres; not registered to a floor plan",
                "sensorOnly": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("PathSense-device-capture-report.json"), options: .atomic)
        } catch { NSLog("Local map capture export failed: %@", String(describing: error)) }
    }

    private final class Capture {
        let camera = SignCamera()
        var recorder = LocalMappingRecorder(), book = LandmarkBook()
        var normalFrames = 0, state = "starting"
        private var lastID: FrameID?
        func accept(_ event: CameraEvent) {
            switch event {
            case .state(let value): state = String(describing: value)
            case .pose(let pose):
                if lastID?.sameWorld(pose.id) != true { book = LandmarkBook() }
                lastID = pose.id
                recorder.record(pose: pose)
                if pose.normal { normalFrames += 1 }
                if let points = camera.latestMappingPoints() { recorder.record(points: points) }
            case .near(let field):
                recorder.record(field: field)
                if let points = camera.latestMappingPoints() { recorder.record(points: points) }
            case .key(let key):
                guard let current = recorder.snapshot.pose, current.id.sameWorld(key.pose.id) else { return }
                book.expire(at: current.time)
                for feature in key.features { _ = book.observe(feature, at: key.pose) }
                recorder.record(landmarks: book.records)
            default: break
            }
        }
    }
}
#endif
