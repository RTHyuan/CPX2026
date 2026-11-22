import Foundation

/// Keep the printed label for the screen and its meaning for speech. A room named B1
/// and a directory listing on floor B1 can occur in the very same instruction.
struct GuidancePrompt: ExpressibleByStringInterpolation, Equatable {
    let text: String
    let speech: String

    init(stringLiteral value: String) { text = value; speech = value }
    init(stringInterpolation parts: StringInterpolation) { text = parts.text; speech = parts.speech }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        var speech = ""
        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ value: String) { text += value; speech += value }
        mutating func appendInterpolation(_ label: String) { text += label; speech += SignReading.spoken(label) }
        mutating func appendInterpolation(floor label: String) { text += label; speech += Mandarin.floor(label) }
        mutating func appendInterpolation(site: RouteSite) {
            if let level = site.level { appendInterpolation(floor: level) }
            if let landmark = site.landmark {
                if site.level != nil { appendLiteral(" ") }
                appendInterpolation(landmark)
            }
        }
    }
}

enum Mandarin {
    /// Lower ranks prefer mainland Mandarin. Never substitute an unrelated system voice.
    static func voiceRank(_ language: String) -> Int? {
        let parts = language.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")
        guard parts.first == "zh" || parts.first == "cmn" else { return nil }
        guard ["yue", "nan", "hak", "wuu", "hk", "mo"].allSatisfy({ !parts.contains($0) }) else { return nil }
        if parts.contains("cn") { return 0 }
        if parts.contains("hans") || parts.contains("sg") { return 1 }
        if parts.contains("tw") || parts.contains("hant") { return 2 }
        return parts == ["zh"] || parts.first == "cmn" ? 3 : nil
    }

    static func floor(_ label: String) -> String {
        switch label {
        case "GF": return "地面层"
        case "LG": return "地面下层"
        default: break
        }
        let basement = label.hasPrefix("B")
        guard basement || label.hasSuffix("F") else { return label }
        let digits = basement ? label.dropFirst() : label.dropLast()
        guard let n = Int(digits), (0...99).contains(n) else { return label }
        let numbers = Array("零一二三四五六七八九").map(String.init)
        let number: String
        if n < 10 { number = numbers[n] }
        else { number = (n < 20 ? "" : numbers[n / 10]) + "十" + (n % 10 == 0 ? "" : numbers[n % 10]) }
        return basement ? "地下\(number)层" : "\(number)楼"
    }
}
