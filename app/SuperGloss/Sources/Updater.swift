import AppKit
import CryptoKit
import Observation
import OSLog
import Security

/// Keeps Super Gloss current from its GitHub releases: beside the disk image people download,
/// each release carries the signed app zipped (scripts/release.sh makes both), and that is
/// the update. A zip unpacks without mounting anything, which macOS would guard.
///
/// A newer release's zip is fetched in the background and checked against the digest GitHub
/// lists for it; the app inside is admitted only if it is newer and satisfies this app's own
/// designated requirement (same identifier, same Developer ID team), so nothing but a build we
/// signed can replace this one. It waits on the app's own volume and goes in with one atomic
/// swap at relaunch: at once from the pill, by itself while Super Gloss is out of sight, or at
/// quit. The reader comes back to the same word, at the same place.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(version: String)
        /// Verified and waiting beside the app for a relaunch.
        case ready(version: String)
        /// Newer, but this copy can't replace itself (a read-only place): the release page.
        case available(version: String, page: URL)
        case current
        case failed(String)
        /// Just relaunched into this version.
        case updated(version: String, page: URL)

        var isDownloading: Bool { if case .downloading = self { true } else { false } }
        var isAvailable: Bool { if case .available = self { true } else { false } }
    }

    private(set) var phase: Phase = .idle
    /// The pill is on screen.
    private(set) var pillShown = false
    /// The pointer is over the pill: it stays until it leaves.
    var hovering = false {
        didSet { if hovering != oldValue { scheduleHide() } }
    }

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Only a build signed with a Developer ID can tell a genuine update; development builds can't.
    let enabled = Updater.ownRequirement() != nil
    var isReady: Bool { staged != nil }

    /// The verified new version, waiting (observed: the menu offers to relaunch).
    private var staged: Staged?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var inactiveSince: Date?
    /// Shown when the app next comes forward (it may have relaunched out of sight).
    @ObservationIgnored private var pendingPill = false
    /// The check under way was asked for from the menu, so its outcome is told in the pill.
    @ObservationIgnored private var pillForCheck = false

    private struct Staged {
        let app: URL
        let dir: URL
        let version: String
        let page: URL
    }

    private let defaults = UserDefaults.standard
    private static let log = Logger(subsystem: "app.supergloss.SuperGloss", category: "update")
    private static let feed = URL(string: "https://api.github.com/repos/quangnd159/super-gloss/releases/latest")!
    private static let checkEvery: Duration = .seconds(6 * 3600)

    private init() {}

    // MARK: lifecycle

    func start() {
        if let u = defaults.dictionary(forKey: Keys.updated), let v = u["version"] as? String,
           let page = (u["page"] as? String).flatMap(URL.init(string:)) {
            defaults.removeObject(forKey: Keys.updated)
            phase = .updated(version: v, page: page)
            pendingPill = true
        }
        if let r = defaults.dictionary(forKey: Keys.resume), let word = r["word"] as? String {
            defaults.removeObject(forKey: Keys.resume)
            let place = (r["dict"] as? String).flatMap { d in (r["offset"] as? Double).map { Place(dict: d, offset: $0) } }
            AppModel.shared.resume(Visit(word: word, place: place))
        }
        if NSApp.isActive { appBecameActive() }
        scheduleChecks()
    }

    /// Checks shortly after launch, then every few hours, while automatic checks are on.
    func scheduleChecks() {
        scheduleTask?.cancel()
        guard enabled, AppModel.shared.prefs.checksForUpdates else { return }
        scheduleTask = Task {
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                check()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    func appBecameActive() {
        inactiveSince = nil
        if pendingPill {
            pendingPill = false
            show()
        }
    }

    /// Quitting puts a waiting update in place, so the next launch is the new version.
    func appWillTerminate() {
        guard let s = staged, swapIn() else { return }
        remember(updatedTo: s)
    }

    // MARK: checking

    /// `userInitiated`: asked for, so every step is told, "up to date" included; otherwise only
    /// a ready update is. `inPill`: told in the window's pill (Settings tells it in place).
    func check(userInitiated: Bool = false, inPill: Bool = true) {
        pillForCheck = userInitiated && inPill
        if staged != nil || checkTask != nil {
            if pillForCheck { show() }
            return
        }
        guard enabled else {
            if userInitiated { settle(.failed("Only release builds can update themselves")) }
            return
        }
        if userInitiated {
            phase = .checking
            if pillForCheck { show() }
        }
        let current = version
        let feed = defaults.string(forKey: Keys.feedOverride).flatMap(URL.init(string:)) ?? Self.feed
        checkTask = Task {
            defer { checkTask = nil }
            do {
                let release: Release
                do { release = try await Self.latest(feed) } catch let e as UpdateError { throw e } catch {
                    throw UpdateError("Couldn't reach GitHub", error)
                }
                guard Self.isNewer(release.version, than: current) else {
                    if userInitiated { settle(.current) } else { endQuietly() }
                    return
                }
                guard let archive = release.archive, let dir = Self.stagingDirectory() else {
                    phase = .available(version: release.version, page: release.page)
                    if userInitiated || defaults.string(forKey: Keys.dismissed) != release.version { show() }
                    return
                }
                phase = .downloading(version: release.version)
                let app: URL
                do {
                    app = try await Task.detached(priority: .utility) {
                        try await Self.fetch(archive, digest: release.digest, into: dir, newerThan: current)
                    }.value
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    throw (error as? UpdateError) ?? UpdateError("Couldn't download the update", error)
                }
                staged = Staged(app: app, dir: dir, version: release.version, page: release.page)
                phase = .ready(version: release.version)
                if userInitiated || defaults.string(forKey: Keys.dismissed) != release.version {
                    if NSApp.isActive { show() } else { pendingPill = true }
                }
                watchForIdle()
            } catch {
                let e = (error as? UpdateError) ?? UpdateError("Couldn't check for updates", error)
                Self.log.error("\(e.message, privacy: .public): \(e.cause, privacy: .public)")
                if userInitiated {
                    settle(.failed(e.message))
                } else {
                    endQuietly()
                }
            }
        }
    }

    // MARK: relaunching

    /// Swaps the new version in and opens it in this one's place, on the same word.
    /// `quietly`: Super Gloss is out of sight, so it comes back without taking focus, and
    /// hidden if it was hidden.
    func relaunch(quietly: Bool = false, hidden: Bool = false) {
        guard let s = staged else { return }
        let target = Bundle.main.bundleURL
        guard swapIn() else { return }
        remember(updatedTo: s)
        if let v = AppModel.shared.resumePoint {
            var r: [String: Any] = ["word": v.word]
            if let p = v.place {
                r["dict"] = p.dict
                r["offset"] = p.offset
            }
            defaults.set(r, forKey: Keys.resume)
        }
        // Opens the new version once this process has gone; `open` alone would just bring
        // this instance forward.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let flags = quietly ? (hidden ? ["-g", "-j"] : ["-g"]) : []
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.05; done; exec /usr/bin/open \"$@\"", "sh"]
            + flags + [target.path]
        do {
            try p.run()
        } catch {
            settle(.failed("Installed — quit and reopen Super Gloss to finish"))
            return
        }
        NSApp.terminate(nil)
    }

    /// One atomic exchange of the staged app with the running one's bundle; the old version,
    /// left in the staging folder, goes with it.
    private func swapIn() -> Bool {
        guard let s = staged else { return false }
        let target = Bundle.main.bundleURL
        guard renamex_np(s.app.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            staged = nil
            try? FileManager.default.removeItem(at: s.dir)
            settle(.failed("Couldn't replace the app where it is"))
            return false
        }
        staged = nil
        idleTask?.cancel()
        LSRegisterURL(target as CFURL, true)
        try? FileManager.default.removeItem(at: s.dir)
        return true
    }

    private func remember(updatedTo s: Staged) {
        defaults.set(["version": s.version, "page": s.page.absoluteString], forKey: Keys.updated)
        defaults.removeObject(forKey: Keys.dismissed)
    }

    /// While an update waits, it goes in by itself once Super Gloss has been in the background
    /// for a minute and is out of sight (hidden, closed, minimized), or nobody has touched the
    /// Mac for five.
    private func watchForIdle() {
        idleTask?.cancel()
        idleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard staged != nil else { return }
                if NSApp.isActive {
                    inactiveSince = nil
                    continue
                }
                let since = inactiveSince ?? .now
                inactiveSince = since
                guard Date.now.timeIntervalSince(since) >= 60 else { continue }
                let window = AppDelegate.mainWindow()
                let outOfSight = NSApp.isHidden || window?.isVisible != true || window?.isMiniaturized == true
                let away = CGEventType(rawValue: ~0).map {
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= 300
                } ?? false
                if outOfSight || away {
                    relaunch(quietly: true, hidden: outOfSight)
                    return
                }
            }
        }
    }

    // MARK: the pill

    func show() {
        pillShown = true
        scheduleHide()
    }

    /// Closed by hand. A ready update still goes in by itself; it isn't announced again.
    func dismiss() {
        pillShown = false
        hideTask?.cancel()
        switch phase {
        case let .ready(v), let .available(v, _): defaults.set(v, forKey: Keys.dismissed)
        case .downloading, .checking: break
        default: phase = .idle
        }
    }

    /// A check nobody asked for, ending with nothing to say, leaves other news (an update
    /// that just went in) where it is.
    private func endQuietly() {
        switch phase {
        case .checking, .downloading: phase = .idle
        default: break
        }
    }

    private func settle(_ p: Phase) {
        phase = p
        if pillForCheck { show() }
    }

    /// Passing news leaves on its own, unless the pointer is resting on it.
    private func scheduleHide() {
        hideTask?.cancel()
        let seconds: Double
        switch phase {
        case .current: seconds = 2.5
        case .failed, .updated: seconds = 7
        default: return
        }
        guard pillShown, !hovering else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            pillShown = false
            phase = staged.map { .ready(version: $0.version) } ?? .idle
        }
    }

    // MARK: work off the main thread

    private struct Release: Sendable {
        let version: String
        let page: URL
        /// The zipped app; older releases have only the disk image.
        let archive: URL?
        let digest: String?
    }

    private struct UpdateError: Error {
        /// For the pill.
        let message: String
        /// For the log.
        let cause: String
        init(_ m: String, _ underlying: (any Error)? = nil) {
            message = m
            cause = underlying.map { String(describing: $0) } ?? m
        }
    }

    nonisolated private static func latest(_ feed: URL) async throws -> Release {
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("GitHub answered \(http.statusCode)") }
        struct Wire: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
                let digest: String?
            }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let w = try dec.decode(Wire.self, from: data)
        let zip = w.assets.first { $0.name.hasSuffix(".zip") }
        let v = w.tagName.hasPrefix("v") ? String(w.tagName.dropFirst()) : w.tagName
        let digest = zip?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: v, page: w.htmlUrl, archive: zip?.browserDownloadUrl, digest: digest)
    }

    /// Downloads the release's zip into `dir`, unpacks the app and admits it.
    nonisolated private static func fetch(_ archive: URL, digest: String?, into dir: URL, newerThan current: String) async throws -> URL {
        let fm = FileManager.default
        let (tmp, response) = try await URLSession.shared.download(from: archive)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("The download failed (\(http.statusCode))") }
        let zip = dir.appendingPathComponent("update.zip")
        try fm.moveItem(at: tmp, to: zip)
        if let want = digest {
            let got = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard got == want.lowercased() else { throw UpdateError("The download was damaged") }
        }
        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        try? fm.removeItem(at: zip)
        guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("The download has no app in it") }
        try admit(app, newerThan: current)
        return app
    }

    /// The gate: newer than this version, and signed as this app is.
    nonisolated private static func admit(_ app: URL, newerThan current: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist), let v = info["CFBundleShortVersionString"] as? String,
              isNewer(v, than: current) else { throw UpdateError("The download isn't a newer version") }
        guard let req = ownRequirement()?.0 else { throw UpdateError("This build can't check signatures") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The update isn't signed")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, req, nil) == errSecSuccess else {
            throw UpdateError("The update isn't signed by Super Gloss")
        }
    }

    /// This app's designated requirement, when it's signed by a team (nil for ad-hoc builds).
    nonisolated private static func ownRequirement() -> (SecRequirement, team: String)? {
        var me: SecCode?
        var stat: SecStaticCode?
        var info: CFDictionary?
        var req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &stat) == errSecSuccess, let stat,
              SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              SecCodeCopyDesignatedRequirement(stat, [], &req) == errSecSuccess, let req
        else { return nil }
        return (req, team)
    }

    /// A fresh folder on the app's own volume (so the swap is a rename), or nil when the app
    /// can't be replaced where it is: a read-only volume, App Translocation, no permission.
    private static func stagingDirectory() -> URL? {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard !app.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: app.path),
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
        else { return nil }
        return try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
    }

    private struct ToolFailure: Error, CustomStringConvertible { let description: String }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let said = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError("Couldn't open the update", ToolFailure(description: "\(tool) \(p.terminationStatus): \(said)"))
        }
        return data
    }

    /// Dotted versions compared numerically: 1.10 is newer than 1.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private enum Keys {
        static let updated = "updatedTo"
        static let resume = "resumeAt"
        static let dismissed = "updateDismissed"
        /// A different release feed (a URL to JSON shaped like GitHub's), for testing. Only
        /// builds signed as this one can come through it.
        static let feedOverride = "SGUpdateFeed"
    }
}
