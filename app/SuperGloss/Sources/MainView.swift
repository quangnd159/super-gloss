import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Layout shared with app.css, in the page's CSS pixels: one reading column (≤700),
/// centred, never closer than 18 to the window's edges. Text Size zooms the page, making
/// a CSS pixel `zoom` points wide, so the header works in the same pixels to stay on the
/// column's line at every size.
enum Column {
    static let reading: CGFloat = 700
    static let margin: CGFloat = 18

    /// The room a scroll bar keeps at the window's right edge: none when scroll bars float
    /// over the content (trackpads), the bar's width when they always show (a mouse, or
    /// Show scroll bars: Always). The page keeps the same room (app.css).
    static var gutter: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// The reading column's left edge and width, in points, in a window `width` points wide.
    static func frame(for width: CGFloat, zoom: CGFloat, gutter: CGFloat) -> (lead: CGFloat, width: CGFloat) {
        let w = (width - gutter) / zoom
        let lead = max(margin, (w - reading) / 2)
        let column = min(reading, w - 2 * lead)
        return (lead * zoom, max(0, column) * zoom)
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
    @State private var gutter = Column.gutter

    var body: some View {
        GeometryReader { geo in
            let column = Column.frame(for: geo.size.width, zoom: model.zoom, gutter: gutter)
            let lead = column.lead
            VStack(spacing: 0) {
                header(lead: lead, width: column.width)
                ZStack(alignment: .topLeading) {
                    ArticleView(model: model)
                        .opacity(model.query.isEmpty || model.noResults ? 0 : 1)
                    if model.query.isEmpty {
                        Home(model: model, lead: lead)
                    } else if model.noResults {
                        NoResults(query: model.query)
                            .padding(.leading, lead)
                            .padding(.top, 26)
                    }
                }
            }
            .overlay(alignment: .top) { IndexingLine(progress: model.indexingProgress) }
            .overlay(alignment: .topTrailing) { navButtons.padding(.trailing, 13) }
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
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            gutter = Column.gutter // a mouse plugged in or out
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
    }

    private func header(lead: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // The search line ends at the column's right edge, at every size, with its
            // controls: clear it, save the word, go to one of the dictionaries that answered.
            HStack(spacing: 8) {
                SearchField(model: model, focused: $fieldFocused)
                // Wide targets that meet, with no dead gap between them.
                HStack(spacing: 0) {
                    ClearButton(model: model, reveal: headerHover)
                    SavedMark(model: model, reveal: headerHover)
                }
                SourcesButton(model: model)
            }
            // The find and index lines take the related words' place, at the same height.
            ZStack(alignment: .leading) {
                if model.finding {
                    FindLine(model: model, focused: $findFocused)
                } else if model.indexing {
                    IndexLine(model: model, focused: $indexFocused)
                } else {
                    WordStrip(model: model)
                }
            }
            .frame(height: 24)
            .opacity(model.query.isEmpty ? 0 : 1)
        }
        // As wide as the column below: the related words end where its text does.
        .frame(width: width, alignment: .leading)
        .padding(.leading, lead)
        .padding(.top, 40)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { headerHover = $0 }
    }

    private var navButtons: some View {
        HStack(spacing: 0) {
            NavButton(symbol: "chevron.left", label: "Back", help: "Back (⌘[)", enabled: !model.backStack.isEmpty) { model.goBack() }
            NavButton(symbol: "chevron.right", label: "Forward", help: "Forward (⌘])", enabled: !model.forwardStack.isEmpty) { model.goForward() }
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
                // Only while it fits: past the field's width the text scrolls, the ghost wouldn't.
                ViewThatFits(in: .horizontal) {
                    (Text(model.query).foregroundStyle(.clear) + Text(rest).foregroundStyle(.tertiary))
                        .font(Self.font)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 2)
                    Color.clear.frame(width: 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            TextField("", text: $model.query, prompt: Text("Look up").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(Self.font)
                .focused(focused)
                .autocorrectionDisabled()
                .onSubmit { model.submit() }
                // On the home page ↑↓ walk its words; ⌥↑↓ go along the related words. Otherwise
                // the keys that scroll a document scroll the entries (below).
                .onKeyPress(keys: [.downArrow, .upArrow], phases: [.down, .repeat, .up]) { press in
                    let d = press.key == .downArrow ? 1 : -1
                    if model.query.isEmpty {
                        if press.phase != .up { model.moveHome(d) }
                    } else if press.modifiers.contains(.option) {
                        if press.phase != .up { model.moveSelection(d) }
                    } else if press.modifiers.contains(.shift) || !model.scrollPage() {
                        return .ignored
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    model.acceptCompletion() ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    if model.query.isEmpty {
                        NSApp.hide(nil)
                    } else {
                        model.clear()
                    }
                    return .handled
                }
                .onKeyPress(keys: [.pageDown, .pageUp, .home, .end], phases: [.down, .repeat, .up]) { _ in
                    model.scrollPage() ? .handled : .ignored
                }
                .accessibilityLabel("Look up")
        }
        .frame(height: 40)
    }
}

// MARK: - Word strip

struct WordStrip: View {
    let model: AppModel
    /// How far the row runs past each edge, so each fades only where there is more.
    @State private var beyond = Beyond()

    struct Beyond: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

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
            .onScrollGeometryChange(for: Beyond.self) { g in
                Beyond(leading: min(32, max(0, g.contentOffset.x)).rounded(),
                       trailing: min(96, max(0, g.contentSize.width - g.contentOffset.x - g.containerSize.width)).rounded())
            } action: { _, new in
                beyond = new
            }
            // Each fade grows with what lies past its edge: none at rest on the left, none
            // once the last word is in view on the right.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: beyond.leading)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: beyond.trailing)
                }
            }
            .background(SidewaysWheel())
            .onChange(of: model.selected) {
                guard model.selected >= 0 else { return }
                proxy.scrollTo(model.selected, anchor: .center)
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
                .italic(suggestion.kind == "fuzzy")
                .foregroundStyle(color)
                .lineLimit(1)
                .selectionMark(selected, below: 4)
                // Saved words carry a small mark, like a dot pencilled beside them.
                .overlay(alignment: .topTrailing) {
                    if saved {
                        Circle().fill(Color.ink).frame(width: 4, height: 4).offset(x: 6, y: 1)
                    }
                }
                .largerTarget(horizontal: 8, vertical: 4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    private var color: Color {
        if selected { return .primary }
        if suggestion.kind == "lemma" { return Color.ink }
        return hover ? .primary : .secondary
    }

    private var help: String {
        let sources = "\(suggestion.sources) dictionar\(suggestion.sources == 1 ? "y" : "ies")"
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
            HStack(spacing: 0) {
                NavButton(symbol: "chevron.up", label: "Previous match", help: "Previous match (⇧⌘G)", enabled: model.findTotal > 0) { model.findStep(-1) }
                NavButton(symbol: "chevron.down", label: "Next match", help: "Next match (⌘G)", enabled: model.findTotal > 0) { model.findStep(1) }
                NavButton(symbol: "xmark", label: "Done", help: "Done (Esc)", enabled: true) { model.endFind() }
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
            Text("\(model.findIndex) of \(model.findTotal)").foregroundStyle(.secondary).monospacedDigit()
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

/// Going to a dictionary (⌘J). The page lists every dictionary as a contents page; this
/// line takes the typing that narrows it.
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

/// A wheel mouse scrolls only up and down. Over a row that scrolls sideways, its turns move
/// the row instead, as they do with Shift held. Trackpads already scroll both ways.
struct SidewaysWheel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WheelView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WheelView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0
                else { return event }
                let point = event.locationInWindow
                let number = event.windowNumber
                let over = MainActor.assumeIsolated { self?.covers(point, inWindow: number) ?? false }
                return over ? Self.sideways(event) : event
            }
        }

        private func covers(_ point: NSPoint, inWindow number: Int) -> Bool {
            window?.windowNumber == number && bounds.contains(convert(point, from: nil))
        }

        private nonisolated static func sideways(_ event: NSEvent) -> NSEvent {
            guard let cg = event.cgEvent?.copy() else { return event }
            for (down, across) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis2),
                                   (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)] {
                cg.setIntegerValueField(across, value: cg.getIntegerValueField(down))
                cg.setIntegerValueField(down, value: 0)
            }
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            return NSEvent(cgEvent: cg) ?? event
        }
    }
}

// MARK: - Clear button

/// Esc for the mouse: empties the search line, back to the home page. Shown, like the
/// saved mark beside it, while the pointer is over the header.
struct ClearButton: View {
    let model: AppModel
    let reveal: Bool
    @State private var hover = false

