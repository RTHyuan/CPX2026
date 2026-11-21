import SwiftUI

@MainActor final class Scanner: ObservableObject {
    #if DEBUG && !targetEnvironment(simulator)
    let diagnostics=DeviceDiagnostics()
    #endif
    let camera = SignCamera()
    let feedback = Feedback()
    @Published var entry = ""
    @Published private(set) var journey: WayfindingJourney?
    var target: Destination? { journey?.target }
    @Published private(set) var capture: CaptureState = .starting
    @Published private(set) var isPaused = false
    @Published private(set) var message = ""
    @Published private(set) var validation = ""
    @Published var sound: Bool {
        didSet { UserDefaults.standard.set(sound, forKey: "voice"); if !sound { feedback.stop() } }
    }
    @Published private(set) var history: [String]
    #if DEBUG && targetEnvironment(simulator)
    @Published private(set) var replayPreview: UIImage?
    #endif
    var cameraLabel: String {
        #if DEBUG && targetEnvironment(simulator)
        if replayPreview != nil { return "模拟镜头 · 持续扫描中" }
        #endif
        return "后置相机 · 持续扫描中"
    }
    var canGuide: Bool { journey != nil && journey?.stage != .arrived && capture == .ready && !isPaused }
    @Published private(set) var listening = false
    @Published private(set) var cloudEnabled = false
    @Published var proxyAddress = ""
    @Published private(set) var networkNote = "仅本机 · 可读牌、寻找门和提醒停步"
    @Published private(set) var lastSpatialCue: CueKind?
    @Published private(set) var canCheckDoor = false
    @Published private(set) var metricsText = ""
    @Published private(set) var mapNote = "无先验图"
    private var prior: PriorMap?, live: LiveNavigation?
    private var routeMeasures = WalkMeasures()
    private let microphone = DestinationMicrophone()
    private var utterance = "", manual = false

