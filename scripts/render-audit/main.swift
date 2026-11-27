// Renders words the way Super Gloss does, with the app's own Web/ folder over the real
// core, and reports each article frame that scrolls sideways, misses an image, reads in
// the browser's default face, raises a script error or keeps growing. Pages in fixtures/
// stand in for markup the dictionaries at hand don't have. With --cards, each entry is also
// shared as an image twice, as the app does it: a few words must make a card, the whole entry
// a card or the too-long notice. Run it through
// scripts/render-audit.sh, from the repository root.
import AppKit
import WebKit

// ---------- options ----------

var width: CGFloat = 1000
var dark = false
var shots: URL?
var only: String?
var random = 0
var cards = false
var roots: [String] = []
var words: [String] = []
var rest = CommandLine.arguments.dropFirst()
while let a = rest.popFirst() {
    switch a {
    case "--width": width = CGFloat(Double(rest.popFirst() ?? "") ?? 1000)
    case "--dark": dark = true
    case "--cards": cards = true
    case "--shots": shots = URL(fileURLWithPath: rest.popFirst() ?? "shots")
    case "--only": only = rest.popFirst()
    case "--random": random = Int(rest.popFirst() ?? "") ?? 0
    case "--root": roots.append(rest.popFirst() ?? "")
    case "--words": words += ((try? String(contentsOfFile: rest.popFirst() ?? "", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    default: words.append(a)
    }
}
let tool = URL(fileURLWithPath: "scripts/render-audit")
let web = URL(fileURLWithPath: "app/SuperGloss/Web")
let out = URL(fileURLWithPath: "target/render-audit")
if roots.isEmpty { roots = UserDefaults(suiteName: "app.supergloss.SuperGloss")?.stringArray(forKey: "roots") ?? [] }
if words.isEmpty {
    words = (try? String(contentsOf: tool.appendingPathComponent("words.txt"), encoding: .utf8))?
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") } ?? []
}
let fixtures = ((try? FileManager.default.contentsOfDirectory(atPath: tool.appendingPathComponent("fixtures").path)) ?? [])
    .filter { $0.hasSuffix(".html") }.map { String($0.dropLast(5)) }.sorted()

// ---------- the library ----------

func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { sg_free_string(p) }
    return String(cString: p)
}
func json(_ s: String?) -> Any? { s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } }

try? FileManager.default.createDirectory(at: out.appendingPathComponent("cache"), withIntermediateDirectories: true)
let lib = sg_library_new(out.appendingPathComponent("cache").path)!
sg_configure(lib, String(data: try! JSONSerialization.data(withJSONObject: ["roots": roots]), encoding: .utf8)!)
var dicts: [[String: Any]] = []
while true {
    dicts = json(take(sg_dictionaries(lib))) as? [[String: Any]] ?? []
    if dicts.allSatisfy({ ["ready", "error"].contains($0["state"] as? String) }) { break }
    Thread.sleep(forTimeInterval: 0.1)
}
for d in dicts where d["state"] as? String == "error" {
    print("not loaded: \(d["name"] ?? "?"): \(d["error"] ?? "")")
}
for _ in 0..<random { if let w = take(sg_random_word(lib)) { words.append(w) } }
let names = Dictionary(dicts.map { ($0["id"] as! String, $0["name"] as! String) }, uniquingKeysWith: { a, _ in a })

// ---------- the page ----------

final class Host: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    var probes: [[String: Any]] = []
    var ready = false
    var missing: [String] = []
    var frames: [String: WKFrameInfo] = [:]
    var shared: [String: Any]?
    var card: [String: Any]?

    func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        var data: Data?
        var mime = "application/octet-stream"
        // The share card's own files, on the entry's origin, as the app serves them.
        let card = url.host != "app" && url.path.hasPrefix("/__card/")
        switch card ? "app" : url.host {
        case "app":
            data = try? Data(contentsOf: web.appendingPathComponent(card ? "card/" + url.path.dropFirst(8) : url.path))
            mime = ["html": "text/html", "css": "text/css", "js": "text/javascript"][url.pathExtension].map { $0 + "; charset=utf-8" } ?? mime
        case "fixture":
            // Wrapped as Library::article_page wraps an entry.
            let body = (try? String(contentsOf: tool.appendingPathComponent("fixtures\(url.path).html"), encoding: .utf8)) ?? ""
            let cls = url.query ?? "sg-foreign"
            data = Data(("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
                + "<link rel=\"stylesheet\" href=\"sgloss://app/article.css\"></head><body class=\"\(cls) fmt-fixture\">"
                + "<article class=\"sg-entry\">\(body)</article></body></html>").utf8)
            mime = "text/html; charset=utf-8"
        default:
            var len = 0
            var m: UnsafeMutablePointer<CChar>?
            if let p = url.absoluteString.withCString({ sg_serve(lib, $0, &len, &m) }) {
                data = Data(bytes: p, count: len)
                sg_free_bytes(p, len)
                mime = take(m) ?? mime
            }
        }
        if data == nil { missing.append(url.absoluteString) }
        var headers = ["Content-Type": mime]
        // The card's entries are text only, as in the app.
        if w !== view, !card, url.host != "app" { headers["Content-Security-Policy"] = "img-src 'none'; media-src 'none'" }
        task.didReceive(HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data ?? Data())
        task.didFinish()
    }
    func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) {}

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any] else { return }
        if m.name == "probe" { probes.append(b); frames[b["url"] as! String] = m.frameInfo }
        if m.name == "card" { card = b }
        if b["type"] as? String == "loaded" { ready = true }
        if b["type"] as? String == "share" { shared = b }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let host = Host()
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
config.setURLSchemeHandler(host, forURLScheme: "sgloss")
for name in ["sg", "probe"] { config.userContentController.add(host, name: name) }
func script(_ src: String, _ at: WKUserScriptInjectionTime) {
    config.userContentController.addUserScript(WKUserScript(source: src, injectionTime: at, forMainFrameOnly: false))
}
script("window.__probeErrors=[];addEventListener('error',e=>__probeErrors.push(String(e.message||(e.target&&(e.target.src||e.target.href))||'?').slice(0,120)),true);", .atDocumentStart)
script(try! String(contentsOf: web.appendingPathComponent("frame.js"), encoding: .utf8), .atDocumentEnd)
script(try! String(contentsOf: tool.appendingPathComponent("probe.js"), encoding: .utf8), .atDocumentEnd)