    var body: some View {
        let present = !model.query.isEmpty
        Button { model.clear() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(hover ? .secondary : .tertiary)
                .frame(width: 32, height: 40, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .opacity(present && (reveal || hover) ? 1 : 0)
        .allowsHitTesting(present)
        .accessibilityHidden(!present)
        .onHover { hover = $0 }
        .help("Clear (Esc)")
        .animation(.easeOut(duration: 0.15), value: reveal)
        .accessibilityLabel("Clear")
    }
}

// MARK: - Saved mark

/// Saves the word on screen. A bookmark at the end of the search line: filled in
/// the accent when saved, otherwise shown only while the pointer is over the header.
struct SavedMark: View {
    let model: AppModel
    let reveal: Bool
    @State private var hover = false
    /// Clicks that saved: the mark gives a small bounce for the pointer. ⌘D changes it at once.
    @State private var clicks = 0

    var body: some View {
        let saved = model.shownIsSaved
        let present = model.shownWord != nil
        Button {
            withAnimation(.easeOut(duration: 0.15)) { model.toggleSaved() }
            if model.shownIsSaved { clicks += 1 }
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(saved ? AnyShapeStyle(Color.ink) : AnyShapeStyle(hover ? .secondary : .tertiary))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.down, value: clicks)
                .frame(width: 32, height: 40, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .opacity(present && (saved || reveal || hover) ? 1 : 0)
        .allowsHitTesting(present)
        .accessibilityHidden(!present)
        .onHover { hover = $0 }
        .help(saved ? "Saved — click to remove (⌘D)" : "Save this word (⌘D)")
        .animation(.easeOut(duration: 0.15), value: reveal)
        .accessibilityLabel(saved ? "Remove from saved" : "Save this word")
    }
}

/// ⌘J for the mouse. Says how many dictionaries answered the word, and opens the list
/// of them; in the accent, like the list's own line, while it is open. Always in view
/// when there is somewhere to go, so it is found without knowing the key.
struct SourcesButton: View {
    let model: AppModel
    @State private var hover = false

    var body: some View {
        let count = model.query.isEmpty || model.noResults ? 0 : model.shown?.hits.count ?? 0
        let open = model.indexing
        Button { model.startIndex() } label: {
            // One run of text: the symbol takes the figures' font and weight and centres
            // itself on their cap height, as SF Symbols do inline; the small scale keeps it
            // close to their height, so it neither towers over nor sinks below them.
            Text("\(Image(systemName: "books.vertical")) \(count.formatted())")
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .imageScale(.small)
                .foregroundStyle(open ? AnyShapeStyle(Color.ink) : AnyShapeStyle(hover ? .secondary : .tertiary))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(open ? 0.07 : hover ? 0.05 : 0)))
                // The whole height of the search line takes the click, not just the chip.
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        // The figures sit on the column's edge; the chip reaches into the gutter.
        .padding(.trailing, -8)
        // Kept in place when hidden, so the line doesn't shift as results change while typing.
        // Nothing here animates but the pointer's hover: the count follows typing and ⌘J.
        .opacity(count > 1 ? 1 : 0)
        .allowsHitTesting(count > 1)
        .accessibilityHidden(count < 2)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hover = inside }
        }
        .help(open ? "Back to the entries (⌘J)" : "Go to a dictionary (⌘J)")
        .accessibilityLabel(open ? "Close the list of dictionaries" : "Go to a dictionary")
        .accessibilityValue("\(count) dictionaries")
    }
}

struct NavButton: View {
    let symbol: String
    let label: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(hover && enabled ? 0.07 : 0)))
                // Larger to the pointer than to the eye; neighbours' targets meet.
                .padding(.horizontal, 1)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - States

