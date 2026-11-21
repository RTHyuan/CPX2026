import Foundation

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
    private(set) var prompt: GuidancePrompt = "请站定，慢慢把镜头转向四周，寻找门、入口或附近的导览牌。"
    private(set) var history: [String] = []
    private(set) var action: Action?
    private var outsideRoom = false
    private var approachedPortal = false
    private var transferFacility: String?
    enum Action: String { case crossed = "我已通过这扇门", atTransfer = "我已到换层点", atDestination = "已核对，确认到达" }
    init(target: Destination) { self.target = target }

    mutating func observe(_ observed: WayfindingSigns) {
        guard stage != .arrived else { return }
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
            stage = .verify; action = .atDestination
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
                prompt = "读到\(transport)标识。请核对现场入口，使用\(transport)前往\(floor: goal)。到站后扫描楼层牌。"
            }
            return
        }
        if let arrow = sign.onward, let zone = site.landmark {
            stage = site.level != nil && site.level != currentLevel ? .transfer : .corridor
            prompt = "\(zone)的指示牌\(direction(arrow))。到了下一个指示牌再扫。"; return
        }
        if let room = sign.nearbyRoom {
            latestRoom = room
            if originRoom == nil { originRoom = room; log("首次门牌 · \(room)") }
            if goalOnOtherFloor { stage = .transfer; prompt = "眼前门牌是\(room)。目标在\(site: site)，请继续找换层指示。" }
            else if site.level != nil { stage = .corridor; prompt = "眼前门牌是\(room)，请继续寻找\(target.text)的走廊指示或独立牌。" }
            else { stage = .directory; prompt = "记下门牌\(room)。请在公共区域寻找楼层目录，确认\(target.text)在哪里。" }
            return
        }
        if sign.target == .mention {
            prompt = "这段文字提到\(target.text)。请靠近同一条目的楼层或箭头，或核对独立标识。"; return
        }
        if stage == .survey || stage == .doorway, !outsideRoom {
            let door = sign.scene.door
            if let portal = sign.portal {
                if let arrow = sign.portalArrow {
                    stage = .doorway; prompt = "\(portal)指示牌\(direction(arrow))。请沿现场指引寻找门口，再核对眼前通道。"; return
                }
                stage = .doorway; approachedPortal = true; action = .crossed
                prompt = "读到\(portal)标识。请核对眼前的门和通道，通过后站定，再环顾寻找门牌或目录。"; return
            }
            if let door {
                stage = .doorway; approachedPortal = true; action = .crossed
                if sign.scene.geometricDoor {
                    prompt = "画面\(door)有疑似门形轮廓，边框延伸到地面。请核对门口和通道，通过后再扫周围。"; return
                }
                prompt = "\(sign.scene.setting == .room ? "画面像在室内。" : "")\(door == "画面中" ? door : "画面" + door)有疑似门。请核对门的位置与通行情况，通过后再扫周围。"; return
            }
            if let setting = sign.scene.setting {
                prompt = setting == .outside ? "画面像在室外。请站定转动镜头，寻找主入口或入口处的导览牌。" : "画面像在室内。请站定转动镜头，寻找通往公共区域的门或导向标识。"; return
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
        case .survey, .doorway: return "请站定，慢慢转动手机寻找入口或门。如果已在公共区域，可以直接扫门牌或目录。"
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
            prompt = "请核对\(transferFacility ?? "换层设施")，前往\(site: site)。离开后站定，扫描楼层牌。"
        case .atDestination:
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
    mutating func enteredPublicArea() {
        guard stage == .survey || stage == .doorway else { return }
        outsideRoom = true; action = nil; stage = .orient; log("已进入公共区域")
        prompt = "请站定环顾四周，先扫刚经过的门牌，再找走廊方向牌或楼层目录。"
    }
    mutating func relocalize() {
        guard stage != .arrived else { return }
        choices = []; resolvedName = nil; chosenSite = nil
        stage = .orient; currentLevel = nil; site = RouteSite(); latestRoom = nil; transferFacility = nil; action = nil
        log("重新定位"); prompt = "请站定，重新扫描当前位置牌，再扫附近的目录。"
    }
    mutating func expireConfirmation() {
        let hadPrompt = action != nil || !choices.isEmpty
        choices = []
        action = nil
        if stage == .verify { stage = .corridor }
        if hadPrompt { prompt = recovery }
    }
    private mutating func log(_ entry: String) { if history.last != entry { history = Array((history + [entry]).suffix(12)) } }
}

/// Vote on structured route evidence, not the quick reader's verdict: two directories
/// can both mention the target while pointing to different floors or opposite arrows.
struct RouteEvidenceGate {
    private var candidate: WayfindingSigns?
    private var lastTime: TimeInterval = -.infinity
    private var delivered: WayfindingSigns?
    private var lastUseful: TimeInterval
    init(now: TimeInterval) { lastUseful = now }
    mutating func accept(_ signs: WayfindingSigns, at now: TimeInterval) -> Bool {
        guard now > lastTime else { return false }
        let repeated = candidate == signs && (0.1...3.5).contains(now - lastTime)
        candidate = signs
        lastTime = now
        if repeated, signs != WayfindingSigns() {
            lastUseful = now
            guard delivered != signs else { return false }
            delivered = signs
            return true
        }
        // An empty reading can request a rescan. A changing sequence of plausible
        // but conflicting signs must never be delivered as a navigational fact.
        guard signs == WayfindingSigns(), now - lastUseful >= 5, delivered != signs else { return false }
        delivered = signs
        return true
    }
}
