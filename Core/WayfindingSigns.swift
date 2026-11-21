import Foundation

/// A sign's layout matters. A floor label in a tenant list describes the tenant,
/// whereas a landing plate at the lift describes the traveler's current location.
struct RouteSite: Equatable, Hashable {
    var level: String?
    var landmark: String?
    var arrow: SignArrow?
}

enum SignArrow: String, CaseIterable {
    case left = "←", right = "→", ahead = "↑", down = "↓", upperLeft = "↖", upperRight = "↗", lowerLeft = "↙", lowerRight = "↘"
    var words: String {
        switch self {
        case .left: return "左"; case .right: return "右"; case .ahead: return "前方"; case .down: return "下方"
        case .upperLeft: return "左前方"; case .upperRight: return "右前方"; case .lowerLeft: return "左下方"; case .lowerRight: return "右下方"
        }
    }
    var pattern: String {
        switch self {
        case .left: return #"←|⬅|⇦|向左|左转|左侧|往左|\b(?:TURN )?LEFT\b"#
        case .right: return #"→|➡|⇨|向右|右转|右侧|往右|\b(?:TURN )?RIGHT\b"#
        case .ahead: return #"↑|⬆|⇧|直行|向前|\b(?:STRAIGHT(?: AHEAD)?|AHEAD)\b"#
        case .down: return #"↓|⬇|⇩"#
        default: return rawValue
        }
    }
}

enum VisualSetting: String { case room, outside, shop }
struct SceneClues: Equatable {
    var setting: VisualSetting?
    /// Position in the camera image only. A classifier cannot verify a traversable opening.
    var door: String?
    var geometricDoor = false
    var doorBoxes: [CGRect] = []
}

enum TargetSign: Equatable {
    case plate, listed(RouteSite), ambiguous, mention
}
struct RouteChoice: Equatable, Hashable {
    let name: String
    let site: RouteSite
    var label: String {
        [name, site.level, site.landmark, site.arrow.map { "箭头向\($0.words)" }].compactMap { $0 }.joined(separator: " · ")
    }
}
struct WayfindingSigns: Equatable {
    var choices: [RouteChoice] = []
    var restricted = false
    var currentLevel: String?
    var target: TargetSign?
    var nearbyRoom: String?
    var transfer: String?
    var transferArrow: SignArrow?
    var onward: SignArrow?
    var portal: String?
    var portalArrow: SignArrow?
    var scene = SceneClues()
    var signboard = false
}