// WebKit paints only what it believes is on screen: a window, barely visible, in front.
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
let view = WKWebView(frame: window.contentLayoutRect, configuration: config)
view.setValue(false, forKey: "drawsBackground")
window.appearance = app.appearance
window.contentView = view
window.alphaValue = 0.01
window.ignoresMouseEvents = true
window.level = .floating
window.orderFrontRegardless()
view.load(URLRequest(url: URL(string: "sgloss://app/index.html")!))
// The card's view is never on screen, as in the app (ShareCard).
let cardConfig = WKWebViewConfiguration()
cardConfig.websiteDataStore = config.websiteDataStore
cardConfig.setURLSchemeHandler(host, forURLScheme: "sgloss")
cardConfig.userContentController.add(host, name: "card")
let cardView = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 675), configuration: cardConfig)
cardView.setValue(false, forKey: "drawsBackground")
cardView.appearance = app.appearance

func spin(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        if let e = app.nextEvent(matching: .any, until: min(until, Date().addingTimeInterval(0.01)), inMode: .default, dequeue: true) {
            app.sendEvent(e)
        }
    }
}
func eval(_ js: String, in frame: WKFrameInfo? = nil, on page: WKWebView = view) -> Any? {
    var result: Any?
    var done = false
    page.evaluateJavaScript(js, in: frame, in: .page) { r in result = try? r.get(); done = true }
    while !done { spin(0.01) }
    return result
}
while !host.ready { spin(0.05) }

// ---------- a page per word, then one of fixtures ----------

struct Frame { let word: String; let source: String; let probe: [String: Any]; let growth: Int; let shown: Int }
var frames: [Frame] = []

