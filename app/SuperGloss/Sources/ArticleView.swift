import AppKit
import ImageIO
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ArticleView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> ArticleCoordinator { ArticleCoordinator(model: model) }

    func makeNSView(context: Context) -> ArticleWebView {
        let c = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(c, forURLScheme: "sgloss")
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = config.userContentController
        ucc.add(WeakMessageHandler(c), name: "sg")
        if let url = Bundle.main.url(forResource: "frame", withExtension: "js", subdirectory: "Web"),
           let src = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        #if DEBUG
        ucc.addUserScript(WKUserScript(source: ArticleCoordinator.debugSelectScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        #endif
        let web = ArticleWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        web.uiDelegate = c
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.pageZoom = model.zoom
        web.lookUp = { [weak model] w in model?.commit(w) }
        web.share = { [weak c] present in c?.shareAsImage(present: present) }
        c.web = web
        model.article = c
        web.load(URLRequest(url: URL(string: "sgloss://app/index.html")!))
        return web
    }

    func updateNSView(_ nsView: ArticleWebView, context: Context) {}
}

/// WKWebView without browser affordances: no file drops (the window handles
/// dictionary drops), no reload/navigation menu items. Its right-click menu opens with
/// looking up the word under the pointer here, in place of the system's dictionary, and
/// offers a selection to share as an image.
final class ArticleWebView: WKWebView {
    /// The word the page offered as the right-click landed; see frame.js.
    var menuWord = ""
    /// The right-click landed with a selection to share.
    var menuShare = false
    var lookUp: ((String) -> Void)?
    /// Asks the page for its selection, to show the share picker (true) or only to have its card ready.
    var share: ((Bool) -> Void)?

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let drop: Set<String> = [
            "WKMenuItemIdentifierLookUp",
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
            "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
            "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierInspectElement",
        ]
        menu.items.removeAll { drop.contains($0.identifier?.rawValue ?? "") }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        if !menuWord.isEmpty {
            let item = NSMenuItem(title: "Look Up “\(menuWord)”", action: #selector(lookUpMenuWord(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = menuWord
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            menu.insertItem(item, at: 0)
        }
        if menuShare {
            let item = NSMenuItem(title: "Share as Image…", action: #selector(shareSelection(_:)), keyEquivalent: "")
            item.target = self
            if menuWord.isEmpty, !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            menu.insertItem(item, at: menuWord.isEmpty ? 0 : 1)
            // The card is made while the pointer travels to the item.
            share?(false)
        }
        super.willOpenMenu(menu, with: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        menuWord = ""
        menuShare = false
    }

    @objc private func lookUpMenuWord(_ sender: NSMenuItem) {
        if let w = sender.representedObject as? String { lookUp?(w) }
    }

    @objc private func shareSelection(_ sender: NSMenuItem) { share?(true) }
}

/// Breaks the WKUserContentController → handler retain cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

@MainActor
final class ArticleCoordinator: NSObject, ArticleController, WKURLSchemeHandler, WKScriptMessageHandler,
    WKNavigationDelegate, WKUIDelegate
{
    let model: AppModel
    weak var web: WKWebView?
    private var loaded = false
    private var active: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    init(model: AppModel) { self.model = model }

    // MARK: ArticleController

    func show(_ result: LookupResult?, dictionaries: [DictSummary], landing: Landing?) {
        guard let result, !result.hits.isEmpty else {
            run("window.sg && sg.clear()")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: dictionaries.map { ($0.id, $0) })
        let hits: [[String: Any]] = result.hits.map { h in
            let d = byID[h.dict]
            return [
                "id": h.dict,
                "name": d?.name ?? h.name,
                "short": d?.shortName ?? DictSummary.shorten(h.name),
                "url": "sgloss://\(h.dict)/?e=" + h.entries.map(String.init).joined(separator: ","),
                "icon": d?.icon != nil ? "sgloss://app/icon/\(h.dict)" : "",
                "count": h.entries.count,
            ]
        }
        var payload: [String: Any] = ["word": result.word, "hits": hits, "icons": model.showIcons]
        if let via = result.via { payload["via"] = via }
        switch landing {
        case let .anchor(dict, id, find):
            var land: [String: Any] = ["dict": dict]
            if let id { land["id"] = id }
            if let find { land["find"] = find }
            payload["land"] = land
        case let .place(p): payload["land"] = ["dict": p.dict, "offset": p.offset]
        case nil: break
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        run("sg.show(\(json))")
    }

    func jump(_ direction: Int) { run("sg.jump(\(direction))") }
    func scroll(with key: NSEvent) {
        if key.type == .keyUp {
            web?.keyUp(with: key)
        } else {
            run("sg.cancelHold()") // the reader takes over from a position being held
            web?.keyDown(with: key)
        }
    }
    func pronounce() { run("sg.pronounce() || null") }
    func setZoom(_ zoom: Double) { web?.pageZoom = zoom }
    func setIcons(_ on: Bool) { run("sg.icons(\(on))") }
    func hideCurrent(_ hide: Bool) { run("sg.hideCurrent(\(hide))") }

    func find(_ query: String) { run("sg.find(\(Self.literal(query)))") }

    func findStep(_ direction: Int) { run("sg.findStep(\(direction))") }
    func prepareFind() { run("sg.prepareFind()") }

    func indexOpen() { run("sg.indexOpen()") }
    func indexQuery(_ query: String) { run("sg.indexQuery(\(Self.literal(query)))") }
    func indexMove(_ direction: Int) { run("sg.indexMove(\(direction))") }
    func indexClose(_ exit: IndexExit) { run("sg.indexClose('\(exit.rawValue)')") }

    /// A string (or null) as a JavaScript literal.
    private static func literal(_ s: String?) -> String {
        guard let s, let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return "\(json)[0]"
    }

    /// Calls before the page has loaded are dropped: once it has, it shows what is current.
    private func run(_ js: String) {
        guard loaded else { return }
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        // Only the app's own page speaks for the reader. An entry's scripts reach this handler
        // too; all they may say is which word a right-click is on.
        guard type == "menu" || (message.frameInfo.isMainFrame && message.frameInfo.securityOrigin.host == "app") else { return }
        switch type {
        case "loaded":
            // First load, a reopened window, or a reload after WebKit's process quit.
            loaded = true
            let (result, landing) = model.pageLoaded()
            show(result, dictionaries: model.dictionaries, landing: landing)
        case "lookup":
            if let w = body["word"] as? String, !w.isEmpty { model.commit(w) }
        case "find":
            model.noteFind(total: body["total"] as? Int ?? 0, index: body["index"] as? Int ?? 0,
                           pending: body["pending"] as? Bool ?? false)
        case "place":
            if let w = body["word"] as? String {
                let p = body["place"] as? [String: Any]
                let place = (p?["dict"] as? String).flatMap { d in (p?["offset"] as? Double).map { Place(dict: d, offset: $0) } }
                model.noteReading(w, place)
            }
        case "link":
            if let t = body["target"] as? String, let d = body["dict"] as? String, !t.isEmpty {
                model.follow(t, text: body["text"] as? String, from: d)
            }
        case "sound":
            if let d = body["dict"] as? String, let p = body["path"] as? String { model.audio.play(dict: d, path: p) }
        case "open":
            // Only from a click: an entry's script can't send the reader to the web by itself.
            guard let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .leftMouseDown,
                  ProcessInfo.processInfo.systemUptime - e.timestamp < 1 else { break }
            if let s = body["url"] as? String, let u = URL(string: s), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(u)
            }
        case "key":
            if let k = body["key"] as? String { model.typed(k) }
        case "menu":
            (web as? ArticleWebView)?.menuWord = body["word"] as? String ?? ""
            (web as? ArticleWebView)?.menuShare = body["share"] as? Bool ?? false
        case "shareable":
            model.canShare = body["on"] as? Bool ?? false
        case "share":
            share(body)
        case "current":
            model.current = (body["name"] as? String).map { CurrentEntry(name: $0, hidden: body["hidden"] as? Bool ?? false) }
        case "index":
            model.noteIndex(open: body["open"] as? Bool ?? false, name: body["name"] as? String ?? "",
                            matches: body["matches"] as? Int ?? 0, total: body["total"] as? Int ?? 0)
        default:
            break
        }
    }

    // MARK: share as image

    private lazy var cards = ShareCard(schemes: self, store: web?.configuration.websiteDataStore ?? .nonPersistent())
    /// When the reader asked for the picker, for the log.
    private var shareAsked: ContinuousClock.Instant?

    /// The page answers with its selection (`share` below).
    func shareAsImage(present: Bool) {
        if present { shareAsked = .now }
        run("sg.share(\(present))")
    }

    private func share(_ body: [String: Any]) {
        guard let web, let dict = body["dict"] as? String, let word = model.shownWord,
              let hit = model.shown?.hits.first(where: { $0.dict == dict }),
              let start = body["start"] as? String, let end = body["end"] as? String, let text = body["text"] as? String,
              let r = body["rect"] as? [String: Double] else { return }
        let present = body["present"] as? Bool ?? false
        let selection = ShareCard.Selection(
            dict: dict, entries: hit.entries, word: word,
            name: model.dictionaries.first { $0.id == dict }?.shortName ?? DictSummary.shorten(hit.name),
            start: start, end: end, text: text,
            dark: web.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        // CSS px in the page's viewport, to the view's points (the view is flipped).
        let z = web.pageZoom
        let rect = NSRect(x: (r["x"] ?? 0) * z, y: (r["y"] ?? 0) * z, width: (r["w"] ?? 0) * z, height: (r["h"] ?? 0) * z)
        cards.render(selection) { [weak self] outcome in
            // Not over a page the reader has since left for another word.
            guard present, let self, let web = self.web, self.model.shownWord == word else { return }
            switch outcome {
            case let .image(file):
                // Out of sight (scrolled away), it points from the edge of the view it lies past.
                var at = rect.intersection(web.bounds)
                if at.isEmpty {
                    at = NSRect(x: min(max(rect.minX, 0), web.bounds.maxX), y: rect.maxY <= 0 ? 0 : web.bounds.maxY,
                                width: min(rect.width, web.bounds.width), height: 0)
                }
                // The PNG and its file URL, and nothing else: Copy then leaves one pasteboard item carrying both,
                // as a screenshot tool does. `NSItemProvider(contentsOf:)` adds `public.url` too, which Copy writes
                // as items of their own, and a browser pastes the card three times.
                let card = NSItemProvider()
                card.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) {
                    $0(file, false, nil)
                    return nil
                }
                card.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) {
                    $0(file.dataRepresentation, nil)
                    return nil
                }
                NSSharingServicePicker(items: [card]).show(relativeTo: at, of: web, preferredEdge: .maxY)
                if let t = self.shareAsked {
                    Self.log.debug("picker \(Int((ContinuousClock.now - t) / .milliseconds(1))) ms after asking")
                }
            case .tooLong:
                self.model.tell("Select less to share as an image")
            case .failed:
                NSSound.beep()
            }
        }
    }

    private static let log = Logger(subsystem: "app.supergloss.SuperGloss", category: "share")

    // MARK: navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMain = action.targetFrame?.isMainFrame ?? true
        if scheme == "about" { return decisionHandler(.allow) }
        if scheme == "sgloss" {
            if isMain {
                // Only the app shell may occupy the main frame.
                return decisionHandler(url.host == "app" && !loadedShell ? .allow : .cancel)
            }
            return decisionHandler(.allow)
        }
        // Script-driven navigations inside dictionaries (location.href = "sound://…").
        let raw = url.absoluteString
        let frameHost = action.targetFrame?.request.url?.host ?? action.sourceFrame.request.url?.host
        switch scheme {
        case "sound":
            if let host = frameHost { model.audio.play(dict: host, path: String(raw.dropFirst("sound://".count))) }
        case "entry", "bword":
            let target = String(raw.dropFirst(8))
            if !target.hasPrefix("#") {
                model.follow(target.removingPercentEncoding ?? target, text: nil, from: frameHost ?? "")
            }
        case "http", "https", "mailto":
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        default:
            break
        }
        decisionHandler(.cancel)
    }

    private var loadedShell = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedShell = true
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(u)
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        loadedShell = false
        webView.load(URLRequest(url: URL(string: "sgloss://app/index.html")!))
    }

    // MARK: sgloss:// scheme

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(task)
        active[key] = task
        let forCard = webView !== web
        let engine = model.engine
        let iconPath: String? = url.host == "app" && url.path.hasPrefix("/icon/")
            ? model.dictionaries.first { $0.id == url.lastPathComponent }?.icon : nil
        // A queue of its own: an entry's many pictures and sounds never hold up the
        // lookups that typing waits on.
        Self.serving.async {
            // The share card's own files are served on the entry's origin (ShareCard).
            let card = url.host != "app" && url.path.hasPrefix("/__card/")
            let app = url.host == "app" || card
            let served = app ? AppResources.serve(path: card ? "/card/" + url.path.dropFirst(8) : url.path, iconPath: iconPath)
                : engine.serve(url.absoluteString)
            Task { @MainActor in self.finish(key, url: url, served: served, app: app, pictures: !forCard) }
        }
    }

    private static let serving = DispatchQueue(label: "app.supergloss.serve", qos: .userInitiated, attributes: .concurrent)

    /// `pictures` false: for the share card, which is text only, so they are never fetched.
    private func finish(_ key: ObjectIdentifier, url: URL, served: Engine.Served?, app: Bool, pictures: Bool) {
        guard let task = active.removeValue(forKey: key) else { return }
        var headers = [
            "Content-Type": served?.mime ?? "text/plain",
            "Access-Control-Allow-Origin": "*",
            // The app's own files can't change while it runs.
            "Cache-Control": app ? "max-age=31536000, immutable" : "no-cache",
        ]
        // An entry may run its own scripts, but nothing it does reaches the network.
        if !app { headers["Content-Security-Policy"] = "connect-src sgloss: data: blob:" + (pictures ? "" : "; img-src 'none'; media-src 'none'") }
        let resp = HTTPURLResponse(url: url, statusCode: served == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(served?.data ?? Data())
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))
    }
}

