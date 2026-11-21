import Foundation

enum PlannerAction: String, Codable { case rescan, target_waypoint, wait, verify_destination }
struct ModelItem: Codable {
    let ref: String, kind: FeatureKind, box: ImageBox
}
struct PlannerReply: Codable {
    let frame_id: FrameID, observations, hazards: [ModelItem], action: PlannerAction, target_ref: String?, speech_zh: String, uncertain: Bool
    static func parse(_ data: Data, for expected: FrameID) throws -> Self {
        guard data.count <= 24_576, let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(obj.keys) == ["frame_id","observations","hazards","action","target_ref","speech_zh","uncertain"] else { throw SpatialError.invalid }
        let reply = try JSONDecoder().decode(Self.self,from:data), items=reply.observations+reply.hazards
        guard reply.frame_id == expected, items.count <= 24, Set(items.map(\.ref)).count == items.count,
              items.allSatisfy({ $0.ref.range(of:#"^[A-Za-z][A-Za-z0-9_]{0,23}$"#,options:.regularExpression) != nil && $0.box.valid }),
              !reply.speech_zh.isEmpty, reply.speech_zh.count <= 64,
              reply.hazards.allSatisfy({ $0.kind.mobile || $0.kind == .steps }),
              !reply.uncertain || [.wait,.rescan].contains(reply.action) else { throw SpatialError.invalid }
        if [.target_waypoint,.verify_destination].contains(reply.action) {
            guard let ref=reply.target_ref, reply.observations.contains(where:{$0.ref == ref && $0.kind.waypoint}) else {throw SpatialError.invalid}
        } else if reply.target_ref != nil { throw SpatialError.invalid }
        return reply
    }
    /// Only allow a semantic, stationary action to bypass the geometry renderer. Movement text is always rebound to live geometry.
    var stationarySpeech: String? {
        let permitted: [PlannerAction:Set<String>] = [.wait:["请先站定。","先停一下。","请站定等待。"],.rescan:["请站定，慢慢补扫四周。","请站定，重新查看门框。"],.verify_destination:["请站定，核对眼前的门牌。","请站定，核对眼前的门框。"]]
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
    init(_ r:Landmark) { id=r.id;kind=r.kind;last_seen=r.last.time;position_seen_from=r.last.position;heading_seen_from=r.last.heading;box=r.box;confidence=r.confidence;point=r.point;label=r.label }
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