    func dictate() {
        if listening { microphone.finish(); return }
        if journey != nil { end() }
        feedback.stop(); listening=true; validation=""; entry=""
        microphone.start(partial: { [weak self] text in self?.entry=text }) { [weak self] text, error in
            guard let self else { return }; self.listening=false
            if let text { self.entry=text; self.begin() }
            else { self.validation=error ?? "请重新说出目的地。"; self.feedback.deliver(self.validation,sound:self.sound,interrupt:true) }
        }
    }
    func cancelDictation() { microphone.cancel(); listening=false }
    func configureCloud(enable: Bool) {
        if enable && CloudClient.endpoint(proxyAddress)==nil { networkNote="请输入演示 Mac 显示的完整配对地址。"; return }
        if journey != nil && !isPaused && journey?.stage != .arrived { stopCapture(); isPaused=true; message="配置已更新，点继续重新观察。"; spokenMessage=message }
        cloudEnabled=enable
        networkNote=enable ? "云端视觉已启用，等待首次关键帧。" : "仅本机 · 可读牌、寻找门和提醒停步"
    }
    func loadPrior(_ url:URL) {
        let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let n=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,n<=200_000 else {throw SpatialError.invalid}
            let map=try JSONDecoder().decode(PriorMap.self,from:Data(contentsOf:url)); try map.validate(); prior=map
            mapNote="已载入\(map.floor)参考图；匹配现场锚点后启用。"
        } catch { prior=nil; mapNote="地图无法读取，使用现场观察。" }
    }
    func clearPrior() { prior=nil; mapNote="无先验图" }
    func bodyForward() { live?.face() }
    func rescanPassage() { live?.retry() }
    func confirmDoor() { manual=true; live?.manualFinish(); manual=false }
    func cancelForHelp() { if listening { cancelDictation() }; if canGuide {pauseOrResume()} }
    private func rememberMeasures() {
        guard let measures=live?.measures, let data=try? JSONEncoder().encode(measures) else {return}
        metricsText=String(decoding:data,as:UTF8.self)
    }
    private func spatial(_ cue:LocalCue) {
        guard canGuide else {return}; lastSpatialCue=cue.kind; canCheckDoor=live?.canManuallyVerifyDoor ?? false
        if cue.kind == .arrived, var route=journey { rememberMeasures(); route.finishedDoor(manual:manual); apply(route); return }
        if cue.kind == .aligned {
            feedback.deliver("",sound:false,haptic:.alignment); return
        }
        present(cue.text, speech: cue.kind == .route ? SignReading.spoken(cue.text) : cue.text, haptic: cue.kind == .stop ? .emergency : nil, interrupt:true)
    }
    private var sessionID = UUID()
    private var gate = RouteEvidenceGate(now: 0)
    private var acceptSince: TimeInterval = 0
    private var spokenMessage = ""
    private var returningFromSettings = false
    private var expiry: Task<Void, Never>?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["voice": true])
        sound = defaults.bool(forKey: "voice")
        history = defaults.stringArray(forKey: "recentTargets") ?? []
    }
    func begin() {
        cancelDictation()
        guard let destination = Destination(wayfinding: entry) else {
            validation = "请输入房号、科室、店名或设施名称。"
            feedback.deliver(validation, sound: sound, interrupt: true)
            return
        }
        stopCapture()
        metricsText=""; routeMeasures=WalkMeasures(); utterance=entry
        journey = WayfindingJourney(target: destination)
        entry = destination.text
        validation = ""
        // Free-form names can reveal a medical visit. Keep them in the active journey only.
        switch destination {
        case .room, .facility:
            history = Array(([entry] + history.filter { $0 != entry }).prefix(4))
            UserDefaults.standard.set(history, forKey: "recentTargets")
        case .named: break
        }
        startCapture(opening: "开始导航")
    }
    func end() {
        stopCapture()
        journey = nil
        utterance=""
        isPaused = false
        returningFromSettings = false
        validation = ""
        message = ""
        spokenMessage = ""
    }
    func pauseOrResume() {
        guard journey != nil, journey?.stage != .arrived else { return }
        if isPaused { startCapture() }
        else if canGuide {
            stopCapture()
            isPaused = true
            present("扫描已暂停。点继续，接着找当前目的地。")
        }
    }
    func retryCamera() {
        guard journey != nil, journey?.stage != .arrived, !isPaused else { return }
        stopCapture()
        startCapture()
    }
    func background() {
        cancelDictation()
        guard journey != nil, journey?.stage != .arrived, !isPaused else { feedback.stop(); return }
        returningFromSettings = capture == .denied || capture == .restricted
        stopCapture()
        isPaused = true
        message = "扫描已暂停，点继续可恢复本次导航。"
        spokenMessage = message
    }
    func foreground() {
        if returningFromSettings {
            returningFromSettings = false
            startCapture()
        }
    }
    func routeAction(_ action: WayfindingJourney.Action) {
        guard canGuide, live?.canConfirmEntrance != false, var route = journey, route.action == action else { return }
        route.confirm()
        apply(route)
    }
    func selectRouteChoice(_ option: RouteChoice) {
        guard canGuide, var route = journey, route.choices.contains(option) else { return }
        route.choose(option)
        camera.updateTarget(route.searchTarget)
        apply(route)
    }
    func publicArea() {
        guard canGuide, var route = journey else { return }
        route.enteredPublicArea()
        apply(route)
    }
    func locateAgain() {
        guard canGuide, var route = journey else { return }
        route.relocalize()
        camera.updateTarget(route.searchTarget)
        gate = RouteEvidenceGate(now: now)
        apply(route)
    }
    private func apply(_ route: WayfindingJourney) {
        // Discard in-flight samples from before the tap. Keep the delivery latch so
        // holding the camera on a transfer arrow cannot undo a confirmed transition.
        acceptSince = now
        expiry?.cancel()
        if route.stage == .arrived { live?.finishMeasures(manual:true); stopCapture() }
        journey = route; live?.updateRoute(route,userChanged:true)
        if let live, live.nav.current != nil {
            let text = route.stage == .landing ? "已记录换层点。到达目标楼层后，请用手机查看楼层牌。" : route.cue
            live.stationary(text); return
        }
        present(route.cue, speech: route.prompt.speech, haptic: route.stage == .arrived ? .arrival : .guidance, interrupt: true)
    }
    private func present(_ text: String, speech: String? = nil, haptic: NavigationHaptic? = nil, interrupt: Bool = false) {
        message = text
        live?.instruction(speech ?? text)
        spokenMessage = speech ?? text
        feedback.deliver(spokenMessage, sound: sound, haptic: haptic, interrupt: interrupt)
    }
    func repeatLast() { feedback.deliver(spokenMessage, sound: true, interrupt: true) }
    private func clearEvidence() {
        expiry?.cancel()
        acceptSince = now
        gate = RouteEvidenceGate(now: acceptSince)
        journey?.expireConfirmation()
    }
    private func stopCapture() {
        if let live { live.closeSegment(); routeMeasures=live.measures; rememberMeasures(); live.stop() }
        live=nil; lastSpatialCue=nil; canCheckDoor=false
        feedback.onSpeech=nil
        sessionID = UUID()
        camera.stop()
        feedback.stop()
        clearEvidence()
        capture = .starting
        #if DEBUG && targetEnvironment(simulator)
        replayPreview = nil
        #endif
    }
    private func startCapture(opening: String = "继续导航") {
        guard let route = journey else { return }
        let target = route.searchTarget
        isPaused = false
        capture = .starting
        let intro = "\(opening)，正在寻找\(SignReading.spoken(target.text))。"
        present(capture.description, speech: intro + route.prompt.speech, haptic: .start, interrupt: true)
        camera.updateOrientation(UIDevice.current.orientation)
        let id = sessionID
        let endpoint=cloudEnabled ? CloudClient.endpoint(proxyAddress):nil
        live=LiveNavigation(route:route,utterance:utterance,endpoint:endpoint,prior:prior,camera:camera,previousMeasures:routeMeasures,isSpeaking:{ [weak self] text in self?.feedback.isSpeaking(text) == true },output:{ [weak self] cue in self?.spatial(cue) },status:{ [weak self] note in
            guard let self, self.networkNote != note else {return}; self.networkNote=note
            if note.hasPrefix("云端暂不可用"), self.lastSpatialCue != .stop { self.feedback.deliver("云端暂不可用，本机仍在扫描。",sound:self.sound) }
        })
        feedback.onSpeech={ [weak self] text,time,ended in self?.live?.speech(text,time:time,ended:ended) }
        camera.start(id: id, target: target, cloud: endpoint != nil) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.sessionID == id, !self.isPaused else { return }
                self.handle(event)
            }
        }
    }
    private func handle(_ event: CameraEvent) {
        #if DEBUG && !targetEnvironment(simulator)
        diagnostics.observe(event)
        #endif
        switch event {
        case .state(let state):
            guard capture != state else { return }
            let wasInterrupted = capture == .interrupted
            capture = state
            if state == .ready, let route = journey {
                message = route.cue
                spokenMessage = route.prompt.speech
                if wasInterrupted { feedback.deliver(spokenMessage, sound: sound, haptic: .start, interrupt: true) }
            } else {
                live?.sessionInterrupted(); clearEvidence()
                present(state.description, haptic: .warning, interrupt: true)
            }
        case .pose(let pose):
            guard canGuide else {return}; live?.pose(pose)
        case .near(let near):
            guard canGuide else {return}; live?.near(near)
        case .key(let key):
            guard canGuide, let current=camera.latestPose(), current.id.sameWorld(key.pose.id), key.pose.time >= acceptSince else {return}
            let signs = key.signs.flatMap { frame in
                journey.map { WayfindingParser.read(frame, for: $0.searchTarget, landmark: $0.site.landmark) }
            }
            if let signs { live?.observeReadout(signs, at:key.pose) }
            live?.observation(key, printedRestriction: signs?.restricted == true)
            if let signs, target?.isClassroomDoor != true { consumeSigns(signs, at:key.pose.time, capturePose:key.pose) }
            let check=live?.canManuallyVerifyDoor ?? false; if check != canCheckDoor {canCheckDoor=check}
        case .frame(let frame, let sampledAt):
            if let route = journey {
                consumeSigns(WayfindingParser.read(frame, for: route.searchTarget, landmark: route.site.landmark), at:sampledAt)
            }
        case .error(let reason):
            guard canGuide else { return }; clearEvidence()
            if message != reason { present(reason,haptic:.warning,interrupt:true) }
        #if DEBUG && targetEnvironment(simulator)
        case .preview(let image): replayPreview = image
        #endif
        }
    }
    private func consumeSigns(_ signs:WayfindingSigns,at sampledAt:Double,capturePose:FramePose?=nil) {
            let spatial = capturePose != nil
            guard canGuide, sampledAt >= acceptSince, var route = journey else { return }
            if route.action == .atDestination {
                if signs.target == .plate, !signs.restricted { armExpiry() }
                else {
                    clearEvidence()
                    route.expireConfirmation()
                    if !spatial { present(route.cue, speech: route.prompt.speech, interrupt: true) }
                }
            }
            guard gate.accept(signs, at: sampledAt) else { return }
            route.observe(signs)
            journey = route; live?.updateRoute(route)
            if spatial {
                if route.action == .atDestination { armExpiry() }
                if signs.restricted { return } // The capture-bound access notice owns this announcement.
                if let pose = capturePose { live?.observeReadout(signs, at:pose, confirmed:true) }
                // Map storage happens on the first capture. The second agreeing reading advances the journey.
                // Report the sign itself even when the camera is level or the current strip is unknown.
                var room = signs.nearbyRoom
                if signs.target == .plate { room = route.searchTarget.text }
                if signs.target == .mention, case .room(let code) = route.searchTarget { room = code }
                if let pose = capturePose, let room, live?.localSign(for:room, at:pose) == true { return }
                let text:String
                switch signs.target {
                case .listed(let site):
                    let floor=site.level.map { "，在" + Mandarin.floor($0) } ?? ""
                    let arrow=site.arrow.map { "，牌上箭头向" + $0.words } ?? ""
                    text="目录列有「\(route.searchTarget.text)」\(floor)\(arrow)。"
                case .plate:
                    text = route.action == .atDestination ? "读到「\(route.searchTarget.text)」的独立标牌，可核对是否到达。" : route.cue
                case .ambiguous, .mention:
                    text="这块牌提到「\(route.searchTarget.text)」。请移动手机，让对应的一行完整入镜。"
                case nil:
                    if let floor=signs.currentLevel { text="楼层牌写着\(Mandarin.floor(floor))。" }
                    else if let room=signs.nearbyRoom { text="附近门牌写着\(room)，已记下。" }
                    else if let transfer=signs.transfer { text="看到\(transfer)标识。" + (signs.transferArrow.map { "牌上箭头向\($0.words)。" } ?? "") }
                    else if let arrow=signs.onward ?? signs.portalArrow { text="标牌的箭头向\(arrow.words)。" }
                    else if signs.signboard { text="看到一张目录，请移动手机查看对应条目。" }
                    else {return}
                }
                live?.stationary(text)
                return
            }
            if route.action == .atDestination { armExpiry() }
            if message != route.cue {
                let haptic: NavigationHaptic? = signs.restricted ? .warning : (signs == WayfindingSigns() ? nil : .guidance)
                present(route.cue, speech: route.prompt.speech, haptic: haptic, interrupt: signs.restricted)
            }
    }
    private func armExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.canGuide, self.journey?.action == .atDestination else { return }
            self.clearEvidence()
            if let route=self.journey, self.live?.nav.current == nil || self.live?.allowsSignDirections == true { self.present(route.cue,speech:route.prompt.speech,interrupt:true) }
        }
    }
}
