import AppKit
import OSLog
import UniformTypeIdentifiers
import WebKit

/// Share as Image: the reader's selection set on a card (Web/card) in a web view that is never
/// on screen, captured at exactly 1080×1350 sRGB and written to a PNG for the share picker.
/// The view is made when a card is first wanted and let go once sharing has rested a while.
@MainActor
final class ShareCard: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Selection: Equatable {
        let dict: String
        let entries: [Int]
        let word: String
        /// The dictionary's short name, the card's byline.
        let name: String
        /// Where the selection lies in the entry and what it reads (frame.js).
        let start: String
        let end: String
        let text: String
        let dark: Bool
    }

    enum Outcome {
        case image(URL)
        /// Too long to fit: a card is never cut.
        case tooLong
        case failed

        /// Still good to hand out: its file is where it was written.
        var stands: Bool {
            if case let .image(url) = self { FileManager.default.fileExists(atPath: url.path) } else { true }
        }
    }

    private static let log = Logger(subsystem: "app.supergloss.SuperGloss", category: "share")
    /// The card in CSS px (card.js lays it out at this size), captured at 2x.
    private static let size = CGSize(width: 540, height: 675)
    nonisolated private static let pixels = (width: 1080, height: 1350)
    /// A card is waited for this long at most.
    private static let patience = Duration.seconds(6)
    /// After this long unused, the view goes: nothing stays resident for a share that isn't coming.
    private static let rest = Duration.seconds(180)

    private let schemes: any WKURLSchemeHandler
    private let store: WKWebsiteDataStore
    private var view: WKWebView?
    private var job: (selection: Selection, url: URL, waiting: [(Outcome) -> Void], since: ContinuousClock.Instant)?
    private var last: (selection: Selection, outcome: Outcome)?
    private var deadline: Task<Void, Never>?
    private var idle: Task<Void, Never>?

    /// Served as the reading page is (`schemes`, the entries' origins), sharing its data store.
    init(schemes: any WKURLSchemeHandler, store: WKWebsiteDataStore) {
        self.schemes = schemes
        self.store = store
    }

    /// Calls `done` with the card for `s`: at once when it is the one last made, once ready
    /// when it is being made. A card for another selection takes its place.
    func render(_ s: Selection, then done: @escaping (Outcome) -> Void) {
        if let last, last.selection == s, last.outcome.stands { return done(last.outcome) }
        if job?.selection == s {
            job?.waiting.append(done)
            return
        }
        let web = view ?? makeView()
        var c = URLComponents()
        c.scheme = "sgloss"
        c.host = s.dict
        c.path = "/__card/card.html"
        c.queryItems = [
            .init(name: "e", value: s.entries.map(String.init).joined(separator: ",")),
            .init(name: "word", value: s.word), .init(name: "name", value: s.name),
            .init(name: "start", value: s.start), .init(name: "end", value: s.end), .init(name: "text", value: s.text),
        ]
        // URLSearchParams reads "+" as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { return done(.failed) }
        job = (s, url, [done], .now)
        last = nil
        idle?.cancel()
        web.appearance = NSAppearance(named: s.dark ? .darkAqua : .aqua)
        web.load(URLRequest(url: url))
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            // A page that hangs is left behind with its view: the next card gets a new one.
            self?.view = nil
            self?.finish(.failed, "timed out")
        }
    }

    private func makeView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.setURLSchemeHandler(schemes, forURLScheme: "sgloss")
        config.userContentController.add(WeakMessageHandler(self), name: "card")
        let web = WKWebView(frame: CGRect(origin: .zero, size: Self.size), configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        view = web
        return web
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the card itself, not the entries it holds (they share its origin).
        guard let j = job, message.frameInfo.isMainFrame, message.frameInfo.request.url == j.url,
              let body = message.body as? [String: Any], let state = body["state"] as? String else { return }
        switch state {
        case "ready": capture()
        case "too-long": finish(.tooLong, "too long")
        default: finish(.failed, "\(state): \(body["reason"] ?? "")")
        }
    }

    private func capture() {
        guard let web = view, let j = job else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: Self.size)
        // In points, painted at the scale WebKit gives a view in no window, the main screen's:
        // this many points come out 1080 pixels wide.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        cfg.snapshotWidth = NSNumber(value: Double(Self.pixels.width) / scale)
        cfg.afterScreenUpdates = true
        let file = Self.file(for: j.selection)
        web.takeSnapshot(with: cfg) { [weak self] image, error in
            // A card for another selection may have taken its place meanwhile.
            guard let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                if self?.job?.selection == j.selection { self?.finish(.failed, "snapshot: \(error?.localizedDescription ?? "no image")") }
                return
            }
            Task { [weak self] in
                let written = await Task.detached(priority: .userInitiated) { Self.writePNG(image, to: file) }.value
                guard self?.job?.selection == j.selection else { return }
                self?.finish(written ? .image(file) : .failed, written ? "\(image.width)×\(image.height) px snapshot" : "PNG not written")
            }
        }
    }

    private func finish(_ outcome: Outcome, _ note: String) {
        guard let j = job else { return }
        job = nil
        deadline?.cancel()
        let ms = Int((ContinuousClock.now - j.since) / .milliseconds(1))
        if case .failed = outcome { Self.log.error("card failed after \(ms) ms, \(note, privacy: .public)") }
        else { Self.log.debug("card in \(ms) ms, \(note, privacy: .public)") }
        if case .failed = outcome {} else { last = (j.selection, outcome) }
        // The entries' scripts stop with their frames. The page stays: the next card loads in the
        // same web process, where a page of its own (about:blank) would cost a new one, ~40 ms.
        view?.evaluateJavaScript("document.body.replaceChildren()")
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.rest)
            guard !Task.isCancelled else { return }
            self?.view = nil
        }
        for done in j.waiting { done(outcome) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Nothing on the card leaves it: no sounds, links or pages from the web.
        decisionHandler(["sgloss", "about"].contains(action.request.url?.scheme?.lowercased() ?? "") ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        view = nil
        finish(.failed, "web content process ended")
    }

    // MARK: the file

    nonisolated private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share as Image", isDirectory: true)

    /// Named for what it shows, which is the name the picker and whoever receives it see, in a
    /// folder of its own: the next card of the same word never replaces one already handed out
    /// (copied, or waiting in a message not yet sent).
    private static func file(for s: Selection) -> URL {
        let name = "\(s.word) – \(s.name)".replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        return folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name).appendingPathExtension("png")
    }

    /// Cards a day old go as the next is written: long past being pasted or sent.
    nonisolated private static func sweep() {
        let fm = FileManager.default, old = Date(timeIntervalSinceNow: -86_400)
        for dir in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        where ((try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture) < old {
            try? fm.removeItem(at: dir)
        }
    }

    /// Exactly the card's pixels, in sRGB, opaque.
    nonisolated private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        sweep()
        guard (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.interpolationQuality = image.width == pixels.width ? .none : .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard let out = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        // Unfiltered rows suit a card's flat colours: a quarter of the default's time, and smaller.
        CGImageDestinationAddImage(dst, out, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_NONE]] as CFDictionary)
        return CGImageDestinationFinalize(dst)
    }
}
