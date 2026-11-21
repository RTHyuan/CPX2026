import Foundation

/// Main-actor arbiter. The camera is the only clock for all observations and dispatch/readback poses.
@MainActor final class LiveNavigation {
    private struct Selection { let key: KeyObservation, reason: String, ticket: DecisionTicket }
    private var uploads = LatestOnly<Selection>()
    private var request: Task<Void, Never>?, watchdog: Task<Void, Never>?
    private let client = CloudClient(), endpoint: URL?, camera: SignCamera, utterance: String
    private let output: (LocalCue) -> Void, status: (String) -> Void
    private(set) var nav: SpatialNavigator, measures = WalkMeasures()
    private var grid = LocalGrid(), lastCue: LocalCue?, lastCueAt = -Double.infinity, lastPoseAt = -Double.infinity
    private var stopped = false, hazard = false, firstUpload = true, nextUploadAt = 0.0, lastOfferAt = -Double.infinity
    private var reason: String?, issuedFrom: FramePose?, lastStage: JourneyStage?, lastFork = false, lastAisle: Int?
    private var knownIDs = Set<Int>(), generationLog: [(Double,Int)] = []
    private var modelTurn: (PlannerReply,Int)?
    private var stopUtterance: String?
    private var lastRequestPose: FramePose?, route: WayfindingJourney, prior: PriorMap?
    private var lastSeenDoorTarget: Int?
    var allowsSignDirections: Bool { nav.hasFrontProof && !nav.emergency }
    var canManuallyVerifyDoor: Bool { nav.canManuallyVerifyDoor }
    init(route:WayfindingJourney, utterance:String, endpoint:URL?, prior:PriorMap?, camera:SignCamera, previousMeasures:WalkMeasures,
         output:@escaping(LocalCue)->Void, status:@escaping(String)->Void) {
        self.route=route; self.utterance=utterance; self.endpoint=endpoint; self.prior=prior; self.camera=camera; self.output=output; self.status=status
        nav=SpatialNavigator(doorTarget:route.target.isClassroomDoor); measures=previousMeasures; measures.openSegment(at:ProcessInfo.processInfo.systemUptime)
        watchdog=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(260)) } catch {return}
                guard let self, !self.stopped else {return}; let now=ProcessInfo.processInfo.systemUptime
                if now-self.lastPoseAt > 0.8 && self.nav.current != nil {
                    self.deliver(.init(kind:.wait,text:"先停一下，相机画面已中断。"),at:now)
                    self.nav.invalidate(); self.nav.nearLost(); self.lastPoseAt=now
                }
            }
        }
    }
    func updateRoute(_ route:WayfindingJourney, userChanged:Bool=false) {
        if self.route.searchTarget != route.searchTarget || userChanged { nav.invalidate(); reason="changed_route"; modelTurn=nil; camera.requestKey() }
        if route.stage != self.route.stage { reason="navigation_stage"; camera.requestKey() }
        self.route=route
    }
    func pose(_ p:FramePose) {
        guard !stopped else {return}
        if let previous=nav.current, !p.id.sameWorld(previous.id) {
            cancelUploads(); reason="tracking_reset"; firstUpload=true; modelTurn=nil; knownIDs.removeAll(); generationLog=[]; lastRequestPose=nil
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
        if nav.emergency && !hazard { measures.hazard(at:n.pose.time); reason="blocked"; camera.requestKey() }
        if hazard && nav.hasFrontProof { reason="passage_reconfirmed"; camera.requestKey() }
        hazard=nav.emergency
        let best=n.best, fork=n.sectors.contains { $0.state == .free && $0.angle <= -15 } && n.sectors.contains { $0.state == .free && $0.angle >= 15 }
        if fork && !lastFork { reason="junction"; camera.requestKey() }
        if let best, lastAisle != best { reason="new_aisle"; camera.requestKey() }
        lastFork=fork; lastAisle=best; render()
    }
    private func markGeneration(_ t:Double) {
        if generationLog.last?.1 != nav.generation { generationLog.append((t,nav.generation)); generationLog=Array(generationLog.suffix(40)) }
    }
    func observation(_ key:KeyObservation) {
        guard !stopped, let live=nav.current, key.pose.normal, key.pose.id.sameWorld(live.id) else {return}
        let ids=nav.register(key.features,at:key.pose,local:true)
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
        let trigger=firstUpload ? "first_observation":reason
        // While a request is in flight retain only the freshest eligible observation for the outstanding decision.
        guard let trigger = trigger ?? (uploads.pending != nil ? "latest_observation" : nil) else {return}
        let gen=generationLog.last(where:{$0.0<=key.pose.time})?.1 ?? -1
        let sel=Selection(key:key,reason:trigger,ticket:.init(pose:key.pose,generation:gen,destination:route.searchTarget.text))
        firstUpload=false; reason=nil; lastOfferAt=live.time
        if let first=uploads.offer(sel) { send(first) }
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
                self.status("云端暂不可用。本机仍可读牌、寻找门和提醒停步。")
                self.nextUploadAt=(self.nav.current?.time ?? 0)+4; self.reason="reconnect"; self.uploads=LatestOnly(); return
            }
            if !Task.isCancelled { self.drain() }
        }
    }
    private func accept(_ reply:PlannerReply, for sel:Selection, at p:FramePose) {
        guard reply.frame_id == sel.key.pose.id else {return}
        let items=reply.observations+reply.hazards
        let ids=nav.register(items.map { .init(kind:$0.kind,box:$0.box,confidence:0.64) },at:sel.key.pose,local:false)
        guard sel.ticket.current(at:p,generation:nav.generation,destination:route.searchTarget.text), !nav.emergency else {return}
        switch reply.action {
        case .target_waypoint:
            guard let i=items.firstIndex(where:{$0.ref==reply.target_ref}), let id=ids[i] else {return}
            nav.select(id); modelTurn=(reply,id)
        case .wait,.rescan,.verify_destination:
            let fallback=reply.action == .rescan ? "请站定，慢慢补扫四周。" : (reply.action == .wait ? "请先站定。" : "请站定，核对眼前的目的地。")
            nav.cloudHold = .init(kind:.wait,text:reply.stationarySpeech ?? fallback); nav.cloudHoldUntil=p.time+2; reason="recheck"
        }
        render()
    }
    private func drain() { if let next=uploads.finish() {send(next)} }
    private func cancelUploads() { request?.cancel();request=nil;uploads=LatestOnly() }
    func finishMeasures(manual:Bool) { if measures.finished == nil {measures.finish(ProcessInfo.processInfo.systemUptime,door:nav.door,manual:manual)} }
    func stop() { stopped=true; watchdog?.cancel(); watchdog=nil; cancelUploads(); client.close(); nav=SpatialNavigator(doorTarget:nav.doorTarget); grid=LocalGrid(); modelTurn=nil }
    func closeSegment() { measures.closeSegment(at:ProcessInfo.processInfo.systemUptime) }
    func sessionInterrupted() { cancelUploads(); nav.recheck(); grid=LocalGrid(); modelTurn=nil; knownIDs=[] }
    func retry() { nav.recheck(); reason="user_recheck"; camera.requestKey(); render() }
    func face() { nav.faceForward(); render() }
    func manualFinish() { if nav.manualDoorArrival() { render(manual:true) } }
    func speech(_ text:String, time:Double, ended:Bool) { if text == stopUtterance { measures.speech(at:time,ended:ended) } }
    func instruction(_ text:String) { nav.lastInstruction=text; issuedFrom=nav.current }
    private func render(manual:Bool=false) {
        guard !stopped, let p=nav.current else {return}
        if lastCue?.kind == .advance && !nav.hasFrontProof && !nav.emergency {
            nav.invalidate(); markGeneration(p.time)
            deliver(.init(kind:.wait,text:"先停一下，重新核对眼前通道。"),at:p.time)
            return
        }
        guard var cue=nav.cue() else {return}
        if cue.kind == .turn, nav.waypoint == modelTurn?.1, let (reply,id)=modelTurn,
           let bearing=nav.record(id)?.bearing(at:p), let words=reply.turnSpeech(error:bearing),
           cue.text.hasPrefix(bearing<0 ? "向左" : "向右") {cue.text=words}
        if cue.kind == .arrived { measures.finish(p.time,door:nav.door,manual:manual) }
        deliver(cue,at:p.time)
    }
    private func deliver(_ cue:LocalCue,at t:Double) {
        guard cue != lastCue else {return}
        // Give discovery a chance to finish. A safety transition always wins, even in this window.
        if lastCue?.kind == .found && t-lastCueAt < 1.0 && nav.current?.normal == true && nav.near?.visible == true && ![.stop,.arrived].contains(cue.kind) {return}
        if lastCue?.kind == .stop && t-lastCueAt < 0.65 && cue.kind != .stop {return}
        if cue.isEmergency { stopUtterance=cue.text; measures.requested(at:ProcessInfo.processInfo.systemUptime) }
        lastCue=cue; lastCueAt=t; instruction(cue.text); output(cue)
    }
}
