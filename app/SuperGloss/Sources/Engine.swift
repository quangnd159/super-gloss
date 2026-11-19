import Foundation

/// Thin, thread-safe wrapper over the Rust core. Every call is synchronous and
/// cheap enough for interactive use, but callers run them off the main actor.
final class Engine: @unchecked Sendable {
    private let lib: OpaquePointer

    init(cacheDirectory: URL) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let p = cacheDirectory.path.withCString({ sg_library_new($0) }) else {
            fatalError("Super Gloss core failed to initialise")
        }
        lib = p
    }

    deinit { sg_library_free(lib) }

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { sg_free_string(p) }
        return String(cString: p)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ p: UnsafeMutablePointer<CChar>?) -> T? {
        guard let s = take(p) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    func configure(roots: [String], order: [String], disabled: [String]) {
        let cfg: [String: [String]] = ["roots": roots, "order": order, "disabled": disabled]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { sg_configure(lib, $0) }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        id.withCString { sg_set_enabled(lib, $0, enabled) }
    }

    func reindex(_ id: String) {
        id.withCString { sg_reindex(lib, $0) }
    }

    var generation: UInt64 { sg_generation(lib) }

    func dictionaries() -> [DictSummary] {
        decode([DictSummary].self, sg_dictionaries(lib)) ?? []
    }

    func suggest(_ query: String, limit: Int = 40) -> [Suggestion] {
        decode([Suggestion].self, query.withCString { sg_suggest(lib, $0, UInt32(limit)) }) ?? []
    }

    func lookup(_ word: String) -> LookupResult {
        decode(LookupResult.self, word.withCString { sg_lookup(lib, $0) })
            ?? LookupResult(word: word, via: nil, hits: [])
    }

    func randomWord() -> String? {
        take(sg_random_word(lib))
    }

    struct Served: Sendable {
        let data: Data
        let mime: String
    }

    func serve(_ url: String) -> Served? {
        var len = 0
        var mime: UnsafeMutablePointer<CChar>?
        guard let p = url.withCString({ sg_serve(lib, $0, &len, &mime) }) else { return nil }
        let data = Data(bytes: p, count: len)
        sg_free_bytes(p, len)
        return Served(data: data, mime: take(mime) ?? "application/octet-stream")
    }

    func audio(dict: String, path: String) -> Data? {
        var len = 0
        let p = dict.withCString { d in path.withCString { sg_audio(lib, d, $0, &len) } }
        guard let p else { return nil }
        defer { sg_free_bytes(p, len) }
        return Data(bytes: p, count: len)
    }
}
