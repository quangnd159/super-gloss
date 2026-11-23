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

    /// A compact name for bylines and ⌘J's list: drops language tags, editions and versions.
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

/// Where a cross-reference clicked inside an article leads.
struct ResolvedLink: Codable, Sendable {
    /// What to look up.
    let word: String
    /// What the search line shows.
    let label: String
    /// Element id to scroll to in the linking dictionary's article.
    let anchor: String?
}

/// A reading position: this far (in CSS px) below the top of one dictionary's section.
struct Place: Equatable, Sendable {
    let dict: String
    let offset: Double
}

/// Where the view should land when an article is shown.
enum Landing: Equatable, Sendable {
    /// What a followed link points at in dictionary `dict`, marked briefly on arrival:
    /// element `id` (or the whole article), narrowed to the text that was clicked.
    case anchor(dict: String, id: String?, find: String?)
    /// Where the reader was, restored silently by Back and Forward.
    case place(Place)
}

/// A step in Back/Forward history.
struct Visit: Equatable, Sendable {
    let word: String
    let place: Place?
}

struct LookupResult: Codable, Hashable, Sendable {
    let word: String
    let via: String?
    let hits: [Hit]
}

/// A word on the home page, or the "N more" that unfolds the saved words.
enum HomeItem: Hashable, Sendable {
    case saved(String)
    case more
    case recent(String)
}

/// The entry the reader is on: its dictionary's short name, and whether it is hidden.
struct CurrentEntry: Equatable {
    let name: String
    let hidden: Bool
}
