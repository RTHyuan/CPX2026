import Foundation
import CoreFoundation

enum DemoGuideAction: String, Codable { case look, turn_left, turn_right, forward, stop }

/// A short model-authored description and intent. A forward intent still needs a local step permit.
struct DemoGuideReply: Codable {
    let frame_id: FrameID
    let scene_zh: String
    let speech_zh: String
    let action: DemoGuideAction
    let target_kind: FeatureKind?
    let target_box: ImageBox?

    private enum CodingKeys: String, CodingKey { case frame_id, scene_zh, speech_zh, action, target_kind, target_box }

    static func parse(_ data: Data, for expected: FrameID, language: GuidanceLanguage = .chinese) throws -> Self {
        let keys: Set<String> = ["frame_id", "scene_zh", "speech_zh", "action", "target_kind", "target_box"]
        guard data.count <= 4_096,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == keys,
              let stamp = raw["frame_id"] as? [String: Any], Set(stamp.keys) == ["session", "world", "frame"],
              DemoGuideWire.integer(stamp["world"]), DemoGuideWire.integer(stamp["frame"]),
              (raw["target_kind"] is NSNull) == (raw["target_box"] is NSNull) else { throw SpatialError.invalid }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard reply.frame_id == expected,
              DemoGuideWire.text(reply.scene_zh, limit: language == .chinese ? 32 : 120),
              DemoGuideWire.text(reply.speech_zh, limit: language == .chinese ? 24 : 90) else { throw SpatialError.invalid }
        switch language {
        case .chinese:
            guard !DemoGuideWire.sceneCommandsMovement(reply.scene_zh),
                  DemoGuideWire.speech(reply.speech_zh, for: reply.action) else { throw SpatialError.invalid }
        case .english:
            guard DemoGuideWire.english(reply.scene_zh), DemoGuideWire.english(reply.speech_zh),
                  !DemoGuideWire.englishSceneCommandsMovement(reply.scene_zh),
                  DemoGuideWire.englishSpeech(reply.speech_zh, for: reply.action) else { throw SpatialError.invalid }
        }
        if let kind = reply.target_kind {
            guard [.door, .aisle_entrance, .sign, .junction].contains(kind), reply.target_box?.valid == true else { throw SpatialError.invalid }
        } else if reply.target_box != nil { throw SpatialError.invalid }
        if reply.action == .forward {
            guard let kind = reply.target_kind, [.door, .aisle_entrance, .junction].contains(kind) else { throw SpatialError.invalid }
        }
        return reply
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frame_id, forKey: .frame_id)
        try c.encode(scene_zh, forKey: .scene_zh)
        try c.encode(speech_zh, forKey: .speech_zh)
        try c.encode(action, forKey: .action)
        // Both keys are required even when the model only describes the view.
        try c.encode(target_kind, forKey: .target_kind)
        try c.encode(target_box, forKey: .target_box)
    }
}

