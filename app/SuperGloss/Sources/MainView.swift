import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Layout shared with app.css. From 1100 pt the page has a margin (140, where it lists
/// its dictionaries) + gap (28) + reading column (≤700), centred together; narrower, the
/// reading column is centred alone, and at 760 pt or less it fills the window.
enum Column {
    static let gloss: CGFloat = 140
    static let gap: CGFloat = 28
    static let reading: CGFloat = 700
    static let margin: CGFloat = 28
    /// The narrowest window with room for the margin.
    static let withMargin: CGFloat = 1100

    static func leading(for width: CGFloat) -> CGFloat {
        if width <= 760 { return 18 }
        if width < withMargin { return max(margin, (width - reading) / 2) }
        return max(margin, (width - gloss - gap - reading) / 2) + gloss + gap
    }
}

extension Color {
    /// Exactly the article page background so the window reads as one surface.
    static let paper = Color(nsColor: NSColor(name: "paper") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1)
            : .white
    })
    static let ink = Color(nsColor: NSColor(name: "ink") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.54, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.77, green: 0.28, blue: 0.11, alpha: 1)
    })
}

struct MainView: View {
    @Bindable var model: AppModel
    @FocusState private var fieldFocused: Bool
    @FocusState private var findFocused: Bool
    @FocusState private var indexFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false
    @State private var headerHover = false

    var body: some View {
        GeometryReader { geo in
            let lead = Column.leading(for: geo.size.width)
            VStack(spacing: 0) {
                header(lead: lead)
                ZStack(alignment: .topLeading) {
                    ArticleView(model: model)
                        .opacity(model.query.isEmpty || model.noResults ? 0 : 1)
                    if model.query.isEmpty {
                        Home(model: model)
                            .padding(.leading, lead)
                            .padding(.trailing, Column.margin)
                            .padding(.top, 26)
                            .transition(.opacity)
                    } else if model.noResults {
                        NoResults(query: model.query)
                            .padding(.leading, lead)
                            .padding(.top, 26)
                    }
                }
            }
            .overlay(alignment: .top) { IndexingLine(progress: model.indexingProgress) }
            .overlay(alignment: .topTrailing) { navButtons.padding(.top, 9).padding(.trailing, 14) }
            .overlay { if dropTargeted { DropTarget() } }
            .overlay(alignment: .bottomTrailing) { UpdatePill(updater: .shared) }
        }
        .background(Color.paper)
        .ignoresSafeArea()
        .frame(minWidth: 460, minHeight: 360)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Whenever the window comes forward, the search line is ready for typing —
            // unless the reader was working inside an article.
            guard let w = note.object as? NSWindow, w.identifier?.rawValue.hasPrefix("main") == true else { return }
            if w.firstResponder is WKWebView { return }
            if model.finding { findFocused = true } else if model.indexing { indexFocused = true } else { fieldFocused = true }
        }
        .onChange(of: model.focusTick) {
            fieldFocused = true
            if model.selectAll {
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
        .onChange(of: model.indexFocusTick) {
            indexFocused = true
            // A key typed in the article continues what is in the line.
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil)
            }
        }
        // Going back to the search line keeps the place the list is showing.
        .onChange(of: fieldFocused) {
            if fieldFocused && model.indexing { model.endIndex(.stay, refocus: false) }
        }
        .onChange(of: model.findFocusTick) {
            findFocused = true
            let all = model.findSelectAll
            DispatchQueue.main.async {
                // Re-opening selects the last query, so typing replaces it; a key typed
                // in the article continues it.
                let sel = all ? #selector(NSText.selectAll(_:)) : #selector(NSResponder.moveToEndOfDocument(_:))
                NSApp.sendAction(sel, to: nil, from: nil)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.query.isEmpty)
    }

    private func header(lead: CGFloat) -> some View {
        // With room for the margin, the saved mark sits there, right-aligned with
        // the dictionary names below; in a narrow window it follows the field.
        let inMargin = lead >= Column.gap + SavedMark.width + 8
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SearchField(model: model, focused: $fieldFocused)
                if !inMargin { SavedMark(model: model, reveal: headerHover) }
            }
            .overlay(alignment: .leading) {
                if inMargin {
                    SavedMark(model: model, reveal: headerHover)
                        .offset(x: -(Column.gap + SavedMark.width))
                }
            }
            // The find and index lines take the related words' place, at the same height.
            ZStack(alignment: .leading) {
                if model.finding {
                    FindLine(model: model, focused: $findFocused)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                } else if model.indexing {
                    IndexLine(model: model, focused: $indexFocused)
                } else {
                    WordStrip(model: model)
                        .transition(.opacity)
                }
            }
            .frame(height: 24)
            .opacity(model.query.isEmpty ? 0 : 1)
            .animation(.easeOut(duration: 0.14), value: model.finding)
            .animation(nil, value: model.indexing)
        }
        .padding(.leading, lead)
        .padding(.trailing, Column.margin)
        .padding(.top, 40)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { headerHover = $0 }
    }

    private var navButtons: some View {
        HStack(spacing: 2) {
            NavButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: !model.backStack.isEmpty) { model.goBack() }
            NavButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: !model.forwardStack.isEmpty) { model.goForward() }
        }
        .opacity(model.backStack.isEmpty && model.forwardStack.isEmpty ? 0 : 1)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in AppModel.shared.addRoots([url]) }
            }
        }
        return accepted
    }
}

