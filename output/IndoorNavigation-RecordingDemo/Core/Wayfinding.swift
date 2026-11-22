import Foundation

/// An independent inscription can identify a goal at any image scale. Only current,
/// matching local observations and a triangulated point can measure its proximity.
enum EntranceProximity: Equatable {
    case unseen, unmeasured(Int), distant(Int), nearby(Int)
    var id: Int? {
        switch self { case .unseen: return nil; case .unmeasured(let id), .distant(let id), .nearby(let id): return id }
    }
}
struct EntranceSymbolGate {
    private var candidate: (id: Int, pose: FramePose)?
    mutating func accept(id: Int, capture: FramePose) -> Bool {
        defer { candidate = (id, capture) }
        guard let prior = candidate, prior.id == id, prior.pose.id.sameWorld(capture.id),
              prior.pose.id.frame < capture.id.frame else { return false }
        return (0.1...20).contains(capture.time-prior.pose.time)
    }
}
extension LandmarkBook {
    func entrance(for target: Destination, captured: FramePose, at current: FramePose, confirmedSymbolID: Int? = nil) -> EntranceProximity {
        guard captured.normal, current.normal, captured.id.sameWorld(current.id),
              (0...(confirmedSymbolID == nil ? 2.5 : 6)).contains(current.time-captured.time), current.sameView(as: captured, within: 22) else { return .unseen }
        let matches = records.filter { r in
            guard r.kind == .sign, !r.signConflict else { return false }
            if let confirmedSymbolID {
                return r.id == confirmedSymbolID && r.signCapture?.id == captured.id && r.sign?.representsEntrance(for:target) == true
            }
            return r.hasLocalSign && r.labelCapture?.id == captured.id &&
                r.label.map { WayfindingParser.isPlate(SignParser.normalize($0), for: target) } == true
        }
        guard matches.count == 1, let sign = matches.first, let bearing = sign.bearing(at: current), abs(bearing) < 48 else { return .unseen }
        guard let point = sign.point, sign.count >= 3 else { return .unmeasured(sign.id) }
        // Ground distance is to the matched sign, not the physical length of a step.
        return current.position.groundDistance(point) <= 1.2 ? .nearby(sign.id) : .distant(sign.id)
    }
}

/// The locally triangulated door and the tracked approach define a finite crossing.
/// The outside scene still has to be observed independently. This guide supplies a
/// target bearing only; the execution layer checks the volume anew at every station.
struct MappedDoorCrossing {
    let id: Int, threshold: V3, direction: V3, observed: FramePose
    private var previous: FramePose
    private var inside: Bool
    private var passed: FramePose?

    init?(id: Int, localDoor: Landmark, from p: FramePose) {
        guard localDoor.kind == .door, localDoor.count >= 3, let point = localDoor.point,
              p.normal, p.id.sameWorld(localDoor.last.id), (0...0.8).contains(p.time - localDoor.last.time) else { return nil }
        let toward = point - p.position, distance = p.position.groundDistance(point)
        guard (0.12...1.2).contains(distance), abs(turnAngle(toward.heading - p.heading)) <= 25 else { return nil }
        self.id = id; threshold = point; observed = localDoor.last
        direction = V3(toward.x, 0, toward.z).unit
        previous = p; inside = true
    }
    private func offset(_ p: FramePose) -> (forward: Double, lateral: Double) {
        let delta = p.position - threshold
        return (delta.dot(direction), delta.dot(V3(direction.z, 0, -direction.x)))
    }
    mutating func sample(_ p: FramePose) {
        guard p.time >= previous.time else { return }
        let earlier = previous
        previous = p
        let d = offset(p)
        let continuous = earlier.normal && p.normal && p.id.sameWorld(earlier.id) && p.id.sameWorld(observed.id)
            && p.time - earlier.time <= 0.55 && p.position.groundDistance(earlier.position) <= 0.30
        if !continuous || abs(d.lateral) > 0.42 || !(-1.4...2.0).contains(d.forward) { inside = false; passed = nil }
        if p.normal, p.id.sameWorld(observed.id), abs(d.lateral) <= 0.42, (-1.2 ... -0.12).contains(d.forward) { inside = true; passed = nil }
        if inside, continuous, passed == nil, d.forward >= 0.25 { passed = p }
    }
    func confirms(_ p: FramePose) -> Bool {
        guard let passed, p.normal, p.id.sameWorld(observed.id), p.id.frame >= passed.id.frame, p.time >= passed.time else { return false }
        let d = offset(p)
        return (0.25...2.0).contains(d.forward) && abs(d.lateral) <= 0.42
    }
    func bearing(at p: FramePose) -> Double? {
        let d = offset(p)
        guard inside, passed == nil, p.normal, p.id.sameWorld(observed.id),
              (-1.25..<0.25).contains(d.forward), abs(d.lateral) <= 0.42 else { return nil }
        // Centre the approach on the measured door. At the threshold it drops out of the
        // camera view; following the measured approach axis avoids turning back into the room.
        let heading = d.forward < -0.22 ? (threshold - p.position).heading : direction.heading
        return turnAngle(heading - p.heading)
    }
}

