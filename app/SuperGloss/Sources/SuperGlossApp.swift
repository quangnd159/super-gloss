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
        .defaultSize(width: 980, height: 780)
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
        CommandGroup(replacing: .newItem) {
            Button("Add Dictionaries…") { chooseDictionaries() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .textEditing) {
            Button("Look Up…") { model.requestFocus(selectAll: true) }
                .keyboardShortcut("l")
            Button("Find in Library") { model.requestFocus(selectAll: true) }
                .keyboardShortcut("f")
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(model.backStack.isEmpty)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(model.forwardStack.isEmpty)
            Divider()
            Button("Next Source") { model.article?.jump(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Source") { model.article?.jump(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("Pronounce") { model.article?.pronounce() }
                .keyboardShortcut("p")
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
