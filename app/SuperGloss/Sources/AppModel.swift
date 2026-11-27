import AppKit
import Observation
import SwiftUI

@MainActor
protocol ArticleController: AnyObject {
    func show(_ result: LookupResult?, dictionaries: [DictSummary], landing: Landing?)
    func jump(_ direction: Int)
    /// Hands a key to the page to scroll by, as if it had focus: WebKit's own keyboard scrolling.
    func scroll(with key: NSEvent)
    func pronounce()
    /// Shares the selection in an entry as an image, from the system's share picker
    /// (`present`), or only has its card made, ready for when it is asked for.
    func shareAsImage(present: Bool)
    func setZoom(_ zoom: Double)
    func setIcons(_ on: Bool)
    /// Hides (true) or shows the entry the reader is on: ⌘J's selection while the list is open.
    func hideCurrent(_ hide: Bool)
    func find(_ query: String)
    func findStep(_ direction: Int)
    func prepareFind()
    /// Opens the list of the page's dictionaries, selecting the one being read.
    func indexOpen()
    /// Brings dictionary `dict`'s entry to the top, showing it if it was hidden.
    func indexQuery(_ query: String)
    func indexMove(_ direction: Int)
    func indexClose(_ exit: IndexExit)
}

/// How the list of the page's dictionaries closes.
enum IndexExit: String {
    /// Return or a click: keep the place, showing the dictionary if it was hidden.
    case pick
    /// Closed by something else (⌘J again, the search line, find): keep the place.
    case stay
    /// Esc: return to where the reader was.
    case back
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let engine: Engine
    let prefs = Prefs()
    let audio: AudioPlayer

