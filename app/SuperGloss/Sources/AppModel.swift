import AppKit
import Observation
import SwiftUI

@MainActor
protocol ArticleController: AnyObject {
    func show(_ result: LookupResult?, dictionaries: [DictSummary])
    func jump(_ direction: Int)
    func page(_ direction: Int)
    func pronounce()
    func setZoom(_ zoom: Double)
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let engine: Engine
    let prefs = Prefs()
    let audio: AudioPlayer

    // MARK: search state

    var query = "" {
        didSet { if query != oldValue && !programmatic { search(show: nil) } }
    }
    private(set) var suggestions: [Suggestion] = []
    /// Index into `suggestions` of the word on screen; -1 when the shown word is not in the strip.
    private(set) var selected = 0
    private(set) var shown: LookupResult?
    private(set) var noResults = false
    /// Incremented to ask the search field to take focus (and select all when `selectAll`).
    private(set) var focusTick = 0
    private(set) var selectAll = false

    // MARK: navigation

    private(set) var committed: String?
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var history: [String]

    // MARK: library

    private(set) var dictionaries: [DictSummary] = []
    var readyCount: Int { dictionaries.filter { $0.isReady && $0.enabled }.count }
    var busy: [DictSummary] { dictionaries.filter(\.isBusy) }
    var indexingProgress: Double? {
        let b = busy
        guard !b.isEmpty else { return nil }
        let total = dictionaries.count
        let done = dictionaries.filter { !$0.isBusy }.count
        let partial = b.reduce(0.0) { $0 + Double($1.progress) }
        return min(1, (Double(done) + partial) / Double(max(total, 1)))
    }

    weak var article: ArticleController?
    var openMainWindow: (() -> Void)?

