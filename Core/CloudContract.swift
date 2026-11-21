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

enum PlannerAction: String, Codable { case rescan, target_waypoint, wait, verify_destination }
struct ModelItem: Codable {
    let ref: String, kind: FeatureKind, box: ImageBox
    var sign: SignMeaning? = nil

    private enum CodingKeys: String, CodingKey { case ref, kind, box, sign }
}

extension ModelItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FeatureKind.self, forKey: .kind)
        try CloudWire.checkKeys(decoder, required: ["ref", "kind", "box"], optional: kind == .sign ? ["sign"] : [])
        ref = try c.decode(String.self, forKey: .ref)
        box = try c.decode(ImageBox.self, forKey: .box)
        guard CloudWire.validRef(ref), box.valid else { throw SpatialError.invalid }
        if c.contains(.sign), try !c.decodeNil(forKey: .sign) {
            let nested = try c.superDecoder(forKey: .sign)
            try CloudWire.checkKeys(nested, required: ["symbol"], optional: ["text", "arrow"])
            let meaning = try SignMeaning(from: nested)
            guard CloudWire.validSign(meaning) else { throw SpatialError.invalid }
            sign = meaning
        }
    }
}
struct PlannerReply: Codable {
    let frame_id: FrameID, observations, hazards: [ModelItem], action: PlannerAction, target_ref: String?, speech_zh: String, uncertain: Bool
    static func parse(_ data: Data, for expected: FrameID) throws -> Self {
        guard data.count <= 24_576, let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(obj.keys) == ["frame_id","observations","hazards","action","target_ref","speech_zh","uncertain"],
              let stamp = obj["frame_id"] as? [String: Any], Set(stamp.keys) == ["session", "world", "frame"],
              CloudWire.frameCounter(stamp["world"]), CloudWire.frameCounter(stamp["frame"]) else { throw SpatialError.invalid }
        let reply = try JSONDecoder().decode(Self.self,from:data), items=reply.observations+reply.hazards
        guard reply.frame_id == expected, items.count <= 24, Set(items.map(\.ref)).count == items.count,
              CloudWire.validText(reply.speech_zh, limit: 64),
              reply.hazards.allSatisfy({ $0.kind.mobile || $0.kind == .steps }),
              !reply.uncertain || [.wait,.rescan].contains(reply.action) else { throw SpatialError.invalid }
        if [.target_waypoint,.verify_destination].contains(reply.action) {
            guard let ref=reply.target_ref, reply.observations.contains(where:{$0.ref == ref && $0.kind.waypoint}) else {throw SpatialError.invalid}
        } else if reply.target_ref != nil { throw SpatialError.invalid }
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
    init(_ r:Landmark) {
        id=r.id;kind=r.kind;last_seen=r.last.time;position_seen_from=r.last.position;heading_seen_from=r.last.heading;box=r.box;confidence=r.confidence;point=r.point;label=r.label
        sign = r.kind == .sign ? r.sign.flatMap { CloudWire.validSign($0) ? $0 : nil } : nil
    }
}
struct CloudContext: Encodable {
    let utterance, destination, stage, trigger:String
    let capture, request:PosePacket, history:[PosePacket]
    let image_width,image_height:Int
    let image_transform="full native sensor → EXIF upright → uniform resize; no crop; normalized top-left boxes"
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