/// Files bundled with the app and dictionary icons, served at `sgloss://app/…`.
enum AppResources {
    nonisolated(unsafe) private static let iconCache = NSCache<NSString, NSData>()
    /// Every frame asks for article.css; it is read from disk once.
    nonisolated(unsafe) private static let fileCache = NSCache<NSString, NSData>()

    static func serve(path: String, iconPath: String?) -> Engine.Served? {
        if path.hasPrefix("/icon/") {
            guard let iconPath, let png = icon(at: iconPath) else { return nil }
            return Engine.Served(data: png, mime: "image/png")
        }
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty, !rel.contains(".."),
              let base = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) else { return nil }
        let url = base.appendingPathComponent(rel)
        let data: Data
        if let hit = fileCache.object(forKey: rel as NSString) {
            data = hit as Data
        } else {
            guard let read = try? Data(contentsOf: url) else { return nil }
            fileCache.setObject(read as NSData, forKey: rel as NSString)
            data = read
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "js": mime = "text/javascript; charset=utf-8"
        case "png": mime = "image/png"
        case "svg": mime = "image/svg+xml"
        default: mime = "application/octet-stream"
        }
        return Engine.Served(data: data, mime: mime)
    }

    /// Converts any icon file (BMP, ICO, PNG, JPEG…) to a small PNG.
    static func icon(at path: String) -> Data? {
        if let hit = iconCache.object(forKey: path as NSString) { return hit as Data }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        // Pick the frame closest to 64 px (ICO files carry several sizes).
        var best = 0
        var bestScore = Int.max
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let score = abs(w - 64)
            if score < bestScore { bestScore = score; best = i }
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, best, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        iconCache.setObject(out, forKey: path as NSString)
        return out as Data
    }
}