    @ObservationIgnored private var programmatic = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var lastGeneration: UInt64 = 0
    @ObservationIgnored private var lastReadyIDs: Set<String> = []

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SuperGloss", isDirectory: true)
            .appendingPathComponent("Indexes", isDirectory: true)
        engine = Engine(cacheDirectory: caches)
        audio = AudioPlayer(engine: engine)
        history = prefs.history
        applyConfiguration()
    }

    // MARK: configuration

    func applyConfiguration() {
        engine.configure(roots: prefs.roots, order: prefs.order, disabled: prefs.disabled)
        refreshDictionaries()
        startPolling()
    }

    func addRoots(_ urls: [URL]) {
        var roots = prefs.roots
        for u in urls where !roots.contains(u.path) {
            roots.append(u.path)
        }
        prefs.roots = roots
        applyConfiguration()
    }

    func removeRoot(_ path: String) {
        prefs.roots.removeAll { $0 == path }
        applyConfiguration()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var d = Set(prefs.disabled)
        if on { d.remove(id) } else { d.insert(id) }
        prefs.disabled = Array(d)
        engine.setEnabled(id, on)
        refreshDictionaries()
        refreshCurrent()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var ids = dictionaries.map(\.id)
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        prefs.order = ids
        applyConfiguration()
        refreshCurrent()
    }

    func reindex(_ id: String) {
        engine.reindex(id)
        refreshDictionaries()
        startPolling()
    }

    private func startPolling() {
        guard poller == nil else { return }
        poller = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let g = engine.generation
        guard g != lastGeneration else { return }
        lastGeneration = g
        refreshDictionaries()
        if busy.isEmpty {
            poller?.invalidate()
            poller = nil
        }
    }

    private func refreshDictionaries() {
        dictionaries = engine.dictionaries()
        let ready = Set(dictionaries.filter(\.isReady).map(\.id))
        if !ready.subtracting(lastReadyIDs).isEmpty {
            lastReadyIDs = ready
            refreshCurrent()
        } else {
            lastReadyIDs = ready
        }
    }

    /// Re-runs the current search so newly indexed or re-ordered sources appear.
    private func refreshCurrent() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let word = selected >= 0 && selected < suggestions.count ? suggestions[selected].word : shown?.word
        search(show: word, force: true)
    }

    // MARK: searching

    private func search(show pinned: String?, force: Bool = false) {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewTask?.cancel()
            suggestions = []
            selected = 0
            noResults = false
            display(nil)
            return
        }
        let engine = engine
        searchTask = Task {
            let s = await Task.detached(priority: .userInitiated) { engine.suggest(q) }.value
            guard !Task.isCancelled, q == self.query else { return }
            self.suggestions = s
            if let pinned {
                self.selected = s.firstIndex { $0.word.lowercased() == pinned.lowercased() } ?? -1
                self.lookUp(pinned, delay: .zero, force: force)
            } else {
                self.selected = 0
                self.lookUp(s.first?.word ?? q, delay: .milliseconds(45), force: force)
            }
        }
    }

    private func lookUp(_ word: String, delay: Duration, force: Bool = false) {
        previewTask?.cancel()
        let engine = engine
        previewTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let r = await Task.detached(priority: .userInitiated) { engine.lookup(word) }.value
            guard !Task.isCancelled else { return }
            if force || r != self.shown {
                self.display(r)
            }
        }
    }

    private func display(_ r: LookupResult?) {
        shown = r
        noResults = r.map { $0.hits.isEmpty } ?? false
        article?.show(r?.hits.isEmpty == false ? r : nil, dictionaries: dictionaries)
    }

    /// Ghost completion for the search field.
    var completion: String? {
        guard selected == 0, let s = suggestions.first, s.kind == "exact" || s.kind == "prefix" else { return nil }
        let q = query
        guard !q.isEmpty, s.word.count > q.count, q.count < 48 else { return nil }
        guard s.word.prefix(q.count).lowercased() == q.lowercased() else { return nil }
        return String(s.word.dropFirst(q.count))
    }

    func acceptCompletion() -> Bool {
        guard let c = completion else { return false }
        setQuery(query + c, show: suggestions.first?.word)
        return true
    }

    func moveSelection(_ d: Int) {
        guard !suggestions.isEmpty else { return }
        let n = max(0, min(suggestions.count - 1, (selected < 0 ? (d > 0 ? -1 : 0) : selected) + d))
        guard n != selected else { return }
        selected = n
        lookUp(suggestions[n].word, delay: .milliseconds(20))
    }

    func choose(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        commit(suggestions[index].word)
    }

    /// Return key: commit the word on screen.
    func submit() {
        if selected >= 0 && selected < suggestions.count {
            commit(suggestions[selected].word)
        } else if let w = shown?.word, !(shown?.hits.isEmpty ?? true) {
            commit(w)
        } else {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { commit(q) }
        }
    }

    /// Looks up `word` as a deliberate navigation (links, history, services).
    func commit(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        if let c = committed, c != w {
            backStack.append(c)
            if backStack.count > 200 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        committed = w
        record(w)
        setQuery(w, show: w)
        requestFocus(selectAll: true)
    }

    func lookUpExternally(_ word: String) {
        openMainWindow?()
        commit(word)
    }

    private func setQuery(_ q: String, show word: String?) {
        programmatic = true
        query = q
        programmatic = false
        search(show: word)
    }

    func clear() {
        if query.isEmpty { return }
        query = ""
        requestFocus(selectAll: false)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        if let c = committed { forwardStack.append(c) }
        committed = prev
        setQuery(prev, show: prev)
        requestFocus(selectAll: true)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let c = committed { backStack.append(c) }
        committed = next
        setQuery(next, show: next)
        requestFocus(selectAll: true)
    }

    func surprise() {
        let engine = engine
        Task {
            if let w = await Task.detached(priority: .userInitiated, operation: { engine.randomWord() }).value {
                self.commit(w)
            }
        }
    }

    func requestFocus(selectAll: Bool) {
        self.selectAll = selectAll
        focusTick &+= 1
    }

    /// A character typed while the article had focus.
    func typed(_ key: String) {
        if key == "Escape" {
            clear()
            return
        }
        requestFocus(selectAll: false)
        query += key
    }

    private func record(_ w: String) {
        history.removeAll { $0.caseInsensitiveCompare(w) == .orderedSame }
        history.insert(w, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
        prefs.history = history
    }

    func clearHistory() {
        history = []
        prefs.history = []
    }

    // MARK: reading

    var zoom: Double {
        get { prefs.zoom }
        set {
            prefs.zoom = min(2.0, max(0.7, newValue))
            article?.setZoom(prefs.zoom)
        }
    }
}

/// Persistent preferences.
@MainActor
final class Prefs {
    private let d = UserDefaults.standard

    init() {
        if d.object(forKey: "roots") == nil {
            d.set(Prefs.defaultRoots(), forKey: "roots")
        }
    }

    static var libraryFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Super Gloss/Dictionaries", isDirectory: true)
    }

    /// Well-known places dictionaries live. Avoids TCC-protected folders
    /// (Documents, Downloads, Desktop) so first launch never prompts.
    static func defaultRoots() -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Dictionaries",
            "/Library/Dictionaries/Super Gloss",
            "\(home)/Dictionaries",
            "\(home)/.goldendict/dictionaries",
            "\(home)/.stardict/dic",
            libraryFolder.path,
        ]
        return candidates.filter { fm.fileExists(atPath: $0) }
    }

    var roots: [String] {
        get { d.stringArray(forKey: "roots") ?? [] }
        set { d.set(newValue, forKey: "roots") }
    }
    var order: [String] {
        get { d.stringArray(forKey: "order") ?? [] }
        set { d.set(newValue, forKey: "order") }
    }
    var disabled: [String] {
        get { d.stringArray(forKey: "disabled") ?? [] }
        set { d.set(newValue, forKey: "disabled") }
    }
    var history: [String] {
        get { d.stringArray(forKey: "history") ?? [] }
        set { d.set(newValue, forKey: "history") }
    }
    var zoom: Double {
        get { d.object(forKey: "zoom") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "zoom") }
    }
    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "appearance") }
    }
    var hotKey: HotKeyPreset {
        get { HotKeyPreset(rawValue: d.string(forKey: "hotKey") ?? "") ?? .optionSpace }
        set { d.set(newValue.rawValue, forKey: "hotKey") }
    }
}
