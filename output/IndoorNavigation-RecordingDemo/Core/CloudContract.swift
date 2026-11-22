import Foundation
import CoreFoundation

private enum CloudWire {
    // A typed CodingKey container alone silently ignores unrecognized keys.
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func checkKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw SpatialError.invalid }
    }

    static func validText(_ value: String, limit: Int) -> Bool {
        let scalars = value.unicodeScalars
        return scalars.count <= limit && scalars.contains { !$0.properties.isWhitespace } && scalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }

    static func validSign(_ meaning: SignMeaning) -> Bool {
        guard let label = meaning.text else { return meaning.symbol != .unknown }
        let hasLegend = label.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
        return hasLegend && validText(label, limit: 48) && !SignArrow.allCases.contains { label.contains($0.rawValue) }
    }

    static func validRef(_ ref: String) -> Bool {
        let bytes = ref.utf8
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
        guard let first = bytes.first, bytes.count <= 24, letter(first) else { return false }
        return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 95 }
    }

    static func frameCounter(_ value: Any?) -> Bool {
        // JSONDecoder also accepts integral doubles. The wire requires JSON integers.
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) else { return false }
        return n.int64Value >= 0
    }
}

// Version 2 is a semantic proposal. Only the local executor may issue a motion permit.
enum PlannerScene: String, Codable { case unknown, room, publicCorridor = "public_corridor", doorway, other }
enum PlannerCompletion: String, Codable {
    case sceneObserved = "scene_observed", exitIdentified = "exit_identified", aisleReached = "aisle_reached"
    case doorReached = "door_reached", crossingVerified = "crossing_verified", signIdentified = "sign_identified"
    case entranceReached = "entrance_reached", destinationVerified = "destination_verified"
}
enum PlannerTask: String, Codable {
    case observe, findExit = "find_exit", approachAisle = "approach_aisle", approachExit = "approach_exit"
    case verifyCrossing = "verify_crossing", findSigns = "find_signs", approachDestination = "approach_destination", verifyDestination = "verify_destination"
    var completion: PlannerCompletion {
        switch self {
        case .observe: return .sceneObserved
        case .findExit: return .exitIdentified
        case .approachAisle: return .aisleReached
        case .approachExit: return .doorReached
        case .verifyCrossing: return .crossingVerified
        case .findSigns: return .signIdentified
        case .approachDestination: return .entranceReached
        case .verifyDestination: return .destinationVerified
        }
    }
    var exitTask: Bool { [.findExit, .approachAisle, .approachExit, .verifyCrossing].contains(self) }
    func accepts(_ kind: FeatureKind?) -> Bool {
        guard let kind else { return true } // wait/rescan describes the unfinished task without a target
        switch self {
        case .observe: return false
        case .approachAisle: return kind == .aisle_entrance
        case .approachExit, .verifyCrossing: return kind == .door
        case .findExit: return [.door, .aisle_entrance, .sign].contains(kind)
        case .findSigns: return [.sign, .junction, .aisle_entrance].contains(kind)
        case .approachDestination: return kind.waypoint
        case .verifyDestination: return kind == .door || kind == .sign
        }
    }
}
struct SceneLayoutEvidence: Codable, Equatable {
    enum Kind: String, Codable { case room = "room_layout", corridor = "corridor_layout", threshold, other }
    let kind: Kind, source_frame: FrameID, box: ImageBox
}
struct PlannerDirective: Codable, Equatable {
    let scene: PlannerScene, scene_uncertain: Bool, task: PlannerTask, reason: String, completion: PlannerCompletion
    var layout: SceneLayoutEvidence? = nil
    var valid: Bool {
        completion == task.completion && CloudWire.validText(reason, limit: 128)
            && (scene != .unknown || scene_uncertain)
            && (scene != .publicCorridor || scene_uncertain || !task.exitTask || task == .verifyCrossing)
    }
}
struct PlanningSnapshot: Encodable {
    let scene: PlannerScene, task: PlannerTask, version: Int, requires_exit: Bool
    init(_ journey: WayfindingJourney) {
        scene = journey.plannerScene; task = journey.plannerTask; version = journey.taskVersion; requires_exit = journey.requiresExit
    }
}
enum PlannerAction: String, Codable { case rescan, target_waypoint, wait, verify_destination }
struct ModelItem: Codable {
    let ref: String, kind: FeatureKind, box: ImageBox
    var sign: SignMeaning? = nil
    var source_frame: FrameID? = nil

    private enum CodingKeys: String, CodingKey { case ref, kind, box, sign, source_frame }
}

