import Foundation

/// Turns a running transcript into actions: "stop"/"freeze" anywhere → stop now (no wake word, no LLM);
/// "Tony …" → a command for the agent, sent when the phrase is final.
public struct Listener: Sendable {
    public init() {}

    public enum Action: Equatable, Sendable {
        case none
        case stop
        case wake  // heard "Tony", waiting for the rest
        case command(String)
    }

    /// Always recognised, on top of what the bridge sends (tonyd's skill names).
    public static let baseVocabulary = [
        "Tony", "stop", "freeze", "wave", "bow", "walk forward", "turn left", "turn right", "get up", "stand up",
        "sit down", "step in place",
    ]
    public static let wakeWords: Set<String> = ["tony", "toni", "tonie", "tonys", "tony's"]
    public static let stopWords: Set<String> = ["stop", "freeze", "halt"]
    public static let followUpWindow: TimeInterval = 6

    /// Skill words ("wave", "bow", "step", …). A command word one letter away from exactly one of them, with the
    /// same first letter, is snapped to it: speech models hear "bow" as "Bo" and "wave" as "wade".
    public var vocabulary: Set<String> = []

    private var awakeUntil: Date?
    private var stoppedSegment = false

    /// Feed every transcript update. `isFinal` ends a segment.
    public mutating func hear(_ text: String, isFinal: Bool, now: Date = Date()) -> Action {
        let words = Self.words(text)
        defer { if isFinal { stoppedSegment = false } }
        if !stoppedSegment, words.contains(where: Self.stopWords.contains) {
            stoppedSegment = true  // one stop per segment, however often the volatile text repeats it
            awakeUntil = nil
            return .stop
        }
        if stoppedSegment { return .none }
        if let i = words.firstIndex(where: Self.wakeWords.contains) {
            let rest = words[(i + 1)...].joined(separator: " ")
            if isFinal {
                if rest.isEmpty {
                    awakeUntil = now.addingTimeInterval(Self.followUpWindow)
                    return .wake
                }
                awakeUntil = nil
                return .command(snap(rest))
            }
            return .wake
        }
        if isFinal, let until = awakeUntil, now < until, !words.isEmpty {
            awakeUntil = nil
            return .command(snap(words.joined(separator: " ")))
        }
        return .none
    }

    public mutating func setVocabulary(_ phrases: [String]) {
        vocabulary = Set(phrases.flatMap(Self.words).filter { $0.count >= 3 })
    }

    func snap(_ command: String) -> String {
        Self.words(command).map { w in
            guard !vocabulary.contains(w), w.count >= 2 else { return w }
            let near = vocabulary.filter { $0.first == w.first && Self.oneEditApart($0, w) }
            return near.count == 1 ? near.first! : w
        }.joined(separator: " ")
    }

    static func oneEditApart(_ a: String, _ b: String) -> Bool {
        let a = Array(a)
        let b = Array(b)
        if abs(a.count - b.count) > 1 || a == b { return false }
        var i = 0
        var j = 0
        var edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count {
                i += 1
            } else if b.count > a.count {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }

    public static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }
}
