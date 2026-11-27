import AppKit
import AVFoundation
import Carbon.HIToolbox

/// Plays dictionary audio natively (Ogg Vorbis is transcoded by the core).
@MainActor
final class AudioPlayer {
    private let engine: Engine
    private var player: AVAudioPlayer?
    private var token = 0

    init(engine: Engine) { self.engine = engine }

    func play(dict: String, path: String) {
        token += 1
        let t = token
        let engine = engine
        Task {
            let data = await Task.detached(priority: .userInitiated) { engine.audio(dict: dict, path: path) }.value
            guard t == self.token else { return }
            guard let data, let p = try? AVAudioPlayer(data: data) else {
                NSSound.beep()
                return
            }
            self.player?.stop()
            self.player = p
            p.prepareToPlay()
            p.play()
        }
    }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case none, optionSpace, controlOptionSpace, commandShiftSpace, controlCommandD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .optionSpace: "⌥ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .commandShiftSpace: "⇧⌘ Space"
        case .controlCommandD: "⌃⌥⌘ D"
        }
    }

    var combo: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .none: nil
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .commandShiftSpace: (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .controlCommandD: (UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey))
        }
    }
}

/// System-wide shortcut via Carbon (no accessibility permission needed).
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    /// The chosen shortcut is held by another app, so it does nothing here.
    private(set) var taken = false

    func register(_ preset: HotKeyPreset) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        taken = false
        guard let combo = preset.combo else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Carbon calls this on the main thread.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5347_4C53), id: 1) // 'SGLS'
        taken = RegisterEventHotKey(combo.key, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) != noErr
    }
}

/// Light/dark override for the whole app; `.system` follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Services menu provider ("Look Up in Super Gloss") and URL scheme handling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.prefs.appearance.apply()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        HotKey.shared.action = { AppDelegate.toggleMainWindow() }
        HotKey.shared.register(AppModel.shared.prefs.hotKey)
        // ⌥⌘↑/↓ step between sources and ⌥⌘←/→ hide and show one, wherever focus is.
        // Arrow-key equivalents in SwiftUI menus don't match reliably (the function-key
        // flag), so route them here. A mouse's side buttons go back and forward, as in a browser.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            guard event.window?.identifier?.rawValue.hasPrefix("main") == true else { return event }
            if event.type == .otherMouseDown {
                let button = event.buttonNumber
                guard button == 3 || button == 4 else { return event }
                MainActor.assumeIsolated {
                    if button == 3 { AppModel.shared.goBack() } else { AppModel.shared.goForward() }
                }
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = event.keyCode
            guard mods == [.command, .option] else { return event }
            switch code {
            case 125, 126: MainActor.assumeIsolated { AppModel.shared.stepSource(code == 125 ? 1 : -1) }
            case 123, 124: MainActor.assumeIsolated { AppModel.shared.hideCurrent(code == 123) }
            default: return event
            }
            return nil
        }
        Updater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.appWillTerminate()
    }

    private var keyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.openMainWindow?() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "supergloss" {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                // supergloss://lookup?q=cat, supergloss://lookup/cat or supergloss://cat
                let path = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
                let word = comps?.queryItems?.first { $0.name == "q" || $0.name == "word" }?.value
                    ?? (url.host == "lookup" ? path : [url.host?.removingPercentEncoding ?? "", path].filter { !$0.isEmpty }.joined(separator: "/"))
                #if DEBUG
                // supergloss://debug-select?dict=LDOCE&from=when&to=accident[&before=img]: selects text in an entry.
                if url.host == "debug-select" {
                    let q = { (k: String) in comps?.queryItems?.first { $0.name == k }?.value ?? "" }
                    (AppModel.shared.article as? ArticleCoordinator)?.debugSelect(dict: q("dict"), from: q("from"), to: q("to"), before: q("before"))
                    continue
                }
                #endif
                if !word.isEmpty, word != "lookup" {
                    AppModel.shared.lookUpExternally(word)
                    AppDelegate.summon()
                }
            } else if url.isFileURL {
                AppModel.shared.addRoots([url])
            }
        }
    }

    @objc func lookUp(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let s = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        AppModel.shared.lookUpExternally(String(s.prefix(200)))
        AppDelegate.summon()
    }

    static func mainWindow() -> NSWindow? {
        // SwiftUI can keep more than one NSWindow for the scene; prefer the live one.
        let candidates = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeKey }
        return candidates.first(where: \.isKeyWindow) ?? candidates.first(where: \.isVisible) ?? candidates.first
    }

    /// Set while waiting for activation to land; see `applicationDidBecomeActive`.
    private static var pendingPresent = false

    /// Brings the main window forward as the key window, search line ready for typing.
    static func summon() {
        if NSApp.isActive {
            presentMain()
        } else {
            // NSApp.activate() is cooperative: from a hot key it marks the app active but
            // the window server keeps keyboard focus with the previous app, so typing goes
            // nowhere. Activation requested through LaunchServices gets real focus.
            pendingPresent = true
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg)
        }
    }

    private static func presentMain() {
        if let w = mainWindow() {
            w.makeKeyAndOrderFront(nil)
        } else {
            AppModel.shared.openMainWindow?()
        }
        AppModel.shared.requestFocus(selectAll: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Updater.shared.appBecameActive()
        if Self.pendingPresent {
            Self.pendingPresent = false
            Self.presentMain()
        }
    }

    static func toggleMainWindow() {
        if NSApp.isActive, mainWindow()?.isVisible == true {
            NSApp.hide(nil)
        } else {
            summon()
        }
    }
}
