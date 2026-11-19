import Foundation

struct DictSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let format: String
    let path: String
    let state: String
    let progress: Float
    let entries: UInt64
    let enabled: Bool
    let icon: String?
    let about: String
    let languages: String
    let error: String?
    let size: UInt64

    var isReady: Bool { state == "ready" }
    var isBusy: Bool { state == "pending" || state == "indexing" }

    /// A compact name for the margin: drops language tags, editions and versions.
    var shortName: String { Self.shorten(name) }

    static func shorten(_ name: String) -> String {
        var s = name
        // "(En-En)", "(Eng-Eng)" and similar bracketed tags
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[_\s]+\d+(\.\d+)+\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_\d+\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",?\s*\d+(st|nd|rd|th)\s+(Edition|Ed\.?)\b\.?"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\s+\d+(st|nd|rd|th)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+(\d+(\.\d+)?)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "‘", with: "’").replacingOccurrences(of: "'", with: "’")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,._-"))
        return s.isEmpty ? name : s
    }
}

struct Suggestion: Codable, Hashable, Sendable {
    let word: String
    /// exact | lemma | prefix | fuzzy | glob
    let kind: String
    let sources: UInt32
}

struct Hit: Codable, Hashable, Sendable {
    let dict: String
    let name: String
    let entries: [Int]
    let words: [String]
    let foreign: Bool
}

struct LookupResult: Codable, Hashable, Sendable {
    let word: String
    let via: String?
    let hits: [Hit]
}