// MARK: - Search field

struct SearchField: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    static let font = Font.system(size: 30, weight: .regular, design: .serif)

    var body: some View {
        ZStack(alignment: .leading) {
            if let rest = model.completion {
                (Text(model.query).foregroundStyle(.clear) + Text(rest).foregroundStyle(.tertiary))
                    .font(Self.font)
                    .lineLimit(1)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextField("", text: $model.query, prompt: Text("Look up").foregroundStyle(.quaternary))
                .textFieldStyle(.plain)
                .font(Self.font)
                .focused(focused)
                .autocorrectionDisabled()
                .onSubmit { model.submit() }
                // ↑↓ go between dictionaries, the most frequent move; ⌥↑↓ along the related words.
                .onKeyPress(keys: [.downArrow, .upArrow], phases: [.down, .repeat]) { press in
                    let d = press.key == .downArrow ? 1 : -1
                    if press.modifiers.contains(.option) {
                        model.moveSelection(d)
                    } else {
                        model.article?.jump(d)
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    _ = model.acceptCompletion()
                    return .handled
                }
                .onKeyPress(.escape) {
                    if model.query.isEmpty {
                        NSApp.hide(nil)
                    } else {
                        model.clear()
                    }
                    return .handled
                }
                .onKeyPress(keys: [.pageDown, .pageUp], phases: [.down, .repeat]) { press in
                    model.article?.page(press.key == .pageDown ? 1 : -1)
                    return .handled
                }
                .accessibilityLabel("Look up")
        }
        .frame(height: 40)
    }
}

// MARK: - Word strip

struct WordStrip: View {
    let model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    if model.suggestions.first?.kind == "fuzzy" {
                        Text("Did you mean")
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { i, s in
                        StripWord(suggestion: s, selected: i == model.selected, saved: model.isSaved(s.word)) { model.choose(i) }
                            .id(i)
                    }
                }
                .font(.system(size: 13.5))
                .padding(.vertical, 3)
                .padding(.trailing, 40)
            }
            .mask(
                LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .onChange(of: model.selected) {
                guard model.selected >= 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.selected, anchor: .center) }
            }
            .onChange(of: model.suggestions) {
                proxy.scrollTo(0, anchor: .leading)
            }
        }
        .frame(height: 24)
    }
}

struct StripWord: View {
    let suggestion: Suggestion
    let selected: Bool
    var saved = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(suggestion.word)
                .fontWeight(selected ? .medium : .regular)
                .italic(suggestion.kind == "fuzzy")
                .foregroundStyle(color)
                .lineLimit(1)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.ink)
                        .frame(height: 2)
                        .offset(y: 4)
                        .opacity(selected ? 1 : 0)
                }
                // Saved words carry a small mark, like a dot pencilled beside them.
                .overlay(alignment: .topTrailing) {
                    if saved {
                        Circle().fill(Color.ink).frame(width: 4, height: 4).offset(x: 6, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.1), value: selected)
    }

    private var color: Color {
        if selected { return .primary }
        if suggestion.kind == "lemma" { return Color.ink }
        return hover ? .primary : .secondary
    }

    private var help: String {
        let sources = "\(suggestion.sources) source\(suggestion.sources == 1 ? "" : "s")"
        let base = suggestion.kind == "lemma" ? "Base form · in \(sources)" : "In \(sources)"
        return saved ? base + " · saved" : base
    }
}

// MARK: - Find line

