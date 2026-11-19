import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            SourcesPane(model: model)
                .tabItem { Label("Sources", systemImage: "books.vertical") }
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 500)
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
                    Text("Articles appear in this order. Drag to rearrange.")
                }
                Section("Locations") {
                    ForEach(model.prefs.roots, id: \.self) { root in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(root)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
                            } label: { Image(systemName: "arrow.right.circle") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                            Button {
                                model.removeRoot(root)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop reading from this location")
                        }
                    }
                }
            }
            HStack {
                Button("Add Dictionaries…") { chooseDictionaries() }
                Spacer()
                Text("Formats: MDict · StarDict · DSL · Babylon · dictd · XDXF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Toggle("", isOn: Binding(get: { dict.enabled }, set: { model.setEnabled(dict.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .help(dict.about.isEmpty ? dict.path : dict.about)
        .contextMenu {
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
    @State private var hotKey: HotKeyPreset = AppModel.shared.prefs.hotKey
    @State private var zoom: Double = AppModel.shared.prefs.zoom
    @State private var appearance: AppearanceMode = AppModel.shared.prefs.appearance

    var body: some View {
        Form {
            Section {
                Picker("Summon from anywhere", selection: $hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: hotKey) {
                    model.prefs.hotKey = hotKey
                    HotKey.shared.register(hotKey)
                }
                Text("Press it again to hide. Select text in any app and choose **Services → Look Up in Super Gloss** to look it up directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: appearance) {
                    model.prefs.appearance = appearance
                    appearance.apply()
                }
                LabeledContent("Text size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $zoom, in: 0.7...2.0, step: 0.05)
                            .onChange(of: zoom) { model.zoom = zoom }
                        Image(systemName: "textformat.size.larger")
                    }
                }
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