private enum DemoGuideWire {
    static func integer(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) else { return false }
        return n.int64Value >= 0
    }

    static func text(_ value: String, limit: Int) -> Bool {
        value.count <= limit && value.unicodeScalars.contains { !$0.properties.isWhitespace } && value.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }

    private static func has(_ text: String, _ fragments: [String]) -> Bool { fragments.contains { text.contains($0) } }
    private static func matches(_ text: String, _ expression: String) -> Bool { text.range(of: expression, options: .regularExpression) != nil }

    // A scene can describe a sign's direction ("左转有厕所"). Walking instructions belong only in speech.
    static func sceneCommandsMovement(_ text: String) -> Bool {
        let text = text.filter { !$0.isWhitespace }
        return has(text, ["向前走", "往前走", "向前迈", "往前迈", "前进一步", "前进一小步", "向前一步", "往前一步", "向前一小步", "往前一小步"])
            || matches(text, "(?:走|迈|前进|前行)(?:一小步|一步)")
            || matches(text, "(?:请|先|继续|直接|马上|现在|应当|需要|必须|务必)(?:你)?(?:向|往|朝)?(?:左|右|前)?(?:转|走|直行|行走|移动|挪|上楼|下楼|进门|出门)")
    }

    private static func hasForwardInstruction(_ text: String) -> Bool {
        has(text, ["向前走", "往前走", "向前行", "往前行", "向前挪", "往前挪", "向前移动", "往前移动", "前进", "前行", "迈", "踏", "一步", "一小步", "直行", "走向", "走到", "走过去", "继续走", "往前一步", "向前一步", "靠近", "行进"])
            || matches(text, "走(?!廊|道)|(?:向|往|朝)(?:着)?前(?:方)?(?:慢慢|慢|小|轻轻|直)?(?:走|行|移|挪|迈|踏)")
    }

    static func speech(_ text: String, for action: DemoGuideAction) -> Bool {
        let text = text.filter { !$0.isWhitespace }
        // No reply may combine an inspected short step with an unbounded, vertical or destination action.
        guard !has(text, ["一直", "不停", "连续", "持续", "直到", "走到", "多步", "数步", "几步", "一步一步", "再走", "接着走", "然后走",
                          "跑", "跳", "跨", "攀", "爬", "后退", "倒退", "上楼", "下楼", "上台阶", "下台阶", "上下楼", "沿楼梯",
                          "已到", "到了", "到达", "抵达", "已经到", "穿过", "穿门", "开门", "进入", "进门", "出门"]),
              !matches(text, "(?:[零〇二两三四五六七八九十百千万几多0-9]+[零〇一二两三四五六七八九十百千万]*|一[十百千万][零〇一二两三四五六七八九十百千万]*)(?:小)?步|[0-9零〇一二两三四五六七八九十百千万]+(?:米|公尺|厘米)"),
              !matches(text, "(?:继续|再|接着|然后|接下来)(?:向前|往前|前进|前行|走|迈)") else { return false }
        guard action == .forward else { return !hasForwardInstruction(text) }
        let counted = text.replacingOccurrences(of: "一小步", with: "一步")
        let parts = counted.components(separatedBy: "一步")
        guard parts.count == 2, !hasForwardInstruction(parts[1]),
              has(text, ["走", "迈", "前进", "前行", "向前", "往前"]),
              !has(text, ["转", "退", "原地", "横向", "不要", "不用", "不必", "无需", "别", "到门口", "到入口", "到终点"]),
              !matches(text, "(?:向|往|朝)(?:后|左|右)(?:走|行|移|挪)|(?:侧|横)(?:着|身)?(?:走|挪|移|迈)") else { return false }
        return true
    }

    // The wire keys stay unchanged; only their contents and validation follow the selected language.
    static func english(_ text: String) -> Bool {
        !matches(text, "\\p{Han}") && matches(text, "[A-Za-z]")
    }

    private static func englishText(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func englishSceneCommandsMovement(_ text: String) -> Bool {
        var text = englishText(text)
        // An attributed quotation is a fact about a sign, not an instruction from the app.
        // Remove only that quotation, so a later "Please walk forward" is still inspected.
        text = text.replacingOccurrences(
            of: "\\b(?:the |a )?(?:sign|arrow|notice|board|signage)\\s+(?:says?|reads?|indicates?|shows?)\\s*[:, -]?\\s*(?:[\"“][^\"”]*[\"”]|['‘][^'’]*['’])",
            with: "route fact", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\b(?:sign|arrow|notice|board|signage)\\s+(?:says?|reads?|indicates?|shows?|points?)(?:\\s+that)?(?:\\s+to)?\\s*[:, -]?\\s*(?:turn\\s+(?:left|right)|(?:go|continue|walk)\\s+straight(?:\\s+ahead)?)\\b",
            with: "route fact", options: .regularExpression)
        let verb = "(?:look|turn|walk|step|move|go|take|stop|wait|face|point|aim|tilt|raise|lower|continue|proceed|head|enter|exit|cross|climb|descend|follow|advance|approach)"
        let adverbs = "(?:(?:[a-z]+ly|now|first|next)\\s+)*"
        return matches(text, "(?:^|[.!?;,:]\\s*|\\b(?:and|then)\\s+)(?:please\\s+)?" + adverbs + verb + "\\b")
            || matches(text, "\\b(?:please|must|should|need to|have to|time to|safe to|ready to)\\s+(?:you\\s+)?" + adverbs + verb + "\\b")
            || matches(text, "\\byou\\s+(?:can|could|may|might|will|would|should|must|need to|have to)\\s+" + adverbs + verb + "\\b")
    }

    private static func englishWalking(_ text: String) -> Bool {
        // Camera/head instructions may use "move" without asking the user to walk.
        let body = text.replacingOccurrences(
            of: "\\b(?:move|moving|turn|turning|rotate|rotating|keep|keeping|hold|holding)\\s+(?:(?:only|just)\\s+)?(?:(?:your|the)\\s+)?(?:camera|phone|lens|head|eyes|gaze)\\b",
            with: "camera", options: .regularExpression)
        return matches(body, "\\b(?:walk|walking|move|moving|go|going|proceed|proceeding|advance|advancing|approach|approaching|run|running|jump|jumping|climb|climbing|descend|ascending|enter|entering|cross|crossing|follow|following|retreat|retreating|sidestep|sidestepping|shuffle|shuffling|stride|striding|pace|pacing)\\b")
            || matches(body, "\\b(?:take|taking)\\s+(?:(?:one|a|another|small|single|more|two|three|four|five|several|multiple)\\s+|[0-9]+\\s+)*steps?\\b")
            || matches(body, "\\b(?:step|stepping|head|heading)(?:\\s+(?:[a-z]+ly|straight|a little|a bit)){0,3}\\s+(?:forward|forwards|ahead|towards?|back|backwards?|left|right|sideways|up|down)\\b")
            || matches(body, "\\b(?:back|backing)\\s+(?:up|away)\\b|(?:^|[.!?;,:]\\s*|\\b(?:and|then|next|please)\\s+)(?:exit|leave)\\b")
    }

    static func englishSpeech(_ value: String, for action: DemoGuideAction) -> Bool {
        let text = englishText(value)
        guard !matches(text, "\\b(?:keep(?: on)?|continue|carry on)\\s+(?:walking|moving|going|stepping|forward|forwards|ahead)\\b|\\b(?:until|without stopping|all the way|nonstop|non-stop|repeatedly)\\b"),
              !matches(text, "\\b(?:run|running|jump|jumping|hop|hopping|leap|climb|climbing|ascend|ascending|descend|descending|crawl)\\b"),
              !matches(text, "\\b(?:arrived|reached|you(?:'re| are) there|at (?:your|the) destination|arrive|reach|enter|entering)\\b"),
              !matches(text, "\\b(?:go|walk|step|move|head|take)(?:\\s+\\w+){0,3}\\s+(?:upstairs|downstairs|up the stairs|down the stairs)\\b"),
              !matches(text, "\\b(?:walk|go|move|pass|step)\\s+(?:through|across|inside|outside)\\b|\\b(?:open|close)\\s+(?:the|that|a)\\s+door\\b"),
              !matches(text, "\\b(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|several|multiple|many|few|couple|dozen)(?:\\s+(?:more|small))?\\s+steps?\\b|\\b(?:[0-9]+(?:\\.[0-9]+)?|one|two|three|four|five|six|seven|eight|nine|ten)\\s*(?:metres?|meters?|feet|foot|centimetres?|centimeters?|cm|m)\\b") else { return false }
        guard action == .forward else {
            if action == .stop {
                // Only the explicit prohibition is removed. A later movement still fails.
                let stationary = text.replacingOccurrences(
                    of: "\\b(?:stop\\s+(?:walking|moving|stepping)|(?:do not|don't)\\s+(?:walk|move|step))\\b",
                    with: "halt", options: .regularExpression)
                return !englishWalking(stationary)
            }
            return !englishWalking(text)
        }

        let count = "\\bone(?: small)? step\\b"
        guard let expression = try? NSRegularExpression(pattern: count),
              expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1,
              let step = text.range(of: count, options: .regularExpression) else { return false }
        let before = String(text[..<step.lowerBound]), after = String(text[step.upperBound...])
        // The quantity alone ("One step forward is clear") is not a movement instruction.
        guard matches(before, "\\b(?:take|move|walk|step)\\b"),
              matches(text, "\\b(?:forward|forwards|ahead|towards?)\\b"),
              !englishWalking(after),
              !matches(text, "\\b(?:steps|twice|thrice|again|another|repeat|repeating|backwards?|back|backing|sideways|sidewards?|leftwards?|rightwards?|sidestep|stairs?|staircase|upstairs|downstairs|through|across|inside|outside|turn|rotate|continue|carry on|keep on)\\b"),
              !matches(text, "\\b(?:at a time|in succession|one by one)\\b"),
              !matches(text, "\\b(?:one(?: small)? step|(?:walk|move|step))(?:\\s+[a-z]+ly){0,2}\\s+(?:away(?:\\s+from)?|to\\s+(?:(?:the|your|one)\\s+)?side)\\b"),
              !matches(text, "\\b(?:one(?: small)? step|(?:walk|move|step)(?:\\s+[a-z]+ly){0,2})\\s+(?:(?:to|towards?|in)\\s+(?:(?:your|the)\\s+)?)?(?:left|right)\\b(?!\\s+(?:door|doorway|passage|entrance|opening|aisle|corridor|hall)\\b)"),
              !matches(after, "\\b(?:two|three|four|five|six|seven|eight|nine|ten|[0-9]+)\\s+more\\b"),
              !matches(text, "\\b(?:not|don't|cannot|can't|never|avoid|without|unless|if|no need|needn't|shouldn't|wouldn't)\\b"),
              !matches(text, "\\b(?:sign|notice|board)\\s+(?:says|reads|indicates)\\b|\\b(?:room|space|clearance)\\s+(?:for|to)\\b") else { return false }
        // A second movement before the counted step also invalidates the single-step intent.
        guard let commands = try? NSRegularExpression(pattern: "\\b(?:take|move|walk|step|go|proceed|advance|approach)\\b") else { return false }
        return commands.numberOfMatches(in: before, range: NSRange(before.startIndex..., in: before)) == 1
    }
}