enum JourneyStage: String {
    case survey = "环顾四周", doorway = "寻找公共区域", orient = "确认你的位置", directory = "寻找导览牌"
    case transfer = "寻找换层点", landing = "核对楼层", corridor = "沿途找标识", verify = "核对目的地", arrived = "已确认到达"
    var icon: String {
        switch self {
        case .survey: return "viewfinder"; case .doorway: return "door.left.hand.open"; case .orient: return "location"
        case .directory: return "list.bullet.rectangle"; case .transfer: return "arrow.up.arrow.down"
        case .landing: return "square.3.layers.3d"; case .corridor: return "signpost.right"; case .verify: return "scope"; case .arrived: return "checkmark.circle.fill"
        }
    }
}

/// Facts are collected across stops. The room number never supplies a floor and a sign
/// in the frame never proves that the user has physically moved or arrived.
struct WayfindingJourney: Equatable {
    let target: Destination
    private(set) var stage: JourneyStage = .survey
    private(set) var originRoom: String?
    private(set) var latestRoom: String?
    private(set) var currentLevel: String?
    private(set) var site = RouteSite()
    private(set) var resolvedName: String?
    private(set) var choices: [RouteChoice] = []
    private var chosenSite: RouteChoice?
    var searchTarget: Destination {
        guard case .named = target, let resolvedName else { return target }
        return .named(resolvedName)
    }
    var cue: String { prompt.text }
    private(set) var prompt: GuidancePrompt = "慢慢转动手机，看看四周的门、入口或导览牌。"
    private(set) var history: [String] = []
    private(set) var action: Action?
    private(set) var plannerScene: PlannerScene = .unknown
    private(set) var plannerTask: PlannerTask = .observe
    private(set) var taskVersion = 0
    private(set) var requiresExit = false
    private var nearExit = false
    private var outsideRoom = false
    private var approachedPortal = false
    private var transferFacility: String?
    enum Action: String {
        case crossed = "我已通过这扇门", atTransfer = "我已到换层点", atDestination = "已核对，确认到达"
        case confirmUnmeasuredEntrance = "我就在目的地入口旁，已独立核对"
        var confirmsDestination: Bool { self == .atDestination || self == .confirmUnmeasuredEntrance }
    }
    init(target: Destination) { self.target = target }