    // MARK: search state

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Back on home from a word opened there: the keyboard is on it again, so ↓ goes on to the next.
            if !query.isEmpty { keptOnHome = nil }
            homeSelection = query.isEmpty ? homeReturn.flatMap { homeItems.contains($0) ? $0 : nil } : nil
            if !programmatic {
                // The reader's own typing outranks anything still on its way: a link being
                // resolved, a landing, the word a relaunch was going to reopen.
                linkTask?.cancel()
                pendingLanding = nil
                pendingResume = nil
                search(show: nil)
            }
        }
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
    private(set) var backStack: [Visit] = []
    private(set) var forwardStack: [Visit] = []
    private(set) var history: [String]

    // MARK: find in entries

    /// The find line is open under the word.
    private(set) var finding = false
    /// Kept between finds, like a find pasteboard: ⌘F brings it back selected.
    var findQuery = "" {
        didSet { if finding && findQuery != oldValue { article?.find(findQuery) } }
    }
    private(set) var findTotal = 0
    /// 1-based position of the current match; 0 when there is none.
    private(set) var findIndex = 0
    /// The article view is still collecting matches from its sources.
    private(set) var findPending = false
    /// Incremented to ask the find field to take focus (and select all when `findSelectAll`).
    private(set) var findFocusTick = 0
    private(set) var findSelectAll = false

    // MARK: going to a dictionary

    /// The list of the page's dictionaries is open, with its line under the word.
    private(set) var indexing = false
    var indexQuery = "" {
        didSet { if indexing && indexQuery != oldValue { article?.indexQuery(indexQuery) } }
    }
    /// The selected dictionary's name, as ⌘J's list shows it.
    private(set) var indexName = ""
    /// How many dictionaries the typing matches, of how many answered the word.
    private(set) var indexMatches = 0
    private(set) var indexTotal = 0
    /// Incremented to ask the line's field to take focus.
    private(set) var indexFocusTick = 0

    /// The entry the reader is on, as the page reports it, for Go › Hide and Show.
    var current: CurrentEntry?

    /// The page has a selection in one entry, for File › Share as Image.
    var canShare = false

    /// A passing word to the reader, in the window's corner; it leaves on its own.
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // MARK: saved words

    /// Saved words and link keys, newest first.
    private(set) var saved: [String]
    /// The saved words as the home page listed them before any was removed there. A word
    /// removed on the home page keeps its place, struck through, until the page is left,
    /// so ⌘D or a right-click puts it back where it was.
    private var keptOnHome: [String]?
    /// The saved words the home page lists, removed ones included.
    var savedOnHome: [String] { keptOnHome ?? saved }

    // MARK: home

    /// The home page lists every saved word, not just the newest.
    var savedExpanded = false
    /// What ↑↓ from the empty search line are on.
    private(set) var homeSelection: HomeItem?
    /// Each time the app is put away, the next visit opens a calm home page: folded, at the top.
    private(set) var homeVisit = 0
    /// The home word last opened this visit, where coming back lands.
    @ObservationIgnored private var homeReturn: HomeItem?

    // MARK: library

    private(set) var dictionaries: [DictSummary] = []
    /// Folders and files dictionaries are read from, as Settings lists them.
    private(set) var roots: [String] = []
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
    /// Where to land on the next display of `word` (a followed link, or Back/Forward).
    @ObservationIgnored private var pendingLanding: (word: String, landing: Landing)?
    /// The reading position the article view last reported, for the word it showed.
    @ObservationIgnored private var reading: (word: String, place: Place?)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    /// The query `suggestions` belong to: Return waits for them to catch up with the typing.
    @ObservationIgnored private var suggestedFor = ""
    /// The library changed while find or ⌘J's list was open; the page refreshes when they close.
    @ObservationIgnored private var refreshWhenFree = false
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var lastGeneration: UInt64 = 0
    @ObservationIgnored private var lastReadyIDs: Set<String> = []
    @ObservationIgnored private var pendingResume: Visit?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SuperGloss", isDirectory: true)
            .appendingPathComponent("Indexes", isDirectory: true)
        engine = Engine(cacheDirectory: caches)
        audio = AudioPlayer(engine: engine)
        history = prefs.history
        saved = prefs.saved
        roots = prefs.roots
        zoom = prefs.zoom
        applyConfiguration()
        // Esc, the hotkey and ⌘H all hide the app; that ends a visit.
        NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.endHomeVisit() }
        }
    }

    // MARK: configuration

    func applyConfiguration() {
        engine.configure(roots: prefs.roots, order: prefs.order, disabled: prefs.disabled)
        refreshDictionaries()
        startPolling()
    }

    func addRoots(_ urls: [URL]) {
        for u in urls where !roots.contains(u.path) {
            roots.append(u.path)
        }
        prefs.roots = roots
        applyConfiguration()
    }

    func removeRoot(_ path: String) {
        roots.removeAll { $0 == path }
        prefs.roots = roots
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
            finishResume()
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
        // Re-showing would close find or ⌘J's list under the reader: wait until they're done.
        if finding || indexing {
            refreshWhenFree = true
            return
        }
        // The reader stays where they were in the entries.
        if let r = reading, r.word == shown?.word, let place = r.place {
            pendingLanding = (r.word, .place(place))
        }
        // A word the reader committed stays. The first suggestion while typing was only the
        // best match among the dictionaries ready then: choose again ("nhà", not "nhang").
        if let c = committed, label(c) == query {
            search(show: c, force: true)
        } else if selected == 0 {
            search(show: nil, force: true)
        } else {
            search(show: selected > 0 && selected < suggestions.count ? suggestions[selected].word : shown?.word, force: true)
        }
    }

    private func refreshIfWaiting() {
        guard refreshWhenFree else { return }
        refreshWhenFree = false
        refreshCurrent()
    }

    // MARK: searching

    private func search(show pinned: String?, force: Bool = false) {
        searchTask?.cancel()
        previewTask?.cancel()
        refreshWhenFree = false
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
        // A known word (a link, Back, history) needn't wait for its suggestions.
        if let pinned { lookUp(pinned, delay: .zero, force: force) }
        searchTask = Task {
            let s = await Task.detached(priority: .userInitiated) { engine.suggest(q) }.value
            guard !Task.isCancelled, q == self.query else { return }
            self.suggestions = s
            self.suggestedFor = q
            if let pinned {
                self.selected = s.firstIndex { $0.word.lowercased() == pinned.lowercased() } ?? -1
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
        // Find belongs to the word it was opened on; a different word closes it.
        if finding && r?.word != shown?.word { endFind(refocus: false) }
        if indexing && r?.word != shown?.word { endIndex(.stay, refocus: false) }
        shown = r
        noResults = r.map { $0.hits.isEmpty } ?? false
        var landing: Landing?
        if let p = pendingLanding, p.word == r?.word {
            landing = p.landing
            pendingLanding = nil
        }
        article?.show(r?.hits.isEmpty == false ? r : nil, dictionaries: dictionaries, landing: landing)
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
        // Return right after a keystroke: the strip still holds the last query's words.
        if !query.isEmpty, suggestedFor != query, let pending = searchTask {
            Task {
                await pending.value
                if self.suggestedFor == self.query { self.submit() }
            }
            return
        }
        if query.isEmpty, let item = homeSelection {
            open(item)
        } else if selected >= 0 && selected < suggestions.count {
            commit(suggestions[selected].word)
        } else if let w = shown?.word, !(shown?.hits.isEmpty ?? true) {
            commit(w)
        } else {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { commit(q) }
        }
    }

    /// Follows a cross-reference clicked inside dictionary `dict`: "above_1" opens
    /// "above"; "@topic_…" pages get a readable search line. The view lands in the
    /// same dictionary, on what the link's text (`text`) names.
    func follow(_ target: String, text: String?, from dict: String) {
        let engine = engine
        linkTask?.cancel()
        linkTask = Task {
            let link = await Task.detached(priority: .userInitiated) { engine.resolveLink(dict: dict, target: target) }.value
            guard !Task.isCancelled else { return }
            let find = text.flatMap { $0.isEmpty ? nil : $0 }
            self.commit(link.word, landing: dict.isEmpty ? nil : .anchor(dict: dict, id: link.anchor, find: find))
        }
    }

    /// The search-line text for a committed word or link key.
    func label(_ word: String) -> String { engine.label(word) }

    /// The article view reports where the reader is (nil: at the top).
    func noteReading(_ word: String, _ place: Place?) {
        reading = (word, place)
    }

    private func visit(_ word: String) -> Visit {
        Visit(word: word, place: reading?.word == word ? reading?.place : nil)
    }

    /// Looks up `word` as a deliberate navigation (links, history, services).
    func commit(_ word: String, landing: Landing? = nil) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        pendingResume = nil
        if let c = committed, c != w {
            backStack.append(visit(c))
            if backStack.count > 200 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        committed = w
        record(w)
        navigate(to: w, landing: landing)
    }

    private func navigate(to word: String, landing: Landing?) {
        pendingLanding = landing.map { (word, $0) }
        // Landing in the article already on screen still has to re-show it.
        setQuery(label(word), show: word, force: landing != nil)
        requestFocus(selectAll: true)
    }

    /// A fresh page (first load, a reopened window, a reload): what it should show, and where.
    /// Find and ⌘J's list belonged to the page that went.
    func pageLoaded() -> (LookupResult?, Landing?) {
        endFind(refocus: false)
        endIndex(.stay, refocus: false)
        let place = reading.flatMap { $0.word == shown?.word ? $0.place : nil }
        return (shown, place.map(Landing.place))
    }

    /// The word on screen and the place in it, for a relaunch to come back to.
    var resumePoint: Visit? { shown.map { visit($0.word) } }

    /// Opens `v` as it was left, without making it a new step in history. Waits for the
    /// library to finish opening (two seconds at most), so the page lands once, with every
    /// dictionary on it.
    func resume(_ v: Visit) {
        pendingResume = v
        if !dictionaries.isEmpty && busy.isEmpty {
            finishResume()
        } else {
            Task {
                try? await Task.sleep(for: .seconds(2))
                finishResume()
            }
        }
    }

    private func finishResume() {
        guard let v = pendingResume else { return }
        pendingResume = nil
        committed = v.word
        navigate(to: v.word, landing: v.place.map(Landing.place))
    }

    func lookUpExternally(_ word: String) {
        openMainWindow?()
        commit(word)
    }

    private func setQuery(_ q: String, show word: String?, force: Bool = false) {
        programmatic = true
        query = q
        programmatic = false
        search(show: word, force: force)
    }

    /// Esc, ⇧⌘H or the line's clear button: back to the home page.
    func clear() {
        if query.isEmpty { return }
        query = ""
        requestFocus(selectAll: false)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        if let c = committed { forwardStack.append(visit(c)) }
        committed = prev.word
        navigate(to: prev.word, landing: prev.place.map(Landing.place))
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let c = committed { backStack.append(visit(c)) }
        committed = next.word
        navigate(to: next.word, landing: next.place.map(Landing.place))
    }

    /// A word worth meeting that you have not looked up or saved yet.
    func surprise() {
        let engine = engine
        let met = Set((history + saved).map { $0.lowercased() })
        Task {
            let word = await Task.detached(priority: .userInitiated) { () -> String? in
                var last: String?
                for _ in 0..<4 {
                    guard let w = engine.randomWord() else { break }
                    if !met.contains(w.lowercased()) { return w }
                    last = w
                }
                return last
            }.value
            if let word { self.commit(word) } else { NSSound.beep() }
        }
    }

    func requestFocus(selectAll: Bool) {
        self.selectAll = selectAll
        focusTick &+= 1
    }

    /// ↑↓, ⌘↑↓, Page Up and Down, Home and End typed in the search line scroll the entries,
    /// as they would a document, and the line keeps the focus and its selected word.
    func scrollPage() -> Bool {
        guard canFind, let key = NSApp.currentEvent, key.type == .keyDown || key.type == .keyUp else { return false }
        article?.scroll(with: key)
        return true
    }

    /// A character typed while the article had focus.
    func typed(_ key: String) {
        // ↑↓ scroll the page by themselves; it sends them only while ⌘J's list is open.
        switch key {
        case "ArrowDown", "ArrowUp":
            if indexing { indexMove(key == "ArrowDown" ? 1 : -1) }
            return
        case "AltArrowDown", "AltArrowUp":
            if !finding && !indexing { moveSelection(key == "AltArrowDown" ? 1 : -1) }
            return
        default:
            break
        }
        if indexing {
            switch key {
            case "Escape": endIndex(.back)
            case "Enter", "ShiftEnter": endIndex(.pick)
            default:
                indexQuery += key
                indexFocusTick &+= 1
            }
            return
        }
        if finding {
            switch key {
            case "Escape": endFind()
            case "Enter": findStep(1)
            case "ShiftEnter": findStep(-1)
            default:
                findQuery += key
                findSelectAll = false
                findFocusTick &+= 1
            }
            return
        }
        if key == "Enter" || key == "ShiftEnter" { return }
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

    // MARK: find in entries

    /// Whether there is an article to find in.
    var canFind: Bool { !query.isEmpty && shown?.hits.isEmpty == false }

    /// ⌘F: opens the find line (or re-selects it). Without an article, goes to the search line.
    func startFind() {
        guard canFind else {
            requestFocus(selectAll: true)
            return
        }
        if indexing { endIndex(.stay, refocus: false) }
        if !finding {
            finding = true
            findTotal = 0
            findIndex = 0
            findPending = !findQuery.isEmpty
            if findQuery.isEmpty { article?.prepareFind() } else { article?.find(findQuery) }
        }
        findSelectAll = true
        findFocusTick &+= 1
    }

    func endFind(refocus: Bool = true) {
        guard finding else { return }
        finding = false
        findTotal = 0
        findIndex = 0
        findPending = false
        article?.find("")
        if refocus { requestFocus(selectAll: false) }
        refreshIfWaiting()
    }

    /// Next (1) or previous (-1) match; opens the find line if it is closed.
    func findStep(_ direction: Int) {
        guard finding else { return startFind() }
        article?.findStep(direction)
    }

    func noteFind(total: Int, index: Int, pending: Bool) {
        findTotal = total
        findIndex = index
        findPending = pending
    }

    // MARK: going to a dictionary

    /// ⌘J: the list opens where the reader is; ⌘J again closes it, keeping the place.
    /// It opens whenever there is an entry, even from a single dictionary: it then says
    /// so, and typing that runs ahead of the list stays in it instead of replacing the word.
    func startIndex() {
        guard canFind else {
            requestFocus(selectAll: true)
            return
        }
        if indexing { return endIndex(.stay) }
        if finding { endFind(refocus: false) }
        indexQuery = ""
        indexName = ""
        indexMatches = 0
        indexTotal = 0
        indexing = true
        article?.indexOpen()
        indexFocusTick &+= 1
    }

    func endIndex(_ exit: IndexExit, refocus: Bool = true) {
        guard indexing else { return }
        indexing = false
        article?.indexClose(exit)
        if refocus { requestFocus(selectAll: false) }
        refreshIfWaiting()
    }

    func indexMove(_ direction: Int) {
        article?.indexMove(direction)
    }

    /// Next or previous dictionary: through the list while it is open, else down the page.
    func stepSource(_ direction: Int) {
        if indexing { indexMove(direction) } else { article?.jump(direction) }
    }

    /// ⌥⌘← and ⌥⌘→: hides or shows the entry the reader is on, as a click on its name does.
    func hideCurrent(_ hide: Bool) {
        guard canFind else { return }
        article?.hideCurrent(hide)
    }

    /// The page reports the selection, or that it closed the list itself (a click).
    func noteIndex(open: Bool, name: String, matches: Int, total: Int) {
        guard open else {
            if indexing {
                indexing = false
                requestFocus(selectAll: false)
                refreshIfWaiting()
            }
            return
        }
        // The line shows no name (the list does); VoiceOver hears it instead.
        if name != indexName && !name.isEmpty {
            AccessibilityNotification.Announcement(name).post()
        }
        indexName = name
        indexMatches = matches
        indexTotal = total
    }


    func shareAsImage() {
        guard canShare else { return }
        article?.shareAsImage(present: true)
    }

    func tell(_ message: String) {
        notice = message
        AccessibilityNotification.Announcement(message).post()
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { notice = nil }
        }
    }

    // MARK: saved words

    /// The word an article is about: the base form when one was used ("ran" → "run").
    var shownWord: String? {
        guard let r = shown, !r.hits.isEmpty else { return nil }
        return r.via ?? r.word
    }

    func isSaved(_ word: String) -> Bool {
        saved.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    var shownIsSaved: Bool { shownWord.map(isSaved) ?? false }

    /// What ⌘D acts on: the word on screen, or on the home page the word the keyboard is on.
    var focusWord: String? {
        guard query.isEmpty else { return shownWord }
        switch homeSelection {
        case .saved(let w), .recent(let w): return w
        default: return nil
        }
    }

    var focusIsSaved: Bool { focusWord.map(isSaved) ?? false }

    /// ⌘D: saves the word in focus (or `word`), or removes it when it is already saved.
    func toggleSaved(_ word: String? = nil) {
        guard let w = word ?? focusWord else { return }
        isSaved(w) ? unsave(w) : save(w)
    }

    private func save(_ word: String) {
        let same = { (w: String) in w.caseInsensitiveCompare(word) == .orderedSame }
        if let kept = keptOnHome, let i = kept.firstIndex(where: same) {
            // Back in its place among the others.
            saved.insert(word, at: kept[..<i].filter(isSaved).count)
        } else {
            saved.insert(word, at: 0)
            keptOnHome?.insert(word, at: 0)
        }
        prefs.saved = saved
    }

    private func unsave(_ word: String) {
        if query.isEmpty && keptOnHome == nil { keptOnHome = saved }
        saved.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        prefs.saved = saved
    }

    /// Every saved word, one per line, newest first: ready to paste into flashcards.
    func copySaved() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(saved.map(label).joined(separator: "\n"), forType: .string)
    }

    // MARK: home

    /// How many saved words the home page shows before "N more".
    static let savedShown = 24
    static let recentShown = 9

    /// The home page's words in the order ↑↓ walk them.
    var homeItems: [HomeItem] {
        let listed = savedOnHome
        let folded = !savedExpanded && listed.count > Self.savedShown
        var items = listed.prefix(folded ? Self.savedShown : listed.count).map(HomeItem.saved)
        if folded { items.append(.more) }
        return items + history.prefix(Self.recentShown).map(HomeItem.recent)
    }

    /// ↓ from the search line goes onto the first word; ↑ from the first goes back to the line.
    func moveHome(_ d: Int) {
        let items = homeItems
        guard let i = homeSelection.flatMap(items.firstIndex) else {
            if d > 0, let first = items.first { homeSelection = first }
            return
        }
        let n = i + d
        homeSelection = n < 0 ? nil : items[min(n, items.count - 1)]
    }

    func open(_ item: HomeItem) {
        switch item {
        case .saved(let w), .recent(let w):
            homeReturn = item
            commit(w)
        case .more:
            savedExpanded = true
            let listed = savedOnHome
            if homeSelection == .more { homeSelection = listed.indices.contains(Self.savedShown) ? .saved(listed[Self.savedShown]) : nil }
        }
    }

    private func endHomeVisit() {
        keptOnHome = nil
        savedExpanded = false
        homeSelection = nil
        homeReturn = nil
        homeVisit &+= 1
    }

    func clearHistory() {
        history = []
        prefs.history = []
    }

    // MARK: reading

    /// Dictionaries' own icons beside their names (some have none).
    var showIcons: Bool {
        get { prefs.showIcons }
        set {
            prefs.showIcons = newValue
            article?.setIcons(newValue)
        }
    }

    /// The page's zoom (Text Size). Stored, not read through from prefs, so the header,
    /// which lines up with the page's column, follows it.
    var zoom: Double = 1 {
        didSet {
            // On the slider's 5% steps, so steps of 10% from the menu never drift.
            let z = (min(2.0, max(0.7, zoom)) * 20).rounded() / 20
            if z != zoom { zoom = z }
            prefs.zoom = zoom
            article?.setZoom(zoom)
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

    /// Well-known places dictionaries live. Avoids TCC-protected folders
    /// (Documents, Downloads, Desktop) so first launch never prompts.
    static func defaultRoots() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Dictionaries",
            "/Library/Dictionaries/Super Gloss",
            "\(home)/Dictionaries",
            "\(home)/.goldendict/dictionaries",
            "\(home)/.stardict/dic",
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
    var saved: [String] {
        get { d.stringArray(forKey: "saved") ?? [] }
        set { d.set(newValue, forKey: "saved") }
    }
    var zoom: Double {
        get { d.object(forKey: "zoom") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "zoom") }
    }
    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "appearance") }
    }
    var showIcons: Bool {
        get { d.object(forKey: "showIcons") as? Bool ?? true }
        set { d.set(newValue, forKey: "showIcons") }
    }
    var checksForUpdates: Bool {
        get { d.object(forKey: "checksForUpdates") as? Bool ?? true }
        set { d.set(newValue, forKey: "checksForUpdates") }
    }
    var hotKey: HotKeyPreset {
        get { HotKeyPreset(rawValue: d.string(forKey: "hotKey") ?? "") ?? .optionSpace }
        set { d.set(newValue.rawValue, forKey: "hotKey") }
    }
}