func render(_ word: String, _ hits: [[String: Any]]) {
    guard !hits.isEmpty else { return }
    host.probes = []
    let payload = try! JSONSerialization.data(withJSONObject: ["word": word, "hits": hits, "icons": false])
    _ = eval("sg.show(\(String(data: payload, encoding: .utf8)!)), 0")
    let deadline = Date().addingTimeInterval(10)
    while host.probes.count < hits.count && Date() < deadline { spin(0.05) }
    // A frame whose height feeds back into its content (100vh) keeps growing.
    let heights = "JSON.stringify(Object.fromEntries([...document.querySelectorAll('iframe')].map(f => [f.src.split('#')[0], f.offsetHeight])))"
    let before = json(eval(heights) as? String) as? [String: Int] ?? [:]
    spin(1.0)
    let after = json(eval(heights) as? String) as? [String: Int] ?? [:]
    for p in host.probes {
        let url = p["url"] as! String
        let source = hits.first { $0["url"] as? String == url }?["name"] as? String ?? url
        frames.append(Frame(word: word, source: source, probe: p, growth: (after[url] ?? 0) - (before[url] ?? 0), shown: after[url] ?? 0))
    }
    if let shots { shoot(word, to: shots) }
}

func shoot(_ word: String, to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let height = min(16000, CGFloat(eval("document.getElementById('col').getBoundingClientRect().bottom + 40") as? Double ?? 900))
    window.setContentSize(NSSize(width: width, height: height))
    view.frame = window.contentLayoutRect
    spin(0.8)
    var done = false
    view.createPDF(configuration: WKPDFConfiguration()) { result in
        defer { done = true }
        guard case let .success(data) = result, let pdf = NSPDFImageRep(data: data) else { return }
        let size = NSSize(width: pdf.bounds.width * 2, height: pdf.bounds.height * 2)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor(white: 0.118, alpha: 1) : .white).setFill()
        NSRect(origin: .zero, size: size).fill()
        pdf.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let file = word.replacingOccurrences(of: "/", with: "_") + "-\(Int(width))\(dark ? "-dark" : "").png"
        try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
    }
    while !done { spin(0.05) }
    window.setContentSize(NSSize(width: width, height: 900))
    view.frame = window.contentLayoutRect
}

// ---------- share as image ----------

struct Card { let word: String; let source: String; let what: String; let ms: Int; let problem: String? }
var made: [Card] = []

// Selects in each frame what `select` sets `r` to, has the page hand it over as it does for
// ⇧⌘I, and makes its card. `fits`: it must be ready, not too long.
func shareCards(_ word: String, _ hits: [[String: Any]]) {
    for hit in hits {
        let url = hit["url"] as! String
        guard let frame = host.frames[url] else { continue }
        for (what, fits, select) in [
            ("a few words", true, "for (const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); w.nextNode();) { const n = w.currentNode, m = /\\p{L}+\\s+\\p{L}+\\s+\\p{L}+/u.exec(n.data); if (m && n.parentElement.getClientRects().length) { r.setStart(n, m.index); r.setEnd(n, m.index + m[0].length); break; } }"),
            ("the whole entry", false, "r.selectNodeContents(document.querySelector('.sg-entry') || document.body)"),
        ] {
            host.shared = nil
            host.card = nil
            guard eval("(() => { const r = document.createRange(); \(select); getSelection().removeAllRanges(); getSelection().addRange(r); return r.collapsed ? 0 : 1; })()", in: frame) as? Int == 1 else { continue }
            _ = eval("[...document.querySelectorAll('iframe')].find((f) => f.src.split('#')[0] === '\(url)').contentWindow.postMessage({ sg: { type: 'share' } }, '*'), 0")
            var deadline = Date().addingTimeInterval(2)
            while host.shared == nil && Date() < deadline { spin(0.01) }
            guard let s = host.shared else {
                made.append(Card(word: word, source: hit["name"] as! String, what: what, ms: 0, problem: "the page didn't hand it over"))
                continue
            }
            var c = URLComponents(string: "sgloss://\(hit["id"]!)/__card/card.html")!
            c.queryItems = [("e", URLComponents(string: url)?.queryItems?.first?.value), ("word", word), ("name", hit["name"] as? String),
                            ("start", s["start"] as? String), ("end", s["end"] as? String), ("text", s["text"] as? String)].map { URLQueryItem(name: $0, value: $1) }
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let t = Date()
            cardView.load(URLRequest(url: c.url!))
            deadline = t.addingTimeInterval(6)
            while host.card == nil && Date() < deadline { spin(0.01) }
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            let state = host.card?["state"] as? String ?? "timed out"
            var problem: String? = state == "ready" || state == "too-long" && !fits ? nil : "\(state) \(host.card?["reason"] ?? "")"
            if state == "ready" {
                // Something marked, between the byline and the mark.
                problem = eval("""
                    (() => {
                      const box = (s) => document.querySelector(s).getBoundingClientRect();
                      const g = box('.grp'), p = [...document.querySelectorAll('.win')].at(-1).getBoundingClientRect();
                      return !(p.height > 0) ? 'no passage' : !(document.querySelector('.rule')?.offsetHeight > 0) ? 'no accent line'
                        : g.top < box('.by').bottom || g.bottom > box('.mark').top ? 'out of its room' : '';
                    })()
                    """, on: cardView) as? String
                if problem == "" { problem = nil }
            }
            made.append(Card(word: word, source: hit["name"] as! String, what: what, ms: ms, problem: problem))
        }
    }
}

