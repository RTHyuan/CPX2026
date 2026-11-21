import Foundation
import CoreGraphics

struct SignLine: Equatable {
    let text: String
    let confidence: Float
    let bounds: CGRect

    init(_ text: String, confidence: Float = 1, bounds: CGRect = .zero) {
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
    }
}

struct FrameResult: Equatable {
    let lines: [SignLine]
    let reading: SignReading
    var scene = SceneClues()
}

enum Facility: String, CaseIterable {
    case lift = "电梯", exit = "出口", stairs = "楼梯", restroom = "洗手间"

    var aliases: [String] {
        switch self {
        case .lift: return ["电梯", "電梯", "LIFT", "ELEVATOR"]
        case .exit: return ["出口", "安全出口", "EXIT"]
        case .stairs: return ["楼梯", "樓梯", "STAIRS", "STAIRCASE"]
        case .restroom: return ["洗手间", "卫生间", "洗手間", "衛生間", "RESTROOM", "TOILET", "WC"]
        }
    }
}

enum Destination: Equatable {
    case room(String), facility(Facility), named(String)

    init?(_ input: String) {
        var value = SignParser.normalize(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 100 else { return nil }
        value = value.replacingOccurrences(of: #"[。.!！?？]+$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^(?:请帮我找|請幫我找|帮我找|幫我找|我想找|我要找|我想去|我要去|请找|請找|寻找|尋找|找|去|(?:FIND|LOOK FOR)\s+)\s*"#, with: "", options: .regularExpression)
        if let facility = Facility.allCases.first(where: { $0.aliases.contains(value) }) {
            self = .facility(facility)
        } else if let id = Self.roomID(fromEntry: value) {
            self = .room(id)
        } else { return nil }
    }

    /// Only user entry accepts spoken number forms. Printed identifiers keep their exact spelling.
    private static func roomID(fromEntry text: String) -> String? {
        let prefixes = #"^(?:(?:ROOM|CLASSROOM|RM\.?)\s+|(?:房间号|房間號|房号|房號|房间|房間|教室)\s*)"#
        let suffixes = #"\s*(?:[号號]?(?:教室|房间|房間|室)|[号號])$"#
        let value = text.replacingOccurrences(of: prefixes, with: "", options: .regularExpression)
            .replacingOccurrences(of: suffixes, with: "", options: .regularExpression)
        let digitNames = Array("零一二三四五六七八九")
        let normalized = value.replacingOccurrences(of: "〇", with: "零").replacingOccurrences(of: "幺", with: "一")
            .replacingOccurrences(of: "两", with: "二").replacingOccurrences(of: "兩", with: "二").replacingOccurrences(of: "萬", with: "万")
        var id = normalized
        if let span = normalized.range(of: #"[零一二三四五六七八九十百千万]+"#, options: .regularExpression), normalized[span].contains(where: { "十百千万".contains($0) }) {
            let words = String(normalized[span])
            guard normalized[..<span.lowerBound].allSatisfy({ $0.isASCII && $0.isUppercase }),
                  normalized[span.upperBound...].allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
            let format = NumberFormatter()
            format.locale = Locale(identifier: "zh_CN")
            format.numberStyle = .spellOut
            // The round trip rejects truncated or ambiguous phrases such as 三百五.
            guard let number = format.number(from: words), (1...99999).contains(number.intValue),
                  let canonical = format.string(from: number),
                  canonical.replacingOccurrences(of: "两", with: "二").replacingOccurrences(of: "〇", with: "零") == words else { return nil }
            id.replaceSubrange(span, with: number.stringValue)
        } else {
            id = normalized.map { character in digitNames.firstIndex(of: character).map(String.init) ?? String(character) }.joined()
        }
        return SignParser.fullRoom.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) == nil ? nil : id
    }

    var text: String {
        switch self { case .room(let value), .named(let value): return value; case .facility(let item): return item.rawValue }
    }
}

enum SignKind: String { case target, facility, range, directory, mention, restricted, neighbor, unclear }

struct SignReading: Equatable {
    let kind: SignKind
    let evidence: String
    var isMatch: Bool { kind == .target || kind == .facility }
    static let unclear = SignReading(kind: .unclear, evidence: "")

