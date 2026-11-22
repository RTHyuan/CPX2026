import SwiftUI

@MainActor final class Scanner: ObservableObject {
    #if DEBUG && !targetEnvironment(simulator)
    let diagnostics=DeviceDiagnostics()
    var dictationMetrics: DestinationMicrophone.Diagnostics { microphone.diagnostics }
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
    enum DictationPhase { case idle, preparing, listening, finishing }
    @Published private(set) var dictationPhase: DictationPhase = .idle
    var listening: Bool { dictationPhase != .idle }
    @Published private(set) var cloudEnabled = false
    @Published var proxyAddress = ""
    @Published private(set) var directCloudAvailable = false
    private let directCloudConsentKey = "consentToDirectDeepSeekV2"
    private var planningEndpoint: URL? { directCloudAvailable ? CloudClient.directEndpoint : CloudClient.endpoint(proxyAddress) }
    @Published private(set) var checkingCloud = false
    @Published private(set) var cloudTestNote = ""
    private var ranLaunchCloudCheck = false
    private var storesPairing: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["PATHSENSE_TEST_CAMERA"] == nil
        #else
        return true
        #endif
    }
    @Published private(set) var networkNote = "仅本机 · 可读文字、检查通道；纯图形标识需复核"
    @Published private(set) var lastSpatialCue: CueKind?
    @Published private(set) var canCheckDoor = false
    @Published private(set) var metricsText = ""
    @Published private(set) var mapNote = "无先验图"
    private var prior: PriorMap?, live: LiveNavigation?
    private var routeMeasures = WalkMeasures()
    private let microphone = DestinationMicrophone()
    private var utterance = "", manual = false
    private var playNextStepOnRequest = false

    func dictate() {
        switch dictationPhase {
        case .preparing, .finishing: return
        case .listening:
            dictationPhase = .finishing
            microphone.finish()
            return
        case .idle: break
        }
        if journey != nil { end() }
        feedback.stop()
        dictationPhase = .preparing
        validation = ""
        entry = ""
        microphone.start(ready: { [weak self] in
            guard let self, self.dictationPhase == .preparing else { return }
            self.dictationPhase = .listening
        }, partial: { [weak self] text in self?.entry = text }) { [weak self] text, error in
            guard let self else { return }
            self.dictationPhase = .idle
            if let text {
                self.entry = text
                self.begin()
            } else {
                self.validation = error ?? "请重新说出目的地。"
                self.feedback.deliver(self.validation, sound: self.sound, interrupt: true)
            }
        }
        #if DEBUG && !targetEnvironment(simulator)
        diagnostics.observeManualDictation(self)
        #endif
    }
    func cancelDictation() {
        microphone.cancel()
        dictationPhase = .idle
    }
    func configureCloud(enable: Bool) {
        if enable && planningEndpoint == nil { networkNote="请输入演示 Mac 显示的完整配对地址。"; return }
        if journey != nil && !isPaused && journey?.stage != .arrived { stopCapture(); isPaused=true; message="配置已更新，点继续重新观察。"; spokenMessage=message }
        cloudEnabled=enable
        if directCloudAvailable { UserDefaults.standard.set(enable, forKey: directCloudConsentKey) }
        else if storesPairing { try? CloudPairing.save(proxyAddress, consent: enable) }
        networkNote=enable ? "云端视觉已启用，等待首次关键帧。" : "仅本机 · 可读文字、检查通道；纯图形标识需复核"
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
        guard canGuide, let live else { return }
        if cue.kind == .advance, let permit = cue.permitID {
            guard sound || UIAccessibility.isVoiceOverRunning || playNextStepOnRequest else {
                message = "一步提示已静音。点重听，重新检查后播报。"; spokenMessage = message
                lastSpatialCue = .wait
                return
            }
            playNextStepOnRequest = false
            let played = feedback.playStep(validate: { live.submitForPlayback(cue) }, began: { [weak self, weak live] in
                guard let self, let live, self.live === live, live.playbackStarted(cue) else { return false }
                self.lastSpatialCue = .advance; self.message = cue.text; self.spokenMessage = cue.text
                #if DEBUG && !targetEnvironment(simulator)
                self.diagnostics.observeCue(cue, hazard: live.nav.frontHazard)
                #endif
                return true
            }, ended: { [weak live] finished in live?.playbackEnded(permit, finished: finished) })
            if !played { live.declineStep(cue, reason: "playbackUnavailableOrProofChanged") }
            return
        }
        lastSpatialCue=cue.kind; canCheckDoor=live.canManuallyVerifyDoor
        #if DEBUG && !targetEnvironment(simulator)
        diagnostics.observeCue(cue, hazard: live.nav.frontHazard)
        #endif
        if cue.kind == .arrived, var route=journey { rememberMeasures(); route.finishedDoor(manual:manual); apply(route); return }
        if cue.kind == .aligned {
            feedback.deliver("",sound:false,haptic:.alignment); return
        }
        let origin = live.nav.current, generation = live.nav.generation, targetID = live.nav.waypoint
        present(cue.text, speech: cue.kind == .route ? SignReading.spoken(cue.text) : cue.text,
                haptic: cue.isEmergency ? .emergency : nil, interrupt: cue.isEmergency || cue == .revokeAdvance,
                valid: { [weak live] in guard let live, let origin else { return false }; return live.validForSpeech(cue, origin: origin, generation: generation, targetID: targetID) })
    }
    private var sessionID = UUID()
    private var gate = RouteEvidenceGate(now: 0)
    private var entranceCapture: FramePose?
    private var entranceProximity: EntranceProximity?
    private var entranceSymbolID: Int?
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
        if storesPairing {
            try? DeviceCloudCredential.importEnrollmentIfPresent()
            directCloudAvailable = (try? DeviceCloudCredential.read()) != nil
        }
        if directCloudAvailable {
            cloudEnabled = defaults.bool(forKey: directCloudConsentKey)
            networkNote = cloudEnabled ? "手机云端直连已启用，等待首次关键帧。" : "手机云端直连已就绪，启用后可发送导航关键帧。"
        } else if storesPairing, let pairing = CloudPairing.load() {
            proxyAddress = pairing.address
            cloudEnabled = pairing.consent
            networkNote = pairing.consent ? "云端视觉已启用，等待首次关键帧。" : "已配对演示 Mac。启用云端视觉后，可发送导航关键帧。"
        }
    }

    func checkCloudOnLaunchIfRequested() async {
        let options = ProcessInfo.processInfo.arguments
        guard !ranLaunchCloudCheck, options.contains("--check-paired-cloud") || options.contains("--check-direct-cloud") else { return }
        ranLaunchCloudCheck = true
        await checkCloud()
    }

    func checkCloud() async {
        guard !checkingCloud, !canGuide else { return }
        checkingCloud = true
        defer { checkingCloud = false }
        var receipt = CloudCheckReceipt()
        if directCloudAvailable {
            receipt.transport = "iphone-direct-https"; receipt.providerHost = CloudClient.directEndpoint.host; receipt.model = "deepseek-flash"
        }
        receipt.save()
        let started = ProcessInfo.processInfo.systemUptime
        let client = CloudClient()
        defer {
            client.close()
            receipt.seconds = (1000 * (ProcessInfo.processInfo.systemUptime - started)).rounded() / 1000
            receipt.save()
        }
        let requireDirect = ProcessInfo.processInfo.arguments.contains("--check-direct-cloud")
        guard let endpoint = planningEndpoint, !requireDirect || directCloudAvailable else {
            receipt.status = "failed"; receipt.outcome = requireDirect ? "missing_device_enrollment" : "missing_pairing"
            cloudTestNote = "请先填入演示 Mac 的配对地址。"; return
        }
        cloudTestNote = "正在用公开门照测试云端连接…"
        do {
            let reply = try await client.checkWithPublicPhoto(endpoint: endpoint)
            receipt.status = "ok"; receipt.outcome = reply.action.rawValue
            receipt.frame = reply.frame_id; receipt.observations = reply.observations.map { $0.kind.rawValue }
            if !directCloudAvailable && storesPairing { try? CloudPairing.save(proxyAddress, consent: cloudEnabled) }
            cloudTestNote = "连接成功，手机已收到并核对公开门照的规划回复。"
        } catch let e as URLError {
            receipt.status = "failed"; receipt.outcome = "url_" + String(e.errorCode)
            cloudTestNote = directCloudAvailable ? "未能直连 DeepSeek。请检查手机的无线局域网或蜂窝数据，然后重新测试。" : "未连通。请确认手机可访问演示 Mac，并在系统设置中允许 PathSense 使用本地网络。"
        } catch let e as CloudHTTPError {
            receipt.status = "failed"; receipt.outcome = "http_" + String(e.status) + (e.reason.map { "_" + $0 } ?? "")
            if directCloudAvailable {
                cloudTestNote = [401, 403].contains(e.status) ? "DeepSeek 未接受此设备的授权。" : "DeepSeek 暂未返回有效结果，请稍后重试。"
            } else { cloudTestNote = e.status == 404 ? "配对地址已失效，请更新演示 Mac 的地址。" : "手机已连到代理，模型暂未返回有效结果。请稍后重试。" }
        } catch {
            receipt.status = "failed"; receipt.outcome = "invalid_photo_or_reply"
            cloudTestNote = "回复未能通过图像和帧号校验，请重新测试。"
        }
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
        if action.confirmsDestination, let capture = entranceCapture {
            guard let current = camera.latestPose(), let live,
                  (0...2.5).contains(now - current.time), current.id.sameWorld(capture.id) else { clearEvidence(); return }
            let latest = live.nav.book.entrance(for: route.searchTarget, captured: capture, at: current, confirmedSymbolID: entranceSymbolID)
            guard latest.id == entranceProximity?.id, latest.id != nil else { clearEvidence(); return }
            switch (action, latest) {
            case (.atDestination, .nearby), (.confirmUnmeasuredEntrance, .unmeasured), (.confirmUnmeasuredEntrance, .nearby): break
            default: clearEvidence(); return
            }
        } else if action.confirmsDestination, live?.nav.current != nil { clearEvidence(); return }
        route.confirm()
        apply(route)
    }
    func selectRouteChoice(_ option: RouteChoice) {
        guard canGuide, var route = journey, route.choices.contains(option) else { return }
        route.choose(option)
        camera.updateTarget(route.searchTarget)
        apply(route)
    }
    func confirmInsideRoom() {
        guard canGuide, var route = journey else { return }
        route.confirmedInsideRoom(); apply(route)
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
    private func present(_ text: String, speech: String? = nil, haptic: NavigationHaptic? = nil, interrupt: Bool = false, valid: (() -> Bool)? = nil) {
        message = text
        spokenMessage = speech ?? text
        feedback.deliver(spokenMessage, sound: sound, haptic: haptic, interrupt: interrupt, valid: valid)
    }
    func repeatLast() {
        guard canGuide, let live, live.nav.current != nil else {
            let text = lastSpatialCue == .advance || lastSpatialCue == .turn || spokenMessage == "向前迈一步。" ? "正在重新观察脚前区域。" : spokenMessage
            feedback.deliver(text, sound: true); return
        }
        if message == "一步提示已静音。点重听，重新检查后播报。" {
            playNextStepOnRequest = true; live.retry(); return
        }
        if live.nav.activeStep?.spokenAt != nil {
            if !feedback.isBusy { feedback.deliver("本次只迈一步，站稳后再观察。", sound: true) }
            return
        }
        if let cue = live.repeatCue(), let origin = live.nav.current {
            let words = cue.kind == .route ? SignReading.spoken(cue.text) : cue.text
            message = cue.text; spokenMessage = words
            let generation = live.nav.generation, targetID = live.nav.waypoint
            feedback.deliver(words, sound: true, interrupt: cue.isEmergency, valid: { [weak live] in live?.validForSpeech(cue, origin: origin, generation: generation, targetID: targetID) == true })
        } else { feedback.deliver("正在重新观察脚前区域。", sound: true) }
    }
    private func clearStepMessage(completed: Bool) {
        guard lastSpatialCue == .advance else { return }
        lastSpatialCue = .wait
        message = completed ? "这一步已结束，正在观察下一步。" : "正在重新观察脚前区域。"
        spokenMessage = message
    }
    private func clearEvidence() {
        expiry?.cancel(); entranceCapture = nil; entranceProximity = nil; entranceSymbolID = nil
        acceptSince = now
        gate = RouteEvidenceGate(now: acceptSince)
        journey?.expireConfirmation()
        if let route = journey { live?.updateRoute(route) }
    }
    private func stopCapture() {
        if let live { live.closeSegment(); routeMeasures=live.measures; rememberMeasures(); live.stop() }
        live=nil; lastSpatialCue=nil; canCheckDoor=false
        feedback.onSpeech=nil
        playNextStepOnRequest = false
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
        let endpoint = cloudEnabled ? planningEndpoint : nil
        live=LiveNavigation(route:route,utterance:utterance,endpoint:endpoint,prior:prior,camera:camera,previousMeasures:routeMeasures,isSpeaking:{ [weak self] text in self?.feedback.isSpeaking(text) == true },speechBusy:{ [weak self] in self?.feedback.isBusy == true },cancelPlayback: { [weak self] in self?.feedback.cancelStep() },clearStepMessage: { [weak self] done in self?.clearStepMessage(completed: done) },routeChanged: { [weak self] updated in self?.journey = updated },output:{ [weak self] cue in self?.spatial(cue) },status:{ [weak self] note in
            guard let self, self.networkNote != note else {return}; self.networkNote=note
            // Network availability is informational. Do not enqueue it on the movement or stop voice channel.
        })
        live?.verifiedSymbol = { [weak self] id, frame in
            self?.consumeSigns(.init(target:.plate), at:frame.time, capturePose:frame, verifiedSymbolID:id)
        }
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
    private func consumeSigns(_ signs:WayfindingSigns,at sampledAt:Double,capturePose:FramePose?=nil,verifiedSymbolID:Int?=nil) {
            let spatial = capturePose != nil
            guard canGuide, sampledAt >= acceptSince, var route = journey else { return }
            // An empty OCR frame supplies no contradiction to a recently verified unlettered icon.
            if verifiedSymbolID == nil, signs.target == nil, !signs.restricted, signs.nearbyRoom == nil, !signs.signboard,
               let id = entranceSymbolID, let prior = entranceCapture, let current = camera.latestPose(),
               let live, live.nav.book.entrance(for:route.searchTarget,captured:prior,at:current,confirmedSymbolID:id).id == id { return }
            let proximity: EntranceProximity? = capturePose.map { capture in
                guard signs.target == .plate, !signs.restricted, let current = camera.latestPose(), let live else { return .unseen }
                return live.nav.book.entrance(for: route.searchTarget, captured: capture, at: current, confirmedSymbolID: verifiedSymbolID)
            }
            let isFreshPlate = signs.target == .plate && !signs.restricted
            if route.action?.confirmsDestination == true {
                if isFreshPlate && (!spatial || proximity?.id != nil && proximity?.id == entranceProximity?.id) { armExpiry() }
                else {
                    clearEvidence(); route.expireConfirmation(); journey = route; live?.updateRoute(route)
                    if !spatial { present(route.cue, speech: route.prompt.speech, interrupt: true) }
                }
            }
            let newVote = gate.accept(signs, at: sampledAt, landmarkID: proximity?.id)
            let samePlate = isFreshPlate && proximity?.id.map { gate.stillConfirmed(signs, landmarkID:$0) } == true
            // Do not wait for a different inscription when its distance changes during approach.
            let verifiedGraphic = verifiedSymbolID != nil && proximity?.id == verifiedSymbolID
            guard newVote || verifiedGraphic || samePlate && proximity != entranceProximity else {
                if samePlate { entranceCapture = capturePose }
                return
            }
            route.observe(signs, entrance: proximity, symbolOnly: verifiedGraphic)
            entranceSymbolID = verifiedGraphic ? verifiedSymbolID : nil
            entranceCapture = isFreshPlate ? capturePose : nil; entranceProximity = isFreshPlate ? proximity : nil
            if signs.scene.setting == .publicCorridor, let pose = capturePose, live?.confirmsCrossing(at:pose) == true { route.observedCrossing() }
            journey = route; live?.updateRoute(route)
            if spatial {
                if route.plannerTask == .approachDestination, let id = proximity?.id { live?.selectEntranceForApproach(id) }
                if route.action?.confirmsDestination == true { armExpiry() }
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
                    text = !verifiedGraphic && route.action == .atDestination ? "读到「\(route.searchTarget.text)」的独立标牌，可核对是否到达。" : route.cue
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
                live?.stationary(text, signFact:true)
                return
            }
            if route.action?.confirmsDestination == true { armExpiry() }
            if message != route.cue {
                let haptic: NavigationHaptic? = signs.restricted ? .warning : (signs == WayfindingSigns() ? nil : .guidance)
                present(route.cue, speech: route.prompt.speech, haptic: haptic, interrupt: signs.restricted)
            }
    }
    private func armExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.canGuide, self.journey?.action?.confirmsDestination == true else { return }
            self.clearEvidence()
            if let route=self.journey, self.live?.nav.current == nil || self.live?.allowsSignDirections == true { self.present(route.cue,speech:route.prompt.speech,interrupt:true) }
        }
    }
}
