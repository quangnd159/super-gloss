import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Layout shared with app.css: a gloss column (140) + gap (28) + reading column (≤700),
/// centred, collapsing to a single column under 760 pt.
enum Column {
    static let gloss: CGFloat = 140
    static let gap: CGFloat = 28
    static let reading: CGFloat = 700
    static let margin: CGFloat = 28

    static func leading(for width: CGFloat) -> CGFloat {
        if width <= 760 { return 18 }
        let total = gloss + gap + reading
        return max(margin, (width - total) / 2) + gloss + gap
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
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

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
            if !(w.firstResponder is WKWebView) { fieldFocused = true }
        }
        .onChange(of: model.focusTick) {
            fieldFocused = true
            if model.selectAll {
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.query.isEmpty)
    }

    private func header(lead: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SearchField(model: model, focused: $fieldFocused)
            WordStrip(model: model)
                .opacity(model.query.isEmpty ? 0 : 1)
        }
        .padding(.leading, lead)
        .padding(.trailing, Column.margin)
        .padding(.top, 40)
        .padding(.bottom, 6)
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
                .onKeyPress(keys: [.downArrow, .upArrow], phases: [.down, .repeat]) { press in
                    let d = press.key == .downArrow ? 1 : -1
                    if press.modifiers.contains(.option) {
                        model.article?.jump(d)
                    } else {
                        model.moveSelection(d)
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
                        StripWord(suggestion: s, selected: i == model.selected) { model.choose(i) }
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
        switch suggestion.kind {
        case "lemma": "Base form · in \(suggestion.sources) source\(suggestion.sources == 1 ? "" : "s")"
        default: "In \(suggestion.sources) source\(suggestion.sources == 1 ? "" : "s")"
        }
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
                if !model.history.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Label2("Recent")
                        ForEach(model.history.prefix(9), id: \.self) { w in
                            HomeLink(text: w) { model.commit(w) }
                        }
                    }
                }
                HStack(spacing: 18) {
                    Button { model.surprise() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "die.face.5")
                            Text("Surprise me")
                        }
                        .foregroundStyle(Color.ink)
                    }
                    .help("A random word from your library (⌘R)")
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