/// Find in the entries on screen. Takes the related words' row: the query is
/// underlined like the strip's current word, and the count follows right after it.
struct FindLine: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    private static let prompt = "Find in these entries"

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink)
            FittedField(text: $model.findQuery, prompt: Self.prompt, focused: focused) { press in
                switch press.key {
                case .return: model.findStep(press.modifiers.contains(.shift) ? -1 : 1)
                case .downArrow, .upArrow: model.findStep(press.key == .downArrow ? 1 : -1)
                case .tab: model.findStep(press.modifiers.contains(.shift) ? -1 : 1)
                default: if press.phase == .down { model.endFind() }
                }
                return .handled
            }
            status
                .padding(.leading, 6)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                NavButton(symbol: "chevron.up", help: "Previous match (⇧⌘G)", enabled: model.findTotal > 0) { model.findStep(-1) }
                NavButton(symbol: "chevron.down", help: "Next match (⌘G)", enabled: model.findTotal > 0) { model.findStep(1) }
                NavButton(symbol: "xmark", help: "Done (Esc)", enabled: true) { model.endFind() }
            }
        }
        .font(.system(size: 13.5))
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        if model.findQuery.isEmpty || (model.findPending && model.findTotal == 0) {
            EmptyView()
        } else if model.findTotal == 0 {
            Text("No matches").foregroundStyle(.secondary)
        } else if model.findIndex > 0 {
            Text("\(model.findIndex) of \(model.findTotal)").foregroundStyle(.tertiary).monospacedDigit()
        } else {
            Text("\(model.findTotal) \(model.findTotal == 1 ? "match" : "matches")").foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

/// A plain field exactly as wide as its text, so what follows reads as part of the
/// line, underlined like the strip's current word. Takes Return, ↑↓, Tab and Esc.
struct FittedField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding
    let onKey: (KeyPress) -> KeyPress.Result

    var body: some View {
        Text(text.isEmpty ? prompt : text)
            .lineLimit(1)
            .padding(.trailing, 3)
            .hidden()
            .frame(minWidth: 24, maxWidth: 380, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .leading) {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .autocorrectionDisabled()
                    .onKeyPress(keys: [.return, .downArrow, .upArrow, .escape, .tab], phases: [.down, .repeat], action: onKey)
                    .accessibilityLabel(prompt)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color.ink)
                    .frame(height: 2)
                    .offset(y: 4)
                    .opacity(text.isEmpty ? 0.3 : 1)
            }
    }
}

// MARK: - Index line

/// Going to a dictionary (⌘J). The page lists every dictionary in the margin; this
/// line takes the typing that narrows it and names the one selected, in full.
struct IndexLine: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    private static let prompt = "Go to a dictionary"

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "books.vertical")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink)
            FittedField(text: $model.indexQuery, prompt: Self.prompt, focused: focused) { press in
                switch press.key {
                case .downArrow, .upArrow: model.indexMove(press.key == .downArrow ? 1 : -1)
                case .tab: model.indexMove(press.modifiers.contains(.shift) ? -1 : 1)
                case .return: if press.phase == .down { model.endIndex(.pick) }
                default: if press.phase == .down { model.endIndex(.back) }
                }
                return .handled
            }
            status
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 6)
            Spacer(minLength: 8)
        }
        .font(.system(size: 13.5))
        .padding(.vertical, 3)
    }

    /// Silent while the list says it all; speaks when the dictionary isn't there.
    @ViewBuilder private var status: some View {
        if model.indexTotal == 1 {
            Text("Only in \(model.indexName)").foregroundStyle(.secondary)
        } else if !model.indexQuery.isEmpty && model.indexMatches == 0 {
            Text("Not among the \(model.indexTotal) dictionaries for this word").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Saved mark

/// Saves the word on screen. A bookmark in the margin beside the word: filled in
/// the accent when saved, otherwise shown only while the pointer is over the header.
struct SavedMark: View {
    let model: AppModel
    let reveal: Bool
    static let width: CGFloat = 22
    @State private var hover = false

    var body: some View {
        let saved = model.shownIsSaved
        let present = model.shownWord != nil
        Button { model.toggleSaved() } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(saved ? AnyShapeStyle(Color.ink) : AnyShapeStyle(hover ? .secondary : .tertiary))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.down, value: model.saveTick)
                .frame(width: Self.width, height: 40, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(present && (saved || reveal || hover) ? 1 : 0)
        .allowsHitTesting(present)
        .onHover { hover = $0 }
        .help(saved ? "Saved — click to remove (⌘D)" : "Save this word (⌘D)")
        .animation(.easeOut(duration: 0.15), value: reveal)
        .animation(.easeOut(duration: 0.15), value: saved)
        .accessibilityLabel(saved ? "Remove from saved" : "Save this word")
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(hover && enabled ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - States

struct Home: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.dictionaries.isEmpty {
                Onboarding(model: model)
            } else {
                if !model.saved.isEmpty {
                    SavedWords(model: model)
                }
                if !model.history.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Label2("Recent")
                        ForEach(model.history.prefix(9), id: \.self) { w in
                            HomeLink(text: model.label(w)) { model.commit(w) }
                        }
                    }
                }
                HStack(spacing: 18) {
                    SurpriseButton { model.surprise() }
                    Button { openWindow(id: "shortcuts") } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "command")
                            Text("Shortcuts")
                        }
                        .foregroundStyle(.secondary)
                    }
                    .help("Every keyboard shortcut (⌘/)")
                }
                .font(.system(size: 13))
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                LibraryStatus(model: model)
            }
        }
        .frame(maxWidth: Column.reading, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 24)
    }
}

