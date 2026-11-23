import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            SourcesPane(model: model)
                .frame(width: 640, height: 500)
                .tabItem { Label("Dictionaries", systemImage: "books.vertical") }
            // Only as tall as its rows: the window fits each pane, as macOS settings do.
            GeneralPane(model: model)
                .scrollDisabled(true)
                .frame(width: 640)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
    }
}

struct SourcesPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                Section {
                    ForEach(model.dictionaries) { d in
                        SourceRow(model: model, dict: d)
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Reading order")
                }
                Section("Locations") {
                    ForEach(model.roots, id: \.self) { root in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((root as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(root)
                            Spacer()
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
                            } label: { Image(systemName: "arrow.right.circle") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                                .accessibilityLabel("Show in Finder")
                            Button {
                                model.removeRoot(root)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop reading from this location")
                                .accessibilityLabel("Remove location")
                        }
                    }
                }
            }
            Button("Add Dictionaries…") { chooseDictionaries() }
        }
        .padding(16)
    }
}

struct SourceRow: View {
    let model: AppModel
    let dict: DictSummary

    var body: some View {
        HStack(spacing: 10) {
            DictIcon(path: dict.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(dict.name).lineLimit(1)
                Group {
                    switch dict.state {
                    case "ready":
                        Text(subtitle)
                    case "failed":
                        Text(dict.error ?? "Could not open").foregroundStyle(.red)
                    default:
                        HStack(spacing: 6) {
                            ProgressView(value: Double(dict.progress))
                                .frame(width: 90)
                            Text("Indexing…")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Toggle(dict.name, isOn: Binding(get: { dict.enabled }, set: { model.setEnabled(dict.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .help(dict.about.isEmpty ? dict.path : dict.about)
        .contextMenu {
            // Reordering without a long drag, and without the mouse (VoiceOver's actions too).
            let i = model.dictionaries.firstIndex { $0.id == dict.id } ?? 0
            let last = model.dictionaries.count - 1
            Button("Move to Top") { model.move(fromOffsets: [i], toOffset: 0) }.disabled(i == 0)
            Button("Move Up") { model.move(fromOffsets: [i], toOffset: i - 1) }.disabled(i == 0)
            Button("Move Down") { model.move(fromOffsets: [i], toOffset: i + 2) }.disabled(i >= last)
            Button("Move to Bottom") { model.move(fromOffsets: [i], toOffset: last + 1) }.disabled(i >= last)
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dict.path)]) }
            Button("Rebuild Index") { model.reindex(dict.id) }
        }
    }

    private var subtitle: String {
        var parts = [dict.format, "\(dict.entries.formatted()) headwords"]
        if !dict.languages.isEmpty { parts.append(dict.languages) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(dict.size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

struct DictIcon: View {
    let path: String?
    var body: some View {
        Group {
            if let path, let data = AppResources.icon(at: path), let img = NSImage(data: data) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct GeneralPane: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var hotKey: HotKeyPreset
    @State private var hotKeyTaken = HotKey.shared.taken
    @State private var appearance: AppearanceMode
    @State private var showIcons: Bool
    @State private var checksForUpdates: Bool

    init(model: AppModel) {
        self.model = model
        _hotKey = State(initialValue: model.prefs.hotKey)
        _appearance = State(initialValue: model.prefs.appearance)
        _showIcons = State(initialValue: model.prefs.showIcons)
        _checksForUpdates = State(initialValue: model.prefs.checksForUpdates)
    }

    var body: some View {
        Form {
            Section {
                Picker("Super Gloss Hotkey", selection: $hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: hotKey) {
                    model.prefs.hotKey = hotKey
                    HotKey.shared.register(hotKey)
                    hotKeyTaken = HotKey.shared.taken
                }
                if hotKeyTaken {
                    Text("\(hotKey.label) is taken by another app. Choose another.")
                        .foregroundStyle(.red)
                }
                LabeledContent("Keyboard shortcuts") {
                    Button("Show All…") { openWindow(id: "shortcuts") }
                }
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: appearance) {
                    model.prefs.appearance = appearance
                    appearance.apply()
                }
                Toggle("Show dictionary icons", isOn: $showIcons)
                    .onChange(of: showIcons) { model.showIcons = showIcons }
                Slider(value: Binding(get: { model.zoom }, set: { model.zoom = $0 }), in: 0.7...2.0, step: 0.05) {
                    Text("Text size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityValue(Text(model.zoom, format: .percent))
            }
            Section {
                Toggle("Update automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) {
                        model.prefs.checksForUpdates = checksForUpdates
                        Updater.shared.scheduleChecks()
                    }
                LabeledContent("Version \(Updater.shared.version)") { UpdateStatus(updater: .shared) }
            }
            Section {
                LabeledContent("History") {
                    Button("Clear Recent Words") { model.clearHistory() }
                        .disabled(model.history.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings' line for updates: what the updater is doing, said beside the button that asked.
private struct UpdateStatus: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            switch updater.phase {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case let .downloading(v):
                ProgressView().controlSize(.small)
                Text("Downloading \(v)…").foregroundStyle(.secondary)
            case .current:
                Text("Up to date").foregroundStyle(.secondary)
            case let .failed(message):
                Text(message).foregroundStyle(.secondary)
            case let .available(v, page):
                Text("\(v) is out").foregroundStyle(.secondary)
                Button("Download…") { NSWorkspace.shared.open(page) }
            default:
                EmptyView()
            }
            if case let .ready(v) = updater.phase {
                Text("\(v) is ready").foregroundStyle(.secondary)
                Button("Relaunch to Update") { updater.relaunch() }
            } else if !updater.phase.isAvailable {
                Button("Check Now") { updater.check(userInitiated: true, inPill: false) }
                    .disabled(updater.phase == .checking || updater.phase.isDownloading)
            }
        }
        .lineLimit(1)
    }
}