#if DEBUG
/// For checking Share as Image in a running build: selects text in an entry as a drag would.
extension ArticleCoordinator {
    static let debugSelectScript = """
    if (window.top !== window) addEventListener('message', (e) => {
      const m = e.data && e.data.sgDebugSelect;
      if (!m) return;
      const nodes = [];
      let all = '';
      const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let n = w.nextNode(); n; n = w.nextNode()) {
        if (!n.parentElement.getClientRects().length || /^(SCRIPT|STYLE)$/.test(n.parentElement.tagName)) continue;
        nodes.push([n, all.length]); all += n.data;
      }
      const r = document.createRange();
      if (!m.from && !m.before) r.selectNodeContents(document.body);
      else {
        const i = m.before ? 0 : all.indexOf(m.from), j = m.to ? all.indexOf(m.to, i) + m.to.length : i + m.from.length;
        if (i < 0 || j < i) return parent.postMessage({ sgDebugRect: null }, '*');
        const a = nodes.findLast(([, o]) => o <= i), b = nodes.find(([n, o]) => o + n.data.length >= j);
        r.setStart(a[0], i - a[1]); r.setEnd(b[0], j - b[1]);
        if (m.before) r.setStartBefore(document.querySelector(m.before));
      }
      getSelection().removeAllRanges(); getSelection().addRange(r);
      parent.postMessage({ sgDebugRect: r.getBoundingClientRect().top }, '*');
    });
    """

    func debugSelect(dict: String, from: String, to: String, before: String) {
        guard let hit = model.shown?.hits.first(where: { $0.dict == dict || $0.name.localizedCaseInsensitiveContains(dict) }),
              let args = try? JSONSerialization.data(withJSONObject: [hit.dict, from, to, before]),
              let json = String(data: args, encoding: .utf8) else { return }
        web?.evaluateJavaScript("""
            (([id, from, to, before]) => {
              const f = document.querySelector(`section.src[data-id="${id}"] iframe`);
              const on = (e) => {
                if (!e.data || !('sgDebugRect' in e.data)) return;
                removeEventListener('message', on);
                if (e.data.sgDebugRect != null) scrollTo(0, f.getBoundingClientRect().top + scrollY + e.data.sgDebugRect - 160);
              };
              addEventListener('message', on);
              f.contentWindow.postMessage({ sgDebugSelect: { from, to, before } }, '*');
            })(\(json))
            """, completionHandler: nil)
    }
}
#endif