    private mutating func setTask(_ task: PlannerTask) {
        if plannerTask != task { plannerTask = task; taskVersion += 1 }
    }
    private mutating func setScene(_ scene: PlannerScene) {
        if plannerScene != scene { plannerScene = scene; taskVersion += 1 }
    }
    private mutating func rememberRoom(_ room: String) {
        latestRoom = room
        if originRoom == nil { originRoom = room; log("首次门牌 · \(room)") }
    }
    private mutating func needExit() {
        guard !outsideRoom else { return }
        requiresExit = true; stage = .doorway
        if !plannerTask.exitTask { setTask(.findExit) }
    }
    /// Accept a semantic proposal only while it agrees with unfinished physical obligations.
    /// The caller separately checks capture identity, the task revision, and the latest local pose.
    @discardableResult mutating func applyPlan(_ directive: PlannerDirective, targetKind: FeatureKind?) -> Bool {
        guard stage != .arrived, directive.valid, directive.task.accepts(targetKind) else { return false }
        let previousTaskVersion = taskVersion, previousStage = stage
        let scene = directive.scene_uncertain ? plannerScene : directive.scene
        if outsideRoom && (directive.task.exitTask || scene == .room) { return false }
        if directive.scene_uncertain, targetKind == nil, plannerTask != .observe { return true }
        if targetKind == nil, requiresExit, plannerTask.exitTask, directive.task.exitTask, directive.task != plannerTask {
            return false // A wait/rescan with no replacement landmark cannot undo physical progress.
        }
        if (requiresExit || scene == .room && !target.isClassroomDoor) && !directive.task.exitTask && directive.task != .observe { return false }
        if directive.task.exitTask && !requiresExit && scene != .room && !target.isClassroomDoor { return false }
        if directive.task == .verifyCrossing && !nearExit { return false }
        if plannerTask == .verifyCrossing && ![.observe, .verifyCrossing].contains(directive.task) { return false }
        // Looking through the doorway into a corridor does not move the phone across it.
        if !directive.scene_uncertain && !(requiresExit && scene == .publicCorridor) { setScene(scene) }
        if scene == .room && !outsideRoom { needExit() }
        if scene == .publicCorridor && !requiresExit { outsideRoom = true; if stage == .survey { stage = .corridor } }
        if directive.task == .verifyDestination && action != .atDestination {
            // The model can recognize an entrance from across the hall. Local geometry owns proximity.
            setTask(.approachDestination)
        } else if directive.task == .findExit, let targetKind, [.door, .aisle_entrance].contains(targetKind) {
            setTask(targetKind == .door ? .approachExit : .approachAisle)
        } else if directive.task != .observe || plannerTask == .observe { setTask(directive.task) }
        if directive.task.exitTask { stage = .doorway }
        if (taskVersion != previousTaskVersion || stage != previousStage), action == nil, choices.isEmpty,
           ![.directory, .transfer, .landing, .verify].contains(stage) {
            // Resume with the accepted semantic task. Confirmation prompts and known
            // directory/floor instructions retain their independent local evidence.
            switch plannerTask {
            case .observe:
                switch plannerScene {
                case .publicCorridor: prompt = "已识别公共走廊。请观察沿途导向牌。"
                case .room: prompt = "已识别室内空间。请观察出口和过道。"
                default: break
                }
            case .findExit: prompt = "请观察通往公共区域的门和过道。"
            case .approachAisle: prompt = "请将手机对准选定的过道入口。"
            case .approachExit: prompt = "请将手机对准选定的门。"
            case .verifyCrossing: prompt = "请观察同一扇门外的环境，核对是否已进入公共区域。"
            case .findSigns: prompt = "请观察沿途导向牌，寻找\(searchTarget.text)标识。"
            case .approachDestination: prompt = "请观察通往\(searchTarget.text)的标识和对应入口。"
            case .verifyDestination: prompt = "请观察\(searchTarget.text)入口的标识，核对目的地。"
            }
        }
        return true
    }
    /// A local geometric approach or a deliberate user confirmation supplies completion evidence.
    /// Callers must match the active landmark, not just another door of the same kind.
    mutating func reachedWaypoint(_ kind: FeatureKind) {
        switch (plannerTask, kind) {
        case (.approachAisle, .aisle_entrance): setTask(.approachExit)
        case (.findExit, .door), (.approachExit, .door):
            nearExit = true; approachedPortal = true; action = .crossed
            setTask(.verifyCrossing); stage = .doorway
            prompt = "已接近选定的门。通过后请观察门外环境，或确认已进入公共区域。"
        case (.approachDestination, .sign), (.approachDestination, .door): setTask(.verifyDestination)
        default: break
        }
    }
    mutating func lostExitAnchor() {
        guard requiresExit else { return }
        nearExit = false; approachedPortal = false; action = nil
        setTask(.findExit); stage = .doorway
        prompt = "位置跟踪已重置，请重新观察出口和通往它的过道。"
    }
    mutating func observedCrossing() {
        guard requiresExit, nearExit, plannerTask == .verifyCrossing else { return }
        enteredPublicArea()
    }