/// Home: saved words set as a flowing line of text, newest first.
struct SavedWords: View {
    let model: AppModel
    @State private var expanded = false
    private static let shown = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label2("Saved")
            Flow(spacing: 18, lineSpacing: 4) {
                ForEach(expanded ? model.saved : Array(model.saved.prefix(Self.shown)), id: \.self) { w in
                    HomeLink(text: model.label(w)) { model.commit(w) }
                        .contextMenu {
                            Button("Remove from Saved") { model.unsave(w) }
                        }
                }
                if !expanded && model.saved.count > Self.shown {
                    Button("\(model.saved.count - Self.shown) more") { expanded = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ink)
                        .frame(height: 25)
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping like words in a paragraph.
struct Flow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, arrange(width: bounds.width, subviews).origins) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return (origins, CGSize(width: widest, height: y + line))
    }
}

struct Label2: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// The die rolls to a new face whenever the pointer comes near.
struct SurpriseButton: View {
    let action: () -> Void
    @State private var face = Int.random(in: 1...6)
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "die.face.\(face)")
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text("Surprise me")
            }
            .foregroundStyle(Color.ink)
        }
        .onHover { inside in
            guard inside else { return }
            face = (face + Int.random(in: 0...4)) % 6 + 1
        }
        .help("A word worth meeting from your library (⌘R)")
    }
}

struct HomeLink: View {
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 19, design: .serif))
                .foregroundStyle(hover ? .primary : .secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct LibraryStatus: View {
    let model: AppModel
    var body: some View {
        let ready = model.dictionaries.filter { $0.isReady && $0.enabled }
        let words = ready.reduce(UInt64(0)) { $0 + $1.entries }
        let busy = model.busy
        VStack(alignment: .leading, spacing: 3) {
            if let b = busy.first {
                Text("Preparing \(b.shortName)\(busy.count > 1 ? " and \(busy.count - 1) more" : "")…")
            }
            Text("\(ready.count) source\(ready.count == 1 ? "" : "s") · \(words.formatted()) headwords")
            let failed = model.dictionaries.filter { $0.state == "failed" }
            if !failed.isEmpty {
                Text("\(failed.count) could not be opened — see Settings")
                    .foregroundStyle(Color.ink)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.tertiary)
    }
}

struct Onboarding: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.busy.isEmpty ? "Bring your dictionaries" : "Looking for dictionaries…")
                .font(.system(size: 22, design: .serif))
            Text("Drop dictionary files or folders anywhere in this window. Super Gloss reads MDict, StarDict, ABBYY Lingvo DSL, Babylon, dictd and XDXF — with their sounds and pictures.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
            Button("Choose Folder…") { chooseDictionaries() }
                .controlSize(.large)
                .padding(.top, 4)
        }
    }
}

@MainActor
func chooseDictionaries() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.allowsMultipleSelection = true
    p.prompt = "Add"
    p.message = "Choose dictionary files or folders that contain them."
    if p.runModal() == .OK {
        AppModel.shared.addRoots(p.urls)
    }
}

struct NoResults: View {
    let query: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No entry for “\(query)”")
                .font(.system(size: 19, design: .serif))
                .foregroundStyle(.secondary)
            Text("Try fewer letters, or * and ? as wildcards.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

struct IndexingLine: View {
    let progress: Double?
    var body: some View {
        GeometryReader { g in
            if let p = progress {
                Rectangle()
                    .fill(Color.ink.opacity(0.75))
                    .frame(width: max(8, g.size.width * p), height: 2)
                    .animation(.easeOut(duration: 0.3), value: p)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

struct DropTarget: View {
    var body: some View {
        ZStack {
            Color.paper.opacity(0.85)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.ink, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(18)
            VStack(spacing: 6) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 28, weight: .light))
                Text("Add to your library")
                    .font(.system(size: 17, design: .serif))
            }
            .foregroundStyle(Color.ink)
        }
        .allowsHitTesting(false)
    }
}
