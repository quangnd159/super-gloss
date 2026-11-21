import SwiftUI

@main
struct SuperGlossApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Super Gloss", id: "main") {
            MainView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 780)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 760)
        .defaultPosition(.center)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            let updater = Updater.shared
            Button(updater.isReady ? "Relaunch to Update" : "Check for Updates…") {
                updater.isReady ? updater.relaunch() : updater.check(userInitiated: true)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Dictionaries…") { chooseDictionaries() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .textEditing) {
            Button("Look Up…") { model.requestFocus(selectAll: true) }
                .keyboardShortcut("l")
            Divider()
            Button("Find in Entries…") { model.startFind() }
                .keyboardShortcut("f")
            Button("Find Next") { model.findStep(1) }
                .keyboardShortcut("g")
                .disabled(!model.canFind)
            Button("Find Previous") { model.findStep(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!model.canFind)
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(model.backStack.isEmpty)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(model.forwardStack.isEmpty)
            Divider()
            Button("Next Source") { model.stepSource(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Source") { model.stepSource(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Go to Dictionary…") { model.startIndex() }
                .keyboardShortcut("j")
                .disabled(!model.canFind)
            Divider()
            Button("Pronounce") { model.article?.pronounce() }
                .keyboardShortcut("p")
            Button(model.shownIsSaved ? "Remove from Saved" : "Save Word") { model.toggleSaved() }
                .keyboardShortcut("d")
                .disabled(model.shownWord == nil)
            Button("Copy Saved Words") { model.copySaved() }
                .disabled(model.saved.isEmpty)
            Button("Surprise Me") { model.surprise() }
                .keyboardShortcut("r")
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/")
            Divider()
            Button("Super Gloss on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/quangnd159/super-gloss")!)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { model.zoom += 0.1 }
                .keyboardShortcut("=")
            Button("Smaller Text") { model.zoom -= 0.1 }
                .keyboardShortcut("-")
            Button("Actual Size") { model.zoom = 1 }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