    var title: String {
        switch kind {
        case .target: return "读到目标房号"
        case .facility: return "读到设施标识"
        case .range: return "范围包含目标"
        case .directory: return "目录提到目标"
        case .mention: return "文字提到目标"
        case .restricted: return "读到限制提示"
        case .neighbor: return "读到其他房号"
        case .unclear: return "暂未读清"
        }
    }
    func sentence(for target: Destination) -> String {
        let code = Self.spoken(target.text)
        switch kind {
        case .target: return "标识上读到\(code)，请确认门牌。"
        case .facility: return "标识上读到\(target.text)，请核对现场标识。"
        case .range: return "标识写着\(Self.spoken(evidence))，这个范围包含目标号码。"
        case .directory: return "这张目录提到\(code)，请继续核对独立标识。"
        case .mention: return "文字里出现\(code)，请确认标牌。"
        case .restricted: return "画面里同时读到\(target.text)和限制提示，请核对现场原文。"
        case .neighbor: return "读到\(Self.spoken(evidence))，正在找\(code)。"
        case .unclear: return "暂未读清。请站定，缓慢调整手机角度，或寻求现场协助。"
        }
    }
    static func spoken(_ text: String) -> String {
        let digits = Array("零一二三四五六七八九")
        return text.map { c in
            if let n = c.wholeNumberValue, (0...9).contains(n) { return String(digits[n]) }
            return c == "–" ? "到" : String(c)
        }.joined()
    }
}

/// Layout, not the target number, is the only input to the optional Core ML context classifier.
struct LayoutFeatures {
    let numbers: Int, lines: Int, separators: Int, directoryWords: Int
    var values: [String: Int] { ["numbers": numbers, "lines": lines, "separators": separators, "directoryWords": directoryWords] }
}

struct SignParser {
    private static let token = #"[A-Z]{0,3}[0-9]{1,5}[A-Z]{0,2}"#
    private static let boundaryStart = #"(?<![A-Z0-9])"#, boundaryEnd = #"(?![A-Z0-9])"#
    static let fullRoom = try! NSRegularExpression(pattern: "^" + token + "$")
    private static let rooms = try! NSRegularExpression(pattern: boundaryStart + token + boundaryEnd)
    private static let ranges = try! NSRegularExpression(pattern: boundaryStart + "(" + token + #")\s*(?:[-–—~至到]|\bTO\b)\s*("# + token + ")" + boundaryEnd)
    private static let door = try! NSRegularExpression(pattern: #"^\s*(?:(?:ROOM|RM\.?|CLASSROOM|教室|房间|房間|室)\s*)?("# + token + #")(?:\s*(?:室|教室|房间|房間))?\s*$"#)
    private static let parts = try! NSRegularExpression(pattern: #"^([A-Z]*)([0-9]+)([A-Z]*)$"#)
    private static let rangeGlue = try! NSRegularExpression(pattern: #"(?:[-–—~至到]|\bTO)\s*$|^\s*(?:[-–—~至到]|TO\b)"#)
    private static let directoryWords = ["目录", "索引", "索引图", "平面图", "一览", "導覽", "導引", "DIRECTORY", "INDEX", "DIRECTORIES", "FLOOR PLAN", "ROOM LIST"]
    // A restriction elsewhere on the same sign warrants caution. Its scope can be ambiguous.
    private static let facilityRestriction = try! NSRegularExpression(pattern: #"(?:停用|暂停|暫停|维修|維修|检修|檢修|故障|关闭|關閉|禁止|封闭|封閉|非.{0,3}出口|不得|勿用|施工|\b(?:NO|NOT|CLOSED|RESTRICTED|UNAVAILABLE|OUT OF (?:SERVICE|ORDER)|DO NOT USE|STAFF ONLY)\b)"#)

    private static func namesFacility(_ facility: Facility, in text: String) -> Bool {
        facility.aliases.contains { alias in
            if alias.unicodeScalars.allSatisfy(\.isASCII) {
                return text.range(of: boundaryStart + alias + boundaryEnd, options: .regularExpression) != nil
            }
            return text.contains(alias)
        }
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.uppercased()
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: #"\b(CLASSROOM|ROOM|RM\.?)(?=[0-9])"#, with: "$1 ", options: .regularExpression)
    }
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    static func layout(_ input: [String]) -> LayoutFeatures {
        let text = input.joined(separator: " ")
        let numberSet = Set(matches(rooms, text).map { (text as NSString).substring(with: $0.range) })
        return LayoutFeatures(numbers: numberSet.count, lines: input.count, separators: text.filter { "/|、•".contains($0) }.count, directoryWords: directoryWords.filter(text.contains).count)
    }
    private static func components(_ id: String) -> (String, String, String)? {
        guard let match = matches(parts, id).first else { return nil }
        let ns = id as NSString
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)), ns.substring(with: match.range(at: 3)))
    }
    private static func contains(_ id: String, left: String, right: String) -> Bool {
        guard let t = components(id), let l = components(left), let r = components(right), l.0 == t.0, (r.0.isEmpty || r.0 == l.0), l.2 == t.2, r.2 == t.2,
              let start = Int(l.1), let end = Int(r.1), let number = Int(t.1), start <= end else { return false }
        if [t.1,l.1,r.1].contains(where: { $0.count > 1 && $0.hasPrefix("0") }), !(l.1.count == r.1.count && l.1.count == t.1.count) { return false }
        return (start...end).contains(number)
    }
    static func analyze(_ observations: [SignLine], for target: Destination, suggestsDirectory: ((LayoutFeatures) -> Bool)? = nil) -> SignReading {
        let sorted = observations.filter { $0.confidence >= 0.50 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lines = sorted.map { normalize($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
        let strong = zip(sorted, lines).filter { $0.0.confidence >= 0.65 }.map(\.1)
        let content = lines.joined(separator: " "), strongContent = strong.joined(separator: " ")
        let features = layout(lines)
        switch target {
        case .named(let name):
            let reference = normalize(name).filter { !$0.isWhitespace }
            guard strong.contains(where: { $0.filter { !$0.isWhitespace } == reference }) else { return .unclear }
            return SignReading(kind: features.directoryWords > 0 ? .directory : .mention, evidence: name)
        case .facility(let facility):
            guard namesFacility(facility, in: strongContent) else { return .unclear }
            if !matches(facilityRestriction, content).isEmpty {
                return SignReading(kind: .restricted, evidence: facility.rawValue)
            }
            let multipleFacilities = Facility.allCases.contains { $0 != facility && namesFacility($0, in: content) }
            let listed = features.directoryWords > 0 || features.separators > 0 || multipleFacilities
            return SignReading(kind: listed ? .directory : .facility, evidence: facility.rawValue)
        case .room(let id):
            // Identify whole ranges before considering individual endpoints. Joining OCR lines also
            // preserves a range when Vision separates its digits from the separator.
            let rangeMatches = matches(ranges, content)
            let confidentRanges = matches(ranges, strongContent).map { (strongContent as NSString).substring(with: $0.range) }
            for r in rangeMatches {
                let ns = content as NSString
                let a = ns.substring(with: r.range(at: 1)), b = ns.substring(with: r.range(at: 2))
                if contains(id, left: a, right: b), confidentRanges.contains(ns.substring(with: r.range)) {
                    return SignReading(kind: .range, evidence: "\(a)–\(b)")
                }
            }
            let remainder = NSMutableString(string: content)
            for r in rangeMatches.reversed() { remainder.replaceCharacters(in: r.range, with: " ") }
            let tokens = matches(rooms, remainder as String).map { remainder.substring(with: $0.range) }
            let strongTokens = Set(matches(rooms, strongContent).map { (strongContent as NSString).substring(with: $0.range) })
            if tokens.contains(id), strongTokens.contains(id) {
                if features.directoryWords > 0 || features.separators > 0 || features.numbers > 1 || suggestsDirectory?(features) == true {
                    return SignReading(kind: .directory, evidence: id)
                }
                let isSplitRange = lines.contains { !matches(rangeGlue, $0).isEmpty }
                let standalone = strong.contains { line in
                    matches(door, line).contains { (line as NSString).substring(with: $0.range(at: 1)) == id }
                }
                let contextIsDoor = lines.allSatisfy { strongLine in
                    strongLine == "ROOM" || strongLine == "CLASSROOM" || strongLine == "教室" || !matches(door, strongLine).isEmpty
                }
                return SignReading(kind: standalone && contextIsDoor && !isSplitRange ? .target : .mention, evidence: id)
            }
            if let neighbor = strong.first(where: { !matches(door, $0).isEmpty }), let m = matches(door, neighbor).first {
                let code = (neighbor as NSString).substring(with: m.range(at: 1))
                if !rangeMatches.isEmpty || code == id { return .unclear }
                return SignReading(kind: .neighbor, evidence: code)
            }
            return .unclear
        }
    }
}