    mutating func observe(_ observed: WayfindingSigns, entrance: EntranceProximity? = nil, symbolOnly: Bool = false) {
        guard stage != .arrived else { return }
        // Coarse directory/floor phases map to the semantic task when no model is available.
        defer {
            if !requiresExit && [.orient, .directory, .corridor, .transfer, .landing].contains(stage),
               [.observe, .verifyDestination].contains(plannerTask) { setTask(.findSigns) }
        }
        var sign = observed
        choices = []
        let previousAction = action
        action = nil
        if sign.restricted {
            prompt = "读到通行限制。请停在当前位置核对现场标牌，寻找开放的入口或询问工作人员。"
            if stage == .verify { stage = .corridor }
            return
        }
        if let floor = sign.currentLevel {
            if currentLevel != floor { log("位置 · \(floor)") }
            currentLevel = floor
        }
        if let room = sign.nearbyRoom { rememberRoom(room) }
        if !outsideRoom, sign.scene.setting == .room {
            setScene(.room); needExit()
        } else if !requiresExit, sign.scene.setting == .publicCorridor {
            setScene(.publicCorridor); outsideRoom = true
            if stage == .survey || stage == .doorway { stage = .corridor }
            if plannerTask == .observe { setTask(.findSigns) }
        }
        if requiresExit {
            // Read and retain sign facts without treating them as evidence of a crossing.
            stage = .doorway
            if case .listed(let found) = sign.target {
                if let level = found.level { site.level = level }
                if let landmark = found.landmark { site.landmark = landmark }
            }
            if let door = sign.scene.door {
                approachedPortal = true; action = .crossed
                if plannerTask == .findExit { setTask(.approachExit) }
                prompt = "画面\(door)有疑似门。请观察门前通道，进入公共区域后再核对。"
            } else if nearExit || previousAction == .crossed && approachedPortal {
                action = .crossed; prompt = "请核对是否已通过选定的门进入公共区域。"
            } else if plannerTask == .approachAisle {
                prompt = "当前目标是侧过道入口。请观察通往入口的区域。"
            } else {
                prompt = "先寻找通往公共区域的出口。请观察教室两侧的过道和门。"
            }
            return
        }
        if let chosenSite, sign.choices.contains(chosenSite) {
            sign.choices = []
            sign.target = .listed(chosenSite.site)
        }
        if !sign.choices.isEmpty, sign.target == nil || sign.target == .ambiguous {
            choices = sign.choices; stage = .directory
            prompt = "目录里有多个可能的条目。请核对名称和楼层，选择你要去的地方。"; return
        }
        if sign.target == .ambiguous {
            site = RouteSite(); stage = .directory; transferFacility = nil
            prompt = "读到互相冲突的目标条目。请把镜头对准要去的分区和它对应的那一行。"; return
        }
        if case .listed(let found) = sign.target {
            if let selected = chosenSite?.site, (selected.level != nil && found.level != nil && selected.level != found.level)
                || (selected.landmark != nil && found.landmark != nil && selected.landmark != found.landmark) {
                stage = goalOnOtherFloor ? .transfer : .corridor
                prompt = "这块牌指向另一个同名地点。你选的是\(site: site)，请找对应的标识，或重新确认位置。"
                return
            }
            // A fresh directory can correct an earlier guess or a previous building's listing.
            if let newLevel = found.level, let oldLevel = site.level, oldLevel != newLevel {
                site = RouteSite(); transferFacility = nil
            }
            if let level = found.level { site.level = level; log("目标楼层 · \(level)") }
            if let zone = found.landmark { site.landmark = zone; log("目标分区 · \(zone)") }
            if site.level != nil && site.level != currentLevel {
                stage = .transfer
                if let transport = sign.transfer, let arrow = sign.transferArrow {
                    transferFacility = transport; action = .atTransfer
                    prompt = "目录将\(target.text)列在\(site: site)。\(transport)指示牌\(direction(arrow))，请在换层点核对。"; return
                }
                prompt = "导览牌把\(target.text)列在\(site: site)。\(found.arrow.map { direction($0) + "。" } ?? "")请找电梯或楼梯的指示。"
            } else {
                stage = .corridor
                let next = found.arrow.map { direction($0) + "。到下一个路口后站定再扫。" } ?? "请寻找\(site.landmark ?? "沿途")的方向牌或独立门牌。"
                prompt = "指示牌提到\(target.text)。\(next)"
            }
            return
        }
        if sign.target == .plate {
            // A plate on a different known floor may belong to a branch with the same name.
            if let floor = currentLevel, let wanted = site.level, floor != wanted {
                stage = .transfer; prompt = "读到同名标识，但上次楼层牌是\(floor: floor)，目录指向\(floor: wanted)。请先核对当前楼层牌或重新读取目录。"; return
            }
            if currentLevel == nil, let wanted = site.level {
                stage = .landing; prompt = "读到同名标识。目录指向\(floor: wanted)，请先扫本层的楼层牌，再核对门牌或店招。"; return
            }
            if let entrance {
                switch entrance {
                case .nearby: break
                case .unseen, .distant, .unmeasured:
                    setTask(.approachDestination); stage = .corridor
                    if case .unmeasured = entrance {
                        action = .confirmUnmeasuredEntrance
                        prompt = "读到\(target.text)标牌，距离尚未测出。如果已经在入口旁，请独立核对后确认。"
                    } else {
                        action = nil; prompt = "读到\(target.text)标牌。请观察相应入口和下一步区域。"
                    }
                    return
                }
            }
            setTask(.verifyDestination); stage = .verify; action = .atDestination
            if symbolOnly {
                prompt = "入口附近再次辨认到\(target.text)图标。请独立核对现场入口，确认后结束导航。"; return
            }
            prompt = "面前的独立标识写着\(SignReading.spoken(searchTarget.text))。请核对门牌或店招，确认后结束导航。"; return
        }
        if stage == .verify { stage = .corridor }
        if let floor = sign.currentLevel {
            if let wanted = site.level {
                if floor == wanted {
                    stage = .corridor; transferFacility = nil
                    prompt = "楼层牌是\(floor: floor)，与目标楼层一致。请环顾本层，寻找\(site.landmark ?? target.text)的指示牌。"
                } else {
                    stage = .transfer; prompt = "楼层牌是\(floor: floor)，目标在\(floor: wanted)。请继续寻找通往\(floor: wanted)的电梯或楼梯。"
                }
            } else { stage = .directory; prompt = "楼层牌是\(floor: floor)。请寻找列有\(target.text)的楼层目录。" }
            return
        }
        if let transport = sign.transfer, let goal = site.level, goal != currentLevel {
            transferFacility = transport
            if let arrow = sign.transferArrow {
                stage = .transfer; prompt = "\(transport)指示牌\(direction(arrow))。到\(transport)旁再扫，目标楼层是\(floor: goal)。"; action = .atTransfer
            } else {
                stage = .landing; action = .atTransfer
                prompt = "读到\(transport)标识。目标楼层是\(floor: goal)。请核对入口和楼层牌，需要换层时可找工作人员协助。"
            }
            return
        }
        if let arrow = sign.onward, let zone = site.landmark {
            stage = site.level != nil && site.level != currentLevel ? .transfer : .corridor
            prompt = "\(zone)的指示牌\(direction(arrow))。到了下一个指示牌再扫。"; return
        }
        if let room = sign.nearbyRoom {
            if goalOnOtherFloor { stage = .transfer; prompt = "眼前门牌是\(room)。目标在\(site: site)，请继续找换层指示。" }
            else if site.level != nil { stage = .corridor; prompt = "眼前门牌是\(room)，请继续寻找\(target.text)的走廊指示或独立牌。" }
            else {
                stage = .directory
                prompt = plannerScene == .unknown ? "记下门牌\(room)。目的地是\(target.text)。请观察两侧，核对现在是在房间内还是走廊。" : "记下门牌\(room)。请在公共区域寻找楼层目录，确认\(target.text)在哪里。"
            }
            return
        }
        if sign.target == .mention {
            prompt = "这段文字提到\(target.text)。请观察同一条目的楼层或箭头，或核对独立标识。"; return
        }
        if stage == .survey || stage == .doorway, !outsideRoom {
            let door = sign.scene.door
            if let portal = sign.portal {
                guard target.isClassroomDoor else {
                    prompt = "读到\(portal)标识。请观察它所在的通道，核对自己是在房间内还是走廊。"; return
                }
                if let arrow = sign.portalArrow {
                    stage = .doorway; prompt = "\(portal)指示牌\(direction(arrow))。请转动镜头寻找对应门口，核对眼前通道。"; return
                }
                stage = .doorway; approachedPortal = true; action = .crossed
                prompt = "读到\(portal)标识。请核对眼前的门和通道，通过后站定，再环顾寻找门牌或目录。"; return
            }
            if let door {
                guard target.isClassroomDoor else {
                    prompt = "画面有疑似门。请观察两侧环境，核对是在房间内还是公共走廊。"; return
                }
                stage = .doorway; approachedPortal = true; action = .crossed
                if sign.scene.geometricDoor {
                    prompt = "画面\(door)有疑似门形轮廓，边框延伸到地面。请核对门口和通道，通过后再扫周围。"; return
                }
                prompt = "\(sign.scene.setting == .room ? "画面像在室内。" : "")\(door == "画面中" ? door : "画面" + door)有疑似门。请核对门的位置与通行情况，通过后再扫周围。"; return
            }
            if let setting = sign.scene.setting {
                prompt = setting == .outside ? "画面像在室外。请转动镜头，寻找主入口或入口处的导览牌。" : "请观察周围的分区和导向标识，核对当前位置。"; return
            }
        }
        if sign.signboard {
            stage = goalOnOtherFloor ? .transfer : .directory
            prompt = "看到了导览牌。请把目标名称、楼层及同一行的箭头一起放进画面。"; return
        }
        if previousAction == .crossed, approachedPortal { action = .crossed }
        prompt = recovery
    }
    private var goalOnOtherFloor: Bool { site.level != nil && site.level != currentLevel }
    private func direction(_ arrow: SignArrow) -> String { "箭头指向\(arrow.words)" }
    private var recovery: GuidancePrompt {
        switch stage {
        case .survey, .doorway: return "请慢慢转动手机寻找入口或门。如果已在公共区域，可以直接扫门牌或目录。"
        case .orient, .directory: return "请环顾四周，寻找门旁的号码或入口导览牌，让要找的名称和楼层同时进入画面。"
        case .transfer: return "目标在\(site: site)。请站定扫描附近的换层指示，留意电梯的方向。"
        case .landing: return "到站后请扫描独立的楼层牌，核对是否到达\(site: site)。"
        case .corridor, .verify: return "请寻找通往\(site.landmark ?? target.text)的箭头或独立标牌。线索不足时可询问服务台。"
        case .arrived: return "已确认到达\(target.text)。"
        }
    }
    mutating func choose(_ option: RouteChoice) {
        guard choices.contains(option) else { return }
        chosenSite = option
        resolvedName = option.name; site = RouteSite(); log("选定条目 · \(option.name)")
        observe(WayfindingSigns(target: .listed(option.site)))
    }
    mutating func confirm() {
        switch action {
        case .crossed: enteredPublicArea()
        case .atTransfer:
            stage = .landing; action = nil; log("已确认换层点 · \(transferFacility ?? "现场")")
            prompt = "目标在\(site: site)。请核对\(transferFacility ?? "换层设施")的现场说明，离开后扫描楼层牌。"
        case .atDestination, .confirmUnmeasuredEntrance:
            action = nil; stage = .arrived; log("确认到达 · \(target.text)"); prompt = "已确认到达\(target.text)。"
        case nil: break
        }
    }
    mutating func finishedDoor(manual: Bool) {
        guard target.isClassroomDoor else {return}
        stage = .arrived; action = nil; choices = []
        prompt = manual ? "你已核对教室门口，请停下。" : "已到教室门口，请停下。"
        log(manual ? "用户核对门口" : "重见同一扇门，已核对接近证据")
    }
    mutating func confirmedInsideRoom() {
        guard stage != .arrived, plannerScene == .unknown, !outsideRoom else { return }
        setScene(.room); needExit(); action = nil
        log("用户确认在房间内"); prompt = "已记下在房间内。请观察两侧的过道和通往公共区域的门。"
    }
    mutating func enteredPublicArea() {
        guard stage != .arrived, !outsideRoom, plannerScene == .unknown || requiresExit || stage == .survey || stage == .doorway else { return }
        outsideRoom = true; requiresExit = false; nearExit = false; approachedPortal = false
        setScene(.publicCorridor); setTask(.findSigns)
        action = nil; stage = .orient; log("已进入公共区域")
        prompt = "已进入公共区域。转动手机，看看刚经过的门牌或走廊方向牌。"
    }
    mutating func relocalize() {
        guard stage != .arrived else { return }
        choices = []; resolvedName = nil; chosenSite = nil
        outsideRoom = false; requiresExit = false; nearExit = false; approachedPortal = false
        setScene(.unknown); setTask(.observe); taskVersion += 1
        stage = .orient; currentLevel = nil; site = RouteSite(); latestRoom = nil; transferFacility = nil; action = nil
        log("重新定位"); prompt = "请转动手机，看看当前位置牌和附近的目录。"
    }
    mutating func expireConfirmation() {
        let hadPrompt = action != nil || !choices.isEmpty
        choices = []
        action = nil
        if stage == .verify { stage = .corridor; setTask(.approachDestination) }
        if hadPrompt { prompt = recovery }
    }
    private mutating func log(_ entry: String) { if history.last != entry { history = Array((history + [entry]).suffix(12)) } }
}