extension Destination {
    var isClassroomDoor: Bool { ["门", "门口", "教室门", "教室门口", "教室的门", "教室的门口", "房间门口"].contains(text) }
    /// Keep the original strict room / facility entry for standard room and facility identifiers.
    init?(wayfinding input: String) {
        if let parsed = Destination(input) { self = parsed; return }
        // Recognizer partials replace each other. A completed utterance can also contain an explicit correction.
        let revised = input.replacingOccurrences(of: #"^.*[，,。！! ](?:不对|我说错了|说错了|改成|改去)[，,。 ]*"#,with:"",options:.regularExpression)
        let text = revised.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:请带我去|請帶我去|请帮我找|請幫我找|帮我找|带我去|导航到|我想去|我要去|我想找|我要找|寻找|去|找|(?:TAKE ME TO|FIND|LOOK FOR)\s+)\s*"#, with: "", options: [.regularExpression,.caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " 。.!！?？"))
            .replacingOccurrences(of:#"^(?:商场|医院|学校)(?:里边的|里面的|里的|的)"#,with:"",options:.regularExpression)
        if let parsed = Destination(text) { self = parsed; return }
        guard (1...64).contains(text.count), text.rangeOfCharacter(from: .letters) != nil,
              text.range(of: #"^[\p{L}\p{M}\p{N} &’'·.．\-（）()]+$"#, options: .regularExpression) != nil else { return nil }
        self = .named(text)
    }
}

enum WayfindingParser {
    private static let floorPattern = #"(?<![A-Z0-9])(?:B[1-9][0-9]?(?:F)?|(?:L|F)[0-9]{1,2}|[0-9]{1,2}\s*F|(?:FLOOR|LEVEL)\s*(?:B\s*)?[0-9]{1,2}|[0-9]{1,2}(?:ST|ND|RD|TH)\s+FLOOR|(?:LOWER\s+)?GROUND\s+FLOOR|LG|GF)(?![A-Z0-9])|(?:地下|负|負|第)?[零一二两兩三四五六七八九十0-9]{1,3}\s*[楼樓层層]"#
    private static let boardPattern = #"目录|目錄|导览|導覽|指南|索引|分布|分佈|平面图|一览|導引|\b(?:DIRECTOR(?:Y|IES)|INDEX|FLOOR PLAN|STORE GUIDE)\b"#
    private static let herePattern = #"您在此|你在此|当前位置|当前楼层|所在楼层|本层|本層|\b(?:YOU ARE HERE|CURRENT (?:FLOOR|LEVEL)|YOU ARE ON)\b"#
    private static let restrictedPattern = #"停用|暂停|暫停|维修|維修|检修|故障|关闭|關閉|禁止|封闭|施工|员工专用|非出口|勿入|请勿进入|\b(?:CLOSED|NO (?:ENTRY|EXIT|ACCESS)|NOT AN EXIT|STAFF ONLY|OUT OF (?:ORDER|SERVICE)|DO NOT (?:ENTER|USE))\b"#
    private static let landmarkPattern = #"(?:[A-Z0-9东東西南北中]{1,3}\s*[座区區翼栋棟馆館]|[\p{Han}]{2,6}(?:大楼|大樓)|(?:WING|ZONE|BLOCK|BUILDING)\s+[A-Z0-9]+|(?:EAST|WEST|NORTH|SOUTH) WING)"#
    private static let decoration = CharacterSet(charactersIn: " \t\n:：|/、·•.,，。–—-[]()（）")
    private static func parts(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    private static func has(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func strip(_ pattern: String, _ text: String) -> String { text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
    private static func key(_ input: String) -> String { SignParser.normalize(input).filter { !$0.isWhitespace } }
    // Compare complete printed labels. A longer clinic or brand name cannot be
    // promoted to a match by dropping its suffix. Preserve the original OCR for display.
    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        let a = key(lhs), b = key(rhs)
        if a == b { return true }
        guard a.count == b.count, a.unicodeScalars.contains(where: { !$0.isASCII }), b.unicodeScalars.contains(where: { !$0.isASCII }) else { return false }
        let fold = StringTransform("Hant-Hans")
        return (a.applyingTransform(fold, reverse: false) ?? a) == (b.applyingTransform(fold, reverse: false) ?? b)
    }
    private static let bilingualLabel = try! NSRegularExpression(pattern: #"^(?:([\p{Han}·]{2,32})[\s/|·]+([\p{Latin}][\p{Latin} &’.\-']{1,55})|([\p{Latin}][\p{Latin} &’.\-']{1,55})[\s/|·]+([\p{Han}·]{2,32}))$"#)
    private static func names(on text: String) -> [String] {
        let ns = text as NSString
        guard let match = bilingualLabel.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return [text] }
        return [text] + (1..<match.numberOfRanges).compactMap { index in
            let span = match.range(at: index)
            return span.location == NSNotFound ? nil : ns.substring(with: span)
        }
    }
    private static func level(_ match: String) -> String? {
        if match == "GF" || match == "GROUND FLOOR" { return "GF" }
        if match == "LG" || match == "LOWER GROUND FLOOR" { return "LG" }
        let chinese = ["零":0,"一":1,"二":2,"两":2,"兩":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let word = match.filter { chinese[String($0)] != nil || $0 == "十" }
        let number: Int?
        if let integer = Int(match.filter(\.isNumber).filter(\.isASCII)) { number = integer }
        else if let ten = word.firstIndex(of: "十") {
            let tens = chinese[String(word[..<ten])] ?? 1, ones = chinese[String(word[word.index(after: ten)...])] ?? 0
            number = tens * 10 + ones
        } else { number = chinese[String(word)] }
        guard let number, (0...99).contains(number) else { return nil }
        let basement = match.contains("B") || match.hasPrefix("地下") || match.hasPrefix("负") || match.hasPrefix("負")
        return basement ? "B\(number)" : "\(number)F"
    }
    private static func floorTokens(_ row: String) -> Set<String> { Set(parts(floorPattern, row).compactMap(level)) }
    private static func isFloorPlate(_ row: String) -> Bool {
        !floorTokens(row).isEmpty && strip(floorPattern, strip(herePattern, row)).trimmingCharacters(in: decoration).isEmpty
    }
    private static func arrows(_ text: String) -> [SignArrow] { SignArrow.allCases.filter { has($0.pattern, text) } }
    private static func label(_ row: String) -> String {
        var name = strip(boardPattern, strip(floorPattern, row))
        for arrow in SignArrow.allCases { name = strip(arrow.pattern, name) }
        return name.trimmingCharacters(in: decoration)
    }
    private struct Row {
        var text: String
        let column: Int
    }

    /// Repeated stacks of floor headings reveal separate directory columns, even
    /// when perspective shifts one translation above or below its counterpart.
    private static func headingCenters(_ lines: [SignLine]) -> [CGFloat] {
        let headings = lines.filter { !$0.bounds.isEmpty && isFloorPlate($0.text) && !has(herePattern, $0.text) }
            .sorted { $0.bounds.midX < $1.bounds.midX }
        var stacks: [[SignLine]] = []
        for line in headings {
            if let left = stacks.last?.first, line.bounds.midX - left.bounds.midX <= 0.14 {
                stacks[stacks.count - 1].append(line)
            } else { stacks.append([line]) }
        }
        let centers = stacks.compactMap { stack -> CGFloat? in
            guard Set(stack.flatMap { floorTokens($0.text) }).count >= 2 else { return nil }
            return stack.map(\.bounds.midX).reduce(0, +) / CGFloat(stack.count)
        }
        return centers.count >= 2 ? centers : []
    }

    private static func rows(_ lines: [SignLine]) -> [Row] {
        let strong = lines.filter { $0.confidence >= 0.65 }.map { SignLine(SignParser.normalize($0.text), confidence: $0.confidence, bounds: $0.bounds) }
        let centers = headingCenters(strong)
        let columns = Dictionary(grouping: strong) { line -> Int in
            guard !line.bounds.isEmpty, let nearest = centers.indices.min(by: {
                abs(centers[$0] - line.bounds.midX) < abs(centers[$1] - line.bounds.midX)
            }) else { return 0 }
            return abs(centers[nearest] - line.bounds.midX) < 0.27 ? nearest : -1
        }
        return columns.keys.sorted().flatMap { column -> [Row] in
            var groups: [[SignLine]] = []
            for line in columns[column]!.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
                if !line.bounds.isEmpty, let i = groups.firstIndex(where: { group in
                    guard let first = group.first, !first.bounds.isEmpty else { return false }
                    return abs(first.bounds.midY - line.bounds.midY) <= 0.48 * min(first.bounds.height, line.bounds.height)
                }) { groups[i].append(line) } else { groups.append([line]) }
            }
            return groups.flatMap { group -> [Row] in
                var result: [Row] = []
                var last: SignLine?
                for item in group.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                    if let last, item.bounds.minX - last.bounds.maxX < 0.27 { result[result.count-1].text += " " + item.text }
                    else { result.append(Row(text: item.text, column: column)) }
                    last = item
                }
                return result
            }
        }
    }
    private static func matches(_ row: String, destination: Destination) -> Bool {
        switch destination {
        case .room:
            let read = SignParser.analyze([SignLine(label(row))], for: destination)
            return [.target, .directory, .mention, .range].contains(read.kind)
        case .named(let name):
            let cleaned = label(row)
            let landmarkRemoved = strip(landmarkPattern, cleaned).trimmingCharacters(in: decoration)
            return [cleaned, landmarkRemoved].contains { names(on: $0).contains { sameName($0, name) } }
                || sameName(row, name)
        case .facility(let facility): return names(on: label(row)).contains { item in facility.aliases.contains { sameName($0, item) } }
        }
    }
    /// An abbreviated spoken place can correspond to several tenants or service desks.
    /// Only offer names actually printed on a directory. The traveler chooses one.
    private static func similar(_ row: String, to target: Destination) -> String? {
        guard case .named(let name) = target else { return nil }
        let visible = strip(landmarkPattern, label(row)).trimmingCharacters(in: decoration)
        let query = key(name), candidate = key(visible)
        guard (2...64).contains(candidate.count), query.count >= 2, query != candidate,
              candidate.range(of: #"^[\p{L}\p{N}·&’'\-]+$"#, options: .regularExpression) != nil else { return nil }
        if candidate.contains(query) || (candidate.count >= 3 && query.contains(candidate)) { return visible }
        // Permit one substitution in a longer name as a question, never as an arrival match.
        if candidate.count >= 4, query.count == candidate.count,
           zip(candidate, query).filter({ $0 != $1 }).count == 1 { return visible }
        return nil
    }
    private static func isPlate(_ row: String, for target: Destination) -> Bool {
        switch target {
        case .room: return SignParser.analyze([SignLine(row)], for: target).kind == .target
        case .named(let name): return names(on: row).contains { sameName($0, name) }
        case .facility(let facility): return names(on: row).contains { item in facility.aliases.contains { sameName($0, item) } }
        }
    }
    static func read(_ frame: FrameResult, for target: Destination, landmark: String? = nil) -> WayfindingSigns {
        let layout = rows(frame.lines)
        let ordered = layout.map(\.text)
        let context = frame.lines.filter { $0.confidence >= 0.45 }.map { SignParser.normalize($0.text) }.joined(separator: " ")
        var result = WayfindingSigns()
        result.restricted = has(restrictedPattern, context)
        let headings = ordered.filter { isFloorPlate($0) && !has(herePattern, $0) }
        let hasFloorGroups = Set(headings.flatMap(floorTokens)).count >= 2 && headings.count < ordered.count
        result.signboard = has(boardPattern, context) || hasFloorGroups
        let here = ordered.filter { has(herePattern, $0) }.flatMap { floorTokens($0) }
        // A floor heading on a directory describes entries. A standalone landing sign can update location.
        if Set(here).count == 1 { result.currentLevel = here.first }
        else if !result.signboard, !ordered.isEmpty, ordered.allSatisfy(isFloorPlate) {
            let floors = Set(ordered.flatMap(floorTokens))
            if floors.count == 1 { result.currentLevel = floors.first }
        }
        var headers: [Int: String] = [:]
        var entries: [RouteSite] = [], isPlateCandidate = false, conflict = false
        var portals: [String: Set<SignArrow>] = [:]
        var transportRows: [(String, SignArrow?)] = [], landmarkDirections: Set<SignArrow> = []
        for item in layout {
            let row = item.text
            let levels = floorTokens(row), directions = arrows(row)
            if result.signboard, isFloorPlate(row), !has(herePattern, row) { headers[item.column] = levels.count == 1 ? levels.first : nil; continue }
            let header = item.column >= 0 ? headers[item.column] : nil
            if has(herePattern, row) { continue }
            if directions.count <= 1 {
                let trimmed = label(row)
                let name = has(#"\bENTRANCE\b|入口|正门|正門"#, trimmed) ? "入口" : (has(#"\bEXIT\b|出口"#, trimmed) ? "出口" : nil)
                if let name { portals[name, default: []].formUnion(directions) }
            }
            if matches(row, destination: target) {
                if directions.count > 1 || levels.count > 1 { conflict = true }
                let zone = parts(landmarkPattern, row).first.flatMap { key($0) == key(target.text) ? nil : $0 }
                entries.append(RouteSite(level: levels.first ?? header, landmark: zone, arrow: directions.first))
                isPlateCandidate = isPlateCandidate || isPlate(row, for: target)
            }
            if result.signboard, !has(boardPattern,row), !matches(row, destination: target),
               let name = similar(row, to: target), levels.count <= 1, directions.count <= 1 {
                let choice = RouteChoice(name: name, site: RouteSite(level: levels.first ?? header, landmark: parts(landmarkPattern,row).first, arrow: directions.first))
                if !result.choices.contains(choice), result.choices.count < 5 { result.choices.append(choice) }
            }
            if let landmark, key(label(row)) == key(landmark) { landmarkDirections.formUnion(directions) }
            if directions.count <= 1 {
                let transfers = Set(names(on: label(row)).compactMap(transitName))
                if transfers.count == 1, let transfer = transfers.first { transportRows.append((transfer, directions.first)) }
            }
        }
        if conflict || Set(entries).count > 1 { result.target = .ambiguous }
        else if let site = entries.first {
            let extra = ordered.filter { !isPlate($0, for: target) && !["ROOM","CLASSROOM","教室"].contains($0) }
            let lowContext = frame.lines.contains { $0.confidence >= 0.45 && $0.confidence < 0.65 && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if isPlateCandidate && extra.isEmpty && !lowContext && !result.signboard && site == RouteSite() { result.target = .plate }
            else if !result.signboard && site == RouteSite() { result.target = .mention }
            else { result.target = .listed(site) }
        }
        if result.target == .ambiguous, !conflict {
            result.choices = entries.reduce(into: []) { choices, site in
                let choice = RouteChoice(name: target.text, site: site)
                if !choices.contains(choice) { choices.append(choice) }
            }
        } else if result.target != nil { result.choices = [] }
        if result.target == nil, case .room = target, frame.reading.kind == .range { result.target = .listed(RouteSite()) }
        if result.target == nil, frame.reading.kind == .directory { result.target = .mention }
        // A directory with a highlighted row read below threshold must never be promoted to a local plate.
        if result.target == .plate && frame.reading.kind == .directory { result.target = .mention }
        if landmarkDirections.count == 1 { result.onward = landmarkDirections.first }
        if let chosen = transportRows.first(where: { $0.0 == "电梯" }) ?? transportRows.first,
           !(result.signboard && chosen.1 == nil), Set(transportRows.filter { $0.0 == chosen.0 }.map(\.1)).count == 1 {
            result.transfer = chosen.0; result.transferArrow = chosen.1
        }
        if !result.signboard, result.currentLevel == nil, !ordered.isEmpty,
           ordered.allSatisfy({ ["ROOM","CLASSROOM","教室"].contains($0) || SignParser.analyze([SignLine($0)], for: .room("00000")).kind == .neighbor }),
           ordered.compactMap({ row -> String? in
               let reading = SignParser.analyze([SignLine(row)], for: .room("00000")); return reading.kind == .neighbor ? reading.evidence : nil
           }).count == 1 {
            result.nearbyRoom = ordered.map { SignParser.analyze([SignLine($0)], for: .room("00000")) }.first { $0.kind == .neighbor }?.evidence
        }
        if !result.signboard, portals.count == 1, let (name, directions) = portals.first, directions.count <= 1 {
            result.portal = name; result.portalArrow = directions.first
        }
        if result.target == nil, result.nearbyRoom == nil, result.transfer == nil, result.currentLevel == nil, !result.signboard { result.scene = frame.scene }
        return result
    }
    private static func transitName(_ text: String) -> String? {
        let value = key(text)
        if ["电梯","電梯","客梯","无障碍电梯","LIFT","LIFTS","ELEVATOR","ELEVATORS"].contains(value) { return "电梯" }
        if ["楼梯","樓梯","STAIRS","STAIRCASE"].contains(value) { return "楼梯" }
        if ["扶梯","自动扶梯","ESCALATOR","ESCALATORS"].contains(value) { return "扶梯" }
        return nil
    }
}
