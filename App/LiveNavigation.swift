import Foundation

/// Main-actor arbiter. The camera is the only clock for all observations and dispatch/readback poses.
@MainActor final class LiveNavigation {
    private struct Selection { let key: KeyObservation, reason: String, ticket: DecisionTicket, signs: [(Sighting, Int)] }
    private var uploads = LatestOnly<Selection>()
    private var request: Task<Void, Never>?, watchdog: Task<Void, Never>?
    private let client = CloudClient(), endpoint: URL?, camera: SignCamera, utterance: String
    private let isSpeaking: (String) -> Bool
    private var displayedFacts: WayfindingSigns?, factsSeenAt: FramePose?
    private var lastFactReceipt = -Double.infinity, missingFactFrames = 0
    private let output: (LocalCue) -> Void, status: (String) -> Void
    private(set) var nav: SpatialNavigator, measures = WalkMeasures()
    private var grid = LocalGrid(), delivery = CueDelivery(), lastPoseAt = -Double.infinity
    private var lastScene: UInt64?
    private var focusedSign: Int?, saidSign: (Int, String)?, needReobserve = false
    private var accessNotices = AccessNotices(), holdingForAccess = false
    private var signIssuedFrom: FramePose?, spokenMeaning: SignMeaning?
    private var stopped = false, hazard = false, firstUpload = true, nextUploadAt = 0.0, lastOfferAt = -Double.infinity
    private var reason: String?, issuedFrom: FramePose?, lastStage: JourneyStage?, lastFork = false, lastAisle: Int?
    private var knownIDs = Set<Int>(), generationLog: [(Double,Int)] = []
    private var modelTurn: (PlannerReply,Int)?
    private var stopUtterance: String?
    private var lastRequestPose: FramePose?, route: WayfindingJourney, prior: PriorMap?
    private var lastSeenDoorTarget: Int?
    var allowsSignDirections: Bool { nav.hasFrontProof && !nav.emergency && !holdingForAccess }
    var canManuallyVerifyDoor: Bool { nav.canManuallyVerifyDoor && !holdingForAccess }
    var canConfirmEntrance: Bool { !holdingForAccess && !nav.emergency }
    init(route:WayfindingJourney, utterance:String, endpoint:URL?, prior:PriorMap?, camera:SignCamera, previousMeasures:WalkMeasures,
         isSpeaking:@escaping(String)->Bool, output:@escaping(LocalCue)->Void, status:@escaping(String)->Void) {
        self.isSpeaking=isSpeaking; self.route=route; self.utterance=utterance; self.endpoint=endpoint; self.prior=prior; self.camera=camera; self.output=output; self.status=status
        nav=SpatialNavigator(doorTarget:route.target.isClassroomDoor); measures=previousMeasures; measures.openSegment(at:ProcessInfo.processInfo.systemUptime)
        watchdog=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(260)) } catch {return}
                guard let self, !self.stopped else {return}; let now=ProcessInfo.processInfo.systemUptime
                if now-self.lastPoseAt > 0.8 && self.nav.current != nil {
                    self.nav.invalidate(); self.nav.nearLost(); self.lastPoseAt=now
                    let moving = self.delivery.forwardOutstanding
                    self.deliver(.init(kind:.wait,text:moving ? "先停一下，相机画面已中断。" : "相机画面已中断，正在等待恢复。"), at:now, revoke:moving)
                }
            }
        }
    }
    func updateRoute(_ route:WayfindingJourney, userChanged:Bool=false) {
        if self.route.searchTarget != route.searchTarget || userChanged {
            displayedFacts=nil; factsSeenAt=nil
            nav.invalidate(); reason="changed_route"; modelTurn=nil; camera.requestKey(); focusedSign=nil; saidSign=nil
        }
        if route.stage != self.route.stage { reason="navigation_stage"; camera.requestKey() }
        self.route=route
    }
    func pose(_ p:FramePose) {
        guard !stopped else {return}
        if let previous=nav.current, !p.id.sameWorld(previous.id) {
            cancelUploads(); reason="tracking_reset"; firstUpload=true; modelTurn=nil; knownIDs.removeAll(); generationLog=[]; lastRequestPose=nil; lastScene=nil; focusedSign=nil; saidSign=nil; grid=LocalGrid(); accessNotices = AccessNotices(); holdingForAccess = false
        }
        lastPoseAt=p.time; nav.pose(p); markGeneration(p.time)
        measures.sample(p,scanning:nav.doorTarget)
        if let old=lastRequestPose, abs(turnAngle(p.heading-old.heading)) > 35 || old.position.groundDistance(p.position)>0.90, reason == nil {
            reason="deviation_or_new_position"; camera.requestKey()
        }
        render()
    }
    func near(_ raw:NearField) {
        guard !stopped, let p=nav.current, p.id.sameWorld(raw.pose.id), p.time-raw.pose.time <= 0.55,
              raw.pose.time > (nav.near?.pose.time ?? -.infinity) else {return}
        let n = grid.reconcile(raw)
        nav.risk(n); markGeneration(n.pose.time)
        _=nav.register(n.hazards,at:n.pose,local:true)
        if nav.emergency && !hazard { reason="blocked"; camera.requestKey() }
        if hazard && nav.hasFrontProof { reason="passage_reconfirmed"; camera.requestKey() }
        if nav.emergency || nav.hasFrontProof { hazard=nav.emergency }
        delivery.sampled(at:p.time,dangerPresent:nav.emergency || holdingForAccess,frontProven:nav.hasFrontProof)
        let best=n.best, fork=n.sectors.contains { $0.state == .free && $0.angle <= -15 } && n.sectors.contains { $0.state == .free && $0.angle >= 15 }
        if fork && !lastFork { reason="junction"; camera.requestKey() }
        if let best, lastAisle != best { reason="new_aisle"; camera.requestKey() }
        lastFork=fork; lastAisle=best; render()
    }
    private func markGeneration(_ t:Double) {
        if generationLog.last?.1 != nav.generation { generationLog.append((t,nav.generation)); generationLog=Array(generationLog.suffix(40)) }
    }
    func observation(_ key:KeyObservation, printedRestriction: Bool) {
        guard !stopped, let live=nav.current, key.pose.normal, key.pose.id.sameWorld(live.id) else {return}
        let ids=nav.register(key.features,at:key.pose,local:true)
        let signs = zip(key.features,ids).compactMap { item, id -> (Sighting, Int)? in
            guard item.kind == .sign, let id else { return nil }; return (item,id)
        }
        accessNotices.observe(key.pose, signs: signs, printedRestriction: printedRestriction)
        // A clear inscription is a fact on the first capture. Route changes and arrival
        // still require the separate voting and confirmation gates below the camera adapter.
        let readable = signs.filter { item, _ in
            guard item.confidence >= 0.78, let label = item.label else { return false }
            return WayfindingParser.sameInscription(label, route.searchTarget.text)
        }
        if readable.count == 1, !printedRestriction { focusedSign = readable[0].1 }

        var fresh=false
        for (s,id) in zip(key.features,ids) where s.kind == .door || s.kind == .sign {
            if let id, knownIDs.insert(id).inserted { fresh=true }
        }
        if fresh { reason="new_landmark" }
        if let d=nav.door { measures.lock(d, in:live.id) }
        if let mapped=prior?.nextPoint(for:route.searchTarget.text,from:live,anchors:nav.book.records,level:route.currentLevel) { nav.priorWaypoint=mapped } else { nav.priorWaypoint=nil }
        if let d=nav.door, let r=nav.book.records.first(where:{$0.id==d}), r.box.bottom-r.box.top > 0.40, lastSeenDoorTarget != d {
            reason="verify_door"; lastSeenDoorTarget=d
        }
        if route.stage == .verify && lastStage != .verify {reason="verify_destination"}; lastStage=route.stage
        render()
        guard !stopped, endpoint != nil, key.jpeg != nil, live.time >= nextUploadAt, live.time-lastOfferAt >= 0.6 else {return}
        if reason == nil, let scene=key.sceneSignature, let lastScene, (scene ^ lastScene).nonzeroBitCount >= 16 { reason="changed_view" }
        let trigger=firstUpload ? "first_observation":reason
        // While a request is in flight retain only the freshest eligible observation for the outstanding decision.
        guard let trigger = trigger ?? (uploads.pending != nil ? "latest_observation" : nil) else {return}
        let gen=generationLog.last(where:{$0.0<=key.pose.time})?.1 ?? -1
        let sel=Selection(key:key,reason:trigger,ticket:.init(pose:key.pose,generation:gen,destination:route.searchTarget.text),signs:signs)
        lastScene=key.sceneSignature
        firstUpload=false; reason=nil; lastOfferAt=live.time
        if let first=uploads.offer(sel) { send(first); return }
        #if DEBUG && targetEnvironment(simulator)
        // Let a phased loopback replay release its in-flight HTTP reply only after a new
        // camera measurement has actually reached the pending upload slot.
        if let phase = ProcessInfo.processInfo.environment["PATHSENSE_TEST_PHASE"] {
            let name = "\(phase).queued.\(Int(key.pose.heading.rounded()))" as CFString
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue: name), nil, nil, true)
        }
        #endif
    }
    private func send(_ sel:Selection) {
        let key=sel.key
        guard !stopped, let endpoint, let jpg=key.jpeg, let current=camera.latestPose(), current.id.sameWorld(key.pose.id),
              current.time-key.pose.time < 4, current.normal, route.searchTarget.text == sel.ticket.destination else { drain(); return }
        let refs=nav.book.records.sorted { $0.last.time > $1.last.time }
        var features=Array(key.features.prefix(60)); for i in features.indices { features[i].appearance=nil }
        let context=CloudContext(utterance:String(utterance.prefix(160)),destination:route.searchTarget.text,stage:route.stage.rawValue,trigger:sel.reason,
            capture:PosePacket(key.pose),request:PosePacket(current),history:nav.summary.suffix(4).map(PosePacket.init),image_width:key.sentWidth,image_height:key.sentHeight,
            features:features,scanned_bins:nav.scan.seen.sorted(),known:refs.filter { $0.kind.waypoint }.prefix(16).map(CloudAnchor.init),
            recent_hazards:refs.filter { !$0.kind.waypoint && current.time-$0.last.time < 1 }.prefix(8).map(CloudAnchor.init),
            last_instruction:nav.lastInstruction,turned_since_instruction:issuedFrom.map {turnAngle(current.heading-$0.heading)} ?? 0,
            moved_since_instruction:issuedFrom.map {$0.position.groundDistance(current.position)} ?? 0,sign_history:Array(route.history.suffix(5)))
        lastRequestPose=current
        request=Task { [weak self] in
            guard let self else {return}
            do {
                let reply=try await self.client.plan(endpoint:endpoint,context:context,jpeg:jpg)
                guard !Task.isCancelled, !self.stopped, let receipt=self.camera.latestPose(), receipt.id.sameWorld(key.pose.id) else {return}
                self.status("云端已连接 · 停步由本机判断")
                // Consume the newest pose before considering the reply; never enqueue provider movement speech verbatim.
                if receipt.time >= (self.nav.current?.time ?? 0) {self.nav.pose(receipt)}
                self.accept(reply, for:sel, at:receipt)
            } catch {
                guard !Task.isCancelled, !self.stopped else {return}
                self.status("云端暂不可用。本机继续读牌、避障和引导近处过道。")
                self.nextUploadAt=(self.nav.current?.time ?? 0)+4; self.reason="reconnect"; self.uploads=LatestOnly(); return
            }
            if !Task.isCancelled { self.drain() }
        }
    }
    private func accept(_ reply:PlannerReply, for sel:Selection, at p:FramePose) {
        guard reply.frame_id == sel.key.pose.id else {return}
        let items=reply.observations+reply.hazards
        let ids=nav.register(items.map { .init(kind:$0.kind,box:$0.box,confidence:0.64,sign:$0.sign) },at:sel.key.pose,local:false,capturedSigns:sel.signs)
        // Late observations belong to the captured scene. Only a current decision may choose a waypoint.
        if sel.ticket.destination == route.searchTarget.text {
            let signIDs = zip(items,ids).compactMap { item, id in item.kind == .sign && item.sign != nil ? id : nil }
            let selected = zip(items,ids).first { $0.0.ref == reply.target_ref && $0.0.kind == .sign }?.1
            if let id = selected ?? signIDs.first(where:{ nav.record($0)?.signReadout(at:p,target:route.searchTarget.text) != nil }) {
                focusedSign=id; useSign(at:p)
            }
        }
        guard sel.ticket.current(at:p,generation:nav.generation,destination:route.searchTarget.text), !nav.emergency, !holdingForAccess else {return}
        switch reply.action {
        case .target_waypoint:
            guard let i=items.firstIndex(where:{$0.ref==reply.target_ref}), let id=ids[i] else {return}
            if items[i].kind == .sign { focusedSign=id; useSign(at:p) }
            else { nav.select(id); modelTurn=(reply,id) }
        case .wait,.rescan,.verify_destination:
            let fallback = reply.action == .verify_destination ? "转动手机，看看目的地的标识。" : "可以慢慢转动手机，看看周围。"
            nav.cloudHold = .init(kind:.scan,text:reply.stationarySpeech ?? fallback); nav.cloudHoldUntil=p.time+2; reason="recheck"
        }
        render()
    }
    private func drain() { if let next=uploads.finish() {send(next)} }
    private func cancelUploads() { request?.cancel();request=nil;uploads=LatestOnly() }
    func finishMeasures(manual:Bool) { if measures.finished == nil {measures.finish(ProcessInfo.processInfo.systemUptime,door:nav.door,manual:manual)} }
    func stop() { stopped=true; watchdog?.cancel(); watchdog=nil; cancelUploads(); client.close(); nav=SpatialNavigator(doorTarget:nav.doorTarget); grid=LocalGrid(); modelTurn=nil }
    func closeSegment() { measures.closeSegment(at:ProcessInfo.processInfo.systemUptime) }
    func sessionInterrupted() { cancelUploads(); nav.recheck(); grid=LocalGrid(); modelTurn=nil; knownIDs=[]; delivery=CueDelivery(); focusedSign=nil; saidSign=nil }
    func retry() { nav.recheck(); reason="user_recheck"; camera.requestKey(); render() }
    func face() { nav.faceForward(); render() }
    func manualFinish() { if canManuallyVerifyDoor && nav.manualDoorArrival() { render(manual:true) } }
    func speech(_ text:String, time:Double, ended:Bool) { if text == stopUtterance { measures.speech(at:time,ended:ended) } }
    func instruction(_ text:String) { nav.lastInstruction=text; issuedFrom=nav.current }
    /// Keep the spoken facts separate from path permission, including a plaque seen while looking up.
    func stationary(_ text:String) {
        guard let pose = nav.current, !nav.emergency, !holdingForAccess else { return }
        deliver(.init(kind:.route,text:text), at:pose.time)
    }
    func observeReadout(_ facts: WayfindingSigns, at capture: FramePose, confirmed: Bool = false) {
        let vote = facts.votingEvidence
        if confirmed && vote != WayfindingSigns() { displayedFacts = vote }
        if displayedFacts == vote {
            factsSeenAt = capture
            lastFactReceipt = nav.current?.time ?? capture.time
            missingFactFrames = 0
        } else if factsSeenAt != nil {
            missingFactFrames += 1
            if missingFactFrames >= 2 { factsSeenAt = nil }
        }
    }
    private func keepReadout(at pose: FramePose) -> Bool {
        guard let last = delivery.last, last.kind == .route else { return false }
        if isSpeaking(SignReading.spoken(last.text)) { return true }
        if let seen = factsSeenAt, seen.id.sameWorld(pose.id), (0...10).contains(pose.time - lastFactReceipt),
           pose.position.groundDistance(seen.position) <= 0.38, pose.sameView(as:seen, within:12) { return true }
        guard saidSign?.1 == last.text, let sign = nav.record(focusedSign),
              (0...8).contains(pose.time - sign.last.time), let angle = sign.bearing(at:pose) else { return false }
        return abs(angle) <= 18 || (pose.sameView(as:sign.last, within:12) && pose.position.groundDistance(sign.last.position) <= 0.38)
    }
    @discardableResult func localSign(for label:String, at capture:FramePose) -> Bool {
        let matching = nav.book.records.filter { $0.kind == .sign && $0.last.id == capture.id && $0.label == label }
        guard matching.count == 1, let sign=matching.first, let p=nav.current else {return false}
        focusedSign=sign.id
        return useSign(at:p) || (saidSign?.0 == sign.id && delivery.last?.text == saidSign?.1)
    }
    @discardableResult private func useSign(at p:FramePose) -> Bool {
        guard !nav.emergency, !delivery.turnHasPriority(at: p.time), p.normal, !holdingForAccess, let id=focusedSign, let sign=nav.record(id),
              let words=sign.signReadout(at:p,target:route.searchTarget.text) else {return false}
        let reobserve=sign.bearing(at:p) == nil
        guard saidSign?.0 != id || saidSign?.1 != words || reobserve != needReobserve else {return false}
        // A new readable inscription must supersede “turn the phone”, even if geometry
        // and the symbol did not change. Only suppress jitter after the facts were read.
        // A fact readout carries a location sentence followed by its anchored meaning.
        let newFact = words.split(separator:"。", maxSplits:1).dropFirst().first
        let oldFact = saidSign?.1.split(separator:"。", maxSplits:1).dropFirst().first
        let gainingText = newFact != nil && newFact != oldFact
        if !gainingText, saidSign?.0 == id, sign.sign == spokenMeaning, reobserve == needReobserve, let origin=signIssuedFrom,
           origin.id.sameWorld(p.id), origin.position.groundDistance(p.position)<0.25,
           abs(turnAngle(origin.heading-p.heading))<12 { return false }
        if deliver(.init(kind:.route,text:words),at:p.time) {
            saidSign=(id,words); needReobserve=reobserve; signIssuedFrom=p; spokenMeaning=sign.sign; return true
        }
        return false
    }
    private func render(manual:Bool=false) {
        guard !stopped, let p=nav.current else {return}
        nav.verifyingRoute = route.action == .atDestination || route.stage == .landing || !route.choices.isEmpty
        let restricted = accessNotices.blocks(p, in: nav.book)
        if restricted && !holdingForAccess {
            nav.invalidate(); markGeneration(p.time)
        }
        holdingForAccess = restricted
        if restricted {
            if let hazard = nav.frontHazard {
                deliver(hazard == .drop ? .dropStop : .obstacleStop, at:p.time, cause:hazard.rawValue)
            } else {
                deliver(.init(kind:.stop,text:"先停一下，标牌写有通行限制。请核对这个入口。"), at:p.time, cause:"restriction")
            }
            return
        }
        let next = nav.cue(forwardOutstanding: delivery.forwardOutstanding)
        if next == .revokeAdvance {
            nav.invalidate(); markGeneration(p.time)
            deliver(.revokeAdvance,at:p.time,revoke:true)
            return
        }
        if let cue=next, cue.kind == .stop {
            deliver(cue,at:p.time,cause:nav.frontHazard?.rawValue ?? "obstacle"); return
        }
        if next == .noConfirmedAisle || next?.kind == .found || next?.kind == .aligned {
            if let next { deliver(next, at:p.time) }
            return
        }
        if let next, next.kind == .arrived {
            measures.finish(p.time,door:nav.door,manual:manual)
            deliver(next,at:p.time)
            return
        }
        if let next, next.isAvoidanceTurn {
            deliver(next, at: p.time)
            return
        }
        if let id=focusedSign, let record=nav.record(id),
           (record.last.time+12 >= p.time || record.bearing(at:p) == nil), useSign(at:p) { return }
        guard var cue=next else {return}
        if (cue.kind == .scan || cue.kind == .wait), keepReadout(at:p) { return }
        if cue.kind == .turn, nav.waypoint == modelTurn?.1, let (reply,id)=modelTurn,
           let bearing=nav.record(id)?.bearing(at:p), let words=reply.turnSpeech(error:bearing),
           cue.text.hasPrefix(bearing<0 ? "向左" : "向右") {cue.text=words}
        deliver(cue,at:p.time)
    }
    @discardableResult private func deliver(_ cue:LocalCue,at t:Double,cause:String="obstacle",revoke:Bool=false) -> Bool {
        guard delivery.take(cue,at:t,cause:cause,revoke:revoke) else {return false}
        nav.didDeliver(cue)
        if cue.isEmergency {
            stopUtterance=cue.text
            measures.hazard(at:cause == "restriction" ? t : nav.near?.pose.time ?? t)
            measures.requested(at:ProcessInfo.processInfo.systemUptime)
        }
        instruction(cue.text); output(cue); return true
    }
}