struct Home: View {
    let model: AppModel
    let lead: CGFloat
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.dictionaries.isEmpty {
            Onboarding(model: model)
                .frame(maxWidth: Column.reading, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, lead)
                .padding(.trailing, Column.margin)
                .padding(.top, 26)
                .padding(.bottom, 24)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // The page scrolls under the header, so a long list of saved words is all there.
                ScrollViewReader { proxy in
                    ScrollView {
                        lists
                            .frame(maxWidth: Column.reading, alignment: .leading)
                            .padding(.leading, lead)
                            .padding(.trailing, Column.margin)
                            .padding(.top, 26)
                            .padding(.bottom, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .mask(EdgeFade())
                    .id(model.homeVisit)
                    .onAppear {
                        // Back from a word opened here: it sits mid-page, among its neighbours.
                        if let item = model.homeSelection { proxy.scrollTo(item, anchor: .center) }
                    }
                    .onChange(of: model.homeSelection) {
                        // nil anchor: the least scrolling that brings the word into view.
                        if let item = model.homeSelection { proxy.scrollTo(item) }
                    }
                }
                LibraryStatus(model: model)
                    .padding(.leading, lead)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
            }
        }
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.savedOnHome.isEmpty {
                SavedWords(model: model)
            }
            if !model.history.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel("Recent")
                    ForEach(model.history.prefix(AppModel.recentShown), id: \.self) { w in
                        HomeLink(text: model.label(w), selected: model.homeSelection == .recent(w)) { model.commit(w) }
                            .scrollTarget(HomeItem.recent(w))
                            .contextMenu {
                                Button(model.isSaved(w) ? "Remove from Saved" : "Save Word") { model.toggleSaved(w) }
                            }
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
        }
    }
}

