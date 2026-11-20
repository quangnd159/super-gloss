import AppKit
import ImageIO
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
        config.suppressesIncrementalRendering = false
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = config.userContentController
        ucc.add(WeakMessageHandler(c), name: "sg")
        if let url = Bundle.main.url(forResource: "frame", withExtension: "js", subdirectory: "Web"),
           let src = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        let web = ArticleWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        web.uiDelegate = c
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.pageZoom = model.zoom
        c.web = web
        model.article = c
        web.load(URLRequest(url: URL(string: "sgloss://app/index.html")!))
        return web
    }

    func updateNSView(_ nsView: ArticleWebView, context: Context) {}
}

/// WKWebView without browser affordances: no file drops (the window handles
/// dictionary drops), no reload/navigation menu items.
final class ArticleWebView: WKWebView {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let drop: Set<String> = [
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
            "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
            "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierInspectElement",
        ]
        menu.items.removeAll { drop.contains($0.identifier?.rawValue ?? "") }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        super.willOpenMenu(menu, with: event)
    }
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
    private var queued: String?
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
    func page(_ direction: Int) { run("sg.page(\(direction))") }
    func pronounce() { run("sg.pronounce() || null") }
    func setZoom(_ zoom: Double) { web?.pageZoom = zoom }
    func setIcons(_ on: Bool) { run("sg.icons(\(on))") }

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

    private func run(_ js: String) {
        guard loaded else {
            if js.hasPrefix("sg.show") || js.hasPrefix("window.sg && sg.clear") { queued = js }
            return
        }
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "loaded":
            loaded = true
            if let q = queued {
                queued = nil
                web?.evaluateJavaScript(q, completionHandler: nil)
            }
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
            if let s = body["url"] as? String, let u = URL(string: s), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(u)
            }
        case "key":
            if let k = body["key"] as? String { model.typed(k) }
        case "index":
            model.noteIndex(open: body["open"] as? Bool ?? false, name: body["name"] as? String ?? "",
                            matches: body["matches"] as? Int ?? 0, total: body["total"] as? Int ?? 0)
        default:
            break
        }
    }

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
        let shown = model.shown
        queued = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.show(shown, dictionaries: self.model.dictionaries, landing: nil)
        }
    }

    // MARK: sgloss:// scheme

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(task)
        active[key] = task
        let engine = model.engine
        let iconPath: String? = url.host == "app" && url.path.hasPrefix("/icon/")
            ? model.dictionaries.first { $0.id == url.lastPathComponent }?.icon : nil
        Task {
            let served: Engine.Served? = await Task.detached(priority: .userInitiated) {
                if url.host == "app" {
                    return AppResources.serve(path: url.path, iconPath: iconPath)
                }
                return engine.serve(url.absoluteString)
            }.value
            guard let task = self.active.removeValue(forKey: key) else { return }
            let status = served == nil ? 404 : 200
            var headers = ["Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
            headers["Content-Type"] = served?.mime ?? "text/plain"
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(resp)
            task.didReceive(served?.data ?? Data())
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))
    }
}

/// Files bundled with the app and dictionary icons, served at `sgloss://app/…`.
enum AppResources {
    nonisolated(unsafe) private static let iconCache = NSCache<NSString, NSData>()

    static func serve(path: String, iconPath: String?) -> Engine.Served? {
        if path.hasPrefix("/icon/") {
            guard let iconPath, let png = icon(at: iconPath) else { return nil }
            return Engine.Served(data: png, mime: "image/png")
        }
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty, !rel.contains(".."),
              let base = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) else { return nil }
        let url = base.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url) else { return nil }
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