for word in words {
    let result = json(take(word.withCString { sg_lookup(lib, $0) })) as? [String: Any] ?? [:]
    let hits = (result["hits"] as? [[String: Any]] ?? []).compactMap { hit -> [String: Any]? in
        let id = hit["dict"] as! String
        if let only, !id.contains(only), !(hit["name"] as! String).localizedCaseInsensitiveContains(only) { return nil }
        let entries = hit["entries"] as! [Int]
        return ["id": id, "name": hit["name"]!, "short": hit["name"]!, "icon": "", "count": entries.count,
                "url": "sgloss://\(id)/?e=" + entries.map(String.init).joined(separator: ",")]
    }
    render(word, hits)
    if cards { shareCards(word, hits) }
}
if only == nil {
    render("fixtures", fixtures.flatMap { f in
        ["sg-foreign", "sg-native"].map { cls in
            ["id": "fixture-\(f)-\(cls)", "name": "\(f) (\(cls.dropFirst(3)))", "short": f, "icon": "", "count": 1,
             "url": "sgloss://fixture/\(f)?\(cls)"]
        }
    })
}

// ---------- report ----------

func list(_ title: String, _ hits: [Frame], _ detail: (Frame) -> String) {
    print("\n\(title): \(hits.count)")
    var seen = Set<String>()
    for f in hits {
        let line = "  \(f.source) · \(f.word) · \(detail(f))"
        if seen.insert(f.source + detail(f)).inserted, seen.count <= 40 { print(line) }
    }
}
let sources = Set(frames.map(\.source)).count
print("\(frames.count) frames from \(sources) sources, \(words.count) words, \(Int(width))px\(dark ? " dark" : "")")
list("Scroll sideways", frames.filter { $0.probe["overflow"] as! Int > 0 }) { "\($0.probe["overflow"]!)px, \($0.probe["culprit"] as? String ?? "?")" }
list("Keep growing", frames.filter { $0.growth > 0 }) { "+\($0.growth)px in 1s" }
list("Cut off", frames.filter { $0.growth == 0 && $0.probe["height"] as! Int > $0.shown + 2 }) { "content \($0.probe["height"]!)px in a \($0.shown)px frame" }
list("Garbled text", frames.filter { $0.probe["garbled"] is String }) { "…\($0.probe["garbled"]!)…" }
list("Default face (Times)", frames.filter { ($0.probe["face"] as! String).hasPrefix("Times") }) { "\($0.probe["face"]!)" }
list("Missing images", frames.filter { !($0.probe["broken"] as! [String]).isEmpty }) { ($0.probe["broken"] as! [String]).prefix(3).joined(separator: " ") }
list("Script errors", frames.filter { !($0.probe["errors"] as! [String]).isEmpty }) { ($0.probe["errors"] as! [String]).prefix(2).joined(separator: " | ") }
if cards {
    let ms = made.map(\.ms).sorted()
    print("\n\(made.count) cards, median \(ms.isEmpty ? 0 : ms[ms.count / 2]) ms, slowest \(ms.last ?? 0) ms")
    let bad = made.filter { $0.problem != nil }
    print("Cards gone wrong: \(bad.count)")
    for c in bad.prefix(40) { print("  \(c.source) · \(c.word) · \(c.what): \(c.problem!)") }
}
if !host.missing.isEmpty {
    print("\nResources not found: \(Set(host.missing).count)")
    for u in Set(host.missing).sorted().prefix(20) { print("  \(names[URL(string: u)?.host ?? ""] ?? "") \(u)") }
}
let report = frames.map { ["word": $0.word, "source": $0.source, "growth": $0.growth].merging($0.probe) { a, _ in a } }
try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("report-\(Int(width))\(dark ? "-dark" : "").json"))