/// Words fade out where the home page scrolls under its edges.
private struct EdgeFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
    }
}

extension View {
    /// Scrolling to `id` brings this view in clear of the faded edges, underline and all.
    func scrollTarget<ID: Hashable>(_ id: ID) -> some View {
        background(Color.clear.frame(height: 88).id(id))
    }
}

/// Home: saved words set as a flowing line of text, newest first.
struct SavedWords: View {
    let model: AppModel

    var body: some View {
        let all = model.savedOnHome
        let live = Set(model.saved.map { $0.lowercased() })
        let folded = !model.savedExpanded && all.count > AppModel.savedShown
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SectionLabel("Saved")
                Text(live.count.formatted())
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .contextMenu {
                Button("Copy All Saved Words") { model.copySaved() }
            }
            Flow(spacing: 18, lineSpacing: 4) {
                ForEach(folded ? Array(all.prefix(AppModel.savedShown)) : all, id: \.self) { w in
                    let removed = !live.contains(w.lowercased())
                    HomeLink(text: model.label(w), selected: model.homeSelection == .saved(w), removed: removed) { model.commit(w) }
                        .scrollTarget(HomeItem.saved(w))
                        .contextMenu {
                            Button(removed ? "Put Back in Saved" : "Remove from Saved") { model.toggleSaved(w) }
                        }
                }
                if folded {
                    Button { model.open(.more) } label: {
                        Text("\(all.count - AppModel.savedShown) more")
                            .selectionMark(model.homeSelection == .more, below: 3)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink)
                    .frame(height: 25)
                    .scrollTarget(HomeItem.more)
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

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// The die rolls to a new face whenever the pointer comes near.
struct SurpriseButton: View {
    let action: () -> Void
    @State private var face = Int.random(in: 1...6)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                face = (face + Int.random(in: 0...4)) % 6 + 1
            }
        }
        .help("A word worth meeting from your library (⌘R)")
    }
}

struct HomeLink: View {
    let text: String
    var selected = false
    /// Removed from Saved on this visit: struck through, still in its place.
    var removed = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 19, design: .serif))
                .strikethrough(removed)
                .foregroundStyle(removed ? (hover || selected ? .secondary : .tertiary) : (hover || selected ? .primary : .secondary))
                .lineLimit(1)
                .selectionMark(selected, below: 2)
                .largerTarget(horizontal: 9, vertical: 2)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(removed ? "Removed from Saved — right-click to put it back" : "")
    }
}

extension View {
    /// Grows what takes the pointer past what is drawn, leaving the layout as it was.
    func largerTarget(horizontal: CGFloat, vertical: CGFloat) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }

    /// The ink underline under the word the keyboard is on, as in the related words.
    func selectionMark(_ on: Bool, below: CGFloat) -> some View {
        overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.ink)
                .frame(height: 2)
                .offset(y: below)
                .opacity(on ? 1 : 0)
        }
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
            Text("\(ready.count) dictionar\(ready.count == 1 ? "y" : "ies") · \(words.formatted()) headwords")
            let failed = model.dictionaries.filter { $0.state == "failed" }.count
            if failed > 0 {
                SettingsLink {
                    Text("\(failed) dictionar\(failed == 1 ? "y" : "ies") couldn’t be opened")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .help("See why in Settings")
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
            Button("Add Dictionaries…") { chooseDictionaries() }
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
    p.message = "Choose dictionaries, or folders of them: MDict, StarDict, DSL, Babylon, dictd or XDXF."
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