extension ModelItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FeatureKind.self, forKey: .kind)
        try CloudWire.checkKeys(decoder, required: ["ref", "kind", "box"], optional: kind == .sign ? ["sign", "source_frame"] : ["source_frame"])
        source_frame = try c.decodeIfPresent(FrameID.self, forKey: .source_frame)
        ref = try c.decode(String.self, forKey: .ref)
        box = try c.decode(ImageBox.self, forKey: .box)
        guard CloudWire.validRef(ref), box.valid else { throw SpatialError.invalid }
        if c.contains(.sign), try !c.decodeNil(forKey: .sign) {
            let nested = try c.superDecoder(forKey: .sign)
            try CloudWire.checkKeys(nested, required: ["symbol"], optional: ["text", "arrow"])
            let meaning = try SignMeaning(from: nested)
            if CloudWire.validSign(meaning) {
                sign = meaning
            } else {
                let keys = Set(try nested.container(keyedBy: CloudWire.Key.self).allKeys.map(\.stringValue))
                // A standalone arrow has no identified destination. Retain its detection,
                // without attaching its direction to another sign or losing the valid plan.
                let standaloneArrow = keys == ["symbol", "arrow"] && meaning.symbol == .unknown
                    && meaning.text == nil && meaning.arrow != nil
                // Some replies mix a panel's arrow into its label. Isolate that semantic
                // record; guessing a row association could point at the wrong facility.
                var embeddedArrow = false
                if let label = meaning.text, CloudWire.validText(label, limit: 48),
                   SignArrow.allCases.contains(where: { label.contains($0.rawValue) }) {
                    let legend = SignArrow.allCases.reduce(label) { $0.replacingOccurrences(of: $1.rawValue, with: "") }
                    embeddedArrow = CloudWire.validSign(.init(symbol: meaning.symbol, text: legend, arrow: meaning.arrow))
                }
                guard standaloneArrow || embeddedArrow else { throw SpatialError.invalid }
                sign = nil
            }
        }
    }
}
struct PlannerReply: Codable {
    let frame_id: FrameID, observations, hazards: [ModelItem], action: PlannerAction, target_ref: String?
    var speech_zh: String
    let uncertain: Bool
    var plan: PlannerDirective? = nil
    /// nil requires the v1 shape. A v2 caller must supply the exact frames attached to this request.
    static func parse(_ data: Data, for expected: FrameID, sources: Set<FrameID>? = nil) throws -> Self {
        var keys: Set<String> = ["frame_id","observations","hazards","action","target_ref","speech_zh","uncertain"]
        if sources != nil { keys.insert("plan") }
        func validStamp(_ raw: Any?) -> Bool {
            guard let stamp = raw as? [String:Any], Set(stamp.keys) == ["session", "world", "frame"] else { return false }
            return CloudWire.frameCounter(stamp["world"]) && CloudWire.frameCounter(stamp["frame"])
        }
        guard data.count <= 24_576, let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(obj.keys) == keys, validStamp(obj["frame_id"]),
              let observations = obj["observations"] as? [[String:Any]], let hazards = obj["hazards"] as? [[String:Any]],
              (observations + hazards).allSatisfy({ sources == nil ? $0["source_frame"] == nil : validStamp($0["source_frame"]) })
        else { throw SpatialError.invalid }
        var reply = try JSONDecoder().decode(Self.self,from:data)
        let items = reply.observations+reply.hazards
        guard reply.frame_id == expected, items.count <= 24, Set(items.map(\.ref)).count == items.count,
              CloudWire.validText(reply.speech_zh, limit: 64),
              reply.hazards.allSatisfy({ $0.kind.mobile || $0.kind == .steps }),
              !reply.uncertain || [.wait,.rescan].contains(reply.action) else { throw SpatialError.invalid }
        if [.target_waypoint,.verify_destination].contains(reply.action) {
            guard let ref=reply.target_ref, reply.observations.contains(where:{$0.ref == ref && $0.kind.waypoint}) else {throw SpatialError.invalid}
        } else if reply.target_ref != nil { throw SpatialError.invalid }
        // Recognition is useful even when the model paraphrases an observation prompt.
        // The executor never plays arbitrary model movement/arrival instructions.
        if !reply.hasObservationSpeech { reply.speech_zh = reply.defaultObservationSpeech }
        if let sources {
            let kind = reply.observations.first(where: { $0.ref == reply.target_ref })?.kind
            guard sources.contains(expected), sources.count <= 3, sources.allSatisfy({ $0.sameWorld(expected) && $0.frame <= expected.frame }),
                  let raw = obj["plan"] as? [String:Any], Set(raw.keys).subtracting(["layout"]) == ["scene", "scene_uncertain", "task", "reason", "completion"],
                  let plan = reply.plan, plan.valid, plan.task.accepts(kind),
                  (reply.action != .verify_destination || plan.task == .verifyDestination), reply.hasObservationSpeech,
                  items.allSatisfy({ $0.source_frame.map(sources.contains) == true }),
                  reply.hazards.allSatisfy({ $0.source_frame == expected }) else { throw SpatialError.invalid }
            if raw["layout"] != nil {
                guard let evidence = raw["layout"] as? [String:Any], Set(evidence.keys) == ["kind", "source_frame", "box"],
                      validStamp(evidence["source_frame"]), let layout = plan.layout, sources.contains(layout.source_frame) else { throw SpatialError.invalid }
            } else if plan.scene == .publicCorridor, !plan.scene_uncertain {
                // A separately boxed passage in this exposure can supply the omitted
                // layout field. A sign box or an old view cannot establish this scene.
                let passages = reply.observations.filter {
                    $0.source_frame == expected && [.junction, .aisle_entrance].contains($0.kind)
                }
                if passages.count == 1, let passage = passages.first {
                    reply.plan?.layout = .init(kind: .corridor, source_frame: expected, box: passage.box)
                }
            }
            guard let normalized = reply.plan,
                  normalized.scene != .room || normalized.scene_uncertain || reply.containsRoomContext,
                  normalized.scene != .publicCorridor || normalized.scene_uncertain || normalized.layout?.kind == .corridor else { throw SpatialError.invalid }
        }
        return reply
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frame_id, forKey: .frame_id)
        try c.encode(observations, forKey: .observations)
        try c.encode(hazards, forKey: .hazards)
        try c.encode(action, forKey: .action)
        try c.encode(target_ref, forKey: .target_ref) // Required key, including for wait/rescan.
        try c.encode(speech_zh, forKey: .speech_zh)
        try c.encode(uncertain, forKey: .uncertain)
        try c.encodeIfPresent(plan, forKey: .plan)
    }
    /// A room plate (even on a door) is equally visible from a public corridor. Request
    /// another view unless the reply also reports an independent layout cue.
    private var containsRoomContext: Bool {
        let kinds = Set((observations + hazards).map(\.kind))
        return plan?.layout?.kind == .room || !kinds.isDisjoint(with: [.chair, .stool]) && !kinds.isDisjoint(with: [.door, .aisle_entrance, .sign])
    }
    private var hasObservationSpeech: Bool {
        if action != .target_waypoint { return stationarySpeech != nil }
        return ["请观察选定目标。", "可以慢慢转动手机，看看周围。", "先转向左侧过道。", "先转向右侧过道。",
                "请转向左侧门口。", "请转向右侧门口。", "先朝左侧转动手机。", "先朝右侧转动手机。"].contains(speech_zh)
    }
    private var defaultObservationSpeech: String {
        switch action {
        case .wait: return "可以慢慢转动手机，看看周围。"
        case .rescan: return "请慢慢转动手机，补扫周围。"
        case .target_waypoint: return "请观察选定目标。"
        case .verify_destination: return "转动手机，看看目的地的标识。"
        }
    }
    /// Only observation prompts may bypass the geometry renderer. Stop cues belong to the phone.
    var stationarySpeech: String? {
        let permitted: [PlannerAction: Set<String>] = [
            .wait: ["可以慢慢转动手机，看看周围。"],
            .rescan: ["请慢慢转动手机，补扫周围。"],
            .verify_destination: ["转动手机，看看目的地的标识。"]
        ]
        return permitted[action]?.contains(speech_zh) == true ? speech_zh : nil
    }
    func turnSpeech(error:Double) -> String? {
        guard !uncertain, action == .target_waypoint, abs(error)>8 else {return nil}
        let side=error<0 ? "左":"右"
        return ["先转向\(side)侧过道。","请转向\(side)侧门口。","先朝\(side)侧转动手机。"].contains(speech_zh) ? speech_zh:nil
    }
}
struct PosePacket: Encodable {
    let sample: FramePose, position: V3, heading: Double
    init(_ pose:FramePose) { sample=pose; position=pose.position; heading=pose.heading }
}
struct CloudAnchor: Encodable {
    let id:Int, kind:FeatureKind, last_seen:Double, position_seen_from:V3, heading_seen_from:Double, box:ImageBox, confidence:Double, point:V3?, label:String?
    let sign: SignMeaning?
    let frame_id: FrameID
    init(_ r:Landmark) {
        frame_id = r.last.id
        id=r.id;kind=r.kind;last_seen=r.last.time;position_seen_from=r.last.position;heading_seen_from=r.last.heading;box=r.box;confidence=r.confidence;point=r.point;label=r.label
        sign = r.kind == .sign ? r.sign.flatMap { CloudWire.validSign($0) ? $0 : nil } : nil
    }
}
struct CloudContext: Encodable {
    let utterance, destination, stage, trigger:String
    let capture, request:PosePacket, history:[PosePacket]
    let image_width,image_height:Int
    let image_transform="native sensor → EXIF upright; full frame, no crop; normalized top-left boxes"
    let features:[Sighting], scanned_bins:[Int], known:[CloudAnchor], recent_hazards:[CloudAnchor]
    let last_instruction:String, turned_since_instruction,moved_since_instruction:Double
    let sign_history:[String]
}
/// Single in flight; while busy the latest selection replaces the previous pending one.
struct LatestOnly<Value> {
    private(set) var busy=false
    private(set) var pending:Value?
    mutating func offer(_ value:Value) -> Value? { if busy { pending=value; return nil }; busy=true; return value }
    mutating func finish() -> Value? { if let pending { self.pending=nil; return pending }; busy=false; return nil }
}
