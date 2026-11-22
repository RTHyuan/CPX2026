import Foundation

/// Main-actor arbiter. The camera is the only clock for all observations and dispatch/readback poses.
@MainActor final class LiveNavigation {
    private struct Captured {
        let key: KeyObservation, matches: [(Sighting, Int)]
        var signs: [(Sighting, Int)] { matches.filter { $0.0.kind == .sign } }
        var image: CloudKeyframe? {
            key.jpeg.map { CloudKeyframe(pose: key.pose, jpeg: $0, width: key.sentWidth, height: key.sentHeight) }
        }
    }
    private struct Selection {
        let frame: Captured, history: [Captured], reason: String, ticket: DecisionTicket, taskVersion: Int
        var key: KeyObservation { frame.key }
    }
    private var history: [Captured] = []
    private let routeChanged: (WayfindingJourney) -> Void
    private var approachedID: Int?
    private var entranceSymbolGate = EntranceSymbolGate()
    var verifiedSymbol: ((Int, FramePose) -> Void)?
    private var lastGoalFrame: FrameID?
    private var uploads = LatestOnly<Selection>()
    private var request: Task<Void, Never>?, watchdog: Task<Void, Never>?
    private let client = CloudClient(), endpoint: URL?, camera: SignCamera, utterance: String
    private let isSpeaking: (String) -> Bool, speechBusy: () -> Bool
    private var lastReading: PendingSignReading?, pendingReading: PendingSignReading?
    private var pendingRouteNotice: (reading: PendingSignReading, revision: Int)?
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
    private var taskRevision = 0
    private var playbackID: UUID?
    private var displayedStep: UUID?
    private let cancelPlayback: () -> Void
    private let clearStepMessage: (Bool) -> Void
    private var lastSentAudio: (LocalCue, FramePose)?
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    var allowsSignDirections: Bool { nav.hasFrontProof && !nav.emergency && !holdingForAccess }
    var canManuallyVerifyDoor: Bool { nav.canManuallyVerifyDoor && !holdingForAccess }
    var canConfirmEntrance: Bool { !holdingForAccess && !nav.emergency }
    init(route:WayfindingJourney, utterance:String, endpoint:URL?, prior:PriorMap?, camera:SignCamera, previousMeasures:WalkMeasures,
         isSpeaking:@escaping(String)->Bool, speechBusy:@escaping()->Bool, cancelPlayback: @escaping () -> Void, clearStepMessage: @escaping (Bool) -> Void, routeChanged: @escaping (WayfindingJourney) -> Void, output:@escaping(LocalCue)->Void, status:@escaping(String)->Void) {
        self.routeChanged = routeChanged
        self.cancelPlayback = cancelPlayback; self.clearStepMessage = clearStepMessage
        self.isSpeaking=isSpeaking; self.speechBusy=speechBusy; self.route=route; self.utterance=utterance; self.endpoint=endpoint; self.prior=prior; self.camera=camera; self.output=output; self.status=status
        nav=SpatialNavigator(doorTarget:route.target.isClassroomDoor || (route.requiresExit && route.plannerTask != .verifyCrossing), requiresPlannedTarget:true); measures=previousMeasures; measures.openSegment(at:ProcessInfo.processInfo.systemUptime)
        nav.setStepTask(destination: route.target.text, task: route.plannerTask.rawValue, revision: taskRevision)
        watchdog=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(260)) } catch {return}
                guard let self, !self.stopped else {return}; let now=ProcessInfo.processInfo.systemUptime
                if now-self.lastPoseAt > 0.8 && self.nav.current != nil {
                    let moving = self.nav.stepIsMoving || self.nav.activeStep?.startedMovingAt != nil
                    self.nav.revokeStep("cameraTimeout", at: now); self.nav.nearLost(); self.lastPoseAt=now
                    self.flushSteps()
                    self.deliver(moving ? .uncheckedMotion : .init(kind:.wait,text:"相机画面已中断，正在等待恢复。"), at:now, cause:"tracking")
                }
            }
        }
    }
    func updateRoute(_ route:WayfindingJourney, userChanged:Bool=false) {
        if self.route.taskVersion != route.taskVersion || self.route.stage != route.stage || self.route.searchTarget != route.searchTarget || userChanged {
            taskRevision += 1
            nav.setStepTask(destination: route.target.text, task: route.plannerTask.rawValue, revision: taskRevision)
            flushSteps()
            displayedFacts=nil; factsSeenAt=nil; lastReading=nil; pendingReading=nil
            nav.doorTarget = route.target.isClassroomDoor || (route.requiresExit && route.plannerTask != .verifyCrossing)
            if self.route.requiresExit && !route.requiresExit { nav.clearRoomTargets() }
            nav.invalidate(); reason="changed_route"; modelTurn=nil; camera.requestKey(); focusedSign=nil; saidSign=nil
        }
        if route.stage != self.route.stage { reason="navigation_stage"; camera.requestKey() }
        self.route=route
    }
    func pose(_ p:FramePose) {
        guard !stopped else {return}
        if let previous=nav.current, !p.id.sameWorld(previous.id) {
            guard p.time >= previous.time, p.id.session != previous.id.session || p.id.world >= previous.id.world else { return }
            var next = route; next.lostExitAnchor()
            if next != route { updateRoute(next); routeChanged(next) }
            cancelUploads(); history.removeAll(); approachedID = nil; lastGoalFrame = nil; reason="tracking_reset"; firstUpload=true; modelTurn=nil; knownIDs.removeAll(); generationLog=[]; lastRequestPose=nil; lastScene=nil; lastReading=nil; pendingReading=nil; delivery=CueDelivery(); focusedSign=nil; saidSign=nil; grid=LocalGrid(); accessNotices = AccessNotices(); holdingForAccess = false
        }
        lastPoseAt=p.time; nav.pose(p); markGeneration(p.time)
        measures.sample(p,scanning:nav.doorTarget)
        if let old=lastRequestPose, abs(turnAngle(p.heading-old.heading)) > 35 || old.position.groundDistance(p.position)>0.90, reason == nil {
            reason="deviation_or_new_position"; camera.requestKey()
        }
        render()
    }
    func near(_ raw:NearField) { consumeNear(raw, renderAfter: true) }
    private func consumeNear(_ raw:NearField, renderAfter: Bool) {
        guard !stopped, let p=nav.current, p.id.sameWorld(raw.pose.id), p.time-raw.pose.time <= 0.55,
              raw.pose.time > (nav.near?.pose.time ?? -.infinity) else {return}
        let n = grid.reconcile(raw)
        nav.risk(n); markGeneration(n.pose.time)
        _=nav.register(n.hazards,at:n.pose,local:true)
        if nav.emergency && !hazard { reason="blocked"; camera.requestKey() }
        if hazard && nav.hasFrontProof { reason="passage_reconfirmed"; camera.requestKey() }
        if nav.emergency || nav.hasFrontProof { hazard=nav.emergency }
        delivery.sampled(at:p.time,dangerPresent:nav.emergency || holdingForAccess,frontProven:nav.hasFrontProof, observedClear:n.visible && n.reason == nil && n.front == .free)
        let best=n.best, fork=n.sectors.contains { $0.state == .free && $0.angle <= -15 } && n.sectors.contains { $0.state == .free && $0.angle >= 15 }
        if fork && !lastFork { reason="junction"; camera.requestKey() }
        if let best, lastAisle != best { reason="new_aisle"; camera.requestKey() }
        lastFork=fork; lastAisle=best
        if renderAfter { render() }
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
        updateLocalTarget(at:live, observed:key)
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
        let matches = zip(key.features, ids).compactMap { feature, id in id.map { (feature, $0) } }
        let captured = Captured(key: key, matches: matches)
        let eligible = history.filter { $0.key.pose.id.sameWorld(key.pose.id) && $0.key.pose.time < key.pose.time && key.pose.time - $0.key.pose.time < 100 }
        let sel = Selection(frame: captured, history: Array(eligible.suffix(2)), reason: trigger,
                            ticket: .init(pose:key.pose, generation:gen, destination:route.target.text), taskVersion: taskRevision)
        // Keep distinct viewpoints. A stationary sequence should not evict the last view of the door or sign.
        if let last = history.last, last.key.pose.sameView(as:key.pose, within:16),
           last.key.pose.position.groundDistance(key.pose.position) < 0.35,
           Set(last.matches.map { $0.1 }) == Set(matches.map { $0.1 }) { history.removeLast() }
        history.append(captured); history = Array(history.suffix(2))
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
              current.time-key.pose.time < 4, current.normal, route.target.text == sel.ticket.destination, taskRevision == sel.taskVersion else { drain(); return }
        let refs=nav.book.records.sorted { $0.last.time > $1.last.time }
        var features=Array(key.features.prefix(60)); for i in features.indices { features[i].appearance=nil }
        let context=CloudContext(utterance:String(utterance.prefix(160)),destination:route.target.text,stage:route.stage.rawValue,trigger:sel.reason,
            capture:PosePacket(key.pose),request:PosePacket(current),history:nav.summary.suffix(4).map(PosePacket.init),image_width:key.sentWidth,image_height:key.sentHeight,
            features:features,scanned_bins:nav.scan.seen.sorted(),known:refs.filter { $0.kind.waypoint }.prefix(16).map(CloudAnchor.init),
            recent_hazards:refs.filter { !$0.kind.waypoint && current.time-$0.last.time < 1 }.prefix(8).map(CloudAnchor.init),
            last_instruction:nav.lastInstruction,turned_since_instruction:issuedFrom.map {turnAngle(current.heading-$0.heading)} ?? 0,
            moved_since_instruction:issuedFrom.map {$0.position.groundDistance(current.position)} ?? 0,sign_history:Array(route.history.suffix(5)))
        let planning = PlanningSnapshot(route), execution = nav.stepPhase.rawValue
        lastRequestPose=current
        request=Task { [weak self] in
            guard let self else {return}
            do {
                let reply=try await self.client.plan(endpoint:endpoint, context:context, jpeg:jpg, history:sel.history.compactMap(\.image), planning:planning, executionState:execution)
                guard !Task.isCancelled, !self.stopped, let receipt=self.camera.latestPose(), receipt.id.sameWorld(key.pose.id) else {return}
                self.status("云端已连接 · 停步由本机判断")
                // Consume the newest pose before considering the reply; never enqueue provider movement speech verbatim.
                if receipt.time >= (self.nav.current?.time ?? 0) {self.nav.pose(receipt)}
                self.accept(reply, for:sel, at:receipt)
            } catch {
                guard !Task.isCancelled, !self.stopped else {return}
                self.status("云端暂不可用。本机继续读文字和检查脚前通道；纯图形标识需复核。")
                self.nextUploadAt=(self.nav.current?.time ?? 0)+4; self.reason="reconnect"; self.uploads=LatestOnly(); return
            }
            if !Task.isCancelled { self.drain() }
        }
    }
    private func accept(_ reply:PlannerReply, for sel:Selection, at p:FramePose) {
        guard reply.frame_id == sel.key.pose.id else {return}
        let items = reply.observations + reply.hazards
        var ids = Array<Int?>(repeating: nil, count: items.count)
        // Every box belongs to its own native image/pose, including detections from an old viewpoint.
        for source in sel.history + [sel.frame] {
            let indices = items.indices.filter { items[$0].source_frame == source.key.pose.id }
            let detections = indices.map { i in Sighting(kind: items[i].kind, box: items[i].box, confidence: 0.64, sign: items[i].sign) }
            let mapped = nav.register(detections, at: source.key.pose, local: false, capturedSigns: source.signs)
            for (index, result) in zip(indices, mapped) {
                let item = items[index]
                if item.kind != .sign, item.kind.waypoint {
                    let seen = source.matches.filter { $0.0.kind == item.kind && $0.0.box.overlap(with: item.box) > 0.45 && nav.record($0.1) != nil }
                    ids[index] = seen.count == 1 ? seen[0].1 : (seen.isEmpty ? result : nil)
                } else { ids[index] = result }
            }
        }
        guard sel.taskVersion == taskRevision, sel.ticket.current(at:p,generation:nav.generation,destination:route.target.text),
              !nav.emergency, !holdingForAccess, let plan = reply.plan else { return }
        // Require a new corridor view from beyond the same mapped door. Historical corridor
        // photos and a glimpse through an open door cannot complete the crossing.
        if route.plannerTask == .verifyCrossing, plan.scene == .publicCorridor, !plan.scene_uncertain,
           let layout = plan.layout, layout.kind == .corridor, layout.source_frame == sel.key.pose.id,
           confirmsCrossing(at: sel.key.pose), confirmsCrossing(at: p) {
            var next = route; next.observedCrossing()
            updateRoute(next); routeChanged(next)
            reason = "crossing_verified"; camera.requestKey(); render(); return
        }
        let index = items.firstIndex { $0.ref == reply.target_ref }
        if reply.target_ref != nil, index.flatMap({ ids[$0] }) == nil { reason = "target_needs_observation"; camera.requestKey(); return }
        if let index, let id = ids[index] {
            if route.requiresExit && !nav.acceptsRoomTarget(id) {
                reason = "reobserve_same_exit"; camera.requestKey(); return
            }
            if [.verifyDestination, .approachDestination].contains(plan.task), !route.target.isClassroomDoor,
               [.door, .sign].contains(items[index].kind) || plan.task == .verifyDestination {
                let source = (sel.history + [sel.frame]).first { $0.key.pose.id == items[index].source_frame }
                let signsInImage = (source?.signs ?? []) + items.indices.compactMap { i -> (Sighting, Int)? in
                    guard items[i].kind == .sign, items[i].source_frame == items[index].source_frame, let signID = ids[i] else { return nil }
                    return (.init(kind: .sign, box: items[i].box, confidence: 0.64, sign: items[i].sign), signID)
                }
                var otherDoors = source?.matches.compactMap { feature, observedID in
                    feature.kind == .door && observedID != id ? feature.box : nil
                } ?? []
                otherDoors += items.indices.compactMap { i in
                    guard i != index, items[i].kind == .door, items[i].source_frame == items[index].source_frame,
                          ids[i] != id else { return nil }
                    return items[i].box
                }
                if !nav.supportsDestination(route.searchTarget, id: id, box: items[index].box,
                                            signsInImage: signsInImage, otherDoorBoxes: otherDoors) {
                    reason = "destination_evidence_missing"; camera.requestKey(); return
                }
            }
        } else if plan.task == .verifyDestination || plan.task == .approachDestination {
            // An observation-only reply cannot start a destination approach from a bare doorway.
            if ![.verifyDestination, .approachDestination].contains(route.plannerTask) {
                reason = "destination_evidence_missing"; camera.requestKey(); return
            }
        }
        var planned = route
        guard planned.applyPlan(plan, targetKind:index.map { items[$0].kind }) else { reason = "task_conflict"; camera.requestKey(); return }
        // A stationary or uncertain proposal cannot switch a movement target behind the executor.
        if planned != route { updateRoute(planned); routeChanged(planned) }
        if let index, let id = ids[index], let source = items[index].source_frame {
            lastGoalFrame = source
            measures.plans.append(.init(frame:source, box:items[index].box, landmark:id, directive:plan, receivedAt:p.id))
        }
        if reply.action == .verify_destination, !route.requiresExit, let index, let id = ids[index],
           items[index].source_frame == sel.key.pose.id, items[index].sign?.representsEntrance(for: route.searchTarget) == true {
            let capture = sel.key.pose
            if entranceSymbolGate.accept(id:id, capture:capture) { verifiedSymbol?(id, capture) }
        } else if reply.action == .verify_destination { entranceSymbolGate = EntranceSymbolGate() }
        if reply.action == .verify_destination, route.plannerTask == .approachDestination, let index, let id = ids[index], nav.waypoint != id {
            nav.select(id)
        }
        switch reply.action {
        case .target_waypoint:
            guard let i=items.firstIndex(where:{$0.ref==reply.target_ref}), let id=ids[i] else {return}
            if route.requiresExit {
                guard nav.selectRoomTarget(id) else { return }
            } else { nav.select(id) }
            modelTurn = (reply, nav.waypoint ?? id)
            if items[i].kind == .sign { focusedSign=id; useSign(at:p) }
        case .wait,.rescan,.verify_destination:
            let fallback = reply.action == .verify_destination ? "转动手机，看看目的地的标识。" : "可以慢慢转动手机，看看周围。"
            nav.cloudHold = .init(kind:.scan,text:reply.stationarySpeech ?? fallback); nav.cloudHoldUntil=p.time+2; reason="recheck"
        }
        render()
    }
    private func reachedIntermediateDoor() {
        guard nav.door != nil else { return }
        var next = route; next.reachedWaypoint(.door)
        guard next.plannerTask == .verifyCrossing else { return }
        nav.beginCrossing(); updateRoute(next); routeChanged(next)
        if let id = nav.crossing?.id { nav.select(id) }
        reason = "verify_crossing"; camera.requestKey()
        stationary(next.cue)
    }
    /// A changed scene must be captured after reaching and passing the same locally mapped exit.
    func confirmsCrossing(at capture: FramePose) -> Bool {
        guard let p = nav.current, let crossing = nav.crossing else { return false }
        return crossing.confirms(capture) && crossing.confirms(p)
    }
    private func updateLocalTarget(at p: FramePose, observed key: KeyObservation) {
        if route.requiresExit {
            var next = route
            let id = nav.roomWaypoint(for: &next, capture: key.pose, features: key.features)
            if next != route { updateRoute(next); routeChanged(next); reason = "room_waypoint_changed"; camera.requestKey() }
            if let id { nav.select(id) }
            return
        }
        if route.target.isClassroomDoor, let id = nav.door { nav.select(id); return }
        if let id = nav.waypoint, let r = nav.record(id) {
            if route.plannerTask == .approachDestination, approachedID != id, r.kind != .sign,
               r.count >= 3, let point = r.point, (0...0.8).contains(p.time - r.last.time),
               p.position.groundDistance(point) < 1.05,
               r.first.position.groundDistance(point) - p.position.groundDistance(point) > 0.4 {
                approachedID = id
                var next = route; next.reachedWaypoint(r.kind)
                if next != route { updateRoute(next); routeChanged(next); reason = "waypoint_reached"; camera.requestKey() }
            }
            if nav.waypoint != nil { return }
        }
        chooseObservationTarget(at:p, observed:key)
    }
    /// Offline planning still selects an image-bound landmark. A free sector by itself has no identity.
    private func chooseObservationTarget(at p: FramePose, observed key: KeyObservation) {
        guard nav.waypoint == nil, !nav.verifyingRoute, !route.target.isClassroomDoor || nav.door == nil else { return }
        let records = nav.book.records.filter { $0.last.id == key.pose.id && $0.bearing(at:p) != nil }
        if !route.requiresExit, let signID = focusedSign, let sign = records.first(where: { $0.id == signID }),
           sign.sign?.arrow == nil, let label = sign.label, WayfindingParser.sameInscription(label,route.searchTarget.text) {
            nav.select(sign.id); return
        }
        // A verified arrow is a direction to search. Only choose an actual entrance seen on that side.
        let facts = key.signs.map { WayfindingParser.read($0, for:route.searchTarget, landmark:route.site.landmark) }
        var desired = 0.0, constrained = false
        if case .listed(let site) = facts?.target, let arrow = site.arrow {
            switch arrow {
            case .left, .upperLeft, .lowerLeft: desired = -60; constrained = true
            case .right, .upperRight, .lowerRight: desired = 60; constrained = true
            case .ahead: desired = 0; constrained = true
            case .down: return // A printed downward arrow needs scene context; it is not a step-down instruction.
            }
        }
        let openings = records.filter { $0.kind == .aisle_entrance && $0.count >= 2 }
        let candidates = openings.compactMap { r in r.bearing(at:p).map { (r,abs(turnAngle($0-desired))) } }.sorted { $0.1 < $1.1 }
        guard let (opening, error) = candidates.first, !constrained || error <= 30 else { return }
        nav.select(opening.id)
    }
    private func drain() { if let next=uploads.finish() {send(next)} }
    private func cancelUploads() { request?.cancel();request=nil;uploads=LatestOnly() }
    func finishMeasures(manual:Bool) { if measures.finished == nil {measures.finish(ProcessInfo.processInfo.systemUptime,door:nav.door,manual:manual)} }
    func stop() { nav.revokeStep("sessionEnded", at: now); flushSteps(); stopped=true; watchdog?.cancel(); watchdog=nil; cancelUploads(); client.close(); nav=SpatialNavigator(doorTarget:nav.doorTarget, requiresPlannedTarget:true); grid=LocalGrid(); modelTurn=nil }
    func closeSegment() { nav.revokeStep("segmentClosed", at: now); flushSteps(); measures.closeSegment(at:ProcessInfo.processInfo.systemUptime) }
    func sessionInterrupted() { nav.revokeStep("sessionInterrupted", at: now); flushSteps(); cancelUploads(); nav.recheck(); grid=LocalGrid(); modelTurn=nil; knownIDs=[]; delivery=CueDelivery(); lastReading=nil; pendingReading=nil; focusedSign=nil; saidSign=nil }
    func retry() { nav.recheck(); reason="user_recheck"; camera.requestKey(); render() }
    func face() { nav.faceForward(); render() }
    func manualFinish() { if canManuallyVerifyDoor && nav.manualDoorArrival() { render(manual:true) } }
    func speech(_ text:String, time:Double, ended:Bool) {
        if !ended { nav.lastInstruction = text; issuedFrom = nav.current }
        if text == stopUtterance { measures.speech(at: time, ended: ended) }
    }
    // An assessment can reach the camera's lock before its main-queue notification.
    // Consume that observation without recursively offering speech from inside an audio callback.
    private func syncPlaybackEvidence() -> Bool {
        let (pose, measured) = camera.latestAssessment()
        guard let pose, let measured, let current = nav.current, pose.id.sameWorld(current.id),
              measured.pose.id.sameWorld(pose.id), pose.normal else { return false }
        nav.pose(pose)
        if nav.near?.pose.id != measured.pose.id { consumeNear(measured, renderAfter: false) }
        return nav.near?.pose.id == measured.pose.id
    }
    /// Runs on MainActor after audio preparation, immediately before the player is started.
    func submitForPlayback(_ cue: LocalCue) -> Bool {
        guard !stopped, !holdingForAccess, let id = cue.permitID, syncPlaybackEvidence() else { return false }
        let t = now
        guard nav.permitsSpeech(cue, at: t) else { return false }
        nav.submittedStep(id, at: t); playbackID = id; flushSteps()
        return true
    }
    func playbackStarted(_ cue: LocalCue) -> Bool {
        guard !stopped, let id = cue.permitID, playbackID == id else { return false }
        guard syncPlaybackEvidence(), nav.stepSpeechStarted(id, at: now) else {
            declineStep(cue, reason: "proofLostAtAudioStart"); flushSteps(); return false
        }
        nav.lastInstruction = cue.text; issuedFrom = nav.current; displayedStep = id
        flushSteps(); return true
    }
    func playbackEnded(_ id: UUID, finished: Bool) {
        if playbackID == id { playbackID = nil }
        if finished { nav.stepSpeechEnded(id, at: now) } else { nav.cancelStepSpeech(id, at: now) }
        flushSteps()
    }
    func declineStep(_ cue: LocalCue, reason: String) {
        guard let id = cue.permitID, nav.activeStep?.id == id else { return }
        nav.revokeStep(reason, at: now); flushSteps()
    }
    private func flushSteps() {
        delivery.syncStep(nav.activeStep)
        let events = nav.takeStepEvents()
        measures.stepEvents.append(contentsOf: events)
        if let id = playbackID, nav.activeStep?.id != id {
            playbackID = nil; cancelPlayback()
        }
        if let id = displayedStep, nav.activeStep?.id != id {
            displayedStep = nil
            clearStepMessage(events.contains { $0.type == "completed" && $0.permit?.id == id })
        }
    }
    /// Recalculate turns and text bound to a landmark. A repeat tap never grants a second step.
    func repeatCue() -> LocalCue? {
        guard !stopped, let p = camera.latestPose(), p.normal, now - p.time < 0.55 else { return nil }
        nav.pose(p)
        if let hazard = nav.frontHazard { return nav.safetyCue(forwardOutstanding: nav.activeStep?.spokenAt != nil) ?? (hazard == .drop ? .dropAtRest : .obstacleAtRest) }
        if lastSentAudio?.0.kind == .advance || displayedStep != nil { return nil }
        if let reading = lastReading, lastSentAudio?.0.kind == .route,
           let words = reading.words(at:p, for:route.searchTarget.text, in:nav.book) { return .init(kind:.route,text:words) }
        if let (cue, origin) = lastSentAudio, cue.kind != .turn && cue.kind != .stop && cue.kind != .route,
           origin.id.sameWorld(p.id), p.sameView(as:origin,within:10), p.position.groundDistance(origin.position)<0.12 { return cue }
        return nav.cue(forwardOutstanding: false).flatMap { $0.kind == .advance ? nil : $0 }
    }
    func validForSpeech(_ cue: LocalCue, origin: FramePose, generation: Int, targetID: Int?) -> Bool {
        guard !stopped else { return false }
        if cue.isEmergency || cue == .revokeAdvance { return true }
        guard let p = camera.latestPose(), p.id.sameWorld(origin.id) else { return false }
        if cue.kind == .turn || cue.kind == .face { return generation == nav.generation && targetID == nav.waypoint && now - p.time < 0.55 && p.normal && p.sameView(as: origin, within: 10) && origin.position.groundDistance(p.position) < 0.16 && (!nav.emergency || cue.isAvoidanceTurn) }
        return true
    }
    /// Keep the spoken facts separate from path permission, including a plaque seen while looking up.
    func stationary(_ text:String, signFact:Bool = false) {
        guard let pose = nav.current, !nav.emergency, !holdingForAccess else { return }
        let cue = LocalCue(kind:.route,text:text)
        if signFact {
            let reading = PendingSignReading(cue:cue, origin:pose, goal:route.searchTarget.text, landmarkID:nil)
            if deliver(cue, at:pose.time) { lastReading=reading }
            else if speechBusy() && delivery.last != cue { pendingReading=reading }
        } else if !deliver(cue, at:pose.time), delivery.last != cue {
            pendingRouteNotice = (PendingSignReading(cue:cue, origin:pose, goal:route.searchTarget.text, landmarkID:nil), taskRevision)
        }
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
    func selectEntranceForApproach(_ id: Int) {
        guard !holdingForAccess, !nav.emergency, nav.record(id)?.kind == .sign, nav.waypoint != id else { return }
        nav.select(id); focusedSign = id
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
            lastReading = .init(cue:.init(kind:.route,text:words), origin:p, goal:route.searchTarget.text, landmarkID:id)
            saidSign=(id,words); needReobserve=reobserve; signIssuedFrom=p; spokenMeaning=sign.sign; return true
        }
        return false
    }
    private func render(manual:Bool=false) {
        guard !stopped, let p=nav.current else {return}
        flushSteps()
        defer { flushSteps() }
        nav.verifyingRoute = route.action == .atDestination || route.stage == .landing || !route.choices.isEmpty
        let restricted = accessNotices.blocks(p, in: nav.book)
        if restricted && !holdingForAccess {
            nav.invalidate(); markGeneration(p.time)
        }
        if holdingForAccess && !restricted { delivery.leftRestrictedEntrance() }
        holdingForAccess = restricted
        if restricted {
            if !nav.stepIsMoving, nav.activeStep?.spokenAt == nil {
                deliver(.init(kind:.wait,text:"标牌写有通行限制。请原地核对这个入口。"), at:p.time, cause:"restriction"); return
            }
            if let hazard = nav.frontHazard {
                deliver(hazard == .drop ? .dropStop : .obstacleStop, at:p.time, cause:hazard.rawValue)
            } else {
                deliver(.init(kind:.stop,text:"先停一下，标牌写有通行限制。请核对这个入口。"), at:p.time, cause:"restriction")
            }
            return
        }
        let next = nav.cue(forwardOutstanding: nav.activeStep?.spokenAt != nil, canAnnounceSweep: !speechBusy())
        if next == .revokeAdvance {
            nav.invalidate(); markGeneration(p.time)
            deliver(.revokeAdvance,at:p.time,revoke:true)
            return
        }
        if let cue=next, cue.kind == .stop {
            deliver(cue,at:p.time,cause:nav.frontHazard?.rawValue ?? "obstacle"); return
        }
        if next == .stepReview || next == .obstacleAtRest || next == .personAtRest || next == .dropAtRest {
            if let next { deliver(next, at:p.time) }; return
        }
        if next == .noConfirmedAisle || next?.kind == .found || next?.kind == .aligned {
            if let next { deliver(next, at:p.time) }
            return
        }
        if let next, next.kind == .arrived {
            if route.requiresExit && !route.target.isClassroomDoor {
                reachedIntermediateDoor(); return
            }
            measures.finish(p.time,door:nav.door,manual:manual)
            deliver(next,at:p.time)
            return
        }
        if let next, next.isAvoidanceTurn {
            deliver(next, at: p.time)
            return
        }
        if !nav.emergency, !speechBusy(), let notice = pendingRouteNotice {
            if notice.revision != taskRevision || notice.reading.words(at:p, for:route.searchTarget.text, in:nav.book) == nil {
                pendingRouteNotice = nil
            } else if deliver(notice.reading.cue, at:p.time) {
                pendingRouteNotice = nil
                return
            } else if delivery.last == notice.reading.cue {
                pendingRouteNotice = nil
            }
        }
        if !nav.emergency, !speechBusy(), let reading=pendingReading {
            if let words=reading.words(at:p, for:route.searchTarget.text, in:nav.book) {
                let cue=LocalCue(kind:.route,text:words)
                if deliver(cue,at:p.time) {
                    lastReading=reading; pendingReading=nil
                    if let id=reading.landmarkID { saidSign=(id,words) }
                    return
                }
            } else { pendingReading=nil }
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
        // Re-evaluate ordinary directions on the next AR frame after actual speech finishes.
        // Do not queue a turn or permission to walk for later playback.
        let urgent = cue.isEmergency || revoke || cue.kind == .arrived
        guard urgent || cue.kind == .aligned || !speechBusy() else { return false }
        guard delivery.take(cue,at:t,cause:cause,revoke:revoke) else {return false}
        if urgent, let reading=lastReading, isSpeaking(SignReading.spoken(reading.cue.text)) {
            pendingReading = reading
        }
        nav.didDeliver(cue)
        if cue.isEmergency {
            stopUtterance=cue.text
            measures.hazard(at:cause == "restriction" ? t : nav.near?.pose.time ?? t)
            measures.requested(at:ProcessInfo.processInfo.systemUptime)
        }
        if let p = nav.current, cue.kind != .aligned { lastSentAudio = (cue,p) }
        output(cue); return true
    }
}