extension WayfindingSigns {
    /// The text and its row determine a sign vote. Door detector boxes move by pixels
    /// even when the same plaque stays in view. Keep scene-only votes for doorway searches.
    var votingEvidence: Self {
        var facts = self
        facts.scene = SceneClues()
        if facts != Self() { return facts }
        facts.scene = scene
        facts.scene.doorBoxes = []
        return facts
    }
}

/// Vote on structured route evidence, not the quick reader's verdict: two directories
/// can both mention the target while pointing to different floors or opposite arrows.
struct RouteEvidenceGate {
    private var candidate: WayfindingSigns?
    private var lastTime: TimeInterval = -.infinity
    private var delivered: WayfindingSigns?
    private var candidateID: Int?, deliveredID: Int?
    private var currentRepeated = false
    private var lastUseful: TimeInterval
    init(now: TimeInterval) { lastUseful = now }
    func stillConfirmed(_ signs: WayfindingSigns, landmarkID: Int) -> Bool {
        let evidence = signs.votingEvidence
        return currentRepeated && candidate == evidence && delivered == evidence && deliveredID == landmarkID && candidateID == landmarkID
    }
    mutating func accept(_ signs: WayfindingSigns, at now: TimeInterval, landmarkID: Int? = nil) -> Bool {
        guard now > lastTime else { return false }
        let signs = signs.votingEvidence
        let repeated = candidate == signs && candidateID == landmarkID && (0.1...3.5).contains(now - lastTime)
        currentRepeated = repeated; candidate = signs; candidateID = landmarkID
        lastTime = now
        if repeated, signs != WayfindingSigns() {
            lastUseful = now
            guard delivered != signs || deliveredID != landmarkID else { return false }
            delivered = signs; deliveredID = landmarkID
            return true
        }
        // An empty reading can request a rescan. A changing sequence of plausible
        // but conflicting signs must never be delivered as a navigational fact.
        guard signs == WayfindingSigns(), now - lastUseful >= 5, delivered != signs else { return false }
        delivered = signs; deliveredID = landmarkID
        return true
    }
}
